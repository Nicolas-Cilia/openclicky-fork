// Ports AgentHousekeeping.swift: what agent tasks leave behind. Each task's screenshot is a temp
// file, removed when the run ends; Codex keeps its own copy inside the task's session file, which
// goes when the task passes the limit picked in Settings → Privacy (`AgentSessionLimit`).

using OpenClicky.Core.Configuration;

namespace OpenClicky.Core.Agent;

public static class AgentSessionLimit
{
    public const int DefaultDays = 14;

    /// <summary>The choices Settings offers; 0 keeps every task.</summary>
    public static readonly IReadOnlyList<int> Choices = [7, 14, 30, 90, 0];

    /// <summary>A new limit was picked: the companion applies it at once.</summary>
    public static event Action? Changed;

    /// <summary>shell.json's `agentSessionDays`: unset or nonsense is the default.</summary>
    public static int Days(int? stored) => stored is >= 0 ? stored.Value : DefaultDays;

    public static string Label(int days) => days == 0 ? "Forever" : $"{days} days";

    public static void Set(int days)
    {
        OpenClickyConfiguration.Update(settings => settings.AgentSessionDays = days);
        Changed?.Invoke();
    }
}

public static class AgentHousekeeping
{
    private const string ScreenshotPrefix = "openclicky-";
    private const string ScreenshotExtension = ".jpg";

    public static readonly TimeSpan FirstCleanupDelay = TimeSpan.FromSeconds(60);
    public static readonly TimeSpan CleanupInterval = TimeSpan.FromHours(24);

    public static string NewScreenshotPath(string? folder = null) =>
        Path.Combine(folder ?? Path.GetTempPath(), $"{ScreenshotPrefix}{Guid.NewGuid()}{ScreenshotExtension}");

    /// <summary>Removes one screenshot; a file still held open is left for the next launch's sweep.</summary>
    public static void RemoveScreenshot(string? path)
    {
        if (path is null) return;
        try { File.Delete(path); }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException) { AppLog.Write($"agent: couldn't remove the screenshot ({error.Message})"); }
    }

    /// <summary>Screenshots a quit or crash left mid-task. An hour's grace for anything still in use.</summary>
    public static void RemoveLeftoverScreenshots(string? folder = null, DateTime? utcNow = null)
    {
        var now = utcNow ?? DateTime.UtcNow;
        string[] files;
        try { files = Directory.GetFiles(folder ?? Path.GetTempPath(), $"{ScreenshotPrefix}*{ScreenshotExtension}"); }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException) { return; }
        foreach (var file in files)
        {
            try
            {
                if (now - File.GetLastWriteTimeUtc(file) > TimeSpan.FromHours(1)) File.Delete(file);
            }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException) { /* the next launch tries again */ }
        }
    }
}
