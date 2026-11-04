//
//  ClaudeLimitRings.swift
//  OpenClicky
//
//  Claude's plan limits for the Coding agents component: the figures `claude -p` reports with each
//  answer (`PlanLimitStore`). OpenClicky must not read Claude Code's sign-in or call Anthropic with
//  it: subscription tokens are not for other apps. So the rings only move when Clicky answers on
//  the Claude plan, and a window that has reset is left out because its figure is no longer true.
//

import Foundation

struct ClaudeLimitRing: Equatable {
    var label: String
    var fraction: Double
    var resetsAt: Date?
}

enum ClaudeLimitRings {
    /// The window titles `PlanLimitSnapshot.fromClaude` writes, with what each ring says.
    private static let labelsByWindowTitle = [("5 hours", "5 h"), ("7 days", "7 d")]

    static func rings(from snapshot: PlanLimitSnapshot?, now: Date) -> [ClaudeLimitRing] {
        labelsByWindowTitle.compactMap { windowTitle, label in
            guard let window = snapshot?.windows.first(where: { $0.title == windowTitle }) else { return nil }
            if let resetsAt = window.resetsAt, resetsAt <= now { return nil }
            return ClaudeLimitRing(label: label, fraction: window.usedFraction, resetsAt: window.resetsAt)
        }
    }

    /// "resets 2 h 10 m", "resets 35 m", "resets soon"; nothing without a date.
    static func resetText(until: Date?, now: Date) -> String {
        guard let until else { return "" }
        let seconds = Int(until.timeIntervalSince(now).rounded(.down))
        guard seconds >= 60 else { return "resets soon" }
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        return hours > 0 ? "resets \(hours) h \(minutes) m" : "resets \(minutes) m"
    }
}
