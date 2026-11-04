//
//  ClaudeLimitRings.cs
//  OpenClicky (Windows port of Plugins/CodingAgents/ClaudeLimitRings.swift)
//
//  Claude's plan limits for the Coding agents plugin: the figures `claude -p` reports with each
//  answer (PlanLimitStore). OpenClicky must not read Claude Code's sign-in or call Anthropic with
//  it: subscription tokens are not for other apps. So the rings only move when Clicky answers on
//  the Claude plan, and a window that has reset is left out because its figure is no longer true.
//

using OpenClicky.Core.Providers;

namespace OpenClicky.Core.Plugins.CodingAgents;

public sealed record ClaudeLimitRing(string Label, double Fraction, DateTimeOffset? ResetsAt);

public static class ClaudeLimitRings
{
    /// <summary>The window titles PlanLimitSnapshot.FromClaude writes, with what each ring says.</summary>
    private static readonly (string WindowTitle, string Label)[] LabelsByWindowTitle = [("5 hours", "5 h"), ("7 days", "7 d")];

    public static IReadOnlyList<ClaudeLimitRing> Rings(PlanLimitSnapshot? snapshot, DateTimeOffset now)
    {
        var rings = new List<ClaudeLimitRing>();
        foreach (var (windowTitle, label) in LabelsByWindowTitle)
        {
            var window = snapshot?.Windows.FirstOrDefault(candidate => candidate.Title == windowTitle);
            if (window is null || window.ResetsAt <= now) continue;
            rings.Add(new ClaudeLimitRing(label, window.UsedFraction, window.ResetsAt));
        }
        return rings;
    }

    /// <summary>"resets 2 h 10 m", "resets 35 m", "resets soon"; nothing without a date.</summary>
    public static string ResetText(DateTimeOffset? until, DateTimeOffset now)
    {
        if (until is not { } resetsAt) return "";
        var seconds = (int)Math.Floor((resetsAt - now).TotalSeconds);
        if (seconds < 60) return "resets soon";
        var hours = seconds / 3600;
        var minutes = seconds % 3600 / 60;
        return hours > 0 ? $"resets {hours} h {minutes} m" : $"resets {minutes} m";
    }
}
