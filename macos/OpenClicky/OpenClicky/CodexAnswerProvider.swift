//
//  CodexAnswerProvider.swift
//  OpenClicky
//
//  Answers on the person's ChatGPT plan through Codex, for one turn, with its tools switched off:
//
//    codex exec --skip-git-repo-check --ephemeral --ignore-user-config --ignore-rules
//               --sandbox read-only --color never --json
//               --disable shell_tool --disable unified_exec ... (see `disabledFeatures`)
//               -c web_search="disabled" -c model_reasoning_effort="low"
//               -c developer_instructions="<the request's system prompt>"
//               -C <scratch dir> -i <image files...> -o <scratch dir>/last-message.txt
//               [-m <model>] -
//
//  with the earlier turns, the image labels and the question on stdin. Verified against
//  codex-cli 0.152.1 (2026-10-11): a red square comes back as "red" in about 6 s.
//
//  Why these flags:
//    - It uses the person's own login: CODEX_HOME is removed from the environment so the default
//      ~/.codex is read, never OpenClicky's agent home (~/.openclicky/codex-home).
//    - `--ignore-user-config` skips ~/.codex/config.toml (auth still comes from CODEX_HOME). With
//      the person's config, plugins and skills loaded, a one-word answer took 34 s and ran shell
//      commands to read skill files; without it, 6 s and no commands.
//    - The disabled features and the read-only sandbox leave nothing for the agent to do but
//      answer. Low reasoning effort keeps a spoken answer quick.
//    - `developer_instructions` is Codex's slot for instructions on top of its own, the closest it
//      has to a system prompt; it is passed as a TOML string because `-c` values are parsed as TOML.
//    - `--output-last-message` writes exactly the final answer; `--json` events on stdout carry
//      the error message when a turn fails. Codex does not stream text here, so `onTextChunk`
//      gets the whole answer once.
//    - The request's quick-action tools have no CLI equivalent: they are described in the
//      developer instructions and asked for as [ACTION: …] lines (PlanToolProtocol.swift), which
//      are taken out of the answer and returned as tool calls. maxTokens is not sent.
//

import Foundation

nonisolated struct CodexAnswerProvider: AnswerProvider {
    let executablePath: String
    private let usageSink: PlanUsageSink
    /// `-m`: e.g. "gpt-5.5"; nil = Codex's default for a ChatGPT sign-in.
    let model: String?
    let processRunner: PlanCLIProcessRunning
    let timeoutSeconds: TimeInterval

    /// Agent capabilities that are on by default and have no place in a one-turn answer.
    static let disabledFeatures = [
        "shell_tool", "unified_exec", "plugins", "apps", "multi_agent", "image_generation",
        "browser_use", "computer_use", "skill_search", "hooks", "view_image",
    ]
    static let outputFileName = "last-message.txt"

    init(
        executablePath: String,
        model: String? = nil,
        processRunner: PlanCLIProcessRunning = PlanCLIProcessRunner(),
        timeoutSeconds: TimeInterval = 120,
        usageSink: PlanUsageSink = .none
    ) {
        self.usageSink = usageSink
        self.executablePath = executablePath
        self.model = model
        self.processRunner = processRunner
        self.timeoutSeconds = timeoutSeconds
    }

    func answer(_ request: AnswerRequest, onTextChunk: @escaping @Sendable (String) -> Void) async throws -> AnswerResult {
        let scratchWorkingDirectory: URL
        let imageFilePaths: [String]
        do {
            scratchWorkingDirectory = try PlanCLIs.makeScratchWorkingDirectory()
        } catch {
            throw AnswerProviderError(source: .codexPlan, status: 0, message: "Couldn't make a scratch folder to run Codex in.")
        }
        // The screenshots and the answer file live in the scratch folder, so removing it cleans up all.
        defer { try? FileManager.default.removeItem(at: scratchWorkingDirectory) }
        do {
            imageFilePaths = try Self.writeImageFiles(request.images, into: scratchWorkingDirectory)
        } catch {
            throw AnswerProviderError(source: .codexPlan, status: 0, message: "Couldn't save the screenshot for Codex.")
        }
        let outputFilePath = scratchWorkingDirectory.appendingPathComponent(Self.outputFileName).path

        let output: PlanCLIProcessOutput
        do {
            output = try await processRunner.run(
                executablePath: executablePath,
                arguments: Self.commandLineArguments(
                    model: model,
                    systemPrompt: PlanToolProtocol.systemPrompt(request.systemPrompt, offering: request.tools),
                    imageFilePaths: imageFilePaths,
                    outputFilePath: outputFilePath,
                    workingDirectoryPath: scratchWorkingDirectory.path
                ),
                standardInput: Data(Self.promptText(for: request).utf8),
                workingDirectory: scratchWorkingDirectory,
                environment: PlanCLIs.processEnvironment(forExecutableAt: executablePath),
                timeoutSeconds: timeoutSeconds,
                onStandardOutputChunk: nil
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw AnswerProviderError(source: .codexPlan, status: 0, message: "Couldn't start Codex at \(executablePath).")
        }
        try Task.checkCancellation()

        if let sample = Self.usageSample(fromJSONLines: output.standardOutputText) { usageSink.record(sample) }
        let outputFileContents = try? String(contentsOfFile: outputFilePath, encoding: .utf8)
        let answerText = try Self.answerText(outputFileContents: outputFileContents, output: output, timeoutSeconds: timeoutSeconds)
        guard !request.tools.isEmpty else {
            onTextChunk(answerText)
            return AnswerResult(text: answerText, toolCalls: [])
        }
        let (spokenText, toolCalls) = PlanToolProtocol.parse(answerText: answerText, knownToolNames: Set(request.tools.map(\.name)))
        if !spokenText.isEmpty { onTextChunk(spokenText) }
        return AnswerResult(text: spokenText, toolCalls: toolCalls)
    }

    // MARK: building the call

    static func commandLineArguments(
        model: String?,
        systemPrompt: String,
        imageFilePaths: [String],
        outputFilePath: String,
        workingDirectoryPath: String
    ) -> [String] {
        var arguments = [
            "exec",
            "--skip-git-repo-check",
            "--ephemeral",
            "--ignore-user-config",
            "--ignore-rules",
            "--sandbox", "read-only",
            "--color", "never",
            "--json",
        ]
        for featureName in disabledFeatures {
            arguments += ["--disable", featureName]
        }
        arguments += [
            "-c", "web_search=\"disabled\"",
            "-c", "model_reasoning_effort=\"low\"",
        ]
        if !systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            arguments += ["-c", "developer_instructions=\(tomlBasicString(systemPrompt))"]
        }
        if let model = model?.trimmingCharacters(in: .whitespacesAndNewlines), !model.isEmpty {
            arguments += ["-m", model]
        }
        arguments += ["-C", workingDirectoryPath]
        for imageFilePath in imageFilePaths {
            arguments += ["-i", imageFilePath]
        }
        arguments += ["-o", outputFilePath]
        // "-" reads the prompt from stdin: no length limit, and it never shows up in `ps`.
        arguments.append("-")
        return arguments
    }

    /// A TOML basic string ("..."), escaping what TOML requires: backslash, quote and control
    /// characters. Unescaped, a system prompt with a quote or a new line would fail to parse and
    /// Codex would take the raw text, quotes and all.
    static func tomlBasicString(_ text: String) -> String {
        var escapedText = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\\": escapedText += "\\\\"
            case "\"": escapedText += "\\\""
            case "\n": escapedText += "\\n"
            case "\r": escapedText += "\\r"
            case "\t": escapedText += "\\t"
            default:
                if scalar.value < 0x20 || scalar.value == 0x7F {
                    escapedText += String(format: "\\u%04X", scalar.value)
                } else {
                    escapedText.unicodeScalars.append(scalar)
                }
            }
        }
        return escapedText + "\""
    }

    /// The stdin prompt: earlier turns, what each attached image is (Codex attaches them in `-i`
    /// order without their labels), then the question.
    static func promptText(for request: AnswerRequest) -> String {
        var sections: [String] = []
        if let historyText = ClaudeCodeAnswerProvider.historyText(for: request.history) {
            sections.append(historyText)
        }
        if !request.images.isEmpty {
            var imageLines = ["Attached images, in order:"]
            for (imageIndex, image) in request.images.enumerated() {
                imageLines.append("\(imageIndex + 1). \(image.label)")
            }
            sections.append(imageLines.joined(separator: "\n"))
        }
        sections.append(request.userPrompt)
        return sections.joined(separator: "\n\n")
    }

    /// Writes each screenshot to the scratch folder with an extension matching its type, which is
    /// how Codex decides how to read it.
    static func writeImageFiles(_ images: [AnswerRequest.Image], into directory: URL) throws -> [String] {
        var imageFilePaths: [String] = []
        for (imageIndex, image) in images.enumerated() {
            let fileExtension = image.mediaType.lowercased().contains("png") ? "png" : "jpg"
            let imageFileURL = directory.appendingPathComponent("image-\(imageIndex + 1).\(fileExtension)")
            try image.data.write(to: imageFileURL)
            imageFilePaths.append(imageFileURL.path)
        }
        return imageFilePaths
    }

    // MARK: reading the result

    static func answerText(outputFileContents: String?, output: PlanCLIProcessOutput, timeoutSeconds: TimeInterval) throws -> String {
        if output.timedOut {
            throw AnswerProviderError(source: .codexPlan, status: 0, message: "Codex took longer than \(Int(timeoutSeconds)) seconds to answer.")
        }
        if output.exitStatus != 0 {
            let reason = errorMessage(fromJSONLines: output.standardOutputText) ?? PlanCLIs.lastNonEmptyLine(of: output.standardErrorText)
            throw AnswerProviderError(
                source: .codexPlan,
                status: 0,
                message: reason.map { humanSentence(forFailureText: $0) } ?? "Codex stopped with exit status \(output.exitStatus)."
            )
        }
        let fileAnswer = outputFileContents?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let answerText = fileAnswer.isEmpty ? (lastAgentMessage(fromJSONLines: output.standardOutputText) ?? "") : fileAnswer
        guard !answerText.isEmpty else {
            throw AnswerProviderError(source: .codexPlan, status: 0, message: "Codex finished without an answer.")
        }
        return answerText
    }

    /// The token counts on `turn.completed`. Codex's `input_tokens` already includes the cached ones.
    static func usageSample(fromJSONLines jsonLines: String) -> PlanUsageSample? {
        guard let usage = jsonEvents(in: jsonLines).last(where: { $0["type"] as? String == "turn.completed" })?["usage"] as? [String: Any] else { return nil }
        let count = { (key: String) in usage[key] as? Int ?? 0 }
        return PlanUsageSample(
            date: Date(), source: AnswerSource.codexPlan.rawValue, lane: .answer,
            inputTokens: count("input_tokens"), cachedInputTokens: count("cached_input_tokens"),
            outputTokens: count("output_tokens"), estimatedCostUSD: nil)
    }

    /// The last failure in `--json` output: a `turn.failed` event's error, else the last `error`
    /// event. The message is often the API's JSON error body itself
    /// (`{"type":"error","status":400,"error":{"message":"..."}}`), so the inner message is used.
    static func errorMessage(fromJSONLines jsonLines: String) -> String? {
        var turnFailedMessage: String?
        var lastErrorEventMessage: String?
        for event in jsonEvents(in: jsonLines) {
            switch event["type"] as? String {
            case "turn.failed":
                if let error = event["error"] as? [String: Any], let message = error["message"] as? String { turnFailedMessage = message }
            case "error":
                if let message = event["message"] as? String { lastErrorEventMessage = message }
            default:
                break
            }
        }
        guard let rawMessage = turnFailedMessage ?? lastErrorEventMessage else { return nil }
        return innerAPIErrorMessage(rawMessage) ?? rawMessage
    }

    static func lastAgentMessage(fromJSONLines jsonLines: String) -> String? {
        var lastAgentText: String?
        for event in jsonEvents(in: jsonLines) where event["type"] as? String == "item.completed" {
            if let item = event["item"] as? [String: Any], item["type"] as? String == "agent_message",
               let text = item["text"] as? String, !text.isEmpty {
                lastAgentText = text
            }
        }
        return lastAgentText?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func jsonEvents(in jsonLines: String) -> [[String: Any]] {
        jsonLines.split(whereSeparator: \.isNewline).compactMap { line in
            try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
        }
    }

    private static func innerAPIErrorMessage(_ rawMessage: String) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(rawMessage.utf8)) as? [String: Any] else { return nil }
        if let error = object["error"] as? [String: Any], let message = error["message"] as? String { return message }
        return object["message"] as? String
    }

    static func humanSentence(forFailureText failureText: String) -> String {
        let trimmedFailureText = failureText.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowercasedFailureText = trimmedFailureText.lowercased()
        if lowercasedFailureText.contains("not logged in") || lowercasedFailureText.contains("codex login")
            || lowercasedFailureText.contains("401") || lowercasedFailureText.contains("unauthorized") {
            return "Codex is signed out. Open Terminal, run codex login, and sign in with ChatGPT."
        }
        if PlanLimitText.matches(trimmedFailureText) {
            return "Your ChatGPT plan has hit its Codex usage limit for now."
        }
        return trimmedFailureText.isEmpty ? "Codex couldn't answer." : "Codex couldn't answer: \(trimmedFailureText)"
    }
}
