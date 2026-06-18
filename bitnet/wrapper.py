"""High-level Python wrapper around bitnet.cpp for the Discord bot.

Provides a clean async API for loading the model and generating text.
"""

from __future__ import annotations

import logging
import time
from typing import AsyncIterator

from bitnet.process import BitNetProcess

log = logging.getLogger(__name__)


class BitNetModel:
    """Async wrapper around the bitnet.cpp subprocess.

    Example
    -------
    model = BitNetModel(
        executable="./bitnet",
        model_path="./models/heretic",
        threads=4,
        context_length=4096,
    )
    await model.load()

    async for token in model.generate(prompt="Hello!", ...):
        print(token, end="", flush=True)

    await model.unload()
    """

    def __init__(
        self,
        executable: str,
        model_path: str,
        threads: int = 4,
        context_length: int = 4096,
    ) -> None:
        self._executable = executable
        self._model_path = model_path
        self._threads = threads
        self._context_length = context_length
        self._process = BitNetProcess(
            executable=executable,
            model_path=model_path,
            threads=threads,
            context_length=context_length,
        )
        self._loaded = False
        self._total_inferences: int = 0
        self._total_tokens: int = 0
        self._total_inference_time: float = 0.0

    # ------------------------------------------------------------------
    # Lifecycle
    # ------------------------------------------------------------------

    async def load(self) -> None:
        """Launch the underlying bitnet.cpp process and warm up the model."""
        if self._loaded:
            log.warning("BitNetModel.load() called but model is already loaded.")
            return
        log.info(
            "Loading BitNet model from '%s' (threads=%d, context=%d).",
            self._model_path,
            self._threads,
            self._context_length,
        )
        await self._process.start()
        self._loaded = True
        log.info("BitNet model loaded successfully.")

    async def unload(self) -> None:
        """Shut down the underlying subprocess."""
        if not self._loaded:
            return
        await self._process.stop()
        self._loaded = False
        log.info("BitNet model unloaded.")

    @property
    def is_loaded(self) -> bool:
        return self._loaded and self._process.is_alive

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
        """Generate a response for *prompt*, yielding tokens as they arrive.

        Parameters
        ----------
        prompt:
            The full formatted prompt string (including conversation history).
        temperature:
            Sampling temperature (higher = more creative).
        top_p:
            Nucleus sampling probability threshold.
        top_k:
            Keep only the *top_k* most likely next tokens.
        repeat_penalty:
            Penalty applied to recently generated tokens.
        max_tokens:
            Maximum number of tokens to generate.

        Yields
        ------
        str
            Individual text tokens / chunks as they stream from the model.
        """
        if not self._loaded:
            raise RuntimeError(
                "Model is not loaded. Call BitNetModel.load() first."
            )

        start = time.monotonic()
        token_count = 0

        log.debug(
            "Starting inference | temp=%.2f top_p=%.2f top_k=%d max_tokens=%d",
            temperature,
            top_p,
            top_k,
            max_tokens,
        )

        async for token in self._process.generate(
            prompt=prompt,
            temperature=temperature,
            top_p=top_p,
            top_k=top_k,
            repeat_penalty=repeat_penalty,
            max_tokens=max_tokens,
        ):
            token_count += len(token.split())
            yield token

        elapsed = time.monotonic() - start
        tokens_per_second = token_count / elapsed if elapsed > 0 else 0.0

        self._total_inferences += 1
        self._total_tokens += token_count
        self._total_inference_time += elapsed

        log.info(
            "Inference complete | tokens≈%d | %.2fs | %.1f tok/s",
            token_count,
            elapsed,
            tokens_per_second,
        )

    # ------------------------------------------------------------------
    # Stats
    # ------------------------------------------------------------------

    @property
    def stats(self) -> dict[str, object]:
        """Return cumulative inference statistics."""
        avg_tps = (
            self._total_tokens / self._total_inference_time
            if self._total_inference_time > 0
            else 0.0
        )
        return {
            "loaded": self.is_loaded,
            "executable": self._executable,
            "model_path": self._model_path,
            "threads": self._threads,
            "context_length": self._context_length,
            "total_inferences": self._total_inferences,
            "total_tokens_generated": self._total_tokens,
            "avg_tokens_per_second": round(avg_tps, 2),
            "total_inference_time_seconds": round(self._total_inference_time, 2),
        }
