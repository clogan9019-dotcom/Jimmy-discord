"""High-level async wrapper around BitNet inference.

Provides a clean BitNetModel API used by the Discord bot commands.
"""

from __future__ import annotations

import logging
import sys
import time
from pathlib import Path
from typing import AsyncIterator

from bitnet.process import BitNetProcess

log = logging.getLogger(__name__)


class BitNetModel:
    """Async wrapper around bitnet.cpp's run_inference.py.

    Example
    -------
    model = BitNetModel(
        src_dir="./bitnet_cpp_src",
        model_path="./models/heretic/ggml-model-i2_s.gguf",
        threads=4,
        context_length=4096,
    )
    await model.load()          # validates files exist

    async for token in model.generate(prompt="Hello!"):
        print(token, end="", flush=True)
    """

    def __init__(
        self,
        src_dir: str | Path,
        model_path: str | Path,
        threads: int = 4,
        context_length: int = 4096,
        executable_path: str | Path | None = None,
    ) -> None:
        self._src_dir = Path(src_dir)
        self._model_path = Path(model_path)
        self._threads = threads
        self._context_length = context_length

        self._process = BitNetProcess(
            src_dir=src_dir,
            model_path=model_path,
            threads=threads,
            context_length=context_length,
            python_executable=sys.executable,
            executable_path=executable_path,
        )

        self._loaded = False
        self._total_inferences: int = 0
        self._total_tokens: int = 0
        self._total_inference_time: float = 0.0

    # ------------------------------------------------------------------
    # Lifecycle
    # ------------------------------------------------------------------

    async def load(self) -> None:
        """Validate that all required files are present.

        Does not start a persistent process — each inference call spawns
        run_inference.py on demand, which keeps things simple and crash-safe.
        """
        if self._loaded:
            return
        log.info(
            "Validating BitNet model (src=%s, model=%s, threads=%d, ctx=%d).",
            self._src_dir,
            self._model_path,
            self._threads,
            self._context_length,
        )
        self._process.validate()
        self._loaded = True
        log.info("BitNet model validated and ready.")

    async def unload(self) -> None:
        """No persistent process to stop — nothing to do."""
        self._loaded = False
        log.info("BitNetModel unloaded.")

    @property
    def is_loaded(self) -> bool:
        return self._loaded

    # ------------------------------------------------------------------
    # Inference
    # ------------------------------------------------------------------

    async def generate(
        self,
        prompt: str,
        temperature: float = 0.8,
        top_p: float = 0.95,
        top_k: int = 40,
        repeat_penalty: float = 1.1,
        max_tokens: int = 512,
    ) -> AsyncIterator[str]:
        """Generate a response for *prompt*, yielding text chunks as they arrive.

        Parameters
        ----------
        prompt:
            Full formatted prompt string (including conversation history).
        temperature:
            Sampling temperature.
        top_p:
            Nucleus sampling threshold.
        top_k:
            Top-K candidates per step.
        repeat_penalty:
            Repetition penalty factor.
        max_tokens:
            Maximum tokens to generate.

        Yields
        ------
        str
            Text chunks streamed from run_inference.py stdout.
        """
        if not self._loaded:
            raise RuntimeError("Model not loaded. Call BitNetModel.load() first.")

        start = time.monotonic()
        token_count = 0

        log.debug(
            "Inference start | temp=%.2f top_p=%.2f top_k=%d max_tokens=%d",
            temperature, top_p, top_k, max_tokens,
        )

        async for chunk in self._process.generate(
            prompt=prompt,
            temperature=temperature,
            top_p=top_p,
            top_k=top_k,
            repeat_penalty=repeat_penalty,
            max_tokens=max_tokens,
        ):
            token_count += len(chunk.split())
            yield chunk

        elapsed = time.monotonic() - start
        tps = token_count / elapsed if elapsed > 0 else 0.0

        self._total_inferences += 1
        self._total_tokens += token_count
        self._total_inference_time += elapsed

        log.info(
            "Inference done | tokens≈%d | %.2fs | %.1f tok/s",
            token_count, elapsed, tps,
        )

    # ------------------------------------------------------------------
    # Stats
    # ------------------------------------------------------------------

    @property
    def stats(self) -> dict[str, object]:
        avg_tps = (
            self._total_tokens / self._total_inference_time
            if self._total_inference_time > 0 else 0.0
        )
        return {
            "loaded": self.is_loaded,
            "src_dir": str(self._src_dir),
            "model_path": str(self._model_path),
            "threads": self._threads,
            "context_length": self._context_length,
            "total_inferences": self._total_inferences,
            "total_tokens_generated": self._total_tokens,
            "avg_tokens_per_second": round(avg_tps, 2),
            "total_inference_time_seconds": round(self._total_inference_time, 2),
        }
