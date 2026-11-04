//
//  ProviderCapabilitiesTests.swift
//  OpenClicky
//

import Testing
@testable import OpenClicky

struct ProviderCapabilitiesTests {
    private func capabilities(signedIn: Bool = true, _ edit: (inout OpenClickyShellSettings) -> Void = { _ in }) -> ProviderCapabilities {
        var settings = OpenClickyShellSettings()
        edit(&settings)
        return ProviderCapabilities.current(settings: settings, codexSignedIn: { signedIn })
    }

    @Test func nothingSetUpHearsOnThisMacAndRunsNoAgentOrRealtime() {
        let nothing = capabilities()
        #expect(nothing.hearsOnDevice)
        #expect(!nothing.usesAgent)
        #expect(!nothing.usesRealtime)
    }

    @Test func anOwnOpenAIKeyDoesEverything() {
        let openAI = capabilities(signedIn: false) { $0.openaiApiKey = "sk" }
        #expect(!openAI.hearsOnDevice)
        #expect(openAI.usesAgent)
        #expect(openAI.usesRealtime)
    }

    @Test func theCodexPlanRunsTheAgentOnlyWhenOnAndSignedIn() {
        #expect(capabilities { $0.useCodexPlan = true }.usesAgent)
        #expect(!capabilities(signedIn: false) { $0.useCodexPlan = true }.usesAgent)
        #expect(!capabilities().usesAgent)
        // A plan hears on this Mac and has no realtime.
        #expect(capabilities { $0.useCodexPlan = true }.hearsOnDevice)
        #expect(!capabilities { $0.useCodexPlan = true }.usesRealtime)
    }

    @Test func theClaudePlanAnswersButRunsNoAgent() {
        #expect(!capabilities { $0.useClaudeCodePlan = true }.usesAgent)
    }

    @Test func aGeminiKeyRunsRealtimeButNotTheAgent() {
        let gemini = capabilities(signedIn: false) { $0.geminiApiKey = "g" }
        #expect(gemini.usesRealtime)
        #expect(!gemini.usesAgent)
        #expect(gemini.hearsOnDevice)
    }
}
