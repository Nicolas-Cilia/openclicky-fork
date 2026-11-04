//
//  ClaudeAPI.swift
//  Claude API Implementation with streaming support
//

import Foundation

/// Anthropic refused a question, with the status and body exactly as they came.
nonisolated struct AnswerHTTPError: LocalizedError, CustomNSError, Equatable {
    let status: Int
    let body: Data

    var bodyText: String { String(decoding: body, as: UTF8.self) }
    var errorDescription: String? { "API Error (\(status)): \(bodyText)" }

    // Bridged to NSError with the status as its code, so log lines that print an error's domain
    // and code still show the status.
    static var errorDomain: String { "OpenClickyAnswerHTTP" }
    var errorCode: Int { status }
    var errorUserInfo: [String: Any] { [NSLocalizedDescriptionKey: errorDescription ?? ""] }
}

/// Claude API helper with streaming for progressive text display.
class ClaudeAPI {
    private static let tlsWarmupLock = NSLock()
    private static var hasStartedTLSWarmup = false

    var model: String

    /// The NSError code (domain "ClaudeAPI") for an `error` event inside a stream that had started.
    static let midStreamErrorCode = -1002
    private let session: URLSession

    init(model: String = "claude-sonnet-4-6") {
        self.model = model

        // Use .default instead of .ephemeral so TLS session tickets are cached.
        // Ephemeral sessions do a full TLS handshake on every request, which causes
        // transient -1200 (errSSLPeerHandshakeFail) errors with large image payloads.
        // Disable URL/cookie caching to avoid storing responses or credentials on disk.
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 300
        config.waitsForConnectivity = true
        config.urlCache = nil
        config.httpCookieStorage = nil
        self.session = URLSession(configuration: config)

        // Fire a lightweight HEAD request in the background to pre-establish the TLS
        // connection. This caches the TLS session ticket so the first real API call
        // (which carries a large image payload) doesn't need a cold TLS handshake.
        warmUpTLSConnectionIfNeeded()
    }

    /// The person's own Anthropic key goes straight to Anthropic. Every other source answers through
    /// its AnswerProvider, before a request is built.
    private func makeAPIRequest() throws -> URLRequest {
        var request: URLRequest
        switch ProviderRouter.current(for: .claude) {
        case .anthropicDirect:
            guard let anthropicKey = ProviderRouter.currentCredentials().anthropicKey else {
                throw ProviderRouteUnavailable(capability: .claude, sentence: ProviderRouter.needsAnthropicKeySentence)
            }
            request = DirectProviderRequests.anthropicMessages(key: anthropicKey)
        case .unavailable(let sentence):
            throw ProviderRouteUnavailable(capability: .claude, sentence: sentence)
        case .answerProvider(let source):
            // analyzeImageStreaming hands these to an AnswerProvider before building a request.
            throw ProviderRouteUnavailable(capability: .claude, sentence: "\(source.displayName) answers through its own provider")
        case .openAIDirect:
            throw ProviderRouteUnavailable(capability: .claude, sentence: ProviderRouter.needsAnthropicKeySentence)
        }
        request.timeoutInterval = 120
        return request
    }

    /// Detects the MIME type of image data by inspecting the first bytes.
    /// Screen captures from ScreenCaptureKit are JPEG, but pasted images from the
    /// clipboard are PNG. The API rejects requests where the declared media_type
    /// doesn't match the actual image format.
    private func detectImageMediaType(for imageData: Data) -> String {
        // PNG files start with the 8-byte signature: 89 50 4E 47 0D 0A 1A 0A
        if imageData.count >= 4 {
            let pngSignature: [UInt8] = [0x89, 0x50, 0x4E, 0x47]
            let firstFourBytes = [UInt8](imageData.prefix(4))
            if firstFourBytes == pngSignature {
                return "image/png"
            }
        }
        // Default to JPEG — screen captures use JPEG compression
        return "image/jpeg"
    }

    /// Sends a no-op HEAD request to the API host to establish and cache a TLS session.
    /// Failures are silently ignored — this is purely an optimization.
    private func warmUpTLSConnectionIfNeeded() {
        Self.tlsWarmupLock.lock()
        let shouldStartTLSWarmup = !Self.hasStartedTLSWarmup
        if shouldStartTLSWarmup {
            Self.hasStartedTLSWarmup = true
        }
        Self.tlsWarmupLock.unlock()

        guard shouldStartTLSWarmup else { return }

        // Only an own Anthropic key talks to Anthropic from here; the other sources warm nothing.
        guard ProviderRouter.currentCredentials().anthropicKey != nil else { return }
        let warmupTarget = URL(string: DirectProviderRequests.anthropicMessagesURL)!
        guard var warmupURLComponents = URLComponents(url: warmupTarget, resolvingAgainstBaseURL: false) else {
            return
        }

        // The TLS session ticket is host-scoped, so warming the root host is enough.
        // Hitting the host instead of `/v1/messages` avoids extra endpoint-specific noise.
        warmupURLComponents.path = "/"
        warmupURLComponents.query = nil
        warmupURLComponents.fragment = nil

        guard let warmupURL = warmupURLComponents.url else {
            return
        }

        var warmupRequest = URLRequest(url: warmupURL)
        warmupRequest.httpMethod = "HEAD"
        warmupRequest.timeoutInterval = 10
        session.dataTask(with: warmupRequest) { _, _, _ in
            // Response doesn't matter — the TLS handshake is the goal
        }.resume()
    }

    /// Send a vision request to Claude with streaming.
    /// Calls `onTextChunk` on the main actor each time new text arrives so the UI updates progressively.
    /// Returns the full accumulated text and total duration when the stream completes.
    func analyzeImageStreaming(
        images: [(data: Data, label: String)],
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)] = [],
        userPrompt: String,
        tools: [[String: Any]] = [],
        onTextChunk: @MainActor @Sendable (String) -> Void
    ) async throws -> (text: String, toolCalls: [ClaudeToolCall], duration: TimeInterval) {
        let startTime = Date()

        // Another source answers (an OpenAI-compatible key, Gemini, a Claude Code or Codex plan):
        // the same question goes to its AnswerProvider, and its text streams back the same way.
        if case .answerProvider(let source) = ProviderRouter.current(for: .claude) {
            let result = try await answerThroughProvider(
                source: source, images: images, systemPrompt: systemPrompt, conversationHistory: conversationHistory,
                userPrompt: userPrompt, tools: tools, maxTokens: 1024, onTextChunk: onTextChunk)
            return (text: result.text, toolCalls: result.toolCalls, duration: Date().timeIntervalSince(startTime))
        }

        var request = try makeAPIRequest()

        // Build messages array
        var messages: [[String: Any]] = []

        for (userPlaceholder, assistantResponse) in conversationHistory {
            messages.append(["role": "user", "content": userPlaceholder])
            messages.append(["role": "assistant", "content": assistantResponse])
        }

        // Build current message with all labeled images + prompt
        var contentBlocks: [[String: Any]] = []
        for image in images {
            contentBlocks.append([
                "type": "image",
                "source": [
                    "type": "base64",
                    "media_type": detectImageMediaType(for: image.data),
                    "data": image.data.base64EncodedString()
                ]
            ])
            contentBlocks.append([
                "type": "text",
                "text": image.label
            ])
        }
        contentBlocks.append([
            "type": "text",
            "text": userPrompt
        ])
        messages.append(["role": "user", "content": contentBlocks])

        var body: [String: Any] = [
            "model": model,
            "max_tokens": 1024,
            "stream": true,
            "system": systemPrompt,
            "messages": messages
        ]
        if !tools.isEmpty { body["tools"] = tools }

        let bodyData = try JSONSerialization.data(withJSONObject: body)
        request.httpBody = bodyData
        let payloadMB = Double(bodyData.count) / 1_048_576.0
        print("🌐 Claude streaming request: \(String(format: "%.1f", payloadMB))MB, \(images.count) image(s)")

        // Use bytes streaming for SSE (Server-Sent Events).
        let (byteStream, response) = try await session.bytes(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(
                domain: "ClaudeAPI",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Invalid HTTP response"]
            )
        }
        // If non-2xx status, read the full body as error text
        guard (200...299).contains(httpResponse.statusCode) else {
            var errorBodyChunks: [String] = []
            for try await line in byteStream.lines {
                errorBodyChunks.append(line)
            }
            throw AnswerHTTPError(status: httpResponse.statusCode, body: Data(errorBodyChunks.joined(separator: "\n").utf8))
        }

        // Parse SSE stream — each event is "data: {json}\n\n"
        var accumulatedResponseText = ""
        var sseLines: [String] = []

        for try await line in byteStream.lines {
            sseLines.append(line)
            // SSE lines look like: "data: {...}"
            guard line.hasPrefix("data: ") else { continue }
            let jsonString = String(line.dropFirst(6)) // Drop "data: " prefix

            // End of stream marker
            guard jsonString != "[DONE]" else { break }

            guard let jsonData = jsonString.data(using: .utf8),
                  let eventPayload = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                  let eventType = eventPayload["type"] as? String else {
                continue
            }

            // Anthropic reports a failure after the 200 (overloaded, a dropped upstream) as an
            // `error` event; ignored, it ended the answer in silence as if it were complete.
            if let streamFailure = Self.streamFailure(fromEvent: eventPayload) {
                AppLog.append("claude: stream error after \(accumulatedResponseText.count) chars: \(streamFailure.localizedDescription)")
                throw streamFailure
            }
            // A cut-off answer is still spoken as it is; the log says why it ended early.
            if Self.stopReason(fromEvent: eventPayload) == "max_tokens" {
                AppLog.append("claude: answer cut off at max_tokens (\(accumulatedResponseText.count) chars)")
            }

            // We care about content_block_delta events that contain text chunks
            if eventType == "content_block_delta",
               let delta = eventPayload["delta"] as? [String: Any],
               let deltaType = delta["type"] as? String,
               deltaType == "text_delta",
               let textChunk = delta["text"] as? String {
                accumulatedResponseText += textChunk
                // Send the accumulated text so far to the UI for progressive rendering
                let currentAccumulatedText = accumulatedResponseText
                await onTextChunk(currentAccumulatedText)
            }
        }

        let duration = Date().timeIntervalSince(startTime)
        return (text: accumulatedResponseText, toolCalls: Self.parseToolCalls(fromSSELines: sseLines), duration: duration)
    }

    /// The same question asked of another source's AnswerProvider (an OpenAI-compatible key,
    /// Gemini, a Claude Code or Codex plan). The pieces come through a stream this call reads to the
    /// end, in order; each is handed on as the whole answer so far, like the Anthropic path.
    /// Cancelling the question cancels the provider (a CLI process is ended).
    /// Whether any of an answer has reached the voice: past that, starting again would repeat it.
    @MainActor private final class AnswerProgress {
        var hasStarted = false
    }

    /// Asks `source`. If it refuses because the plan has run out and nothing has been said yet, the
    /// backup plan answers the same question, once. Said already: the refusal stands, and the backup
    /// takes the next question.
    private func answerThroughProvider(
        source: AnswerSource,
        images: [(data: Data, label: String)],
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)],
        userPrompt: String,
        tools: [[String: Any]],
        maxTokens: Int,
        onTextChunk: @MainActor @Sendable (String) -> Void
    ) async throws -> AnswerResult {
        let progress = AnswerProgress()
        do {
            return try await askProvider(
                source: source, images: images, systemPrompt: systemPrompt, conversationHistory: conversationHistory,
                userPrompt: userPrompt, tools: tools, maxTokens: maxTokens, progress: progress, onTextChunk: onTextChunk)
        } catch let refusal as AnswerProviderError where refusal.isPlanLimit {
            await PlanLimitStore.shared.noteLimitHit(source)
            guard !progress.hasStarted, let backup = ProviderRouter.currentCredentials().activeAnswerSource,
                  backup != source, backup == .claudeCodePlan || backup == .codexPlan else { throw refusal }
            OpenClickyConfiguration.showNotice?("\(source.shortName) hit its limit. \(backup.shortName) is answering for now.")
            do {
                return try await askProvider(
                    source: backup, images: images, systemPrompt: systemPrompt, conversationHistory: conversationHistory,
                    userPrompt: userPrompt, tools: tools, maxTokens: maxTokens, progress: progress, onTextChunk: onTextChunk)
            } catch let secondRefusal as AnswerProviderError where secondRefusal.isPlanLimit {
                await PlanLimitStore.shared.noteLimitHit(backup)
                throw secondRefusal
            }
        }
    }

    private func askProvider(
        source: AnswerSource,
        images: [(data: Data, label: String)],
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)],
        userPrompt: String,
        tools: [[String: Any]],
        maxTokens: Int,
        progress: AnswerProgress,
        onTextChunk: @MainActor @Sendable (String) -> Void
    ) async throws -> AnswerResult {
        let provider = try await AnswerProviderFactory.make(for: source, credentials: ProviderRouter.currentCredentials(),
                                                      modelOverrides: OpenClickyConfiguration.settings.answerModels ?? [:])
        var answerRequest = AnswerRequest(
            images: images.map { AnswerRequest.Image(data: $0.data, label: $0.label, mediaType: detectImageMediaType(for: $0.data)) },
            systemPrompt: systemPrompt,
            history: conversationHistory.map { AnswerRequest.Turn(user: $0.userPlaceholder, assistant: $0.assistantResponse) },
            userPrompt: userPrompt,
            tools: tools.compactMap(Self.answerTool(fromAnthropicTool:)))
        answerRequest.maxTokens = maxTokens
        let (pieces, piecesContinuation) = AsyncStream<String>.makeStream()
        let answerTask = Task<AnswerResult, Error> {
            defer { piecesContinuation.finish() }
            return try await provider.answer(answerRequest) { piecesContinuation.yield($0) }
        }
        let result = try await withTaskCancellationHandler {
            var answerSoFar = ""
            for await piece in pieces {
                answerSoFar += piece
                progress.hasStarted = true
                await onTextChunk(answerSoFar)
            }
            return try await answerTask.value
        } onCancel: {
            answerTask.cancel()
        }
        AppLog.append("answer: \(source.displayName) answered (\(result.text.count) chars, \(result.toolCalls.count) tool calls)")
        return result
    }

    /// Non-streaming request for short answers nobody watches arrive (screen grounding). Another
    /// answer source gets the question through its AnswerProvider, as the streaming call does; it
    /// used to throw here, so grounding silently never ran on those routes.
    func analyzeImage(
        images: [(data: Data, label: String)],
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)] = [],
        userPrompt: String
    ) async throws -> (text: String, duration: TimeInterval) {
        let startTime = Date()

        if case .answerProvider(let source) = ProviderRouter.current(for: .claude) {
            let result = try await answerThroughProvider(
                source: source, images: images, systemPrompt: systemPrompt, conversationHistory: conversationHistory,
                // Not the 256 Anthropic gets below: a reasoning model (a Gemini 3, an OpenAI
                // reasoning model) spends part of its limit thinking before the short answer.
                userPrompt: userPrompt, tools: [], maxTokens: 1024, onTextChunk: { _ in })
            return (text: result.text, duration: Date().timeIntervalSince(startTime))
        }

        var request = try makeAPIRequest()

        var messages: [[String: Any]] = []
        for (userPlaceholder, assistantResponse) in conversationHistory {
            messages.append(["role": "user", "content": userPlaceholder])
            messages.append(["role": "assistant", "content": assistantResponse])
        }

        // Build current message with all labeled images + prompt
        var contentBlocks: [[String: Any]] = []
        for image in images {
            contentBlocks.append([
                "type": "image",
                "source": [
                    "type": "base64",
                    "media_type": detectImageMediaType(for: image.data),
                    "data": image.data.base64EncodedString()
                ]
            ])
            contentBlocks.append([
                "type": "text",
                "text": image.label
            ])
        }
        contentBlocks.append([
            "type": "text",
            "text": userPrompt
        ])
        messages.append(["role": "user", "content": contentBlocks])

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 256,
            "system": systemPrompt,
            "messages": messages
        ]

        let bodyData = try JSONSerialization.data(withJSONObject: body)
        request.httpBody = bodyData
        let payloadMB = Double(bodyData.count) / 1_048_576.0
        print("🌐 Claude request: \(String(format: "%.1f", payloadMB))MB, \(images.count) image(s)")

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(
                domain: "ClaudeAPI",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Invalid HTTP response"]
            )
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            throw AnswerHTTPError(status: httpResponse.statusCode, body: data)
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let content = json?["content"] as? [[String: Any]],
              let textBlock = content.first(where: { ($0["type"] as? String) == "text" }),
              let text = textBlock["text"] as? String else {
            throw NSError(
                domain: "ClaudeAPI",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Invalid response format"]
            )
        }

        let duration = Date().timeIntervalSince(startTime)
        return (text: text, duration: duration)
    }
}

extension ClaudeAPI {
    /// An Anthropic tool definition (name, description, input_schema) as an AnswerRequest tool.
    nonisolated static func answerTool(fromAnthropicTool tool: [String: Any]) -> AnswerRequest.Tool? {
        guard let name = tool["name"] as? String else { return nil }
        let schema = tool["input_schema"] as? [String: Any] ?? ["type": "object", "properties": [String: Any]()]
        guard let schemaJSON = try? JSONSerialization.data(withJSONObject: schema) else { return nil }
        return AnswerRequest.Tool(name: name, description: tool["description"] as? String ?? "", inputSchemaJSON: schemaJSON)
    }
}

nonisolated struct ClaudeToolCall: Equatable, Sendable {
    let id: String
    let name: String
    let arguments: [String: String]
}

extension ClaudeAPI {
    /// The failure an Anthropic `error` event reports ({"type":"error","error":{"type":…,"message":…}}),
    /// as a ClaudeAPI error with `midStreamErrorCode`; nil for every other event.
    static func streamFailure(fromEvent eventPayload: [String: Any]) -> NSError? {
        guard eventPayload["type"] as? String == "error" else { return nil }
        let streamError = eventPayload["error"] as? [String: Any]
        let errorType = streamError?["type"] as? String ?? "unknown"
        let errorMessage = streamError?["message"] as? String ?? ""
        return NSError(
            domain: "ClaudeAPI",
            code: midStreamErrorCode,
            userInfo: [NSLocalizedDescriptionKey: "Stream error (\(errorType)): \(errorMessage)"]
        )
    }

    /// The `stop_reason` a `message_delta` event carries ("end_turn", "max_tokens", "tool_use"…).
    static func stopReason(fromEvent eventPayload: [String: Any]) -> String? {
        guard eventPayload["type"] as? String == "message_delta",
              let delta = eventPayload["delta"] as? [String: Any] else { return nil }
        return delta["stop_reason"] as? String
    }

    /// Tool calls from an Anthropic SSE stream: `content_block_start` names the tool, `input_json_delta`
    /// pieces build its input, `content_block_stop` closes it. Input that is not valid JSON is dropped.
    static func parseToolCalls(fromSSELines lines: [String]) -> [ClaudeToolCall] {
        var open: [Int: (id: String, name: String, json: String)] = [:]
        var calls: [ClaudeToolCall] = []
        for line in lines where line.hasPrefix("data: ") {
            guard let data = line.dropFirst(6).data(using: .utf8),
                  let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = event["type"] as? String,
                  let index = event["index"] as? Int else { continue }
            switch type {
            case "content_block_start":
                if let block = event["content_block"] as? [String: Any], block["type"] as? String == "tool_use" {
                    open[index] = (block["id"] as? String ?? "", block["name"] as? String ?? "", "")
                }
            case "content_block_delta":
                if let delta = event["delta"] as? [String: Any], delta["type"] as? String == "input_json_delta",
                   let piece = delta["partial_json"] as? String, open[index] != nil {
                    open[index]!.json += piece
                }
            case "content_block_stop":
                guard let tool = open.removeValue(forKey: index) else { continue }
                let raw = tool.json.isEmpty ? "{}" : tool.json
                guard let object = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any] else { continue }
                var arguments: [String: String] = [:]
                for (key, value) in object {
                    if let string = value as? String { arguments[key] = string }
                    else if let number = value as? NSNumber { arguments[key] = number.stringValue }
                }
                calls.append(ClaudeToolCall(id: tool.id, name: tool.name, arguments: arguments))
            default:
                continue
            }
        }
        return calls
    }
}
