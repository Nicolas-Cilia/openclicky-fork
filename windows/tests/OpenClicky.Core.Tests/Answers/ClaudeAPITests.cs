// Ports ClaudeToolStreamTests.swift (the tool-call parsing; the MacAction schema checks belong to
// the Actions port), and adds the request/stream behaviour the Mac covered by hand, through
// HttpClients.UseHandler: an own key goes to Anthropic with x-api-key, text arrives as the whole answer so far, an error event or a refusal is thrown, and another answer
// source gets the question through its IAnswerProvider.

using System.Net;
using System.Text;
using System.Text.Json.Nodes;
using OpenClicky.Core.Answers;
using OpenClicky.Core.Providers;
using OpenClicky.Core.Tests.Providers;

namespace OpenClicky.Core.Tests.Answers;

public class ClaudeToolStreamTests
{
    [Fact]
    public void ParsesAToolCallStreamedInPieces()
    {
        string[] lines =
        [
            """data: {"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"toolu_1","name":"create_folder","input":{}}}""",
            """data: {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\"name\": \"Launch"}}""",
            """data: {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":" Ideas\", \"location\": \"desktop\"}"}}""",
            """data: {"type":"content_block_stop","index":1}""",
        ];
        Assert.Equal([new ClaudeToolCall("toolu_1", "create_folder", new Dictionary<string, string> { ["name"] = "Launch Ideas", ["location"] = "desktop" })],
                     ClaudeAPI.ParseToolCalls(lines));
    }

    [Fact]
    public void NumbersBecomeStrings()
    {
        string[] lines =
        [
            """data: {"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"t","name":"set_volume","input":{}}}""",
            """data: {"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\"level\": 30}"}}""",
            """data: {"type":"content_block_stop","index":0}""",
        ];
        Assert.Equal("30", ClaudeAPI.ParseToolCalls(lines)[0].Arguments["level"]);
    }

    [Fact]
    public void InvalidJsonYieldsNoCall()
    {
        string[] lines =
        [
            """data: {"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"t","name":"open_app","input":{}}}""",
            """data: {"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\"name\": "}}""",
            """data: {"type":"content_block_stop","index":0}""",
        ];
        Assert.Empty(ClaudeAPI.ParseToolCalls(lines));
    }

    [Fact]
    public void AToolWithoutInputHasNoArguments()
    {
        string[] lines =
        [
            """data: {"type":"content_block_start","index":2,"content_block":{"type":"tool_use","id":"t2","name":"media_control","input":{}}}""",
            """data: {"type":"content_block_stop","index":2}""",
        ];
        Assert.Equal([new ClaudeToolCall("t2", "media_control", new Dictionary<string, string>())], ClaudeAPI.ParseToolCalls(lines));
    }

    [Fact]
    public void AnAnthropicToolBecomesAnAnswerTool()
    {
        var tool = ClaudeAPI.AnswerTool(WriteInPlace.AnthropicToolDefinition())!;
        Assert.Equal("write_in_place", tool.Name);
        Assert.StartsWith("Replace the text", tool.Description);
        Assert.Equal("object", JsonNode.Parse(tool.InputSchemaJson)!["type"]!.GetValue<string>());
        var bare = ClaudeAPI.AnswerTool(new JsonObject { ["name"] = "noop" })!;
        Assert.Equal("", bare.Description);
        Assert.Equal("""{"type":"object","properties":{}}""", bare.InputSchemaJson);
        Assert.Null(ClaudeAPI.AnswerTool(new JsonObject { ["description"] = "no name" }));
    }

    [Fact]
    public void ImageTypesAreReadFromTheirFirstBytes()
    {
        Assert.Equal("image/png", ClaudeAPI.DetectImageMediaType([0x89, 0x50, 0x4E, 0x47, 0x0D]));
        Assert.Equal("image/jpeg", ClaudeAPI.DetectImageMediaType([0xFF, 0xD8, 0xFF, 0xE0]));
        Assert.Equal("image/jpeg", ClaudeAPI.DetectImageMediaType([0x89]));
    }
}

[Collection("HttpClients")]
public class ClaudeApiRequestTests : IDisposable
{
    private sealed class RecordingHandler
    {
        public readonly List<(HttpRequestMessage Request, string Body)> Requests = [];
        public Func<HttpRequestMessage, int, HttpResponseMessage> Answer = (_, _) => new HttpResponseMessage(HttpStatusCode.OK);

        public DelegatingTestHandler Handler => new((request, _) =>
        {
            lock (Requests)
            {
                Requests.Add((request, request.Content?.BodyText() ?? ""));
                return Task.FromResult(Answer(request, Requests.Count));
            }
        });
    }

    private readonly RecordingHandler recorder = new();

    public ClaudeApiRequestTests() => HttpClients.UseHandler(recorder.Handler);

    public void Dispose() => HttpClients.Reset();

    private static readonly ProviderCredentials OwnKey = new(null, "sk-ant-test", null);

    private static HttpResponseMessage Sse(params string[] events) => new(HttpStatusCode.OK)
    {
        Content = new StringContent(string.Concat(events.Select(line => line + "\n\n")), Encoding.UTF8, "text/event-stream"),
    };

    private static readonly string[] AnswerEvents =
    [
        """data: {"type":"message_start","message":{"id":"m"}}""",
        """data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"[POINT:none] hi"}}""",
        """data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":" there."}}""",
        """data: {"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"toolu_9","name":"set_volume","input":{}}}""",
        """data: {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\"level\":20}"}}""",
        """data: {"type":"content_block_stop","index":1}""",
        """data: {"type":"message_delta","delta":{"stop_reason":"tool_use"}}""",
        """data: {"type":"message_stop"}""",
    ];

    private static ClaudeAPI Api(ProviderCredentials credentials, AnswerProviderMaker? maker = null) =>
        new("claude-test-model", () => credentials, makeAnswerProvider: maker, warmUpConnection: false);

    private static readonly (byte[] Data, string Label)[] OneImage = [([0x89, 0x50, 0x4E, 0x47, 0x01], "screen 1 (image dimensions: 10x10 pixels)")];

    [Fact]
    public async Task AnOwnKeyStreamsFromAnthropicDirectly()
    {
        recorder.Answer = (_, _) => Sse(AnswerEvents);
        var chunks = new List<string>();
        var tools = new List<JsonObject> { WriteInPlace.AnthropicToolDefinition() };
        var result = await Api(OwnKey).AnalyzeImageStreamingAsync(OneImage, "system words", [("earlier", "reply")], "what is this?", tools, chunks.Add);

        Assert.Equal("[POINT:none] hi there.", result.Text);
        Assert.Equal(["[POINT:none] hi", "[POINT:none] hi there."], chunks);
        Assert.Equal([new ClaudeToolCall("toolu_9", "set_volume", new Dictionary<string, string> { ["level"] = "20" })], result.ToolCalls);

        var (request, bodyText) = Assert.Single(recorder.Requests);
        Assert.Equal(DirectProviderRequests.AnthropicMessagesUrl, request.RequestUri!.AbsoluteUri);
        Assert.Equal("sk-ant-test", request.HeaderValue("x-api-key"));
        Assert.Equal("2023-06-01", request.HeaderValue("anthropic-version"));
        Assert.Null(request.HeaderValue("Authorization"));
        var body = JsonNode.Parse(bodyText)!;
        Assert.Equal("claude-test-model", body["model"]!.GetValue<string>());
        Assert.Equal(1024, body["max_tokens"]!.GetValue<int>());
        Assert.True(body["stream"]!.GetValue<bool>());
        Assert.Equal("system words", body["system"]!.GetValue<string>());
        Assert.Equal("write_in_place", body["tools"]![0]!["name"]!.GetValue<string>());
        var messages = body["messages"]!.AsArray();
        Assert.Equal(3, messages.Count);
        Assert.Equal("earlier", messages[0]!["content"]!.GetValue<string>());
        Assert.Equal("assistant", messages[1]!["role"]!.GetValue<string>());
        var blocks = messages[2]!["content"]!.AsArray();
        Assert.Equal("image/png", blocks[0]!["source"]!["media_type"]!.GetValue<string>());
        Assert.Equal(Convert.ToBase64String(OneImage[0].Data), blocks[0]!["source"]!["data"]!.GetValue<string>());
        Assert.Equal(OneImage[0].Label, blocks[1]!["text"]!.GetValue<string>());
        Assert.Equal("what is this?", blocks[2]!["text"]!.GetValue<string>());
    }

    [Fact]
    public async Task NoToolsMeansNoToolsField()
    {
        recorder.Answer = (_, _) => Sse(AnswerEvents);
        await Api(OwnKey).AnalyzeImageStreamingAsync(OneImage, "s", null, "q", null, _ => { });
        Assert.False(JsonNode.Parse(recorder.Requests[0].Body)!.AsObject().ContainsKey("tools"));
    }

    [Fact]
    public async Task ARefusalIsThrownWithItsStatusAndBody()
    {
        recorder.Answer = (_, _) => new HttpResponseMessage(HttpStatusCode.PaymentRequired) { Content = new StringContent("{\"error\":\"limit\"}\n") };
        var error = await Assert.ThrowsAsync<AnswerHttpException>(() => Api(OwnKey).AnalyzeImageStreamingAsync(OneImage, "s", null, "q", null, _ => { }));
        Assert.Equal(402, error.Status);
        Assert.Equal("{\"error\":\"limit\"}", error.BodyText);
    }

    [Fact]
    public async Task AnErrorEventMidStreamIsAFailure()
    {
        recorder.Answer = (_, _) => Sse(
            """data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"half"}}""",
            """data: {"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}""");
        var error = await Assert.ThrowsAsync<ClaudeApiException>(() => Api(OwnKey).AnalyzeImageStreamingAsync(OneImage, "s", null, "q", null, _ => { }));
        Assert.Equal(ClaudeAPI.MidStreamErrorCode, error.Code);
        Assert.Contains("overloaded_error", error.Message);
    }

    [Fact]
    public async Task NothingSetUpIsTheRoutesSentence()
    {
        var error = await Assert.ThrowsAsync<ProviderRouteUnavailableException>(() =>
            Api(new ProviderCredentials(null, null)).AnalyzeImageStreamingAsync(OneImage, "s", null, "q", null, _ => { }));
        Assert.Equal(ProviderRouter.NeedsAnthropicKeySentence, error.Sentence);
        Assert.Empty(recorder.Requests);
    }

    [Fact]
    public async Task AnotherSourceAnswersThroughItsProvider()
    {
        var fake = new FakeAnswerProvider(["Red", ", plainly."], [new ClaudeToolCall("c", "open_app", new Dictionary<string, string> { ["name"] = "Edge" })]);
        AnswerSource? madeFor = null;
        var api = Api(new ProviderCredentials(null, null, geminiKey: "AIza"), maker: (source, _, _) =>
        {
            madeFor = source;
            return Task.FromResult<IAnswerProvider>(fake);
        });
        var chunks = new List<string>();
        var tools = QuickActionToolDefinitions.All();
        var result = await api.AnalyzeImageStreamingAsync(OneImage, "system", [("u", "a")], "q", tools, chunks.Add);

        Assert.Equal(AnswerSource.Gemini, madeFor);
        Assert.Equal("Red, plainly.", result.Text);
        Assert.Equal(["Red", "Red, plainly."], chunks);
        Assert.Single(result.ToolCalls);
        Assert.Empty(recorder.Requests);
        var request = fake.Requests.Single();
        Assert.Equal("system", request.SystemPrompt);
        Assert.Equal([new AnswerRequest.Turn("u", "a")], request.History);
        Assert.Equal("image/png", request.Images[0].MediaType);
        Assert.Equal(1024, request.MaxTokens);
        Assert.Equal(tools.Select(tool => tool["name"]!.GetValue<string>()), request.Tools.Select(tool => tool.Name));
    }

    [Fact]
    public async Task TheShortAnswerIsTheFirstTextBlock()
    {
        recorder.Answer = (_, _) => new HttpResponseMessage(HttpStatusCode.OK)
        {
            Content = new StringContent("""{"content":[{"type":"text","text":"[POINT:12,34:Save]"}],"stop_reason":"end_turn"}"""),
        };
        var reply = await Api(OwnKey).AnalyzeImageAsync(OneImage, "locate", null, "where?");
        Assert.Equal("[POINT:12,34:Save]", reply.Text);
        var body = JsonNode.Parse(recorder.Requests.Single().Body)!.AsObject();
        Assert.Equal(256, body["max_tokens"]!.GetValue<int>());
        Assert.False(body.ContainsKey("stream"));
    }

    [Fact]
    public async Task AShortAnswerWithoutTextIsAnInvalidResponse()
    {
        recorder.Answer = (_, _) => new HttpResponseMessage(HttpStatusCode.OK) { Content = new StringContent("""{"content":[]}""") };
        var error = await Assert.ThrowsAsync<ClaudeApiException>(() => Api(OwnKey).AnalyzeImageAsync(OneImage, "s", null, "q"));
        Assert.Equal(-1, error.Code);
    }

    [Fact]
    public async Task TheShortAnswerGoesToAnotherSourcesProviderWithRoomToThink()
    {
        var fake = new FakeAnswerProvider(["[POINT:1,2]"], []);
        var api = Api(new ProviderCredentials("sk-openai", null), maker: (_, _, _) => Task.FromResult<IAnswerProvider>(fake));
        var reply = await api.AnalyzeImageAsync(OneImage, "s", null, "q");
        Assert.Equal("[POINT:1,2]", reply.Text);
        Assert.Equal(1024, fake.Requests.Single().MaxTokens);
        Assert.Empty(fake.Requests.Single().Tools);
    }

    [Fact]
    public async Task TheWarmUpIsAHeadToTheHostsRoot()
    {
        ClaudeAPI.ResetTlsWarmup();
        _ = new ClaudeAPI(currentCredentials: () => OwnKey);
        for (var attempt = 0; attempt < 100 && recorder.Requests.Count == 0; attempt++) await Task.Delay(20);
        var (request, _) = Assert.Single(recorder.Requests);
        Assert.Equal(HttpMethod.Head, request.Method);
        Assert.Equal("https://api.anthropic.com/", request.RequestUri!.AbsoluteUri);
        // Once per app run.
        _ = new ClaudeAPI(currentCredentials: () => OwnKey);
        await Task.Delay(100);
        Assert.Single(recorder.Requests);
    }
}

/// <summary>An answer provider that hands back canned pieces and records each request.</summary>
internal sealed class FakeAnswerProvider(string[] pieces, ClaudeToolCall[] toolCalls) : IAnswerProvider
{
    public readonly List<AnswerRequest> Requests = [];

    public Task<AnswerResult> AnswerAsync(AnswerRequest request, Action<string> onTextChunk, CancellationToken cancellationToken = default)
    {
        Requests.Add(request);
        foreach (var piece in pieces) onTextChunk(piece);
        return Task.FromResult(new AnswerResult(string.Concat(pieces), toolCalls));
    }
}
