"""Discord /stats and /ping slash commands."""

from __future__ import annotations

import logging
import os
import time
from typing import TYPE_CHECKING

import discord
from discord import app_commands

if TYPE_CHECKING:
    from bot import DiscordBitNetBot

log = logging.getLogger(__name__)


def _get_memory_usage_mb() -> float:
    """Return current RSS memory usage of this process in MB."""
    try:
        with open(f"/proc/{os.getpid()}/status", "r") as fh:
            for line in fh:
                if line.startswith("VmRSS:"):
                    kb = int(line.split()[1])
                    return round(kb / 1024, 1)
    except Exception:
        pass
    return 0.0


def setup_stats_commands(bot: "DiscordBitNetBot") -> None:
    """Register /stats and /ping on *bot*."""

    @bot.tree.command(
        name="ping",
        description="Check the bot's latency.",
    )
    async def ping(interaction: discord.Interaction) -> None:
        latency_ms = round(bot.latency * 1000, 1)
        await interaction.response.send_message(
            f"🏓 Pong! Websocket latency: **{latency_ms} ms**",
            ephemeral=True,
        )

    @bot.tree.command(
        name="stats",
        description="Show bot and model statistics.",
    )
    async def stats(interaction: discord.Interaction) -> None:
        await interaction.response.defer(ephemeral=True, thinking=True)

        model_stats = bot.model.stats
        queue_stats = bot.inference_queue.stats
        memory_stats = await bot.memory.stats(interaction.guild_id)

        uptime_seconds = time.monotonic() - bot.start_time
        hours, remainder = divmod(int(uptime_seconds), 3600)
        minutes, seconds = divmod(remainder, 60)
        uptime_str = f"{hours}h {minutes}m {seconds}s"

        memory_mb = _get_memory_usage_mb()

        embed = discord.Embed(
            title="📊 Bot Statistics",
            colour=discord.Colour.blurple(),
        )

        embed.add_field(
            name="⏱️ Uptime",
            value=uptime_str,
            inline=True,
        )
        embed.add_field(
            name="🏓 Latency",
            value=f"{round(bot.latency * 1000, 1)} ms",
            inline=True,
        )
        embed.add_field(
            name="💾 Memory (RSS)",
            value=f"{memory_mb} MB",
            inline=True,
        )
        embed.add_field(
            name="🌐 Servers",
            value=str(len(bot.guilds)),
            inline=True,
        )
        embed.add_field(
            name="🤖 Model Loaded",
            value="✅ Yes" if model_stats["loaded"] else "❌ No",
            inline=True,
        )
        embed.add_field(
            name="🔢 Total Inferences",
            value=str(model_stats["total_inferences"]),
            inline=True,
        )
        embed.add_field(
            name="📝 Tokens Generated",
            value=str(model_stats["total_tokens_generated"]),
            inline=True,
        )
        embed.add_field(
            name="⚡ Avg Tokens/sec",
            value=str(model_stats["avg_tokens_per_second"]),
            inline=True,
        )
        embed.add_field(
            name="📋 Queue Length",
            value=str(queue_stats["queue_size"]),
            inline=True,
        )
        embed.add_field(
            name="⚙️ Model Threads",
            value=str(model_stats["threads"]),
            inline=True,
        )
        embed.add_field(
            name="📏 Context Length",
            value=str(model_stats["context_length"]),
            inline=True,
        )
        embed.add_field(
            name="🎮 GPU Offload",
            value=(
                f"Detected: {'✅' if model_stats.get('gpu_detected') else '❌'}\n"
                f"Layers: {model_stats.get('gpu_layers', 0)}"
            ),
            inline=True,
        )
        embed.add_field(
            name="🧠 Global Memory",
            value="✅ Enabled",
            inline=True,
        )
        embed.add_field(
            name="💬 This Server Memory",
            value=(
                f"{memory_stats['scope_messages']} messages\n"
                f"{memory_stats['scope_users']} user(s)\n"
                f"{memory_stats['scope_assistant_messages']} bot replies"
            ),
            inline=True,
        )
        embed.add_field(
            name="🗃️ Total Memory DB",
            value=(
                f"{memory_stats['total_messages']} messages\n"
                f"{memory_stats['total_users']} user(s)\n"
                f"{memory_stats['total_assistant_messages']} bot replies"
            ),
            inline=True,
        )

        embed.set_footer(text=f"Model: {model_stats['model_path']}")

        await interaction.followup.send(embed=embed, ephemeral=True)
        log.info("Stats requested by user_id=%s.", interaction.user.id)
