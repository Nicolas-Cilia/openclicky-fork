// Ports ProviderCapabilities.swift: one answer to "what can this PC use?", so every lane asks the
// same question. Realtime needs an own OpenAI or Gemini key; agent tasks need an own OpenAI key or
// the Codex plan switched on and signed in; speech is heard on this PC unless an own OpenAI key can
// hear it.

using OpenClicky.Core.Configuration;
using OpenClicky.Core.Speech;

namespace OpenClicky.Core.Providers;

/// <param name="HasOwnOpenAIKey">An OpenAI key in shell.json.</param>
/// <param name="HasRealtimeKey">A key that runs realtime voice: OpenAI or Gemini.</param>
/// <param name="HasCodexPlan">The Codex plan is switched on and `codex login` has signed in with ChatGPT.</param>
/// <param name="CodexPausedUntil">The Codex plan has run out; agent tasks wait for this time.</param>
public sealed record ProviderCapabilities(bool HasOwnOpenAIKey, bool HasRealtimeKey, bool HasCodexPlan, DateTimeOffset? CodexPausedUntil = null)
{
    /// <summary>The sign-in `codex login` writes, which the CLI's agent runs use (agent/src/codexHome.ts).</summary>
    public static string CodexAuthFile => Path.Combine(OpenClickyPaths.HomeDirectory, ".codex", "auth.json");

    public static ProviderCapabilities Current(OpenClickyShellSettings? settings = null, Func<bool>? codexSignedIn = null)
    {
        var credentials = ProviderCredentials.FromSettings(settings ?? OpenClickyConfiguration.Settings);
        return new ProviderCapabilities(
            credentials.OpenAIKey is not null,
            RealtimeVoiceProviders.HasOwnKey(credentials),
            credentials.CodexPlanOn && (codexSignedIn ?? (() => File.Exists(CodexAuthFile)))(),
            PlanAvailability.Shared.ExhaustedUntil(AnswerSource.CodexPlan));
    }

    public bool UsesRealtime => HasRealtimeKey;
    public bool UsesAgent => HasOwnOpenAIKey || (HasCodexPlan && CodexPausedUntil is null);
    public bool HearsOnDevice => !HasOwnOpenAIKey;

    /// <summary>What to say instead of running an agent task while Codex has run out.</summary>
    public string? AgentPausedSentence =>
        !HasOwnOpenAIKey && HasCodexPlan && CodexPausedUntil is { } until
            ? $"codex has hit its limit, so agent tasks are paused until {until.ToLocalTime():t}."
            : null;
}
