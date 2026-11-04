// The CompanionManager-level rules that are logic (OpenClickyTests, AskLaneFailureTests'
// notices, HUDPlacementTests' open-at-login offer, NotchVoiceDestination), plus the seams the
// integration added (the orb adapter, the connect card mapping).

using System.Text;
using OpenClicky.Core.Companion;
using OpenClicky.Core.Dictation;
using OpenClicky.Core.Platform;
using OpenClicky.Core.Pointing;
using OpenClicky.Core.Providers;
using OpenClicky.Core.Settings;

namespace OpenClicky.Core.Tests.Companion;

public class CompanionManagerTests
{
    private static CompanionScreenCapture Capture(bool isCursorScreen, int left = 0, int top = 0, int width = 3024, int height = 1964,
                                                  int screenshotWidth = 1280, int screenshotHeight = 831, string device = "\\\\.\\DISPLAY1") =>
        new([1, 2, 3], "image/jpeg", "screen", isCursorScreen, width / 2, height / 2, new PixelRect(left, top, width, height), 2.0, device,
            screenshotWidth, screenshotHeight);

    // MARK: pointing

    [Fact]
    public void AScreenshotPointLandsOnTheCapturedMonitorInPixels()
    {
        var capture = Capture(true, left: -3024, top: 100);
        var location = CompanionManager.ScreenLocation(new ScreenPoint(640, 415.5), capture);
        Assert.Equal(-3024 + 640 * 3024.0 / 1280, location.X, 3);
        Assert.Equal(100 + 415.5 * 1964.0 / 831, location.Y, 3);
    }

    [Fact]
    public void AnOutOfRangeOrNaNPointIsClampedToTheScreenshot()
    {
        var capture = Capture(true);
        Assert.Equal(new ScreenPoint(3024, 1964), CompanionManager.ScreenLocation(new ScreenPoint(99_999, double.PositiveInfinity), capture));
        Assert.Equal(new ScreenPoint(0, 0), CompanionManager.ScreenLocation(new ScreenPoint(double.NaN, -40), capture));
    }

    // MARK: the screens a question carries

    [Fact]
    public void TheCursorScreenGoesFirst()
    {
        var captures = new[] { Capture(false, device: "a"), Capture(false, device: "b"), Capture(true, device: "c") };
        Assert.Equal(["c", "a", "b"], CompanionManager.ScreensForAsk(captures).Select(capture => capture.DeviceName));
    }

    // MARK: the open-at-sign-in offer (HUDPlacementTests)

    [Fact]
    public void TheIslandOffersOpenAtLoginOnceAfterFiveUses()
    {
        Assert.False(FirstRunTourController.ShouldOfferOpenAtLogin(4, tourIsFinished: true, alreadyAsked: false, isOpenAtLogin: false));
        Assert.True(FirstRunTourController.ShouldOfferOpenAtLogin(5, tourIsFinished: true, alreadyAsked: false, isOpenAtLogin: false));
        Assert.False(FirstRunTourController.ShouldOfferOpenAtLogin(9, tourIsFinished: true, alreadyAsked: true, isOpenAtLogin: false));
        Assert.False(FirstRunTourController.ShouldOfferOpenAtLogin(9, tourIsFinished: false, alreadyAsked: false, isOpenAtLogin: false));
        Assert.False(FirstRunTourController.ShouldOfferOpenAtLogin(9, tourIsFinished: true, alreadyAsked: false, isOpenAtLogin: true));
    }

    [Fact]
    public void TheTourStepIsStoredUnderTheMacsRawValues()
    {
        foreach (var step in Enum.GetValues<FirstRunTourStep>())
        {
            Assert.Equal(step, FirstRunTourController.StepFromRaw(FirstRunTourController.RawValue(step)));
        }
        Assert.Equal("openAtLogin", FirstRunTourController.RawValue(FirstRunTourStep.OpenAtLogin));
        Assert.Null(FirstRunTourController.StepFromRaw("speech"));
    }

    // MARK: the voice pill (NotchVoiceDestination)

    [Fact]
    public void TheVoicePillNamesWhatIsMissingAndOpensThePageThatFixesIt()
    {
        Assert.Null(IslandVoiceDestination.BlockedPillLabel(DictationEngineChoice.Offline, null));
        Assert.Equal("add sarvam key ›", IslandVoiceDestination.BlockedPillLabel(DictationEngineChoice.Sarvam, "needs a sarvam key"));
        Assert.Equal(DictationSettingsPage.Keys, IslandVoiceDestination.SetupPage(DictationEngineChoice.Sarvam, "needs a sarvam key"));
        Assert.Equal("download parakeet ›", IslandVoiceDestination.BlockedPillLabel(DictationEngineChoice.Parakeet, "not downloaded"));
        Assert.Equal("pick a language parakeet hears ›",
            IslandVoiceDestination.BlockedPillLabel(DictationEngineChoice.Parakeet, DictationEngineResolver.ParakeetLanguageNotHeardReason));
        Assert.Equal("open language settings",
            IslandVoiceDestination.ButtonTitle(DictationEngineChoice.Parakeet, DictationEngineResolver.ParakeetLanguageNotHeardReason));
        Assert.Equal("add your openai key ›", IslandVoiceDestination.BlockedPillLabel(DictationEngineChoice.OpenAI, "needs your own openai key"));
        Assert.Equal(DictationSettingsPage.Keys, IslandVoiceDestination.SetupPage(DictationEngineChoice.OpenAI, "needs your own openai key"));
        Assert.Equal(DictationSettingsPage.Dictation, IslandVoiceDestination.SetupPage(DictationEngineChoice.Parakeet, "not downloaded"));
        Assert.Equal("pick english or auto-detect ›",
            IslandVoiceDestination.BlockedPillLabel(DictationEngineChoice.Moonshine, DictationEngineResolver.MoonshineLanguageNotHeardReason));
        Assert.Equal("open language settings",
            IslandVoiceDestination.ButtonTitle(DictationEngineChoice.Moonshine, DictationEngineResolver.MoonshineLanguageNotHeardReason));
        Assert.Equal("pick another engine ›", IslandVoiceDestination.BlockedPillLabel(DictationEngineChoice.Moonshine, DictationEngineResolver.MoonshineMissingReason));
        Assert.Equal(DictationSettingsPage.Dictation, IslandVoiceDestination.SetupPage(DictationEngineChoice.Moonshine, DictationEngineResolver.MoonshineMissingReason));
    }

    // MARK: seams

    [Fact]
    public void TheTakeControllersOrbPhasesDriveTheOrbModel()
    {
        var orb = new OrbModel();
        var adapter = new OrbModelDictationAdapter(orb);
        adapter.Phase = DictationOrbPhase.Working("moving your words");
        Assert.Equal(OrbPhase.Working("moving your words"), orb.Phase);
        adapter.Phase = DictationOrbPhase.Failed("didn't catch that");
        Assert.Equal(OrbPhaseKind.Failed, orb.Phase.Kind);
        Assert.Equal(DictationOrbPhase.Failed("didn't catch that"), adapter.Phase);
        adapter.AudioLevel = 0.4;
        adapter.LiveTranscript = "hello";
        Assert.Equal(0.4, orb.AudioLevel);
        Assert.Equal("hello", orb.LiveTranscript);
        foreach (var phase in new[] { DictationOrbPhase.Idle, DictationOrbPhase.Listening, DictationOrbPhase.EditListening, DictationOrbPhase.Done("pasted") })
        {
            Assert.Equal(phase, OrbModelDictationAdapter.ToDictation(OrbModelDictationAdapter.ToOrb(phase)));
        }
    }

    [Fact]
    public void TheConnectCardKeepsItsWordsOnTheIsland()
    {
        Assert.Null(CompanionManager.IslandConnectCard(null));
        var prompt = new Core.Agent.AppConnectPrompt
        {
            SkillId = "gmail",
            AppName = "Gmail",
            Integration = "gmail",
            FrontExecutablePath = @"C:\chrome.exe",
            ExamplePrompts = ["archive the newsletters"],
            Stage = Core.Agent.AppConnectPromptStage.ComposioMissing,
        };
        var card = CompanionManager.IslandConnectCard(prompt)!;
        Assert.Equal("gmail skill is on", card.Headline);
        Assert.Equal(Core.Companion.AppConnectPromptStage.ComposioMissing, card.Stage);
        Assert.Equal(["archive the newsletters"], card.ExamplePrompts);
    }
}
