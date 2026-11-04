//
//  GuidedStepsTests.swift
//  OpenClickyTests
//
//  Step by step guidance: the [NEXT] marker is found and never spoken, and a click, Return or Tab
//  (not typing alone, not esc) is what moves a guide on. A click far from where the pointer pointed
//  is flagged to the model as off target; Return and Tab have no position and count as unknown.
//

import AppKit
import Testing
@testable import OpenClicky

struct GuidedStepsTests {
    @Test func theMarkerIsFoundHoweverItIsWritten() {
        #expect(GuidedStepMarker.containsMarker("click the paperclip. [NEXT]"))
        #expect(GuidedStepMarker.containsMarker("click the paperclip. [ next ]"))
        #expect(!GuidedStepMarker.containsMarker("that's the next button."))
        #expect(GuidedStepMarker.removingMarkers(from: "[POINT:1,2:clip] click the paperclip. [NEXT]\n") == "[POINT:1,2:clip] click the paperclip.")
    }

    @Test func theMarkerIsNeverSpoken() {
        var chunker = SpokenChunker()
        #expect(chunker.feed(accumulated: "[POINT:612,88:attach] click the paperclip at the top. [NEXT]") == ["click the paperclip at the top."])
        #expect(chunker.finish() == [])
        #expect(chunker.pointTag == "[POINT:612,88:attach]")
    }

    @Test func aMarkerOnItsOwnLineIsNotSpokenEither() {
        var chunker = SpokenChunker()
        #expect(chunker.feed(accumulated: "click the paperclip at the top.\n[NEXT]\n") == ["click the paperclip at the top."])
        #expect(chunker.finish() == [])
    }

    @Test func aTrailingPointTagBeforeTheMarkerStillPoints() {
        var chunker = SpokenChunker()
        _ = chunker.feed(accumulated: "click the paperclip at the top [POINT:612,88:attach] [NEXT]")
        #expect(chunker.finish() == ["click the paperclip at the top"])
        #expect(chunker.pointTag == "[POINT:612,88:attach]")
    }

    @Test func aClickReturnOrTabFinishesAStepAfterTheScreenSettles() {
        #expect(GuidedStepRules.reaction(to: .click, askIsPending: false) == .askForNextStep(settleSeconds: GuidedStepRules.settleSecondsAfterClick))
        #expect(GuidedStepRules.reaction(to: .stepKey, askIsPending: false) == .askForNextStep(settleSeconds: GuidedStepRules.settleSecondsAfterStepKey))
    }

    @Test func typingAloneIsNotAStepButTypingAfterAClickWaitsLonger() {
        #expect(GuidedStepRules.reaction(to: .otherKey, askIsPending: false) == .ignore)
        #expect(GuidedStepRules.reaction(to: .otherKey, askIsPending: true) == .postponePendingAsk(settleSeconds: GuidedStepRules.settleSecondsWhileTyping))
    }

    /// "Right-click the clip" is a step: the right click that opens the menu counts like a left click.
    @Test func aRightClickCountsAsAClick() throws {
        for eventType in [NSEvent.EventType.leftMouseUp, .rightMouseUp] {
            let event = try #require(NSEvent.mouseEvent(
                with: eventType, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 0))
            #expect(GuidedStepWatcher.input(for: event) == .click)
        }
    }

    @Test func escEndsTheGuide() {
        #expect(GuidedStepRules.reaction(to: .escapeKey, askIsPending: false) == .endGuide)
        #expect(GuidedStepRules.reaction(to: .escapeKey, askIsPending: true) == .endGuide)
    }

    @Test func theNextStepRequestRepeatsTheGoal() {
        let request = GuidedStepRules.nextStepRequest(forGoal: "how do i attach a file")
        #expect(request.hasPrefix(GuidedStepRules.nextStepRequestOpening))
        #expect(request.contains("how do i attach a file"))
        #expect(!request.contains("—"))
    }

    @Test func aClickNearThePointedSpotIsOnTarget() {
        let pointed = CGPoint(x: 400, y: 300)
        #expect(GuidedStepClickCheck.verdict(pointedAt: pointed, clickedAt: CGPoint(x: 400, y: 300)) == .onTarget)
        // Pointing is known to be up to about 100 points off: that is still on target.
        #expect(GuidedStepClickCheck.verdict(pointedAt: pointed, clickedAt: CGPoint(x: 480, y: 360)) == .onTarget)
        #expect(GuidedStepClickCheck.verdict(pointedAt: pointed, clickedAt: CGPoint(x: 520, y: 300)) == .onTarget)
    }

    @Test func aClickFarFromThePointedSpotIsOffTargetByAboutHowFar() {
        let pointed = CGPoint(x: 400, y: 300)
        #expect(GuidedStepClickCheck.verdict(pointedAt: pointed, clickedAt: CGPoint(x: 521, y: 300)) == .offTarget(pointsAway: 120))
        #expect(GuidedStepClickCheck.verdict(pointedAt: pointed, clickedAt: CGPoint(x: 400, y: 0)) == .offTarget(pointsAway: 300))
        #expect(GuidedStepClickCheck.verdict(pointedAt: pointed, clickedAt: CGPoint(x: 550, y: 500)) == .offTarget(pointsAway: 250))
    }

    @Test func noClickOrNothingPointedAtIsUnknown() {
        #expect(GuidedStepClickCheck.verdict(pointedAt: CGPoint(x: 1, y: 1), clickedAt: nil) == .unknown)
        #expect(GuidedStepClickCheck.verdict(pointedAt: nil, clickedAt: CGPoint(x: 1, y: 1)) == .unknown)
    }

    @Test func anOffTargetClickAsksTheModelToCheckAndStillRepeatsTheGoal() {
        let request = GuidedStepRules.nextStepRequest(forGoal: "turn on dark mode", clickCheck: .offTarget(pointsAway: 180))
        #expect(request.hasPrefix(GuidedStepRules.offTargetRequestOpening))
        #expect(request.contains("about 180 points away from where you pointed"))
        #expect(request.contains("gently point me back"))
        #expect(request.hasSuffix("what i asked was: turn on dark mode)"))
        #expect(!request.contains("—"))
        #expect(!GuidedStepClickCheck.offTargetCaption.contains("—"))
    }

    @Test func onTargetAndUnknownClicksKeepTodaysRequest() {
        let plain = GuidedStepRules.nextStepRequest(forGoal: "turn on dark mode")
        #expect(GuidedStepRules.nextStepRequest(forGoal: "turn on dark mode", clickCheck: .onTarget) == plain)
        #expect(GuidedStepRules.nextStepRequest(forGoal: "turn on dark mode", clickCheck: .unknown) == plain)
        #expect(plain.hasPrefix(GuidedStepRules.nextStepRequestOpening))
    }

    // MARK: Waiting for a spoken "continue"

    @Test func whenTheGuideWaitsForContinueNoClickOrKeyFinishesAStep() {
        for input in [GuidedStepInput.click, .stepKey, .otherKey] {
            #expect(GuidedStepRules.reaction(to: input, askIsPending: false, advancesOnlyWhenTold: true) == .ignore)
            #expect(GuidedStepRules.reaction(to: input, askIsPending: true, advancesOnlyWhenTold: true) == .ignore)
        }
    }

    @Test func escStillEndsAGuideThatWaitsForContinue() {
        #expect(GuidedStepRules.reaction(to: .escapeKey, askIsPending: false, advancesOnlyWhenTold: true) == .endGuide)
    }

    @Test func aGuideThatWaitsForContinueWaitsLongerBeforeGivingUp() {
        #expect(GuidedStepRules.idleSecondsBeforeGivingUpWhileWaitingForContinue > GuidedStepRules.idleSecondsBeforeGivingUp)
    }

    @Test func continueAndItsShortCousinsMoveTheGuideOn() {
        for spokenWords in ["continue", "Continue.", "okay, continue", "ok continue please", "next", "Next step!",
                            "go on", "I'm done", "I’m ready", "what's next?", "done", "alright, keep going", "Clicky, continue"] {
            #expect(GuidedStepContinuePhrase.isContinue(spokenWords), "\(spokenWords)")
        }
    }

    @Test func theWaysPeopleActuallySayItMoveTheGuideOn() {
        for spokenWords in ["okay I did that, what's next", "I've done that", "ok that's done, next step", "yep, all done", "finished, what now",
                            "I clicked it, what do I do next?", "what's the next step", "alright I did it and what should I do next"] {
            #expect(GuidedStepContinuePhrase.isContinue(spokenWords), "\(spokenWords)")
        }
    }

    @Test func aRealQuestionWithContinueWordsInItIsStillAQuestion() {
        for spokenWords in ["i did that but nothing happened", "what's next to the save button", "done with what",
                            "i clicked it and it says error", "go ahead and delete this file", "ready to print this how do i do that"] {
            #expect(!GuidedStepContinuePhrase.isContinue(spokenWords), "\(spokenWords)")
        }
    }

    @Test func aRealQuestionIsNotAContinue() {
        for spokenWords in ["", "okay", "what does this button do", "what's the next tab over", "continue the email i was writing",
                            "now", "what", "how do i get back to the previous step", "next to the save button what is that icon", "wait"] {
            #expect(!GuidedStepContinuePhrase.isContinue(spokenWords), "\(spokenWords)")
        }
    }
}
