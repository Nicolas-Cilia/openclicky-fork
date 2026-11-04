//
//  PlanFailoverAndUsageTests.swift
//  OpenClickyTests
//
//  Who answers when a plan runs out, what the CLIs' usage reports turn into, the ledger, and when
//  another app counts as using the notch.
//

import CoreGraphics
import Foundation
import Testing
@testable import OpenClicky

struct PlanFailoverTests {
    private func credentials(claude: Bool = true, codex: Bool = true, preferred: AnswerSource? = nil, backup: String? = nil,
                             out: Set<AnswerSource> = [], anthropicKey: String? = nil) -> ProviderCredentials {
        var credentials = ProviderCredentials(openAIKey: nil, anthropicKey: anthropicKey, claudeCodePlanOn: claude, codexPlanOn: codex, preferredAnswerSource: preferred)
        credentials.backupChoice = backup
        credentials.exhaustedPlans = out
        return credentials
    }

    @Test func theDefaultAnswersUntilItRunsOutThenTheBackupDoes() {
        #expect(credentials(preferred: .codexPlan).activeAnswerSource == .codexPlan)
        #expect(credentials(preferred: .codexPlan, out: [.codexPlan]).activeAnswerSource == .claudeCodePlan)
        #expect(credentials(preferred: .claudeCodePlan, out: [.claudeCodePlan]).activeAnswerSource == .codexPlan)
    }

    @Test func withBothOutTheDefaultSaysSo() {
        #expect(credentials(preferred: .codexPlan, out: [.codexPlan, .claudeCodePlan]).activeAnswerSource == .codexPlan)
    }

    @Test func dontSwitchMeansNoBackup() {
        let chosen = credentials(preferred: .codexPlan, backup: ProviderCredentials.noBackup, out: [.codexPlan])
        #expect(chosen.backupSource == nil)
        #expect(chosen.activeAnswerSource == .codexPlan)
    }

    @Test func oneLinkedPlanHasNoBackup() {
        #expect(credentials(codex: false, preferred: .claudeCodePlan, out: [.claudeCodePlan]).activeAnswerSource == .claudeCodePlan)
    }

    @Test func aPlanRunningOutNeverFallsToAKey() {
        let keyAndOnePlan = credentials(codex: false, out: [.claudeCodePlan], anthropicKey: "sk")
        #expect(keyAndOnePlan.backupSource == nil)
        #expect(keyAndOnePlan.activeAnswerSource == .claudeCodePlan)
        let keyPickedAsBackup = credentials(codex: false, backup: AnswerSource.anthropic.rawValue, out: [.claudeCodePlan], anthropicKey: "sk")
        #expect(keyPickedAsBackup.activeAnswerSource == .claudeCodePlan)
    }

    @Test func automaticPrefersAPlanOverAKey() {
        #expect(credentials(anthropicKey: "sk").activeAnswerSource == .claudeCodePlan)
    }

    @Test func aKeyPickedAsDefaultStillAnswers() {
        #expect(credentials(preferred: .anthropic, anthropicKey: "sk").activeAnswerSource == .anthropic)
        #expect(ProviderRouter.route(for: .claude, credentials: credentials(preferred: .anthropic, anthropicKey: "sk")) == .anthropicDirect)
    }

    @Test func theRouterFollowsTheBackup() {
        #expect(ProviderRouter.route(for: .claude, credentials: credentials(preferred: .codexPlan, out: [.codexPlan])) == .answerProvider(.claudeCodePlan))
    }

    @Test func limitRefusalsAreRecognised() {
        for text in ["You've hit your limit · resets 3am", "Claude usage limit reached", "rate_limit_error", "You've hit your usage limit.", "Quota exceeded"] {
            #expect(PlanLimitText.matches(text), "\(text)")
            #expect(ClaudeCodeAnswerProvider.humanSentence(forFailureText: text) == "Your Claude plan has hit its usage limit for now.")
        }
        #expect(!PlanLimitText.matches("Not logged in"))
        #expect(AnswerProviderError(source: .codexPlan, status: 0, message: CodexAnswerProvider.humanSentence(forFailureText: "usage limit")).isPlanLimit)
        #expect(!AnswerProviderError(source: .openAI, status: 429, message: "rate limit").isPlanLimit)
    }

    @Test func availabilityRestsAPlanUntilItsResetAndForgetsAfter() throws {
        let defaults = try #require(UserDefaults(suiteName: "plan-availability-\(UUID())"))
        let availability = PlanAvailability(defaults: defaults)
        let now = Date()
        availability.markExhausted(.codexPlan, until: now.addingTimeInterval(600), now: now)
        #expect(availability.exhaustedPlans(now: now) == [.codexPlan])
        #expect(availability.exhaustedPlans(now: now.addingTimeInterval(601)).isEmpty)
        availability.markExhausted(.claudeCodePlan, until: nil, now: now)
        #expect(abs((availability.exhaustedUntil(.claudeCodePlan, now: now) ?? .distantPast).timeIntervalSince(now) - PlanAvailability.restWithoutResetTime) < 0.01)
        availability.clear(.claudeCodePlan)
        #expect(availability.exhaustedUntil(.claudeCodePlan, now: now) == nil)
    }

    @MainActor @Test func anAllowedReportClearsARestAndAFullOneStartsIt() throws {
        let defaults = try #require(UserDefaults(suiteName: "plan-limits-\(UUID())"))
        let availability = PlanAvailability(defaults: defaults)
        let store = PlanLimitStore(defaults: defaults, availability: availability, readCodex: { nil })
        let reset = Date().addingTimeInterval(3600)
        store.ingest(PlanLimitSnapshot(windows: [PlanLimitWindow(title: "5 hours", usedFraction: 1, resetsAt: reset)]), for: .claudeCodePlan)
        #expect(availability.exhaustedUntil(.claudeCodePlan) != nil)
        store.ingest(PlanLimitSnapshot(windows: [PlanLimitWindow(title: "5 hours", usedFraction: 0.2, resetsAt: reset)]), for: .claudeCodePlan)
        #expect(availability.exhaustedUntil(.claudeCodePlan) == nil)
    }

    @Test func agentTasksPauseWhileCodexIsOutButNotOnAKey() {
        let reset = Date().addingTimeInterval(3600)
        let paused = ProviderCapabilities(hasOwnOpenAIKey: false, hasRealtimeKey: false, hasCodexPlan: true, codexPausedUntil: reset)
        #expect(!paused.usesAgent)
        #expect(paused.agentPausedSentence?.contains("paused until") == true)
        let onKey = ProviderCapabilities(hasOwnOpenAIKey: true, hasRealtimeKey: true, hasCodexPlan: true, codexPausedUntil: reset)
        #expect(onKey.usesAgent)
        #expect(onKey.agentPausedSentence == nil)
    }
}

struct PlanUsageParsingTests {
    /// The shapes both CLIs really sent (Claude Code 2.1.318, codex-cli 0.166.0, 2026-11-03).
    @Test func claudesStreamGivesTokensCostAndLimits() {
        let parser = ClaudeCodeStreamParser()
        let lines = #"""
        {"type":"rate_limit_event","rate_limit_info":{"status":"allowed","resetsAt":1793789400,"rateLimitType":"five_hour","unifiedWindows":{"five_hour":{"utilization":0.06,"resetsAt":1793789400,"status":"allowed"},"seven_day":{"utilization":0.17,"resetsAt":1793916000,"status":"allowed"}}}}
        {"type":"result","subtype":"success","is_error":false,"result":"ok","total_cost_usd":0.00046689,"usage":{"input_tokens":2,"output_tokens":4,"cache_read_input_tokens":649,"cache_creation_input_tokens":2291}}

        """#
        _ = parser.consume(Data(lines.utf8))
        let summary = parser.summary
        #expect(summary.usage?.inputTokens == 2942)
        #expect(summary.usage?.cachedInputTokens == 649)
        #expect(summary.usage?.outputTokens == 4)
        #expect(summary.usage?.estimatedCostUSD == 0.00046689)
        #expect(summary.limits?.windows.map(\.title) == ["5 hours", "7 days"])
        #expect(summary.limits?.windows.first?.usedFraction == 0.06)
        #expect(summary.limits?.isExhausted == false)
    }

    @Test func aRejectedClaudeReportCarriesItsReset() {
        let snapshot = PlanLimitSnapshot.fromClaude(rateLimitInfo: ["status": "rejected", "resetsAt": 1793789400.0])
        #expect(snapshot.isExhausted)
        #expect(snapshot.exhaustedUntil == Date(timeIntervalSince1970: 1793789400))
    }

    @Test func codexsTurnGivesTokens() throws {
        let lines = #"""
        {"type":"turn.started"}
        {"type":"turn.completed","usage":{"input_tokens":12329,"cached_input_tokens":9856,"cache_write_input_tokens":0,"output_tokens":5,"reasoning_output_tokens":0}}
        """#
        let sample = try #require(CodexAnswerProvider.usageSample(fromJSONLines: lines))
        #expect(sample.inputTokens == 12329)
        #expect(sample.cachedInputTokens == 9856)
        #expect(sample.outputTokens == 5)
        #expect(sample.estimatedCostUSD == nil)
    }

    @Test func codexsRateLimitsBecomeWindows() throws {
        let reply = #"{"ordinaryUsageAllowed":true,"rateLimits":{"primary":{"usedPercent":17,"windowDurationMins":300,"resetsAt":1793788715},"secondary":{"usedPercent":7,"windowDurationMins":10080,"resetsAt":1793906780},"credits":{"hasCredits":false,"unlimited":false,"balance":"0"},"planType":"plus","rateLimitReachedType":null}}"#
        let result = try #require(try JSONSerialization.jsonObject(with: Data(reply.utf8)) as? [String: Any])
        let snapshot = try #require(PlanLimitSnapshot.fromCodex(rateLimitsResult: result))
        #expect(snapshot.windows.map(\.title) == ["5 hours", "7 days"])
        #expect(snapshot.windows[0].usedFraction == 0.17)
        #expect(snapshot.windows[1].resetsAt == Date(timeIntervalSince1970: 1793906780))
        #expect(!snapshot.isExhausted)
        #expect(snapshot.creditsBalance == nil)
        #expect(snapshot.planName == "plus")
    }

    @Test func aCodexLimitReachedIsExhausted() throws {
        let reply = #"{"ordinaryUsageAllowed":false,"rateLimits":{"primary":{"usedPercent":100,"windowDurationMins":300,"resetsAt":1793788715},"credits":{"hasCredits":true,"balance":"12"},"rateLimitReachedType":"primary"}}"#
        let result = try #require(try JSONSerialization.jsonObject(with: Data(reply.utf8)) as? [String: Any])
        let snapshot = try #require(PlanLimitSnapshot.fromCodex(rateLimitsResult: result))
        #expect(snapshot.isExhausted)
        #expect(snapshot.exhaustedUntil == Date(timeIntervalSince1970: 1793788715))
        #expect(snapshot.creditsBalance == "12")
    }

    @Test func theLedgerAddsUpByPlanAndDayAndKeepsNoWords() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("usage-\(UUID()).jsonl")
        defer { try? FileManager.default.removeItem(at: file) }
        let ledger = PlanUsageLedger(fileURL: file)
        let now = Date()
        ledger.record(PlanUsageSample(date: now.addingTimeInterval(-90_000), source: "codexPlan", lane: .agent, inputTokens: 100, cachedInputTokens: 0, outputTokens: 10))
        ledger.record(PlanUsageSample(date: now, source: "codexPlan", lane: .answer, inputTokens: 200, cachedInputTokens: 50, outputTokens: 20))
        ledger.record(PlanUsageSample(date: now, source: "claudeCodePlan", lane: .answer, inputTokens: 5, cachedInputTokens: 0, outputTokens: 1, estimatedCostUSD: 0.25))
        #expect(ledger.totals(for: .codexPlan) == PlanUsageTotals(requests: 2, tokens: 330))
        #expect(ledger.totals(for: .codexPlan, since: now.addingTimeInterval(-60)) == PlanUsageTotals(requests: 1, tokens: 220))
        #expect(ledger.totals(for: .claudeCodePlan).estimatedCostUSD == 0.25)
        try "not json\n".appendLine(to: file)
        #expect(ledger.samples().count == 3)
    }
}

private extension String {
    func appendLine(to file: URL) throws {
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(utf8))
    }
}

struct NotchOccupancyTests {
    private let zone = CGRect(x: 656, y: 0, width: 200, height: 37)
    private func occupied(_ windows: [NotchOccupancy.Window], system: Set<Int32> = []) -> Bool {
        NotchOccupancy.isOccupied(windows: windows, zone: zone, ownPID: 1, isSystemProcess: { system.contains($0) })
    }

    /// Vorssaint's two windows as measured on a real Mac.
    @Test func vorssaintCounts() {
        #expect(occupied([
            .init(ownerPID: 933, layer: 2147483628, bounds: CGRect(x: 1511, y: 981, width: 1, height: 1), alpha: 1),
            .init(ownerPID: 933, layer: 2147483628, bounds: CGRect(x: 0, y: 0, width: 1512, height: 491), alpha: 1),
        ]))
    }

    @Test func aNotchAppAtMainMenuLevelCounts() {
        #expect(occupied([.init(ownerPID: 2, layer: 27, bounds: CGRect(x: 600, y: 0, width: 300, height: 40), alpha: 1)]))
    }

    @Test func whatDoesNotCount() {
        #expect(!occupied([.init(ownerPID: 1, layer: 101, bounds: zone, alpha: 1)]), "our own island")
        #expect(!occupied([.init(ownerPID: 2, layer: 25, bounds: zone, alpha: 1)]), "a status item")
        #expect(!occupied([.init(ownerPID: 2, layer: 0, bounds: zone, alpha: 1)]), "an ordinary window")
        #expect(!occupied([.init(ownerPID: 2, layer: 101, bounds: zone, alpha: 0)]), "fully transparent")
        #expect(!occupied([.init(ownerPID: 2, layer: 101, bounds: CGRect(x: 0, y: 200, width: 500, height: 200), alpha: 1)]), "elsewhere")
        #expect(!occupied([.init(ownerPID: 2, layer: 101, bounds: CGRect(x: 700, y: 0, width: 30, height: 30), alpha: 1)]), "tiny")
        #expect(!occupied([.init(ownerPID: 2, layer: 101, bounds: zone, alpha: 1)], system: [2]), "the system's own")
    }

    @Test func oneStraySampleDoesNotMoveTheIsland() {
        var debouncer = NotchOccupancyDebouncer(startingWith: false)
        let changes = [true, false, true, true, false, false].map { debouncer.take($0) }
        #expect(changes == [false, false, false, true, false, true])
        #expect(!debouncer.isOccupied)
    }

    @Test func automaticResolvesAndTheOthersStay() {
        #expect(HUDPlacement.automatic.resolved(notchIsOccupied: false) == .notch)
        #expect(HUDPlacement.automatic.resolved(notchIsOccupied: true) == .right)
        #expect(HUDPlacement.notch.resolved(notchIsOccupied: true) == .notch)
        #expect(HUDPlacement.left.resolved(notchIsOccupied: true) == .left)
        #expect(HUDPlacement.hidden.resolved(notchIsOccupied: true) == .hidden)
    }
}
