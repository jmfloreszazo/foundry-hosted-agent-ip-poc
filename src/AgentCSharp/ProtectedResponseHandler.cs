using System.ClientModel;
using System.Runtime.CompilerServices;
using Azure.AI.AgentServer.Responses;
using Azure.AI.AgentServer.Responses.Models;
using OpenAI.Chat;
// CreateResponseExtensions.GetInputText — synchronous, reads only from the
// request payload (no Foundry storage / history round-trip). Using this
// instead of context.GetInputTextAsync avoids the 404 on first-turn
// invocations where azd sends store=true + a fresh client-generated
// conversation_id that Foundry storage has not yet materialized.

/// <summary>
/// ProtectedResponseHandler — protected IP with OPAQUE response.
///   - Prompt/rules in Key Vault (out of the repo and out of the binary),
///     loaded once at startup by KeyVaultPromptStore (DI singleton).
///   - Input/output guardrails against extraction.
///   - Opaque response: uniform refusal, normalized latency (no timing
///     oracle), same contract for refusal and answer (no status oracle),
///     generic error (no error oracle). Differential info = 0.
///
/// Phase B: real inference against the gpt-5-mini deployment on the Foundry
/// account via the injected ChatClient (Azure.AI.OpenAI). The model call is
/// wrapped by the same guardrail/opacity envelope Phase A used, so the wire
/// contract is byte-for-byte indistinguishable between refusal and answer.
/// </summary>
public sealed class ProtectedResponseHandler : ResponseHandler
{
    private const string PhaseABenchmarkMode = "phase-a";

    private readonly KeyVaultPromptStore _promptStore;
    private readonly ChatClient _chatClient;
    private readonly ILogger<ProtectedResponseHandler> _logger;
    private readonly bool _usePhaseACannedResponse;

    public ProtectedResponseHandler(
        KeyVaultPromptStore promptStore,
        ChatClient chatClient,
        ILogger<ProtectedResponseHandler> logger)
    {
        _promptStore = promptStore;
        _chatClient = chatClient;
        _logger = logger;
        _usePhaseACannedResponse = string.Equals(
            Environment.GetEnvironmentVariable("BENCHMARK_MODE"),
            PhaseABenchmarkMode,
            StringComparison.OrdinalIgnoreCase);
    }

    public override async IAsyncEnumerable<ResponseStreamEvent> CreateAsync(
        CreateResponse request,
        ResponseContext context,
        [EnumeratorCancellation] CancellationToken cancellationToken)
    {
        var startedAt = DateTimeOffset.UtcNow;
        var stream = new ResponseEventStream(context, request);

        yield return stream.EmitCreated();
        yield return stream.EmitInProgress();

        string userInput;
        bool inputReadFailed = false;
        try
        {
            // Read input directly from the request payload — does NOT hit
            // Foundry storage/history. Safe on first-turn where the
            // conversation id from the client is not yet materialized.
            // GetInputExpanded() parses request.Input (BinaryData that can be
            // either a plain string or an array of Item objects); the
            // GetInputText() extension on IEnumerable<Item> then joins the
            // text content of every ItemMessage with newlines.
            userInput = request.GetInputExpanded().GetInputText() ?? string.Empty;
        }
        catch (OperationCanceledException)
        {
            throw;
        }
        catch (Exception ex)
        {
            _logger.LogWarning(ex, "Failed to read input text; returning generic error.");
            userInput = string.Empty;
            inputReadFailed = true;
        }

        if (inputReadFailed)
        {
            await Opacity.NormalizeLatencyAsync(startedAt, ct: cancellationToken);
            foreach (var evt in stream.OutputItemMessage(Opacity.GenericError))
                yield return evt;
            yield return stream.EmitCompleted();
            yield break;
        }

        // --- INPUT: extraction attempt -> OPAQUE refusal ---
        // Do not fast-fail: latency is normalized so there is no timing oracle,
        // and the wire contract is identical to a real response. The attacker
        // cannot tell "I was detected" from "the model doesn't know".
        if (Guardrails.IsExtractionAttempt(userInput))
        {
            await Opacity.NormalizeLatencyAsync(startedAt, ct: cancellationToken);
            foreach (var evt in stream.OutputItemMessage(Opacity.Refusal()))
                yield return evt;
            yield return stream.EmitCompleted();
            yield break;
        }

        // --- Phase A benchmark mode: no model call, deterministic body ---
        if (_usePhaseACannedResponse)
        {
            var canned = CreatePhaseACannedResponse(userInput);
            await Opacity.NormalizeLatencyAsync(startedAt, ct: cancellationToken);
            foreach (var evt in stream.OutputItemMessage(canned))
                yield return evt;
            yield return stream.EmitCompleted();
            yield break;
        }

        // --- Real gpt-5-mini inference ---
        // yield return cannot appear inside a catch block, so we route the
        // failure through a nullable body + flag pattern (same shape as the
        // input-read error path above).
        string? body = null;
        bool modelCallFailed = false;
        try
        {
            body = await CallModelAsync(userInput, cancellationToken);
        }
        catch (OperationCanceledException)
        {
            throw;
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Model call failed; returning generic error.");
            modelCallFailed = true;
        }

        if (modelCallFailed || body is null)
        {
            await Opacity.NormalizeLatencyAsync(startedAt, ct: cancellationToken);
            foreach (var evt in stream.OutputItemMessage(Opacity.GenericError))
                yield return evt;
            yield return stream.EmitCompleted();
            yield break;
        }

        // Output guardrail: even the model's real response is scrubbed against
        // the KV-loaded system prompt so a regression here cannot silently
        // leak it (belt-and-braces on top of Prompt Shields at the platform).
        var scrubbed = Guardrails.ScrubOutput(body, _promptStore.SystemPrompt);
        if (scrubbed is null)
        {
            _logger.LogError("Output guardrail tripped on model response; returning opaque refusal.");
            await Opacity.NormalizeLatencyAsync(startedAt, ct: cancellationToken);
            foreach (var evt in stream.OutputItemMessage(Opacity.Refusal()))
                yield return evt;
            yield return stream.EmitCompleted();
            yield break;
        }

        await Opacity.NormalizeLatencyAsync(startedAt, ct: cancellationToken);
        foreach (var evt in stream.OutputItemMessage(scrubbed))
            yield return evt;
        yield return stream.EmitCompleted();
    }

    private string CreatePhaseACannedResponse(string userInput)
    {
        var inputTokens = Math.Max(1, userInput.Length / 4);
        return $"Protected response OK. prompt_sha256={_promptStore.SystemPromptSha256[..12]}; input_tokens_est={inputTokens}; model_call=false";
    }

    private async Task<string> CallModelAsync(string userInput, CancellationToken ct)
    {
        var messages = new ChatMessage[]
        {
            new SystemChatMessage(_promptStore.SystemPrompt),
            new UserChatMessage(userInput),
        };

        // reasoning_effort=minimal keeps gpt-5-mini's reasoning-token spend
        // bounded and matches the Python handler. Note we deliberately do NOT
        // set MaxOutputTokenCount here: in Azure.AI.OpenAI 2.2.0-beta.4 that
        // property serialises to the legacy ``max_tokens`` wire field, which
        // Azure OpenAI rejects for reasoning models with HTTP 400
        // ``Unsupported parameter: 'max_tokens' is not supported with this
        // model. Use 'max_completion_tokens' instead``. The extensible-enum
        // ctor is used because ChatReasoningEffortLevel in this SDK version
        // only exposes Low/Medium/High as static members even though the wire
        // protocol accepts "minimal" too.
        var options = new ChatCompletionOptions
        {
            ReasoningEffortLevel = new ChatReasoningEffortLevel("minimal"),
        };

        ClientResult<ChatCompletion> result = await _chatClient.CompleteChatAsync(messages, options, ct);
        var completion = result.Value;
        var content = completion.Content;
        if (content is null || content.Count == 0)
        {
            return string.Empty;
        }
        return (content[0].Text ?? string.Empty).Trim();
    }
}
