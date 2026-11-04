// Ports ProviderRoute.swift. A capability the person has a key for goes straight to that vendor with
// their key; a question can also go to a Claude or Codex plan through its CLI. Every caller asks
// `ProviderRouter` the same question, so there is one place that decides, and one log line per change
// of route.

using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using OpenClicky.Core.Configuration;

namespace OpenClicky.Core.Providers;

/// <summary>What a call is for, by the key that can pay for it.</summary>
public enum ProviderCapability
{
    /// <summary>Claude: the ask lane (/chat) and screen grounding. Anthropic key.</summary>
    Claude,
    /// <summary>OpenAI chat completions: the take clean-up on an own key. OpenAI key.</summary>
    OpenAIChat,
    /// <summary>OpenAI speech on an own key. Kept because the route table is tested per key.</summary>
    Speech,
    /// <summary>Upload speech-to-text. OpenAI key.</summary>
    Transcription,
    /// <summary>Realtime voice: the client secret. OpenAI key.</summary>
    Realtime,
}

public enum ProviderRouteKind
{
    OpenAIDirect,
    AnthropicDirect,
    /// <summary>Questions answered by another source (an OpenAI-compatible key, Gemini, or a plan). Only for Claude.</summary>
    AnswerProvider,
    /// <summary>Nothing set up for this: the sentence says what is missing.</summary>
    Unavailable,
}

/// <summary>Where one call goes. Compare with ==; build with the static members.</summary>
public sealed record ProviderRoute
{
    public ProviderRouteKind Kind { get; }
    /// <summary>The source for an AnswerProvider route.</summary>
    public AnswerSource? Source { get; }
    /// <summary>The sentence for an Unavailable route.</summary>
    public string? Sentence { get; }

    private ProviderRoute(ProviderRouteKind kind, AnswerSource? source = null, string? sentence = null)
    {
        Kind = kind;
        Source = source;
        Sentence = sentence;
    }

    public static ProviderRoute OpenAIDirect { get; } = new(ProviderRouteKind.OpenAIDirect);
    public static ProviderRoute AnthropicDirect { get; } = new(ProviderRouteKind.AnthropicDirect);
    public static ProviderRoute AnswerProvider(AnswerSource source) => new(ProviderRouteKind.AnswerProvider, source: source);
    public static ProviderRoute Unavailable(string sentence) => new(ProviderRouteKind.Unavailable, sentence: sentence);

    public string LogName => Kind switch
    {
        ProviderRouteKind.OpenAIDirect => "openai, own key",
        ProviderRouteKind.AnthropicDirect => "anthropic, own key",
        ProviderRouteKind.AnswerProvider => Source!.Value.DisplayName(),
        _ => "unavailable",
    };

    /// <summary>The source a Claude route answers with, for saying who answered; null when nothing can.</summary>
    public AnswerSource? AnsweringSource => Kind switch
    {
        ProviderRouteKind.AnthropicDirect => Providers.AnswerSource.Anthropic,
        ProviderRouteKind.AnswerProvider => Source,
        _ => null,
    };

    public string? UnavailableSentence => Kind == ProviderRouteKind.Unavailable ? Sentence : null;

    public override string ToString() => Kind switch
    {
        ProviderRouteKind.AnswerProvider => $"AnswerProvider({Source})",
        ProviderRouteKind.Unavailable => $"Unavailable({Sentence})",
        _ => Kind.ToString(),
    };
}

/// <summary>The keys and plans a route is decided on. Values only: no key ever goes into a log.</summary>
public sealed record ProviderCredentials
{
    public string? OpenAIKey { get; init; }
    public string? AnthropicKey { get; init; }
    /// <summary>The other keys that can answer questions, and the plans the person switched on.</summary>
    public string? OpenRouterKey { get; init; }
    public string? GeminiKey { get; init; }
    public string? GroqKey { get; init; }
    public string? MistralKey { get; init; }
    public string? XaiKey { get; init; }
    public bool ClaudeCodePlanOn { get; init; }
    public bool CodexPlanOn { get; init; }
    /// <summary>Who should answer, when the person picked one (null: automatic).</summary>
    public AnswerSource? PreferredAnswerSource { get; init; }
    /// <summary>Which plan takes over when the default runs out: null is the other linked plan, <see cref="NoBackup"/> none.</summary>
    public string? BackupChoice { get; init; }
    /// <summary>The plans that have run out for now (<see cref="PlanAvailability"/>).</summary>
    public IReadOnlySet<AnswerSource> ExhaustedPlans { get; init; } = new HashSet<AnswerSource>();
    public const string NoBackup = "none";

    /// <summary>Blank values count as missing; every value is trimmed.</summary>
    public ProviderCredentials(string? openAIKey, string? anthropicKey,
                               string? openRouterKey = null, string? geminiKey = null, string? groqKey = null,
                               string? mistralKey = null, string? xaiKey = null,
                               bool claudeCodePlanOn = false, bool codexPlanOn = false, AnswerSource? preferredAnswerSource = null)
    {
        OpenAIKey = OpenClickyConfiguration.Cleaned(openAIKey);
        AnthropicKey = OpenClickyConfiguration.Cleaned(anthropicKey);
        OpenRouterKey = OpenClickyConfiguration.Cleaned(openRouterKey);
        GeminiKey = OpenClickyConfiguration.Cleaned(geminiKey);
        GroqKey = OpenClickyConfiguration.Cleaned(groqKey);
        MistralKey = OpenClickyConfiguration.Cleaned(mistralKey);
        XaiKey = OpenClickyConfiguration.Cleaned(xaiKey);
        ClaudeCodePlanOn = claudeCodePlanOn;
        CodexPlanOn = codexPlanOn;
        PreferredAnswerSource = preferredAnswerSource;
    }

    public static ProviderCredentials FromSettings(OpenClickyShellSettings settings) =>
        new(settings.OpenaiApiKey, settings.AnthropicApiKey,
            openRouterKey: settings.OpenRouterApiKey, geminiKey: settings.GeminiApiKey, groqKey: settings.GroqApiKey,
            mistralKey: settings.MistralApiKey, xaiKey: settings.XaiApiKey,
            claudeCodePlanOn: settings.UseClaudeCodePlan == true, codexPlanOn: settings.UseCodexPlan == true,
            preferredAnswerSource: AnswerSources.FromRawValue(settings.AnswerSource)) { BackupChoice = settings.BackupAnswerSource };

    /// <summary>The keys in shell.json now, and which plans have run out.</summary>
    public static ProviderCredentials Current() =>
        FromSettings(OpenClickyConfiguration.Settings) with { ExhaustedPlans = PlanAvailability.Shared.ExhaustedPlans() };

    /// <summary>The key for an API source, null for the plans.</summary>
    public string? Key(AnswerSource source) => source switch
    {
        AnswerSource.Anthropic => AnthropicKey,
        AnswerSource.OpenAI => OpenAIKey,
        AnswerSource.OpenRouter => OpenRouterKey,
        AnswerSource.Gemini => GeminiKey,
        AnswerSource.Groq => GroqKey,
        AnswerSource.Mistral => MistralKey,
        AnswerSource.Xai => XaiKey,
        _ => null,
    };

    /// <summary>Whether `source` can answer with what is set up: its key, or its plan switched on.</summary>
    public bool CanAnswer(AnswerSource source) => source switch
    {
        AnswerSource.ClaudeCodePlan => ClaudeCodePlanOn,
        AnswerSource.CodexPlan => CodexPlanOn,
        _ => Key(source) is not null,
    };

    private static readonly AnswerSource[] AutomaticOrder =
    [
        AnswerSource.ClaudeCodePlan, AnswerSource.CodexPlan, AnswerSource.Anthropic, AnswerSource.OpenRouter, AnswerSource.OpenAI,
        AnswerSource.Gemini, AnswerSource.Xai, AnswerSource.Mistral, AnswerSource.Groq,
    ];

    private static readonly AnswerSource[] Plans = [AnswerSource.ClaudeCodePlan, AnswerSource.CodexPlan];

    /// <summary>
    /// The sources that can answer, in the order "automatic" tries them: the plans switched on, then
    /// own keys (Anthropic first, then OpenRouter, which reaches the most models).
    /// </summary>
    public IReadOnlyList<AnswerSource> AnswerSourcesInOrder => AutomaticOrder.Where(CanAnswer).ToList();

    /// <summary>Who answers when nothing has run out: the person's pick if it is set up, else the first in order.</summary>
    public AnswerSource? PrimaryAnswerSource =>
        PreferredAnswerSource is { } preferred && CanAnswer(preferred)
            ? preferred
            : AnswerSourcesInOrder.Count > 0 ? AnswerSourcesInOrder[0] : null;

    /// <summary>
    /// The plan that takes over from the primary. Only ever a plan: a key is not used without being
    /// chosen, so a plan running out never turns into a bill.
    /// </summary>
    public AnswerSource? BackupSource
    {
        get
        {
            if (BackupChoice == NoBackup || PrimaryAnswerSource is not { } primary || !Plans.Contains(primary)) return null;
            if (AnswerSources.FromRawValue(BackupChoice) is { } picked && Plans.Contains(picked) && picked != primary && CanAnswer(picked))
            {
                return picked;
            }
            foreach (var plan in Plans)
            {
                if (plan != primary && CanAnswer(plan)) return plan;
            }
            return null;
        }
    }

    /// <summary>
    /// Who answers now: the primary, or the backup while the primary has run out and the backup has
    /// not. With both out, the primary, whose refusal says so.
    /// </summary>
    public AnswerSource? ActiveAnswerSource
    {
        get
        {
            if (PrimaryAnswerSource is not { } primary) return null;
            if (!ExhaustedPlans.Contains(primary) || BackupSource is not { } backup || ExhaustedPlans.Contains(backup)) return primary;
            return backup;
        }
    }
}

public static class ProviderRouter
{
    /// <summary>Nothing set up: connecting a plan is the way in for most people, so it comes first.</summary>
    public const string NeedsOpenAIKeySentence = "that needs your own openai key. add it in settings, keys & plans.";
    public const string NeedsAnthropicKeySentence = "i can answer that once you connect claude or codex, or add a key, in settings, keys & plans.";

    /// <summary>The route for `capability`: own key or plan → that vendor; nothing set up → unavailable, saying what would do.</summary>
    public static ProviderRoute Route(ProviderCapability capability, ProviderCredentials credentials)
    {
        if (capability == ProviderCapability.Claude)
        {
            return credentials.ActiveAnswerSource switch
            {
                AnswerSource.Anthropic => ProviderRoute.AnthropicDirect,
                { } other => ProviderRoute.AnswerProvider(other),
                null => ProviderRoute.Unavailable(NeedsAnthropicKeySentence),
            };
        }
        return credentials.OpenAIKey is not null ? ProviderRoute.OpenAIDirect : ProviderRoute.Unavailable(NeedsOpenAIKeySentence);
    }

    /// <summary>The keys in shell.json now, and which plans have run out.</summary>
    public static ProviderCredentials CurrentCredentials() => ProviderCredentials.Current();

    /// <summary>The route for `capability` with the settings in shell.json now. Logged when it changes.</summary>
    public static ProviderRoute Current(ProviderCapability capability)
    {
        var route = Route(capability, CurrentCredentials());
        NoteRoute(route, capability);
        return route;
    }

    private static readonly object LastRoutesLock = new();
    private static readonly Dictionary<ProviderCapability, ProviderRoute> LastRoutes = [];

    private static void NoteRoute(ProviderRoute route, ProviderCapability capability)
    {
        bool changed;
        lock (LastRoutesLock)
        {
            changed = !LastRoutes.TryGetValue(capability, out var last) || last != route;
            LastRoutes[capability] = route;
        }
        if (changed) AppLog.Write($"route: {capability.RawValue()} → {route.LogName}");
    }
}

/// <summary>The error a caller throws for an unavailable route; its message is the sentence to show or say.</summary>
public sealed class ProviderRouteUnavailableException(ProviderCapability capability, string sentence) : Exception(sentence)
{
    public ProviderCapability Capability { get; } = capability;
    public string Sentence { get; } = sentence;
}

/// <summary>The direct vendor requests.</summary>
public static class DirectProviderRequests
{
    public const string OpenAIBaseUrl = "https://api.openai.com/v1";
    public const string AnthropicMessagesUrl = "https://api.anthropic.com/v1/messages";
    public const string AnthropicVersion = "2023-06-01";

    /// <summary>The default models on an own key.</summary>
    public const string DefaultOpenAIModel = "gpt-5.5";
    public const string DefaultAnthropicModel = "claude-haiku-4-5-20251001";
    public const string RealtimeModel = "gpt-realtime";
    public const string TranscriptionModel = "gpt-4o-mini-transcribe";
    public const string SpeechModel = "gpt-4o-mini-tts";
    public const string SpeechVoice = "marin";

    /// <summary>A body with exactly `Content-Type: application/json` (no charset), as URLRequest sends it.</summary>
    public static HttpContent JsonContent(byte[] body)
    {
        var content = new ByteArrayContent(body);
        content.Headers.ContentType = new MediaTypeHeaderValue("application/json");
        return content;
    }

    public static HttpContent JsonContent(JsonNode body) => JsonContent(Encoding.UTF8.GetBytes(body.ToJsonString()));

    public static HttpContent JsonContent(string body) => JsonContent(Encoding.UTF8.GetBytes(body));

    private static HttpRequestMessage OpenAIRequest(string path, string key)
    {
        var request = new HttpRequestMessage(HttpMethod.Post, OpenAIBaseUrl + path);
        request.SetHeader("Authorization", $"Bearer {key}");
        return request;
    }

    /// <summary>
    /// Anthropic Messages; the body is the caller's, as JSON content —
    /// pass it here or set `Content = DirectProviderRequests.JsonContent(...)` afterwards.
    /// </summary>
    public static HttpRequestMessage AnthropicMessages(string key, JsonNode? body = null)
    {
        var request = new HttpRequestMessage(HttpMethod.Post, AnthropicMessagesUrl);
        request.Content = JsonContent(body ?? new JsonObject());
        request.SetHeader("x-api-key", key);
        request.SetHeader("anthropic-version", AnthropicVersion);
        return request;
    }

    /// <summary>The polish model and its output ceiling.</summary>
    public const string PolishModel = "claude-haiku-4-5";
    public const int PolishMaxOutputTokens = 4096;

    /// <summary>Dictation polish or a Hey Clicky edit on Claude Haiku.</summary>
    public static HttpRequestMessage AnthropicPolish(string key, string system, string text)
    {
        var body = new JsonObject
        {
            ["model"] = PolishModel,
            // An upper bound: some scripts take a token or more per character, and a take cut off
            // at max_tokens would be pasted half-finished.
            ["max_tokens"] = Math.Min(PolishMaxOutputTokens, text.Length * 2 + 64),
            ["system"] = new JsonArray(new JsonObject
            {
                ["type"] = "text",
                ["text"] = system,
                ["cache_control"] = new JsonObject { ["type"] = "ephemeral" },
            }),
            ["messages"] = new JsonArray(new JsonObject { ["role"] = "user", ["content"] = text }),
        };
        return AnthropicMessages(key, body);
    }

    /// <summary>
    /// The text of a non-streamed Messages reply. Null when there is none, or when it stopped at
    /// max_tokens: half a take must never be pasted as if it were whole.
    /// </summary>
    public static string? AnthropicReplyText(byte[] data)
    {
        JsonObject? json;
        try { json = JsonNode.Parse(data) as JsonObject; }
        catch (JsonException) { return null; }
        if (json?["content"] is not JsonArray content) return null;
        if (StringValue(json["stop_reason"]) == "max_tokens") return null;
        var text = string.Concat(content
            .OfType<JsonObject>()
            .Where(block => StringValue(block["type"]) == "text")
            .Select(block => StringValue(block["text"]))
            .Where(blockText => blockText is not null)).Trim();
        return text.Length == 0 ? null : text;
    }

    /// <summary>OpenAI Chat Completions; the body is the caller's.</summary>
    public static HttpRequestMessage OpenAIChatCompletions(string key, JsonNode? body = null)
    {
        var request = OpenAIRequest("/chat/completions", key);
        request.Content = JsonContent(body ?? new JsonObject());
        return request;
    }

    /// <summary>OpenAI speech for `text`, mp3.</summary>
    public static HttpRequestMessage OpenAISpeech(string key, string text)
    {
        var request = OpenAIRequest("/audio/speech", key);
        request.SetHeader("Accept", "audio/mpeg");
        request.Content = JsonContent(new JsonObject
        {
            ["model"] = SpeechModel,
            ["voice"] = SpeechVoice,
            ["input"] = text,
            ["response_format"] = "mp3",
        });
        return request;
    }

    /// <summary>The multipart upload OpenAI's transcription takes.</summary>
    public static HttpRequestMessage OpenAITranscription(string key, byte[] wav, string? language, string? prompt, string? boundary = null)
    {
        boundary ??= $"openclicky-{Guid.NewGuid().ToString().ToUpperInvariant()}";
        var request = OpenAIRequest("/audio/transcriptions", key);
        using var body = new MemoryStream();
        void Append(string text)
        {
            var bytes = Encoding.UTF8.GetBytes(text);
            body.Write(bytes, 0, bytes.Length);
        }
        void Field(string name, string value) =>
            Append($"--{boundary}\r\nContent-Disposition: form-data; name=\"{name}\"\r\n\r\n{value}\r\n");
        Append($"--{boundary}\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\nContent-Type: audio/wav\r\n\r\n");
        body.Write(wav, 0, wav.Length);
        Append("\r\n");
        Field("model", TranscriptionModel);
        Field("response_format", "json");
        if (!string.IsNullOrEmpty(language)) Field("language", language);
        if (!string.IsNullOrEmpty(prompt)) Field("prompt", prompt);
        Append($"--{boundary}--\r\n");
        var content = new ByteArrayContent(body.ToArray());
        content.Headers.TryAddWithoutValidation("Content-Type", $"multipart/form-data; boundary={boundary}");
        request.Content = content;
        return request;
    }

    /// <summary>A Realtime client secret.</summary>
    public static HttpRequestMessage OpenAIRealtimeSecret(string key, string? instructions, string? voice, int expiresInSeconds = 600)
    {
        var request = OpenAIRequest("/realtime/client_secrets", key);
        var session = new JsonObject { ["type"] = "realtime", ["model"] = RealtimeModel };
        if (!string.IsNullOrEmpty(instructions)) session["instructions"] = instructions;
        if (!string.IsNullOrEmpty(voice)) session["audio"] = new JsonObject { ["output"] = new JsonObject { ["voice"] = voice } };
        request.Content = JsonContent(new JsonObject
        {
            ["expires_after"] = new JsonObject { ["anchor"] = "created_at", ["seconds"] = expiresInSeconds },
            ["session"] = session,
        });
        return request;
    }

    private static string? StringValue(JsonNode? node) =>
        node is JsonValue value && value.TryGetValue<string>(out var text) ? text : null;
}
