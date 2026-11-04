//
//  HUDPlacement.swift
//  OpenClicky
//
//  Where the island lives: automatic (the notch, unless another app is using it), hanging from the notch, tucked against the left or right
//  edge of the screen as a drawer, or nowhere at all while idle (shortcuts only: the busy strip,
//  the composer and the permission cards still open under the notch, and the menu bar icon is
//  how the panel opens).
//

import Foundation

enum HUDPlacement: String, CaseIterable, Identifiable {
    case automatic, notch, left, right, hidden

    var id: String { rawValue }

    static let defaultsKey = "openclicky.hudPlacement"

    static var stored: HUDPlacement {
        UserDefaults.standard.string(forKey: defaultsKey).flatMap(HUDPlacement.init(rawValue:)) ?? .automatic
    }

    var title: String {
        switch self {
        case .automatic: return "automatic"
        case .notch: return "notch"
        case .left: return "left edge"
        case .right: return "right edge"
        case .hidden: return "hidden"
        }
    }

    var detail: String {
        switch self {
        case .automatic: return "the notch, or the right edge while another app is using the notch."
        case .notch: return "hangs from the notch; hover it to open."
        case .left: return "a drawer on the left edge of every screen; hover the handle to open."
        case .right: return "a drawer on the right edge of every screen; hover the handle to open."
        case .hidden: return "nothing on screen until you use a shortcut. the menu bar icon opens the panel."
        }
    }

    /// True for the two drawer placements, whose island hangs from a screen edge instead of the top.
    var isSideDrawer: Bool { self == .left || self == .right }

    /// Where the island actually goes. Only Automatic depends on what else is on screen.
    func resolved(notchIsOccupied: Bool) -> HUDPlacement {
        guard self == .automatic else { return self }
        return notchIsOccupied ? .right : .notch
    }
}
