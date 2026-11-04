import Foundation
import Testing
@testable import OpenClicky

/// What the ⌃⌥ ask lane says (or does not say) when an answer does not arrive normally.
@MainActor
struct AskLaneFailureTests {
    // F-09: cancelling the task that reads the answer stream ends it with URLError.cancelled (-999),
    // which must read as an interruption, never as "something went wrong".
    @Test func aCancelledStreamIsAnInterruption() {
        #expect(CompanionManager.isCancellation(URLError(.cancelled)))
        #expect(CompanionManager.isCancellation(NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)))
        #expect(CompanionManager.isCancellation(CancellationError()))
        #expect(!CompanionManager.isCancellation(URLError(.timedOut)))
        #expect(!CompanionManager.isCancellation(AnswerHTTPError(status: 500, body: Data())))
    }

    // F-34: a screenshot that cannot be taken is not a key problem.
    @Test func aCaptureFailureNamesScreenRecordingNotTheToken() {
        let captureError = CompanionManager.AskScreenCaptureError(
            underlyingError: NSError(domain: "com.apple.ScreenCaptureKit.SCStreamErrorDomain", code: -3801))
        let permissionOff = CompanionManager.askFailureSentence(for: captureError, screenRecordingAllowed: false)
        #expect(permissionOff.contains("screen recording"))
        #expect(!permissionOff.contains("key"))
        let permissionOn = CompanionManager.askFailureSentence(for: captureError, screenRecordingAllowed: true)
        #expect(permissionOn.contains("see your screen"))
        #expect(!permissionOn.contains("key"))
    }

    @Test func aRefusedKeyIsSaidToBeTheKey() {
        let forbidden = AnswerHTTPError(status: 403, body: Data())
        #expect(CompanionManager.askFailureSentence(for: forbidden, screenRecordingAllowed: true)
                == CompanionManager.ownKeyRefusedSentence)
        #expect(CompanionManager.isKeyRejection(AnswerHTTPError(status: 401, body: Data())))
        #expect(!CompanionManager.isKeyRejection(AnswerHTTPError(status: 500, body: Data())))
        let serverError = AnswerHTTPError(status: 500, body: Data())
        #expect(CompanionManager.askFailureSentence(for: serverError, screenRecordingAllowed: true)
                == "something went wrong getting your answer. please ask again.")
        #expect(CompanionManager.askFailureSentence(for: URLError(.notConnectedToInternet), screenRecordingAllowed: true).contains("internet"))
    }

    // F-43 (Mac side): an `error` event after the stream started is a failure, not a finished answer.
    @Test func aMidStreamErrorEventIsAFailure() throws {
        let errorEvent = try #require(JSONSerialization.jsonObject(with: Data(
            #"{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#.utf8)) as? [String: Any])
        let failure = try #require(ClaudeAPI.streamFailure(fromEvent: errorEvent))
        #expect(failure.domain == "ClaudeAPI")
        #expect(failure.code == ClaudeAPI.midStreamErrorCode)
        #expect(failure.localizedDescription.contains("overloaded_error"))
        #expect(CompanionManager.askFailureSentence(for: failure, screenRecordingAllowed: true).contains("stopped partway"))

        let textEvent = try #require(JSONSerialization.jsonObject(with: Data(
            #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"hi"}}"#.utf8)) as? [String: Any])
        #expect(ClaudeAPI.streamFailure(fromEvent: textEvent) == nil)
    }

    @Test func aCutOffAnswerIsRecognised() throws {
        let cutOff = try #require(JSONSerialization.jsonObject(with: Data(
            #"{"type":"message_delta","delta":{"stop_reason":"max_tokens","stop_sequence":null},"usage":{"output_tokens":1024}}"#.utf8)) as? [String: Any])
        #expect(ClaudeAPI.stopReason(fromEvent: cutOff) == "max_tokens")
        let finished = try #require(JSONSerialization.jsonObject(with: Data(
            #"{"type":"message_delta","delta":{"stop_reason":"end_turn"}}"#.utf8)) as? [String: Any])
        #expect(ClaudeAPI.stopReason(fromEvent: finished) == "end_turn")
    }

    // F-35: an empty answer, or one that is only a tag, has nothing to speak.
    @Test func anAnswerThatIsOnlyATagHasNothingToSpeak() {
        let bareNone = CompanionManager.parsePointingCoordinates(from: "[POINT:none]")
        #expect(CompanionManager.spokenReply(text: bareNone.spokenText, toolOutcomes: []).isEmpty)
        #expect(CompanionManager.spokenReply(text: "", toolOutcomes: []).isEmpty)
        #expect(!CompanionManager.emptyAnswerSentence.isEmpty)
    }
}
