// Ports Dictation/TakePolishers.swift: the models that tidy a take and make Hey Clicky edits.
// Sarvam's chat on a Sarvam key, OpenAI on an own OpenAI key, Claude Haiku on an own Anthropic
// key, and any other answer key through its own vendor. (The Mac's first rung, Apple's on-device model, has no Windows twin.)
// `DictationEngineResolver.MakePolisher` picks one. Each says honestly who refused: an error
// blamed on the wrong vendor sends people to the wrong key.

using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using OpenClicky.Core.Configuration;
using OpenClicky.Core.Providers;

namespace OpenClicky.Core.Dictation;

public enum TakePolishErrorKind
{
    /// <summary>The vendor answered with a refusal (`Status` is its HTTP status, 0 when there was none).</summary>
    Refused,
    /// <summary>The vendor answered, but there was no text in it.</summary>
    EmptyAnswer,
    /// <summary>Nothing was sent: the route this polisher needs is not set up (the sentence says what is missing).</summary>
    NotSetUp,
}

/// <summary>
/// Why a vendor reached directly on the person's own key did not tidy or edit the words. Neutral
/// on purpose: a refusal names the vendor that refused.
/// </summary>
public sealed class TakePolishException : Exception
{
    public TakePolishErrorKind Kind { get; }
    public string Vendor { get; }
    public int Status { get; }
    public string Detail { get; }

    private TakePolishException(TakePolishErrorKind kind, string vendor, int status, string detail, string message) : base(message)
    {
        Kind = kind; Vendor = vendor; Status = status; Detail = detail;
    }

    public static TakePolishException Refused(string vendor, int status, string message)
    {
        var statusPart = status == 0 ? "" : $" ({status})";
        var trimmedMessage = message.Trim();
        return new(TakePolishErrorKind.Refused, vendor, status, message,
            $"{vendor} refused the request{statusPart}" + (trimmedMessage.Length == 0 ? "." : $": {trimmedMessage}"));
    }

    public static TakePolishException EmptyAnswer(string vendor) =>
        new(TakePolishErrorKind.EmptyAnswer, vendor, 0, "", $"{vendor} sent back no text.");

    public static TakePolishException NotSetUp(string sentence) =>
        new(TakePolishErrorKind.NotSetUp, "", 0, sentence, sentence);
}

/// <summary>Polishes through Sarvam's chat completions with the user's key.</summary>
public sealed class SarvamTakePolisher(SarvamSpeechClient client) : ITakePolisher
{
    public SarvamSpeechClient Client { get; } = client;
    public string DisplayName => "Sarvam";

    public Task<string> PolishAsync(string system, string user, CancellationToken cancellationToken = default) =>
        Client.CompleteAsync(system, user, cancellationToken: cancellationToken);
}

/// <summary>
/// Polishes through OpenAI's chat completions, on the person's own OpenAI key.
/// </summary>
public sealed class OpenAITakePolisher : ITakePolisher
{
    public const string Model = "gpt-4o-mini";
    public static readonly TimeSpan RequestTimeout = TimeSpan.FromSeconds(20);

    public string DisplayName => "OpenAI";

    public static JsonObject Body(string system, string user) => new()
    {
        ["model"] = Model,
        ["messages"] = new JsonArray(
            new JsonObject { ["role"] = "system", ["content"] = system },
            new JsonObject { ["role"] = "user", ["content"] = user }),
        ["temperature"] = 0.2,
    };

    public async Task<string> PolishAsync(string system, string user, CancellationToken cancellationToken = default)
    {
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeout.CancelAfter(RequestTimeout);
        var body = Body(system, user);
        var openAIKey = ProviderRouter.CurrentCredentials().OpenAIKey
            ?? throw TakePolishException.NotSetUp(ProviderRouter.NeedsOpenAIKeySentence);
        using var response = await HttpClients.Shared.SendAsync(DirectProviderRequests.OpenAIChatCompletions(openAIKey, body), timeout.Token).ConfigureAwait(false);
        var data = await response.Content.ReadAsByteArrayAsync(timeout.Token).ConfigureAwait(false);
        var status = (int)response.StatusCode;
        if (status is < 200 or >= 300)
        {
            throw TakePolishException.Refused("openai", status, Encoding.UTF8.GetString(data, 0, Math.Min(200, data.Length)));
        }
        return ChatCompletionContent(data) ?? throw TakePolishException.EmptyAnswer("openai");
    }

    /// <summary>`choices[0].message.content` of an OpenAI-shaped chat completion, null when absent.</summary>
    public static string? ChatCompletionContent(byte[] data)
    {
        try
        {
            if (JsonNode.Parse(data) is not JsonObject answer || answer["choices"] is not JsonArray choices || choices.Count == 0) return null;
            if (choices[0]?["message"]?["content"] is JsonValue value && value.TryGetValue<string>(out var content)) return content;
            return null;
        }
        catch (JsonException)
        {
            return null;
        }
    }
}

// MARK: - Own keys

/// <summary>
/// Polish and edits on the person's own Anthropic key, straight to Anthropic, on Claude Haiku.
/// </summary>
public sealed class AnthropicTakePolisher(string anthropicKey) : ITakePolisher
{
    public string AnthropicKey { get; } = anthropicKey;
    public Func<HttpRequestMessage, CancellationToken, Task<HttpResponseMessage>> Send { get; init; } =
        (request, token) => HttpClients.Shared.SendAsync(request, token);

    public static readonly TimeSpan RequestTimeout = TimeSpan.FromSeconds(20);

    public string DisplayName => "Claude (your key)";

    public async Task<string> PolishAsync(string system, string user, CancellationToken cancellationToken = default)
    {
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeout.CancelAfter(RequestTimeout);
        using var response = await Send(DirectProviderRequests.AnthropicPolish(AnthropicKey, system, user), timeout.Token).ConfigureAwait(false);
        var data = await response.Content.ReadAsByteArrayAsync(timeout.Token).ConfigureAwait(false);
        var status = (int)response.StatusCode;
        if (status is < 200 or >= 300)
        {
            AppLog.Write($"polish (own anthropic key): anthropic answered {status}");
            throw TakePolishException.Refused("anthropic", status, Encoding.UTF8.GetString(data, 0, Math.Min(200, data.Length)));
        }
        if (DirectProviderRequests.AnthropicReplyText(data) is not { } text)
        {
            AppLog.Write("polish (own anthropic key): the reply had no whole text");
            throw TakePolishException.EmptyAnswer("anthropic");
        }
        return text;
    }
}

/// <summary>An answer key's vendor refused (the Mac's AnswerProviderError: status and message).</summary>
public sealed class AnswerKeyCompletionException(int status, string detail) : Exception(detail)
{
    public int Status { get; } = status;
    public string Detail { get; } = detail;
}

/// <summary>One non-streamed completion on an answer key: the seam AnswerKeyTakePolisher asks (tests fake it).</summary>
public interface IAnswerKeyCompletion
{
    Task<string> CompleteAsync(AnswerSource source, ProviderCredentials credentials, string? modelOverride,
                               string system, string user, int maxTokens, CancellationToken cancellationToken);
}

/// <summary>
/// The completion through the answer providers (Swift: AnswerKeyTakePolisher.polish):
/// `AnswerProviderFactory.MakeAsync` for the source with the polish model as its override, then one
/// text-only `AnswerAsync`. A vendor's refusal comes back as AnswerKeyCompletionException.
/// </summary>
public sealed class AnswerProviderKeyCompletion : IAnswerKeyCompletion
{
    public static AnswerProviderKeyCompletion Shared { get; } = new();

    public async Task<string> CompleteAsync(AnswerSource source, ProviderCredentials credentials, string? modelOverride,
                                            string system, string user, int maxTokens, CancellationToken cancellationToken)
    {
        var models = new Dictionary<string, string>();
        if (modelOverride is not null) models[source.Id()] = modelOverride;
        try
        {
            var provider = await Answers.AnswerProviderFactory.MakeAsync(source, credentials, models, cancellationToken: cancellationToken).ConfigureAwait(false);
            var request = new Answers.AnswerRequest([], system, [], user, [], maxTokens);
            var result = await provider.AnswerAsync(request, _ => { }, cancellationToken).ConfigureAwait(false);
            return result.Text;
        }
        catch (Answers.AnswerProviderException error)
        {
            throw new AnswerKeyCompletionException(error.Status, error.VendorMessage);
        }
    }
}

/// <summary>
/// Polish and edits on any other answer key the person added (OpenRouter, Gemini, Groq, Mistral,
/// xAI), straight to that vendor. A quick model where the default answer model is a slow one: the
/// clean-up gives up after `TakeFormatter.ModelTimeout`. The two plans are left out: starting
/// their CLI alone takes longer than that.
/// </summary>
public sealed class AnswerKeyTakePolisher(AnswerSource source, ProviderCredentials credentials) : ITakePolisher
{
    public AnswerSource Source { get; } = source;
    public ProviderCredentials Credentials { get; } = credentials;
    public IAnswerKeyCompletion Completion { get; init; } = AnswerProviderKeyCompletion.Shared;

    /// <summary>The keys that can polish, in the order they are tried; the fast ones first.</summary>
    public static IReadOnlyList<AnswerSource> SourcesInOrder { get; } =
        [AnswerSource.Groq, AnswerSource.Gemini, AnswerSource.Mistral, AnswerSource.OpenRouter, AnswerSource.Xai];

    /// <summary>The model asked to tidy a take, where it differs from the answer model.</summary>
    public static string? PolishModel(AnswerSource source) => source switch
    {
        AnswerSource.OpenRouter => "openai/gpt-4.1-mini",
        AnswerSource.Mistral => "mistral-small-latest",
        _ => null,
    };

    /// <summary>The first source with a key, null without any.</summary>
    public static AnswerKeyTakePolisher? FirstAvailable(ProviderCredentials credentials)
    {
        foreach (var candidate in SourcesInOrder)
        {
            if (credentials.Key(candidate) is not null) return new AnswerKeyTakePolisher(candidate, credentials);
        }
        return null;
    }

    public string DisplayName => $"{Source.ShortName()} (your key)";

    public async Task<string> PolishAsync(string system, string user, CancellationToken cancellationToken = default)
    {
        var vendorName = Source.ShortName().ToLowerInvariant();
        try
        {
            var text = (await Completion.CompleteAsync(Source, Credentials, PolishModel(Source), system, user, 1024, cancellationToken).ConfigureAwait(false)).Trim();
            if (text.Length == 0) throw TakePolishException.EmptyAnswer(vendorName);
            return text;
        }
        catch (AnswerKeyCompletionException error)
        {
            AppLog.Write($"polish (own {Source.RawValue()} key): {error.Status}");
            throw TakePolishException.Refused(vendorName, error.Status, error.Detail);
        }
    }
}

// MARK: - Saying why the clean-up was skipped

/// <summary>
/// Why a take was pasted with only the local clean-up, said once per session (every take hitting
/// the same limit would otherwise repeat it). The orb still says "cleaned up locally"; this is the
/// reason behind it, shown as the companion's quiet caption. Null for a reason not worth saying
/// (a timeout, a passing server error): the log has those.
/// </summary>
public static class PolishFailureNotice
{
    public const string OwnKeyRefusedSentence = "your own api key was refused, so your words were cleaned up locally. check the key in settings, keys & plans.";

    public static string? Sentence(Exception error) => error switch
    {
        // A vendor reached directly is only ever reached on the person's own key.
        TakePolishException { Kind: TakePolishErrorKind.Refused, Status: 401 or 403 } => OwnKeyRefusedSentence,
        _ => null,
    };

    private static readonly object ShownLock = new();
    /// <summary>Sentences already shown this session.</summary>
    private static readonly HashSet<string> ShownSentences = [];

    /// <summary>Returns the sentence when it is new to `alreadyShown` (and marks it shown), null otherwise.</summary>
    public static string? SentenceToShow(Exception error, ISet<string> alreadyShown)
    {
        if (Sentence(error) is not { } sentence || alreadyShown.Contains(sentence)) return null;
        alreadyShown.Add(sentence);
        return sentence;
    }

    /// <summary>Where a new sentence is shown: the companion's quiet caption. Replaceable (tests).</summary>
    public static Action<string> ShowNotice { get; set; } = sentence => OpenClickyConfiguration.ShowNotice?.Invoke(sentence);

    public static void Note(Exception error)
    {
        string? sentence;
        lock (ShownLock) sentence = SentenceToShow(error, ShownSentences);
        if (sentence is null) return;
        ShowNotice(sentence);
    }
}
