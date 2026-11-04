using OpenClicky.Core.Agent;
using OpenClicky.Core.Companion;
using OpenClicky.Core.Speech;
using Xunit;

namespace OpenClicky.Core.Tests.Agent;

public class AgentToolTests
{
    [Fact]
    public void AHandSetCommandAlwaysWins()
    {
        string[] command = ["node", @"C:\repo\agent\dist\cli.js"];
        Assert.Equal(command, AgentTool.Command(command, "cli.js", "downloaded", "system"));
    }

    [Fact]
    public void TheBundledToolRunsOnDownloadedNodeFirstThenThisPCs()
    {
        var unset = AgentTool.UnconfiguredCommand;
        Assert.Equal(["downloaded", "cli.js"], AgentTool.Command(unset, "cli.js", "downloaded", "system"));
        Assert.Equal(["system", "cli.js"], AgentTool.Command(unset, "cli.js", null, "system"));
    }

    [Fact]
    public void WithoutNodeOrABundledToolItFallsBackToWhateverIsLinked()
    {
        var unset = AgentTool.UnconfiguredCommand;
        Assert.Equal(unset, AgentTool.Command(unset, "cli.js", null, null));
        Assert.Equal(unset, AgentTool.Command(unset, null, "downloaded", "system"));
    }

    [Theory]
    [InlineData("v22.0.0\r\n", true)]
    [InlineData("v26.13.0", true)]
    [InlineData("v20.11.1", false)]
    [InlineData("nonsense", false)]
    public void NodeMustBeNewEnough(string version, bool expected) => Assert.Equal(expected, AgentTool.IsNewEnough(version));

    [Fact]
    public void KokoroIsOfferedOnlyToSomeoneOnThePCsOwnVoice()
    {
        Assert.True(FirstRunTourController.OffersNaturalVoice(false, SpeechVoiceChoice.Mac, true));
        Assert.False(FirstRunTourController.OffersNaturalVoice(true, SpeechVoiceChoice.Mac, true));
        Assert.False(FirstRunTourController.OffersNaturalVoice(false, SpeechVoiceChoice.ElevenLabs, true));
        Assert.False(FirstRunTourController.OffersNaturalVoice(false, SpeechVoiceChoice.Mac, false));
    }
}
