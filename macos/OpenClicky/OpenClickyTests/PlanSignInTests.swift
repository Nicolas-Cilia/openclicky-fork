//
//  PlanSignInTests.swift
//  OpenClickyTests
//
//  Signing a plan in from Settings: which login runs, and what its result means. A fake runner
//  stands in for every process, so no browser opens and no real sign-in is touched.
//

import Foundation
import Testing
@testable import OpenClicky

private final class FakeSignInRunner: PlanCLIProcessRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [[String]] = []
    private var timeouts: [TimeInterval] = []
    private let login: PlanCLIProcessOutput
    private let status: PlanCLIProcessOutput

    init(login: PlanCLIProcessOutput, status: PlanCLIProcessOutput) {
        self.login = login
        self.status = status
    }

    var recordedArguments: [[String]] { lock.withLock { calls } }
    var recordedTimeouts: [TimeInterval] { lock.withLock { timeouts } }

    func run(executablePath: String, arguments: [String], standardInput: Data?, workingDirectory: URL,
             environment: [String: String], timeoutSeconds: TimeInterval,
             onStandardOutputChunk: (@Sendable (Data) -> Void)?) async throws -> PlanCLIProcessOutput {
        lock.withLock {
            calls.append(arguments)
            timeouts.append(timeoutSeconds)
        }
        return arguments.contains("status") ? status : login
    }
}

private func output(exit: Int32 = 0, stdout: String = "", stderr: String = "", timedOut: Bool = false) -> PlanCLIProcessOutput {
    PlanCLIProcessOutput(exitStatus: exit, standardOutput: Data(stdout.utf8), standardError: Data(stderr.utf8), timedOut: timedOut)
}

private let claudeSignedIn = output(stdout: #"{"loggedIn": true}"#)
private let claudeSignedOut = output(exit: 1, stdout: #"{"loggedIn": false}"#)
private let codexSignedIn = output(stderr: "Logged in using ChatGPT")
private let codexSignedOut = output(exit: 1, stderr: "Not logged in")

@Suite struct PlanSignInTests {
    @Test func claudeSignsInToTheSubscriptionNotConsoleBilling() async {
        let runner = FakeSignInRunner(login: output(), status: claudeSignedIn)
        let outcome = await PlanCLIs.signIn(.claudeCodePlan, executablePath: "/x/claude", processRunner: runner)
        #expect(outcome == .signedIn)
        #expect(runner.recordedArguments == [["auth", "login", "--claudeai"], ["auth", "status", "--json"]])
        #expect(runner.recordedTimeouts.first == PlanCLIs.signInTimeoutSeconds)
    }

    @Test func codexRunsItsOwnLoginThenChecks() async {
        let runner = FakeSignInRunner(login: output(), status: codexSignedIn)
        let outcome = await PlanCLIs.signIn(.codexPlan, executablePath: "/x/codex", processRunner: runner)
        #expect(outcome == .signedIn)
        #expect(runner.recordedArguments == [["login"], ["login", "status"]])
    }

    @Test func onlyTheTwoPlansHaveALogin() {
        for source in AnswerSource.allCases where source != .claudeCodePlan && source != .codexPlan {
            #expect(PlanCLIs.signInArguments(for: source) == nil)
        }
    }

    @Test func noCLIMeansNothingRuns() async {
        let runner = FakeSignInRunner(login: output(), status: codexSignedIn)
        let outcome = await PlanCLIs.signIn(.codexPlan, executablePath: nil, processRunner: runner)
        #expect(outcome == .notInstalled)
        #expect(runner.recordedArguments.isEmpty)
    }

    @Test func aCleanExitThatDidNotSignInIsNotSuccess() async {
        let runner = FakeSignInRunner(login: output(), status: codexSignedOut)
        let outcome = await PlanCLIs.signIn(.codexPlan, executablePath: "/x/codex", processRunner: runner)
        #expect(outcome == .failed(nil))
    }

    @Test func theStatusCheckOutranksTheLoginsExitStatus() {
        #expect(PlanCLIs.signInOutcome(output: output(exit: 1, stderr: "odd"), statusAfter: .ready) == .signedIn)
    }

    @Test func aTimeoutSaysSo() async {
        let runner = FakeSignInRunner(login: output(exit: 15, timedOut: true), status: claudeSignedOut)
        let outcome = await PlanCLIs.signIn(.claudeCodePlan, executablePath: "/x/claude", processRunner: runner)
        #expect(outcome == .timedOut)
        #expect(outcome.sentence(for: .claudeCodePlan)?.contains("claude auth login") == true)
    }

    @Test func theCLIsReasonIsShown() {
        let outcome = PlanCLIs.signInOutcome(output: output(exit: 1, stderr: "first\nPort 1455 is already in use\n"), statusAfter: .installedSignedOut)
        #expect(outcome == .failed("Port 1455 is already in use"))
    }

    @Test func aSignInLinkIsNeverShownAsTheReason() {
        let outcome = PlanCLIs.signInOutcome(output: output(exit: 1, stderr: "https://auth.example/authorize?state=secret\n"), statusAfter: .installedSignedOut)
        #expect(outcome == .failed(nil))
    }

    @Test func cancellingLeavesNothingToSay() async {
        let runner = FakeSignInRunner(login: output(), status: codexSignedOut)
        let task = Task { () -> PlanSignInOutcome in
            withUnsafeCurrentTask { $0?.cancel() }
            return await PlanCLIs.signIn(.codexPlan, executablePath: "/x/codex", processRunner: runner)
        }
        let outcome = await task.value
        #expect(outcome == .cancelled)
        #expect(outcome.sentence(for: .codexPlan) == nil)
        #expect(runner.recordedArguments.isEmpty)
    }

    @Test func onlyGeminiLinksToAKeyPage() {
        #expect(KeyProvider.gemini.keyPageURL == "https://aistudio.google.com/apikey")
        #expect(KeyProvider.allCases.filter { $0.keyPageURL != nil } == [.gemini])
    }
}
