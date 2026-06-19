"""SQLite-backed conversation memory store.

Messages are stored with per-user and per-guild metadata so the bot can use recent shared server memory when responding.
"""

from __future__ import annotations

import asyncio
import logging
import sqlite3
from contextlib import contextmanager
from dataclasses import dataclass
from pathlib import Path
from typing import Generator

log = logging.getLogger(__name__)

_SCHEMA = """
CREATE TABLE IF NOT EXISTS messages (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id     TEXT    NOT NULL,
    guild_id    TEXT,
    role        TEXT    NOT NULL CHECK(role IN ('user', 'assistant', 'system')),
    content     TEXT    NOT NULL,
    created_at  REAL    NOT NULL DEFAULT (unixepoch('now', 'subsec'))
);

CREATE INDEX IF NOT EXISTS idx_messages_user
    ON messages (user_id, created_at);

CREATE INDEX IF NOT EXISTS idx_messages_guild
    ON messages (guild_id, created_at);
"""


@dataclass
class Message:
    """A single conversation turn."""

    id: int
    user_id: str
    guild_id: str | None
    role: str
    content: str
    created_at: float


class ConversationMemory:
    """Async-safe SQLite conversation memory.

    All public methods are safe to call from asyncio coroutines; heavy
    database work is executed via ``asyncio.to_thread`` to avoid blocking
    the event loop.
    """

    def __init__(self, db_path: str | Path) -> None:
        self._db_path = Path(db_path)
        self._db_path.parent.mkdir(parents=True, exist_ok=True)
        self._write_lock = asyncio.Lock()
        self._init_db()

    # ------------------------------------------------------------------
    # Setup
    # ------------------------------------------------------------------

    def _init_db(self) -> None:
        """Create tables if they don't exist."""
        with self._connect() as conn:
            conn.executescript(_SCHEMA)
        log.info("Database initialised at '%s'.", self._db_path)

    @contextmanager
    def _connect(self) -> Generator[sqlite3.Connection, None, None]:
        conn = sqlite3.connect(self._db_path, timeout=30)
        conn.row_factory = sqlite3.Row
        conn.execute("PRAGMA journal_mode=WAL")
        conn.execute("PRAGMA foreign_keys=ON")
        try:
            yield conn
            conn.commit()
        except Exception:
            conn.rollback()
            raise
        finally:
            conn.close()

    # ------------------------------------------------------------------
    # Public API
    # ------------------------------------------------------------------

    async def add_message(
        self,
        user_id: int | str,
        role: str,
        content: str,
        guild_id: int | str | None = None,
    ) -> None:
        """Append a single message to *user_id*'s history."""
        uid = str(user_id)
        gid = str(guild_id) if guild_id is not None else None

        async with self._write_lock:
            await asyncio.to_thread(self._insert_message, uid, gid, role, content)

    async def get_history(
        self,
        user_id: int | str,
        limit: int = 50,
    ) -> list[Message]:
        """Return the most recent *limit* messages for *user_id*, oldest first."""
        uid = str(user_id)
        return await asyncio.to_thread(self._fetch_history, uid, limit)

    async def get_global_history(
        self,
        guild_id: int | str | None,
        limit: int = 50,
    ) -> list[Message]:
        """Return recent shared history for a guild/DM scope, oldest first."""
        gid = str(guild_id) if guild_id is not None else None
        return await asyncio.to_thread(self._fetch_global_history, gid, limit)

    async def stats(self, guild_id: int | str | None = None) -> dict[str, int | bool]:
        """Return memory statistics for status/stats displays."""
        gid = str(guild_id) if guild_id is not None else None
        return await asyncio.to_thread(self._stats, gid)

    async def clear_history(self, user_id: int | str) -> int:
        """Delete all messages for *user_id*. Returns number of rows deleted."""
        uid = str(user_id)
        async with self._write_lock:
            return await asyncio.to_thread(self._delete_history, uid)

    async def trim_history(
        self,
        user_id: int | str,
        max_messages: int,
    ) -> None:
        """Keep only the latest *max_messages* for *user_id*."""
        uid = str(user_id)
        async with self._write_lock:
            await asyncio.to_thread(self._trim, uid, max_messages)

    async def format_context(
        self,
        user_id: int | str,
        max_messages: int = 20,
        system_prompt: str = "You are Dolphin, a helpful AI assistant.",
        guild_id: int | str | None = None,
        use_global: bool = True,
    ) -> str:
        """Build a simple instruction prompt from conversation history.

        In servers, the prompt uses recent shared guild memory so the bot can
        answer questions about things it said to other users. In DMs, it falls
        back to that user's private history.
        """
        uid = str(user_id)
        if use_global and guild_id is not None:
            messages = await self.get_global_history(guild_id, limit=max_messages)
            parts: list[str] = [
                system_prompt.strip(),
                "",
                "Recent shared server memory follows. Use it only if relevant.",
            ]
            for msg in messages:
                if msg.role == "assistant":
                    speaker = "Assistant"
                elif msg.role == "system":
                    speaker = "System"
                elif msg.user_id == uid:
                    speaker = "Current user"
                else:
                    speaker = f"User {msg.user_id[-4:]}"
                content = msg.content.strip()
                if content:
                    parts.append(f"{speaker}: {content}")
        else:
            messages = await self.get_history(user_id, limit=max_messages)
            parts = [system_prompt.strip(), ""]
            for msg in messages:
                role = "User" if msg.role == "user" else "Assistant"
                content = msg.content.strip()
                if content:
                    parts.append(f"{role}: {content}")

        parts.append("Assistant:")
        return "\n".join(parts)

    # ------------------------------------------------------------------
    # Synchronous helpers (run in executor threads)
    # ------------------------------------------------------------------

    def _insert_message(
        self,
        user_id: str,
        guild_id: str | None,
        role: str,
        content: str,
    ) -> None:
        with self._connect() as conn:
            conn.execute(
                "INSERT INTO messages (user_id, guild_id, role, content) "
                "VALUES (?, ?, ?, ?)",
                (user_id, guild_id, role, content),
            )

    def _fetch_history(self, user_id: str, limit: int) -> list[Message]:
        with self._connect() as conn:
            rows = conn.execute(
                """
                SELECT id, user_id, guild_id, role, content, created_at
                FROM messages
                WHERE user_id = ?
                ORDER BY created_at DESC
                LIMIT ?
                """,
                (user_id, limit),
            ).fetchall()
        # Reverse so oldest is first
        return [
            Message(
                id=r["id"],
                user_id=r["user_id"],
                guild_id=r["guild_id"],
                role=r["role"],
                content=r["content"],
                created_at=r["created_at"],
            )
            for r in reversed(rows)
        ]

    def _fetch_global_history(self, guild_id: str | None, limit: int) -> list[Message]:
        with self._connect() as conn:
            if guild_id is None:
                rows = conn.execute(
                    """
                    SELECT id, user_id, guild_id, role, content, created_at
                    FROM messages
                    WHERE guild_id IS NULL
                    ORDER BY created_at DESC
                    LIMIT ?
                    """,
                    (limit,),
                ).fetchall()
            else:
                rows = conn.execute(
                    """
                    SELECT id, user_id, guild_id, role, content, created_at
                    FROM messages
                    WHERE guild_id = ?
                    ORDER BY created_at DESC
                    LIMIT ?
                    """,
                    (guild_id, limit),
                ).fetchall()
        return [
            Message(
                id=r["id"],
                user_id=r["user_id"],
                guild_id=r["guild_id"],
                role=r["role"],
                content=r["content"],
                created_at=r["created_at"],
            )
            for r in reversed(rows)
        ]

    def _stats(self, guild_id: str | None) -> dict[str, int | bool]:
        with self._connect() as conn:
            total_messages = conn.execute("SELECT COUNT(*) FROM messages").fetchone()[0]
            total_users = conn.execute("SELECT COUNT(DISTINCT user_id) FROM messages").fetchone()[0]
            total_assistant = conn.execute(
                "SELECT COUNT(*) FROM messages WHERE role = 'assistant'"
            ).fetchone()[0]

            if guild_id is None:
                scope_messages = conn.execute(
                    "SELECT COUNT(*) FROM messages WHERE guild_id IS NULL"
                ).fetchone()[0]
                scope_users = conn.execute(
                    "SELECT COUNT(DISTINCT user_id) FROM messages WHERE guild_id IS NULL"
                ).fetchone()[0]
                scope_assistant = conn.execute(
                    "SELECT COUNT(*) FROM messages WHERE guild_id IS NULL AND role = 'assistant'"
                ).fetchone()[0]
            else:
                scope_messages = conn.execute(
                    "SELECT COUNT(*) FROM messages WHERE guild_id = ?",
                    (guild_id,),
                ).fetchone()[0]
                scope_users = conn.execute(
                    "SELECT COUNT(DISTINCT user_id) FROM messages WHERE guild_id = ?",
                    (guild_id,),
                ).fetchone()[0]
                scope_assistant = conn.execute(
                    "SELECT COUNT(*) FROM messages WHERE guild_id = ? AND role = 'assistant'",
                    (guild_id,),
                ).fetchone()[0]

        return {
            "global_enabled": True,
            "total_messages": int(total_messages),
            "total_users": int(total_users),
            "total_assistant_messages": int(total_assistant),
            "scope_messages": int(scope_messages),
            "scope_users": int(scope_users),
            "scope_assistant_messages": int(scope_assistant),
        }

    def _delete_history(self, user_id: str) -> int:
        with self._connect() as conn:
            cursor = conn.execute(
                "DELETE FROM messages WHERE user_id = ?", (user_id,)
            )
            return cursor.rowcount

    def _trim(self, user_id: str, max_messages: int) -> None:
        with self._connect() as conn:
            conn.execute(
                """
                DELETE FROM messages
                WHERE user_id = ?
                  AND id NOT IN (
                      SELECT id FROM messages
                      WHERE user_id = ?
                      ORDER BY created_at DESC
                      LIMIT ?
                  )
                """,
                (user_id, user_id, max_messages),
            )
