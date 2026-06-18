"""Low-level async subprocess manager for the bitnet.cpp executable.

Handles launching, streaming stdout/stderr, crash detection, and
automatic restart with exponential back-off.
"""

from __future__ import annotations

import asyncio
import logging
import time
from typing import AsyncIterator

log = logging.getLogger(__name__)

_MAX_RESTART_ATTEMPTS = 5
_INITIAL_BACKOFF = 1.0   # seconds
_MAX_BACKOFF = 60.0      # seconds
_BACKOFF_FACTOR = 2.0


class BitNetProcess:
    """Manages a single long-running bitnet.cpp subprocess.

    The process is launched with an interactive prompt-based protocol.
    Tokens are streamed line-by-line from stdout.
    """

    def __init__(
        self,
        executable: str,
        model_path: str,
        threads: int,
        context_length: int,
    ) -> None:
        self._executable = executable
        self._model_path = model_path
        self._threads = threads
        self._context_length = context_length

        self._process: asyncio.subprocess.Process | None = None
        self._lock = asyncio.Lock()
        self._restart_count = 0
        self._last_start_time: float = 0.0
        self._running = False

    # ------------------------------------------------------------------
    # Lifecycle
    # ------------------------------------------------------------------

    async def start(self) -> None:
        """Launch the subprocess, retrying with back-off on failure."""
        async with self._lock:
            await self._launch()

    async def stop(self) -> None:
        """Terminate the subprocess gracefully."""
        self._running = False
        if self._process is not None:
            try:
                self._process.terminate()
                try:
                    await asyncio.wait_for(self._process.wait(), timeout=10.0)
                except asyncio.TimeoutError:
                    self._process.kill()
                    await self._process.wait()
                log.info("BitNet process terminated.")
            except ProcessLookupError:
                pass
            self._process = None

    @property
    def is_alive(self) -> bool:
        """True if the subprocess is running."""
        return (
            self._process is not None
            and self._process.returncode is None
        )

    # ------------------------------------------------------------------
    # Inference
    # ------------------------------------------------------------------

    async def generate(
        self,
        prompt: str,
        temperature: float,
        top_p: float,
        top_k: int,
        repeat_penalty: float,
        max_tokens: int,
    ) -> AsyncIterator[str]:
        """Send *prompt* to the process and yield tokens as they arrive.

        Restarts the process automatically if it has crashed.
        """
        if not self.is_alive:
            log.warning("BitNet process not alive; restarting before inference.")
            await self._restart_with_backoff()

        assert self._process is not None
        assert self._process.stdin is not None
        assert self._process.stdout is not None

        # Build the command line that bitnet.cpp understands.
        # bitnet.cpp (run_inference) accepts flags on stdin or via a
        # dedicated prompt delimiter; we write a JSON-style instruction
        # followed by a newline to trigger generation.
        instruction = (
            f"[GENERATE] "
            f"temperature={temperature} "
            f"top_p={top_p} "
            f"top_k={top_k} "
            f"repeat_penalty={repeat_penalty} "
            f"max_tokens={max_tokens}\n"
            f"{prompt}\n"
            f"[END_PROMPT]\n"
        )

        try:
            self._process.stdin.write(instruction.encode("utf-8"))
            await self._process.stdin.drain()
        except (BrokenPipeError, ConnectionResetError):
            log.error("Broken pipe writing to BitNet process; restarting.")
            await self._restart_with_backoff()
            return

        # Stream tokens until we see the end-of-generation marker
        async for token in self._stream_until_eos():
            yield token

    # ------------------------------------------------------------------
    # Internal helpers
    # ------------------------------------------------------------------

    async def _launch(self) -> None:
        """Start the subprocess."""
        cmd = [
            self._executable,
            "-m", self._model_path,
            "-t", str(self._threads),
            "-c", str(self._context_length),
            "--interactive",
        ]
        log.info("Launching BitNet process: %s", " ".join(cmd))
        try:
            self._process = await asyncio.create_subprocess_exec(
                *cmd,
                stdin=asyncio.subprocess.PIPE,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE,
            )
            self._running = True
            self._last_start_time = time.monotonic()
            log.info("BitNet process started (pid=%d).", self._process.pid)

            # Drain the startup banner from stderr without blocking
            asyncio.create_task(self._drain_stderr(), name="bitnet-stderr-drain")
        except FileNotFoundError:
            log.error(
                "BitNet executable not found at '%s'. "
                "Run install.sh to build bitnet.cpp.",
                self._executable,
            )
            raise

    async def _drain_stderr(self) -> None:
        """Log stderr output from the subprocess in the background."""
        if self._process is None or self._process.stderr is None:
            return
        try:
            async for line in self._process.stderr:
                decoded = line.decode("utf-8", errors="replace").rstrip()
                if decoded:
                    log.debug("bitnet stderr: %s", decoded)
        except asyncio.CancelledError:
            pass
        except Exception:
            log.exception("Error reading bitnet stderr.")

    async def _stream_until_eos(self) -> AsyncIterator[str]:
        """Yield decoded tokens from stdout until the EOS marker."""
        if self._process is None or self._process.stdout is None:
            return

        eos_marker = b"[EOS]"
        buffer = b""

        try:
            while True:
                chunk = await asyncio.wait_for(
                    self._process.stdout.read(64),
                    timeout=60.0,
                )
                if not chunk:
                    # EOF — process died
                    log.warning("BitNet process stdout closed unexpectedly.")
                    break

                buffer += chunk

                # Emit complete UTF-8 sequences
                while buffer:
                    if eos_marker in buffer:
                        before, _ = buffer.split(eos_marker, 1)
                        if before:
                            yield before.decode("utf-8", errors="replace")
                        return

                    # Try to decode as much as possible
                    try:
                        text = buffer.decode("utf-8")
                        yield text
                        buffer = b""
                    except UnicodeDecodeError:
                        # Keep the last few bytes in case they form a
                        # multi-byte character split across two reads
                        if len(buffer) > 8:
                            safe = buffer[:-4]
                            yield safe.decode("utf-8", errors="replace")
                            buffer = buffer[-4:]
                        break

        except asyncio.TimeoutError:
            log.error("Timeout waiting for BitNet response.")

    async def _restart_with_backoff(self) -> None:
        """Attempt to restart the process with exponential back-off."""
        backoff = _INITIAL_BACKOFF
        for attempt in range(1, _MAX_RESTART_ATTEMPTS + 1):
            log.info(
                "Restart attempt %d/%d in %.1fs …",
                attempt,
                _MAX_RESTART_ATTEMPTS,
                backoff,
            )
            await asyncio.sleep(backoff)
            try:
                await self.stop()
                async with self._lock:
                    await self._launch()
                self._restart_count += 1
                log.info("BitNet process restarted successfully.")
                return
            except Exception:
                log.exception("Restart attempt %d failed.", attempt)
            backoff = min(backoff * _BACKOFF_FACTOR, _MAX_BACKOFF)

        log.critical(
            "BitNet process could not be restarted after %d attempts.",
            _MAX_RESTART_ATTEMPTS,
        )
        raise RuntimeError("BitNet process failed to restart.")
