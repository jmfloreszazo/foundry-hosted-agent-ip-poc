"""
key_vault_prompt_store.py -- loads the protected system prompt from Azure Key
Vault at startup and keeps it in memory for the lifetime of the process.
Exposes only the prompt text and its SHA-256 fingerprint -- never persists to
disk or logs.

1:1 port of src/AgentCSharp/KeyVaultPromptStore.cs.
"""

from __future__ import annotations

import hashlib
import os
from dataclasses import dataclass

from azure.identity import DefaultAzureCredential
from azure.keyvault.secrets import SecretClient


@dataclass(frozen=True, slots=True)
class PromptStore:
    """Immutable holder for the KV-sourced prompt and its fingerprint."""

    system_prompt: str
    system_prompt_sha256: str


def load_prompt_store() -> PromptStore:
    """
    Env-var override: if ``SYSTEM_PROMPT_INLINE`` is set, use it verbatim and
    skip the Key Vault round-trip. Used when the hosted agent's per-instance
    managed identity cannot obtain Key Vault Secrets User (Entra Agent
    Identity SPs are currently rejected by the ARM RBAC service).

    Otherwise: reads ``$KEY_VAULT_URI`` and ``$SYSTEM_PROMPT_SECRET`` (default
    ``agent-system-prompt``), authenticates with ``DefaultAzureCredential``
    (the Foundry project managed identity when running as a hosted agent),
    fetches the secret, and computes its SHA-256 fingerprint.

    Raises ``RuntimeError`` if neither source is configured so the container
    fails fast at startup instead of at first request.
    """
    inline = os.environ.get("SYSTEM_PROMPT_INLINE")
    if inline and inline.strip():
        system_prompt = inline
    else:
        vault_uri = os.environ.get("KEY_VAULT_URI")
        if not vault_uri:
            raise RuntimeError("KEY_VAULT_URI is not configured and SYSTEM_PROMPT_INLINE is empty.")

        secret_name = os.environ.get("SYSTEM_PROMPT_SECRET", "agent-system-prompt")

        client = SecretClient(vault_url=vault_uri, credential=DefaultAzureCredential())
        secret = client.get_secret(secret_name)
        system_prompt = secret.value or ""

    fingerprint = hashlib.sha256(system_prompt.encode("utf-8")).hexdigest()
    return PromptStore(system_prompt=system_prompt, system_prompt_sha256=fingerprint)
