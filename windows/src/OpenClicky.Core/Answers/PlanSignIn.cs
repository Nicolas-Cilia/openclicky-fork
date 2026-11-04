// Ports PlanSignIn.swift: signs a plan in from Settings by running the CLI's own login and nothing
// else. The CLI opens the browser, waits for the callback and keeps the credentials where it always
// does; OpenClicky never sees or stores them, and its output is never logged, because the sign-in
// links in it carry one-time values.
//
//   claude auth login --claudeai    the Claude plan, never Console API billing
//   codex login                     the ChatGPT plan
//
// Checked with no terminal attached and stdin closed on macOS (claude 2.1.318, codex-cli 0.166.0),
// not yet on Windows. Whether it worked is decided by the CLI's own status check, not the login's
// exit status.

using OpenClicky.Core.Configuration;
using OpenClicky.Core.Providers;

namespace OpenClicky.Core.Answers;

public enum PlanSignInResult
{
    SignedIn,
    Cancelled,
    NotInstalled,
    TimedOut,
    Failed,
}

/// <summary>How a login ended; Reason is the CLI's own words on a failure, when they can be shown.</summary>
public sealed record PlanSignInOutcome(PlanSignInResult Result, string? Reason = null)
{
    /// <summary>What the plan's row says afterwards; null when its usual sentence already says it.</summary>
    public string? Sentence(AnswerSource plan)
    {
        var command = PlanSignIn.Command(plan);
        return Result switch
        {
            PlanSignInResult.SignedIn or PlanSignInResult.Cancelled => null,
            PlanSignInResult.NotInstalled => $"{plan.ShortName()} isn’t installed on this PC.",
            PlanSignInResult.TimedOut => $"Sign-in timed out after {(int)(PlanSignIn.TimeoutSeconds / 60)} minutes. Try again, or run “{command}” in a terminal.",
            _ => Reason is not null ? $"Couldn’t sign in: {Reason}" : $"Sign-in didn’t finish. Try again, or run “{command}” in a terminal.",
        };
    }
}

public static class PlanSignIn
{
    /// <summary>Long enough to find a password or pass a two-factor check.</summary>
    public const double TimeoutSeconds = 300;

    public static IReadOnlyList<string>? Arguments(AnswerSource plan) => plan switch
    {
        AnswerSource.ClaudeCodePlan => ["auth", "login", "--claudeai"],
        AnswerSource.CodexPlan => ["login"],
        _ => null,
    };

    /// <summary>The same login, as someone would type it in a terminal.</summary>
    public static string Command(AnswerSource plan) =>
        plan == AnswerSource.ClaudeCodePlan ? "claude auth login" : "codex login";

    /// <summary>
    /// Signed in is whatever the status check says now, so a login that exits oddly after it worked
    /// still counts. A reason holding a link is dropped: those carry one-time values.
    /// </summary>
    public static PlanSignInOutcome Outcome(PlanCliProcessOutput output, PlanCliStatus statusAfter)
    {
        if (statusAfter == PlanCliStatus.Ready) return new(PlanSignInResult.SignedIn);
        if (output.TimedOut) return new(PlanSignInResult.TimedOut);
        if (output.ExitStatus == 0) return new(PlanSignInResult.Failed);
        var reason = PlanCLIs.LastNonEmptyLine(output.StandardErrorText);
        return reason is null || reason.Contains("://", StringComparison.Ordinal)
            ? new(PlanSignInResult.Failed)
            : new(PlanSignInResult.Failed, reason);
    }

    /// <summary>Runs the login until it finishes, times out or is cancelled.</summary>
    public static async Task<PlanSignInOutcome> RunAsync(AnswerSource plan, string? executablePath,
                                                         IPlanCliProcessRunner? processRunner = null,
                                                         CancellationToken cancellationToken = default)
    {
        if (executablePath is null) return new(PlanSignInResult.NotInstalled);
        if (Arguments(plan) is not { } arguments) return new(PlanSignInResult.Failed);
        processRunner ??= new PlanCliProcessRunner();
        try
        {
            var output = await processRunner.RunAsync(executablePath, arguments, null, Path.GetTempPath(),
                                                      PlanCLIs.ProcessEnvironment(executablePath), TimeoutSeconds, null, cancellationToken).ConfigureAwait(false);
            var statusAfter = plan == AnswerSource.ClaudeCodePlan
                ? await PlanCLIs.ClaudeCodeStatusAsync(executablePath, processRunner, cancellationToken).ConfigureAwait(false)
                : await PlanCLIs.CodexStatusAsync(executablePath, processRunner, cancellationToken).ConfigureAwait(false);
            return Outcome(output, statusAfter);
        }
        catch (OperationCanceledException)
        {
            return new(PlanSignInResult.Cancelled);
        }
        catch (Exception error)
        {
            AppLog.Write($"plans: {plan} sign-in couldn't start: {error.GetType().Name}");
            return new(PlanSignInResult.Failed, $"couldn’t start {plan.ShortName()}.");
        }
    }
}

/// <summary>
/// The logins under way. It outlives the Settings row that started one: leaving the page must not
/// lose the Cancel button, or let a second login start while the first still holds its port.
/// </summary>
public sealed class PlanSignInCoordinator
{
    public static PlanSignInCoordinator Shared { get; } = new();

    private readonly object stateLock = new();
    private readonly Dictionary<AnswerSource, CancellationTokenSource> running = [];
    private readonly Dictionary<AnswerSource, string> failures = [];

    /// <summary>Raised on a background thread when a login starts or ends.</summary>
    public event Action? Changed;

    public bool IsRunning(AnswerSource plan)
    {
        lock (stateLock) return running.ContainsKey(plan);
    }

    public string? FailureSentence(AnswerSource plan)
    {
        lock (stateLock) return failures.GetValueOrDefault(plan);
    }

    public void Start(AnswerSource plan)
    {
        var cancellation = new CancellationTokenSource();
        lock (stateLock)
        {
            if (!running.TryAdd(plan, cancellation))
            {
                cancellation.Dispose();
                return;
            }
            failures.Remove(plan);
        }
        AppLog.Write($"plans: {plan} sign-in started");
        Changed?.Invoke();
        _ = Task.Run(() => RunAsync(plan, cancellation));
    }

    public void Cancel(AnswerSource plan)
    {
        lock (stateLock)
        {
            if (running.TryGetValue(plan, out var cancellation)) cancellation.Cancel();
        }
    }

    private async Task RunAsync(AnswerSource plan, CancellationTokenSource cancellation)
    {
        PlanSignInOutcome outcome;
        try
        {
            var path = plan == AnswerSource.ClaudeCodePlan
                ? await PlanCLIs.ClaudeCodePathAsync(cancellationToken: cancellation.Token).ConfigureAwait(false)
                : await PlanCLIs.CodexPathAsync().ConfigureAwait(false);
            outcome = await PlanSignIn.RunAsync(plan, path, cancellationToken: cancellation.Token).ConfigureAwait(false);
        }
        catch (OperationCanceledException)
        {
            outcome = new(PlanSignInResult.Cancelled);
        }
        AppLog.Write($"plans: {plan} sign-in ended: {outcome.Result}");
        if (outcome.Result == PlanSignInResult.SignedIn)
        {
            // Pressing Sign In is asking to use the plan.
            OpenClickyConfiguration.Update(shell =>
            {
                if (plan == AnswerSource.ClaudeCodePlan) shell.UseClaudeCodePlan = true;
                else shell.UseCodexPlan = true;
            });
        }
        lock (stateLock)
        {
            running.Remove(plan);
            if (outcome.Sentence(plan) is { } sentence) failures[plan] = sentence;
        }
        cancellation.Dispose();
        Changed?.Invoke();
    }
}
