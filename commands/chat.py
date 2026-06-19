"""Discord /chat slash command implementation."""

from __future__ import annotations

import asyncio
import logging
from typing import TYPE_CHECKING

import discord
from discord import app_commands

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

    # Build the full prompt with conversation context
    full_prompt = await memory.format_context(
        user_id=user_id,
        max_messages=_MAX_CONTEXT_MESSAGES,
    )

    # Send an initial "thinking" message
    await interaction.followup.send("⏳ Generating response…")
    # Fetch the message we just sent so we can edit it
    followup_message = await interaction.original_response()

    accumulated = ""
    last_edit_content = ""
    last_edit_time = asyncio.get_event_loop().time()

    async with interaction.channel.typing():  # type: ignore[union-attr]
        try:
            async for token in model.generate(
                prompt=full_prompt,
                temperature=config.bitnet_temperature,
                top_p=config.bitnet_top_p,
                top_k=config.bitnet_top_k,
                repeat_penalty=config.bitnet_repeat_penalty,
                max_tokens=config.bitnet_max_tokens,
            ):
                accumulated += token
                now = asyncio.get_event_loop().time()

                # Edit the message periodically to stream tokens
                if now - last_edit_time >= _EDIT_INTERVAL and accumulated != last_edit_content:
                    preview = accumulated[:_DISCORD_LIMIT]
                    try:
                        await followup_message.edit(content=preview + " ▌")
                    except discord.HTTPException:
                        pass
                    last_edit_time = now
                    last_edit_content = accumulated

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

    full_prompt = await memory.format_context(
        user_id=user_id,
        max_messages=_MAX_CONTEXT_MESSAGES,
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

    accumulated = ""
    last_edit_content = ""
    last_edit_time = asyncio.get_event_loop().time()

    async with message.channel.typing():  # type: ignore[union-attr]
        try:
            async for token in model.generate(
                prompt=full_prompt,
                temperature=config.bitnet_temperature,
                top_p=config.bitnet_top_p,
                top_k=config.bitnet_top_k,
                repeat_penalty=config.bitnet_repeat_penalty,
                max_tokens=config.bitnet_max_tokens,
            ):
                accumulated += token
                now = asyncio.get_event_loop().time()

                if now - last_edit_time >= _EDIT_INTERVAL and accumulated != last_edit_content:
                    preview = accumulated[:_DISCORD_LIMIT]
                    try:
                        await reply_message.edit(content=preview + " ▌")
                    except discord.HTTPException:
                        pass
                    last_edit_time = now
                    last_edit_content = accumulated
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
