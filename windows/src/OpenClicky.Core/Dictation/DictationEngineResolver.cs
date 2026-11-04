// Ports `DictationEngineResolver` and `HeyClickyEditor` from Dictation/DictationTakeController.swift
// (the controller is DictationTakeController.cs): which engine can run and why not, the provider the
// chosen engine is built as, which model polishes takes and answers Hey Clicky, and whether a take's
// words may go to a model at all.

using OpenClicky.Core.Configuration;
using OpenClicky.Core.Providers;
using OpenClicky.Core.Speech;

namespace OpenClicky.Core.Dictation;

/// <summary>
/// Builds each engine's transcription provider (Core/Speech's DictationProviderFactory is the real
/// one; it needs the Platform's Windows speech recogniser for the offline engine).
/// </summary>
public interface IDictationProviderFactory
{
    /// <summary>Windows speech recognition, pinned to `preferredLocale` ("hi-IN") or the PC's language when null.</summary>
    IBuddyTranscriptionProvider MakeOffline(string? preferredLocale);
    /// <summary>The built-in Moonshine; `bareLanguageCode` (null = detect) is read when a take starts, for its unavailable reason.</summary>
    IBuddyTranscriptionProvider MakeMoonshine(Func<string?> bareLanguageCode);
    /// <summary>Parakeet; `bareLanguageCode` (null = detect) is read when a take starts, for its unavailable reason.</summary>
    IBuddyTranscriptionProvider MakeParakeet(Func<string?> bareLanguageCode);
    /// <summary>Sarvam, reading the dictation language when a take starts.</summary>
    IBuddyTranscriptionProvider MakeSarvam(Func<DictationLanguage> language);
    /// <summary>Upload transcription on an own OpenAI key; the bare language read when a take starts, null = detect.</summary>
    IBuddyTranscriptionProvider MakeOpenAI(Func<string?> bareLanguageCode);
}

/// <summary>Builds the transcription provider the settings ask for, and says why one cannot be used.</summary>
public static class DictationEngineResolver
{
    public static IBuddyTranscriptionProvider MakeProvider(DictationEngineChoice choice, DictationSettings settings, IDictationProviderFactory factory) =>
        choice switch
        {
            DictationEngineChoice.Offline => factory.MakeOffline(settings.Language.BareCode is null ? null : settings.Language.Code),
            DictationEngineChoice.Moonshine => factory.MakeMoonshine(() => settings.Language.BareCode),
            DictationEngineChoice.Parakeet => factory.MakeParakeet(() => settings.Language.BareCode),
            DictationEngineChoice.Sarvam => factory.MakeSarvam(() => settings.Language),
            // The styles page's language, read when a take starts; auto sends none so the model detects it.
            _ => factory.MakeOpenAI(() => settings.Language.BareCode),
        };

    /// <summary>Null when the engine can be used; otherwise one line saying what is missing.</summary>
    public static string? UnavailableReason(DictationEngineChoice choice) =>
        UnavailableReason(choice, ProviderCapabilities.Current().HasOwnOpenAIKey, OpenClickyConfiguration.Settings.SarvamKey);

    /// <summary>OpenAI hears on the person's own key.</summary>
    public static string? UnavailableReason(DictationEngineChoice choice, bool hasOpenAIKey, string? sarvamKey,
                                            bool? parakeetInstalled = null, Func<string?>? bareLanguageCode = null,
                                            bool? moonshineInstalled = null)
    {
        switch (choice)
        {
            case DictationEngineChoice.Offline:
                return null;
            case DictationEngineChoice.Moonshine:
                return MoonshineUnavailableReason(moonshineInstalled ?? MoonshineFacts.IsInstalled,
                    bareLanguageCode is null ? DictationSettings.StoredLanguage().BareCode : bareLanguageCode());
            case DictationEngineChoice.Parakeet:
                return ParakeetUnavailableReason(parakeetInstalled ?? ParakeetFacts.IsInstalled,
                    bareLanguageCode is null ? DictationSettings.StoredLanguage().BareCode : bareLanguageCode());
            case DictationEngineChoice.Sarvam:
                return SarvamUnavailableReason(sarvamKey);
            default:
                return hasOpenAIKey ? null : "needs your own openai key";
        }
    }

    /// <summary>
    /// Parakeet's half of `UnavailableReason`. Its provider reads the same function, so the provider
    /// and the resolver can never disagree about whether Parakeet can run.
    /// </summary>
    public static string? ParakeetUnavailableReason(bool isInstalled, string? bareLanguageCode)
    {
        if (!ParakeetFacts.Hears(bareLanguageCode)) return ParakeetLanguageNotHeardReason;
        return isInstalled ? null : $"needs its {ParakeetFacts.DownloadSizeText} download";
    }

    /// <summary>Installed but pinned to a language Parakeet does not hear: the island says this, not "download".</summary>
    public const string ParakeetLanguageNotHeardReason = "parakeet doesn't hear this language; pick auto-detect or a european language";

    /// <summary>Moonshine's half of `UnavailableReason`; its provider reads the same function.</summary>
    public static string? MoonshineUnavailableReason(bool isInstalled, string? bareLanguageCode)
    {
        if (!isInstalled) return MoonshineMissingReason;
        return MoonshineFacts.Hears(bareLanguageCode) ? null : MoonshineLanguageNotHeardReason;
    }

    /// <summary>A build without the bundled model (a plain dev build).</summary>
    public const string MoonshineMissingReason = "the built-in model isn't in this build; pick another engine";

    /// <summary>Pinned to a language other than English: the island says this.</summary>
    public const string MoonshineLanguageNotHeardReason = "moonshine only hears english; pick english, auto-detect or another engine";

    /// <summary>Sarvam's half of `UnavailableReason`; its provider reads the same function.</summary>
    public static string? SarvamUnavailableReason(string? sarvamKey) =>
        string.IsNullOrWhiteSpace(sarvamKey) ? "needs your sarvam key" : null;

    /// <summary>The ways to get a model, for a Hey Clicky edit or a history question asked with none set up.</summary>
    public const string HowToGetAModelSentence = "one of your own keys (settings → keys & plans)";

    /// <summary>
    /// The model that polishes takes and answers Hey Clicky: Sarvam with a key, else the person's
    /// own OpenAI, Anthropic, Groq, Gemini, Mistral, OpenRouter or xAI key, else none. A plan's CLI starts
    /// too slowly to tidy a take. (The Mac asks Apple's on-device model first; Windows has none.)
    /// </summary>
    public static ITakePolisher? MakePolisher() =>
        MakePolisher(OpenClickyConfiguration.Settings.SarvamKey, ProviderRouter.CurrentCredentials());

    public static ITakePolisher? MakePolisher(string? sarvamKey, ProviderCredentials credentials)
    {
        var trimmedSarvamKey = sarvamKey?.Trim() ?? "";
        if (trimmedSarvamKey.Length > 0) return new SarvamTakePolisher(new SarvamSpeechClient(trimmedSarvamKey));
        // An OpenAI key polishes on OpenAI, an Anthropic key alone on Claude Haiku at Anthropic, any
        // other answer key on its own vendor.
        if (credentials.OpenAIKey is not null) return new OpenAITakePolisher();
        if (credentials.AnthropicKey is { } anthropicKey) return new AnthropicTakePolisher(anthropicKey);
        return AnswerKeyTakePolisher.FirstAvailable(credentials);
    }

    /// <summary>
    /// Whether a take's words may go to a model: the switch, and — for the engines whose promise is
    /// that nothing leaves the PC — only when that was explicitly allowed. Every reader of "clean up
    /// my words with ai" asks here (the styles switch, the record page, the take, live typing, the
    /// smoke run), so the switch never shows one thing while takes do another.
    /// </summary>
    public static bool WantsModelPolish(DictationSettings settings) => WantsModelPolish(settings, settings.Engine);

    /// <summary>The same, for an engine other than the chosen one (the smoke run names its own).</summary>
    public static bool WantsModelPolish(DictationSettings settings, DictationEngineChoice engine)
    {
        if (!settings.PolishWithModel) return false;
        if (engine.IsOnDevice()) return settings.PolishOfflineTakes;
        return true;
    }
}

/// <summary>Hey Clicky: an instruction applied to a piece of text by the configured model.</summary>
public static class HeyClickyEditor
{
    public static string SystemPrompt(TakeFormattingContext context) =>
        "You edit text for someone who dictated an instruction. Apply the instruction to the text and return only the edited text: no preamble, no quotes, no explanation, no markdown fences. Keep the language and script of the text unless the instruction changes them. "
        + $"Style for this app ({context.Style.Name}): {context.Style.Rules}";

    public static string UserPrompt(string selection, string instruction) => $"Instruction: {instruction}\n\nText:\n{selection}";

    public static async Task<string> EditAsync(string selection, string instruction, TakeFormattingContext context, ITakePolisher polisher,
                                               CancellationToken cancellationToken = default)
    {
        var answer = await polisher.PolishAsync(SystemPrompt(context), UserPrompt(selection, instruction), cancellationToken).ConfigureAwait(false);
        var cleaned = TakeFormatter.UnwrapModelAnswer(answer);
        // Any model can make the edit, so the error names the one that did, not Sarvam's.
        if (cleaned.Length == 0) throw TakePolishException.EmptyAnswer(polisher.DisplayName);
        return cleaned;
    }
}
