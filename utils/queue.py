"""Async single-concurrency inference queue for the Discord BitNet bot.

Only one inference runs at a time to avoid overloading the Raspberry Pi CPU.
All other requests wait and receive a position estimate.
"""

from __future__ import annotations

import asyncio
import logging
import time
from dataclasses import dataclass, field
from typing import Any, Callable, Coroutine

log = logging.getLogger(__name__)


@dataclass
class InferenceJob:
    """A single queued inference task."""

    user_id: int
    guild_id: int | None
    channel_id: int
    prompt: str
    callback: Callable[..., Coroutine[Any, Any, None]]
    enqueued_at: float = field(default_factory=time.monotonic)

    # Optional: notify the user of their queue position before we start
    position_callback: Callable[[int], Coroutine[Any, Any, None]] | None = None


class InferenceQueue:
    """Single-concurrency async queue for model inference jobs.

    Usage
    -----
    queue = InferenceQueue()
    await queue.start()               # start the worker loop
    await queue.enqueue(job)          # add a job
    await queue.stop()                # graceful shutdown
    """

    def __init__(self) -> None:
        self._queue: asyncio.Queue[InferenceJob] = asyncio.Queue()
        self._worker_task: asyncio.Task[None] | None = None
        self._running = False
        self._current_job: InferenceJob | None = None
        self._total_processed: int = 0
        self._total_wait_time: float = 0.0

    # ------------------------------------------------------------------
    # Public API
    # ------------------------------------------------------------------

    async def start(self) -> None:
        """Start the background worker."""
        if self._running:
            return
        self._running = True
        self._worker_task = asyncio.create_task(self._worker(), name="inference-queue-worker")
        log.info("Inference queue worker started.")

    async def stop(self) -> None:
        """Signal the worker to finish and wait for it."""
        self._running = False
        # Unblock the worker if it is waiting for items
        try:
            self._queue.put_nowait(_SENTINEL)  # type: ignore[arg-type]
        except asyncio.QueueFull:
            pass
        if self._worker_task is not None:
            try:
                await asyncio.wait_for(self._worker_task, timeout=30.0)
            except (asyncio.TimeoutError, asyncio.CancelledError):
                self._worker_task.cancel()
        log.info("Inference queue worker stopped.")

    async def enqueue(self, job: InferenceJob) -> int:
        """Add *job* to the queue and return its 1-based position."""
        await self._queue.put(job)
        position = self._queue.qsize()
        log.info(
            "Job enqueued for user_id=%s | queue_size=%d",
            job.user_id,
            position,
        )
        return position

    @property
    def size(self) -> int:
        """Number of jobs currently waiting (not including the active job)."""
        return self._queue.qsize()

    @property
    def is_busy(self) -> bool:
        """True if a job is currently being processed."""
        return self._current_job is not None

    @property
    def stats(self) -> dict[str, Any]:
        return {
            "queue_size": self.size,
            "is_busy": self.is_busy,
            "total_processed": self._total_processed,
            "avg_wait_seconds": (
                self._total_wait_time / self._total_processed
                if self._total_processed > 0
                else 0.0
            ),
        }

    # ------------------------------------------------------------------
    # Internal worker
    # ------------------------------------------------------------------

    async def _worker(self) -> None:
        """Continuously pull jobs from the queue and execute them."""
        while self._running:
            try:
                job = await self._queue.get()
            except asyncio.CancelledError:
                break

            # Sentinel value used to unblock during shutdown
            if job is _SENTINEL:  # type: ignore[comparison-overlap]
                self._queue.task_done()
                break

            self._current_job = job
            wait_time = time.monotonic() - job.enqueued_at
            self._total_wait_time += wait_time

            log.info(
                "Processing job for user_id=%s after %.2fs wait",
                job.user_id,
                wait_time,
            )

            try:
                await job.callback()
            except Exception:
                log.exception("Unhandled exception in inference job for user_id=%s", job.user_id)
            finally:
                self._current_job = None
                self._total_processed += 1
                self._queue.task_done()


# Sentinel object used to unblock the worker during shutdown
class _SentinelType:
    pass


_SENTINEL = _SentinelType()
