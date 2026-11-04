//
//  SettingsPlanUsage.swift
//  OpenClicky
//
//  Settings → Keys & Plans: each plan's usage. The first lines are what OpenClicky sent; the bars
//  are the plan's own limits, which count everything on that account.
//

import SwiftUI

struct PlanUsageRow: View {
    let plan: AnswerSource
    @ObservedObject private var limits = PlanLimitStore.shared
    @State private var today = PlanUsageTotals()
    @State private var month = PlanUsageTotals()

    var body: some View {
        SettingsRow(title: "\(plan.shortName) usage", detail: Self.detail(today: today, month: month, snapshot: limits.snapshots[plan], pausedUntil: PlanAvailability.shared.exhaustedUntil(plan))) {
            VStack(alignment: .trailing, spacing: 6) {
                ForEach(limits.snapshots[plan]?.windows ?? [], id: \.title) { window in
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("\(window.title): \(Int((window.usedFraction * 100).rounded()))% used")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                        ProgressView(value: window.usedFraction).frame(width: 130)
                        if let reset = Self.resetText(window.resetsAt) {
                            Text(reset).font(.system(size: 10)).foregroundStyle(.tertiary)
                        }
                    }
                }
            }
        }
        .task {
            reload()
            if plan == .codexPlan { await limits.refreshCodex(force: true) }
        }
        .onReceive(NotificationCenter.default.publisher(for: PlanUsageLedger.changedNotification)) { _ in reload() }
    }

    private func reload() {
        let calendar = Calendar.current
        let now = Date()
        today = PlanUsageLedger.shared.totals(for: plan, since: calendar.startOfDay(for: now))
        let monthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: now)) ?? now
        month = PlanUsageLedger.shared.totals(for: plan, since: monthStart)
    }

    nonisolated static func detail(today: PlanUsageTotals, month: PlanUsageTotals, snapshot: PlanLimitSnapshot?, pausedUntil: Date?) -> String {
        var lines = [
            "OpenClicky today: \(line(today)).",
            "This month: \(line(month)).",
        ]
        if let cost = month.estimatedCostUSD {
            lines.append(String(format: "About $%.2f at list price this month; your plan isn't charged this.", cost))
        }
        if let balance = snapshot?.creditsBalance { lines.append("Credits left: \(balance).") }
        if let pausedUntil {
            lines.append("Out of usage until \(pausedUntil.formatted(date: .omitted, time: .shortened)).")
        }
        if snapshot?.windows.isEmpty != false { lines.append("Limits appear after its next request.") }
        return lines.joined(separator: "\n")
    }

    private nonisolated static func line(_ totals: PlanUsageTotals) -> String {
        "\(totals.requests) \(totals.requests == 1 ? "request" : "requests"), \(totals.tokens.formatted()) tokens"
    }

    private static func resetText(_ date: Date?) -> String? {
        guard let date, date > Date() else { return nil }
        return "resets " + date.formatted(date: Calendar.current.isDateInToday(date) ? .omitted : .abbreviated, time: .shortened)
    }
}

/// Which plan takes over when the default runs out. Only plans are offered: a key is never used
/// without someone choosing it, so running out can't turn into a bill.
struct BackupSourceRow: View {
    @ObservedObject private var shellSettingsRevision = ShellSettingsRevision.shared

    var body: some View {
        let _ = shellSettingsRevision.revision
        let credentials = ProviderRouter.currentCredentials()
        let options = [AnswerSource.claudeCodePlan, .codexPlan].filter(credentials.canAnswer(with:))
        SettingsRow(title: "When it runs out", detail: detail(credentials)) {
            Picker("", selection: Binding(
                get: { OpenClickyConfiguration.settings.backupAnswerSource ?? "auto" },
                set: { choice in
                    OpenClickyConfiguration.update { $0.backupAnswerSource = choice == "auto" ? nil : choice }
                    ShellSettingsRevision.shared.noteChanged()
                }
            )) {
                Text("Use the other plan").tag("auto")
                Text("Don't switch").tag(ProviderCredentials.noBackup)
                if !options.isEmpty { Divider() }
                ForEach(options) { Text($0.displayName).tag($0.rawValue) }
            }
            .labelsHidden().fixedSize()
            .pointerCursor()
        }
    }

    private func detail(_ credentials: ProviderCredentials) -> String {
        guard let backup = credentials.backupSource else { return "No backup: link both plans to have one." }
        return "\(backup.shortName) answers until the default's limit resets. Agent tasks only run on Codex, so they pause instead."
    }
}
