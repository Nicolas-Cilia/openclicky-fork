// Ports SpokenStretchesTests.swift and TranscriptionEchoTests.swift, plus the pure parts of the
// transcription providers: the PCM16/WAV helpers and silence gate, the provider factory, Sarvam's upload pieces, and the offline engine's languages.

using System.Buffers.Binary;
using OpenClicky.Core.Platform;
using OpenClicky.Core.Speech;

namespace OpenClicky.Core.Tests.Speech;

public class SpokenStretchesTests
{
    [Fact]
    public void AStretchWithoutAFullStopGetsOneBeforeTheNextSentence() =>
        Assert.Equal("The weather is lovely today. I am going to the market", SpokenStretches.Joined("The weather is lovely today", "I am going to the market"));

    [Fact]
    public void PunctuationTheRecogniserWroteIsKept() =>
        Assert.Equal("Is it raining? Take an umbrella.", SpokenStretches.Joined("Is it raining?", "Take an umbrella."));

    [Fact]
    public void AStretchThatContinuesTheSentenceIsJoinedWithASpace() =>
        Assert.Equal("I went to the shop and bought milk", SpokenStretches.Joined("I went to the shop", "and bought milk"));

    [Fact]
    public void EmptySidesLeaveTheOther()
    {
        Assert.Equal("Hello", SpokenStretches.Joined("", "Hello"));
        Assert.Equal("Hello.", SpokenStretches.Joined("Hello. ", "  "));
    }
}

public class TranscriptionEchoTests
{
    private const string Prompt = "This is a short push-to-talk transcript for a coding and product app. Expect product names, technical terms, and app-specific vocabulary such as: OpenClicky, Codex, Claude, Anthropic, OpenAI, SwiftUI, Xcode, Vercel, Next.js, localhost.";

    [Fact]
    public void VerbatimPromptIsAnEcho() => Assert.True(OpenAIAudioTranscriptionProvider.LooksLikeEchoedPrompt(Prompt, Prompt));

    [Fact]
    public void NearVerbatimPromptIsAnEcho()
    {
        const string echoed = "This is a short push to talk transcript for a coding and product app, expect product names and technical terms such as OpenClicky, Codex, Claude.";
        Assert.True(OpenAIAudioTranscriptionProvider.LooksLikeEchoedPrompt(echoed, Prompt));
    }

    [Fact]
    public void RealSpeechMentioningKeytermsIsKept()
    {
        const string spoken = "Please open the OpenClicky settings and turn on hands-free mode before I deploy to Vercel.";
        Assert.False(OpenAIAudioTranscriptionProvider.LooksLikeEchoedPrompt(spoken, Prompt));
    }

    [Fact]
    public void ShortTranscriptsAndNoPromptAreKept()
    {
        Assert.False(OpenAIAudioTranscriptionProvider.LooksLikeEchoedPrompt("OpenClicky Codex Claude", Prompt));
        Assert.False(OpenAIAudioTranscriptionProvider.LooksLikeEchoedPrompt(Prompt, null));
    }

    [Fact]
    public void ThePromptNamesTheKeytermsAndIsLeftOutWithoutAny()
    {
        var keyterms = BuddyDictationManager.BuildTranscriptionKeyterms([]);
        Assert.Equal(Prompt, OpenAIAudioTranscriptionProvider.TranscriptionPromptText(keyterms));
        Assert.Null(OpenAIAudioTranscriptionProvider.TranscriptionPromptText([" ", ""]));
    }

    [Fact]
    public void TheTranscriptIsReadFromTheReply()
    {
        Assert.Equal("hello", OpenAIAudioTranscriptionProvider.ParseTranscript("""{"text":"  hello \n"}"""u8.ToArray()));
        Assert.Null(OpenAIAudioTranscriptionProvider.ParseTranscript("not json"u8.ToArray()));
    }
}

public class BuddyAudioConversionTests
{
    [Fact]
    public void TheWavHeaderDescribesSixteenBitMono()
    {
        var wav = BuddyWAVFileBuilder.BuildWavData(new byte[320], 16_000);
        Assert.Equal(44 + 320, wav.Length);
        Assert.Equal("RIFF"u8.ToArray(), wav[..4]);
        Assert.Equal(36 + 320, BinaryPrimitives.ReadInt32LittleEndian(wav.AsSpan(4)));
        Assert.Equal("WAVEfmt "u8.ToArray(), wav[8..16]);
        Assert.Equal(1, BinaryPrimitives.ReadInt16LittleEndian(wav.AsSpan(20)));
        Assert.Equal(1, BinaryPrimitives.ReadInt16LittleEndian(wav.AsSpan(22)));
        Assert.Equal(16_000, BinaryPrimitives.ReadInt32LittleEndian(wav.AsSpan(24)));
        Assert.Equal(32_000, BinaryPrimitives.ReadInt32LittleEndian(wav.AsSpan(28)));
        Assert.Equal(2, BinaryPrimitives.ReadInt16LittleEndian(wav.AsSpan(32)));
        Assert.Equal(16, BinaryPrimitives.ReadInt16LittleEndian(wav.AsSpan(34)));
        Assert.Equal("data"u8.ToArray(), wav[36..40]);
        Assert.Equal(320, BinaryPrimitives.ReadInt32LittleEndian(wav.AsSpan(40)));
    }

    [Fact]
    public void TheSilenceGateMeasuresTheLoudestSample()
    {
        var pcm = new byte[6];
        BinaryPrimitives.WriteInt16LittleEndian(pcm.AsSpan(0), 120);
        BinaryPrimitives.WriteInt16LittleEndian(pcm.AsSpan(2), -399);
        Assert.Equal(399, PCM16SilenceGate.PeakMagnitude(pcm));
        Assert.True(PCM16SilenceGate.IsSilent(399));
        Assert.False(PCM16SilenceGate.IsSilent(400));
        BinaryPrimitives.WriteInt16LittleEndian(pcm.AsSpan(4), short.MinValue);
        Assert.Equal(short.MaxValue, PCM16SilenceGate.PeakMagnitude(pcm));
    }

    [Fact]
    public void AudioAtTheTargetRateIsPassedThrough()
    {
        var converter = new BuddyPCM16AudioConverter(16_000);
        var frame = TestAudio.Tone(160);
        Assert.Same(frame.Pcm16, converter.ConvertToPcm16(frame));
    }

    [Fact]
    public void FortyEightKilohertzBecomesSixteenWithoutLosingSamplesAtTheJoins()
    {
        var converter = new BuddyPCM16AudioConverter(16_000);
        var total = 0;
        for (var frameIndex = 0; frameIndex < 10; frameIndex++)
        {
            var frame = TestAudio.Tone(481, sampleRate: 48_000);
            total += converter.ConvertToPcm16(frame)!.Length / 2;
        }
        // 4,810 input samples at a third of the rate: 1,603 or 1,604, never a frame's worth short.
        Assert.InRange(total, 1_602, 1_604);
    }

    [Fact]
    public void FloatSamplesAreClippedNotWrapped()
    {
        var pcm = BuddyPCM16AudioConverter.FloatToPcm16([0f, 2f, -2f]);
        Assert.Equal(short.MaxValue, BinaryPrimitives.ReadInt16LittleEndian(pcm.AsSpan(2)));
        Assert.Equal(-short.MaxValue, BinaryPrimitives.ReadInt16LittleEndian(pcm.AsSpan(4)));
    }
}

public class BuddyTranscriptionProviderFactoryTests
{
    private sealed class FakeProvider(string name, bool configured) : IBuddyTranscriptionProvider
    {
        public string DisplayName => name;
        public bool RequiresSpeechRecognitionPermission => false;
        public bool IsConfigured => configured;
        public string? UnavailableExplanation => configured ? null : "no";
        public Task<IBuddyStreamingTranscriptionSession> StartStreamingSessionAsync(IReadOnlyList<string> keyterms, Action<string> onTranscriptUpdate,
            Action<string> onFinalTranscriptReady, Action<Exception> onError, CancellationToken cancellationToken = default) => throw new NotSupportedException();
    }

    private static string Resolve(string? stored, bool configured, bool openAI) =>
        BuddyTranscriptionProviderFactory.ResolveProvider(stored, configured, new FakeProvider("openai", openAI),
            () => new FakeProvider("offline", true)).DisplayName;

    [Fact]
    public void AStoredPreferenceWinsWhenItCanRun()
    {
        Assert.Equal("offline", Resolve("apple", true, true));
        Assert.Equal("openai", Resolve("openai", true, true));
    }

    [Fact]
    public void APreferenceThatCannotRunFallsBackToOffline()
    {
        Assert.Equal("offline", Resolve("openai", true, false));
        Assert.Equal("offline", Resolve("openai", false, false));
    }

    [Fact]
    public void APreferenceForARemovedEngineReadsAsNone()
    {
        Assert.Equal("openai", Resolve("assemblyai", true, true));
        Assert.Equal("offline", Resolve("assemblyai", true, false));
    }

    [Fact]
    public void WithoutAPreferenceAKeyMeansUploadTranscription()
    {
        Assert.Equal("openai", Resolve(null, true, true));
        Assert.Equal("openai", Resolve(null, false, true));
        Assert.Equal("offline", Resolve(null, false, false));
    }
}

public class SarvamUploadTests
{
    [Fact]
    public void ALongTakeGoesUpInWholePiecesTheLastShorter()
    {
        var pcm = new byte[16_000 * 2 * 60];
        var pieces = SarvamUploadSession.Split(pcm, 16_000, SarvamUploadSession.PieceSeconds);
        Assert.Equal(3, pieces.Count);
        Assert.Equal(16_000 * 2 * 28, pieces[0].Length);
        Assert.Equal(16_000 * 2 * 28, pieces[1].Length);
        Assert.Equal(16_000 * 2 * 4, pieces[2].Length);
        Assert.Empty(SarvamUploadSession.Split([], 16_000, 28));
    }
}

public class WindowsSpeechTranscriptionTests
{
    [Fact]
    public void LanguagesAreTriedPinnedThenReplyThenEnglishWithoutRepeats()
    {
        Assert.Equal(["hi-IN", "hi", "en-US"], WindowsSpeechTranscriptionProvider.LanguageTagsToTry(null, "hi-IN", "hi"));
        Assert.Equal(["ta-IN", "en-IN", "en", "en-US"], WindowsSpeechTranscriptionProvider.LanguageTagsToTry("ta-IN", "en-IN", "en"));
        Assert.Equal(["en-US", "en"], WindowsSpeechTranscriptionProvider.LanguageTagsToTry(" ", "en-US", "en"));
    }

    private sealed class FakeOfflineSession : IOfflineSpeechSession
    {
        public event Action<string>? TranscriptUpdated;
        public event Action<Exception>? Error;
        public string LanguageTag => "en-US";
        public string FinalText { get; set; } = "";
        public bool WasCancelled { get; private set; }
        public bool ThrowsOnCancel { get; set; }
        public void Update(string text) => TranscriptUpdated?.Invoke(text);
        public void Fail(Exception error) => Error?.Invoke(error);
        public Task<string> StopAsync() => Task.FromResult(FinalText);
        public void Cancel()
        {
            WasCancelled = true;
            if (ThrowsOnCancel) throw new System.Runtime.InteropServices.COMException("already stopped", unchecked((int)0x80131509));
        }
        public ValueTask DisposeAsync()
        {
            if (ThrowsOnCancel) throw new System.Runtime.InteropServices.COMException("already stopped", unchecked((int)0x80131509));
            return ValueTask.CompletedTask;
        }
    }

    private sealed class FakeRecognizer(FakeOfflineSession session) : IOfflineSpeechRecognizer
    {
        public OfflineSpeechOptions? LastOptions { get; private set; }
        public Exception? StartFailure { get; set; }
        public bool UsesDefaultMicrophoneOnly => true;
        public IReadOnlyList<string> SupportedLanguages() => ["en-US"];
        public Task<IOfflineSpeechSession> StartAsync(OfflineSpeechOptions options, CancellationToken cancellationToken = default)
        {
            LastOptions = options;
            return StartFailure is { } failure ? Task.FromException<IOfflineSpeechSession>(failure) : Task.FromResult<IOfflineSpeechSession>(session);
        }
    }

    /// <summary>The recogniser's cancel and dispose throw once the session has stopped by itself; neither may reach the take.</summary>
    [Fact]
    public async Task ACancelThatThrowsInTheRecogniserNeverEscapes()
    {
        var offline = new FakeOfflineSession { ThrowsOnCancel = true };
        var log = new TranscriptLog();
        var provider = new WindowsSpeechTranscriptionProvider(new FakeRecognizer(offline));
        var session = await provider.StartStreamingSessionAsync([], log.Partial, log.Final, log.Error);
        Assert.Null(Record.Exception(session.Cancel));
        Assert.True(offline.WasCancelled);
        Assert.Null(Record.Exception(session.Cancel));
    }

    [Fact]
    public async Task TheStoppedRecogniserGivesTheFinalWords()
    {
        var offline = new FakeOfflineSession { FinalText = "Hello there." };
        var log = new TranscriptLog();
        var provider = new WindowsSpeechTranscriptionProvider(new FakeRecognizer(offline), () => "en-GB");
        var session = await provider.StartStreamingSessionAsync([], log.Partial, log.Final, log.Error);
        offline.Update("Hello");
        session.RequestFinalTranscript();
        Assert.Equal("Hello there.", await log.WaitForFinalAsync());
        Assert.Equal(["Hello"], log.Partials);
    }

    [Fact]
    public async Task AnErrorAfterReleaseWithWordsHeardDeliversThem()
    {
        var offline = new FakeOfflineSession();
        var log = new TranscriptLog();
        var recognizer = new FakeRecognizer(offline);
        var session = await new WindowsSpeechTranscriptionProvider(recognizer).StartStreamingSessionAsync([], log.Partial, log.Final, log.Error);
        offline.Update("words so far");
        offline.Fail(new InvalidOperationException("audio problem"));
        // Before release an error is the take's error.
        Assert.Single(log.Errors);
        Assert.Contains("en-US", recognizer.LastOptions!.FallbackLanguageTags.Prepend(recognizer.LastOptions.LanguageTag!));
        session.Cancel();
        Assert.True(offline.WasCancelled);
    }

    [Fact]
    public async Task AMissingLanguagePackSaysSoInWords()
    {
        var recognizer = new FakeRecognizer(new FakeOfflineSession())
        {
            StartFailure = new OfflineSpeechException(OfflineSpeechFailure.LanguageNotInstalled, "add the english speech pack in settings."),
        };
        var error = await Assert.ThrowsAsync<TranscriptionProviderException>(() =>
            new WindowsSpeechTranscriptionProvider(recognizer).StartStreamingSessionAsync([], _ => { }, _ => { }, _ => { }));
        Assert.Equal("add the english speech pack in settings.", error.Message);
    }
}
