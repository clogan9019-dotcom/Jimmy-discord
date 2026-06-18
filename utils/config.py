"""Configuration loader for the Discord BitNet bot."""

from __future__ import annotations

import os
from pathlib import Path
from typing import Any

import yaml


_DEFAULT_CONFIG: dict[str, Any] = {
    "discord": {
        "token": "",
    },
    "bitnet": {
        "executable": "./bitnet",
        "model": "./models/heretic",
        "threads": 4,
        "context": 4096,
        "temperature": 0.8,
        "top_p": 0.95,
        "top_k": 40,
        "repeat_penalty": 1.1,
        "max_tokens": 512,
    },
    "database": {
        "file": "memory.db",
    },
    "logging": {
        "level": "INFO",
    },
}


class Config:
    """Typed wrapper around the YAML configuration file."""

    def __init__(self, path: str | Path = "config.yaml") -> None:
        self._path = Path(path)
        self._data: dict[str, Any] = {}
        self._load()

    # ------------------------------------------------------------------
    # Internal helpers
    # ------------------------------------------------------------------

    def _load(self) -> None:
        """Load and merge config from disk with defaults."""
        if self._path.exists():
            with self._path.open("r", encoding="utf-8") as fh:
                loaded: dict[str, Any] = yaml.safe_load(fh) or {}
        else:
            loaded = {}

        self._data = self._deep_merge(_DEFAULT_CONFIG, loaded)

    @staticmethod
    def _deep_merge(base: dict[str, Any], override: dict[str, Any]) -> dict[str, Any]:
        result = dict(base)
        for key, value in override.items():
            if key in result and isinstance(result[key], dict) and isinstance(value, dict):
                result[key] = Config._deep_merge(result[key], value)
            else:
                result[key] = value
        return result

    def get(self, *keys: str, default: Any = None) -> Any:
        """Retrieve a nested config value by dot-path keys."""
        node: Any = self._data
        for key in keys:
            if not isinstance(node, dict):
                return default
            node = node.get(key, default)
        return node

    # ------------------------------------------------------------------
    # Convenience accessors
    # ------------------------------------------------------------------

    @property
    def discord_token(self) -> str:
        token = os.environ.get("DISCORD_TOKEN") or self.get("discord", "token", default="")
        return str(token)

    @property
    def bitnet_executable(self) -> str:
        return str(self.get("bitnet", "executable", default="./bitnet"))

    @property
    def bitnet_model(self) -> str:
        return str(self.get("bitnet", "model", default="./models/heretic"))

    @property
    def bitnet_threads(self) -> int:
        return int(self.get("bitnet", "threads", default=4))

    @property
    def bitnet_context(self) -> int:
        return int(self.get("bitnet", "context", default=4096))

    @property
    def bitnet_temperature(self) -> float:
        return float(self.get("bitnet", "temperature", default=0.8))

    @property
    def bitnet_top_p(self) -> float:
        return float(self.get("bitnet", "top_p", default=0.95))

    @property
    def bitnet_top_k(self) -> int:
        return int(self.get("bitnet", "top_k", default=40))

    @property
    def bitnet_repeat_penalty(self) -> float:
        return float(self.get("bitnet", "repeat_penalty", default=1.1))

    @property
    def bitnet_max_tokens(self) -> int:
        return int(self.get("bitnet", "max_tokens", default=512))

    @property
    def database_file(self) -> str:
        return str(self.get("database", "file", default="memory.db"))

    @property
    def logging_level(self) -> str:
        return str(self.get("logging", "level", default="INFO")).upper()
