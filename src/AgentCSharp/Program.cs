using Azure;
using Azure.AI.AgentServer.Core;
using Azure.AI.AgentServer.Responses;
using Azure.AI.OpenAI;
using Azure.Identity;
using OpenAI.Chat;

// -----------------------------------------------------------------------------
// Program.cs — Hosted Agent bootstrap.
//
// The Azure.AI.AgentServer.Core / .Responses packages provide the ASP.NET
// Core host, the /responses SSE endpoint, telemetry, and lifecycle. We just
// register our ResponseHandler subclass: THAT class is the proprietary logic
// (guardrails + opacity + prompt-from-Key-Vault + gpt-5-mini call) and lives
// inside the image, which lives in the private ACR and runs in the isolated
// Foundry sandbox. Source code is never served to the client.
// -----------------------------------------------------------------------------

var builder = AgentHost.CreateBuilder();

// KeyVaultPromptStore fetches the protected system prompt from Key Vault ONCE
// at startup using the agent's managed identity. Registered as a singleton
// so the network round-trip only happens on process start.
builder.Services.AddSingleton<KeyVaultPromptStore>();

// AzureOpenAIClient + ChatClient — real inference against the gpt-5-mini
// deployment behind the Foundry account. AZURE_OPENAI_ENDPOINT and
// MODEL_DEPLOYMENT_NAME are injected by the Foundry runtime through
// azure.yaml's environmentVariables block. Note the FOUNDRY_* / AGENT_*
// namespaces are reserved by the platform, hence the neutral variable name.
//
// Auth: the Foundry hosted-agent runtime injects an ``agentIdentityBlueprint``
// principal into the container. That principal type CANNOT receive classic
// Azure RBAC role assignments (rejected by ARM with PrincipalTypeNotSupported),
// so ``DefaultAzureCredential`` against the account also fails with 401.
// The production-correct pattern is Foundry AgentID / fmi_path token exchange
// (see docs skill entra-agent-id). For this PoC we take the pragmatic path:
// authenticate against Azure OpenAI with an API key sourced from the Foundry
// account (env var, injected by azd from ``AZURE_OPENAI_API_KEY``). If the
// key is absent we fall back to ``DefaultAzureCredential`` so a future rewire
// to Foundry AgentID keeps working with the same handler code.
var azureOpenAiEndpoint = Environment.GetEnvironmentVariable("AZURE_OPENAI_ENDPOINT")
    ?? throw new InvalidOperationException("AZURE_OPENAI_ENDPOINT env var not set.");
var modelDeployment = Environment.GetEnvironmentVariable("MODEL_DEPLOYMENT_NAME")
    ?? throw new InvalidOperationException("MODEL_DEPLOYMENT_NAME env var not set.");
var azureOpenAiApiKey = Environment.GetEnvironmentVariable("AZURE_OPENAI_API_KEY");

builder.Services.AddSingleton(_ =>
    !string.IsNullOrEmpty(azureOpenAiApiKey)
        ? new AzureOpenAIClient(new Uri(azureOpenAiEndpoint), new AzureKeyCredential(azureOpenAiApiKey))
        : new AzureOpenAIClient(new Uri(azureOpenAiEndpoint), new DefaultAzureCredential()));
builder.Services.AddSingleton<ChatClient>(sp =>
    sp.GetRequiredService<AzureOpenAIClient>().GetChatClient(modelDeployment));

// Register the response protocol pointing at our handler. Framework handles
// SSE, sequencing, cancellation, background execution, health, tracing.
builder.AddResponses<ProtectedResponseHandler>();

builder.Build().Run();
