//
//  AgentHousekeeping.swift
//  OpenClicky
//
//  What agent tasks leave behind. Each task's screenshot is a temp file, removed when the run ends;
//  Codex keeps its own copy inside the task's session file, which goes when the task passes the
//  limit picked in Settings → Privacy (`AgentSessionLimit`).
//

import Foundation

enum AgentSessionLimit {
    static let defaultDays = 14
    /// The choices Settings offers; 0 keeps every task.
    static let choices = [7, 14, 30, 90, 0]

    /// shell.json's `agentSessionDays`: unset or nonsense is the default.
    static func days(stored: Int?) -> Int {
        guard let stored, stored >= 0 else { return defaultDays }
        return stored
    }

    static func label(_ days: Int) -> String {
        days == 0 ? "Forever" : "\(days) days"
    }
}

enum AgentHousekeeping {
    private static let screenshotPrefix = "openclicky-"
    private static let screenshotExtension = "jpg"

    static let firstCleanupDelayNanoseconds: UInt64 = 60 * 1_000_000_000
    static let cleanupIntervalNanoseconds: UInt64 = 24 * 60 * 60 * 1_000_000_000

    static func newScreenshotURL(in folder: URL = FileManager.default.temporaryDirectory) -> URL {
        folder.appendingPathComponent("\(screenshotPrefix)\(UUID().uuidString).\(screenshotExtension)")
    }

    /// Screenshots a quit or crash left mid-task. An hour's grace for anything still in use.
    static func removeLeftoverScreenshots(in folder: URL = FileManager.default.temporaryDirectory, now: Date = Date()) {
        let fileManager = FileManager.default
        let files = (try? fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for file in files where file.lastPathComponent.hasPrefix(screenshotPrefix) && file.pathExtension == screenshotExtension {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? now
            if now.timeIntervalSince(modified) > 3600 { try? fileManager.removeItem(at: file) }
        }
    }
}
