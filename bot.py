"""Main entry point for the Discord BitNet bot.

Usage
-----
    python bot.py [--config path/to/config.yaml]
"""

from __future__ import annotations

import argparse
import asyncio
import logging
import signal
import sys
import time

import discord
from discord.ext import commands

from bitnet.wrapper import BitNetModel
from commands.admin import setup_admin_commands
from commands.chat import setup_chat_command
from commands.history import setup_history_commands
from commands.stats import setup_stats_commands
from database.memory import ConversationMemory
from utils.config import Config
from utils.logger import get_logger, setup_logging
from utils.queue import InferenceQueue

log = get_logger(__name__)


class DiscordBitNetBot(commands.Bot):
    """Custom discord.py Bot subclass with BitNet model integration."""

    def __init__(self, config: Config) -> None:
        intents = discord.Intents.default()
        intents.message_content = False  # not needed for slash commands

        super().__init__(
            command_prefix="!",  # prefix commands disabled; slash commands only
            intents=intents,
            help_command=None,
        )

        self.config = config
        self.start_time: float = 0.0

        self.model = BitNetModel(
            executable=config.bitnet_executable,
            model_path=config.bitnet_model,
            threads=config.bitnet_threads,
            context_length=config.bitnet_context,
        )

        self.memory = ConversationMemory(db_path=config.database_file)
        self.inference_queue = InferenceQueue()

    # ------------------------------------------------------------------
    # discord.py lifecycle hooks
    # ------------------------------------------------------------------

    async def setup_hook(self) -> None:
        """Called once after login, before the gateway connection."""
        log.info("Running setup_hook: registering slash commands…")

        setup_chat_command(self)
        setup_history_commands(self)
        setup_stats_commands(self)
        setup_admin_commands(self)

        # Sync application commands globally
        synced = await self.tree.sync()
        log.info("Synced %d application command(s).", len(synced))

        # Start the inference queue worker
        await self.inference_queue.start()

        # Load the BitNet model
        log.info("Loading BitNet model — this may take a moment on Raspberry Pi…")
        try:
            await self.model.load()
        except FileNotFoundError:
            log.critical(
                "BitNet executable not found. "
                "Please run install.sh to build bitnet.cpp first."
            )
            # Allow the bot to start so slash commands are registered,
            # but generation will fail until the model is available.

    async def on_ready(self) -> None:
        """Called when the bot has connected to Discord."""
        self.start_time = time.monotonic()
        log.info(
            "Bot ready! Logged in as %s (id=%s) | %d guild(s)",
            self.user,
            self.user.id if self.user else "unknown",
            len(self.guilds),
        )
        await self.change_presence(
            activity=discord.Activity(
                type=discord.ActivityType.listening,
                name="/chat",
            )
        )

    async def on_guild_join(self, guild: discord.Guild) -> None:
        log.info("Joined guild: %s (id=%s)", guild.name, guild.id)

    async def on_guild_remove(self, guild: discord.Guild) -> None:
        log.info("Left guild: %s (id=%s)", guild.name, guild.id)

    async def on_error(self, event: str, *args: object, **kwargs: object) -> None:
        log.exception("Unhandled error in event '%s'.", event)

    async def on_app_command_error(
        self,
        interaction: discord.Interaction,
        error: discord.app_commands.AppCommandError,
    ) -> None:
        log.exception(
            "App command error for user_id=%s: %s",
            interaction.user.id,
            error,
        )
        message = "❌ An unexpected error occurred. Please try again later."
        try:
            if interaction.response.is_done():
                await interaction.followup.send(message, ephemeral=True)
            else:
                await interaction.response.send_message(message, ephemeral=True)
        except discord.HTTPException:
            pass

    async def close(self) -> None:
        """Graceful shutdown: stop queue and unload model before disconnecting."""
        log.info("Shutting down bot…")
        await self.inference_queue.stop()
        await self.model.unload()
        await super().close()
        log.info("Bot shutdown complete.")


# ------------------------------------------------------------------
# Runner
# ------------------------------------------------------------------

async def _run(config_path: str) -> None:
    config = Config(config_path)
    setup_logging(config.logging_level)

    token = config.discord_token
    if not token:
        log.critical(
            "No Discord token found. Set DISCORD_TOKEN env var or "
            "add 'discord.token' to config.yaml."
        )
        sys.exit(1)

    bot = DiscordBitNetBot(config)

    # Graceful shutdown on SIGINT / SIGTERM
    loop = asyncio.get_running_loop()

    def _handle_signal() -> None:
        log.info("Received shutdown signal.")
        asyncio.create_task(bot.close())

    for sig in (signal.SIGINT, signal.SIGTERM):
        try:
            loop.add_signal_handler(sig, _handle_signal)
        except NotImplementedError:
            # Windows does not support add_signal_handler for all signals
            pass

    log.info("Starting Discord BitNet Bot…")
    async with bot:
        await bot.start(token)


def main() -> None:
    parser = argparse.ArgumentParser(description="Discord BitNet AI Bot")
    parser.add_argument(
        "--config",
        default="config.yaml",
        metavar="PATH",
        help="Path to the YAML configuration file (default: config.yaml)",
    )
    args = parser.parse_args()

    try:
        asyncio.run(_run(args.config))
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
