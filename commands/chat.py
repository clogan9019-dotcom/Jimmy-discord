"""Discord /chat slash command implementation."""

from __future__ import annotations

import asyncio
import logging
import re
from typing import TYPE_CHECKING

import discord
from discord import app_commands

from commands.tools import search_tool, shell_tool

if TYPE_CHECKING:
    from bot import DiscordBitNetBot

log = logging.getLogger(__name__)

# Discord message character limit
_DISCORD_LIMIT = 1990
# How often to edit the streaming message (seconds)
_EDIT_INTERVAL = 0.8
# Maximum conversation history messages to include in context
_MAX_CONTEXT_MESSAGES = 20
# Maximum messages kept per user in the database
_MAX_STORED_MESSAGES = 100
# Maximum AI tool calls before returning a normal response
_MAX_TOOL_ROUNDS = 2
_TOOL_CALL_RE = re.compile(r"\[\[\s*(search|shell)\s*:\s*(.*?)\s*\]\]", re.IGNORECASE | re.DOTALL)


def _split_message(text: str, limit: int = _DISCORD_LIMIT) -> list[str]:
    """Split *text* into chunks that fit within Discord's character limit."""
    if len(text) <= limit:
        return [text]
    chunks: list[str] = []
    while text:
        if len(text) <= limit:
            chunks.append(text)
            break
        # Try to split on a newline near the limit
        split_at = text.rfind("\n", 0, limit)
        if split_at == -1:
            split_at = text.rfind(" ", 0, limit)
        if split_at == -1:
            split_at = limit
        chunks.append(text[:split_at])
        text = text[split_at:].lstrip("\n")
    return chunks


def _tool_system_prompt(shell_allowed: bool) -> str:
    tools = [
        "You are Dolphin, a helpful AI assistant.",
        "You may use lightweight tools when they would help.",
        "To use web search, reply ONLY with: [[search: your search query]]",
    ]
    if shell_allowed:
        tools.append("To inspect this Raspberry Pi with shell, reply ONLY with: [[shell: command]]")
    tools.extend([
        "Only call one tool at a time.",
        "After a tool result is provided, answer the user's question normally.",
        "Do not invent tool results. Do not show tool-call syntax unless you are calling a tool.",
    ])
    return "\n".join(tools)


def _parse_tool_call(text: str) -> tuple[str, str] | None:
    match = _TOOL_CALL_RE.search(text.strip())
    if not match:
        return None
    tool = match.group(1).lower().strip()
    arg = match.group(2).strip()
    if not arg:
        return None
    return tool, arg


async def _collect_generation(bot: "DiscordBitNetBot", prompt: str) -> str:
    config = bot.config
    chunks: list[str] = []
    async for token in bot.model.generate(
        prompt=prompt,
        temperature=config.bitnet_temperature,
        top_p=config.bitnet_top_p,
        top_k=config.bitnet_top_k,
        repeat_penalty=config.bitnet_repeat_penalty,
        max_tokens=config.bitnet_max_tokens,
    ):
        chunks.append(token)
    return "".join(chunks).strip()


async def _generate_with_tools(
    bot: "DiscordBitNetBot",
    user: discord.abc.User,
    prompt: str,
    status_message: discord.Message | None = None,
) -> str:
    """Generate, execute AI-requested tools, then generate final answer."""
    shell_allowed = await bot.is_owner(user)
    current_prompt = prompt

    for round_index in range(_MAX_TOOL_ROUNDS + 1):
        output = await _collect_generation(bot, current_prompt)
        tool_call = _parse_tool_call(output)
        if tool_call is None or round_index >= _MAX_TOOL_ROUNDS:
            return output

        tool, arg = tool_call
        if status_message is not None:
            try:
                await status_message.edit(content=f"🛠️ Using `{tool}` tool…")
            except discord.HTTPException:
                pass

        if tool == "search":
            tool_result = await search_tool(arg)
        elif tool == "shell" and shell_allowed:
            tool_result = await shell_tool(arg)
        elif tool == "shell":
            tool_result = "Shell tool is owner-only and unavailable for this user."
        else:
            tool_result = f"Unknown tool: {tool}"

        # Keep tool result small enough for the model context on Raspberry Pi.
        tool_result = tool_result[:2400]
        current_prompt = (
            f"{current_prompt}\n{output}\n"
            f"Tool result for {tool}({arg!r}):\n{tool_result}\n"
            "Assistant:"
        )

    return "*(No response generated)*"


async def _stream_response(
    interaction: discord.Interaction,
    bot: "DiscordBitNetBot",
    prompt: str,
) -> None:
    """Run inference and stream the response by editing a Discord message."""
    memory = bot.memory
    model = bot.model
    config = bot.config

    user_id = interaction.user.id
    guild_id = interaction.guild_id

    # Persist the user's message
    await memory.add_message(
        user_id=user_id,
        role="user",
        content=prompt,
        guild_id=guild_id,
    )

    # Trim stored history to avoid unbounded growth
    await memory.trim_history(user_id, max_messages=_MAX_STORED_MESSAGES)

    # Build the full prompt with conversation context and tool instructions.
    shell_allowed = await bot.is_owner(interaction.user)
    full_prompt = await memory.format_context(
        user_id=user_id,
        max_messages=_MAX_CONTEXT_MESSAGES,
        system_prompt=_tool_system_prompt(shell_allowed),
    )

    # Send an initial "thinking" message
    await interaction.followup.send("⏳ Generating response…")
    # Fetch the message we just sent so we can edit it
    followup_message = await interaction.original_response()

    try:
        accumulated = await _generate_with_tools(
            bot=bot,
            user=interaction.user,
            prompt=full_prompt,
            status_message=followup_message,
        )
    except Exception:
        log.exception("Error during generation for user_id=%s", user_id)
        await followup_message.edit(content="❌ An error occurred during generation.")
        return

    # Final edit — remove cursor, show complete response
    if not accumulated.strip():
        accumulated = "*(No response generated)*"

    chunks = _split_message(accumulated.strip())

    try:
        await followup_message.edit(content=chunks[0])
    except discord.HTTPException as exc:
        log.warning("Could not edit followup message: %s", exc)

    # Send overflow chunks as additional messages
    for chunk in chunks[1:]:
        try:
            await interaction.followup.send(chunk)
        except discord.HTTPException as exc:
            log.warning("Could not send overflow chunk: %s", exc)

    # Persist the assistant reply
    await memory.add_message(
        user_id=user_id,
        role="assistant",
        content=accumulated.strip(),
        guild_id=guild_id,
    )

    log.info(
        "Chat response delivered | user_id=%s guild_id=%s chars=%d",
        user_id,
        guild_id,
        len(accumulated),
    )


async def stream_message_chat(
    message: discord.Message,
    bot: "DiscordBitNetBot",
    prompt: str,
) -> None:
    """Run inference for a normal Discord message mention/reply.

    This mirrors /chat behavior, but replies in-channel to a message when the
    bot is @mentioned, DM'd, or replied to.
    """
    memory = bot.memory
    model = bot.model
    config = bot.config

    user_id = message.author.id
    guild_id = message.guild.id if message.guild else None

    await memory.add_message(
        user_id=user_id,
        role="user",
        content=prompt,
        guild_id=guild_id,
    )
    await memory.trim_history(user_id, max_messages=_MAX_STORED_MESSAGES)

    shell_allowed = await bot.is_owner(message.author)
    full_prompt = await memory.format_context(
        user_id=user_id,
        max_messages=_MAX_CONTEXT_MESSAGES,
        system_prompt=_tool_system_prompt(shell_allowed),
    )

    try:
        reply_message = await message.reply(
            "⏳ Generating response…",
            mention_author=False,
            allowed_mentions=discord.AllowedMentions.none(),
        )
    except discord.HTTPException:
        reply_message = await message.channel.send(
            "⏳ Generating response…",
            allowed_mentions=discord.AllowedMentions.none(),
        )

    try:
        accumulated = await _generate_with_tools(
            bot=bot,
            user=message.author,
            prompt=full_prompt,
            status_message=reply_message,
        )
    except Exception:
        log.exception("Error during message generation for user_id=%s", user_id)
        try:
            await reply_message.edit(content="❌ An error occurred during generation.")
        except discord.HTTPException:
            pass
        return

    if not accumulated.strip():
        accumulated = "*(No response generated)*"

    chunks = _split_message(accumulated.strip())
    try:
        await reply_message.edit(content=chunks[0])
    except discord.HTTPException as exc:
        log.warning("Could not edit mention reply message: %s", exc)

    for chunk in chunks[1:]:
        try:
            await message.channel.send(
                chunk,
                allowed_mentions=discord.AllowedMentions.none(),
            )
        except discord.HTTPException as exc:
            log.warning("Could not send overflow mention chunk: %s", exc)

    await memory.add_message(
        user_id=user_id,
        role="assistant",
        content=accumulated.strip(),
        guild_id=guild_id,
    )

    log.info(
        "Mention/reply response delivered | user_id=%s guild_id=%s chars=%d",
        user_id,
        guild_id,
        len(accumulated),
    )


def setup_chat_command(bot: "DiscordBitNetBot") -> None:
    """Register the /chat slash command on *bot*."""

    @bot.tree.command(name="chat", description="Chat with the local BitNet AI model.")
    @app_commands.describe(message="Your message to the AI.")
    async def chat(interaction: discord.Interaction, message: str) -> None:
        await interaction.response.defer(thinking=True)

        queue = bot.inference_queue

        # Report queue position to the user if the model is busy
        position = queue.size + (1 if queue.is_busy else 0)
        if position > 0:
            try:
                await interaction.followup.send(
                    f"⏳ Your request is queued (position **{position + 1}**). "
                    "Please wait…",
                    ephemeral=True,
                )
            except discord.HTTPException:
                pass

        from utils.queue import InferenceJob  # local import to avoid circular deps

        job = InferenceJob(
            user_id=interaction.user.id,
            guild_id=interaction.guild_id,
            channel_id=interaction.channel_id,  # type: ignore[arg-type]
            prompt=message,
            callback=lambda: _stream_response(interaction, bot, message),
        )

        await queue.enqueue(job)
