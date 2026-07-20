using System.Security.Cryptography;

/// <summary>
/// Opacity — opaque-response discipline. The goal is zero differential
/// information: from HOW the agent responds, nothing can be inferred (not
/// content, not timing, not status, not error). Closes the oracles that a
/// naive guardrail leaves open.
/// </summary>
public static class Opacity
{
    // Pool of semantically identical refusals (info = 0) with varied wording,
    // so we don't hand out a clean "you were detected" fingerprint.
    private static readonly string[] Refusals =
    [
        "I can't help with that. What do you need to solve?",
        "That's outside what I can do. Tell me how I can help.",
        "I can't take that request. What else can I help you with?",
        "That isn't something I can handle. How can I help?",
    ];

    // A refusal does NOT reveal why, does not quote the attempt, does not confirm rules.
    public static string Refusal()
        => Refusals[RandomNumberGenerator.GetInt32(Refusals.Length)];

    /// <summary>
    /// Normalizes the latency of the refusal path so it looks like a real
    /// response and no timing oracle exists. Calibrated to the model's p50.
    /// </summary>
    public static async Task NormalizeLatencyAsync(
        DateTimeOffset startedAt,
        int targetMinMs = 900,
        int jitterMs = 600,
        CancellationToken ct = default)
    {
        var elapsed = (DateTimeOffset.UtcNow - startedAt).TotalMilliseconds;
        var target = targetMinMs + RandomNumberGenerator.GetInt32(jitterMs);
        var remaining = target - (int)elapsed;
        if (remaining > 0)
        {
            await Task.Delay(remaining, ct);
        }
    }

    // Single generic error message: does not leak stack, fields, or model.
    public const string GenericError =
        "I couldn't process the request. Please try again.";
}
