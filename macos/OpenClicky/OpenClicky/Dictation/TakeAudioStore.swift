//
//  TakeAudioStore.swift
//  OpenClicky
//
//  "retry failed dictations": the audio of a take that a network engine could not finish is kept
//  on this Mac as a WAV, so the take can be heard again once the key, the credits or the network
//  are back. Bounded (100 takes, 200 MB); nothing is kept once a take succeeds or is cancelled, and
//  nothing is kept at all when the setting is off.
//

import AVFoundation
import Foundation
import os

final class TakeAudioStore: @unchecked Sendable {
    static let defaultDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/OpenClicky/TakeAudio")
    static let maxRetainedTakes = 100
    static let maxRetainedBytes: UInt64 = 200_000_000
    /// A take longer than this is cut off in memory (ten minutes of 16 kHz PCM16 is 19 MB).
    static let maxCaptureBytes = 16_000 * 2 * 600

    let directoryURL: URL
    private let converter = BuddyPCM16AudioConverter(targetSampleRate: Double(SarvamSpeechClient.sampleRate))
    private let capture = OSAllocatedUnfairLock(initialState: Data())

    init(directoryURL: URL = TakeAudioStore.defaultDirectoryURL) {
        self.directoryURL = directoryURL
    }

    // MARK: capturing the take in progress

    func beginCapture() {
        capture.withLock { $0 = Data() }
    }

    /// Called on the render thread.
    func append(_ buffer: AVAudioPCMBuffer) {
        guard let pcm = converter.convertToPCM16Data(from: buffer) else { return }
        capture.withLock { data in
            guard data.count < Self.maxCaptureBytes else { return }
            data.append(pcm)
        }
    }

    /// The take's audio so far, as PCM16 mono 16 kHz, and forgets it.
    func endCapture() -> Data {
        capture.withLock { data in
            defer { data = Data() }
            return data
        }
    }

    // MARK: retaining failed takes

    func retain(takeID: UUID, pcm16: Data) throws {
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let wav = BuddyWAVFileBuilder.buildWAVData(fromPCM16MonoAudio: pcm16, sampleRate: SarvamSpeechClient.sampleRate)
        try wav.write(to: url(for: takeID), options: .atomic)
        pruneIfNeeded()
    }

    func url(for takeID: UUID) -> URL {
        directoryURL.appendingPathComponent("\(takeID.uuidString).wav")
    }

    func hasAudio(for takeID: UUID) -> Bool {
        FileManager.default.fileExists(atPath: url(for: takeID).path)
    }

    func discard(takeID: UUID) {
        try? FileManager.default.removeItem(at: url(for: takeID))
    }

    func discardAll() {
        try? FileManager.default.removeItem(at: directoryURL)
    }

    /// Oldest first beyond the caps.
    func pruneIfNeeded() {
        guard let entries = try? FileManager.default.contentsOfDirectory(at: directoryURL, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]) else { return }
        var files = entries.compactMap { url -> (URL, Date, UInt64)? in
            guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]) else { return nil }
            return (url, values.contentModificationDate ?? .distantPast, UInt64(values.fileSize ?? 0))
        }
        .sorted { $0.1 < $1.1 }
        var total = files.reduce(0) { $0 + $1.2 }
        while files.count > Self.maxRetainedTakes || total > Self.maxRetainedBytes, let oldest = files.first {
            try? FileManager.default.removeItem(at: oldest.0)
            total -= oldest.2
            files.removeFirst()
        }
    }

    /// Why feeding a recording to an engine gave no words; the smoke run says each differently.
    enum RecordedAudioTranscriptionError: LocalizedError {
        /// The file could not be opened or decoded.
        case unreadableRecording(String)
        /// The engine refused to open a session (no key, no account, not downloaded).
        case engineDidNotOpen(String)
        /// The engine took the audio but sent no final words in time.
        case engineDidNotAnswer

        var errorDescription: String? {
            switch self {
            case .unreadableRecording(let reason): return reason
            case .engineDidNotOpen(let reason): return reason
            case .engineDidNotAnswer: return "the engine did not answer in time"
            }
        }
    }

    /// Feeds a recording (a retained take's WAV, or the smoke run's file) to a provider as if it
    /// were the microphone and returns the final text. Slices are paced like a microphone for the
    /// streaming engines; a retry goes faster than real time, the smoke run at real time.
    static func transcribe(fileURL: URL, provider: any BuddyTranscriptionProvider, keyterms: [String],
                           sliceSeconds: Double = 0.25, pauseBetweenSlicesNanoseconds: UInt64 = 60_000_000,
                           onTranscriptUpdate: @escaping @Sendable (String) -> Void = { _ in }) async throws -> String {
        let file: AVAudioFile
        let buffer: AVAudioPCMBuffer
        do {
            file = try AVAudioFile(forReading: fileURL)
            guard let readBuffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else {
                throw TakeStoreError(message: "could not read the recorded audio")
            }
            try file.read(into: readBuffer)
            buffer = readBuffer
        } catch {
            throw RecordedAudioTranscriptionError.unreadableRecording(error.localizedDescription)
        }
        return try await withCheckedThrowingContinuation { continuation in
            let resumed = OSAllocatedUnfairLock(initialState: false)
            let openSession = OSAllocatedUnfairLock<(any BuddyStreamingTranscriptionSession)?>(initialState: nil)
            func finish(_ result: Result<String, Error>) {
                let first = resumed.withLock { done -> Bool in defer { done = true }; return !done }
                guard first else { return }
                // Whatever ended it, the engine's session goes with it (a timeout would otherwise leak it).
                openSession.withLock { $0?.cancel(); $0 = nil }
                continuation.resume(with: result)
            }
            Task {
                let session: any BuddyStreamingTranscriptionSession
                do {
                    session = try await provider.startStreamingSession(
                        keyterms: keyterms,
                        onTranscriptUpdate: onTranscriptUpdate,
                        onFinalTranscriptReady: { text in finish(.success(text)) },
                        onError: { error in finish(.failure(error)) })
                } catch {
                    finish(.failure(RecordedAudioTranscriptionError.engineDidNotOpen(error.localizedDescription)))
                    return
                }
                openSession.withLock { $0 = session }
                let sliceFrames = AVAudioFrameCount(file.processingFormat.sampleRate * sliceSeconds)
                var offset: AVAudioFrameCount = 0
                while offset < buffer.frameLength {
                    let count = min(sliceFrames, buffer.frameLength - offset)
                    guard let slice = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: count) else { break }
                    for channel in 0..<Int(buffer.format.channelCount) {
                        if let from = buffer.floatChannelData?[channel], let to = slice.floatChannelData?[channel] {
                            to.update(from: from + Int(offset), count: Int(count))
                        } else if let from = buffer.int16ChannelData?[channel], let to = slice.int16ChannelData?[channel] {
                            to.update(from: from + Int(offset), count: Int(count))
                        }
                    }
                    slice.frameLength = count
                    session.appendAudioBuffer(slice)
                    offset += count
                    try? await Task.sleep(nanoseconds: pauseBetweenSlicesNanoseconds)
                }
                session.requestFinalTranscript()
                try? await Task.sleep(nanoseconds: UInt64((session.finalTranscriptFallbackDelaySeconds + 20) * 1_000_000_000))
                finish(.failure(RecordedAudioTranscriptionError.engineDidNotAnswer))
            }
        }
    }
}
