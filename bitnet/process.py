"""Async subprocess runner for BitNet inference via run_inference.py.

Each generate() call spawns a fresh run_inference.py process, captures its
stdout, and streams the text back as chunks.  The InferenceQueue in utils/queue.py
guarantees only one process runs at a time, so there is no resource contention.
"""

from __future__ import annotations

import asyncio
import logging
import os
import sys
from pathlib import Path
from typing import AsyncIterator

log = logging.getLogger(__name__)


class BitNetProcess:
    """Runs BitNet inference by calling run_inference.py as a subprocess.

    Parameters
    ----------
    src_dir:
        Path to the cloned bitnet_cpp_src directory that contains
        run_inference.py.
    model_path:
        Path to the quantized GGUF model file.
    threads:
        Number of CPU threads to pass to the inference script.
    context_length:
        Maximum context window in tokens.
    python_executable:
        Python interpreter to use.  Defaults to the current interpreter so
        the bot's venv is always used.
    """

    def __init__(
        self,
        src_dir: str | Path,
        model_path: str | Path,
        threads: int = 4,
        context_length: int = 4096,
        python_executable: str | None = None,
    ) -> None:
        self._src_dir = Path(src_dir).resolve()
        self._model_path = Path(model_path).resolve()
        self._threads = threads
        self._context_length = context_length
        self._python = python_executable or sys.executable
        self._inference_script = self._src_dir / "run_inference.py"

    def _subprocess_env(self) -> dict[str, str]:
        """Environment for BitNet subprocesses.

        The BitNet/llama.cpp build produces shared libraries such as
        libllama.so under build subdirectories. When run_inference.py launches
        build/bin/llama-cli, the dynamic linker may not find those libraries
        unless LD_LIBRARY_PATH includes the directories containing .so files.
        """
        env = {**os.environ, "TOKENIZERS_PARALLELISM": "false"}
        if os.name != "nt":
            build_dir = self._src_dir / "build"
            lib_dirs: list[str] = []
            if build_dir.is_dir():
                for lib in build_dir.rglob("*.so*"):
                    parent = str(lib.parent)
                    if parent not in lib_dirs:
                        lib_dirs.append(parent)

            # Include common locations even if globbing missed a symlink/name.
            for candidate in (
                build_dir / "bin",
                build_dir / "src",
                build_dir / "3rdparty" / "llama.cpp" / "src",
                build_dir / "3rdparty" / "llama.cpp" / "ggml" / "src",
            ):
                if candidate.is_dir():
                    parent = str(candidate)
                    if parent not in lib_dirs:
                        lib_dirs.append(parent)

            if lib_dirs:
                existing = env.get("LD_LIBRARY_PATH")
                env["LD_LIBRARY_PATH"] = (
                    ":".join(lib_dirs + [existing]) if existing else ":".join(lib_dirs)
                )
        return env

    # ------------------------------------------------------------------
    # Validation
    # ------------------------------------------------------------------

    def validate(self) -> None:
        """Raise RuntimeError if the required files are missing."""
        if not self._src_dir.is_dir():
            raise RuntimeError(
                f"BitNet src_dir not found: '{self._src_dir}'. "
                "Run install.sh to clone and build bitnet.cpp."
            )
        if not self._inference_script.is_file():
            raise RuntimeError(
                f"run_inference.py not found at '{self._inference_script}'. "
                "Ensure bitnet_cpp_src was cloned correctly."
            )
        if not self._model_path.is_file():
            raise RuntimeError(
                f"Model file not found: '{self._model_path}'. "
                "Run install.sh — setup_env.py downloads and quantizes the model."
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
        """Run inference for *prompt* and yield output text chunks.

        Spawns run_inference.py, streams its stdout line by line, and
        yields each non-empty line as a chunk.
        """
        # Microsoft BitNet's run_inference.py only accepts a small subset of
        # llama-cli sampling flags. Passing unsupported flags such as --top-p,
        # --top-k, or --repeat-penalty makes argparse exit with code 2, which
        # produces an empty Discord response. Keep those settings in the public
        # API for future direct llama-cli support, but do not pass them through
        # this wrapper script.
        _ = (top_p, top_k, repeat_penalty)
        cmd = [
            self._python,
            str(self._inference_script),
            "-m", str(self._model_path),
            "-p", prompt,
            "-n", str(max_tokens),
            "-temp", str(temperature),
            "-t", str(self._threads),
            "-c", str(self._context_length),
        ]

        log.debug("Spawning inference: %s", " ".join(cmd[:6]) + " …")

        try:
            proc = await asyncio.create_subprocess_exec(
                *cmd,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE,
                cwd=str(self._src_dir),
                env=self._subprocess_env(),
            )
        except FileNotFoundError as exc:
            raise RuntimeError(
                f"Could not launch Python interpreter '{self._python}': {exc}"
            ) from exc

        assert proc.stdout is not None
        assert proc.stderr is not None

        # Drain stderr in the background so the pipe never blocks. Keep a small
        # copy so non-zero exits are diagnosable at INFO/WARNING log levels.
        stderr_lines: list[str] = []
        stderr_task = asyncio.create_task(
            self._drain_stderr(proc, stderr_lines),
            name="bitnet-stderr",
        )

        # Stream stdout to the caller
        try:
            async for line in proc.stdout:
                text = line.decode("utf-8", errors="replace")
                if text:
                    yield text
        except asyncio.CancelledError:
            proc.kill()
            raise

        await proc.wait()
        await stderr_task

        if proc.returncode not in (0, None):
            tail = "\n".join(stderr_lines[-20:])
            if tail:
                log.warning(
                    "run_inference.py exited with code %d. stderr tail:\n%s",
                    proc.returncode,
                    tail,
                )
            else:
                log.warning("run_inference.py exited with code %d.", proc.returncode)

    # ------------------------------------------------------------------
    # Internal
    # ------------------------------------------------------------------

    @staticmethod
    async def _drain_stderr(
        proc: asyncio.subprocess.Process,
        stderr_lines: list[str] | None = None,
    ) -> None:
        """Log stderr from the inference subprocess."""
        if proc.stderr is None:
            return
        try:
            async for line in proc.stderr:
                decoded = line.decode("utf-8", errors="replace").rstrip()
                if decoded:
                    if stderr_lines is not None:
                        stderr_lines.append(decoded)
                    log.debug("bitnet stderr: %s", decoded)
        except Exception:
            pass
