// Ports AgentTool.swift: how agent tasks reach the openclicky tool. The tool ships beside the app
// (agent-tool\, by scripts\embed-agent-tool.ps1) but runs on Node.js. It uses this PC's Node when
// that is new enough, and otherwise downloads Node once, only when someone has agent tasks set up.
// A `cliCommand` set by hand in shell.json always wins.

using System.Diagnostics;
using System.Runtime.InteropServices;
using OpenClicky.Core.Configuration;
using OpenClicky.Core.Platform;
using OpenClicky.Core.Speech;

namespace OpenClicky.Core.Agent;

public static class AgentTool
{
    /// <summary>The value `cliCommand` has when nobody chose one: use the tool beside the app.</summary>
    public static readonly IReadOnlyList<string> UnconfiguredCommand = ["openclicky"];

    /// <summary>package.json's `engines`.</summary>
    public const int MinimumNodeMajor = 22;

    public const string NodeVersion = "22.23.4";

    public static string? BundledScript
    {
        get
        {
            var script = Path.Combine(AppContext.BaseDirectory, "agent-tool", "agent", "dist", "cli.js");
            return File.Exists(script) ? script : null;
        }
    }

    /// <summary>What to run: a hand-set command, else the bundled tool on the first Node that will do, else the unconfigured command, which still finds an `openclicky` someone linked onto their PATH.</summary>
    public static IReadOnlyList<string> Command(IReadOnlyList<string> configured, string? bundledScript, string? downloadedNode, string? systemNode)
    {
        if (!configured.SequenceEqual(UnconfiguredCommand) || bundledScript is null) return configured;
        return (downloadedNode ?? systemNode) is { } node ? [node, bundledScript] : configured;
    }

    /// <summary>True for "v22.1.0" and newer.</summary>
    public static bool IsNewEnough(string nodeVersion)
    {
        var major = nodeVersion.Trim().TrimStart('v').Split('.')[0];
        return int.TryParse(major, out var value) && value >= MinimumNodeMajor;
    }

    private static readonly Lazy<string?> FoundSystemNode = new(FindSystemNode);

    /// <summary>This PC's Node, if it is new enough. Looked up once per launch.</summary>
    public static string? SystemNode => FoundSystemNode.Value;

    private static string? FindSystemNode()
    {
        OpenClickyConfiguration.CliProcessEnvironment.TryGetValue("PATH", out var path);
        var node = (path ?? "").Split(Path.PathSeparator, StringSplitOptions.RemoveEmptyEntries)
            .Select(folder => Path.Combine(folder, "node.exe")).FirstOrDefault(File.Exists);
        if (node is null) return null;
        try
        {
            using var process = Process.Start(new ProcessStartInfo(node, "--version")
            {
                RedirectStandardOutput = true, RedirectStandardError = true, UseShellExecute = false, CreateNoWindow = true,
            });
            if (process is null) return null;
            var version = process.StandardOutput.ReadToEnd();
            process.WaitForExit();
            return process.ExitCode == 0 && IsNewEnough(version) ? node : null;
        }
        catch (Exception error) when (error is IOException or InvalidOperationException or System.ComponentModel.Win32Exception)
        {
            return null;
        }
    }

    // MARK: Node, downloaded

    private static string NodePlatform => RuntimeInformation.ProcessArchitecture == Architecture.Arm64 ? "win-arm64" : "win-x64";

    private static ModelDownload NodeDownload => new(
        new Uri($"https://nodejs.org/dist/v{NodeVersion}/node-v{NodeVersion}-{NodePlatform}.zip"),
        RuntimeInformation.ProcessArchitecture == Architecture.Arm64
            ? "a8b8cd79cbbb3062435f449591d98dd63730bbbf30ce2d7cc3a6376c236cb111"
            : "cbc74b5e0982c9dbb41525fd8fb5dcd32fbee237863f7829072f4639a1ce5f20",
        RuntimeInformation.ProcessArchitecture == Architecture.Arm64 ? 31_332_011 : 35_604_229);

    private static string NodeParent => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "OpenClicky", "Node");
    private static string NodeFolder => Path.Combine(NodeParent, $"node-v{NodeVersion}-{NodePlatform}");
    private static string NodeBinary => Path.Combine(NodeFolder, "node.exe");

    public static string? DownloadedNode => File.Exists(NodeBinary) ? NodeBinary : null;

    /// <summary>Whether downloading Node is what stands between this PC and running agent tasks.</summary>
    public static bool NeedsNodeDownload =>
        OpenClickyConfiguration.Settings.CliCommand.SequenceEqual(UnconfiguredCommand) && BundledScript is not null
        && DownloadedNode is null && SystemNode is null;

    private static int isDownloading;

    /// <summary>Downloads Node if it is needed. Only node.exe is kept; the archive also holds npm and headers, which nothing here uses.</summary>
    public static async Task DownloadNodeIfNeededAsync(IProcessRunner unpacker)
    {
        if (!NeedsNodeDownload || Interlocked.Exchange(ref isDownloading, 1) == 1) return;
        try
        {
            await NodeDownload.InstallAsync(NodeParent, _ => { }, unpacker, CancellationToken.None).ConfigureAwait(false);
            foreach (var folder in Directory.GetDirectories(NodeFolder)) Directory.Delete(folder, recursive: true);
            foreach (var file in Directory.GetFiles(NodeFolder).Where(file => !file.Equals(NodeBinary, StringComparison.OrdinalIgnoreCase))) File.Delete(file);
            AppLog.Write($"agent: downloaded node {NodeVersion}");
        }
        catch (Exception error) when (error is not OutOfMemoryException)
        {
            AppLog.Write($"agent: couldn't download node ({error.Message})");
        }
        finally
        {
            Volatile.Write(ref isDownloading, 0);
        }
    }
}
