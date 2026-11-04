//
//  TeacherSketchWriter.swift
//  OpenClicky
//
//  The Realtime voice model talks well and draws badly: asked for refraction it ran the incoming
//  ray straight down the normal. So on that lane it only says what to draw, and a text model
//  writes the drawing while the voice is already explaining. On an own OpenAI key that is gpt-5.5
//  with reasoning off (refraction correct in ~3.5 s, where gpt-4.1 at 2 s piled labels on each
//  other and gpt-5.4-mini barely bent the ray; measured 2026-10-23).
//
//  It also writes the lessons the app starts itself (`TeacherPlugin.startLesson`), so it has to
//  work without OpenAI too, since most people have no key: an Anthropic key gets Claude Sonnet 5.5
//  with thinking off (3-4 s and the clearest drawings of those measured; Haiku 4.5 overlapped
//  its labels), and another API key its own provider. Plans (the Claude Code and
//  Codex apps) take 15 s or more to start, so they never start a lesson early.
//

import Foundation

enum TeacherSketchWriter {
    static let openAIModel = "gpt-5.5"
    static let anthropicModel = "claude-sonnet-5-5"
    /// The output a lesson needs: 25 commands is 400-700 tokens.
    static let maximumOutputTokens = 1024

    /// Where a lesson is written, best first.
    enum Route: Equatable {
        case openAI(key: String)
        case anthropic(key: String)
        /// Another API key the ask lane answers with (OpenRouter, Gemini, Groq, Mistral, xAI).
        case answerSource(AnswerSource)
    }

    /// Nil when the only way to write is a plan, or nothing at all.
    static func route(for credentials: ProviderCredentials) -> Route? {
        if let openAIKey = credentials.openAIKey { return .openAI(key: openAIKey) }
        if let anthropicKey = credentials.anthropicKey { return .anthropic(key: anthropicKey) }
        let fastSources = credentials.answerSourcesInOrder.filter { ![.claudeCodePlan, .codexPlan, .anthropic, .openAI].contains($0) }
        return fastSources.first.map(Route.answerSource)
    }
    static let timeoutSeconds: TimeInterval = 20

    static var systemPrompt: String {
        "You draw teaching diagrams on a whiteboard for a school student. Reply with only the drawing commands, nothing else: no code fences, no explanation.\n" + TeacherPlugin.sketchGrammar
    }

    static func userPrompt(title: String, whatToDraw: String) -> String {
        "Draw: \(whatToDraw)\nTitle: \(title)"
    }

    /// For a question nobody has described a drawing for yet (`TeacherPlugin.startLesson`).
    static func userPrompt(question: String, withScreenshot: Bool = false) -> String {
        """
        The student asked: "\(question)"\(withScreenshot ? "\nThe attached screenshot is what they are looking at; \"this\" means what is on it." : "")
        Draw the one diagram a good teacher would put on the whiteboard to answer it, with a short title at the top. \
        If they ask to solve or work something out, write the worked solution instead: the problem first, then one \
        short line per step, in order, left-aligned under each other (text with the option left), the answer last in red. \
        If no simple diagram can show it well (a real animal, an organ, a place, a painting, a photo of a machine), \
        reply with exactly one line instead: PICTURE: <a short search phrase in English>
        """
    }

    /// What the writer answered: drawing commands, or a picture to search for.
    enum Reply: Equatable {
        case sketch(String)
        case picture(query: String)

        static func parse(_ text: String) -> Reply {
            let trimmed = withoutCodeFences(text).trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.uppercased().hasPrefix("PICTURE:") {
                return .picture(query: String(trimmed.dropFirst("PICTURE:".count)).trimmingCharacters(in: .whitespacesAndNewlines))
            }
            return .sketch(trimmed)
        }
    }

    /// The drawing commands, or nil when no model could write them.
    @MainActor static func write(title: String, whatToDraw: String) async -> String? {
        await complete(userPrompt: userPrompt(title: title, whatToDraw: whatToDraw), screenshotJPEG: nil).map(withoutCodeFences)
    }

    /// The lesson for a question: drawing commands or a picture search; nil when no model answered.
    /// `screenshotJPEG` goes along when the question is about the screen ("solve this").
    @MainActor static func lesson(for question: String, screenshotJPEG: Data?) async -> Reply? {
        await complete(userPrompt: userPrompt(question: question, withScreenshot: screenshotJPEG != nil), screenshotJPEG: screenshotJPEG).map(Reply.parse)
    }

    /// Wherever a lesson can be written in a few seconds; a plan alone would race the model's own
    /// drawing for nothing.
    @MainActor static var canStartLessonsEarly: Bool {
        route(for: ProviderRouter.currentCredentials()) != nil
    }

    @MainActor private static func complete(userPrompt: String, screenshotJPEG: Data?) async -> String? {
        let startedAt = Date()
        let route = route(for: ProviderRouter.currentCredentials())
        let reply: String?
        switch route {
        case .openAI(let key)?:
            reply = await writeWithOpenAI(key: key, userPrompt: userPrompt, screenshotJPEG: screenshotJPEG)
        case .anthropic(let key)?:
            reply = await writeWithClaude(request: DirectProviderRequests.anthropicMessages(key: key),
                                          userPrompt: userPrompt, screenshotJPEG: screenshotJPEG)
        case .answerSource?, nil:
            // ClaudeAPI hands these to the source's AnswerProvider (1,024 tokens); a plan is slow but
            // still draws what the Realtime lane described.
            let answers = ClaudeAPI()
            let images = screenshotJPEG.map { [(data: $0, label: "the student's screen")] } ?? []
            reply = try? await answers.analyzeImage(images: images, systemPrompt: systemPrompt, userPrompt: userPrompt).text
        }
        AppLog.append("teacher: sketch \(reply == nil ? "not written" : "written") via \(routeName(route)) in \(String(format: "%.1f", Date().timeIntervalSince(startedAt))) s")
        return reply
    }

    static func routeName(_ route: Route?) -> String {
        switch route {
        case .openAI?: return "openai \(openAIModel)"
        case .anthropic?: return "anthropic \(anthropicModel)"
        case .answerSource(let source)?: return source.rawValue
        case nil: return "the answer source"
        }
    }

    /// The Messages body for a lesson. Thinking is turned off: Sonnet 5.5 thinks by default and
    /// spent the whole budget before writing a stroke (it takes "between_tools", not "disabled").
    static func claudeBody(userPrompt: String, screenshotJPEG: Data?) -> [String: Any] {
        var content: [[String: Any]] = []
        if let screenshotJPEG {
            content.append(["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": screenshotJPEG.base64EncodedString()]])
        }
        content.append(["type": "text", "text": userPrompt])
        return [
            "model": anthropicModel,
            "max_tokens": maximumOutputTokens,
            "thinking": ["type": "between_tools"],
            "system": systemPrompt,
            "messages": [["role": "user", "content": content]],
        ]
    }

    private static func writeWithClaude(request: URLRequest, userPrompt: String, screenshotJPEG: Data?) async -> String? {
        var request = request
        request.timeoutInterval = timeoutSeconds
        request.httpBody = try? JSONSerialization.data(withJSONObject: claudeBody(userPrompt: userPrompt, screenshotJPEG: screenshotJPEG))
        guard let (data, response) = try? await URLSession.shared.data(for: request) else { return nil }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            AppLog.append("teacher: sketch writer refused (\((response as? HTTPURLResponse)?.statusCode ?? 0))")
            return nil
        }
        // Nil at max_tokens: half a drawing is not drawn.
        return DirectProviderRequests.anthropicReplyText(from: data)
    }

    private static func writeWithOpenAI(key: String, userPrompt: String, screenshotJPEG: Data?) async -> String? {
        var request = DirectProviderRequests.openAIChatCompletions(key: key)
        request.timeoutInterval = timeoutSeconds
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "model": openAIModel,
            "reasoning_effort": "none",
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userContent(userPrompt: userPrompt, screenshotJPEG: screenshotJPEG)],
            ],
        ] as [String: Any])
        guard let (data, response) = try? await URLSession.shared.data(for: request) else { return nil }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            AppLog.append("teacher: sketch writer refused (\((response as? HTTPURLResponse)?.statusCode ?? 0))")
            return nil
        }
        return chatCompletionText(from: data)
    }

    /// Plain text, or text plus the screenshot as a data URL (Chat Completions' image input).
    static func userContent(userPrompt: String, screenshotJPEG: Data?) -> Any {
        guard let screenshotJPEG else { return userPrompt }
        return [
            ["type": "text", "text": userPrompt],
            ["type": "image_url", "image_url": ["url": "data:image/jpeg;base64,\(screenshotJPEG.base64EncodedString())"]],
        ]
    }

    static func chatCompletionText(from data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = ((root["choices"] as? [[String: Any]])?.first)?["message"] as? [String: Any],
              let content = message["content"] as? String,
              !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return content
    }

    /// Models sometimes wrap the commands in ``` fences anyway.
    static func withoutCodeFences(_ text: String) -> String {
        text.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("```") }.joined(separator: "\n")
    }
}
