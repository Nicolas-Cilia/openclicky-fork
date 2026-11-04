//
//  WordsPageView.swift
//  OpenClicky
//
//  "Your words": the record and history pages as one, drawn like the settings pages (a grouped
//  form with the system's own type and controls). At the top, how to dictate and who hears you;
//  a "try it here" box a take lands in when this window is in front; this week's count; then
//  every take, newest first, a section per day. Typing in the search filters the takes and
//  return asks a model across them; the answer names the takes it was drawn from. A row selects
//  with a click (details · copy), double-click opens it, a failed take offers retry · delete, and
//  every action is also on the row's context menu.
//

import AppKit
import Combine
import SwiftUI

struct WordsPageView: View {
    @ObservedObject var model: DictationWindowModel
    let companionManager: CompanionManager
    @ObservedObject private var settings: DictationSettings
    @ObservedObject private var controller: DictationTakeController

    // The "try it here" box.
    @State private var tryItHereText = ""

    // This week.
    @State private var stats = TakeStats(wordsToday: 0, takesToday: 0, wordsThisWeek: 0, takesThisWeek: 0, mostUsedAppToday: nil, allTimeTakes: 0)
    @State private var wordsPerDay: [(day: Date, words: Int)] = []

    // The takes.
    @State private var query = ""
    @State private var takes: [TakeRecord] = []
    @State private var modeFilter: TakeRecord.Mode?
    @State private var appFilter: String?
    @State private var appsUsed: [(bundleID: String, name: String?, count: Int)] = []
    @State private var revisedTakeIDs: Set<UUID> = []
    @State private var selectedTakeID: UUID?
    @State private var inspectedTake: TakeRecord?

    // Asking across the takes.
    @State private var answer: String?
    @State private var answerSources: [TakeRecord] = []
    @State private var isAsking = false

    /// The last read or write of the history file that failed, said under the search field.
    @State private var historyProblem: String?

    init(model: DictationWindowModel, companionManager: CompanionManager) {
        self.model = model
        self.companionManager = companionManager
        self.settings = companionManager.dictationSettings
        self.controller = companionManager.dictationTakeController
    }

    var body: some View {
        Form {
            howToDictateSection
            tryItHereSection
            thisWeekSection
            searchSection
            if isAsking || answer != nil { answerSection }
            if takes.isEmpty {
                emptyTakesSection
            } else {
                ForEach(groupedByDay, id: \.title) { dayGroup in
                    daySection(dayGroup)
                }
            }
        }
        .formStyle(.grouped)
        .sheet(item: $inspectedTake) { take in
            WordsTakeDetailSheet(take: take, companionManager: companionManager, onClose: { inspectedTake = nil; reload() })
        }
        .onChange(of: query) { _, _ in reload() }
        .onAppear {
            if let pendingSearch = model.pendingHistorySearch {
                query = pendingSearch
                model.pendingHistorySearch = nil
            }
            reload()
        }
        .onReceive(controller.$historyVersion) { _ in reload() }
        .onReceive(controller.$lastTake.dropFirst().compactMap { $0 }) { take in
            // A take while this window was in front and no field took it: it lands here. (A take
            // pasted into the box itself is already there — verified — and is not added twice.)
            if take.pasteOutcome == .leftInOrb || (take.appBundleID == Bundle.main.bundleIdentifier && take.pasteOutcome != .verified) {
                tryItHereText = tryItHereText.isEmpty ? take.displayText : tryItHereText + " " + take.displayText
            }
        }
    }

    // MARK: how to dictate, and who hears you

    private var howToDictateSection: some View {
        let keyLabel = settings.dictationKey.keycapLabel
        let unavailableReason = DictationEngineResolver.unavailableReason(for: settings.engine)
        return Section {
            SettingsRow(
                title: "Hold \(keyLabel) in any app, speak, let go.",
                detail: "Words are tidied for the app in front and pasted at the cursor. Tap to start, tap to finish; Esc discards.") {
                SettingsKeys(keys: [keyLabel], gesture: "hold")
            }
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(unavailableReason == nil ? SettingsLook.success : SettingsLook.danger)
                            .frame(width: 7, height: 7)
                            .accessibilityHidden(true)
                        Text(settings.engine.howToDictateTitle).font(SettingsLook.rowTitle)
                    }
                    if let unavailableReason {
                        Text(Self.sentenceCased(unavailableReason) + ".")
                            .font(SettingsLook.caption).foregroundStyle(SettingsLook.danger)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text(Self.engineSentenceInSentenceCase(settings: settings, hasPolisher: DictationEngineResolver.makePolisher() != nil))
                            .font(SettingsLook.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 16)
                Button("Change Engine…") { companionManager.showSettings(.dictation) }
                    .pointerCursor()
                    .help("Opens Settings → Dictation")
            }
            .padding(.vertical, SettingsLook.Metric.rowVertical)
            .accessibilityElement(children: .contain)
        }
    }

    /// Where a take's voice and words go, in lower case. The polish half reads the same rule the
    /// take does. Kept for the tests that pin that rule down; the page shows the sentence-case
    /// version, of which this is exactly the lower-cased form.
    static func engineSentence(settings: DictationSettings, hasPolisher: Bool) -> String {
        engineSentenceInSentenceCase(settings: settings, hasPolisher: hasPolisher).lowercased()
    }

    /// Where a take's voice and words go, as the page shows it.
    static func engineSentenceInSentenceCase(settings: DictationSettings, hasPolisher: Bool) -> String {
        let history = settings.incognito ? "Incognito: nothing is saved." : "Your history stays on this Mac."
        guard settings.engine.isOnDevice else {
            return settings.engine.audioDestinationSentence + " " + history
        }
        if DictationEngineResolver.wantsModelPolish(settings: settings) && hasPolisher {
            return "Your voice stays on this Mac; the words go to a model for polish. " + history
        }
        return settings.incognito ? "Your voice stays on this Mac, and nothing is saved." : "Your voice and your history stay on this Mac."
    }

    /// The resolver's reasons are written in lower case ("needs your sarvam key") for the orb;
    /// this page writes sentences, so the first letter and the product names get their capitals.
    static func sentenceCased(_ lowercaseSentence: String) -> String {
        let properNames = ["openclicky": "OpenClicky", "openai": "OpenAI", "assemblyai": "AssemblyAI", "sarvam": "Sarvam", "mac": "Mac"]
        var sentence = lowercaseSentence
        for (lowercaseName, properName) in properNames {
            sentence = sentence.replacingOccurrences(of: "\\b\(lowercaseName)\\b", with: properName, options: .regularExpression)
        }
        guard let firstCharacter = sentence.first else { return sentence }
        return firstCharacter.uppercased() + sentence.dropFirst()
    }

    // MARK: try it here

    /// The box a take lands in when this window is in front and no field took it.
    private var tryItHereSection: some View {
        let wordCount = tryItHereText.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
        return Section {
            TextEditor(text: $tryItHereText)
                .font(SettingsLook.body(13))
                .scrollContentBackground(.hidden)
                .scrollIndicators(.never)
                .frame(height: 64)
                .overlay(alignment: .topLeading) {
                    if tryItHereText.isEmpty {
                        Text("With this window in front, your words land here.")
                            .font(SettingsLook.body(13)).foregroundStyle(SettingsLook.inkTertiary)
                            .padding(.leading, 5)
                            .allowsHitTesting(false)
                    }
                }
            HStack(spacing: 8) {
                Text(wordCount == 1 ? "1 word" : "\(wordCount) words")
                    .font(SettingsLook.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(tryItHereText, forType: .string)
                }
                .controlSize(.small)
                .pointerCursor(isEnabled: !tryItHereText.isEmpty)
                .disabled(tryItHereText.isEmpty)
                Button("Clear") { tryItHereText = "" }
                    .controlSize(.small)
                    .pointerCursor(isEnabled: !tryItHereText.isEmpty)
                    .disabled(tryItHereText.isEmpty)
            }
        } header: {
            Text("Try it here")
        }
    }

    // MARK: this week

    private var thisWeekSection: some View {
        Section {
            HStack(alignment: .bottom, spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(stats.wordsThisWeek.formatted())
                        .font(.system(size: 28, weight: .semibold))
                        .monospacedDigit()
                    Text("words in \(stats.takesThisWeek) \(stats.takesThisWeek == 1 ? "take" : "takes")")
                        .font(SettingsLook.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 16)
                weekBars
            }
            .padding(.vertical, 4)
            .accessibilityElement(children: .combine)
            LabeledContent("Today") {
                Text("\(stats.wordsToday.formatted()) \(stats.wordsToday == 1 ? "word" : "words") · \(stats.takesToday) \(stats.takesToday == 1 ? "take" : "takes")")
            }
            LabeledContent("All time") {
                Text("\(stats.allTimeTakes.formatted()) \(stats.allTimeTakes == 1 ? "take" : "takes")")
            }
        } header: {
            Text("This week")
        }
    }

    /// Seven bars, today on the right in the accent, scaled to the busiest day.
    private var weekBars: some View {
        let busiestDayWords = max(1, wordsPerDay.map(\.words).max() ?? 1)
        let maximumBarHeight: CGFloat = 36
        return HStack(alignment: .bottom, spacing: 5) {
            ForEach(Array(wordsPerDay.enumerated()), id: \.offset) { index, entry in
                let isToday = index == wordsPerDay.count - 1
                VStack(spacing: 3) {
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(isToday ? SettingsLook.accent : Color.secondary.opacity(0.35))
                        .frame(width: 14, height: max(2, maximumBarHeight * CGFloat(entry.words) / CGFloat(busiestDayWords)))
                        .help("\(entry.words) words")
                    Text(Self.weekdayInitial.string(from: entry.day))
                        .font(SettingsLook.micro).foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(Self.weekdayName.string(from: entry.day)): \(entry.words) words")
            }
        }
        .frame(height: maximumBarHeight + 16, alignment: .bottom)
    }

    // MARK: search and ask

    private var searchSection: some View {
        Section {
            HStack(spacing: 8) {
                TextField("Search", text: $query, prompt: Text("What did I say about…?"))
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                    .onSubmit(ask)
                if !query.isEmpty {
                    Button(action: clearSearch) {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .pointerCursor()
                    .help("Clear the search")
                    .accessibilityLabel("Clear the search")
                }
                Button("Ask", action: ask)
                    .pointerCursor(isEnabled: canAsk)
                    .disabled(!canAsk)
                    .help("Ask a model across your takes (Return)")
            }
            Picker("App", selection: $appFilter) {
                Text("All apps").tag(String?.none)
                ForEach(appsUsed, id: \.bundleID) { app in
                    Text(appName(app)).tag(String?.some(app.bundleID))
                }
            }
            .pointerCursor()
            Picker("Kind", selection: $modeFilter) {
                Text("Every kind of take").tag(TakeRecord.Mode?.none)
                Text("Dictations").tag(TakeRecord.Mode?.some(.dictate))
                Text("Hey Clicky edits").tag(TakeRecord.Mode?.some(.edit))
                if settings.clipboardHistoryEnabled || modeFilter == .clipboard {
                    Text("Clipboard").tag(TakeRecord.Mode?.some(.clipboard))
                }
            }
            .pointerCursor()
        } header: {
            Text("Your takes")
        } footer: {
            // Without these lines a take missing from history, or a delete that did nothing, has
            // no explanation anywhere.
            if companionManager.dictationTakeStore == nil {
                Text("History can't be saved on this Mac right now. Takes still paste; the log says why.")
                    .font(SettingsLook.caption).foregroundStyle(SettingsLook.danger)
            } else if let historyProblem {
                Text(historyProblem).font(SettingsLook.caption).foregroundStyle(SettingsLook.danger)
            } else {
                Text("Type to filter your takes; press Return to ask a model across them.")
                    .font(SettingsLook.caption).foregroundStyle(.secondary)
            }
        }
        .onChange(of: appFilter) { _, _ in reload() }
        .onChange(of: modeFilter) { _, _ in reload() }
    }

    private var canAsk: Bool {
        !query.trimmingCharacters(in: .whitespaces).isEmpty && !isAsking
    }

    private func clearSearch() {
        query = ""
        answer = nil
        answerSources = []
        reload()
    }

    private var answerSection: some View {
        Section {
            HStack(alignment: .top, spacing: 12) {
                if isAsking {
                    ProgressView().controlSize(.small)
                    Text("Asking across your takes…").foregroundStyle(.secondary)
                } else if let answer {
                    Text(answer)
                        .font(SettingsLook.body(13))
                        .lineSpacing(2)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                if !isAsking {
                    Button(action: { answer = nil; answerSources = [] }) {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .pointerCursor()
                    .help("Close the answer")
                    .accessibilityLabel("Close the answer")
                }
            }
            .padding(.vertical, 2)
            if !isAsking {
                ForEach(answerSources) { source in
                    Button(action: { reveal(source) }) {
                        HStack(spacing: 10) {
                            takeIcon(source)
                            Text(source.displayText.replacingOccurrences(of: "\n", with: " "))
                                .lineLimit(1)
                                .foregroundStyle(.primary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text(sourceLabel(source)).font(SettingsLook.caption).foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                    .help("Show this take in the list")
                }
            }
        } header: {
            Text(answerCaption)
        }
    }

    private var answerCaption: String {
        if isAsking { return "Asking a model" }
        if answerSources.isEmpty { return "Answer from your latest takes" }
        return "Answer from \(answerSources.count) \(answerSources.count == 1 ? "take" : "takes") that match"
    }

    /// When and where a source take was said: "3:04 PM · Mail", or with the date before yesterday.
    private func sourceLabel(_ take: TakeRecord) -> String {
        let calendar = Calendar.current
        let timeText = Self.time.string(from: take.createdAt)
        let when = calendar.isDateInToday(take.createdAt) || calendar.isDateInYesterday(take.createdAt)
            ? timeText
            : take.createdAt.formatted(.dateTime.day().month(.abbreviated)) + " " + timeText
        let app = take.appName ?? take.appBundleID.flatMap { AppIconCache.shared.name(for: $0) }
        return ([when] + [app].compactMap { $0 }).joined(separator: " · ")
    }

    /// A source selects its take in the list (clearing the filters that would hide it).
    private func reveal(_ take: TakeRecord) {
        if !takes.contains(where: { $0.id == take.id }) {
            modeFilter = nil
            appFilter = nil
            query = ""
            reload()
        }
        selectedTakeID = take.id
    }

    /// Return in the field: a question goes to the model over the matching takes.
    private func ask() {
        let question = query.trimmingCharacters(in: .whitespaces)
        guard !question.isEmpty, !isAsking else { return }
        isAsking = true
        answerSources = Array(controller.historyMatches(for: question).prefix(8))
        Task {
            let reply = await controller.askHistory(question)
            answer = reply
            isAsking = false
        }
    }

    // MARK: the takes

    private var emptyTakesSection: some View {
        Section {
            Text(query.isEmpty ? "Your dictations will land here, with the app each one went to." : "No matching takes. Press Return to ask anyway.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 16)
        }
    }

    private struct DayGroup {
        let title: String
        let takes: [TakeRecord]
    }

    private var groupedByDay: [DayGroup] {
        let calendar = Calendar.current
        var takesByDay: [Date: [TakeRecord]] = [:]
        for take in takes { takesByDay[calendar.startOfDay(for: take.createdAt), default: []].append(take) }
        return takesByDay.keys.sorted(by: >).map { day in
            let title = calendar.isDateInToday(day) ? "Today" : calendar.isDateInYesterday(day) ? "Yesterday" : Self.day.string(from: day)
            return DayGroup(title: title, takes: takesByDay[day] ?? [])
        }
    }

    private func daySection(_ dayGroup: DayGroup) -> some View {
        Section {
            ForEach(dayGroup.takes) { take in
                WordsTakeRow(
                    take: take,
                    isSelected: selectedTakeID == take.id,
                    wasEdited: revisedTakeIDs.contains(take.id),
                    canRetry: controller.canRetry(takeID: take.id),
                    onSelect: { selectedTakeID = selectedTakeID == take.id ? nil : take.id },
                    onOpen: { inspectedTake = take },
                    onCopy: { copy(take) },
                    onRetry: { Task { await controller.retry(takeID: take.id) } },
                    onDelete: { delete(take) })
            }
        } header: {
            HStack {
                Text(dayGroup.title)
                Spacer()
                Text(dayGroup.takes.count == 1 ? "1 take" : "\(dayGroup.takes.count) takes")
                    .font(SettingsLook.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func takeIcon(_ take: TakeRecord) -> some View {
        if take.mode == .clipboard {
            Image(systemName: "doc.on.clipboard").foregroundStyle(.secondary).frame(width: 18)
        } else {
            AppIconView(bundleID: take.appBundleID, size: 18)
        }
    }

    private func appName(_ app: (bundleID: String, name: String?, count: Int)) -> String {
        app.name ?? AppIconCache.shared.name(for: app.bundleID) ?? app.bundleID
    }

    // MARK: data

    private static let time: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        return formatter
    }()

    private static let day: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE, d MMM"
        return formatter
    }()

    private static let weekdayInitial: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEEE"
        return formatter
    }()

    private static let weekdayName: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE"
        return formatter
    }()

    private func reload() {
        guard let store = companionManager.dictationTakeStore else { return }
        stats = (try? store.stats()) ?? stats
        wordsPerDay = (try? store.wordsPerDay()) ?? []
        appsUsed = (try? store.appsUsed()) ?? []
        revisedTakeIDs = (try? store.revisedTakeIDs()) ?? []
        var rows: [TakeRecord]
        do {
            rows = try store.recent(limit: 500, query: query.isEmpty ? nil : query, mode: modeFilter, appBundleID: appFilter)
        } catch {
            AppLog.append("history couldn't be read: \(error.localizedDescription)")
            historyProblem = "History couldn't be read just now. The log says why."
            rows = []
        }
        if !settings.clipboardHistoryEnabled, modeFilter == nil { rows = rows.filter { $0.mode != .clipboard } }
        takes = rows
    }

    private func copy(_ take: TakeRecord) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(take.displayText, forType: .string)
    }

    private func delete(_ take: TakeRecord) {
        if WordsHistoryWrite.perform("delete", takeID: take.id, { try companionManager.dictationTakeStore?.delete(takeID: take.id) }) {
            companionManager.dictationTakeController.audioStore.discard(takeID: take.id)
        } else {
            historyProblem = "Couldn't delete that take. The log says why."
        }
        if selectedTakeID == take.id { selectedTakeID = nil }
        controller.historyDidChange()
    }
}

/// A change this page makes to the history file (delete, pin, save an edit). A failure — the file
/// locked by another OpenClicky past the busy timeout, a full disk — is logged rather than lost.
private enum WordsHistoryWrite {
    @discardableResult
    static func perform(_ whatIsWritten: String, takeID: UUID, _ write: () throws -> Void) -> Bool {
        do {
            try write()
            return true
        } catch {
            AppLog.append("history \(whatIsWritten) failed for take \(takeID.uuidString.prefix(8)): \(error.localizedDescription)")
            return false
        }
    }
}

/// One take as a form row: the app it went to, its words, and the time. A click selects it and
/// shows Details and Copy; a failed take shows Retry and Delete instead; every action is also on
/// the context menu, and a double-click opens the take.
private struct WordsTakeRow: View {
    let take: TakeRecord
    let isSelected: Bool
    let wasEdited: Bool
    let canRetry: Bool
    let onSelect: () -> Void
    let onOpen: () -> Void
    let onCopy: () -> Void
    let onRetry: () -> Void
    let onDelete: () -> Void
    @State private var isHovered = false

    private static let time: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        return formatter
    }()

    var body: some View {
        HStack(spacing: 10) {
            if take.mode == .clipboard {
                Image(systemName: "doc.on.clipboard").foregroundStyle(.secondary).frame(width: 18)
            } else {
                AppIconView(bundleID: take.appBundleID, size: 18)
            }
            Text(take.displayText.isEmpty ? " " : take.displayText.replacingOccurrences(of: "\n", with: " "))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            if take.pinned {
                Image(systemName: "pin.fill").font(.system(size: 9)).foregroundStyle(SettingsLook.accent).help("Pinned")
            }
            if take.mode == .edit { SettingsTag(text: "Hey Clicky") }
            if take.status == .failed {
                Text(failureLine).font(SettingsLook.caption).foregroundStyle(SettingsLook.danger).lineLimit(1)
                if canRetry {
                    Button("Retry", action: onRetry)
                        .controlSize(.small)
                        .pointerCursor()
                        .help("Hear the saved recording again")
                }
                Button("Delete", role: .destructive, action: onDelete)
                    .controlSize(.small)
                    .pointerCursor()
                    .help("Delete this take")
            } else if isSelected {
                Button("Details…", action: onOpen)
                    .controlSize(.small)
                    .pointerCursor()
                    .help("Open the take to edit, pin, paste again or delete it")
                Button("Copy", action: onCopy)
                    .controlSize(.small)
                    .pointerCursor()
                    .help("Copy the take")
            } else if wasEdited {
                Text("Edited").font(SettingsLook.caption).foregroundStyle(.secondary)
            }
            Text(Self.time.string(from: take.createdAt))
                .font(SettingsLook.caption).foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(minWidth: 56, alignment: .trailing)
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(isSelected ? SettingsLook.selection : (isHovered ? Color.primary.opacity(0.04) : Color.clear)))
        .padding(.horizontal, -6)
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: onOpen)
        .onTapGesture(perform: onSelect)
        .onHover { isHovered = $0 }
        .pointerCursor()
        .contextMenu {
            Button("Copy", action: onCopy).disabled(take.displayText.isEmpty)
            Button("Details…", action: onOpen)
            if take.status == .failed && canRetry {
                Button("Retry", action: onRetry)
            }
            Divider()
            Button("Delete", role: .destructive, action: onDelete)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(take.displayText.isEmpty ? failureLine : take.displayText)
        .accessibilityHint("\(take.appName ?? "Unknown app"), \(Self.time.string(from: take.createdAt))")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .help("\(take.mode == .edit ? "Hey Clicky edit" : "Dictation") into \(take.appName ?? "an unknown app"). Double-click to open.")
    }

    private var failureLine: String {
        guard let reason = take.failureReason?.trimmingCharacters(in: .whitespacesAndNewlines), !reason.isEmpty else { return "Couldn't finish" }
        return "Couldn't finish: \(reason)"
    }
}

/// One take, opened: the written text to edit, the raw words, what happened to it, and copy,
/// pin, paste again, delete and save. A native sheet, like the rest of the page.
private struct WordsTakeDetailSheet: View {
    let take: TakeRecord
    let companionManager: CompanionManager
    let onClose: () -> Void
    @State private var editedText: String

    init(take: TakeRecord, companionManager: CompanionManager, onClose: @escaping () -> Void) {
        self.take = take
        self.companionManager = companionManager
        self.onClose = onClose
        _editedText = State(initialValue: take.displayText)
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    HStack(spacing: 10) {
                        AppIconView(bundleID: take.appBundleID, size: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(take.appName ?? "Take").font(SettingsLook.body(13, weight: .semibold))
                            Text(detailLine).font(SettingsLook.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Section {
                    TextEditor(text: $editedText)
                        .font(SettingsLook.body(13))
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 140)
                } header: {
                    Text("Written")
                }
                if take.rawText != take.formattedText, !take.rawText.isEmpty {
                    Section {
                        Text(take.rawText)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    } header: {
                        Text("What you said")
                    }
                }
                if let failureReason = take.failureReason {
                    Section {
                        Text(failureReason).foregroundStyle(SettingsLook.danger)
                    }
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack(spacing: 8) {
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(editedText, forType: .string)
                }
                .pointerCursor()
                Button(take.pinned ? "Unpin" : "Pin") {
                    WordsHistoryWrite.perform(take.pinned ? "unpin" : "pin", takeID: take.id, { try companionManager.dictationTakeStore?.setPinned(!take.pinned, takeID: take.id) })
                    companionManager.dictationTakeController.historyDidChange()
                    onClose()
                }
                .pointerCursor()
                Button("Paste Again") {
                    onClose()
                    // The window hides so the app behind it is in front for the paste.
                    NSApp.hide(nil)
                    let textToPaste = editedText
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { _ = FrontAppTextInserter.insert(textToPaste) }
                }
                .pointerCursor()
                .help("Hides OpenClicky, then pastes into the app behind it")
                Button("Delete", role: .destructive) {
                    if WordsHistoryWrite.perform("delete", takeID: take.id, { try companionManager.dictationTakeStore?.delete(takeID: take.id) }) {
                        companionManager.dictationTakeController.audioStore.discard(takeID: take.id)
                    }
                    companionManager.dictationTakeController.historyDidChange()
                    onClose()
                }
                .pointerCursor()
                Spacer()
                Button("Close", action: onClose)
                    .keyboardShortcut(.cancelAction)
                    .pointerCursor()
                if editedText != take.displayText {
                    Button("Save Edit") {
                        WordsHistoryWrite.perform("save edit", takeID: take.id, { try companionManager.dictationTakeStore?.revise(takeID: take.id, newText: editedText, editor: "history") })
                        companionManager.dictationTakeController.historyDidChange()
                        onClose()
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .pointerCursor()
                }
            }
            .padding(16)
        }
        .frame(width: 560, height: 460)
    }

    private var detailLine: String {
        var parts: [String] = []
        parts.append(take.createdAt.formatted(date: .abbreviated, time: .shortened))
        if take.durationSeconds > 0 { parts.append(String(format: "%.0f s", take.durationSeconds)) }
        if !take.engine.isEmpty { parts.append(take.engine) }
        switch take.pasteOutcome {
        case .verified: parts.append("Pasted")
        case .posted: parts.append("Pasted (unconfirmed)")
        case .leftInOrb: parts.append("Left in the orb")
        case .leftOnPasteboard: parts.append("Copied to the clipboard")
        case .none: break
        }
        return parts.joined(separator: " · ")
    }
}
