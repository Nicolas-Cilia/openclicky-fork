using OpenClicky.Core.Providers;
using OpenClicky.Core.Configuration;
using Xunit;

namespace OpenClicky.Core.Tests.Providers;

public class PlanUsageShareTests
{
    private static readonly DateTimeOffset Now = new(2026, 11, 4, 12, 0, 0, TimeSpan.Zero);

    private static PlanLimitWindow Window(double used, string title = "5 hours", double resetsInHours = 1) =>
        new(title, used, Now.AddHours(resetsInHours));

    private static PlanLimitSnapshot Snapshot(double used, double resetsInHours = 1) =>
        new() { Windows = [Window(used, resetsInHours: resetsInHours)] };

    private static PlanUsageSample Sample(AnswerSource source, double hoursAgo = 0.1) =>
        new(Now.AddHours(-hoursAgo), source.Id(), PlanUsageLane.Answer, 1000, 0, 0);

    [Fact]
    public void TokensWeighByWhatTheyCost() => Assert.Equal(610, PlanUsageShare.Weight(100, 100, 100));

    [Fact]
    public void WindowLengthsComeFromTheirTitles()
    {
        Assert.Equal(TimeSpan.FromHours(5), PlanUsageShare.Duration("5 hours"));
        Assert.Equal(TimeSpan.FromDays(7), PlanUsageShare.Duration("7 days"));
        Assert.Equal(TimeSpan.FromMinutes(30), PlanUsageShare.Duration("30 min"));
        Assert.Null(PlanUsageShare.Duration("seven day opus"));
    }

    [Fact]
    public void ClaudesShareIsOursAgainstWhatThisComputerLogged()
    {
        var share = PlanUsageShare.ClaudeFraction(Window(0.2), [Sample(AnswerSource.ClaudeCodePlan)], [new LocalClaudeUsage(Now, 3000)]);
        Assert.Equal(0.05, share!.Value, 4);
    }

    [Fact]
    public void ClaudesShareOnlyCountsThisWindowAndThisPlan()
    {
        Assert.Null(PlanUsageShare.ClaudeFraction(Window(0.2), [Sample(AnswerSource.ClaudeCodePlan, 5), Sample(AnswerSource.CodexPlan)], []));
        Assert.Null(PlanUsageShare.ClaudeFraction(Window(0.2, "seven day opus"), [Sample(AnswerSource.ClaudeCodePlan)], []));
        Assert.Equal(0.2, PlanUsageShare.ClaudeFraction(Window(0.2), [Sample(AnswerSource.ClaudeCodePlan)], [new LocalClaudeUsage(Now.AddHours(-5), 9999)])!.Value, 4);
    }

    [Fact]
    public void ClaudesLogsKeepTheLastLineOfEachRequestAndOnlyCounts()
    {
        var folder = Directory.CreateTempSubdirectory().FullName;
        try
        {
            var project = Directory.CreateDirectory(Path.Combine(folder, "some-project", "subagents")).FullName;
            static string Line(string id, string time, int output) =>
                "{\"type\":\"assistant\",\"timestamp\":\"" + time + "\",\"requestId\":\"r\",\"message\":{\"id\":\"" + id + "\",\"content\":[{\"type\":\"text\",\"text\":\"secret words\"}],"
                + "\"usage\":{\"input_tokens\":10,\"cache_creation_input_tokens\":90,\"cache_read_input_tokens\":100,\"output_tokens\":" + output + "}}}";
            File.WriteAllLines(Path.Combine(project, "x.jsonl"),
            [
                Line("a", "2026-05-18T03:00:00.000Z", 1),
                Line("a", "2026-05-18T03:00:01Z", 10),
                Line("old", "2020-01-01T00:00:00.000Z", 5000),
                """{"type":"user","message":{"content":"no usage here"}}""",
                "not json with \"usage\" in it",
            ]);
            File.WriteAllText(Path.Combine(project, "x.txt"), Line("skip", "2026-05-18T03:00:00Z", 7));

            var usage = PlanUsageShare.ReadLocalClaudeUsage(new DateTimeOffset(2023, 11, 1, 0, 0, 0, TimeSpan.Zero), folder);

            Assert.Equal([160.0], usage.Select(entry => entry.Weight));
        }
        finally
        {
            Directory.Delete(folder, recursive: true);
        }
    }

    [Fact]
    public void AMissingLogsFolderIsNoUsage() =>
        Assert.Empty(PlanUsageShare.ReadLocalClaudeUsage(DateTimeOffset.MinValue, Path.Combine(Path.GetTempPath(), Guid.NewGuid().ToString())));

    [Fact]
    public void CodexAddsUpHowFarEachRequestMovedTheBar()
    {
        var measured = PlanUsageShare.Adding(Snapshot(0.10), Snapshot(0.12), []);
        measured = PlanUsageShare.Adding(Snapshot(0.20), Snapshot(0.21), measured);
        Assert.Equal(0.03, PlanUsageShare.CodexFraction(Window(0.30), measured)!.Value, 4);
    }

    [Fact]
    public void AResetStartsTheCountAgain()
    {
        var oldWindow = PlanUsageShare.Adding(Snapshot(0.10), Snapshot(0.50), []);
        var reset = PlanUsageShare.Adding(Snapshot(0.50), Snapshot(0.02, resetsInHours: 5), oldWindow);
        Assert.Equal(0, PlanUsageShare.CodexFraction(Window(0.02, resetsInHours: 5), reset));
        Assert.Null(PlanUsageShare.CodexFraction(Window(0.02, resetsInHours: 5), oldWindow));
    }

    [Fact]
    public void TheShareIsNeverBiggerThanTheBarAndToleratesANudgedResetTime()
    {
        var measured = PlanUsageShare.Adding(Snapshot(0.10), Snapshot(0.50), []);
        Assert.Equal(0.20, PlanUsageShare.CodexFraction(Window(0.20, resetsInHours: 1.01), measured));
    }

    [Fact]
    public void LabelsSayItIsAnEstimate()
    {
        Assert.Equal("about 2% OpenClicky", PlanUsageShare.Label(0.021));
        Assert.Equal("under 1% OpenClicky", PlanUsageShare.Label(0.004));
    }

    [Fact]
    public async Task TheStoreMeasuresAcrossARequestAndKeepsIt()
    {
        var preferences = Preferences.InMemory();
        var readings = new Queue<PlanLimitSnapshot>([Snapshot(0.10), Snapshot(0.13)]);
        var store = new PlanLimitStore(preferences, new PlanAvailability(preferences), () => Task.FromResult<PlanLimitSnapshot?>(readings.Dequeue()));

        store.BeginCodexRequest(TimeSpan.Zero)();
        for (var attempt = 0; attempt < 200 && store.CodexMeasured.Count == 0; attempt++) await Task.Delay(5);

        Assert.Equal(0.03, store.CodexMeasured[0].UsedFraction, 4);
        var reopened = new PlanLimitStore(preferences, new PlanAvailability(preferences), () => Task.FromResult<PlanLimitSnapshot?>(null));
        Assert.Equal(store.CodexMeasured, reopened.CodexMeasured);
    }
}
