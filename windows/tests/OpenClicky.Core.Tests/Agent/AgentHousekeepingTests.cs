using OpenClicky.Core.Agent;
using Xunit;

namespace OpenClicky.Core.Tests.Agent;

public class AgentHousekeepingTests
{
    [Fact]
    public void TheLimitDefaultsToTwoWeeksAndZeroKeepsEverything()
    {
        Assert.Equal(14, AgentSessionLimit.Days(null));
        Assert.Equal(14, AgentSessionLimit.Days(-3));
        Assert.Equal(30, AgentSessionLimit.Days(30));
        Assert.Equal(0, AgentSessionLimit.Days(0));
        Assert.Contains(AgentSessionLimit.DefaultDays, AgentSessionLimit.Choices);
        Assert.Equal("Forever", AgentSessionLimit.Label(0));
        Assert.Equal("14 days", AgentSessionLimit.Label(14));
    }

    [Fact]
    public void ThePruneReplyListsWhatWasDeleted()
    {
        Assert.Equal(["a", "b"], OpenClickyThreadDetail.DecodeDeleted("""{"deleted":["a","b"]}"""));
        Assert.Empty(OpenClickyThreadDetail.DecodeDeleted("""{"deleted":[]}"""));
    }

    [Fact]
    public void OnlyOldScreenshotsOfOursAreSwept()
    {
        var folder = Directory.CreateTempSubdirectory().FullName;
        try
        {
            var now = DateTime.UtcNow;
            string Make(string path, TimeSpan age)
            {
                File.WriteAllBytes(path, [1]);
                File.SetLastWriteTimeUtc(path, now - age);
                return path;
            }
            var old = Make(AgentHousekeeping.NewScreenshotPath(folder), TimeSpan.FromHours(2));
            var inUse = Make(AgentHousekeeping.NewScreenshotPath(folder), TimeSpan.FromMinutes(1));
            var notOurs = Make(Path.Combine(folder, "holiday.jpg"), TimeSpan.FromHours(2));
            var otherKind = Make(Path.Combine(folder, "openclicky-notes.txt"), TimeSpan.FromHours(2));

            AgentHousekeeping.RemoveLeftoverScreenshots(folder, now);

            Assert.False(File.Exists(old));
            foreach (var kept in new[] { inUse, notOurs, otherKind }) Assert.True(File.Exists(kept));
        }
        finally
        {
            Directory.Delete(folder, recursive: true);
        }
    }
}
