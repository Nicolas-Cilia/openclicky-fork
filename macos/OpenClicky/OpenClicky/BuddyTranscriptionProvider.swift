//
//  BuddyTranscriptionProvider.swift
//  OpenClicky
//
//  Shared protocol surface for voice transcription backends.
//

import AVFoundation
import Foundation

protocol BuddyStreamingTranscriptionSession: AnyObject {
    var finalTranscriptFallbackDelaySeconds: TimeInterval { get }
    func appendAudioBuffer(_ audioBuffer: AVAudioPCMBuffer)
    func requestFinalTranscript()
    func cancel()
}

protocol BuddyTranscriptionProvider {
    var displayName: String { get }
    var requiresSpeechRecognitionPermission: Bool { get }
    var isConfigured: Bool { get }
    var unavailableExplanation: String? { get }

    func startStreamingSession(
        keyterms: [String],
        onTranscriptUpdate: @escaping (String) -> Void,
        onFinalTranscriptReady: @escaping (String) -> Void,
        onError: @escaping (Error) -> Void
    ) async throws -> any BuddyStreamingTranscriptionSession
}

enum BuddyTranscriptionProviderFactory {
    static func makeDefaultProvider() -> any BuddyTranscriptionProvider {
        let provider = resolveProvider()
        print("🎙️ Transcription: using \(provider.displayName)")
        return provider
    }

    /// ~/.openclicky/shell.json `transcriptionProvider` "apple" keeps it on this Mac; otherwise an
    /// own OpenAI key hears, and without one this Mac does.
    private static func resolveProvider() -> any BuddyTranscriptionProvider {
        if OpenClickyConfiguration.settings.transcriptionProvider?.lowercased() == "apple" {
            return AppleSpeechTranscriptionProvider()
        }
        let openAIProvider = OpenAIAudioTranscriptionProvider()
        return openAIProvider.isConfigured ? openAIProvider : AppleSpeechTranscriptionProvider()
    }
}
