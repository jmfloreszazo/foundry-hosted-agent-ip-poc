using System.Security.Cryptography;
using System.Text;
using Azure.Identity;
using Azure.Security.KeyVault.Secrets;

/// <summary>
/// Loads the agent's protected system prompt from Azure Key Vault at startup
/// and keeps it in memory for the lifetime of the process. Exposes only the
/// prompt text and its SHA-256 fingerprint — never persists to disk or logs.
/// </summary>
public sealed class KeyVaultPromptStore
{
    public string SystemPrompt { get; }
    public string SystemPromptSha256 { get; }

    public KeyVaultPromptStore()
    {
        // Env-var override for scenarios where Key Vault is unreachable from
        // the hosted agent's per-instance managed identity (e.g. Entra Agent
        // Identity SPs that ARM RBAC currently rejects). When SYSTEM_PROMPT_INLINE
        // is set, skip the KV round-trip entirely. The rest of the pipeline
        // (guardrails, opacity, fingerprint) is unchanged.
        var inline = Environment.GetEnvironmentVariable("SYSTEM_PROMPT_INLINE");
        if (!string.IsNullOrWhiteSpace(inline))
        {
            SystemPrompt = inline;
        }
        else
        {
            var vaultUri = Environment.GetEnvironmentVariable("KEY_VAULT_URI")
                ?? throw new InvalidOperationException("KEY_VAULT_URI is not configured and SYSTEM_PROMPT_INLINE is empty.");
            var secretName = Environment.GetEnvironmentVariable("SYSTEM_PROMPT_SECRET")
                ?? "agent-system-prompt";

            var client = new SecretClient(new Uri(vaultUri), new DefaultAzureCredential());
            SystemPrompt = client.GetSecret(secretName).Value.Value;
        }

        var hash = SHA256.HashData(Encoding.UTF8.GetBytes(SystemPrompt));
        SystemPromptSha256 = Convert.ToHexString(hash).ToLowerInvariant();
    }
}
