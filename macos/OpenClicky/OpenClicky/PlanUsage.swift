//
//  PlanUsage.swift
//  OpenClicky
//
//  What the Claude and Codex plans have used. Two kinds of numbers:
//    - `PlanUsageLedger`: what OpenClicky itself sent, counted per request in
//      ~/.openclicky/usage.jsonl (counts only, never the words).
//    - `PlanLimitStore`: how full the plan's own limits are, as the CLIs report them. These cover
//      everything on the account, not just OpenClicky.
//  `PlanAvailability` remembers which plan has run out and until when, which is what the router
//  asks when it picks who answers.
//

import Combine
import Foundation

nonisolated struct PlanUsageSample: Codable, Equatable, Sendable {
    enum Lane: String, Codable, Sendable { case answer, agent }

    var date: Date
    var source: String
    var lane: Lane
    /// Everything sent, cached or not.
    var inputTokens: Int
    /// The part of `inputTokens` served from the cache.
    var cachedInputTokens: Int
    var outputTokens: Int
    /// Claude only: an estimate at list price, not what a plan is charged.
    var estimatedCostUSD: Double?
}

nonisolated struct PlanUsageTotals: Equatable, Sendable {
    var requests = 0
    var tokens = 0
    var estimatedCostUSD: Double?

    mutating func add(_ sample: PlanUsageSample) {
        requests += 1
        tokens += sample.inputTokens + sample.outputTokens
        if let cost = sample.estimatedCostUSD { estimatedCostUSD = (estimatedCostUSD ?? 0) + cost }
    }
}

nonisolated final class PlanUsageLedger: @unchecked Sendable {
    static let shared = PlanUsageLedger(fileURL: URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".openclicky/usage.jsonl"))
    static let changedNotification = Notification.Name("openClickyPlanUsageChanged")

    private let fileURL: URL
    private let lock = NSLock()

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    func record(_ sample: PlanUsageSample) {
        guard var line = try? JSONEncoder().encode(sample) else { return }
        line.append(UInt8(ascii: "\n"))
        lock.lock(); defer { lock.unlock() }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let handle = try? FileHandle(forWritingTo: fileURL) {
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: line)
            } else {
                try line.write(to: fileURL, options: .atomic)
            }
        } catch {
            AppLog.append("usage: could not write the ledger: \(error.localizedDescription)")
            return
        }
        DispatchQueue.main.async { NotificationCenter.default.post(name: Self.changedNotification, object: nil) }
    }

    /// Every readable sample; a line that cannot be read is skipped rather than losing the rest.
    func samples() -> [PlanUsageSample] {
        lock.lock(); defer { lock.unlock() }
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return data.split(separator: UInt8(ascii: "\n")).compactMap { try? JSONDecoder().decode(PlanUsageSample.self, from: Data($0)) }
    }

    func totals(for source: AnswerSource, since start: Date = .distantPast) -> PlanUsageTotals {
        var totals = PlanUsageTotals()
        for sample in samples() where sample.source == source.rawValue && sample.date >= start { totals.add(sample) }
        return totals
    }
}

nonisolated struct PlanLimitWindow: Codable, Equatable, Sendable {
    var title: String
    var usedFraction: Double
    var resetsAt: Date?
}

nonisolated struct PlanLimitSnapshot: Codable, Equatable, Sendable {
    var windows: [PlanLimitWindow] = []
    /// The plan refused, or said it would refuse, the next request.
    var isRejected = false
    /// When a refusal lifts, when the plan said so outside any one window.
    var resetsAt: Date?
    /// Credits bought on top of the plan (Codex), when there are any.
    var creditsBalance: String?
    var planName: String?

    /// When this plan can be used again, if it has run out.
    var exhaustedUntil: Date? {
        let full = windows.filter { $0.usedFraction >= 1 }.compactMap(\.resetsAt)
        if let latest = full.max() { return latest }
        return isRejected ? resetsAt : nil
    }

    var isExhausted: Bool { isRejected || windows.contains { $0.usedFraction >= 1 } }

    static func windowTitle(minutes: Int) -> String {
        if minutes >= 1440, minutes % 1440 == 0 { return "\(minutes / 1440) \(minutes == 1440 ? "day" : "days")" }
        if minutes >= 60, minutes % 60 == 0 { return "\(minutes / 60) \(minutes == 60 ? "hour" : "hours")" }
        return "\(minutes) min"
    }

    /// `rate_limit_info` from `claude -p --output-format stream-json`: `unifiedWindows` holds
    /// `utilization` as a fraction (0.06 is 6%) and `resetsAt` in Unix seconds.
    static func fromClaude(rateLimitInfo info: [String: Any]) -> PlanLimitSnapshot {
        var snapshot = PlanLimitSnapshot()
        snapshot.isRejected = info["status"] as? String == "rejected"
        snapshot.resetsAt = (info["resetsAt"] as? Double).map(Date.init(timeIntervalSince1970:))
        let known = [("five_hour", "5 hours"), ("seven_day", "7 days")]
        let unified = info["unifiedWindows"] as? [String: Any] ?? [:]
        let names = known.map(\.0).filter { unified[$0] != nil } + unified.keys.filter { key in !known.contains { $0.0 == key } }.sorted()
        for name in names {
            guard let window = unified[name] as? [String: Any], let utilization = window["utilization"] as? Double else { continue }
            let title = known.first { $0.0 == name }?.1 ?? name.replacingOccurrences(of: "_", with: " ")
            snapshot.windows.append(PlanLimitWindow(
                title: title, usedFraction: min(max(utilization, 0), 1),
                resetsAt: (window["resetsAt"] as? Double).map(Date.init(timeIntervalSince1970:))))
        }
        return snapshot
    }

    /// The reply to the Codex app-server's `account/rateLimits/read`.
    static func fromCodex(rateLimitsResult result: [String: Any]) -> PlanLimitSnapshot? {
        guard let limits = result["rateLimits"] as? [String: Any] else { return nil }
        var snapshot = PlanLimitSnapshot()
        for key in ["primary", "secondary"] {
            guard let window = limits[key] as? [String: Any], let used = window["usedPercent"] as? Double else { continue }
            snapshot.windows.append(PlanLimitWindow(
                title: (window["windowDurationMins"] as? Int).map(windowTitle(minutes:)) ?? key,
                usedFraction: min(max(used / 100, 0), 1),
                resetsAt: (window["resetsAt"] as? Double).map(Date.init(timeIntervalSince1970:))))
        }
        snapshot.isRejected = result["ordinaryUsageAllowed"] as? Bool == false || !(limits["rateLimitReachedType"] is NSNull || limits["rateLimitReachedType"] == nil)
        if let credits = limits["credits"] as? [String: Any], credits["hasCredits"] as? Bool == true {
            snapshot.creditsBalance = credits["balance"] as? String
        }
        snapshot.planName = limits["planType"] as? String
        return snapshot
    }
}

/// Which plan has run out, and until when. Read from any thread by the router; survives a relaunch.
nonisolated final class PlanAvailability: @unchecked Sendable {
    static let shared = PlanAvailability(defaults: .standard)
    /// How long to rest a plan whose refusal gave no reset time.
    static let restWithoutResetTime: TimeInterval = 30 * 60
    private static let defaultsKey = "openclicky.plans.exhaustedUntil"

    private let defaults: UserDefaults
    private let lock = NSLock()

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    func markExhausted(_ source: AnswerSource, until: Date?, now: Date = Date()) {
        lock.lock(); defer { lock.unlock() }
        var entries = defaults.dictionary(forKey: Self.defaultsKey) as? [String: Double] ?? [:]
        let end = until.flatMap { $0 > now ? $0 : nil } ?? now.addingTimeInterval(Self.restWithoutResetTime)
        entries[source.rawValue] = end.timeIntervalSince1970
        defaults.set(entries, forKey: Self.defaultsKey)
        AppLog.append("plans: \(source.rawValue) has hit its limit, resting it")
    }

    func clear(_ source: AnswerSource) {
        lock.lock(); defer { lock.unlock() }
        var entries = defaults.dictionary(forKey: Self.defaultsKey) as? [String: Double] ?? [:]
        guard entries.removeValue(forKey: source.rawValue) != nil else { return }
        defaults.set(entries, forKey: Self.defaultsKey)
    }

    func exhaustedUntil(_ source: AnswerSource, now: Date = Date()) -> Date? {
        lock.lock(); defer { lock.unlock() }
        let entries = defaults.dictionary(forKey: Self.defaultsKey) as? [String: Double] ?? [:]
        guard let end = entries[source.rawValue].map(Date.init(timeIntervalSince1970:)), end > now else { return nil }
        return end
    }

    func exhaustedPlans(now: Date = Date()) -> Set<AnswerSource> {
        Set([AnswerSource.claudeCodePlan, .codexPlan].filter { exhaustedUntil($0, now: now) != nil })
    }
}

/// Where a plan provider reports what a request used. The default reports nowhere, so a test never
/// writes to the real ledger; `AnswerProviderFactory` hands providers `.live`.
nonisolated struct PlanUsageSink: Sendable {
    var record: @Sendable (PlanUsageSample) -> Void = { _ in }
    var limits: @Sendable (AnswerSource, PlanLimitSnapshot) -> Void = { _, _ in }
    /// Called as a Codex request starts; call what it returns when the request ends.
    var beginCodexRequest: @Sendable () async -> @Sendable () -> Void = { { } }

    static let none = PlanUsageSink()
    static let live = PlanUsageSink(
        record: { sample in
            PlanUsageLedger.shared.record(sample)
            if sample.source == AnswerSource.codexPlan.rawValue {
                Task { @MainActor in await PlanLimitStore.shared.refreshCodex() }
            }
        },
        limits: { source, snapshot in
            Task { @MainActor in PlanLimitStore.shared.ingest(snapshot, for: source) }
        },
        beginCodexRequest: { await PlanLimitStore.shared.beginCodexRequest() })
}

@MainActor
final class PlanLimitStore: ObservableObject {
    static let shared = PlanLimitStore(defaults: .standard, availability: .shared)
    private static let defaultsKey = "openclicky.plans.limits"
    private static let measuredKey = "openclicky.plans.codexMeasured"
    private static let claudeBaselinesKey = "openclicky.plans.claudeBaselines"
    private static let codexRefreshInterval: TimeInterval = 60
    /// Codex can take a moment to count a finished request against its limits.
    nonisolated static let codexSettleNanoseconds: UInt64 = 5_000_000_000

    @Published private(set) var snapshots: [AnswerSource: PlanLimitSnapshot] = [:]
    /// How far Codex's limits moved across OpenClicky's requests (PlanUsageShare).
    @Published private(set) var codexMeasured: [MeasuredPlanWindow] = []
    /// How full Claude's bars were when OpenClicky first used each window (PlanUsageShare).
    @Published private(set) var claudeBaselines: [MeasuredPlanWindow] = []

    private let defaults: UserDefaults
    private let availability: PlanAvailability
    private let readCodex: () async -> PlanLimitSnapshot?
    private var lastCodexRead: Date?

    init(defaults: UserDefaults, availability: PlanAvailability,
         readCodex: @escaping () async -> PlanLimitSnapshot? = { await CodexRateLimits.read() }) {
        self.defaults = defaults
        self.availability = availability
        self.readCodex = readCodex
        if let data = defaults.data(forKey: Self.defaultsKey),
           let saved = try? JSONDecoder().decode([String: PlanLimitSnapshot].self, from: data) {
            for (name, snapshot) in saved { if let source = AnswerSource(rawValue: name) { snapshots[source] = snapshot } }
        }
        if let data = defaults.data(forKey: Self.measuredKey),
           let saved = try? JSONDecoder().decode([MeasuredPlanWindow].self, from: data) {
            codexMeasured = saved
        }
        if let data = defaults.data(forKey: Self.claudeBaselinesKey),
           let saved = try? JSONDecoder().decode([MeasuredPlanWindow].self, from: data) {
            claudeBaselines = saved
        }
    }

    /// Reads Codex's limits now, without holding up the request, and again once it has ended; the
    /// difference is added to what OpenClicky has used of each window. Reading costs no usage.
    func beginCodexRequest(settleNanoseconds: UInt64 = PlanLimitStore.codexSettleNanoseconds) -> @Sendable () -> Void {
        let reading = Task { await readCodex() }
        return { [weak self] in
            Task { @MainActor [weak self] in
                let before = await reading.value
                try? await Task.sleep(nanoseconds: settleNanoseconds)
                guard let self, let after = await self.readCodex() else { return }
                self.lastCodexRead = Date()
                if let before { self.recordCodexMeasurement(before: before, after: after) }
                self.ingest(after, for: .codexPlan)
            }
        }
    }

    private func recordCodexMeasurement(before: PlanLimitSnapshot, after: PlanLimitSnapshot) {
        codexMeasured = PlanUsageShare.adding(before: before, after: after, to: codexMeasured)
        if let data = try? JSONEncoder().encode(codexMeasured) { defaults.set(data, forKey: Self.measuredKey) }
    }

    func ingest(_ snapshot: PlanLimitSnapshot, for source: AnswerSource) {
        snapshots[source] = snapshot
        if source == .claudeCodePlan {
            claudeBaselines = PlanUsageShare.updatingBaselines(claudeBaselines, with: snapshot)
            if let data = try? JSONEncoder().encode(claudeBaselines) { defaults.set(data, forKey: Self.claudeBaselinesKey) }
        }
        if snapshot.isExhausted {
            availability.markExhausted(source, until: snapshot.exhaustedUntil)
        } else {
            availability.clear(source)
        }
        let saved = Dictionary(uniqueKeysWithValues: snapshots.map { ($0.key.rawValue, $0.value) })
        if let data = try? JSONEncoder().encode(saved) { defaults.set(data, forKey: Self.defaultsKey) }
        ShellSettingsRevision.shared.noteChanged()
    }

    func refreshCodex(force: Bool = false, now: Date = Date()) async {
        if !force, let lastCodexRead, now.timeIntervalSince(lastCodexRead) < Self.codexRefreshInterval { return }
        lastCodexRead = now
        if let snapshot = await readCodex() { ingest(snapshot, for: .codexPlan) }
    }

    /// A plan just refused a request. Codex can be asked when it comes back; Claude has already
    /// said in the same stream.
    func noteLimitHit(_ source: AnswerSource) async {
        if source == .codexPlan { await refreshCodex(force: true) }
        if availability.exhaustedUntil(source) == nil {
            availability.markExhausted(source, until: snapshots[source]?.exhaustedUntil)
        }
        ShellSettingsRevision.shared.noteChanged()
    }
}

/// Asks `codex app-server` how full the ChatGPT plan's limits are. CODEX_HOME is removed from its
/// environment (`PlanCLIs.processEnvironment`), so this reads the person's own sign-in.
nonisolated enum CodexRateLimits {
    static func read() async -> PlanLimitSnapshot? {
        guard let path = await PlanCLIs.codexPath() else { return nil }
        return await read(executablePath: path, environment: PlanCLIs.processEnvironment(forExecutableAt: path), timeoutSeconds: 15)
    }

    /// The JSON-RPC lines that ask, in order. `initialized` goes out once `initialize` has answered.
    static func initializeLine() -> Data {
        Data(#"{"id":1,"method":"initialize","params":{"clientInfo":{"name":"openclicky","version":"1"}}}"#.utf8 + [UInt8(ascii: "\n")])
    }
    static func readLines() -> Data {
        Data(#"{"method":"initialized"}"#.utf8 + [UInt8(ascii: "\n")] + #"{"id":2,"method":"account/rateLimits/read"}"#.utf8 + [UInt8(ascii: "\n")])
    }

    private final class Session: @unchecked Sendable {
        let lock = NSLock()
        var buffered = Data()
        var continuation: CheckedContinuation<PlanLimitSnapshot?, Never>?

        func finish(_ snapshot: PlanLimitSnapshot?) {
            lock.lock()
            let waiting = continuation
            continuation = nil
            lock.unlock()
            waiting?.resume(returning: snapshot)
        }
    }

    static func read(executablePath: String, environment: [String: String], timeoutSeconds: TimeInterval) async -> PlanLimitSnapshot? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = ["app-server"]
        process.environment = environment
        process.currentDirectoryURL = FileManager.default.temporaryDirectory
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let session = Session()

        let snapshot: PlanLimitSnapshot? = await withCheckedContinuation { continuation in
            session.continuation = continuation
            output.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                guard !chunk.isEmpty else { session.finish(nil); return }
                session.lock.lock()
                session.buffered.append(chunk)
                var lines: [Data] = []
                while let newline = session.buffered.firstIndex(of: UInt8(ascii: "\n")) {
                    lines.append(Data(session.buffered[session.buffered.startIndex..<newline]))
                    session.buffered = Data(session.buffered[session.buffered.index(after: newline)...])
                }
                session.lock.unlock()
                for line in lines {
                    guard let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any], let id = message["id"] as? Int else { continue }
                    if id == 1 {
                        try? input.fileHandleForWriting.write(contentsOf: readLines())
                    } else if id == 2 {
                        session.finish((message["result"] as? [String: Any]).flatMap(PlanLimitSnapshot.fromCodex(rateLimitsResult:)))
                    }
                }
            }
            do {
                try process.run()
                try input.fileHandleForWriting.write(contentsOf: initializeLine())
            } catch {
                session.finish(nil)
                return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeoutSeconds) { session.finish(nil) }
        }
        output.fileHandleForReading.readabilityHandler = nil
        if process.isRunning { process.terminate() }
        return snapshot
    }
}

/// Words the plan CLIs use when a plan has run out.
nonisolated enum PlanLimitText {
    static func matches(_ text: String) -> Bool {
        let lowercased = text.lowercased()
        return ["usage limit", "rate_limit", "rate limit", "hit your limit", "limit reached", "limit exceeded", "quota"].contains { lowercased.contains($0) }
    }
}

/// Switches on Codex if it is already signed in, once: a plan someone switched off stays off.
/// Claude is never switched on here: using a Claude plan with OpenClicky is at the person's own risk
/// (README, Claude plan warning), so it waits for them to press Sign In or flip its switch.
enum PlanAutoLink {
    static func run() async {
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        guard OpenClickyConfiguration.settings.useCodexPlan == nil, await PlanCLIs.codexStatus() == .ready else { return }
        OpenClickyConfiguration.update { $0.useCodexPlan = true }
        ShellSettingsRevision.shared.noteChanged()
        AppLog.append("plans: linked codex, already signed in")
    }
}
