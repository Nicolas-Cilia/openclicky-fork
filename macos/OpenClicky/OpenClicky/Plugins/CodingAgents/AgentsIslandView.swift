//
//  AgentsIslandView.swift
//  OpenClicky
//
//  The Coding agents component: up to three session rows (agent, project, what it is doing,
//  a running bar while live) on the left, Claude's two plan-limit rings on the right.
//

import SwiftUI

/// A plugin: the coding agents running on this Mac.
struct AgentsIslandComponent: IslandComponent {
    let id = IslandPluginRegistry.agentsID
    let title = "Coding agents"
    let symbolName = "terminal"
    let preferredHeight: CGFloat = 76
    let isPlugin = true
    let settingsDetail: String? = "Follows Claude Code and Codex sessions on this Mac from their own logs. Claude's plan limits show once Clicky has answered on your Claude plan."
    func isAvailable(in context: IslandContext) -> Bool { true }
    @MainActor func makeView(companionManager: CompanionManager, model: NotchHUDModel) -> AnyView {
        let hud = companionManager.notchHUDManager
        return AnyView(AgentsIslandView(sessions: hud.agentSessions, model: model))
    }
}

/// One session row, ready to draw.
struct AgentRow: Equatable, Identifiable {
    let id: String
    let agent: String
    let project: String
    let line: String
    let isLive: Bool
}

struct AgentsIslandView: View {
    @ObservedObject var sessions: AgentSessionWatcher
    @ObservedObject private var planLimits = PlanLimitStore.shared
    @ObservedObject var model: NotchHUDModel

    static let maximumRows = 3

    /// The first three sessions as rows; a stopped one says how long ago.
    static func rows(for sessions: [AgentSession], now: Date) -> [AgentRow] {
        sessions.prefix(maximumRows).map { session in
            let isLive = session.isLive(now: now)
            let line: String
            if isLive {
                line = session.activity.line
            } else {
                let minutes = max(0, Int(now.timeIntervalSince(session.lastEventAt) / 60))
                line = minutes == 0 ? "done just now" : "done \(minutes) min ago"
            }
            return AgentRow(id: session.id, agent: session.agent.displayName, project: session.project, line: line, isLive: isLive)
        }
    }

    static func overflowText(count: Int) -> String? {
        count > maximumRows ? "+\(count - maximumRows) more" : nil
    }

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            sessionsColumn
                .frame(maxWidth: .infinity, alignment: .topLeading)
            limits
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            sessions.beginWatching()
        }
        .onDisappear {
            sessions.endWatching()
        }
    }

    private var sessionsColumn: some View {
        let now = Date()
        let rows = Self.rows(for: sessions.sessions, now: now)
        return VStack(alignment: .leading, spacing: 4) {
            if rows.isEmpty {
                Text("nothing running")
                    .font(.system(size: 13))
                    .foregroundColor(DS.HUD.text)
                Text("start claude or codex in a terminal and it shows up here")
                    .font(.system(size: 11))
                    .foregroundColor(DS.HUD.text3)
                    .lineLimit(2)
            } else {
                ForEach(rows) { row in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(row.agent)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(DS.HUD.text)
                            Text(row.project)
                                .font(.system(size: 11))
                                .foregroundColor(DS.HUD.text2)
                                .lineLimit(1)
                            Text(row.line)
                                .font(.system(size: 11))
                                .foregroundColor(row.isLive ? DS.HUD.text : DS.HUD.text3)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                        if row.isLive {
                            IslandIndeterminateBar()
                                .frame(height: 2)
                        }
                    }
                }
                if let overflow = Self.overflowText(count: sessions.sessions.count) {
                    Text(overflow)
                        .font(.system(size: 10))
                        .foregroundColor(DS.HUD.text3)
                }
            }
        }
    }

    @ViewBuilder private var limits: some View {
        let rings = ClaudeLimitRings.rings(from: planLimits.snapshots[.claudeCodePlan], now: Date())
        if rings.isEmpty {
            limitsNote("claude limits show after clicky answers on your plan")
        } else {
            HStack(spacing: 10) {
                ForEach(rings, id: \.label) { UsageRing(ring: $0) }
            }
        }
    }

    private func limitsNote(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10))
            .foregroundColor(DS.HUD.text3)
            .frame(width: 96)
            .multilineTextAlignment(.trailing)
    }
}

/// One plan window: a ring with the percentage inside, the window's name and its reset under it.
private struct UsageRing: View {
    let ring: ClaudeLimitRing

    private var color: Color {
        if ring.fraction >= 1 { return DS.HUD.pointer }
        if ring.fraction > 0.8 { return DS.Colors.warning }
        return DS.HUD.text
    }

    var body: some View {
        VStack(spacing: 3) {
            ZStack {
                Circle().stroke(Color.white.opacity(0.12), lineWidth: 3)
                Circle()
                    .trim(from: 0, to: CGFloat(min(max(ring.fraction, 0), 1)))
                    .stroke(color, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text(SystemStatsFormatter.percent(ring.fraction))
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(DS.HUD.text)
                    .minimumScaleFactor(0.7)
            }
            .frame(width: 28, height: 28)
            Text(ring.label)
                .font(.system(size: 10))
                .foregroundColor(DS.HUD.text2)
            Text(ClaudeLimitRings.resetText(until: ring.resetsAt, now: Date()))
                .font(.system(size: 9))
                .foregroundColor(DS.HUD.text3)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(width: 78)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(ring.label) window \(SystemStatsFormatter.percent(ring.fraction)) used")
    }
}
