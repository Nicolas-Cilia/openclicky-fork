//
//  ClaudeLimitRingsTests.swift
//  OpenClickyTests
//
//  Claude's limit rings: what `claude -p` reported becomes rings, a window that has reset is left
//  out, and how a reset reads.
//

import Foundation
import Testing
@testable import OpenClicky

struct ClaudeLimitRingsTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func theReportedWindowsBecomeTwoRingsInOrder() {
        let snapshot = PlanLimitSnapshot(windows: [
            PlanLimitWindow(title: "7 days", usedFraction: 0.37, resetsAt: now.addingTimeInterval(86_400)),
            PlanLimitWindow(title: "5 hours", usedFraction: 0.38, resetsAt: now.addingTimeInterval(3600)),
            PlanLimitWindow(title: "seven day opus", usedFraction: 0.9, resetsAt: nil),
        ])
        #expect(ClaudeLimitRings.rings(from: snapshot, now: now) == [
            ClaudeLimitRing(label: "5 h", fraction: 0.38, resetsAt: now.addingTimeInterval(3600)),
            ClaudeLimitRing(label: "7 d", fraction: 0.37, resetsAt: now.addingTimeInterval(86_400)),
        ])
    }

    @Test func aWindowThatHasResetIsLeftOut() {
        let snapshot = PlanLimitSnapshot(windows: [
            PlanLimitWindow(title: "5 hours", usedFraction: 0.9, resetsAt: now.addingTimeInterval(-1)),
            PlanLimitWindow(title: "7 days", usedFraction: 0.2, resetsAt: nil),
        ])
        #expect(ClaudeLimitRings.rings(from: snapshot, now: now).map(\.label) == ["7 d"])
    }

    @Test func nothingReportedYetIsNoRings() {
        #expect(ClaudeLimitRings.rings(from: nil, now: now).isEmpty)
    }

    @Test func resetsReadShort() {
        #expect(ClaudeLimitRings.resetText(until: now.addingTimeInterval(2 * 3600 + 10 * 60 + 5), now: now) == "resets 2 h 10 m")
        #expect(ClaudeLimitRings.resetText(until: now.addingTimeInterval(35 * 60), now: now) == "resets 35 m")
        #expect(ClaudeLimitRings.resetText(until: now.addingTimeInterval(30), now: now) == "resets soon")
        #expect(ClaudeLimitRings.resetText(until: nil, now: now) == "")
    }

    /// The rule this file exists for: nothing in the app may read Claude Code's sign-in again.
    @Test func noSourceFileReadsClaudesSignIn() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("OpenClicky")
        let forbidden = ["Claude Code-credentials", "claudeAiOauth", "api/oauth/usage"]
        let files = try #require(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        var swiftFilesRead = 0
        for case let file as URL in files where file.pathExtension == "swift" {
            let text = try String(contentsOf: file, encoding: .utf8)
            swiftFilesRead += 1
            for word in forbidden { #expect(!text.contains(word), "\(file.lastPathComponent) mentions \(word)") }
        }
        #expect(swiftFilesRead > 100)
    }
}
