"""Discord /history, /reset, and /clear slash commands."""

from __future__ import annotations

import logging
from typing import TYPE_CHECKING

import discord
from discord import app_commands

if TYPE_CHECKING:
    from bot import DiscordBitNetBot

log = logging.getLogger(__name__)

_MAX_HISTORY_DISPLAY = 10  # messages shown in /history
_DISCORD_LIMIT = 1990


def setup_history_commands(bot: "DiscordBitNetBot") -> None:
    """Register /history, /reset, and /clear on *bot*."""

    @bot.tree.command(
        name="history",
        description="Show your recent conversation history with the AI.",
    )
    @app_commands.describe(count="Number of recent messages to display (1–20, default 10).")
    async def history(
        interaction: discord.Interaction,
        count: app_commands.Range[int, 1, 20] = _MAX_HISTORY_DISPLAY,
    ) -> None:
        await interaction.response.defer(ephemeral=True, thinking=True)

        messages = await bot.memory.get_history(
            user_id=interaction.user.id,
            limit=count,
        )

        if not messages:
            await interaction.followup.send(
                "You have no conversation history yet. Use `/chat` to start talking!",
                ephemeral=True,
            )
            return

        lines: list[str] = [f"**Your last {len(messages)} message(s):**\n"]
        for msg in messages:
            role_label = "**You**" if msg.role == "user" else "**AI**"
            # Truncate very long messages in the display
            content = msg.content if len(msg.content) <= 300 else msg.content[:297] + "…"
            lines.append(f"{role_label}: {content}")

        full_text = "\n".join(lines)

        # Trim to Discord limit
        if len(full_text) > _DISCORD_LIMIT:
            full_text = full_text[:_DISCORD_LIMIT - 3] + "…"

        await interaction.followup.send(full_text, ephemeral=True)
        log.info("Sent history to user_id=%s (%d messages).", interaction.user.id, len(messages))

    @bot.tree.command(
        name="reset",
        description="Reset your conversation history with the AI.",
    )
    async def reset(interaction: discord.Interaction) -> None:
        await interaction.response.defer(ephemeral=True, thinking=True)

        deleted = await bot.memory.clear_history(user_id=interaction.user.id)

        await interaction.followup.send(
            f"✅ Your conversation history has been reset ({deleted} message(s) deleted).",
            ephemeral=True,
        )
        log.info("Reset history for user_id=%s (%d rows).", interaction.user.id, deleted)

    @bot.tree.command(
        name="clear",
        description="Alias for /reset — clears your conversation history.",
    )
    async def clear(interaction: discord.Interaction) -> None:
        await interaction.response.defer(ephemeral=True, thinking=True)

        deleted = await bot.memory.clear_history(user_id=interaction.user.id)

        await interaction.followup.send(
            f"🗑️ Conversation cleared ({deleted} message(s) removed).",
            ephemeral=True,
        )
        log.info("Cleared history for user_id=%s (%d rows).", interaction.user.id, deleted)
