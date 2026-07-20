"""
protected_response_handler.py -- protected IP with OPAQUE response.

  - Prompt/rules in Key Vault (out of the repo and out of the binary),
    loaded once at startup by ``load_prompt_store`` (module-level singleton).
  - Input/output guardrails against extraction.
  - Opaque response: uniform refusal, normalized latency (no timing oracle),
    same contract for refusal and answer (no status oracle), generic error
    (no error oracle). Differential info = 0.

Phase B: real inference against the ``gpt-5-mini`` deployment on the Foundry
account, using the official ``openai`` async client authenticated with the
agent's managed identity (``DefaultAzureCredential``). The model call is
wrapped by the same guardrail/opacity envelope Phase A used, so the wire
contract is byte-for-byte indistinguishable between refusal and answer.

1:1 port of src/Agent/ProtectedResponseHandler.cs. Wire-parity with the
C# host is intentional -- the benchmark compares the two implementations
end-to-end.
"""

from __future__ import annotations

import logging
import os
import time
from dataclasses import dataclass
from typing import Final

from azure.identity.aio import DefaultAzureCredential, get_bearer_token_provider
from openai import AsyncAzureOpenAI

from . import guardrails, opacity
from .key_vault_prompt_store import PromptStore

_log = logging.getLogger(__name__)


# -----------------------------------------------------------------------------
# Model client (module-level singleton, mirrors the C# DI singleton).
# -----------------------------------------------------------------------------

# ``AZURE_OPENAI_ENDPOINT`` and ``MODEL_DEPLOYMENT_NAME`` are injected by the
# Foundry runtime through azure.yaml's ``environmentVariables`` block. Note the
# ``FOUNDRY_*`` and ``AGENT_*`` namespaces are reserved by the platform, hence
# the neutral ``MODEL_DEPLOYMENT_NAME`` name.
#
# Auth: the Foundry hosted-agent runtime injects an ``agentIdentityBlueprint``
# principal into the container. That principal type CANNOT receive classic
# Azure RBAC role assignments (rejected by ARM with PrincipalTypeNotSupported),
# so ``DefaultAzureCredential`` against the account also fails with 401.
# The production-correct pattern is Foundry AgentID / fmi_path token exchange
# (see docs skill entra-agent-id). For this PoC we take the pragmatic path:
# authenticate against Azure OpenAI with an API key sourced from the Foundry
# account (env var, injected by azd from ``AZURE_OPENAI_API_KEY``). If the key
# is absent we fall back to ``DefaultAzureCredential`` so a future rewire
# to Foundry AgentID keeps working with the same handler code.
_AZURE_OPENAI_ENDPOINT: Final[str] = os.environ["AZURE_OPENAI_ENDPOINT"]
_MODEL_DEPLOYMENT: Final[str] = os.environ["MODEL_DEPLOYMENT_NAME"]
_API_VERSION: Final[str] = os.environ.get("AZURE_OPENAI_API_VERSION", "2024-12-01-preview")
_AZURE_OPENAI_API_KEY: Final[str | None] = os.environ.get("AZURE_OPENAI_API_KEY")

if _AZURE_OPENAI_API_KEY:
    _openai_client: Final[AsyncAzureOpenAI] = AsyncAzureOpenAI(
        azure_endpoint=_AZURE_OPENAI_ENDPOINT,
        api_key=_AZURE_OPENAI_API_KEY,
        api_version=_API_VERSION,
    )
    _log.info("Azure OpenAI client initialized with API key auth (Phase B PoC).")
else:
    # Reserved for the eventual Foundry AgentID rewire.
    _credential = DefaultAzureCredential()
    _token_provider = get_bearer_token_provider(
        _credential, "https://cognitiveservices.azure.com/.default"
    )
    _openai_client = AsyncAzureOpenAI(
        azure_endpoint=_AZURE_OPENAI_ENDPOINT,
        azure_ad_token_provider=_token_provider,
        api_version=_API_VERSION,
    )
    _log.info("Azure OpenAI client initialized with DefaultAzureCredential.")

# Bound the model call so ``gpt-5-mini`` (a reasoning model) cannot burn
# unbounded reasoning tokens on a small prompt. ``minimal`` keeps latency
# predictable and matches the C# ``ChatReasoningEffortLevel("minimal")``.
# We deliberately do NOT pass ``max_completion_tokens`` here: the C# handler
# cannot pass it (SDK bug, see the C# comment) so for wire parity we drop
# it in Python too and let the model default the cap.
_REASONING_EFFORT: Final[str] = "minimal"
_PHASE_A_BENCHMARK_MODE: Final[str] = "phase-a"


@dataclass(slots=True)
class HandlerResult:
    """Text payload produced by the handler plus token usage.

    In Phase B the counts come from the model's ``usage`` block when a real
    call happened, and from a coarse local estimate on the refusal path
    (``max(1, len(text) // 4)``, the canonical OpenAI heuristic). Both
    agents use the same source-of-truth so the benchmark ``usage`` numbers
    remain directly comparable.
    """

    text: str
    input_tokens: int
    output_tokens: int

    @property
    def total_tokens(self) -> int:
        return self.input_tokens + self.output_tokens


def _estimate_tokens(text: str) -> int:
    # Same heuristic in AgentCSharp/ProtectedResponseHandler.cs so the two
    # agents report comparable numbers on the refusal path.
    return max(1, len(text) // 4)


def _use_phase_a_canned_response() -> bool:
    return os.environ.get("BENCHMARK_MODE", "").lower() == _PHASE_A_BENCHMARK_MODE


def _create_phase_a_canned_response(user_input: str, prompt_store: PromptStore) -> HandlerResult:
    input_tokens = _estimate_tokens(user_input)
    text = (
        "Protected response OK. "
        f"prompt_sha256={prompt_store.system_prompt_sha256[:12]}; "
        f"input_tokens_est={input_tokens}; "
        "model_call=false"
    )
    return HandlerResult(
        text=text,
        input_tokens=input_tokens,
        output_tokens=_estimate_tokens(text),
    )


async def _call_model(user_input: str, system_prompt: str) -> tuple[str, int, int]:
    """
    Real inference against ``gpt-5-mini``. Returns ``(text, prompt_tokens,
    completion_tokens)``. Exceptions bubble up so ``handle_text`` can route
    them through the generic-error path (no error oracle to the client).
    """
    completion = await _openai_client.chat.completions.create(
        model=_MODEL_DEPLOYMENT,
        messages=[
            {"role": "system", "content": system_prompt},
            {"role": "user", "content": user_input},
        ],
        reasoning_effort=_REASONING_EFFORT,
    )
    choice = completion.choices[0]
    text = (choice.message.content or "").strip()
    usage = completion.usage
    prompt_tokens = usage.prompt_tokens if usage else _estimate_tokens(user_input + system_prompt)
    completion_tokens = usage.completion_tokens if usage else _estimate_tokens(text)
    return text, prompt_tokens, completion_tokens


async def handle_text(user_input: str, prompt_store: PromptStore) -> HandlerResult:
    """
    Same control-flow as ProtectedResponseHandler.CreateAsync on the C# side:

    1. Input guardrail -> opaque refusal on match.
    2. Call ``gpt-5-mini`` with the KV-loaded system prompt.
    3. Output guardrail; if it trips, opaque refusal.
    4. On any model exception, opaque generic-error (no leak of stack/model).
    5. Normalize latency so all branches are indistinguishable from the wire.

    ``user_input`` is supplied by ``ResponseContext.get_input_text()`` from
    the ``azure-ai-agentserver-responses`` SDK -- no history round-trip.
    Mirrors ``CreateResponseExtensions.GetInputText`` on the C# side.
    """
    started_at = time.monotonic()

    if user_input is None:
        user_input = ""

    # --- INPUT guardrail: extraction attempt -> OPAQUE refusal ---
    # Do not fast-fail: latency is normalized so there is no timing oracle,
    # and the wire contract is identical to a real response.
    if guardrails.is_extraction_attempt(user_input):
        await opacity.normalize_latency(started_at)
        text = opacity.refusal()
        return HandlerResult(
            text=text,
            input_tokens=_estimate_tokens(user_input),
            output_tokens=_estimate_tokens(text),
        )

    # --- Phase A benchmark mode: no model call, deterministic body ---
    if _use_phase_a_canned_response():
        await opacity.normalize_latency(started_at)
        return _create_phase_a_canned_response(user_input, prompt_store)

    # --- Real model call ---
    try:
        body_text, in_tokens, out_tokens = await _call_model(
            user_input, prompt_store.system_prompt
        )
    except Exception:  # noqa: BLE001 -- opaque error path, log detail, leak nothing
        _log.exception("Model call failed; returning generic error.")
        await opacity.normalize_latency(started_at)
        return HandlerResult(
            text=opacity.GENERIC_ERROR,
            input_tokens=_estimate_tokens(user_input),
            output_tokens=_estimate_tokens(opacity.GENERIC_ERROR),
        )

    # --- OUTPUT guardrail: prompt scrubbed against KV system prompt ---
    scrubbed = guardrails.scrub_output(body_text, prompt_store.system_prompt)
    if scrubbed is None:
        _log.error("Output guardrail tripped on model response; returning opaque refusal.")
        await opacity.normalize_latency(started_at)
        text = opacity.refusal()
        return HandlerResult(
            text=text,
            input_tokens=in_tokens,
            output_tokens=_estimate_tokens(text),
        )

    await opacity.normalize_latency(started_at)
    return HandlerResult(
        text=scrubbed,
        input_tokens=in_tokens,
        output_tokens=out_tokens,
    )
