//
//  PlanUsageShare.swift
//  OpenClicky
//
//  Roughly how much of a plan's limit bar is OpenClicky. Neither plan says, so this is an estimate:
//    - Claude: OpenClicky's tokens against the tokens Claude Code logged on this computer
//      (~/.claude/projects; only the counts are read), as a share of the bar. Use on other
//      computers or on the Claude website isn't in those logs, so the share can come out high. It
//      never exceeds how far the bar has risen since OpenClicky first used this window, so what was
//      already on the bar is never counted as OpenClicky's.
//    - Codex: how far the bar moved across each OpenClicky request, added up until the window
//      resets. Anything else using Codex at that moment is counted too.
//

import Foundation

/// How far a Codex limit has moved across OpenClicky's requests, in the window ending at `resetsAt`.
nonisolated struct MeasuredPlanWindow: Codable, Equatable, Sendable {
    var title: String
    var resetsAt: Date?
    var usedFraction: Double
}

nonisolated enum PlanUsageShare {
    /// Reset times this close together are the same window: a plan may nudge the time it reports.
    private static let sameWindowTolerance: TimeInterval = 10 * 60

    /// What a request weighs against a plan's limit, roughly: a cached token costs far less than a
    /// new one, and an output token far more.
    static func weight(newInputTokens: Int, cachedInputTokens: Int, outputTokens: Int) -> Double {
        Double(newInputTokens) + Double(cachedInputTokens) * 0.1 + Double(outputTokens) * 5
    }

    static func weight(of sample: PlanUsageSample) -> Double {
        weight(newInputTokens: max(0, sample.inputTokens - sample.cachedInputTokens),
               cachedInputTokens: sample.cachedInputTokens, outputTokens: sample.outputTokens)
    }

    /// The length of a window from its title ("5 hours", "7 days", "30 min"); nil for any other title.
    static func duration(ofWindowTitled title: String) -> TimeInterval? {
        let parts = title.split(separator: " ")
        guard parts.count == 2, let count = Double(parts[0]) else { return nil }
        switch parts[1] {
        case "min": return count * 60
        case "hour", "hours": return count * 3600
        case "day", "days": return count * 86_400
        default: return nil
        }
    }

    static func start(of window: PlanLimitWindow) -> Date? {
        guard let resetsAt = window.resetsAt, let duration = duration(ofWindowTitled: window.title) else { return nil }
        return resetsAt.addingTimeInterval(-duration)
    }

    static func isSameWindow(_ first: Date?, _ second: Date?) -> Bool {
        guard let first, let second else { return first == nil && second == nil }
        return abs(first.timeIntervalSince(second)) <= sameWindowTolerance
    }

    // MARK: Claude

    /// OpenClicky's part of a Claude bar; nil when it isn't known or OpenClicky used none of this window.
    /// `baselines` is how full each bar was when OpenClicky first used its window (`updatingBaselines`).
    static func claudeFraction(of window: PlanLimitWindow, samples: [PlanUsageSample], localUsage: [LocalClaudeUsage],
                               baselines: [MeasuredPlanWindow]) -> Double? {
        guard let start = start(of: window),
              let baseline = baselines.first(where: { $0.title == window.title && isSameWindow($0.resetsAt, window.resetsAt) }) else { return nil }
        let ours = samples
            .filter { $0.source == AnswerSource.claudeCodePlan.rawValue && $0.date >= start }
            .reduce(0) { $0 + weight(of: $1) }
        guard ours > 0 else { return nil }
        let others = localUsage.filter { $0.date >= start }.reduce(0) { $0 + $1.weight }
        return min(window.usedFraction * ours / (ours + others), max(0, window.usedFraction - baseline.usedFraction))
    }

    /// Remembers how full each bar is the first time it is seen in its window. Claude only reports
    /// its limits on OpenClicky's own requests, so that is when OpenClicky first used the window.
    static func updatingBaselines(_ baselines: [MeasuredPlanWindow], with snapshot: PlanLimitSnapshot) -> [MeasuredPlanWindow] {
        snapshot.windows.map { window in
            baselines.first { $0.title == window.title && isSameWindow($0.resetsAt, window.resetsAt) }
                ?? MeasuredPlanWindow(title: window.title, resetsAt: window.resetsAt, usedFraction: window.usedFraction)
        }
    }

    /// One request Claude Code logged on this computer.
    struct LocalClaudeUsage: Equatable, Sendable {
        var date: Date
        var weight: Double
    }

    static let claudeLogsFolder = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/projects", isDirectory: true)

    /// Requests in Claude Code's logs since `start`. Only the timestamp and counts are kept. A file
    /// untouched since `start` holds nothing newer, so it isn't opened.
    static func localClaudeUsage(in folder: URL = claudeLogsFolder, since start: Date) -> [LocalClaudeUsage] {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .isRegularFileKey]
        guard let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: Array(keys)) else { return [] }
        var requests: [String: LocalClaudeUsage] = [:]
        let marker = Data(#""usage""#.utf8)
        for case let file as URL in files where file.pathExtension == "jsonl" {
            guard let values = try? file.resourceValues(forKeys: keys), values.isRegularFile == true,
                  (values.contentModificationDate ?? .distantFuture) >= start,
                  let data = try? Data(contentsOf: file, options: .mappedIfSafe) else { continue }
            for line in data.split(separator: UInt8(ascii: "\n")) where line.range(of: marker) != nil {
                // A streamed reply is logged over several lines: the last one for a request counts.
                if let (key, usage) = parseClaudeLogLine(Data(line)), usage.date >= start { requests[key] = usage }
            }
        }
        return Array(requests.values)
    }

    static func parseClaudeLogLine(_ line: Data) -> (key: String, usage: LocalClaudeUsage)? {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              object["type"] as? String == "assistant",
              let message = object["message"] as? [String: Any],
              let usage = message["usage"] as? [String: Any],
              let id = message["id"] as? String,
              let timestamp = object["timestamp"] as? String,
              let date = parseLogDate(timestamp) else { return nil }
        let count = { (name: String) in usage[name] as? Int ?? 0 }
        let weight = weight(newInputTokens: count("input_tokens") + count("cache_creation_input_tokens"),
                            cachedInputTokens: count("cache_read_input_tokens"), outputTokens: count("output_tokens"))
        return ("\(id)|\(object["requestId"] as? String ?? "")", LocalClaudeUsage(date: date, weight: weight))
    }

    private static func parseLogDate(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }

    // MARK: Codex

    /// `measured` with one request's movement added: each window keeps its running total, and a
    /// window that has reset starts again from nothing.
    static func adding(before: PlanLimitSnapshot, after: PlanLimitSnapshot, to measured: [MeasuredPlanWindow]) -> [MeasuredPlanWindow] {
        after.windows.map { window in
            let running = measured.first { $0.title == window.title && isSameWindow($0.resetsAt, window.resetsAt) }?.usedFraction ?? 0
            let start = before.windows.first { $0.title == window.title && isSameWindow($0.resetsAt, window.resetsAt) }
            let moved = start.map { max(0, window.usedFraction - $0.usedFraction) } ?? 0
            return MeasuredPlanWindow(title: window.title, resetsAt: window.resetsAt, usedFraction: running + moved)
        }
    }

    /// OpenClicky's part of a Codex bar; nil until a request has been measured in this window.
    static func codexFraction(of window: PlanLimitWindow, measured: [MeasuredPlanWindow]) -> Double? {
        measured.first { $0.title == window.title && isSameWindow($0.resetsAt, window.resetsAt) }
            .map { min($0.usedFraction, window.usedFraction) }
    }

    // MARK: Showing it

    static func label(forFraction fraction: Double) -> String {
        let percent = Int((fraction * 100).rounded())
        return percent < 1 ? "under 1% OpenClicky" : "about \(percent)% OpenClicky"
    }
}
