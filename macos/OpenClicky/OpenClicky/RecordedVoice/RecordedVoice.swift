//
//  RecordedVoice.swift
//  OpenClicky
//
//  The lines OpenClicky says the same way every time, recorded once in its answering voice
//  (OpenAI speech, marin) and bundled, so they sound good with no key and no network: the
//  first-run tour's narration, and the notices that used to be read by the Mac's system voice
//  ("i didn't get an answer…"). Anything not recorded here is spoken the way it was before.
//

import AVFoundation
import Foundation

@MainActor
final class RecordedVoice {
    enum Line: String {
        case tourHello = "tour-hello"
        case tourDictate = "tour-dictate"
        case tourDictateDone = "tour-dictate-done"
        case tourTalk = "tour-talk"
        case tourTalkDone = "tour-talk-done"
        case tourAct = "tour-act"
        case tourActDone = "tour-act-done"
        case tourDone = "tour-done"
        case noticeEmptyAnswer = "notice-empty-answer"
        case noticeNoScreen = "notice-no-screen"
        case noticeScreenRecordingOff = "notice-screen-recording-off"
        case noticeNoInternet = "notice-no-internet"
        case noticeStoppedPartway = "notice-stopped-partway"
        case noticeWentWrong = "notice-went-wrong"
        case noticeRealtimeUnavailable = "notice-realtime-unavailable"
        // The one-minute Settings tour (SettingsTour.swift).
        case settingsTourIntro = "settings-tour-intro"
        case settingsTourDictation = "settings-tour-dictation"
        case settingsTourLanguage = "settings-tour-language"
        case settingsTourPointer = "settings-tour-pointer"
        case settingsTourWords = "settings-tour-words"
        case settingsTourShortcuts = "settings-tour-shortcuts"
        case settingsTourKeys = "settings-tour-keys"
        case settingsTourDone = "settings-tour-done"
    }

    /// The fixed sentences the app speaks, by their exact text (any case), and their recording.
    static let notices: [String: Line] = [
        "i didn't get an answer. please ask again.": .noticeEmptyAnswer,
        "i couldn't see your screen just now. please ask again.": .noticeNoScreen,
        "screen recording is off for openclicky. turn it on in system settings, privacy and security, screen recording.": .noticeScreenRecordingOff,
        "i couldn't reach openclicky. check your internet and ask again.": .noticeNoInternet,
        "the answer stopped partway. please ask again.": .noticeStoppedPartway,
        "something went wrong getting your answer. please ask again.": .noticeWentWrong,
        "realtime voice is unavailable right now.": .noticeRealtimeUnavailable,
    ]

    static func line(forSpokenText text: String) -> Line? {
        notices[text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()]
    }

    private var player: AVAudioPlayer?
    /// Tells whoever played the current line that it ended. Held here because the player's
    /// delegate is weak.
    private var finishObserver: AudioPlayerFinishObserver?

    var isPlaying: Bool { player?.isPlaying ?? false }

    /// Plays `line`, cutting off whatever recording was playing. False when it is not bundled.
    /// `onFinished` runs once when the line ends: played to the end, cut off by the next line, or
    /// stopped (the companion uses it to go back to idle after a spoken notice).
    @discardableResult
    func play(_ line: Line, onFinished: (() -> Void)? = nil) -> Bool {
        guard let url = Bundle.main.url(forResource: line.rawValue, withExtension: "mp3"),
              let newPlayer = try? AVAudioPlayer(contentsOf: url) else {
            AppLog.append("recorded voice: \(line.rawValue).mp3 is not in the bundle")
            return false
        }
        stopCurrentLine()
        newPlayer.volume = 0.85
        let newFinishObserver = AudioPlayerFinishObserver()
        newFinishObserver.onFinish = onFinished
        newPlayer.delegate = newFinishObserver
        finishObserver = newFinishObserver
        player = newPlayer
        if !newPlayer.play() { newFinishObserver.finishOnce() }
        return true
    }

    func stop() {
        stopCurrentLine()
    }

    /// A stopped AVAudioPlayer never calls its delegate, so the end is reported here.
    private func stopCurrentLine() {
        player?.stop()
        finishObserver?.finishOnce()
        finishObserver = nil
    }
}
