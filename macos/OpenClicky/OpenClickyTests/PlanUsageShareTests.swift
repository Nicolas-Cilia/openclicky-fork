//
//  PlanUsageShareTests.swift
//  OpenClickyTests
//
//  OpenClicky's rough part of each plan's limit bars.
//

import Foundation
import Testing
@testable import OpenClicky

struct PlanUsageShareTests {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)

    private func window(_ title: String = "5 hours", used: Double, resetsIn: TimeInterval = 3600) -> PlanLimitWindow {
        PlanLimitWindow(title: title, usedFraction: used, resetsAt: now.addingTimeInterval(resetsIn))
    }

    private func sample(_ source: AnswerSource = .claudeCodePlan, ago: TimeInterval = 60, input: Int = 1000, cached: Int = 0, output: Int = 0) -> PlanUsageSample {
        PlanUsageSample(date: now.addingTimeInterval(-ago), source: source.rawValue, lane: .answer, inputTokens: input, cachedInputTokens: cached, outputTokens: output)
    }

    @Test func tokensWeighByWhatTheyCost() {
        #expect(PlanUsageShare.weight(newInputTokens: 100, cachedInputTokens: 100, outputTokens: 100) == 100 + 10 + 500)
        #expect(PlanUsageShare.weight(of: sample(input: 1000, cached: 900, output: 10)) == 100 + 90 + 50)
    }

    @Test func windowLengthsComeFromTheirTitles() {
        #expect(PlanUsageShare.duration(ofWindowTitled: "5 hours") == 18_000)
        #expect(PlanUsageShare.duration(ofWindowTitled: "1 hour") == 3600)
        #expect(PlanUsageShare.duration(ofWindowTitled: "7 days") == 604_800)
        #expect(PlanUsageShare.duration(ofWindowTitled: "30 min") == 1800)
        #expect(PlanUsageShare.duration(ofWindowTitled: "seven day opus") == nil)
    }

    @Test func claudesShareIsOursAgainstWhatThisComputerLogged() {
        // Window: started 4 hours ago, 20% full. We sent 1000, the terminal 3000.
        let local = [PlanUsageShare.LocalClaudeUsage(date: now.addingTimeInterval(-60), weight: 3000)]
        let share = PlanUsageShare.claudeFraction(of: window(used: 0.2), samples: [sample()], localUsage: local, baselines: empty(0.2))
        #expect(abs((share ?? 0) - 0.05) < 0.0001)
    }

    @Test func claudesShareOnlyCountsThisWindowAndThisPlan() {
        let old = sample(ago: 5 * 3600)
        let codex = sample(.codexPlan)
        #expect(PlanUsageShare.claudeFraction(of: window(used: 0.2), samples: [old, codex], localUsage: [], baselines: empty(0.2)) == nil)
        // A window it can't date shows no share rather than a wrong one.
        #expect(PlanUsageShare.claudeFraction(of: window("seven day opus", used: 0.2), samples: [sample()], localUsage: [], baselines: empty(0.2)) == nil)

        let oldLocal = PlanUsageShare.LocalClaudeUsage(date: now.addingTimeInterval(-5 * 3600), weight: 9999)
        #expect(PlanUsageShare.claudeFraction(of: window(used: 0.2), samples: [sample()], localUsage: [oldLocal], baselines: empty(0.2)) == 0.2)
    }

    /// A bar that was empty when OpenClicky first used it, so only the logs limit the share.
    private func empty(_ used: Double) -> [MeasuredPlanWindow] {
        [MeasuredPlanWindow(title: "5 hours", resetsAt: window(used: used).resetsAt, usedFraction: 0)]
    }

    @Test func whatWasOnTheBarBeforeOpenClickyIsNeverItsShare() {
        // A fresh install: 8% used elsewhere, no logs on this computer, and one test request.
        let snapshot = PlanLimitSnapshot(windows: [window(used: 0.08)])
        let baselines = PlanUsageShare.updatingBaselines([], with: snapshot)
        #expect(PlanUsageShare.claudeFraction(of: window(used: 0.08), samples: [sample()], localUsage: [], baselines: baselines) == 0)
        #expect(PlanUsageShare.label(forFraction: 0) == "under 1% OpenClicky")

        // The bar rises to 11%: at most that 3 points can be OpenClicky's.
        let share = PlanUsageShare.claudeFraction(of: window(used: 0.11), samples: [sample()], localUsage: [], baselines: baselines)
        #expect(abs((share ?? 0) - 0.03) < 0.0001)
    }

    @Test func theLogsStillLimitTheShareOnceTheBarHasRisen() {
        let baselines = PlanUsageShare.updatingBaselines([], with: PlanLimitSnapshot(windows: [window(used: 0.10)]))
        let local = [PlanUsageShare.LocalClaudeUsage(date: now.addingTimeInterval(-60), weight: 3000)]
        let share = PlanUsageShare.claudeFraction(of: window(used: 0.20), samples: [sample()], localUsage: local, baselines: baselines)
        #expect(abs((share ?? 0) - 0.05) < 0.0001)
    }

    @Test func aBarWithNoBaselineShowsNoShareRatherThanAWrongOne() {
        #expect(PlanUsageShare.claudeFraction(of: window(used: 0.2), samples: [sample()], localUsage: [], baselines: []) == nil)
    }

    @Test func aBaselineLastsItsWindowAndANewWindowGetsItsOwn() {
        let first = PlanUsageShare.updatingBaselines([], with: PlanLimitSnapshot(windows: [window(used: 0.08)]))
        let later = PlanUsageShare.updatingBaselines(first, with: PlanLimitSnapshot(windows: [window(used: 0.30)]))
        #expect(later.first?.usedFraction == 0.08)
        let reset = PlanUsageShare.updatingBaselines(later, with: PlanLimitSnapshot(windows: [window(used: 0.01, resetsIn: 18_000)]))
        #expect(reset.first?.usedFraction == 0.01)
    }

    @MainActor @Test func theStoreKeepsClaudesBaselinesAcrossLaunches() {
        let defaults = UserDefaults(suiteName: "PlanUsageShareTests-\(UUID())")!
        let store = PlanLimitStore(defaults: defaults, availability: PlanAvailability(defaults: defaults), readCodex: { nil })
        store.ingest(PlanLimitSnapshot(windows: [window(used: 0.08)]), for: .claudeCodePlan)
        store.ingest(PlanLimitSnapshot(windows: [window(used: 0.09)]), for: .claudeCodePlan)
        store.ingest(PlanLimitSnapshot(windows: [window(used: 0.50)]), for: .codexPlan)
        #expect(store.claudeBaselines.map(\.usedFraction) == [0.08])
        let reopened = PlanLimitStore(defaults: defaults, availability: PlanAvailability(defaults: defaults), readCodex: { nil })
        #expect(reopened.claudeBaselines == store.claudeBaselines)
    }

    @Test func claudesLogsKeepTheLastLineOfEachRequestAndOnlyCounts() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let project = folder.appendingPathComponent("some-project/subagents")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        func line(id: String, time: String, output: Int) -> String {
            #"{"type":"assistant","timestamp":"\#(time)","requestId":"r","message":{"id":"\#(id)","content":[{"type":"text","text":"secret words"}],"usage":{"input_tokens":10,"cache_creation_input_tokens":90,"cache_read_input_tokens":100,"output_tokens":\#(output)}}}"#
        }
        let lines = [
            line(id: "a", time: "2026-05-18T03:00:00.000Z", output: 1),
            line(id: "a", time: "2026-05-18T03:00:01Z", output: 10),
            line(id: "old", time: "2020-01-01T00:00:00.000Z", output: 5000),
            #"{"type":"user","message":{"content":"no usage here"}}"#,
            "not json with \"usage\" in it",
        ]
        try lines.joined(separator: "\n").write(to: project.appendingPathComponent("x.jsonl"), atomically: true, encoding: .utf8)
        try "\(line(id: "skip", time: "2026-05-18T03:00:00Z", output: 7))".write(to: project.appendingPathComponent("x.txt"), atomically: true, encoding: .utf8)

        let usage = PlanUsageShare.localClaudeUsage(in: folder, since: Date(timeIntervalSince1970: 1_700_000_000))
        #expect(usage.map(\.weight) == [100 + 10 + 50])
    }

    @Test func aMissingLogsFolderIsNoUsage() {
        #expect(PlanUsageShare.localClaudeUsage(in: URL(fileURLWithPath: "/nonexistent-\(UUID())"), since: .distantPast).isEmpty)
    }

    private func snapshot(_ used: Double, title: String = "5 hours", resetsIn: TimeInterval = 3600) -> PlanLimitSnapshot {
        PlanLimitSnapshot(windows: [window(title, used: used, resetsIn: resetsIn)])
    }

    @Test func codexAddsUpHowFarEachRequestMovedTheBar() {
        var measured: [MeasuredPlanWindow] = []
        measured = PlanUsageShare.adding(before: snapshot(0.10), after: snapshot(0.12), to: measured)
        measured = PlanUsageShare.adding(before: snapshot(0.20), after: snapshot(0.21), to: measured)
        let share = PlanUsageShare.codexFraction(of: window(used: 0.30), measured: measured)
        #expect(abs((share ?? 0) - 0.03) < 0.0001)
    }

    @Test func aMeasuredRequestThatDidntMoveTheBarIsStillMeasured() {
        let measured = PlanUsageShare.adding(before: snapshot(0.10), after: snapshot(0.10), to: [])
        #expect(PlanUsageShare.codexFraction(of: window(used: 0.10), measured: measured) == 0)
        #expect(PlanUsageShare.label(forFraction: 0) == "under 1% OpenClicky")
    }

    @Test func aResetStartsTheCountAgain() {
        let oldWindow = PlanUsageShare.adding(before: snapshot(0.10), after: snapshot(0.50), to: [])
        // The window reset mid-request: nothing can be said about that request.
        let reset = PlanUsageShare.adding(before: snapshot(0.50), after: snapshot(0.02, resetsIn: 18_000), to: oldWindow)
        #expect(PlanUsageShare.codexFraction(of: window(used: 0.02, resetsIn: 18_000), measured: reset) == 0)
        // Before anything is measured in a new window, there's no share to show.
        #expect(PlanUsageShare.codexFraction(of: window(used: 0.02, resetsIn: 18_000), measured: oldWindow) == nil)
    }

    @Test func theShareIsNeverBiggerThanTheBarAndToleratesANudgedResetTime() {
        let measured = PlanUsageShare.adding(before: snapshot(0.10), after: snapshot(0.50), to: [])
        let share = PlanUsageShare.codexFraction(of: window(used: 0.20, resetsIn: 3600 + 60), measured: measured)
        #expect(share == 0.20)
    }

    @Test func labelsSayItIsAnEstimate() {
        #expect(PlanUsageShare.label(forFraction: 0.021) == "about 2% OpenClicky")
        #expect(PlanUsageShare.label(forFraction: 0.004) == "under 1% OpenClicky")
    }

    @MainActor @Test func theStoreMeasuresAcrossARequestAndKeepsIt() async throws {
        let defaults = UserDefaults(suiteName: "PlanUsageShareTests-\(UUID())")!
        var readings = [snapshot(0.10), snapshot(0.13)]
        let store = PlanLimitStore(defaults: defaults, availability: PlanAvailability(defaults: defaults), readCodex: { readings.removeFirst() })

        let finish = store.beginCodexRequest(settleNanoseconds: 0)
        finish()
        for _ in 0..<200 where store.codexMeasured.isEmpty { try await Task.sleep(nanoseconds: 5_000_000) }

        #expect(abs((store.codexMeasured.first?.usedFraction ?? 0) - 0.03) < 0.0001)
        #expect(store.snapshots[.codexPlan] == snapshot(0.13))
        let reopened = PlanLimitStore(defaults: defaults, availability: PlanAvailability(defaults: defaults), readCodex: { nil })
        #expect(reopened.codexMeasured == store.codexMeasured)
    }
}
