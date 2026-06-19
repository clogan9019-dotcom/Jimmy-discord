"""Async subprocess runner for local GGUF inference via llama-cli.

Each generate() call spawns a fresh llama-cli process, captures its
stdout, and streams the text back as chunks.  The InferenceQueue in utils/queue.py
guarantees only one process runs at a time, so there is no resource contention.
"""

from __future__ import annotations

import asyncio
import logging
import os
import platform
import shutil
import subprocess
import sys
from pathlib import Path
from typing import AsyncIterator

log = logging.getLogger(__name__)


class BitNetProcess:
    """Runs local GGUF inference by calling llama-cli as a subprocess.

    Parameters
    ----------
    src_dir:
        Path to the cloned bitnet_cpp_src directory that contains
        build/bin/llama-cli.
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
        executable_path: str | Path | None = None,
        gpu_layers: str | int = "auto",
    ) -> None:
        self._src_dir = Path(src_dir).resolve()
        self._model_path = Path(model_path).resolve()
        self._threads = threads
        self._context_length = context_length
        self._python = python_executable or sys.executable
        self._inference_script = self._src_dir / "run_inference.py"
        if executable_path:
            self._cli_path = Path(executable_path).resolve()
            self._custom_executable = True
        else:
            self._cli_path = self._src_dir / "build" / "bin" / (
                "llama-cli.exe" if os.name == "nt" else "llama-cli"
            )
            self._custom_executable = False
        self._gpu_layers_setting = str(os.environ.get("JIMMY_GPU_LAYERS", gpu_layers)).strip()
        self._gpu_detected = self._detect_gpu()
        self._gpu_layers = self._resolve_gpu_layers(self._gpu_layers_setting)

    @property
    def gpu_layers(self) -> int:
        return self._gpu_layers

    @property
    def gpu_detected(self) -> bool:
        return self._gpu_detected

    @staticmethod
    def _run_probe(command: list[str], timeout: float = 2.0) -> str:
        try:
            result = subprocess.run(
                command,
                capture_output=True,
                text=True,
                timeout=timeout,
                check=False,
            )
        except Exception:
            return ""
        return (result.stdout or "") + "\n" + (result.stderr or "")

    def _detect_gpu(self) -> bool:
        """Best-effort GPU detection for deciding llama.cpp -ngl.

        Raspberry Pi 4 exposes a VideoCore DRM device, but this build path does
        not use it for llama.cpp acceleration, so ARM Linux defaults to CPU.
        """
        forced = os.environ.get("JIMMY_FORCE_GPU", "").strip().lower()
        if forced in {"1", "true", "yes", "on"}:
            return True

        system = platform.system().lower()
        machine = platform.machine().lower()

        if system == "windows":
            ps = shutil.which("powershell") or shutil.which("pwsh")
            if not ps:
                return False
            output = self._run_probe([
                ps,
                "-NoProfile",
                "-Command",
                "(Get-CimInstance Win32_VideoController | Select-Object -ExpandProperty Name) -join ';'",
            ])
            names = [n.strip().lower() for n in output.replace("\r", "").split(";") if n.strip()]
            bad = ("microsoft basic", "remote display", "parsec", "virtual", "mirror")
            good = ("nvidia", "geforce", "rtx", "gtx", "quadro", "amd", "radeon", "intel", "arc")
            return any(any(g in n for g in good) and not any(b in n for b in bad) for n in names)

        if system == "darwin":
            return True  # Metal-capable Macs, if a Metal llama.cpp binary is used.

        if system == "linux":
            if shutil.which("nvidia-smi") and self._run_probe(["nvidia-smi", "-L"]):
                return True
            # Avoid enabling GPU on Raspberry Pi / ARM SBC DRM devices.
            if machine in {"aarch64", "arm64"} or machine.startswith("arm"):
                return False
            if Path("/dev/dri").exists() and list(Path("/dev/dri").glob("renderD*")):
                return True

        return False

    def _resolve_gpu_layers(self, value: str) -> int:
        normalized = (value or "auto").strip().lower()
        if normalized in {"", "auto", "detect"}:
            return 999 if self._gpu_detected else 0
        if normalized in {"all", "max", "gpu"}:
            return 999
        if normalized in {"off", "false", "no", "cpu", "none"}:
            return 0
        try:
            return max(0, int(normalized))
        except ValueError:
            log.warning("Invalid gpu_layers=%r; using auto detection.", value)
            return 999 if self._gpu_detected else 0

    def _subprocess_env(self) -> dict[str, str]:
        """Environment for BitNet subprocesses.

        The BitNet/llama.cpp build produces shared libraries such as
        libllama.so under build subdirectories. When run_inference.py launches
        build/bin/llama-cli, the dynamic linker may not find those libraries
        unless LD_LIBRARY_PATH includes the directories containing .so files.
        """
        env = {**os.environ, "TOKENIZERS_PARALLELISM": "false"}
        if os.name == "nt":
            # Windows needs DLLs from the llama.cpp binary directory on PATH.
            cli_dir = str(self._cli_path.parent)
            existing_path = env.get("PATH", "")
            env["PATH"] = cli_dir + (os.pathsep + existing_path if existing_path else "")
        else:
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

    @staticmethod
    def _clean_output_chunk(text: str) -> str:
        """Remove common special-token strings from llama-cli output."""
        for marker in (
            "[end of text]",
            "<|endoftext|>",
            "<|im_end|>",
            "<|im_start|>",
        ):
            text = text.replace(marker, "")

        # Drop llama.cpp status/log lines if a build prints them on stdout. They
        # are useful in terminals but look like the bot is saying "Loading model".
        log_prefixes = (
            "loading model",
            "main:",
            "llama_",
            "ggml_",
            "system_info:",
            "sampling:",
            "generate:",
            "print_info:",
            "load_tensors:",
        )
        kept_lines = []
        for line in text.splitlines(keepends=True):
            stripped = line.strip().lower()
            if stripped and any(stripped.startswith(prefix) for prefix in log_prefixes):
                continue
            kept_lines.append(line)
        text = "".join(kept_lines)

        # If a simple transcript model starts roleplaying the next turn, cut it.
        # Streaming is line-based, so sometimes "User:" arrives without the
        # leading newline; drop those chunks too.
        for prefix in ("User:", "Current user:"):
            if text.lstrip().startswith(prefix):
                return ""
        for marker in ("\nUser:", "\n\nUser:", "\nCurrent user:", "\n\nCurrent user:"):
            if marker in text:
                text = text.split(marker, 1)[0]
        # Some small models prefix every line with Assistant:. Keep the first
        # answer text clean without damaging normal uses of the word.
        if text.lstrip().startswith("Assistant:"):
            leading = len(text) - len(text.lstrip())
            text = text[:leading] + text.lstrip()[len("Assistant:"):].lstrip()
        return text

    # ------------------------------------------------------------------
    # Validation
    # ------------------------------------------------------------------

    def validate(self) -> None:
        """Raise RuntimeError if the required files are missing."""
        if not self._custom_executable and not self._src_dir.is_dir():
            raise RuntimeError(
                f"BitNet src_dir not found: '{self._src_dir}'. "
                "Run install.sh to clone and build bitnet.cpp."
            )
        if not self._cli_path.is_file():
            raise RuntimeError(
                f"llama-cli not found at '{self._cli_path}'. "
                "Run install.sh or install_tinydolphin.sh to build llama.cpp first."
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

        Spawns llama-cli, streams its stdout line by line, and
        yields each non-empty line as a chunk.
        """
        cmd = [
            str(self._cli_path),
            "-m", str(self._model_path),
            "-n", str(max_tokens),
            "-t", str(self._threads),
            "-p", prompt,
            "-ngl", str(self._gpu_layers),
            "-c", str(self._context_length),
            "--temp", str(temperature),
            "--top-p", str(top_p),
            "--top-k", str(top_k),
            "--repeat-penalty", str(repeat_penalty),
            # TinyDolphin often emits a special/end token immediately, so ignore
            # EOS. Stop when it tries to start a new fake user turn. `-e` makes
            # the reverse prompts treat \n as a real newline.
            "--ignore-eos",
            "-e",
            "-r", "\nUser:",
            "-r", "\n\nUser:",
            "-r", "\nCurrent user:",
            "-r", "\n\nCurrent user:",
            "-b", "1",
            "--no-display-prompt",
            "--log-disable",
        ]

        log.debug(
            "Spawning inference: %s … | gpu_detected=%s gpu_layers=%d",
            " ".join(cmd[:8]),
            self._gpu_detected,
            self._gpu_layers,
        )

        try:
            proc = await asyncio.create_subprocess_exec(
                *cmd,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE,
                cwd=str(self._src_dir if self._src_dir.is_dir() else self._cli_path.parent),
                env=self._subprocess_env(),
            )
        except FileNotFoundError as exc:
            raise RuntimeError(
                f"Could not launch llama-cli '{self._cli_path}': {exc}"
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
                text = self._clean_output_chunk(line.decode("utf-8", errors="replace"))
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
                    "llama-cli exited with code %d. stderr tail:\n%s",
                    proc.returncode,
                    tail,
                )
            else:
                log.warning("llama-cli exited with code %d.", proc.returncode)

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
