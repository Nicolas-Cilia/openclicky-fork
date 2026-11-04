//
//  AnswerSourceCheck.swift
//  OpenClicky
//
//  "Does this really answer?": one tiny question (what colour is this red square) asked of a
//  single source, for the Test buttons in Settings → Account and the Debug answer smoke.
//

import AppKit
import Foundation

nonisolated enum AnswerSourceCheck {
    enum Outcome: Equatable, Sendable {
        case works(seconds: Double)
        case failed(String)

        /// The line the Test button leaves in its row.
        var sentence: String {
            switch self {
            case .works(let seconds): return "✓ Works. It answered in \(String(format: "%.1f", seconds)) s."
            case .failed(let message): return message
            }
        }
    }

    /// Asks `source` alone, whatever the router would pick. Anthropic is checked by listing its
    /// models (ClaudeAPI answers it, not an AnswerProvider).
    static func run(_ source: AnswerSource, credentials: ProviderCredentials,
                    modelOverrides: [String: String]) async -> Outcome {
        let started = Date()
        do {
            switch source {
            case .anthropic:
                guard let key = credentials.anthropicKey else { return .failed("Add the key first.") }
                var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/models?limit=1")!)
                request.setValue(key, forHTTPHeaderField: "x-api-key")
                request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
                request.timeoutInterval = 20
                let (_, response) = try await URLSession.shared.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                return status == 200 ? .works(seconds: Date().timeIntervalSince(started))
                    : .failed(status == 401 ? "Anthropic didn’t accept this key." : "Anthropic answered \(status).")
            default:
                let provider = try await AnswerProviderFactory.make(for: source, credentials: credentials, modelOverrides: modelOverrides)
                let request = AnswerRequest(
                    images: [AnswerRequest.Image(data: redSquarePNG(), label: "a test image", mediaType: "image/png")],
                    systemPrompt: "answer in lowercase, one word.", history: [],
                    userPrompt: "what color is this square?", tools: [])
                let result = try await provider.answer(request) { _ in }
                let seconds = Date().timeIntervalSince(started)
                return result.text.lowercased().contains("red")
                    ? .works(seconds: seconds)
                    : .failed("It answered “\(result.text.prefix(40))” instead of red.")
            }
        } catch let error as AnswerProviderError {
            return .failed(error.message.prefix(1).uppercased() + error.message.dropFirst())
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// A 64×64 red PNG.
    static func redSquarePNG() -> Data {
        let image = NSImage(size: NSSize(width: 64, height: 64), flipped: false) { rect in
            NSColor.red.setFill(); rect.fill(); return true
        }
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else { return Data() }
        return png
    }
}
