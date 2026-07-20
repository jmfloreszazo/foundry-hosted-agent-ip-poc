"""
guardrails.py -- closes the "second door": IP extraction through the endpoint.

NONE of this depends on the network. A client with Fiddler sees its own
request/response; these rules make sure that in that request/response there is
nothing of your IP to extract.

Honest note: heuristic detection is NOT infallible. The real backstop is the
Azure AI Content Safety content filters / Prompt Shields configured on top of
the model deployment (see infra/modules/foundry.bicep). This is the
application-layer complement to them.

1:1 port of src/AgentCSharp/Guardrails.cs -- same regexes, same semantics.
Both agents MUST behave identically for the benchmark to be apples-to-apples.
"""

from __future__ import annotations

import re
from typing import Final

# Typical patterns of an attempt to exfiltrate the system instructions.
# Kept in sync with Guardrails.cs::ExtractionPatterns.
_EXTRACTION_PATTERNS: Final[tuple[re.Pattern[str], ...]] = (
    re.compile(
        r"(ignore|forget|disregard).{0,20}(previous|above|prior).{0,20}(instruction|prompt|rule)",
        re.IGNORECASE,
    ),
    re.compile(
        r"(repeat|print|show|reveal|output).{0,20}(system\s*prompt|your\s*instructions|initial\s*prompt)",
        re.IGNORECASE,
    ),
    re.compile(
        r"(what\s+are|show\s+me).{0,20}(your\s+rules|your\s+guidelines|the\s+prompt)",
        re.IGNORECASE,
    ),
    re.compile(
        r"(tell\s+me|show|repeat|print).{0,25}(your\s+prompt|your\s+instructions|your\s+rules|the\s+system\s+prompt)",
        re.IGNORECASE,
    ),
)

_LEAK_MARKERS: Final[re.Pattern[str]] = re.compile(
    r"(system\s*prompt|my\s+instructions\s+are|my\s+rules\s+are)",
    re.IGNORECASE,
)


def is_extraction_attempt(user_input: str) -> bool:
    """INPUT guardrail: rejects obvious extraction attempts."""
    return any(p.search(user_input) for p in _EXTRACTION_PATTERNS)


def scrub_output(model_text: str, system_prompt: str) -> str | None:
    """
    OUTPUT guardrail. Returns None if IP leakage is detected (the handler will
    apply the uniform opaque refusal), or the safe text if it is clean. Last
    line before the wire.
    """
    lowered = model_text.lower()

    # 1) If a significant fragment of the system prompt shows up, cut it off.
    for line in system_prompt.split("\n"):
        chunk = line.strip()
        if len(chunk) >= 25 and chunk.lower() in lowered:
            return None

    # 2) Typical markers of rule leakage.
    if _LEAK_MARKERS.search(model_text):
        return None

    return model_text
