//
//  ProviderRoute.swift
//  OpenClicky
//
//  A capability the person has a key for goes straight to that vendor with their key; questions can
//  also go through a plan's own CLI. Every caller asks `ProviderRouter` the same question, so there is
//  one place that decides, and one log line per change of route.
//

import Foundation

/// What a call is for, by the key that can pay for it.
nonisolated enum ProviderCapability: String, CaseIterable, Sendable {
    /// Claude: the ⌃⌥ ask lane (/chat) and screen grounding. Anthropic key.
    case claude
    /// OpenAI chat completions: the take clean-up on an own key. OpenAI key.
    case openAIChat
    /// OpenAI speech on an own key. No call asks the router for it any
    /// more: who speaks the answers is `SpeechVoiceChoice` (SpeechVoices.swift), which also covers
    /// the other voice keys, Kokoro and this Mac. Kept because the route table is tested per key.
    case speech
    /// Upload speech-to-text OpenAI key.
    case transcription
    /// Realtime voice: the client secret. OpenAI key.
    case realtime
}

nonisolated enum ProviderRoute: Equatable, Sendable {
    case openAIDirect
    case anthropicDirect
    /// Questions answered by another source (AnswerProvider.swift): an OpenAI-compatible key,
    /// Gemini, or a Claude Code / Codex plan. Only ever the route for `.claude`.
    case answerProvider(AnswerSource)
    /// No key for this: the sentence says what is missing.
    case unavailable(String)

    var logName: String {
        switch self {
        case .openAIDirect: return "openai, own key"
        case .anthropicDirect: return "anthropic, own key"
        case .answerProvider(let source): return source.displayName
        case .unavailable: return "unavailable"
        }
    }

    /// The source a `.claude` route answers with, for saying who answered; nil when nothing can.
    var answeringSource: AnswerSource? {
        switch self {
        case .anthropicDirect: return .anthropic
        case .answerProvider(let source): return source
        case .openAIDirect, .unavailable: return nil
        }
    }

    var unavailableSentence: String? {
        if case .unavailable(let sentence) = self { return sentence }
        return nil
    }
}

/// The keys a route is decided on. Values only: no key ever goes into a log.
nonisolated struct ProviderCredentials: Equatable, Sendable {
    var openAIKey: String?
    var anthropicKey: String?
    /// The other keys that can answer questions, and the plans the person switched on.
    var openRouterKey: String?
    var geminiKey: String?
    var groqKey: String?
    var mistralKey: String?
    var xaiKey: String?
    var claudeCodePlanOn = false
    var codexPlanOn = false
    /// Who should answer, when the person picked one (nil: automatic).
    var preferredAnswerSource: AnswerSource?
    /// Which plan takes over when the default runs out: nil is the other linked plan, `noBackup` none.
    var backupChoice: String?
    /// The plans that have run out for now (`PlanAvailability`).
    var exhaustedPlans: Set<AnswerSource> = []
    static let noBackup = "none"

    init(openAIKey: String?, anthropicKey: String?,
         openRouterKey: String? = nil, geminiKey: String? = nil, groqKey: String? = nil,
         mistralKey: String? = nil, xaiKey: String? = nil,
         claudeCodePlanOn: Bool = false, codexPlanOn: Bool = false, preferredAnswerSource: AnswerSource? = nil) {
        func cleaned(_ value: String?) -> String? {
            let trimmed = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        self.openAIKey = cleaned(openAIKey)
        self.anthropicKey = cleaned(anthropicKey)
        self.openRouterKey = cleaned(openRouterKey)
        self.geminiKey = cleaned(geminiKey)
        self.groqKey = cleaned(groqKey)
        self.mistralKey = cleaned(mistralKey)
        self.xaiKey = cleaned(xaiKey)
        self.claudeCodePlanOn = claudeCodePlanOn
        self.codexPlanOn = codexPlanOn
        self.preferredAnswerSource = preferredAnswerSource
    }

    init(settings: OpenClickyShellSettings) {
        self.init(openAIKey: settings.openaiApiKey, anthropicKey: settings.anthropicApiKey,
                  openRouterKey: settings.openRouterApiKey, geminiKey: settings.geminiApiKey, groqKey: settings.groqApiKey,
                  mistralKey: settings.mistralApiKey, xaiKey: settings.xaiApiKey,
                  claudeCodePlanOn: settings.useClaudeCodePlan == true, codexPlanOn: settings.useCodexPlan == true,
                  preferredAnswerSource: settings.answerSource.flatMap(AnswerSource.init(rawValue:)))
        backupChoice = settings.backupAnswerSource
    }

    /// The key for an API source, nil for the plans.
    func key(for source: AnswerSource) -> String? {
        switch source {
        case .anthropic: return anthropicKey
        case .openAI: return openAIKey
        case .openRouter: return openRouterKey
        case .gemini: return geminiKey
        case .groq: return groqKey
        case .mistral: return mistralKey
        case .xai: return xaiKey
        case .claudeCodePlan, .codexPlan: return nil
        }
    }

    /// Whether `source` can answer with what is set up: its key or its plan switched on.
    func canAnswer(with source: AnswerSource) -> Bool {
        switch source {
        case .claudeCodePlan: return claudeCodePlanOn
        case .codexPlan: return codexPlanOn
        default: return key(for: source) != nil
        }
    }

    /// The sources that can answer, in the order "automatic" tries them: own keys (Anthropic first,
    /// then OpenRouter, which reaches the most models), then the plans switched on.
    var answerSourcesInOrder: [AnswerSource] {
        let order: [AnswerSource] = [.claudeCodePlan, .codexPlan, .anthropic, .openRouter, .openAI, .gemini, .xai, .mistral, .groq]
        return order.filter(canAnswer(with:))
    }

    /// Who answers when nothing has run out: the person's pick if it is set up, else the first in order.
    var primaryAnswerSource: AnswerSource? {
        preferredAnswerSource.flatMap { canAnswer(with: $0) ? $0 : nil } ?? answerSourcesInOrder.first
    }

    /// The plan that takes over from the primary. Only ever a plan: a key is not used without being
    /// chosen, so a plan running out never turns into a bill.
    var backupSource: AnswerSource? {
        guard backupChoice != Self.noBackup, let primary = primaryAnswerSource else { return nil }
        let plans = [AnswerSource.claudeCodePlan, .codexPlan]
        guard plans.contains(primary) else { return nil }
        if let picked = backupChoice.flatMap(AnswerSource.init(rawValue:)), plans.contains(picked), picked != primary, canAnswer(with: picked) {
            return picked
        }
        return plans.first { $0 != primary && canAnswer(with: $0) }
    }

    /// Who answers now: the primary, or the backup while the primary has run out and the backup has
    /// not. With both out, the primary, whose refusal says so.
    var activeAnswerSource: AnswerSource? {
        guard let primary = primaryAnswerSource else { return nil }
        guard exhaustedPlans.contains(primary), let backupSource, !exhaustedPlans.contains(backupSource) else { return primary }
        return backupSource
    }
}

nonisolated enum ProviderRouter {
    /// Nothing set up: connecting a plan the person already pays for is the way in, so it comes first.
    static let needsOpenAIKeySentence = "that needs your own openai key. add one in settings, keys & plans."
    static let needsAnthropicKeySentence = "i can answer that once you connect claude or codex in settings, keys & plans. a key from openai, anthropic, openrouter, gemini and others works too."

    /// The route for `capability`: own key → that vendor; none → unavailable, saying which key would do.
    static func route(for capability: ProviderCapability, credentials: ProviderCredentials) -> ProviderRoute {
        switch capability {
        case .claude:
            // The person's pick when it can answer, else the first that can in the automatic order.
            switch credentials.activeAnswerSource {
            case .anthropic: return .anthropicDirect
            case .some(let other): return .answerProvider(other)
            case .none: return .unavailable(needsAnthropicKeySentence)
            }
        case .openAIChat, .speech, .transcription, .realtime:
            return credentials.openAIKey != nil ? .openAIDirect : .unavailable(needsOpenAIKeySentence)
        }
    }

    /// The keys in shell.json now.
    @MainActor static func currentCredentials() -> ProviderCredentials {
        var credentials = ProviderCredentials(settings: OpenClickyConfiguration.settings)
        credentials.exhaustedPlans = PlanAvailability.shared.exhaustedPlans()
        return credentials
    }

    /// The route for `capability` with the settings in shell.json now. Logged when it changes.
    @MainActor static func current(for capability: ProviderCapability) -> ProviderRoute {
        let route = route(for: capability, credentials: currentCredentials())
        noteRoute(route, for: capability)
        return route
    }

    private static let lastRoutesLock = NSLock()
    nonisolated(unsafe) private static var lastRoutes: [ProviderCapability: ProviderRoute] = [:]

    private static func noteRoute(_ route: ProviderRoute, for capability: ProviderCapability) {
        lastRoutesLock.lock()
        let changed = lastRoutes[capability] != route
        lastRoutes[capability] = route
        lastRoutesLock.unlock()
        if changed { AppLog.append("route: \(capability.rawValue) → \(route.logName)") }
    }
}

/// The error a caller throws for an unavailable route; its sentence is the one to show or say.
nonisolated struct ProviderRouteUnavailable: LocalizedError, Equatable {
    let capability: ProviderCapability
    let sentence: String
    var errorDescription: String? { sentence }
}

/// The direct vendor requests.
nonisolated enum DirectProviderRequests {
    static let openAIBaseURL = "https://api.openai.com/v1"
    static let anthropicMessagesURL = "https://api.anthropic.com/v1/messages"
    static let anthropicVersion = "2023-06-01"

    /// The default models and voice for own keys.
    static let defaultOpenAIModel = "gpt-5.5"
    static let defaultAnthropicModel = "claude-haiku-4-5-20251001"
    static let realtimeModel = "gpt-realtime"
    static let transcriptionModel = "gpt-4o-mini-transcribe"
    static let speechModel = "gpt-4o-mini-tts"
    static let speechVoice = "marin"

    private static func openAIRequest(_ path: String, key: String) -> URLRequest {
        var request = URLRequest(url: URL(string: openAIBaseURL + path)!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        return request
    }

    /// Anthropic Messages; the body is the caller's (the same one /chat relays).
    static func anthropicMessages(key: String) -> URLRequest {
        var request = URLRequest(url: URL(string: anthropicMessagesURL)!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue(anthropicVersion, forHTTPHeaderField: "anthropic-version")
        return request
    }

    /// The polish model and its output ceiling.
    static let polishModel = "claude-haiku-4-5"
    static let polishMaxOutputTokens = 4096

    /// Dictation polish or a Hey Clicky edit on Claude Haiku, straight to Anthropic.
    static func anthropicPolish(key: String, system: String, text: String) throws -> URLRequest {
        var request = anthropicMessages(key: key)
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": polishModel,
            // An upper bound: some scripts take a token or more per character, and a take cut off
            // at max_tokens would be pasted half-finished.
            "max_tokens": min(polishMaxOutputTokens, text.utf16.count * 2 + 64),
            "system": [["type": "text", "text": system, "cache_control": ["type": "ephemeral"]]],
            "messages": [["role": "user", "content": text]],
        ] as [String: Any])
        return request
    }

    /// The text of a non-streamed Messages reply. Nil when there is none, or when it stopped at
    /// max_tokens: half a take must never be pasted as if it were whole.
    static func anthropicReplyText(from data: Data) -> String? {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let content = json["content"] as? [[String: Any]] else { return nil }
        if (json["stop_reason"] as? String) == "max_tokens" { return nil }
        let text = content.filter { ($0["type"] as? String) == "text" }.compactMap { $0["text"] as? String }.joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    /// OpenAI Chat Completions; the body is the caller's.
    static func openAIChatCompletions(key: String) -> URLRequest {
        var request = openAIRequest("/chat/completions", key: key)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return request
    }

    /// OpenAI speech for `text`, mp3 (synthesizeSpeech in proxy.ts).
    static func openAISpeech(key: String, text: String) throws -> URLRequest {
        var request = openAIRequest("/audio/speech", key: key)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("audio/mpeg", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": speechModel, "voice": speechVoice, "input": text, "response_format": "mp3",
        ])
        return request
    }

    /// The multipart upload for OpenAI's audio transcriptions.
    static func openAITranscription(key: String, wav: Data, language: String?, prompt: String?, boundary: String = "openclicky-\(UUID().uuidString)") -> URLRequest {
        var request = openAIRequest("/audio/transcriptions", key: key)
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\nContent-Type: audio/wav\r\n\r\n".utf8))
        body.append(wav)
        body.append(Data("\r\n".utf8))
        field("model", transcriptionModel)
        field("response_format", "json")
        if let language, !language.isEmpty { field("language", language) }
        if let prompt, !prompt.isEmpty { field("prompt", prompt) }
        body.append(Data("--\(boundary)--\r\n".utf8))
        request.httpBody = body
        return request
    }

    /// A Realtime client secret.
    static func openAIRealtimeSecret(key: String, instructions: String?, voice: String?, expiresInSeconds: Int = 600) throws -> URLRequest {
        var request = openAIRequest("/realtime/client_secrets", key: key)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var session: [String: Any] = ["type": "realtime", "model": realtimeModel]
        if let instructions, !instructions.isEmpty { session["instructions"] = instructions }
        if let voice, !voice.isEmpty { session["audio"] = ["output": ["voice": voice]] }
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "expires_after": ["anchor": "created_at", "seconds": expiresInSeconds], "session": session,
        ] as [String: Any])
        return request
    }
}
