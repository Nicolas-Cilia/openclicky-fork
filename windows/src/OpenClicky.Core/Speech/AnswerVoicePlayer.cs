// Ports AnswerVoicePlayer.swift: fetches the audio for one piece of a spoken answer and plays it.
// The voice is the one picked in Settings → Clicky → Voice (SpeechVoiceChoice): a key's voice
// straight from its vendor, or Kokoro or this PC through CloudVoiceSpeaker. Each piece is fetched
// whole, not streamed; SpeechQueue overlaps fetching the next piece with playing the current one,
// which is what makes the voice start early.

using OpenClicky.Core.Configuration;
using OpenClicky.Core.Platform;

namespace OpenClicky.Core.Speech;

public sealed class AnswerVoicePlayer(IAudioPlayer audioPlayer, SpeechVoiceServices? services = null)
{
    private readonly object voiceLogLock = new();
    /// <summary>The voice last logged, so app.log says when it changes rather than for every sentence.</summary>
    private SpeechVoiceChoice? lastLoggedVoice;

    /// <summary>The voice that speaks now; injectable for tests.</summary>
    public Func<SpeechVoiceChoice> CurrentVoice { get; init; } = () => SpeechVoiceChoices.Current(services);

    /// <summary>
    /// The fetch step for one answer, in the voice <see cref="CurrentVoice"/> names when the answer
    /// starts, so an answer stays in one voice. SpeechQueue calls it for each piece.
    /// </summary>
    public Func<string, CancellationToken, Task<byte[]>> MakeAnswerFetcher()
    {
        var voice = CurrentVoice();
        lock (voiceLogLock)
        {
            if (voice != lastLoggedVoice)
            {
                AppLog.Write($"voice: {voice.RawValue()}");
                lastLoggedVoice = voice;
            }
        }
        return (pieceText, cancellationToken) => CloudVoiceSpeaker.AudioAsync(pieceText, voice, services: services, cancellationToken: cancellationToken);
    }

    /// <summary>
    /// The audio for <paramref name="text"/> as a one-piece answer, without playing it, in the voice <see cref="CurrentVoice"/>
    /// names (a pointing caption, the voice preview).
    /// </summary>
    public Task<byte[]> FetchAudioAsync(string text, CancellationToken cancellationToken = default) =>
        MakeAnswerFetcher()(text, cancellationToken);

    /// <summary>Plays <paramref name="audio"/> and returns when it has finished (or was stopped). Cancelling stops the audio.</summary>
    public async Task PlayToCompletionAsync(byte[] audio, CancellationToken cancellationToken = default)
    {
        cancellationToken.ThrowIfCancellationRequested();
        await audioPlayer.PlayToCompletionAsync(audio, cancellationToken).ConfigureAwait(false);
        cancellationToken.ThrowIfCancellationRequested();
    }

    /// <summary>Whether answer audio is playing.</summary>
    public bool IsPlaying => audioPlayer.IsPlaying;

    /// <summary>Stops any playback at once.</summary>
    public void StopPlayback() => audioPlayer.StopPlayback();
}
