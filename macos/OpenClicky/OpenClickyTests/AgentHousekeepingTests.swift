//
//  AgentHousekeepingTests.swift
//  OpenClickyTests
//
//  The agent-task limit's stored value, and sweeping leftover screenshots.
//

import Foundation
import Testing
@testable import OpenClicky

struct AgentHousekeepingTests {
    @Test func theLimitDefaultsToTwoWeeksAndZeroKeepsEverything() {
        #expect(AgentSessionLimit.days(stored: nil) == 14)
        #expect(AgentSessionLimit.days(stored: -3) == 14)
        #expect(AgentSessionLimit.days(stored: 30) == 30)
        #expect(AgentSessionLimit.days(stored: 0) == 0)
        #expect(AgentSessionLimit.choices.contains(AgentSessionLimit.defaultDays))
        #expect(AgentSessionLimit.label(0) == "Forever")
        #expect(AgentSessionLimit.label(14) == "14 days")
    }

    @Test func aShortSettingsFileLeavesTheLimitUnset() throws {
        let settings = try JSONDecoder().decode(OpenClickyShellSettings.self, from: Data("{}".utf8))
        #expect(settings.agentSessionDays == nil)
        let picked = try JSONDecoder().decode(OpenClickyShellSettings.self, from: Data(#"{"agentSessionDays":7}"#.utf8))
        #expect(picked.agentSessionDays == 7)
    }

    @Test func onlyOldScreenshotsOfOursAreSwept() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let now = Date()
        func file(_ name: URL, age: TimeInterval) throws -> URL {
            try Data([1]).write(to: name)
            try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-age)], ofItemAtPath: name.path)
            return name
        }
        let old = try file(AgentHousekeeping.newScreenshotURL(in: folder), age: 7200)
        let inUse = try file(AgentHousekeeping.newScreenshotURL(in: folder), age: 60)
        let notOurs = try file(folder.appendingPathComponent("holiday.jpg"), age: 7200)
        let otherKind = try file(folder.appendingPathComponent("openclicky-notes.txt"), age: 7200)

        AgentHousekeeping.removeLeftoverScreenshots(in: folder, now: now)

        #expect(!FileManager.default.fileExists(atPath: old.path))
        for kept in [inUse, notOurs, otherKind] { #expect(FileManager.default.fileExists(atPath: kept.path)) }
    }
}
