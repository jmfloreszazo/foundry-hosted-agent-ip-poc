using System.Text.RegularExpressions;

/// <summary>
/// Guardrails — closes the "second door": IP extraction through the endpoint.
/// NONE of this depends on the network. A client with Fiddler sees its own
/// request/response; these rules make sure that in that request/response there
/// is nothing of your IP to extract.
///
/// Honest note: heuristic detection is NOT infallible. The real backstop is the
/// Azure AI Content Safety content filters / Prompt Shields configured on top
/// of the model deployment (see infra/modules/foundry.bicep). This is the
/// application-layer complement to them.
/// </summary>
public static class Guardrails
{
    // Typical patterns of an attempt to exfiltrate the system instructions.
    private static readonly Regex[] ExtractionPatterns =
    [
        new(@"(ignore|forget|disregard).{0,20}(previous|above|prior).{0,20}(instruction|prompt|rule)", RegexOptions.IgnoreCase),
        new(@"(repeat|print|show|reveal|output).{0,20}(system\s*prompt|your\s*instructions|initial\s*prompt)", RegexOptions.IgnoreCase),
        new(@"(what\s+are|show\s+me).{0,20}(your\s+rules|your\s+guidelines|the\s+prompt)", RegexOptions.IgnoreCase),
        new(@"(tell\s+me|show|repeat|print).{0,25}(your\s+prompt|your\s+instructions|your\s+rules|the\s+system\s+prompt)", RegexOptions.IgnoreCase),
    ];

    /// <summary>INPUT guardrail: rejects obvious extraction attempts.</summary>
    public static bool IsExtractionAttempt(string userInput)
        => ExtractionPatterns.Any(p => p.IsMatch(userInput));

    /// <summary>
    /// OUTPUT guardrail: returns null if it detects IP leakage (the handler
    /// will apply the uniform opaque refusal), or the safe text if it is clean.
    /// This is the last line before the wire.
    /// </summary>
    public static string? ScrubOutput(string modelText, string systemPrompt)
    {
        var text = modelText;

        // 1) If a significant fragment of the system prompt shows up, cut it off.
        foreach (var line in systemPrompt.Split('\n', StringSplitOptions.RemoveEmptyEntries))
        {
            var chunk = line.Trim();
            if (chunk.Length >= 25 && text.Contains(chunk, StringComparison.OrdinalIgnoreCase))
            {
                return null;
            }
        }

        // 2) Typical markers of rule leakage.
        if (Regex.IsMatch(text, @"(system\s*prompt|my\s+instructions\s+are|my\s+rules\s+are)", RegexOptions.IgnoreCase))
        {
            return null;
        }

        return text;
    }
}
