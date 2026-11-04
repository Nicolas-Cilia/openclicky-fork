//
//  PlanSignIn.swift
//  OpenClicky
//
//  Signs a plan in from Settings, so nobody has to open a terminal. This runs the CLI's own login
//  and nothing else: the CLI opens the browser, waits for the callback and keeps the credentials
//  where it always does. OpenClicky never sees or stores them, and its output is never logged,
//  because the sign-in links in it carry one-time values.
//
//    claude auth login --claudeai    the Claude plan, never Console API billing
//    codex login                     the ChatGPT plan
//
//  Both were checked with no terminal attached and stdin closed (claude 2.1.318, codex-cli 0.166.0):
//  each one opens its link and keeps waiting. Whether it worked is decided by asking the CLI's own
//  status check afterwards, not by the login's exit status.
//

import Combine
import Foundation

nonisolated enum PlanSignInOutcome: Equatable, Sendable {
    case signedIn
    case cancelled
    case notInstalled
    case timedOut
    /// The CLI's own reason, when it gave one that can be shown.
    case failed(String?)

    /// What the plan's row says afterwards; nil when its usual sentence already says it.
    func sentence(for plan: AnswerSource) -> String? {
        let command = PlanCLIs.signInCommand(for: plan)
        switch self {
        case .signedIn, .cancelled:
            return nil
        case .notInstalled:
            return "\(plan.shortName) isn’t installed on this Mac."
        case .timedOut:
            return "Sign-in timed out after \(Int(PlanCLIs.signInTimeoutSeconds / 60)) minutes. Try again, or run “\(command)” in Terminal."
        case .failed(let reason?):
            return "Couldn’t sign in: \(reason)"
        case .failed(nil):
            return "Sign-in didn’t finish. Try again, or run “\(command)” in Terminal."
        }
    }
}

extension PlanCLIs {
    /// Long enough to find a password or pass a two-factor check.
    nonisolated static let signInTimeoutSeconds: TimeInterval = 300

    nonisolated static func signInArguments(for plan: AnswerSource) -> [String]? {
        switch plan {
        case .claudeCodePlan: return ["auth", "login", "--claudeai"]
        case .codexPlan: return ["login"]
        default: return nil
        }
    }

    /// The same login, as someone would type it in a terminal.
    nonisolated static func signInCommand(for plan: AnswerSource) -> String {
        plan == .claudeCodePlan ? "claude auth login" : "codex login"
    }

    /// Signed in is whatever the status check says now, so a login that exits oddly after it worked
    /// still counts. A reason holding a link is dropped: those carry one-time values.
    nonisolated static func signInOutcome(output: PlanCLIProcessOutput, statusAfter: PlanCLIStatus) -> PlanSignInOutcome {
        if statusAfter == .ready { return .signedIn }
        if output.timedOut { return .timedOut }
        guard output.exitStatus != 0, let reason = lastNonEmptyLine(of: output.standardErrorText), !reason.contains("://") else {
            return .failed(nil)
        }
        return .failed(reason)
    }

    /// Runs the login until it finishes, times out or the calling task is cancelled.
    nonisolated static func signIn(
        _ plan: AnswerSource,
        executablePath: String?,
        processRunner: PlanCLIProcessRunning = PlanCLIProcessRunner()
    ) async -> PlanSignInOutcome {
        guard let executablePath else { return .notInstalled }
        guard let arguments = signInArguments(for: plan) else { return .failed(nil) }
        if Task.isCancelled { return .cancelled }
        let output: PlanCLIProcessOutput
        do {
            output = try await processRunner.run(
                executablePath: executablePath,
                arguments: arguments,
                standardInput: nil,
                workingDirectory: FileManager.default.temporaryDirectory,
                environment: processEnvironment(forExecutableAt: executablePath),
                timeoutSeconds: signInTimeoutSeconds,
                onStandardOutputChunk: nil
            )
        } catch is CancellationError {
            return .cancelled
        } catch {
            return .failed("couldn’t start \(plan.shortName).")
        }
        if Task.isCancelled { return .cancelled }
        let statusAfter = plan == .claudeCodePlan
            ? await claudeCodeStatus(executablePath: executablePath, processRunner: processRunner)
            : await codexStatus(executablePath: executablePath, processRunner: processRunner)
        return signInOutcome(output: output, statusAfter: statusAfter)
    }
}

/// The logins under way. It outlives the Settings row that started one: leaving the page must not
/// lose the Cancel button, or let a second login start while the first still holds its port.
@MainActor
final class PlanSignIn: ObservableObject {
    static let shared = PlanSignIn()

    @Published private var tasks: [AnswerSource: Task<Void, Never>] = [:]
    @Published private var failures: [AnswerSource: String] = [:]
    /// Goes up each time a login ends, so a row knows to check its status again.
    @Published private var finishedCounts: [AnswerSource: Int] = [:]

    func isRunning(_ plan: AnswerSource) -> Bool { tasks[plan] != nil }
    func failureSentence(_ plan: AnswerSource) -> String? { failures[plan] }
    func finishedCount(_ plan: AnswerSource) -> Int { finishedCounts[plan, default: 0] }

    func start(_ plan: AnswerSource) {
        guard tasks[plan] == nil else { return }
        failures[plan] = nil
        AppLog.append("plans: \(plan.rawValue) sign-in started")
        tasks[plan] = Task {
            let path = plan == .claudeCodePlan ? await PlanCLIs.claudeCodePath() : await PlanCLIs.codexPath()
            let outcome = await PlanCLIs.signIn(plan, executablePath: path)
            finish(plan, outcome)
        }
    }

    func cancel(_ plan: AnswerSource) { tasks[plan]?.cancel() }

    private func finish(_ plan: AnswerSource, _ outcome: PlanSignInOutcome) {
        AppLog.append("plans: \(plan.rawValue) sign-in ended: \(String(describing: outcome).prefix(20))")
        if outcome == .signedIn {
            // Pressing Sign In is asking to use the plan.
            OpenClickyConfiguration.update { settings in
                if plan == .claudeCodePlan { settings.useClaudeCodePlan = true } else { settings.useCodexPlan = true }
            }
            ShellSettingsRevision.shared.noteChanged()
        }
        failures[plan] = outcome.sentence(for: plan)
        tasks[plan] = nil
        finishedCounts[plan, default: 0] += 1
    }
}
