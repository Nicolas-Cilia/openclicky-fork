//
//  AnswerProvider.swift
//  OpenClicky
//
//  Who can answer a question besides Anthropic on an own key. The ask lane, screen
//  grounding and the tour's demo all go through `ClaudeAPI.analyzeImageStreaming`; when
//  ProviderRouter picks one of these sources, ClaudeAPI hands the same request to an
//  `AnswerProvider`:
//    - OpenAI-compatible chat (OpenAIChatAnswerProvider): OpenAI, OpenRouter, Groq, Mistral, xAI
//    - Google Gemini (GeminiAnswerProvider)
//    - the Claude Code CLI on the person's Claude plan (ClaudeCodeAnswerProvider)
//    - Codex on the person's ChatGPT plan (CodexAnswerProvider)
//  Keys go straight to their vendor.
//

import Foundation

/// The services that can answer, as the router and Settings name them.
nonisolated enum AnswerSource: String, CaseIterable, Identifiable, Sendable {
    case anthropic, openAI, openRouter, gemini, groq, mistral, xai, claudeCodePlan, codexPlan

    var id: String { rawValue }

    /// The few words the island shows next to "speaking".
    var shortName: String {
        switch self {
        case .anthropic: return "Claude"
        case .openAI: return "OpenAI"
        case .openRouter: return "OpenRouter"
        case .gemini: return "Gemini"
        case .groq: return "Groq"
        case .mistral: return "Mistral"
        case .xai: return "Grok"
        case .claudeCodePlan: return "Claude Code"
        case .codexPlan: return "Codex"
        }
    }

    var displayName: String {
        switch self {
        case .anthropic: return "Claude (Anthropic key)"
        case .openAI: return "OpenAI"
        case .openRouter: return "OpenRouter"
        case .gemini: return "Google Gemini"
        case .groq: return "Groq"
        case .mistral: return "Mistral"
        case .xai: return "xAI (Grok)"
        case .claudeCodePlan: return "Claude Code (your Claude plan)"
        case .codexPlan: return "Codex (your ChatGPT plan)"
        }
    }

    /// The model asked when shell.json's `answerModels` names none. Each one sees images.
    var defaultModel: String? {
        switch self {
        case .anthropic: return nil // ClaudeAPI's own model (Settings → Clicky → Model)
        case .openAI: return "gpt-4.1"
        case .openRouter: return "anthropic/claude-sonnet-4.6"
        case .gemini: return "gemini-3.8-flash"
        case .groq: return "meta-llama/llama-4-scout-17b-16e-instruct"
        case .mistral: return "mistral-medium-latest"
        case .xai: return "grok-4"
        case .claudeCodePlan, .codexPlan: return nil // the CLI's own
        }
    }

    /// The OpenAI-compatible chat completions endpoint, for the sources that speak it.
    var chatCompletionsURL: URL? {
        switch self {
        case .openAI: return URL(string: "https://api.openai.com/v1/chat/completions")
        case .openRouter: return URL(string: "https://openrouter.ai/api/v1/chat/completions")
        case .groq: return URL(string: "https://api.groq.com/openai/v1/chat/completions")
        case .mistral: return URL(string: "https://api.mistral.ai/v1/chat/completions")
        case .xai: return URL(string: "https://api.x.ai/v1/chat/completions")
        default: return nil
        }
    }
}

/// One question: the labelled screenshots, the prompts, the earlier turns, and the quick-action
/// tools (Anthropic's shape: name, description, input_schema as JSON).
nonisolated struct AnswerRequest: Sendable {
    struct Image: Sendable, Equatable {
        let data: Data
        let label: String
        /// "image/jpeg" or "image/png".
        let mediaType: String
    }
    struct Turn: Sendable, Equatable {
        let user: String
        let assistant: String
    }
    struct Tool: Sendable, Equatable {
        let name: String
        let description: String
        /// The JSON Schema of the arguments, serialized (Anthropic's `input_schema`).
        let inputSchemaJSON: Data
    }

    var images: [Image]
    var systemPrompt: String
    var history: [Turn]
    var userPrompt: String
    var tools: [Tool]
    var maxTokens: Int = 1024
}

nonisolated struct AnswerResult: Sendable, Equatable {
    var text: String
    var toolCalls: [ClaudeToolCall]
}

/// A provider that answers. `onTextChunk` gets each piece of text as it arrives (a provider that
/// cannot stream calls it once with the whole answer).
nonisolated protocol AnswerProvider: Sendable {
    func answer(_ request: AnswerRequest, onTextChunk: @escaping @Sendable (String) -> Void) async throws -> AnswerResult
}

/// A refusal or failure from a provider, with the HTTP status (0 for a CLI) and the vendor's own
/// message, so the ask lane can say something better than "something went wrong".
nonisolated struct AnswerProviderError: LocalizedError, Equatable {
    let source: AnswerSource
    let status: Int
    let message: String
    var errorDescription: String? { "\(source.displayName): \(message)" }
    /// A plan refused because it has run out, the one failure another plan can answer for.
    var isPlanLimit: Bool { (source == .claudeCodePlan || source == .codexPlan) && PlanLimitText.matches(message) }
}
