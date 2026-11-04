// A refused question, with the status and body exactly as they came. ClaudeAPI throws it for
// Anthropic on an own key.

using System.Text;

namespace OpenClicky.Core.Answers;

public sealed class AnswerHttpException : Exception
{
    public int Status { get; }
    public byte[] Body { get; }
    public string BodyText => Encoding.UTF8.GetString(Body);

    /// <summary>The status, as NSError's code was (what log lines print).</summary>
    public int Code => Status;

    public AnswerHttpException(int status, byte[] body) : base($"API Error ({status}): {Encoding.UTF8.GetString(body)}")
    {
        Status = status;
        Body = body;
        HResult = status;
    }

    public override bool Equals(object? obj) =>
        obj is AnswerHttpException other && other.Status == Status && other.Body.AsSpan().SequenceEqual(Body);

    public override int GetHashCode() => HashCode.Combine(Status, Body.Length);
}
