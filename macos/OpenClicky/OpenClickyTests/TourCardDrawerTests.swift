//
//  TourCardDrawerTests.swift
//  OpenClickyTests
//
//  The tour in a side drawer: everything fits, and nothing mentions a notch that isn't in use.
//

import AppKit
import SwiftUI
import Testing
@testable import OpenClicky

@MainActor
struct TourCardDrawerTests {
    private func height(of card: FirstRunTourCard) -> CGFloat {
        let view = FirstRunTourCardView(card: card, controller: FirstRunTourController(), isStacked: true)
            .frame(width: 360)
            .fixedSize(horizontal: false, vertical: true)
        return NSHostingView(rootView: view).fittingSize.height
    }

    private func drawer(status: String? = nil, microphone: String? = nil) -> NotchHUDModel {
        let frame = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let model = NotchHUDModel(geometry: NotchGeometry(screenFrame: frame, hasHardwareNotch: false, notchWidth: 190, notchHeight: 0, visibleFrame: frame))
        model.placement = .right
        return model
    }

    /// The real offer, and a card with the longest words any step has, a status and the microphone.
    @Test func theLongestCardsFitTheDrawer() {
        let offer = FirstRunTourCard(
            step: .voice, title: "want a more natural voice?",
            detail: "kokoro is a free voice that runs on this mac, even offline. it’s a one-time 350 MB download. you can change it any time in settings.",
            symbol: "waveform", primaryTitle: "download", secondaryTitle: "not now")
        let room = drawer().tourHeight - drawer().cardTopInset
        #expect(height(of: offer) <= room, "\(height(of: offer)) tall, \(room) to fit in")

        let busy = FirstRunTourCard(
            step: .dictate, title: "hold right ⌘ and say something",
            detail: "try “hello openclicky, this is my first take”, then let go.",
            keys: ["right ⌘"], status: "no words came through. check the microphone below, then try again.", statusIsGood: false,
            microphoneName: "MacBook Pro Microphone", primaryTitle: "next", secondaryTitle: "skip")
        // tourHeight adds the status's and the microphone's room to the same base.
        #expect(height(of: busy) <= room + 38 + 20, "\(height(of: busy)) tall, \(room + 58) to fit in")
    }

    @Test func theLastCardSaysWhereTheIslandReallyIs() {
        #expect(HUDPlacement.notch.reachSentence(hasHardwareNotch: true).contains("notch"))
        #expect(!HUDPlacement.notch.reachSentence(hasHardwareNotch: false).contains("notch"))
        #expect(HUDPlacement.right.reachSentence(hasHardwareNotch: true).contains("right edge"))
        #expect(HUDPlacement.left.reachSentence(hasHardwareNotch: true).contains("left edge"))
        #expect(!HUDPlacement.hidden.reachSentence(hasHardwareNotch: true).contains("hover"))
    }

    @Test func theRecordedGoodbyeOnlyPlaysAtARealNotch() {
        #expect(HUDPlacement.notch.isAtTheNotch(hasHardwareNotch: true))
        #expect(!HUDPlacement.notch.isAtTheNotch(hasHardwareNotch: false))
        #expect(!HUDPlacement.right.isAtTheNotch(hasHardwareNotch: true))
        #expect(!HUDPlacement.left.isAtTheNotch(hasHardwareNotch: true))
        #expect(!HUDPlacement.hidden.isAtTheNotch(hasHardwareNotch: true))
    }
}
