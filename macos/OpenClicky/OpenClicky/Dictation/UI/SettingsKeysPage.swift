//
//  SettingsKeysPage.swift
//  OpenClicky
//
//  Settings → Keys & Plans: the plans you already pay for (Claude Code, Codex) and your own provider
//  keys, each one testable.
//

import AppKit
import SwiftUI

extension SettingsCatalog {
    func keysItems() -> [SettingsItem] {
        [
            SettingsItem(
                id: "keys.list",
                title: "Your keys", detail: "Keys from AI providers (they answer, clean up and speak) and voice services.",
                keywords: ["api key", "byok", "own key", "provider", "add key", "openai", "openaiApiKey", "anthropic", "claude",
                           "anthropicApiKey", "openrouter", "llama", "deepseek", "gemini", "google", "ai studio", "groq",
                           "mistral", "xai", "grok", "sarvam", "saaras", "elevenlabs", "polly", "google cloud", "voice", "test"],
                view: AnyView(ProviderKeysList())),
            SettingsItem(
                id: "keys.keysNote",
                title: "Where keys go", detail: "Your keys go straight to that provider.",
                keywords: ["shell.json", "byok"],
                chrome: .footer,
                view: AnyView(SettingsFootnote(text: "Your keys go straight to that provider."))),
            SettingsItem(
                id: "keys.claudeCodePlan",
                title: "Claude Code (your Claude plan)", detail: "Answer questions through Claude Code, signed in to your Claude plan.",
                keywords: ["claude code", "claude plan", "pro", "max", "subscription", "anthropic"],
                view: AnyView(PlanSubscriptionRow(plan: .claudeCodePlan))),
            SettingsItem(
                id: "keys.codexPlan",
                title: "Codex (your ChatGPT plan)", detail: "Answer questions and run agent tasks through Codex, signed in with ChatGPT.",
                keywords: ["codex", "chatgpt", "plus", "pro", "subscription", "openai"],
                view: AnyView(PlanSubscriptionRow(plan: .codexPlan))),
            SettingsItem(
                id: "keys.usage.claudeCodePlan",
                title: "Claude Code usage", detail: "What OpenClicky has used on your Claude plan, and how full its limits are.",
                keywords: ["usage", "credits", "tracker", "limit", "tokens", "claude", "plan"],
                view: AnyView(PlanUsageRow(plan: .claudeCodePlan))),
            SettingsItem(
                id: "keys.usage.codexPlan",
                title: "Codex usage", detail: "What OpenClicky has used on your ChatGPT plan, and how full its limits are.",
                keywords: ["usage", "credits", "tracker", "limit", "tokens", "codex", "chatgpt", "plan"],
                view: AnyView(PlanUsageRow(plan: .codexPlan))),
            SettingsItem(
                id: "keys.plansNote",
                title: "What a plan can do", detail: "A plan answers, points and does quick actions like opening apps; Codex also runs bigger tasks.",
                keywords: ["subscription", "plan"],
                chrome: .footer,
                view: AnyView(SettingsFootnote(text: "A plan answers questions, points, and does quick actions like opening apps or making folders. Bigger tasks run on Codex, so switch it on for those. Codex answers in one go, a few seconds after you ask."))),
        ]
    }
}

// MARK: - your keys

/// A provider a key can be saved for: where it lives in shell.json and how its row reads.
/// Not private: the Spotify row's mapping is unit-tested.
enum KeyProvider: String, CaseIterable, Identifiable {
    case openAI, anthropic, openRouter, gemini, groq, mistral, xai, sarvam, elevenLabs, googleCloud, amazonPolly, spotify

    var id: String { rawValue }

    var title: String {
        switch self {
        case .openAI: return "OpenAI"
        case .anthropic: return "Anthropic (Claude)"
        case .openRouter: return "OpenRouter"
        case .gemini: return "Google Gemini"
        case .groq: return "Groq"
        case .mistral: return "Mistral"
        case .xai: return "xAI (Grok)"
        case .sarvam: return "Sarvam"
        case .elevenLabs: return "ElevenLabs"
        case .googleCloud: return "Google Cloud voice"
        case .amazonPolly: return "Amazon Polly"
        case .spotify: return "Spotify"
        }
    }

    var detail: String {
        switch self {
        case .openAI: return "Answers, fast voice and hands-free."
        case .anthropic: return "Claude answers your questions about the screen."
        case .openRouter: return "One key for Claude, GPT, Gemini, Llama and more."
        case .gemini: return "Answers and a voice. From Google AI Studio."
        case .groq: return "Very fast answers on open models."
        case .mistral: return "Mistral’s own models."
        case .xai: return "Grok, from xAI."
        case .sarvam: return "Speaks answers in a natural voice (Bulbul), and the Sarvam dictation engine for Indian languages."
        case .elevenLabs: return "Speaks answers in ElevenLabs’ voice, on your own ElevenLabs account."
        case .googleCloud: return "Speaks answers. A Google Cloud API key with the Text-to-Speech API switched on; an AI Studio key won’t do."
        case .amazonPolly: return "Speaks answers in Amazon’s neural voices. Paste access key ID:secret key, then :region if it isn’t us-east-1."
        case .spotify: return "Finds the song you asked for. Paste client id:client secret from developer.spotify.com; without it Spotify’s own search is used."
        }
    }

    var placeholder: String {
        switch self {
        case .openAI: return "sk-…"
        case .anthropic: return "sk-ant-…"
        case .openRouter: return "sk-or-…"
        case .gemini: return "AIza…"
        case .groq: return "gsk_…"
        case .mistral: return "Mistral key"
        case .xai: return "xai-…"
        case .sarvam: return "Sarvam key"
        case .elevenLabs: return "sk_…"
        case .googleCloud: return "AIza…"
        case .amazonPolly: return "AKIA…:secret"
        case .spotify: return "id:secret"
        }
    }

    var keyPath: WritableKeyPath<OpenClickyShellSettings, String?> {
        switch self {
        case .openAI: return \.openaiApiKey
        case .anthropic: return \.anthropicApiKey
        case .openRouter: return \.openRouterApiKey
        case .gemini: return \.geminiApiKey
        case .groq: return \.groqApiKey
        case .mistral: return \.mistralApiKey
        case .xai: return \.xaiApiKey
        case .sarvam: return \.sarvamKey
        case .elevenLabs: return \.elevenLabsApiKey
        case .googleCloud: return \.googleCloudApiKey
        case .amazonPolly: return \.amazonPollyCredentials
        case .spotify: return \.spotifyCredentials
        }
    }

    /// The source this key answers questions as; the voice-only keys answer nothing.
    var answerSource: AnswerSource? {
        switch self {
        case .openAI: return .openAI
        case .anthropic: return .anthropic
        case .openRouter: return .openRouter
        case .gemini: return .gemini
        case .groq: return .groq
        case .mistral: return .mistral
        case .xai: return .xai
        case .sarvam, .elevenLabs, .googleCloud, .amazonPolly, .spotify: return nil
        }
    }

    /// The voice this key speaks answers in, for its Test button.
    var speechVoice: SpeechVoiceChoice? {
        switch self {
        case .sarvam: return .sarvam
        case .elevenLabs: return .elevenLabs
        case .googleCloud: return .google
        case .amazonPolly: return .polly
        default: return nil
        }
    }

    var savedKey: String? {
        let key = (OpenClickyConfiguration.settings[keyPath: keyPath] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return key.isEmpty ? nil : key
    }
}

/// Your keys: one row per saved key (Test, Remove) and an "Add a key" row whose menu holds the
/// providers without one, so the list stays short however many providers there are.
private struct ProviderKeysList: View {
    @ObservedObject private var shellSettingsRevision = ShellSettingsRevision.shared
    @State private var newProvider: KeyProvider = .openAI
    @State private var newKey = ""
    @State private var addStatus: String?
    /// What the last Test or Save said, per provider.
    @State private var rowStatus: [KeyProvider: String] = [:]
    @State private var checking: Set<KeyProvider> = []
    @State private var pendingRemoval: KeyProvider?
    @ObservedObject private var dictationSettings = DictationSettings.shared

    var body: some View {
        let _ = shellSettingsRevision.revision
        let saved = KeyProvider.allCases.filter { $0.savedKey != nil }
        // Sarvam is for Indian languages: offered to add only in India (a saved one always shows).
        let unsaved = KeyProvider.allCases.filter { $0.savedKey == nil && ($0 != .sarvam || dictationSettings.region.offersIndianOptions) }
        // A group, not a stack: the form draws each key as its own row, with its separators.
        Group {
            ForEach(saved) { provider in savedRow(provider) }
            Group {
                if unsaved.isEmpty {
                    SettingsRow(title: "Every provider has a key", detail: addStatus) { EmptyView() }
                } else {
                    addRow(unsaved)
                }
            }
            .onAppear { if !unsaved.contains(newProvider), let first = unsaved.first { newProvider = first } }
            .confirmationDialog("Remove the \(pendingRemoval?.title ?? "") key?", isPresented: Binding(
                get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } })) {
                Button("Remove", role: .destructive) { if let pendingRemoval { remove(pendingRemoval) } }
            } message: {
                Text("It’s deleted from ~/.openclicky/shell.json. Keep a copy if you’ll need it again.")
            }
        }
    }

    private func savedRow(_ provider: KeyProvider) -> some View {
        let masked = "••••" + String((provider.savedKey ?? "").suffix(4))
        return SettingsRow(title: provider.title, detail: rowStatus[provider] ?? "\(provider.detail) \(masked)") {
            HStack(spacing: 8) {
                Button(checking.contains(provider) ? "Testing…" : "Test") { test(provider) }
                    .disabled(checking.contains(provider))
                    .help(provider.speechVoice == nil ? "Ask it what colour a red square is" : "Have it say a word")
                    .pointerCursor(isEnabled: !checking.contains(provider))
                Button("Remove") { pendingRemoval = provider }
                    .pointerCursor()
            }
        }
    }

    private func addRow(_ unsaved: [KeyProvider]) -> some View {
        SettingsRow(title: "Add a key", detail: addStatus ?? newProvider.detail) {
            HStack(spacing: 8) {
                Picker("Provider", selection: $newProvider) {
                    ForEach(unsaved) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
                .onChange(of: newProvider) { _, _ in addStatus = nil }
                .pointerCursor()
                SecureField("", text: $newKey, prompt: Text(newProvider.placeholder))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 130)
                    .onSubmit(add)
                    .accessibilityLabel("\(newProvider.title) key")
                Button("Add", action: add)
                    .fixedSize()
                    .disabled(newKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .pointerCursor(isEnabled: !(newKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
            }
            .layoutPriority(1)
        }
    }

    private func add() {
        let provider = newProvider
        let trimmed = newKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        save(trimmed, for: provider)
        newKey = ""
        addStatus = nil
        if let next = KeyProvider.allCases.first(where: { $0.savedKey == nil }) { newProvider = next }
        // Find out straight away whether it works.
        test(provider)
    }

    private func remove(_ provider: KeyProvider) {
        save(nil, for: provider)
        rowStatus[provider] = nil
        addStatus = "\(provider.title) key removed."
        newProvider = provider
    }

    private func save(_ key: String?, for provider: KeyProvider) {
        OpenClickyConfiguration.update { $0[keyPath: provider.keyPath] = key }
        // A changed key is a changed credential: a live realtime session reconnects with it.
        NotificationCenter.default.post(name: OpenClickyConfiguration.credentialsChangedNotification, object: nil)
        ShellSettingsRevision.shared.noteChanged()
    }

    private func test(_ provider: KeyProvider) {
        guard provider.savedKey != nil else { return }
        checking.insert(provider)
        rowStatus[provider] = "Checking…"
        Task {
            let sentence: String
            if let source = provider.answerSource {
                sentence = await AnswerSourceCheck.run(source, credentials: ProviderRouter.currentCredentials(),
                                                       modelOverrides: OpenClickyConfiguration.settings.answerModels ?? [:]).sentence
            } else if let voice = provider.speechVoice {
                // A voice key is checked by having it say one word.
                do {
                    _ = try await CloudVoiceSpeaker.audio(for: "ok", voice: voice)
                    sentence = "✓ Works. It can speak your answers."
                } catch {
                    sentence = error.localizedDescription
                }
            } else if provider == .spotify {
                // Spotify credentials are checked by looking one song up.
                let route = MusicLookupRoute.route(credentials: provider.savedKey)
                let tracks = await MusicLookup(route: route).search("test")
                sentence = tracks.first.map { "✓ Works. Found \($0.name)." } ?? "✗ Spotify refused the credentials."
            } else {
                sentence = "Saved."
            }
            rowStatus[provider] = sentence
            checking.remove(provider)
        }
    }
}

// MARK: - subscriptions

/// A plan the person already pays for: whether its CLI is here and signed in, and the switch that
/// lets it answer questions.
private struct PlanSubscriptionRow: View {
    let plan: AnswerSource
    @State private var status: PlanCLIStatus?
    @State private var isOn = false
    @State private var checkSentence: String?
    @State private var isChecking = false

    private var title: String { plan.displayName }

    var body: some View {
        SettingsRow(title: title, detail: detail) {
            HStack(spacing: 8) {
                if status == .ready {
                    Button(isChecking ? "Testing…" : "Test", action: test)
                        .disabled(isChecking)
                        .help("Ask it what colour a red square is")
                        .pointerCursor(isEnabled: !isChecking)
                }
                if status == .notInstalled {
                    Button("Get It ↗") { openExternalLink(plan == .claudeCodePlan ? "https://claude.com/product/claude-code" : "https://developers.openai.com/codex/cli") }
                        .pointerCursor()
                }
                SettingsSwitch(isOn: Binding(get: { isOn }, set: { newValue in
                    isOn = newValue
                    OpenClickyConfiguration.update { settings in
                        if plan == .claudeCodePlan { settings.useClaudeCodePlan = newValue } else { settings.useCodexPlan = newValue }
                    }
                    ShellSettingsRevision.shared.noteChanged()
                }))
                .disabled(status != .ready && !isOn)
            }
        }
        .task {
            isOn = plan == .claudeCodePlan ? OpenClickyConfiguration.settings.useClaudeCodePlan == true : OpenClickyConfiguration.settings.useCodexPlan == true
            status = plan == .claudeCodePlan ? await PlanCLIs.claudeCodeStatus() : await PlanCLIs.codexStatus()
        }
    }

    private func test() {
        isChecking = true
        checkSentence = "Checking… a plan takes a few seconds."
        Task {
            checkSentence = await AnswerSourceCheck.run(plan, credentials: ProviderRouter.currentCredentials(),
                                                        modelOverrides: OpenClickyConfiguration.settings.answerModels ?? [:]).sentence
            isChecking = false
        }
    }

    private var detail: String {
        if let checkSentence { return checkSentence }
        let command = plan == .claudeCodePlan ? "claude" : "codex login"
        switch status {
        case .none: return "Checking…"
        case .notInstalled?: return plan == .claudeCodePlan ? "Claude Code isn’t installed on this Mac." : "Codex isn’t installed on this Mac."
        case .installedSignedOut?: return "Installed, not signed in. Run “\(command)” in Terminal and sign in."
        case .ready?: return isOn ? "Signed in. Answering with your plan when it’s the one picked (Settings → Clicky)." : "Signed in. Switch on to answer with your plan."
        }
    }
}
