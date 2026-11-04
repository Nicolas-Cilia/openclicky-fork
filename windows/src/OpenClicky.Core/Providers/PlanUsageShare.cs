// Ports PlanUsageShare.swift: roughly how much of a plan's limit bar is OpenClicky. Neither plan
// says, so this is an estimate:
//   - Claude: OpenClicky's tokens against the tokens Claude Code logged on this computer
//     (%USERPROFILE%\.claude\projects; only the counts are read), as a share of the bar. Use on
//     other computers or on the Claude website isn't in those logs, so the share can come out high.
//     It never exceeds how far the bar has risen since OpenClicky first used this window, so what
//     was already on the bar is never counted as OpenClicky's.
//   - Codex: how far the bar moved across each OpenClicky request, added up until the window
//     resets. Anything else using Codex at that moment is counted too.

using System.Globalization;
using System.Text.Json;
using System.Text.Json.Nodes;
using OpenClicky.Core.Configuration;

namespace OpenClicky.Core.Providers;

/// <summary>How far a Codex limit has moved across OpenClicky's requests, in the window ending at <see cref="ResetsAt"/>.</summary>
public sealed record MeasuredPlanWindow(string Title, DateTimeOffset? ResetsAt, double UsedFraction);

/// <summary>One request Claude Code logged on this computer.</summary>
public sealed record LocalClaudeUsage(DateTimeOffset Date, double Weight);

public static class PlanUsageShare
{
    /// <summary>Reset times this close together are the same window: a plan may nudge the time it reports.</summary>
    private static readonly TimeSpan SameWindowTolerance = TimeSpan.FromMinutes(10);

    /// <summary>What a request weighs against a plan's limit, roughly: a cached token costs far less than a new one, and an output token far more.</summary>
    public static double Weight(int newInputTokens, int cachedInputTokens, int outputTokens) =>
        newInputTokens + cachedInputTokens * 0.1 + outputTokens * 5.0;

    public static double Weight(PlanUsageSample sample) =>
        Weight(Math.Max(0, sample.InputTokens - sample.CachedInputTokens), sample.CachedInputTokens, sample.OutputTokens);

    /// <summary>The length of a window from its title ("5 hours", "7 days", "30 min"); null for any other title.</summary>
    public static TimeSpan? Duration(string windowTitle)
    {
        var parts = windowTitle.Split(' ');
        if (parts.Length != 2 || !double.TryParse(parts[0], NumberStyles.Number, CultureInfo.InvariantCulture, out var count)) return null;
        return parts[1] switch
        {
            "min" => TimeSpan.FromMinutes(count),
            "hour" or "hours" => TimeSpan.FromHours(count),
            "day" or "days" => TimeSpan.FromDays(count),
            _ => null,
        };
    }

    public static DateTimeOffset? Start(PlanLimitWindow window) =>
        window.ResetsAt is { } resetsAt && Duration(window.Title) is { } duration ? resetsAt - duration : null;

    public static bool IsSameWindow(DateTimeOffset? first, DateTimeOffset? second)
    {
        if (first is not { } a || second is not { } b) return first is null && second is null;
        return (a - b).Duration() <= SameWindowTolerance;
    }

    /// <summary>OpenClicky's part of a Claude bar; null when it isn't known or OpenClicky used none of this window. <paramref name="baselines"/> is how full each bar was when OpenClicky first used its window.</summary>
    public static double? ClaudeFraction(PlanLimitWindow window, IEnumerable<PlanUsageSample> samples, IEnumerable<LocalClaudeUsage> localUsage, IReadOnlyList<MeasuredPlanWindow> baselines)
    {
        if (Start(window) is not { } start) return null;
        if (baselines.FirstOrDefault(entry => entry.Title == window.Title && IsSameWindow(entry.ResetsAt, window.ResetsAt)) is not { } baseline) return null;
        var ours = samples.Where(sample => sample.Source == AnswerSource.ClaudeCodePlan.Id() && sample.Date >= start).Sum(Weight);
        if (ours <= 0) return null;
        var others = localUsage.Where(usage => usage.Date >= start).Sum(usage => usage.Weight);
        return Math.Min(window.UsedFraction * ours / (ours + others), Math.Max(0, window.UsedFraction - baseline.UsedFraction));
    }

    /// <summary>Remembers how full each bar is the first time it is seen in its window. Claude only reports its limits on OpenClicky's own requests, so that is when OpenClicky first used the window.</summary>
    public static IReadOnlyList<MeasuredPlanWindow> UpdatingBaselines(IReadOnlyList<MeasuredPlanWindow> baselines, PlanLimitSnapshot snapshot) =>
        [.. snapshot.Windows.Select(window =>
            baselines.FirstOrDefault(entry => entry.Title == window.Title && IsSameWindow(entry.ResetsAt, window.ResetsAt))
            ?? new MeasuredPlanWindow(window.Title, window.ResetsAt, window.UsedFraction))];

    public static string ClaudeLogsFolder => Path.Combine(OpenClickyPaths.HomeDirectory, ".claude", "projects");

    /// <summary>Requests in Claude Code's logs since <paramref name="start"/>. Only the timestamp and counts are kept. A file untouched since then holds nothing newer, so it isn't opened.</summary>
    public static IReadOnlyList<LocalClaudeUsage> ReadLocalClaudeUsage(DateTimeOffset start, string? folder = null)
    {
        var root = folder ?? ClaudeLogsFolder;
        var requests = new Dictionary<string, LocalClaudeUsage>();
        if (!Directory.Exists(root)) return [];
        IEnumerable<string> files;
        try { files = Directory.EnumerateFiles(root, "*.jsonl", SearchOption.AllDirectories); }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException) { return []; }
        foreach (var file in files)
        {
            try
            {
                if (File.GetLastWriteTimeUtc(file) < start.UtcDateTime) continue;
                using var stream = new FileStream(file, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
                using var reader = new StreamReader(stream);
                while (reader.ReadLine() is { } line)
                {
                    if (!line.Contains("\"usage\"", StringComparison.Ordinal)) continue;
                    // A streamed reply is logged over several lines: the last one for a request counts.
                    if (ParseClaudeLogLine(line) is { } parsed && parsed.Usage.Date >= start) requests[parsed.Key] = parsed.Usage;
                }
            }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException) { /* the next read tries again */ }
        }
        return [.. requests.Values];
    }

    public static (string Key, LocalClaudeUsage Usage)? ParseClaudeLogLine(string line)
    {
        try
        {
            if (JsonNode.Parse(line) is not JsonObject json || json["type"]?.GetValue<string>() != "assistant") return null;
            if (json["message"] is not JsonObject message || message["usage"] is not JsonObject usage) return null;
            if (message["id"]?.GetValue<string>() is not { } id || json["timestamp"]?.GetValue<string>() is not { } timestamp) return null;
            if (!DateTimeOffset.TryParse(timestamp, CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal, out var date)) return null;
            int Count(string key) => usage[key] is JsonValue value && value.TryGetValue<int>(out var count) ? count : 0;
            var weight = Weight(Count("input_tokens") + Count("cache_creation_input_tokens"), Count("cache_read_input_tokens"), Count("output_tokens"));
            return ($"{id}|{json["requestId"]?.GetValue<string>()}", new LocalClaudeUsage(date, weight));
        }
        catch (Exception error) when (error is JsonException or InvalidOperationException or FormatException)
        {
            return null;
        }
    }

    /// <summary><paramref name="measured"/> with one request's movement added: each window keeps its running total, and a window that has reset starts again from nothing.</summary>
    public static IReadOnlyList<MeasuredPlanWindow> Adding(PlanLimitSnapshot before, PlanLimitSnapshot after, IReadOnlyList<MeasuredPlanWindow> measured) =>
        [.. after.Windows.Select(window =>
        {
            var running = measured.FirstOrDefault(entry => entry.Title == window.Title && IsSameWindow(entry.ResetsAt, window.ResetsAt))?.UsedFraction ?? 0;
            var start = before.Windows.FirstOrDefault(entry => entry.Title == window.Title && IsSameWindow(entry.ResetsAt, window.ResetsAt));
            var moved = start is null ? 0 : Math.Max(0, window.UsedFraction - start.UsedFraction);
            return new MeasuredPlanWindow(window.Title, window.ResetsAt, running + moved);
        })];

    /// <summary>OpenClicky's part of a Codex bar; null until a request has been measured in this window.</summary>
    public static double? CodexFraction(PlanLimitWindow window, IReadOnlyList<MeasuredPlanWindow> measured) =>
        measured.FirstOrDefault(entry => entry.Title == window.Title && IsSameWindow(entry.ResetsAt, window.ResetsAt)) is { } entry
            ? Math.Min(entry.UsedFraction, window.UsedFraction)
            : null;

    public static string Label(double fraction)
    {
        var percent = (int)Math.Round(fraction * 100, MidpointRounding.AwayFromZero);
        return percent < 1 ? "under 1% OpenClicky" : $"about {percent}% OpenClicky";
    }
}
