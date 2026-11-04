// Ports PlanSignInTests.swift: which login runs, and what its result means. A fake runner stands in
// for every process, so no browser opens and no real sign-in is touched.

using System.Text;
using OpenClicky.Core.Answers;
using OpenClicky.Core.Providers;
using OpenClicky.Core.Settings;

namespace OpenClicky.Core.Tests.Answers;

public class PlanSignInTests
{
    private sealed class FakeRunner(PlanCliProcessOutput login, PlanCliProcessOutput status) : IPlanCliProcessRunner
    {
        public List<IReadOnlyList<string>> Calls { get; } = [];
        public List<double> Timeouts { get; } = [];

        public Task<PlanCliProcessOutput> RunAsync(string executablePath, IReadOnlyList<string> arguments, byte[]? standardInput,
                                                   string workingDirectory, IReadOnlyDictionary<string, string> environment,
                                                   double timeoutSeconds, Action<byte[]>? onStandardOutputChunk,
                                                   CancellationToken cancellationToken = default)
        {
            cancellationToken.ThrowIfCancellationRequested();
            Calls.Add(arguments);
            Timeouts.Add(timeoutSeconds);
            return Task.FromResult(arguments.Contains("status") ? status : login);
        }
    }

    private static PlanCliProcessOutput Output(int exit = 0, string stdout = "", string stderr = "", bool timedOut = false) =>
        new(exit, Encoding.UTF8.GetBytes(stdout), Encoding.UTF8.GetBytes(stderr), timedOut);

    private static readonly PlanCliProcessOutput ClaudeSignedIn = Output(stdout: """{"loggedIn": true}""");
    private static readonly PlanCliProcessOutput ClaudeSignedOut = Output(exit: 1, stdout: """{"loggedIn": false}""");
    private static readonly PlanCliProcessOutput CodexSignedIn = Output(stderr: "Logged in using ChatGPT");
    private static readonly PlanCliProcessOutput CodexSignedOut = Output(exit: 1, stderr: "Not logged in");

    [Fact]
    public async Task ClaudeSignsInToTheSubscriptionNotConsoleBilling()
    {
        var runner = new FakeRunner(Output(), ClaudeSignedIn);
        var outcome = await PlanSignIn.RunAsync(AnswerSource.ClaudeCodePlan, "claude.exe", runner);
        Assert.Equal(PlanSignInResult.SignedIn, outcome.Result);
        Assert.Equal(new[] { "auth", "login", "--claudeai" }, runner.Calls[0]);
        Assert.Equal(new[] { "auth", "status", "--json" }, runner.Calls[1]);
        Assert.Equal(PlanSignIn.TimeoutSeconds, runner.Timeouts[0]);
    }

    [Fact]
    public async Task CodexRunsItsOwnLoginThenChecks()
    {
        var runner = new FakeRunner(Output(), CodexSignedIn);
        var outcome = await PlanSignIn.RunAsync(AnswerSource.CodexPlan, "codex.exe", runner);
        Assert.Equal(PlanSignInResult.SignedIn, outcome.Result);
        Assert.Equal(new[] { "login" }, runner.Calls[0]);
        Assert.Equal(new[] { "login", "status" }, runner.Calls[1]);
    }

    [Fact]
    public void OnlyTheTwoPlansHaveALogin()
    {
        foreach (var source in Enum.GetValues<AnswerSource>())
        {
            if (source is AnswerSource.ClaudeCodePlan or AnswerSource.CodexPlan) continue;
            Assert.Null(PlanSignIn.Arguments(source));
        }
    }

    [Fact]
    public async Task NoCliMeansNothingRuns()
    {
        var runner = new FakeRunner(Output(), CodexSignedIn);
        var outcome = await PlanSignIn.RunAsync(AnswerSource.CodexPlan, null, runner);
        Assert.Equal(PlanSignInResult.NotInstalled, outcome.Result);
        Assert.Empty(runner.Calls);
    }

    [Fact]
    public async Task ACleanExitThatDidNotSignInIsNotSuccess()
    {
        var runner = new FakeRunner(Output(), CodexSignedOut);
        var outcome = await PlanSignIn.RunAsync(AnswerSource.CodexPlan, "codex.exe", runner);
        Assert.Equal(new PlanSignInOutcome(PlanSignInResult.Failed), outcome);
    }

    [Fact]
    public void TheStatusCheckOutranksTheLoginsExitStatus() =>
        Assert.Equal(PlanSignInResult.SignedIn, PlanSignIn.Outcome(Output(exit: 1, stderr: "odd"), Core.Answers.PlanCliStatus.Ready).Result);

    [Fact]
    public async Task ATimeoutSaysSo()
    {
        var runner = new FakeRunner(Output(exit: 1, timedOut: true), ClaudeSignedOut);
        var outcome = await PlanSignIn.RunAsync(AnswerSource.ClaudeCodePlan, "claude.exe", runner);
        Assert.Equal(PlanSignInResult.TimedOut, outcome.Result);
        Assert.Contains("claude auth login", outcome.Sentence(AnswerSource.ClaudeCodePlan), StringComparison.Ordinal);
    }

    [Fact]
    public void TheCliReasonIsShown()
    {
        var outcome = PlanSignIn.Outcome(Output(exit: 1, stderr: "first\nPort 1455 is already in use\n"), Core.Answers.PlanCliStatus.InstalledSignedOut);
        Assert.Equal("Port 1455 is already in use", outcome.Reason);
    }

    [Fact]
    public void ASignInLinkIsNeverShownAsTheReason()
    {
        var outcome = PlanSignIn.Outcome(Output(exit: 1, stderr: "https://auth.example/authorize?state=secret\n"), Core.Answers.PlanCliStatus.InstalledSignedOut);
        Assert.Equal(PlanSignInResult.Failed, outcome.Result);
        Assert.Null(outcome.Reason);
    }

    [Fact]
    public async Task CancellingLeavesNothingToSay()
    {
        using var cancellation = new CancellationTokenSource();
        await cancellation.CancelAsync();
        var runner = new FakeRunner(Output(), CodexSignedOut);
        var outcome = await PlanSignIn.RunAsync(AnswerSource.CodexPlan, "codex.exe", runner, cancellation.Token);
        Assert.Equal(PlanSignInResult.Cancelled, outcome.Result);
        Assert.Null(outcome.Sentence(AnswerSource.CodexPlan));
    }

    [Fact]
    public void OnlyGeminiLinksToAKeyPage()
    {
        Assert.Equal("https://aistudio.google.com/apikey", ProviderKey.Gemini.KeyPageUrl());
        Assert.Equal(new[] { ProviderKey.Gemini }, ProviderKeys.AllCases.Where(provider => provider.KeyPageUrl() is not null));
    }
}
