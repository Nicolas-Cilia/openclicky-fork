//
//  ScreenElementGrounder.swift
//  OpenClicky
//
//  `point_at` fallback for elements OCR cannot snap to (icons, symbols, captions the recognizer
//  missed). The Realtime model's own pixel guess is hundreds of pixels off for icons, but Claude
//  locates an element on the same 1280 px screenshot to within a few pixels (measured ≤ 8 px on
//  a "+" header button and a small "New" button, 2–4 s with Haiku 4.5), so the description the
//  Realtime model gave is handed to Claude (an own Anthropic key) or,
//  when another answer source is picked, to that source's AnswerProvider. The plans are skipped.
//

import CoreGraphics
import Foundation

nonisolated enum ScreenElementGrounder {
    /// Fast and as accurate as Sonnet on this task.
    static let model = "claude-haiku-4-5"

    /// Where Claude put the element, and the text it says the element shows ("arXiv"), when it
    /// shows any. The text is what makes the answer precise: Claude is reliable about *which*
    /// element answers "how do I open this paper" and loose about its pixels — it put a paper's
    /// "arXiv" link 130 px too high, on the abstract — while OCR has that text's exact box.
    struct Located: Equatable {
        let point: CGPoint
        let visibleText: String?
    }

    /// Asks Claude where `label`/`text` is on `capture`'s screenshot. Nil when nothing can answer
    /// (or only a plan), the request fails, or Claude answers [POINT:none]; app.log says when it
    /// could not ask.
    static func locate(label: String, text: String, userRequest: String?, in capture: CompanionScreenCapture) async -> Located? {
        // Own Anthropic key: Claude at Anthropic directly; another answer key: its own provider.
        if let reason = reasonGroundingCannotRun(on: await ProviderRouter.current(for: .claude)) {
            AppLog.append("point_at: no grounding (\(reason))")
            return nil
        }
        let imageSize = CGSize(width: capture.screenshotWidthInPixels, height: capture.screenshotHeightInPixels)
        let api = await ClaudeAPI(model: model)
        let reply: (text: String, duration: TimeInterval)
        do {
            reply = try await api.analyzeImage(
                images: [(data: capture.imageData, label: "Screenshot of the user's screen, \(Int(imageSize.width))×\(Int(imageSize.height)) px, origin top-left.")],
                systemPrompt: "You locate UI elements in screenshots and answer only with a [POINT:x,y:visible text] tag in the screenshot's pixel coordinates.",
                userPrompt: prompt(label: label, text: text, userRequest: userRequest, imageSize: imageSize)
            )
        } catch {
            // Only the domain and code: a refusal's body could quote the request.
            let nsError = error as NSError
            AppLog.append("point_at: grounding failed (\(nsError.domain) \(nsError.code))")
            return nil
        }
        guard let point = parsePoint(from: reply.text, imageSize: imageSize) else { return nil }
        return Located(point: point, visibleText: parseVisibleText(from: reply.text))
    }

    /// Why grounding is skipped on `route`; nil when it can run. The plans answer through a CLI
    /// that takes several seconds to start, while the pointer is waiting mid-sentence, so they
    /// are skipped; the model's own guess (or OCR) stands instead.
    static func reasonGroundingCannotRun(on route: ProviderRoute) -> String? {
        switch route {
        case .unavailable:
            return "nothing is set up to answer"
        case .answerProvider(let source) where source == .claudeCodePlan || source == .codexPlan:
            return "\(source.displayName) is too slow to locate an element mid-sentence"
        case .anthropicDirect, .openAIDirect, .answerProvider:
            return nil
        }
    }

    static func prompt(label: String, text: String, userRequest: String?, imageSize: CGSize) -> String {
        var lines = ["The screenshot is \(Int(imageSize.width))×\(Int(imageSize.height)) px, origin top-left."]
        var element = "Find the center of this UI element: \(label)"
        if !text.isEmpty { element += " (it shows the text \"\(text)\")" }
        lines.append(element + ".")
        if let userRequest, !userRequest.isEmpty {
            lines.append("The user asked: \"\(userRequest)\", pick the element that answers that.")
        }
        lines.append("Reply with only [POINT:x,y:visible text], where visible text is exactly what the element itself shows (a link that reads \"arXiv\" is arXiv, whatever it leads to), or [POINT:x,y] for an element with no text, or [POINT:none] if it is not visible.")
        return lines.joined(separator: "\n")
    }

    /// The `:visible text` part of `[POINT:x,y:visible text]`; nil when absent or blank.
    static func parseVisibleText(from reply: String) -> String? {
        guard let pattern = try? NSRegularExpression(pattern: #"\[POINT:\s*\d+\s*,\s*\d+\s*:([^\]]*)\]"#) else { return nil }
        let wholeReply = NSRange(reply.startIndex..., in: reply)
        guard let match = pattern.firstMatch(in: reply, range: wholeReply),
              let textRange = Range(match.range(at: 1), in: reply) else { return nil }
        let visibleText = reply[textRange].trimmingCharacters(in: .whitespacesAndNewlines)
        return visibleText.isEmpty ? nil : visibleText
    }

    /// `[POINT:x,y]` (spaces allowed) inside the screenshot; nil for `[POINT:none]`, no tag, or
    /// coordinates off the image.
    static func parsePoint(from reply: String, imageSize: CGSize) -> CGPoint? {
        let pattern = try! NSRegularExpression(pattern: #"\[POINT:\s*(\d+)\s*,\s*(\d+)\s*(?::[^\]]*)?\]"#)
        let wholeReply = NSRange(reply.startIndex..., in: reply)
        guard let match = pattern.firstMatch(in: reply, range: wholeReply),
              let xRange = Range(match.range(at: 1), in: reply), let yRange = Range(match.range(at: 2), in: reply),
              let x = Double(reply[xRange]), let y = Double(reply[yRange]),
              x >= 0, y >= 0, x <= imageSize.width, y <= imageSize.height else { return nil }
        return CGPoint(x: x, y: y)
    }
}
