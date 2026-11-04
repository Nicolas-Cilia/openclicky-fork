// Ports PlanUsage.swift: what the Claude and Codex plans have used. Two kinds of numbers:
//   - PlanUsageLedger: what OpenClicky itself sent, counted per request in
//     %USERPROFILE%\.openclicky\usage.jsonl (counts only, never the words).
//   - PlanLimitStore: how full the plan's own limits are, as the CLIs report them. These cover
//     everything on the account, not just OpenClicky.
// PlanAvailability remembers which plan has run out and until when, which is what the router asks
// when it picks who answers.

using System.Diagnostics;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.Json.Serialization;
using OpenClicky.Core.Answers;
using OpenClicky.Core.Configuration;

namespace OpenClicky.Core.Providers;

public enum PlanUsageLane { Answer, Agent }

/// <summary>One request. On disk it has the Mac's fields: `date` is seconds since 2001-01-01 (Swift's default).</summary>
public sealed record PlanUsageSample(
    DateTimeOffset Date,
    string Source,
    PlanUsageLane Lane,
    int InputTokens,
    int CachedInputTokens,
    int OutputTokens,
    double? EstimatedCostUSD = null)
{
    private static readonly DateTimeOffset SwiftReferenceDate = new(2001, 1, 1, 0, 0, 0, TimeSpan.Zero);

    public string ToJsonLine()
    {
        var json = new JsonObject
        {
            ["date"] = (Date - SwiftReferenceDate).TotalSeconds,
            ["source"] = Source,
            ["lane"] = Lane == PlanUsageLane.Agent ? "agent" : "answer",
            ["inputTokens"] = InputTokens,
            ["cachedInputTokens"] = CachedInputTokens,
            ["outputTokens"] = OutputTokens,
        };
        if (EstimatedCostUSD is { } cost) json["estimatedCostUSD"] = cost;
        return json.ToJsonString();
    }

    public static PlanUsageSample? FromJsonLine(string line)
    {
        try
        {
            if (JsonNode.Parse(line) is not JsonObject json) return null;
            if (json["date"]?.GetValue<double>() is not { } seconds || json["source"]?.GetValue<string>() is not { } source) return null;
            return new PlanUsageSample(
                SwiftReferenceDate.AddSeconds(seconds), source,
                json["lane"]?.GetValue<string>() == "agent" ? PlanUsageLane.Agent : PlanUsageLane.Answer,
                json["inputTokens"]?.GetValue<int>() ?? 0, json["cachedInputTokens"]?.GetValue<int>() ?? 0,
                json["outputTokens"]?.GetValue<int>() ?? 0, json["estimatedCostUSD"]?.GetValue<double>());
        }
        catch (Exception error) when (error is JsonException or InvalidOperationException or FormatException)
        {
            return null;
        }
    }
}

public sealed record PlanUsageTotals(int Requests = 0, int Tokens = 0, double? EstimatedCostUSD = null)
{
    public PlanUsageTotals Adding(PlanUsageSample sample) => new(
        Requests + 1,
        Tokens + sample.InputTokens + sample.OutputTokens,
        sample.EstimatedCostUSD is { } cost ? (EstimatedCostUSD ?? 0) + cost : EstimatedCostUSD);
}

public sealed class PlanUsageLedger(string filePath)
{
    private static readonly Lazy<PlanUsageLedger> SharedInstance = new(() => new PlanUsageLedger(Path.Combine(OpenClickyPaths.SettingsDirectory, "usage.jsonl")));
    public static PlanUsageLedger Shared => SharedInstance.Value;

    /// <summary>Raised after a request is written, on whichever thread wrote it.</summary>
    public static event Action? Changed;

    private readonly object fileLock = new();

    public void Record(PlanUsageSample sample)
    {
        try
        {
            lock (fileLock)
            {
                Directory.CreateDirectory(Path.GetDirectoryName(filePath)!);
                File.AppendAllText(filePath, sample.ToJsonLine() + "\n", new UTF8Encoding(false));
            }
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            AppLog.Write($"usage: could not write the ledger: {error.Message}");
            return;
        }
        Changed?.Invoke();
    }

    /// <summary>Every readable sample; a line that cannot be read is skipped rather than losing the rest.</summary>
    public IReadOnlyList<PlanUsageSample> Samples()
    {
        try
        {
            lock (fileLock)
            {
                if (!File.Exists(filePath)) return [];
                return File.ReadAllLines(filePath).Select(PlanUsageSample.FromJsonLine).OfType<PlanUsageSample>().ToList();
            }
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            return [];
        }
    }

    public PlanUsageTotals Totals(AnswerSource source, DateTimeOffset? since = null)
    {
        var totals = new PlanUsageTotals();
        foreach (var sample in Samples())
        {
            if (sample.Source == source.Id() && (since is null || sample.Date >= since)) totals = totals.Adding(sample);
        }
        return totals;
    }
}

public sealed record PlanLimitWindow(string Title, double UsedFraction, DateTimeOffset? ResetsAt);

public sealed record PlanLimitSnapshot
{
    public IReadOnlyList<PlanLimitWindow> Windows { get; init; } = [];
    /// <summary>The plan refused, or said it would refuse, the next request.</summary>
    public bool IsRejected { get; init; }
    /// <summary>When a refusal lifts, when the plan said so outside any one window.</summary>
    public DateTimeOffset? ResetsAt { get; init; }
    /// <summary>Credits bought on top of the plan (Codex), when there are any.</summary>
    public string? CreditsBalance { get; init; }
    public string? PlanName { get; init; }

    /// <summary>When this plan can be used again, if it has run out.</summary>
    [JsonIgnore]
    public DateTimeOffset? ExhaustedUntil
    {
        get
        {
            var full = Windows.Where(window => window.UsedFraction >= 1 && window.ResetsAt is not null).Select(window => window.ResetsAt!.Value).ToList();
            if (full.Count > 0) return full.Max();
            return IsRejected ? ResetsAt : null;
        }
    }

    [JsonIgnore]
    public bool IsExhausted => IsRejected || Windows.Any(window => window.UsedFraction >= 1);

    public static string WindowTitle(int minutes)
    {
        if (minutes >= 1440 && minutes % 1440 == 0) return $"{minutes / 1440} {(minutes == 1440 ? "day" : "days")}";
        if (minutes >= 60 && minutes % 60 == 0) return $"{minutes / 60} {(minutes == 60 ? "hour" : "hours")}";
        return $"{minutes} min";
    }

    private static double? Number(JsonNode? node) =>
        node is JsonValue value && (value.TryGetValue<double>(out var number) || double.TryParse(value.ToString(), out number)) ? number : null;

    private static DateTimeOffset? UnixDate(JsonNode? node) =>
        Number(node) is { } seconds ? DateTimeOffset.FromUnixTimeMilliseconds((long)(seconds * 1000)) : null;

    private static string? Text(JsonNode? node) =>
        node is JsonValue value && value.TryGetValue<string>(out var text) ? text : null;

    /// <summary>
    /// `rate_limit_info` from `claude -p --output-format stream-json`: `unifiedWindows` holds
    /// `utilization` as a fraction (0.06 is 6%) and `resetsAt` in Unix seconds.
    /// </summary>
    public static PlanLimitSnapshot FromClaude(JsonObject info)
    {
        (string Name, string Title)[] known = [("five_hour", "5 hours"), ("seven_day", "7 days")];
        var unified = info["unifiedWindows"] as JsonObject ?? [];
        var names = known.Select(entry => entry.Name).Where(unified.ContainsKey)
            .Concat(unified.Select(entry => entry.Key).Where(key => known.All(entry => entry.Name != key)).OrderBy(key => key, StringComparer.Ordinal));
        var windows = new List<PlanLimitWindow>();
        foreach (var name in names)
        {
            if (unified[name] is not JsonObject window || Number(window["utilization"]) is not { } utilization) continue;
            var title = known.FirstOrDefault(entry => entry.Name == name).Title ?? name.Replace('_', ' ');
            windows.Add(new PlanLimitWindow(title, Math.Clamp(utilization, 0, 1), UnixDate(window["resetsAt"])));
        }
        return new PlanLimitSnapshot
        {
            Windows = windows,
            IsRejected = Text(info["status"]) == "rejected",
            ResetsAt = UnixDate(info["resetsAt"]),
        };
    }

    /// <summary>The reply to the Codex app-server's `account/rateLimits/read`.</summary>
    public static PlanLimitSnapshot? FromCodex(JsonObject result)
    {
        if (result["rateLimits"] is not JsonObject limits) return null;
        var windows = new List<PlanLimitWindow>();
        foreach (var key in new[] { "primary", "secondary" })
        {
            if (limits[key] is not JsonObject window || Number(window["usedPercent"]) is not { } used) continue;
            windows.Add(new PlanLimitWindow(
                Number(window["windowDurationMins"]) is { } minutes ? WindowTitle((int)minutes) : key,
                Math.Clamp(used / 100, 0, 1),
                UnixDate(window["resetsAt"])));
        }
        var allowed = result["ordinaryUsageAllowed"] is JsonValue allowedValue && allowedValue.TryGetValue<bool>(out var isAllowed) ? isAllowed : (bool?)null;
        return new PlanLimitSnapshot
        {
            Windows = windows,
            IsRejected = allowed == false || limits["rateLimitReachedType"] is not null,
            CreditsBalance = limits["credits"] is JsonObject credits && credits["hasCredits"] is JsonValue has && has.TryGetValue<bool>(out var hasCredits) && hasCredits
                ? Text(credits["balance"])
                : null,
            PlanName = Text(limits["planType"]),
        };
    }
}

/// <summary>Which plan has run out, and until when. Read from any thread by the router; survives a relaunch.</summary>
public sealed class PlanAvailability(Preferences preferences)
{
    private static readonly Lazy<PlanAvailability> SharedInstance = new(() => new PlanAvailability(Preferences.Shared));
    public static PlanAvailability Shared => SharedInstance.Value;

    /// <summary>How long to rest a plan whose refusal gave no reset time.</summary>
    public static readonly TimeSpan RestWithoutResetTime = TimeSpan.FromMinutes(30);
    private const string PreferencesKey = "openclicky.plans.exhaustedUntil";

    private readonly object entriesLock = new();

    private Dictionary<string, double> Read() =>
        preferences.GetString(PreferencesKey) is { } json
            ? JsonSerializer.Deserialize<Dictionary<string, double>>(json) ?? []
            : [];

    private void Write(Dictionary<string, double> entries) => preferences.Set(PreferencesKey, JsonSerializer.Serialize(entries));

    public void MarkExhausted(AnswerSource source, DateTimeOffset? until, DateTimeOffset? now = null)
    {
        var current = now ?? DateTimeOffset.UtcNow;
        var end = until is { } given && given > current ? given : current + RestWithoutResetTime;
        lock (entriesLock)
        {
            var entries = Read();
            entries[source.Id()] = end.ToUnixTimeMilliseconds() / 1000.0;
            Write(entries);
        }
        AppLog.Write($"plans: {source.Id()} has hit its limit, resting it");
    }

    public void Clear(AnswerSource source)
    {
        lock (entriesLock)
        {
            var entries = Read();
            if (entries.Remove(source.Id())) Write(entries);
        }
    }

    public DateTimeOffset? ExhaustedUntil(AnswerSource source, DateTimeOffset? now = null)
    {
        Dictionary<string, double> entries;
        lock (entriesLock) entries = Read();
        if (!entries.TryGetValue(source.Id(), out var seconds)) return null;
        var end = DateTimeOffset.FromUnixTimeMilliseconds((long)(seconds * 1000));
        return end > (now ?? DateTimeOffset.UtcNow) ? end : null;
    }

    public IReadOnlySet<AnswerSource> ExhaustedPlans(DateTimeOffset? now = null) =>
        new[] { AnswerSource.ClaudeCodePlan, AnswerSource.CodexPlan }.Where(plan => ExhaustedUntil(plan, now) is not null).ToHashSet();
}

/// <summary>
/// Where a plan provider reports what a request used. The default reports nowhere, so a test never
/// writes to the real ledger; AnswerProviderFactory hands providers <see cref="Live"/>.
/// </summary>
public sealed class PlanUsageSink
{
    public Action<PlanUsageSample> Record { get; init; } = _ => { };
    public Action<AnswerSource, PlanLimitSnapshot> Limits { get; init; } = (_, _) => { };

    public static PlanUsageSink None { get; } = new();

    public static PlanUsageSink Live { get; } = new()
    {
        Record = sample =>
        {
            PlanUsageLedger.Shared.Record(sample);
            if (sample.Source == AnswerSource.CodexPlan.Id()) _ = PlanLimitStore.Shared.RefreshCodexAsync();
        },
        Limits = (source, snapshot) => PlanLimitStore.Shared.Ingest(snapshot, source),
    };
}

public sealed class PlanLimitStore
{
    private static readonly Lazy<PlanLimitStore> SharedInstance = new(() => new PlanLimitStore(Preferences.Shared, PlanAvailability.Shared));
    public static PlanLimitStore Shared => SharedInstance.Value;

    private const string PreferencesKey = "openclicky.plans.limits";
    private static readonly TimeSpan CodexRefreshInterval = TimeSpan.FromSeconds(60);

    private readonly Preferences preferences;
    private readonly Func<Task<PlanLimitSnapshot?>> readCodex;
    private readonly object stateLock = new();
    private readonly Dictionary<AnswerSource, PlanLimitSnapshot> snapshots = [];
    private DateTimeOffset? lastCodexRead;

    public PlanAvailability Availability { get; }

    /// <summary>Raised when a report arrives or a plan runs out, on whichever thread it happened.</summary>
    public event Action? Changed;

    public PlanLimitStore(Preferences preferences, PlanAvailability availability, Func<Task<PlanLimitSnapshot?>>? readCodex = null)
    {
        this.preferences = preferences;
        Availability = availability;
        this.readCodex = readCodex ?? (() => CodexRateLimits.ReadAsync());
        try
        {
            if (preferences.GetString(PreferencesKey) is { } json
                && JsonSerializer.Deserialize<Dictionary<string, PlanLimitSnapshot>>(json) is { } saved)
            {
                foreach (var (name, snapshot) in saved)
                {
                    if (AnswerSources.FromRawValue(name) is { } source) snapshots[source] = snapshot;
                }
            }
        }
        catch (JsonException) { }
    }

    public PlanLimitSnapshot? Snapshot(AnswerSource source)
    {
        lock (stateLock) return snapshots.GetValueOrDefault(source);
    }

    public void Ingest(PlanLimitSnapshot snapshot, AnswerSource source)
    {
        string saved;
        lock (stateLock)
        {
            snapshots[source] = snapshot;
            saved = JsonSerializer.Serialize(snapshots.ToDictionary(entry => entry.Key.Id(), entry => entry.Value));
        }
        if (snapshot.IsExhausted) Availability.MarkExhausted(source, snapshot.ExhaustedUntil);
        else Availability.Clear(source);
        preferences.Set(PreferencesKey, saved);
        Changed?.Invoke();
    }

    public async Task RefreshCodexAsync(bool force = false, DateTimeOffset? now = null)
    {
        var current = now ?? DateTimeOffset.UtcNow;
        lock (stateLock)
        {
            if (!force && lastCodexRead is { } last && current - last < CodexRefreshInterval) return;
            lastCodexRead = current;
        }
        try
        {
            if (await readCodex().ConfigureAwait(false) is { } snapshot) Ingest(snapshot, AnswerSource.CodexPlan);
        }
        catch (Exception error) when (error is not OutOfMemoryException)
        {
            AppLog.Write($"plans: reading codex's limits failed ({error.GetType().Name})");
        }
    }

    /// <summary>A plan just refused a request. Codex can be asked when it comes back; Claude has already said in the same stream.</summary>
    public async Task NoteLimitHitAsync(AnswerSource source)
    {
        if (source == AnswerSource.CodexPlan) await RefreshCodexAsync(force: true).ConfigureAwait(false);
        if (Availability.ExhaustedUntil(source) is null) Availability.MarkExhausted(source, Snapshot(source)?.ExhaustedUntil);
        Changed?.Invoke();
    }
}

/// <summary>
/// Asks `codex app-server` how full the ChatGPT plan's limits are. CODEX_HOME is removed from its
/// environment (PlanCLIs.ProcessEnvironment), so this reads the person's own sign-in.
/// </summary>
public static class CodexRateLimits
{
    public const string InitializeLine = """{"id":1,"method":"initialize","params":{"clientInfo":{"name":"openclicky","version":"1"}}}""";
    public const string InitializedLine = """{"method":"initialized"}""";
    public const string ReadLine = """{"id":2,"method":"account/rateLimits/read"}""";

    public static async Task<PlanLimitSnapshot?> ReadAsync()
    {
        if (await PlanCLIs.CodexPathAsync().ConfigureAwait(false) is not { } path) return null;
        return await ReadAsync(path, PlanCLIs.ProcessEnvironment(path), TimeSpan.FromSeconds(15)).ConfigureAwait(false);
    }

    public static async Task<PlanLimitSnapshot?> ReadAsync(string executablePath, IReadOnlyDictionary<string, string> environment, TimeSpan timeout)
    {
        var launch = PlanCliLaunch.Resolve(executablePath, ["app-server"], environment);
        var startInfo = new ProcessStartInfo(launch.FileName)
        {
            RedirectStandardInput = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
            CreateNoWindow = true,
            WorkingDirectory = Path.GetTempPath(),
            StandardInputEncoding = new UTF8Encoding(false),
            StandardOutputEncoding = Encoding.UTF8,
        };
        if (launch.RawArguments is { } rawArguments) startInfo.Arguments = rawArguments;
        else foreach (var argument in launch.ArgumentList) startInfo.ArgumentList.Add(argument);
        startInfo.Environment.Clear();
        foreach (var (name, value) in environment) startInfo.Environment[name] = value;

        using var process = new Process { StartInfo = startInfo };
        using var deadline = new CancellationTokenSource(timeout);
        try
        {
            if (!process.Start()) return null;
            process.ErrorDataReceived += (_, _) => { };
            process.BeginErrorReadLine();
            await process.StandardInput.WriteLineAsync(InitializeLine.AsMemory(), deadline.Token).ConfigureAwait(false);
            await process.StandardInput.FlushAsync().ConfigureAwait(false);
            while (await process.StandardOutput.ReadLineAsync(deadline.Token).ConfigureAwait(false) is { } line)
            {
                if (ParseLine(line) is not { } message) continue;
                if (message.Id == 1)
                {
                    await process.StandardInput.WriteLineAsync(InitializedLine.AsMemory(), deadline.Token).ConfigureAwait(false);
                    await process.StandardInput.WriteLineAsync(ReadLine.AsMemory(), deadline.Token).ConfigureAwait(false);
                    await process.StandardInput.FlushAsync().ConfigureAwait(false);
                }
                else if (message.Id == 2)
                {
                    return message.Result is { } result ? PlanLimitSnapshot.FromCodex(result) : null;
                }
            }
            return null;
        }
        catch (Exception error) when (error is OperationCanceledException or IOException or InvalidOperationException or System.ComponentModel.Win32Exception)
        {
            return null;
        }
        finally
        {
            try { if (!process.HasExited) process.Kill(entireProcessTree: true); }
            catch (Exception error) when (error is InvalidOperationException or System.ComponentModel.Win32Exception or NotSupportedException) { }
        }
    }

    private static (int Id, JsonObject? Result)? ParseLine(string line)
    {
        try
        {
            if (JsonNode.Parse(line) is JsonObject message && message["id"] is JsonValue id && id.TryGetValue<int>(out var number))
            {
                return (number, message["result"] as JsonObject);
            }
        }
        catch (JsonException) { }
        return null;
    }
}

/// <summary>Words the plan CLIs use when a plan has run out.</summary>
public static class PlanLimitText
{
    private static readonly string[] Phrases = ["usage limit", "rate_limit", "rate limit", "hit your limit", "limit reached", "limit exceeded", "quota"];

    public static bool Matches(string text) => Phrases.Any(phrase => text.Contains(phrase, StringComparison.OrdinalIgnoreCase));
}

/// <summary>Switches on a plan that is already signed in, once: a plan someone switched off stays off.</summary>
public static class PlanAutoLink
{
    public static async Task RunAsync()
    {
        var settings = OpenClickyConfiguration.Settings;
        var claudeReady = settings.UseClaudeCodePlan is null && await PlanCLIs.ClaudeCodeStatusAsync().ConfigureAwait(false) == PlanCliStatus.Ready;
        var codexReady = settings.UseCodexPlan is null && await PlanCLIs.CodexStatusAsync().ConfigureAwait(false) == PlanCliStatus.Ready;
        if (!claudeReady && !codexReady) return;
        OpenClickyConfiguration.Update(shell =>
        {
            if (claudeReady) shell.UseClaudeCodePlan = true;
            if (codexReady) shell.UseCodexPlan = true;
        });
        AppLog.Write($"plans: linked what is already signed in (claude {claudeReady}, codex {codexReady})");
    }
}
