"""
opacity.py -- opaque-response discipline.

The goal is zero differential information: from HOW the agent responds,
nothing can be inferred (not content, not timing, not status, not error).
Closes the oracles that a naive guardrail leaves open.

1:1 port of src/AgentCSharp/Opacity.cs.
"""

from __future__ import annotations

import asyncio
import secrets
import time
from typing import Final

# Pool of semantically identical refusals (info = 0) with varied wording,
# so we don't hand out a clean "you were detected" fingerprint.
_REFUSALS: Final[tuple[str, ...]] = (
    "I can't help with that. What do you need to solve?",
    "That's outside what I can do. Tell me how I can help.",
    "I can't take that request. What else can I help you with?",
    "That isn't something I can handle. How can I help?",
)

# Single generic error message: does not leak stack, fields, or model.
GENERIC_ERROR: Final[str] = "I couldn't process the request. Please try again."


def refusal() -> str:
    """A refusal does NOT reveal why, does not quote the attempt, does not confirm rules."""
    return _REFUSALS[secrets.randbelow(len(_REFUSALS))]


async def normalize_latency(
    started_at: float,
    target_min_ms: int = 900,
    jitter_ms: int = 600,
) -> None:
    """
    Normalizes the latency of the refusal path so it looks like a real
    response and no timing oracle exists. Calibrated to the model's p50.

    Parameters
    ----------
    started_at : float
        Monotonic clock timestamp (from ``time.monotonic()``) captured at
        request start.
    target_min_ms : int
        Minimum wall-clock latency in milliseconds.
    jitter_ms : int
        Random uniform jitter (0..jitter_ms) added to the minimum.
    """
    elapsed_ms = (time.monotonic() - started_at) * 1000.0
    target_ms = target_min_ms + secrets.randbelow(jitter_ms)
    remaining_ms = target_ms - elapsed_ms
    if remaining_ms > 0:
        await asyncio.sleep(remaining_ms / 1000.0)
