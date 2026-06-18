"""Discord /help slash command and admin utilities."""

from __future__ import annotations

import logging
from typing import TYPE_CHECKING

import discord
from discord import app_commands

if TYPE_CHECKING:
    from bot import DiscordBitNetBot

log = logging.getLogger(__name__)


def setup_admin_commands(bot: "DiscordBitNetBot") -> None:
    """Register /help on *bot*."""

    @bot.tree.command(
        name="help",
        description="Show available bot commands and how to use them.",
    )
    async def help_command(interaction: discord.Interaction) -> None:
        embed = discord.Embed(
            title="🤖 BitNet Bot — Help",
            description=(
                "A locally-running AI assistant powered by **bitnet.cpp** and the "
                "`bitnet-b1.58-2B-4T-heretic` model. All inference runs on-device — "
                "no data is sent to external APIs."
            ),
            colour=discord.Colour.green(),
        )

        embed.add_field(
            name="/chat `<message>`",
            value=(
                "Send a message to the AI. Your conversation history is remembered "
                "between messages. Responses stream in real time."
            ),
            inline=False,
        )
        embed.add_field(
            name="/history `[count]`",
            value=(
                "View your recent conversation history (1–20 messages, default 10). "
                "Your history is private and never visible to other users."
            ),
            inline=False,
        )
        embed.add_field(
            name="/reset",
            value="Clear your entire conversation history and start fresh.",
            inline=False,
        )
        embed.add_field(
            name="/clear",
            value="Alias for `/reset` — clears your conversation history.",
            inline=False,
        )
        embed.add_field(
            name="/ping",
            value="Check the bot's current websocket latency.",
            inline=False,
        )
        embed.add_field(
            name="/stats",
            value=(
                "Display bot and model statistics: uptime, memory usage, "
                "total inferences, tokens per second, queue length, and more."
            ),
            inline=False,
        )
        embed.add_field(
            name="/help",
            value="Show this help message.",
            inline=False,
        )

        embed.add_field(
            name="ℹ️ Queue System",
            value=(
                "Only one inference runs at a time to maximise performance on the "
                "Raspberry Pi. If the model is busy, your request is queued and you "
                "will receive a position estimate."
            ),
            inline=False,
        )

        embed.set_footer(text="Running on bitnet.cpp · All inference is local · No external APIs")

        await interaction.response.send_message(embed=embed, ephemeral=True)
        log.info("Help command used by user_id=%s.", interaction.user.id)
