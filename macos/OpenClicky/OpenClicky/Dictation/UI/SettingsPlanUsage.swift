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
    @State private var samples: [PlanUsageSample] = []
    @State private var localClaudeUsage: [PlanUsageShare.LocalClaudeUsage] = []

    private var windows: [PlanLimitWindow] { limits.snapshots[plan]?.windows ?? [] }

    /// OpenClicky's rough part of one bar (PlanUsageShare).
    private func openClickyFraction(of window: PlanLimitWindow) -> Double? {
        plan == .codexPlan
            ? PlanUsageShare.codexFraction(of: window, measured: limits.codexMeasured)
            : PlanUsageShare.claudeFraction(of: window, samples: samples, localUsage: localClaudeUsage)
    }

    private var shareNote: String? {
        guard windows.contains(where: { openClickyFraction(of: $0) != nil }) else { return nil }
        return plan == .codexPlan
            ? "Orange is OpenClicky's rough share: how far the bar moved during its requests."
            : "Orange is OpenClicky's rough share, compared with Claude use logged on this computer."
    }

    var body: some View {
        SettingsRow(title: "\(plan.shortName) usage", detail: [Self.detail(today: today, month: month, snapshot: limits.snapshots[plan], pausedUntil: PlanAvailability.shared.exhaustedUntil(plan)), shareNote].compactMap { $0 }.joined(separator: "\n")) {
            VStack(alignment: .trailing, spacing: 6) {
                ForEach(windows, id: \.title) { window in
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("\(window.title): \(Int((window.usedFraction * 100).rounded()))% used")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                        PlanLimitBar(used: window.usedFraction, openClicky: openClickyFraction(of: window))
                        if let share = openClickyFraction(of: window) {
                            HStack(spacing: 4) {
                                Circle().fill(PlanLimitBar.openClickyColor).frame(width: 6, height: 6)
                                Text(PlanUsageShare.label(forFraction: share))
                                    .font(.system(size: 10)).foregroundStyle(.secondary)
                            }
                        }
                        if let reset = Self.resetText(window.resetsAt) {
                            Text(reset).font(.system(size: 10)).foregroundStyle(.tertiary)
                        }
                    }
                }
            }
        }
        .task {
            reload()
            await reloadLocalClaudeUsage()
            if plan == .codexPlan { await limits.refreshCodex(force: true) }
        }
        .onReceive(NotificationCenter.default.publisher(for: PlanUsageLedger.changedNotification)) { _ in
            reload()
            Task { await reloadLocalClaudeUsage() }
        }
    }

    private func reload() {
        let calendar = Calendar.current
        let now = Date()
        today = PlanUsageLedger.shared.totals(for: plan, since: calendar.startOfDay(for: now))
        let monthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: now)) ?? now
        month = PlanUsageLedger.shared.totals(for: plan, since: monthStart)
        samples = PlanUsageLedger.shared.samples()
    }

    /// Claude Code's logs, read away from the main thread, back as far as the oldest window starts.
    private func reloadLocalClaudeUsage() async {
        guard plan == .claudeCodePlan, let start = windows.compactMap(PlanUsageShare.start(of:)).min() else { return }
        localClaudeUsage = await Task.detached(priority: .utility) { PlanUsageShare.localClaudeUsage(since: start) }.value
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

/// A limit's bar: how full it is, with OpenClicky's rough part highlighted at the start.
struct PlanLimitBar: View {
    static let openClickyColor = Color.orange
    private static let width: CGFloat = 130
    private static let height: CGFloat = 6

    let used: Double
    let openClicky: Double?

    var body: some View {
        ZStack(alignment: .leading) {
            Capsule().fill(Color.primary.opacity(0.12))
            Capsule().fill(Color.accentColor).frame(width: Self.width * min(max(used, 0), 1))
            if let openClicky {
                // Always wide enough to see: "under 1%" is still something.
                Capsule().fill(Self.openClickyColor).frame(width: max(Self.height, Self.width * min(max(openClicky, 0), 1)))
            }
        }
        .frame(width: Self.width, height: Self.height)
        .accessibilityElement()
        .accessibilityLabel("\(Int((used * 100).rounded()))% used")
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
