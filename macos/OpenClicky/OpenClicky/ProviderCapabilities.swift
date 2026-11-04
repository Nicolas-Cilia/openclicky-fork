//
//  ProviderCapabilities.swift
//  OpenClicky
//
//  One answer to "what can this Mac use?", so every lane asks the same question. Realtime needs an
//  own OpenAI or Gemini key; agent tasks need an own OpenAI key or the Codex plan switched on and
//  signed in; speech is heard on this Mac unless an own OpenAI key can hear it.
//

import Foundation

struct ProviderCapabilities: Equatable {
    var hasOwnOpenAIKey: Bool
    /// A key that runs realtime voice: OpenAI or Gemini.
    var hasRealtimeKey: Bool
    /// The Codex plan is switched on and `codex login` has signed in with ChatGPT.
    var hasCodexPlan: Bool
    /// The Codex plan has run out; agent tasks wait for this time.
    var codexPausedUntil: Date? = nil

    /// The sign-in `codex login` writes, which the CLI's agent runs use (agent/src/codexHome.ts).
    nonisolated static var codexAuthFile: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex/auth.json")
    }

    static func current(settings: OpenClickyShellSettings = OpenClickyConfiguration.settings,
                        codexSignedIn: () -> Bool = { FileManager.default.fileExists(atPath: codexAuthFile.path) }) -> ProviderCapabilities {
        let credentials = ProviderCredentials(settings: settings)
        return ProviderCapabilities(
            hasOwnOpenAIKey: credentials.openAIKey != nil,
            hasRealtimeKey: RealtimeVoiceProvider.hasOwnKey(credentials),
            hasCodexPlan: credentials.codexPlanOn && codexSignedIn(),
            codexPausedUntil: PlanAvailability.shared.exhaustedUntil(.codexPlan))
    }

    var usesRealtime: Bool { hasRealtimeKey }
    var usesAgent: Bool { hasOwnOpenAIKey || (hasCodexPlan && codexPausedUntil == nil) }
    /// What to say instead of running an agent task while Codex has run out.
    var agentPausedSentence: String? {
        guard !hasOwnOpenAIKey, hasCodexPlan, let codexPausedUntil else { return nil }
        return "codex has hit its limit, so agent tasks are paused until \(codexPausedUntil.formatted(date: .omitted, time: .shortened))."
    }
    var hearsOnDevice: Bool { !hasOwnOpenAIKey }
}
