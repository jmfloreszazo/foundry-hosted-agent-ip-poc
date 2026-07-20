"""
main.py -- Hosted Agent bootstrap for the Python variant.

Uses the official Microsoft server SDK ``azure-ai-agentserver-responses``
(https://pypi.org/project/azure-ai-agentserver-responses/), which is the
1:1 Python counterpart of the .NET ``Azure.AI.AgentServer.Responses`` SDK
used by ``src/Agent/Program.cs``. The SDK provisions:

  * ``POST /responses`` (OpenAI Responses wire protocol, streaming + non-streaming)
  * ``GET  /readiness`` liveness probe
  * SSE lifecycle wrapping around ``TextResponse``
  * OpenTelemetry tracing

So we no longer hand-roll the wire protocol -- the SDK owns everything from
the socket up to the handler. The proprietary logic (KV prompt loader,
input/output guardrails, opacity/normalized-latency, real ``gpt-5-mini``
inference call) lives in the sibling modules and is byte-for-byte
functionally equivalent to the C# handler.
"""

from __future__ import annotations

import asyncio
import logging

from azure.ai.agentserver.responses import (
    CreateResponse,
    ResponseContext,
    ResponsesAgentServerHost,
    TextResponse,
)

from .key_vault_prompt_store import load_prompt_store
from .protected_response_handler import handle_text

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s: %(message)s")
_log = logging.getLogger("agentpython")

# KV round-trip happens exactly once per process, at import time (before
# ``app.run()``). Same amortization guarantee as the C# DI singleton
# ``KeyVaultPromptStore``.
_log.info("Loading system prompt from Key Vault...")
_prompt = load_prompt_store()
_log.info(
    "Prompt loaded (sha256[:12]=%s, %d chars).",
    _prompt.system_prompt_sha256[:12],
    len(_prompt.system_prompt),
)

# Use SDK defaults. This agent is stateless on the wire (clients send
# ``store: false``) and ``handle_text`` does not consume history (Phase B is
# single-turn: one system + one user), so any history fetched by the platform
# is simply ignored.
app = ResponsesAgentServerHost()


@app.response_handler
async def handler(
    request: CreateResponse,
    context: ResponseContext,
    _cancellation_signal: asyncio.Event,
) -> TextResponse:
    """Same control-flow as ``ProtectedResponseHandler.CreateAsync`` on the C# side:

    1. Read input text from the request context (no history round-trip).
    2. Delegate to ``handle_text``: input guardrail, real ``gpt-5-mini`` call,
       output guardrail, normalized latency.
    3. Wrap the resulting text in ``TextResponse``; the SDK handles the SSE
       envelope, id generation, and ``response.*`` event sequence.
    """
    user_input = await context.get_input_text() or ""
    result = await handle_text(user_input, _prompt)
    return TextResponse(context, request, text=result.text)


if __name__ == "__main__":
    # ``python -m agentpython.main`` in the Dockerfile. ``app.run()`` blocks
    # and binds to the port the Foundry runtime injects (defaults to 8088).
    app.run()
