//
//  AnswerVoicePlayer.swift
//  OpenClicky
//
//  Fetches the audio for one piece of a spoken answer and plays it. The voice is the one picked in
//  Settings → Clicky → Voice (`SpeechVoiceChoice`): a key's voice straight from its vendor, Kokoro or
//  this Mac, through `CloudVoiceSpeaker`. Each piece is fetched whole, not streamed; `SpeechQueue`
//  overlaps fetching the next piece with playing the current one, which is what makes the voice start early.
//

import AVFoundation
import Foundation

@MainActor
final class AnswerVoicePlayer {
    private let session: URLSession

    /// The audio player for the current TTS playback. Kept alive so the
    /// audio finishes playing even if the caller doesn't hold a reference.
    private var audioPlayer: AVAudioPlayer?
    /// The voice last logged, so app.log says when it changes rather than for every sentence.
    private var lastLoggedVoice: SpeechVoiceChoice?

    init() {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        self.session = URLSession(configuration: configuration)
    }

    /// The fetch step for one answer, in the voice `SpeechVoiceChoice.current()` names when the
    /// answer starts, so an answer stays in one voice. It is `SpeechQueue`'s fetch step.
    func makeAnswerFetcher() -> (String) async throws -> Data {
        let voice = SpeechVoiceChoice.current()
        if voice != lastLoggedVoice {
            AppLog.append("voice: \(voice.rawValue)")
            lastLoggedVoice = voice
        }
        return { [session] pieceText in
            try await CloudVoiceSpeaker.audio(for: pieceText, voice: voice, session: session)
        }
    }

    /// The audio for `text` as a one-piece answer, without playing it.
    func fetchAudio(for text: String) async throws -> Data {
        try await makeAnswerFetcher()(text)
    }

    /// Plays `data` and returns when it has finished (or was stopped). Cancelling the calling task
    /// stops the audio.
    func playToCompletion(_ data: Data) async throws {
        try Task.checkCancellation()
        let player = try AVAudioPlayer(data: data)
        let finishObserver = AudioPlayerFinishObserver()
        player.delegate = finishObserver
        self.audioPlayer = player
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                finishObserver.onFinish = { continuation.resume() }
                if !player.play() { finishObserver.finishOnce() }
            }
        } onCancel: {
            Task { @MainActor in
                player.stop()
                finishObserver.finishOnce()
            }
        }
        if audioPlayer === player { audioPlayer = nil }
        try Task.checkCancellation()
    }

    /// Whether TTS audio is currently playing back.
    var isPlaying: Bool {
        audioPlayer?.isPlaying ?? false
    }

    /// Stops any in-progress playback immediately.
    func stopPlayback() {
        if let audioPlayer, let finishObserver = audioPlayer.delegate as? AudioPlayerFinishObserver {
            audioPlayer.stop()
            finishObserver.finishOnce()
        } else {
            audioPlayer?.stop()
        }
        audioPlayer = nil
    }
}

/// Tells `playToCompletion` (and RecordedVoice) when an AVAudioPlayer has finished, exactly once
/// (natural end, decode error, or a stop).
final class AudioPlayerFinishObserver: NSObject, AVAudioPlayerDelegate {
    var onFinish: (() -> Void)?

    func finishOnce() {
        let finish = onFinish
        onFinish = nil
        finish?()
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        DispatchQueue.main.async { self.finishOnce() }
    }

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        DispatchQueue.main.async { self.finishOnce() }
    }
}
