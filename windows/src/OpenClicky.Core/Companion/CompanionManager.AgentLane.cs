//
//  CompanionManager.AgentLane.cs
//  OpenClicky (Windows port of CompanionManager.swift: the OpenClicky agent lane)
//
//  Hands real work to a Codex thread through the `openclicky` CLI, attaching the cursor screen,
//  speaks the agent's final message, and fills the result card.
//

using OpenClicky.Core.Agent;
using OpenClicky.Core.Configuration;
using OpenClicky.Core.Platform;
using OpenClicky.Core.Providers;

namespace OpenClicky.Core.Companion;

public sealed partial class CompanionManager
{
    /// <summary>The Codex thread reused across agent requests this session, so follow-ups resume it.</summary>
    private string? lastAgentThreadId;
    private CancellationTokenSource? agentSessionCleanup;

    /// <summary>Deletes agent tasks past the limit in Settings → Privacy, soon after launch and then daily, and whenever the limit changes.</summary>
    private void StartAgentSessionCleanup()
    {
        AgentHousekeeping.RemoveLeftoverScreenshots();
        AgentSessionLimit.Changed += OnAgentSessionLimitChanged;
        var cancellation = agentSessionCleanup = new CancellationTokenSource();
        _ = Task.Run(async () =>
        {
            try
            {
                await Task.Delay(AgentHousekeeping.FirstCleanupDelay, cancellation.Token).ConfigureAwait(false);
                while (!cancellation.IsCancellationRequested)
                {
                    await DeleteExpiredAgentSessionsAsync(cancellation.Token).ConfigureAwait(false);
                    await Task.Delay(AgentHousekeeping.CleanupInterval, cancellation.Token).ConfigureAwait(false);
                }
            }
            catch (OperationCanceledException) { /* the app is closing */ }
        });
    }

    private void StopAgentSessionCleanup()
    {
        AgentSessionLimit.Changed -= OnAgentSessionLimitChanged;
        agentSessionCleanup?.Cancel();
        agentSessionCleanup = null;
    }

    private void OnAgentSessionLimitChanged() => _ = DeleteExpiredAgentSessionsAsync(CancellationToken.None);

    private async Task DeleteExpiredAgentSessionsAsync(CancellationToken cancellationToken)
    {
        var days = AgentSessionLimit.Days(OpenClickyConfiguration.Settings.AgentSessionDays);
        if (days <= 0) return;
        try
        {
            var deleted = await openClickyAgentClient.PruneThreadsAsync(days, cancellationToken).ConfigureAwait(false);
            if (deleted.Count > 0) AppLog.Write($"agent: deleted {deleted.Count} task(s) older than {days} days");
            // A follow-up can't resume a task that is gone: it starts a new one.
            services.MainThread.Post(() => { if (lastAgentThreadId is { } last && deleted.Contains(last)) lastAgentThreadId = null; });
        }
        catch (OperationCanceledException) { throw; }
        catch (Exception error) { AppLog.Write($"agent: couldn't delete old tasks ({error.Message})"); }
    }

    /// <summary>
    /// Text entry point into the agent lane (the result card's follow-ups, the connect card). Captures
    /// the screen like the voice path does, resumes <paramref name="threadId"/> when given, speaks the result.
    /// </summary>
    public void SubmitTextToAgent(string text, string? threadId = null, bool startsNewThread = false)
    {
        var trimmedText = text.Trim();
        if (trimmedText.Length == 0 || !OpenClickyConfiguration.IsConfigured) return;
        // Nothing can run the agent: say what would, rather than failing later.
        if (!ProviderCapabilities.Current().UsesAgent)
        {
            SpeakWithSystemVoice(ProviderCapabilities.Current().AgentPausedSentence ?? AgentNeedsSetupSentence);
            return;
        }
        InterruptCurrentAnswer(includingAgentWork: true);
        if (threadId is not null) lastAgentThreadId = threadId;
        else if (startsNewThread) lastAgentThreadId = null;
        LastTranscript = trimmedText;
        var cancellation = new CancellationTokenSource();
        currentResponseCancellation = cancellation;
        _ = RunTextAgentTurnAsync(trimmedText, cancellation);
    }

    private async Task RunTextAgentTurnAsync(string text, CancellationTokenSource cancellation)
    {
        var cancellationToken = cancellation.Token;
        VoiceState = CompanionVoiceState.Processing;
        var screenCaptures = await CaptureScreensQuietlyAsync(cancellationToken);
        try
        {
            await RunOpenClickyAgentLaneAsync(text, screenCaptures, cancellationToken);
        }
        catch (Exception error) when (error is OperationCanceledException || cancellationToken.IsCancellationRequested)
        {
        }
        catch (Exception error)
        {
            AppLog.Write($"agent: follow-up failed ({error.GetType().Name})");
            AgentActivityText = null;
            SpeakAgentErrorFallback();
        }
        await WaitForSystemVoiceNoticeToEndAsync();
        if (!cancellationToken.IsCancellationRequested)
        {
            VoiceState = CompanionVoiceState.Idle;
            Overlay.ScheduleTransientHideIfNeeded();
        }
        if (currentResponseCancellation == cancellation) currentResponseCancellation = null;
    }

    private async Task<IReadOnlyList<CompanionScreenCapture>> CaptureScreensQuietlyAsync(CancellationToken cancellationToken)
    {
        try { return await services.ScreenCapture.CaptureAllScreensAsync(cancellationToken: cancellationToken); }
        catch (Exception error)
        {
            AppLog.Write($"agent: no screenshot ({error.GetType().Name})");
            return [];
        }
    }

    /// <summary>The agent lane in the voice path: run the thread, then speak what it said.</summary>
    private async Task RunOpenClickyAgentLaneAsync(string transcript, IReadOnlyList<CompanionScreenCapture> screenCaptures, CancellationToken cancellationToken)
    {
        var spokenText = await PerformAgentTaskAsync(transcript, screenCaptures, cancellationToken);
        if (cancellationToken.IsCancellationRequested) return;
        await SpeakWholeReplyAsync(spokenText, cancellationToken);
    }

    /// <summary>
    /// The agent lane core, shared by the voice path and the Realtime `send_to_agent` tool: attach the
    /// cursor screen, run the Codex thread (resumed across turns), publish milestones and the result
    /// card, and return the sentence to speak.
    /// </summary>
    private async Task<string> PerformAgentTaskAsync(string transcript, IReadOnlyList<CompanionScreenCapture> screenCaptures, CancellationToken cancellationToken = default)
    {
        string? screenshotPath = null;
        if ((screenCaptures.FirstOrDefault(capture => capture.IsCursorScreen) ?? screenCaptures.FirstOrDefault()) is { } cursorScreenCapture)
        {
            var path = AgentHousekeeping.NewScreenshotPath();
            try
            {
                await File.WriteAllBytesAsync(path, cursorScreenCapture.ImageData, CancellationToken.None);
                screenshotPath = path;
            }
            catch (IOException error)
            {
                AppLog.Write($"agent: couldn't save the screenshot ({error.Message})");
            }
        }

        AgentActivityText = "starting agent…";
        AppLog.Write($"agent: task ({transcript.Length} chars)");
        var startedAt = DateTimeOffset.UtcNow;
        OpenClickyAgentRunResult result;
        try
        {
            result = await openClickyAgentClient.RunAgentAsync(
                transcript, screenshotPath, lastAgentThreadId,
                onEvent: milestone => services.MainThread.Post(() => AgentActivityText = milestone),
                cancellationToken);
        }
        finally
        {
            // Codex has read it by the time the run ends, whichever way the run ends.
            AgentHousekeeping.RemoveScreenshot(screenshotPath);
        }
        AppLog.Write($"agent task finished in {(DateTimeOffset.UtcNow - startedAt).TotalSeconds:0.0} s ({result.Status})");

        if (result.ThreadId is { } threadId) lastAgentThreadId = threadId;
        LastAgentArtifacts = result.Artifacts;
        AgentActivityText = null;
        var summary = new OpenClickyAgentResultSummary(
            result.ThreadId ?? lastAgentThreadId ?? "",
            transcript.Length > 60 ? transcript[..60] : transcript,
            result.Text.Trim(),
            result.Artifacts,
            result.Status,
            DateTimeOffset.Now);
        LastAgentResult = summary;
        ShowAgentResult(summary);

        var spokenText = result.Text.Trim();
        if (spokenText.Length == 0)
        {
            spokenText = result.Status == "completed" ? "done." : $"the agent stopped early: {result.ErrorMessage ?? result.Status}";
        }
        if (result.Artifacts.Count > 0)
        {
            var fileCount = result.Artifacts.Count;
            spokenText += $" i saved {fileCount} {(fileCount == 1 ? "file" : "files")}.";
        }
        // Keep the ask lane aware of what the agent did.
        RememberExchange(transcript, spokenText);
        return spokenText;
    }

    /// <summary>The result card (top-right) with the finished turn.</summary>
    private void ShowAgentResult(OpenClickyAgentResultSummary summary)
    {
        AgentCard.ThreadId = summary.ThreadId;
        AgentCard.Title = summary.Title;
        AgentCard.Summary = summary.Text;
        AgentCard.LiveResultText = summary.Text;
        AgentCard.Status = summary.Status;
        AgentCard.IsLoading = false;
        AgentCard.IsVisible = true;
    }

    /// <summary>Opens the result card for a thread and reads it through the CLI (the Mac's Agents tab → Open Agent).</summary>
    public void OpenAgentResultCard(string threadId)
    {
        AgentCard.BeginLoading(threadId);
        if (LastAgentResult is { } last && last.ThreadId == threadId && DateTimeOffset.Now - last.FinishedAt < TimeSpan.FromHours(1))
        {
            AgentCard.LiveResultText = last.Text;
        }
        _ = LoadAgentThreadAsync(threadId);
    }

    private async Task LoadAgentThreadAsync(string threadId)
    {
        try
        {
            var detail = await openClickyAgentClient.ReadThreadAsync(threadId);
            if (AgentCard.ThreadId != threadId) return;
            AgentCard.Title = detail.Thread.Preview.Length > 60 ? detail.Thread.Preview[..60] : detail.Thread.Preview;
            AgentCard.Summary = detail.LastAgentMessage ?? "";
            AgentCard.Status = detail.Thread.Status;
        }
        catch (Exception error)
        {
            AppLog.Write($"agent: couldn't read the thread ({error.GetType().Name})");
            if (AgentCard.ThreadId == threadId) AgentCard.Status = "error";
        }
        finally
        {
            if (AgentCard.ThreadId == threadId) AgentCard.IsLoading = false;
        }
    }
}
