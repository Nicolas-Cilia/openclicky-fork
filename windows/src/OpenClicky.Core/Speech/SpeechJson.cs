// The small JSON readers the speech sockets share.

using System.Text.Json;
using System.Text.Json.Nodes;

namespace OpenClicky.Core.Speech;

internal static class SpeechJson
{
    public static readonly JsonSerializerOptions CompactOptions = new() { Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping };

    public static string? String(JsonNode? node) =>
        node is JsonValue value && value.TryGetValue<string>(out var text) ? text : null;

    public static bool? Bool(JsonNode? node) =>
        node is JsonValue value && value.TryGetValue<bool>(out var flag) ? flag : null;

    public static int? Int(JsonNode? node)
    {
        if (node is not JsonValue value) return null;
        if (value.TryGetValue<int>(out var number)) return number;
        if (value.TryGetValue<double>(out var real) && double.IsFinite(real)) return (int)real;
        return null;
    }

    /// <summary>A number the model sent as a number or as a numeric string.</summary>
    public static double? Number(JsonNode? node)
    {
        if (node is not JsonValue value) return null;
        if (value.TryGetValue<double>(out var number)) return number;
        if (value.TryGetValue<string>(out var text) && double.TryParse(text.Trim(), System.Globalization.NumberStyles.Float, System.Globalization.CultureInfo.InvariantCulture, out var parsed)) return parsed;
        return null;
    }

    /// <summary>A query value escaped as URLComponents escapes it (RFC 3986 unreserved kept).</summary>
    public static string QueryEscape(string value) => Uri.EscapeDataString(value);
}
