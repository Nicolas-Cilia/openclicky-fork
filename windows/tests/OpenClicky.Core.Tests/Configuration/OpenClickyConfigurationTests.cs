// Ports OpenClickyConfigurationTests.swift: the user's provider keys from shell.json reach the CLI
// under OpenClicky names, never as OPENAI_API_KEY; shell.json updates keep what they don't touch.

using System.Text.Json.Nodes;
using OpenClicky.Core.Configuration;

namespace OpenClicky.Core.Tests.Configuration;

public sealed class OpenClickyConfigurationTests : IDisposable
{
    private readonly string temporaryDirectory = Path.Combine(Path.GetTempPath(), $"openclicky-settings-test-{Guid.NewGuid()}");

    public OpenClickyConfigurationTests() => Directory.CreateDirectory(temporaryDirectory);

    public void Dispose()
    {
        try { Directory.Delete(temporaryDirectory, recursive: true); } catch (IOException) { }
    }

    private static readonly IReadOnlyDictionary<string, string> NoEnvironment = new Dictionary<string, string>();

    private string TemporarySettingsFile(string contents)
    {
        var filePath = Path.Combine(temporaryDirectory, "shell.json");
        File.WriteAllText(filePath, contents);
        return filePath;
    }

    private static JsonObject JsonObjectAt(string filePath) => JsonNode.Parse(File.ReadAllText(filePath))!.AsObject();

    [Fact]
    public void AnOwnKeyOrAPlanIsEnoughForModelCalls()
    {
        var settings = new OpenClickyShellSettings { OpenaiApiKey = " sk-user ", AnthropicApiKey = "" };
        Assert.True(OpenClickyConfiguration.UsesOwnKeysFor(settings));
        Assert.True(OpenClickyConfiguration.IsConfiguredFor(settings));
        Assert.True(OpenClickyConfiguration.IsConfiguredFor(new OpenClickyShellSettings { AnthropicApiKey = "ak-user" }));
        Assert.True(OpenClickyConfiguration.IsConfiguredFor(new OpenClickyShellSettings { UseCodexPlan = true }));
        Assert.False(OpenClickyConfiguration.UsesOwnKeysFor(new OpenClickyShellSettings()));
        Assert.False(OpenClickyConfiguration.IsConfiguredFor(new OpenClickyShellSettings()));
    }

    [Fact]
    public void CliEnvironmentCarriesTheUserKeysUnderOpenClickyNames()
    {
        var settings = new OpenClickyShellSettings { OpenaiApiKey = "sk-user" };
        var baseEnvironment = new Dictionary<string, string> { ["OPENAI_API_KEY"] = "sk-leaked", ["ANTHROPIC_API_KEY"] = "ak-leaked", ["PATH"] = "C:\\bin" };
        var environment = OpenClickyConfiguration.CliProcessEnvironmentFor(settings, baseEnvironment);
        Assert.Equal("sk-user", environment["OPENCLICKY_OPENAI_KEY"]);
        Assert.False(environment.ContainsKey("OPENCLICKY_TOKEN"));
        Assert.False(environment.ContainsKey("BACKEND_URL"));
        Assert.False(environment.ContainsKey("OPENAI_API_KEY"));
        Assert.False(environment.ContainsKey("ANTHROPIC_API_KEY"));
        Assert.False(environment.ContainsKey("OPENCLICKY_ANTHROPIC_KEY"));
        Assert.EndsWith("C:\\bin", environment["PATH"]);
    }

    [Fact]
    public void TheCliEnvironmentStripsKeysWhateverTheirCase()
    {
        if (!OperatingSystem.IsWindows()) return;
        var environment = OpenClickyConfiguration.CliProcessEnvironmentFor(new OpenClickyShellSettings(),
            new Dictionary<string, string> { ["openai_api_key"] = "sk-leaked" });
        Assert.DoesNotContain(environment.Keys, key => key.Equals("OPENAI_API_KEY", StringComparison.OrdinalIgnoreCase));
    }

    [Fact]
    public void ResolvedCuaDriverBinAnExplicitSettingWins()
    {
        var settings = new OpenClickyShellSettings { CuaDriverBin = " C:\\custom\\cua-driver.exe " };
        var resolved = OpenClickyConfiguration.ResolveCuaDriverBin(settings,
            new Dictionary<string, string> { ["CUA_DRIVER_BIN"] = "C:\\should\\be\\ignored" }, _ => true);
        Assert.Equal("C:\\custom\\cua-driver.exe", resolved);
    }

    [Fact]
    public void ResolvedCuaDriverBinAnExplicitEmptyStringDisablesIt()
    {
        var settings = new OpenClickyShellSettings { CuaDriverBin = "" };
        Assert.Null(OpenClickyConfiguration.ResolveCuaDriverBin(settings,
            new Dictionary<string, string> { ["CUA_DRIVER_BIN"] = "C:\\should\\also\\be\\ignored" }, _ => true));
    }

    [Fact]
    public void ResolvedCuaDriverBinFallsBackToTheEnvironmentThenAutoDiscovery()
    {
        var settings = new OpenClickyShellSettings();
        Assert.Equal("C:\\env\\cua-driver.exe", OpenClickyConfiguration.ResolveCuaDriverBin(settings,
            new Dictionary<string, string> { ["CUA_DRIVER_BIN"] = "C:\\env\\cua-driver.exe" }, _ => true));
        // Neither set: the first candidate the injected check reports executable wins, never the real disk.
        var second = OpenClickyConfiguration.CuaDriverCandidates[1];
        Assert.Equal(second, OpenClickyConfiguration.ResolveCuaDriverBin(settings, NoEnvironment, path => path == second));
        Assert.Null(OpenClickyConfiguration.ResolveCuaDriverBin(settings, NoEnvironment, _ => false));
    }

    [Fact]
    public void WritableRootsReachTheCliOnlyWhenTheUserSetsThem()
    {
        Assert.False(OpenClickyConfiguration.CliProcessEnvironmentFor(new OpenClickyShellSettings(), NoEnvironment).ContainsKey("OPENCLICKY_WRITABLE_ROOTS"));
        var settings = new OpenClickyShellSettings { WritableRoots = ["~/Desktop", "D:\\Work"] };
        Assert.Equal("~/Desktop,D:\\Work", OpenClickyConfiguration.CliProcessEnvironmentFor(settings, NoEnvironment)["OPENCLICKY_WRITABLE_ROOTS"]);
    }

    // MARK: - shell.json writes

    [Fact]
    public void WritingSettingsCreatesTheDirectoryAndTheFile()
    {
        var filePath = Path.Combine(temporaryDirectory, "nested", "shell.json");
        OpenClickyConfiguration.WriteShellSettingsData("{}", filePath);
        Assert.Equal("{}", File.ReadAllText(filePath));
        if (!OperatingSystem.IsWindows())
        {
            Assert.Equal(UnixFileMode.UserRead | UnixFileMode.UserWrite, File.GetUnixFileMode(filePath));
        }
        // No temp file is left beside it.
        Assert.Single(Directory.GetFiles(Path.GetDirectoryName(filePath)!));
    }

    [Fact]
    public void WritingSettingsReplacesAnExistingFile()
    {
        var filePath = TemporarySettingsFile("{}");
        OpenClickyConfiguration.WriteShellSettingsData("{\"model\":\"m\"}", filePath);
        Assert.Equal("{\"model\":\"m\"}", File.ReadAllText(filePath));
    }

    // MARK: - shell.json updates (F-27)

    [Fact]
    public void AnUpdateNeverRewritesAFileThatDoesNotDecode()
    {
        const string original = """{"model":"old","sarvamKey":"sk-sarvam","openaiApiKey":"sk-openai","voiceSeconds":"5"}""";
        var filePath = TemporarySettingsFile(original);

        var written = OpenClickyConfiguration.Update(filePath, settings => settings.Model = "new");

        Assert.False(written);
        Assert.Equal(original, File.ReadAllText(filePath));
        var reading = Assert.IsType<OpenClickyConfiguration.SettingsFileReading.Unreadable>(OpenClickyConfiguration.ReadSettingsFile(filePath));
        Assert.Equal("\"voiceSeconds\" has the wrong kind of value", reading.Reason);
    }

    [Fact]
    public void AnUpdateNeverRewritesAFileThatIsNotJson()
    {
        const string original = "{ model: oops";
        var filePath = TemporarySettingsFile(original);
        Assert.False(OpenClickyConfiguration.Update(filePath, settings => settings.Model = "new"));
        Assert.Equal(original, File.ReadAllText(filePath));
        var reading = Assert.IsType<OpenClickyConfiguration.SettingsFileReading.Unreadable>(OpenClickyConfiguration.ReadSettingsFile(filePath));
        Assert.Equal("it isn't valid json", reading.Reason);
    }

    [Fact]
    public void AnUpdateKeepsFieldsItDoesNotKnow()
    {
        var filePath = TemporarySettingsFile("""{"model":"old","sarvamKey":"sk-sarvam","futureSetting":{"depth":2},"language":"hi"}""");

        var written = OpenClickyConfiguration.Update(filePath, settings =>
        {
            settings.Model = "new";
            settings.Language = null;
        });

        Assert.True(written);
        var jsonObject = JsonObjectAt(filePath);
        Assert.Equal("new", (string?)jsonObject["model"]);
        Assert.Equal("sk-sarvam", (string?)jsonObject["sarvamKey"]);
        Assert.Equal(2, (int?)jsonObject["futureSetting"]?["depth"]);
        Assert.False(jsonObject.ContainsKey("language"));
        // Defaults the file never spelled out are not written into it.
        Assert.False(jsonObject.ContainsKey("voiceSeconds"));
    }

    [Fact]
    public void AFileWithOnlySomeFieldsReads()
    {
        var filePath = TemporarySettingsFile("""{"model":"m","sarvamKey":"sk-sarvam"}""");
        var settings = OpenClickyConfiguration.Load(filePath, NoEnvironment);
        Assert.Equal("m", settings.Model);
        Assert.Equal("sk-sarvam", settings.SarvamKey);
        Assert.Equal(5, settings.VoiceSeconds);
        Assert.Equal(["openclicky"], settings.CliCommand);
    }

    [Fact]
    public void AnEmptyFileReadsAsTheDefaults()
    {
        var filePath = TemporarySettingsFile("  \n");
        Assert.IsType<OpenClickyConfiguration.SettingsFileReading.Readable>(OpenClickyConfiguration.ReadSettingsFile(filePath));
    }

    [Fact]
    public void EnvironmentOverridesAreNeverWrittenToTheFile()
    {
        var filePath = TemporarySettingsFile("""{"workspace":"/tmp/w"}""");
        var environment = new Dictionary<string, string> { ["OPENCLICKY_MODEL"] = "local-model" };

        Assert.Equal("local-model", OpenClickyConfiguration.Load(filePath, environment).Model);
        Assert.True(OpenClickyConfiguration.Update(filePath, settings => settings.Language = "hi"));

        var jsonObject = JsonObjectAt(filePath);
        Assert.Equal("/tmp/w", (string?)jsonObject["workspace"]);
        Assert.False(jsonObject.ContainsKey("model"));
        Assert.Equal("hi", (string?)jsonObject["language"]);
    }

    /// <summary>A file from when the app had accounts still reads, and the next save drops those fields.</summary>
    [Fact]
    public void OldAccountFieldsReadAndAreDroppedOnSave()
    {
        var filePath = TemporarySettingsFile("""{"backendUrl":"https://old.example","token":"tok","refreshToken":"r","tokenExpiresAt":1,"accountEmail":"a@b.c","sarvamKey":"sk"}""");
        Assert.Equal("sk", OpenClickyConfiguration.Load(filePath, new Dictionary<string, string>()).SarvamKey);
        Assert.True(OpenClickyConfiguration.Update(filePath, settings => settings.Language = "hi"));

        var jsonObject = JsonObjectAt(filePath);
        foreach (var dropped in new[] { "backendUrl", "token", "refreshToken", "tokenExpiresAt", "accountEmail" }) Assert.False(jsonObject.ContainsKey(dropped));
        Assert.Equal("sk", (string?)jsonObject["sarvamKey"]);
    }

    [Fact]
    public void TheCliOverrideIsSplitOnSpaces()
    {
        var settings = OpenClickyConfiguration.Load(Path.Combine(temporaryDirectory, "missing.json"),
            new Dictionary<string, string> { ["OPENCLICKY_SHELL_CLI"] = "node C:\\oc\\agent\\dist\\cli.js" });
        Assert.Equal(["node", "C:\\oc\\agent\\dist\\cli.js"], settings.CliCommand);
    }

    [Fact]
    public void AnUpdateCreatesAMissingFile()
    {
        var filePath = Path.Combine(temporaryDirectory, "new", "shell.json");
        Assert.True(OpenClickyConfiguration.Update(filePath, settings => settings.Model = "tok"));
        Assert.Equal("tok", OpenClickyConfiguration.Load(filePath, NoEnvironment).Model);
    }

    [Fact]
    public void TheFileUsesTheMacsKeyNames()
    {
        var settings = new OpenClickyShellSettings { OpenaiApiKey = "o", XaiApiKey = "x", UseClaudeCodePlan = true };
        var jsonObject = JsonNode.Parse(settings.Encode())!.AsObject();
        Assert.Equal("o", (string?)jsonObject["openaiApiKey"]);
        Assert.Equal("x", (string?)jsonObject["xaiApiKey"]);
        Assert.True((bool?)jsonObject["useClaudeCodePlan"]);
        Assert.False(jsonObject.ContainsKey("anthropicApiKey")); // null is left out, as Swift's encoder does
    }

    [Fact]
    public void AppSkillsComeFromTheCheckoutTheCliRunsFrom()
    {
        var root = Path.Combine(temporaryDirectory, "repo");
        Directory.CreateDirectory(Path.Combine(root, "app-skills"));
        Directory.CreateDirectory(Path.Combine(root, "agent", "dist"));
        var settings = new OpenClickyShellSettings { CliCommand = ["node", Path.Combine(root, "agent", "dist", "cli.js")] };
        Assert.Equal(Path.Combine(root, "app-skills"), OpenClickyConfiguration.AppSkillsDirectoryFor(settings));
        settings.AppSkillsPath = Path.Combine(temporaryDirectory, "mine");
        Assert.Equal(Path.Combine(temporaryDirectory, "mine"), OpenClickyConfiguration.AppSkillsDirectoryFor(settings));
    }

    [Fact]
    public void TheCredentialFingerprintNamesWhatALiveSessionDependsOn()
    {
        var before = new OpenClickyShellSettings { OpenaiApiKey = "a" };
        var after = before.Clone();
        after.Model = "other";
        Assert.Equal(OpenClickyConfiguration.CredentialFingerprint(before), OpenClickyConfiguration.CredentialFingerprint(after));
        after.AnthropicApiKey = "ak";
        Assert.NotEqual(OpenClickyConfiguration.CredentialFingerprint(before), OpenClickyConfiguration.CredentialFingerprint(after));
        // A Gemini key or a fast voice pick can move realtime to another vendor.
        var geminiAdded = before.Clone();
        geminiAdded.GeminiApiKey = "g";
        Assert.NotEqual(OpenClickyConfiguration.CredentialFingerprint(before), OpenClickyConfiguration.CredentialFingerprint(geminiAdded));
        var providerPicked = before.Clone();
        providerPicked.RealtimeProvider = "gemini";
        Assert.NotEqual(OpenClickyConfiguration.CredentialFingerprint(before), OpenClickyConfiguration.CredentialFingerprint(providerPicked));
    }
}
