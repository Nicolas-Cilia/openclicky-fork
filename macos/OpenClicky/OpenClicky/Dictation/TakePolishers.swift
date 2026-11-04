//
//  TakePolishers.swift
//  OpenClicky
//
//  The models that tidy a take and make Hey Clicky edits, besides Apple's on-device one (in
//  `AppleModelTakePolisher.swift`, which needs FoundationModels): Sarvam's chat on a Sarvam key,
//  OpenAI on an own OpenAI key, Claude Haiku on an own Anthropic key, and any other answer key
//  through the ask lane's provider.
//  `DictationEngineResolver.makePolisher` picks one. Each says honestly who refused: an error
//  blamed on the wrong vendor sends people to the wrong key.
//

import Foundation

/// Why a vendor reached directly on the person's own key did not tidy or edit the words. Neutral
/// on purpose: an error blamed on the wrong vendor sends people to the wrong key.
enum TakePolishError: LocalizedError, Equatable {
    /// The vendor answered with a refusal (`status` is its HTTP status, 0 when there was none).
    case refused(vendor: String, status: Int, message: String)
    /// The vendor answered, but there was no text in it.
    case emptyAnswer(vendor: String)
    /// Nothing was sent: the route this polisher needs is not set up (the sentence says what is missing).
    case notSetUp(String)

    var errorDescription: String? {
        switch self {
        case let .refused(vendor, status, message):
            let statusPart = status == 0 ? "" : " (\(status))"
            let trimmedMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)
            return "\(vendor) refused the request\(statusPart)" + (trimmedMessage.isEmpty ? "." : ": \(trimmedMessage)")
        case let .emptyAnswer(vendor):
            return "\(vendor) sent back no text."
        case let .notSetUp(sentence):
            return sentence
        }
    }
}

/// Polishes through Sarvam's chat completions with the user's key.
struct SarvamTakePolisher: TakePolisher {
    let client: SarvamSpeechClient
    var displayName: String { "Sarvam" }
    func polish(system: String, user: String) async throws -> String {
        try await client.complete(system: system, user: user)
    }
}

/// Polishes through OpenAI's chat completions, straight to OpenAI on the person's own OpenAI key.
struct OpenAITakePolisher: TakePolisher {
    var displayName: String { "OpenAI (your key)" }
    func polish(system: String, user: String) async throws -> String {
        let body: [String: Any] = [
            "model": "gpt-4o-mini",
            "messages": [["role": "system", "content": system], ["role": "user", "content": user]],
            "temperature": 0.2,
        ]
        guard let openAIKey = ProviderRouter.currentCredentials().openAIKey else { throw TakePolishError.notSetUp(ProviderRouter.needsOpenAIKeySentence) }
        var request = DirectProviderRequests.openAIChatCompletions(key: openAIKey)
        request.timeoutInterval = 20
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let message = String(decoding: data.prefix(200), as: UTF8.self)
            throw TakePolishError.refused(vendor: "openai", status: status, message: message)
        }
        guard let answer = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let choices = answer["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw TakePolishError.emptyAnswer(vendor: "openai")
        }
        return content
    }
}

// MARK: - Own keys

/// Polish and edits on the person's own Anthropic key, straight to Anthropic, on Claude Haiku.
struct AnthropicTakePolisher: TakePolisher {
    let anthropicKey: String
    var send: @Sendable (URLRequest) async throws -> (Data, URLResponse) = { try await URLSession.shared.data(for: $0) }

    var displayName: String { "Claude (your key)" }

    func polish(system: String, user: String) async throws -> String {
        var request = try DirectProviderRequests.anthropicPolish(key: anthropicKey, system: system, text: user)
        request.timeoutInterval = 20
        let (data, response) = try await send(request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            AppLog.append("polish (own anthropic key): anthropic answered \(status)")
            throw TakePolishError.refused(vendor: "anthropic", status: status, message: String(decoding: data.prefix(200), as: UTF8.self))
        }
        guard let text = DirectProviderRequests.anthropicReplyText(from: data) else {
            AppLog.append("polish (own anthropic key): the reply had no whole text")
            throw TakePolishError.emptyAnswer(vendor: "anthropic")
        }
        return text
    }
}

/// Polish and edits on any other answer key the person added (OpenRouter, Gemini, Groq, Mistral,
/// xAI), straight to that vendor through the ask lane's own provider. A quick model where the
/// default answer model is a slow one: the clean-up gives up after `TakeFormatter.modelTimeoutSeconds`.
/// The two plans are left out: starting their CLI alone takes longer than that.
struct AnswerKeyTakePolisher: TakePolisher {
    let source: AnswerSource
    let credentials: ProviderCredentials

    /// The keys that can polish, in the order they are tried; the fast ones first.
    static let sourcesInOrder: [AnswerSource] = [.groq, .gemini, .mistral, .openRouter, .xai]

    /// The model asked to tidy a take, where it differs from the answer model.
    static func polishModel(for source: AnswerSource) -> String? {
        switch source {
        case .openRouter: return "openai/gpt-4.1-mini"
        case .mistral: return "mistral-small-latest"
        default: return nil
        }
    }

    /// The first source with a key, nil without any.
    static func firstAvailable(credentials: ProviderCredentials) -> AnswerKeyTakePolisher? {
        sourcesInOrder.first { credentials.key(for: $0) != nil }.map { AnswerKeyTakePolisher(source: $0, credentials: credentials) }
    }

    var displayName: String { "\(source.shortName) (your key)" }

    func polish(system: String, user: String) async throws -> String {
        var models: [String: String] = [:]
        if let model = Self.polishModel(for: source) { models[source.rawValue] = model }
        let provider = try await AnswerProviderFactory.make(for: source, credentials: credentials, modelOverrides: models)
        let request = AnswerRequest(images: [], systemPrompt: system, history: [], userPrompt: user, tools: [], maxTokens: 1024)
        let vendorName = source.shortName.lowercased()
        do {
            let result = try await provider.answer(request, onTextChunk: { _ in })
            let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { throw TakePolishError.emptyAnswer(vendor: vendorName) }
            return text
        } catch let error as AnswerProviderError {
            AppLog.append("polish (own \(source.rawValue) key): \(error.status)")
            throw TakePolishError.refused(vendor: vendorName, status: error.status, message: error.message)
        }
    }
}

// MARK: - Saying why the clean-up was skipped

/// Why a take was pasted with only the local clean-up, said once per session (every take hitting
/// the same limit would otherwise repeat it). The orb still says "cleaned up locally"; this is the
/// reason behind it, shown as the companion's quiet caption. Nil for a reason not worth saying
/// (a timeout, a passing server error): the log has those.
enum PolishFailureNotice {
    static func sentence(for error: Error) -> String? {
        switch error {
        case TakePolishError.refused(_, let status, _) where status == 401 || status == 403:
            // A vendor reached directly is only ever reached on the person's own key.
            return ownKeyRefusedSentence
        default:
            return nil
        }
    }

    static let ownKeyRefusedSentence = "your own api key was refused, so your words were cleaned up locally. check the key in settings, keys & plans."

    /// Sentences already shown this session.
    @MainActor private static var shownSentences: Set<String> = []

    /// Returns the sentence when it is new this session (and marks it shown), nil otherwise.
    @MainActor static func sentenceToShow(for error: Error, alreadyShown: inout Set<String>) -> String? {
        guard let sentence = sentence(for: error), !alreadyShown.contains(sentence) else { return nil }
        alreadyShown.insert(sentence)
        return sentence
    }

    @MainActor static func note(_ error: Error) {
        guard let sentence = sentenceToShow(for: error, alreadyShown: &shownSentences) else { return }
        OpenClickyConfiguration.showNotice?(sentence)
    }
}
