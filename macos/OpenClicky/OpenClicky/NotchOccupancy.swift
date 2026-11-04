//
//  NotchOccupancy.swift
//  OpenClicky
//
//  Sharing the notch with other apps (Vorssaint and the like): placement "Automatic" keeps the island
//  in the notch until another app has a window over it, then moves to the right edge, and comes
//  back when that app has gone. It looks at windows rather than a list of app names, so any app
//  doing this is covered. Window bounds and owners need no Screen Recording permission.
//

import AppKit
import Combine

nonisolated enum NotchOccupancy {
    struct Window: Equatable {
        var ownerPID: Int32
        var layer: Int
        var bounds: CGRect
        var alpha: Double
    }

    /// Above the status items (25), so a menu bar icon beside the notch does not count; a notch app
    /// sits at the main menu's level + 3 or anywhere up to the screen saver's.
    static let lowestOccupyingLayer = 26
    static let smallestWidth: CGFloat = 60
    static let smallestHeight: CGFloat = 20

    /// Whether another app has a window over `zone` (top-left-origin screen coordinates).
    static func isOccupied(windows: [Window], zone: CGRect, ownPID: Int32, isSystemProcess: (Int32) -> Bool) -> Bool {
        windows.contains { window in
            window.ownerPID != ownPID
                && window.layer >= lowestOccupyingLayer
                && window.alpha > 0
                && window.bounds.width >= smallestWidth && window.bounds.height >= smallestHeight
                && window.bounds.intersects(zone)
                && !isSystemProcess(window.ownerPID)
        }
    }

    /// The middle of the top edge of the display with the hardware notch (else the main display),
    /// in the top-left-origin coordinates `CGWindowListCopyWindowInfo` reports.
    @MainActor static func zone() -> CGRect? {
        guard let primary = NSScreen.screens.first,
              let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.screens.first else { return nil }
        let top = primary.frame.maxY - screen.frame.maxY
        return CGRect(x: screen.frame.midX - 100, y: top, width: 200, height: max(screen.safeAreaInsets.top, 24))
    }

    static func currentWindows() -> [Window] {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return list.compactMap { entry in
            guard let pid = entry[kCGWindowOwnerPID as String] as? Int32,
                  let layer = entry[kCGWindowLayer as String] as? Int,
                  let boundsDictionary = entry[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDictionary) else { return nil }
            return Window(ownerPID: pid, layer: layer, bounds: bounds, alpha: entry[kCGWindowAlpha as String] as? Double ?? 1)
        }
    }

    static func isSystemProcess(_ pid: Int32) -> Bool {
        guard let bundleIdentifier = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier else { return true }
        return bundleIdentifier.hasPrefix("com.apple.")
    }
}

/// Decides from samples: the answer has to hold for two in a row, so a menu or an alert passing
/// over the notch for a moment does not move the island.
nonisolated struct NotchOccupancyDebouncer: Equatable {
    private(set) var isOccupied: Bool
    private var lastSample: Bool

    init(startingWith sample: Bool) {
        isOccupied = sample
        lastSample = sample
    }

    /// Returns true when the settled answer changed.
    mutating func take(_ sample: Bool) -> Bool {
        defer { lastSample = sample }
        guard sample == lastSample, sample != isOccupied else { return false }
        isOccupied = sample
        return true
    }
}

@MainActor
final class NotchOccupancyWatcher {
    private static let sampleInterval: TimeInterval = 4

    private var timer: Timer?
    private var debouncer = NotchOccupancyDebouncer(startingWith: false)
    private var onChange: ((Bool) -> Void)?

    var isOccupied: Bool { debouncer.isOccupied }

    /// Starts watching, and answers right away so launch does not flash the island in the notch.
    func start(onChange: @escaping (Bool) -> Void) {
        guard timer == nil else { return }
        self.onChange = onChange
        debouncer = NotchOccupancyDebouncer(startingWith: sample())
        let timer = Timer(timeInterval: Self.sampleInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        onChange = nil
        debouncer = NotchOccupancyDebouncer(startingWith: false)
    }

    private func tick() {
        if debouncer.take(sample()) { onChange?(debouncer.isOccupied) }
    }

    private func sample() -> Bool {
        guard let zone = NotchOccupancy.zone() else { return false }
        return NotchOccupancy.isOccupied(
            windows: NotchOccupancy.currentWindows(), zone: zone, ownPID: ProcessInfo.processInfo.processIdentifier,
            isSystemProcess: NotchOccupancy.isSystemProcess)
    }
}
