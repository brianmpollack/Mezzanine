//
//  MenuBarItemScanner.swift
//  Mezzanine
//
//  Finds every status item on the menu bar and works out which ones macOS
//  has dropped because they didn't fit.
//

import AppKit
import ApplicationServices
import Synchronization

/// One status item belonging to some running app.
struct MenuBarItem: Identifiable {
    let id: String
    let appName: String
    let bundleIdentifier: String?
    let icon: NSImage?
    /// Extra detail some apps expose (Nextcloud puts its sync status here).
    let tooltip: String?
    /// Screen frame in Accessibility coordinates. `.zero`-sized when dropped.
    let frame: CGRect
    let isHidden: Bool
    let processIdentifier: pid_t

    let element: AXUIElement

    init(id: String, appName: String, bundleIdentifier: String?, icon: NSImage?,
         tooltip: String?, frame: CGRect, isHidden: Bool,
         processIdentifier: pid_t, element: AXUIElement) {
        self.id = id
        self.appName = appName
        self.bundleIdentifier = bundleIdentifier
        self.icon = icon
        self.tooltip = tooltip
        self.frame = frame
        self.isHidden = isHidden
        self.processIdentifier = processIdentifier
        self.element = element
    }

    /// Where a synthetic click or drag should aim for this item.
    var center: CGPoint { CGPoint(x: frame.midX, y: frame.midY) }

    /// Apple's own extras behave differently under a drag and shouldn't be
    /// volunteered as donors when we're making room.
    var isSystemItem: Bool { bundleIdentifier?.hasPrefix("com.apple.") ?? false }

    /// Clicks the real status item.
    ///
    /// Succeeds for items that run a target/action on click, even while they're
    /// hidden, because the press is delivered to the owning app rather than to a
    /// screen coordinate. Items that instead open an `NSMenu` fail with
    /// `kAXErrorCannotComplete` while hidden: AppKit has nowhere on screen to
    /// anchor the menu. Callers should fall back when this returns false.
    @discardableResult
    func press() -> Bool {
        // Don't block the main thread if the owning app is mid-tracking-loop.
        AXUIElementSetMessagingTimeout(element, 1.0)
        return AXUIElementPerformAction(element, kAXPressAction as CFString) == .success
    }

    /// Last resort when the item itself can't be opened: bring its app forward.
    func activateOwningApp() {
        guard let bundleIdentifier,
              let app = NSRunningApplication.runningApplications(
                withBundleIdentifier: bundleIdentifier).first
        else { return }
        app.activate()
    }
}

/// What a scan finds before it's been dressed up with app names and icons.
/// AXUIElement is a CF type without Sendable annotations, but the references
/// are only read, never mutated, so carrying them across queues is safe.
///
/// `nonisolated` so the background scan can build these: under the project's
/// default main-actor isolation even the memberwise initializer would otherwise
/// belong to the main actor, which defeats the point of the type.
nonisolated struct ScannedItem: @unchecked Sendable {
    let processIdentifier: pid_t
    let index: Int
    let frame: CGRect
    let isHidden: Bool
    let tooltip: String?
    let element: AXUIElement
}

enum MenuBarItemScanner {

    // The project builds with `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, so
    // anything not marked otherwise is main-actor isolated. `scanRaw` runs off
    // the main thread, which makes every piece of state it touches explicitly
    // `nonisolated` — safely, because each one below is either immutable or
    // locked.

    /// Our own status item, so we never list ourselves.
    nonisolated private static let ownBundleID = Bundle.main.bundleIdentifier

    /// Asking an app that has no menu bar extras still costs a full round trip,
    /// and on a typical Mac that's ~120 of the ~130 running processes — the bulk
    /// of the scan. Remember which ones came back empty and stop asking, but
    /// re-check periodically so an app that adds an item later still shows up.
    ///
    /// Locked rather than left to a single-caller convention: the convention was
    /// invisible at the call site, and nothing stopped a second caller from
    /// quietly corrupting the dictionary from another thread.
    nonisolated private static let knownEmpty = Mutex<[pid_t: Int]>([:])
    nonisolated private static let recheckAfterScans = 15

    /// Long enough for a healthy app to answer, short enough that a wedged one
    /// costs milliseconds instead of half a second. Some processes never reply
    /// at all and would otherwise dominate the whole scan.
    nonisolated private static let messagingTimeout: Float = 0.1

    /// The expensive part: pure Accessibility queries, safe to run off the main
    /// thread.
    nonisolated static func scanRaw(geometry: MenuBarGeometry) -> [ScannedItem] {
        guard AXIsProcessTrusted() else { return [] }

        var items: [ScannedItem] = []
        var live: Set<pid_t> = []

        // Taken as a snapshot and written back once, rather than holding the
        // lock across several hundred Accessibility round trips. Two scans
        // overlapping would cost one of them its recorded misses, which is only
        // ever a few redundant queries next time — it's a cache, not state the
        // results depend on.
        var empty = knownEmpty.withLock { $0 }

        for app in NSWorkspace.shared.runningApplications {
            // Background-only processes can't put anything in the menu bar.
            guard app.activationPolicy != .prohibited else { continue }
            guard app.bundleIdentifier != ownBundleID else { continue }

            let pid = app.processIdentifier
            live.insert(pid)

            if let misses = empty[pid], misses < recheckAfterScans {
                empty[pid] = misses + 1
                continue
            }

            let appElement = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(appElement, messagingTimeout)
            guard let extrasBar: AXUIElement = copyAttribute(appElement, "AXExtrasMenuBar"),
                  let children: [AXUIElement] = copyAttribute(extrasBar, kAXChildrenAttribute),
                  !children.isEmpty
            else {
                // Seed the counter randomly so the re-checks spread across
                // scans instead of every empty app coming due on the same one.
                empty[pid] = Int.random(in: 0..<recheckAfterScans)
                continue
            }
            empty[pid] = nil

            let isControlCenter = app.bundleIdentifier == "com.apple.controlcenter"
            for (index, element) in children.enumerated() {
                let frame = frameOf(element)
                let hidden = geometry.isHidden(frame)

                // Control Center keeps a pool of zero-sized placeholders for
                // modules the user has switched off. Those aren't overflow.
                if hidden && isControlCenter { continue }

                items.append(
                    ScannedItem(
                        processIdentifier: pid,
                        index: index,
                        frame: frame,
                        isHidden: hidden,
                        // Only hidden items get shown in the strip, so only they
                        // need a tooltip — these two reads aren't cheap.
                        tooltip: hidden
                            ? copyAttribute(element, kAXHelpAttribute)
                                ?? copyAttribute(element, kAXDescriptionAttribute)
                            : nil,
                        element: element
                    )
                )
            }
        }

        // Drop apps that have quit, so the cache can't grow without bound across
        // a long uptime.
        knownEmpty.withLock { $0 = empty.filter { live.contains($0.key) } }
        return items
    }

    /// Attaches the owning app's name and icon. Cheap, and touches AppKit, so
    /// it belongs on the main thread.
    static func decorate(_ scanned: [ScannedItem]) -> [MenuBarItem] {
        var appsByPID: [pid_t: NSRunningApplication] = [:]
        for app in NSWorkspace.shared.runningApplications {
            appsByPID[app.processIdentifier] = app
        }

        let items = scanned.map { raw in
            let app = appsByPID[raw.processIdentifier]
            return MenuBarItem(
                id: "\(raw.processIdentifier).\(raw.index)",
                appName: app?.localizedName ?? "Unknown",
                bundleIdentifier: app?.bundleIdentifier,
                icon: app?.icon,
                tooltip: raw.tooltip,
                frame: raw.frame,
                isHidden: raw.isHidden,
                processIdentifier: raw.processIdentifier,
                element: raw.element
            )
        }

        // Left-to-right, matching the menu bar. Dropped items have no position,
        // so park them after the positioned ones and sort those by name.
        return items.sorted { a, b in
            switch (a.isHidden, b.isHidden) {
            case (false, false): return a.frame.minX < b.frame.minX
            case (true, true):   return a.appName.localizedStandardCompare(b.appName) == .orderedAscending
            case (false, true):  return true
            case (true, false):  return false
            }
        }
    }

    // There was a `scan()` here that chained `scanRaw` into `decorate` in one
    // call. Nothing used it, and being main-actor isolated it would have run a
    // ~20ms Accessibility sweep on the main thread. Scans go through
    // `scanRaw` on a background queue and `decorate` on the main one.

    nonisolated private static func frameOf(_ element: AXUIElement) -> CGRect {
        var origin = CGPoint.zero
        var size = CGSize.zero
        if let value: AXValue = copyAttribute(element, kAXPositionAttribute) {
            AXValueGetValue(value, .cgPoint, &origin)
        }
        if let value: AXValue = copyAttribute(element, kAXSizeAttribute) {
            AXValueGetValue(value, .cgSize, &size)
        }
        return CGRect(origin: origin, size: size)
    }

    nonisolated private static func copyAttribute<T>(_ element: AXUIElement, _ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success
        else { return nil }
        return value as? T
    }
}

/// Describes the strip of menu bar that macOS will actually draw status items
/// into, so we can tell a rendered item from a dropped one.
///
/// Measured behavior on a notched display: once the status items overflow,
/// macOS keeps assigning them ever-smaller x positions — through the notch and
/// on into the left half of the bar — but only ever *draws* the ones that fit
/// entirely to the right of the notch. So an item's reported position is not
/// evidence that it is on screen; containment in the drawable region is.
///
/// Every attached display gets its own entry. The menu bar follows the display
/// you're working on, so measuring against a single hardcoded screen reports
/// every item as hidden the moment you use a second monitor — items on a
/// display left of the primary have negative x and fall outside it.
struct MenuBarGeometry: Sendable {

    /// One display's menu bar, in Accessibility coordinates (origin top-left of
    /// the primary display, y growing down).
    private struct Display: Sendable {
        /// The whole screen, used to work out which display an item is on.
        let bounds: CGRect
        /// The part of that screen's menu bar status items are drawn into.
        let drawable: CGRect
    }

    private let displays: [Display]

    init() {
        // Cocoa measures up from the bottom-left of the primary display;
        // Accessibility measures down from its top-left.
        let flipOrigin = NSScreen.screens
            .first { $0.frame.origin == .zero }?.frame.maxY
            ?? NSScreen.main?.frame.maxY ?? 0

        displays = NSScreen.screens.map { screen in
            let top = flipOrigin - screen.frame.maxY
            let bounds = CGRect(x: screen.frame.minX, y: top,
                                width: screen.frame.width, height: screen.frame.height)

            let barHeight = screen.safeAreaInsets.top > 0
                ? screen.safeAreaInsets.top
                : NSStatusBar.system.thickness

            let drawable: CGRect
            if let rightArea = screen.auxiliaryTopRightArea {
                // Notched display: everything left of the notch belongs to the
                // app's menus, so only the right-hand area can show status items.
                drawable = CGRect(x: rightArea.minX, y: top,
                                  width: rightArea.width, height: barHeight)
            } else {
                drawable = CGRect(x: screen.frame.minX, y: top,
                                  width: screen.frame.width, height: barHeight)
            }
            return Display(bounds: bounds, drawable: drawable)
        }
    }

    /// True when macOS isn't drawing this item where the user could click it.
    nonisolated func isHidden(_ frame: CGRect) -> Bool {
        // A switched-off item is collapsed to zero size and parked off screen.
        if frame.width <= 0 || frame.height <= 0 { return true }

        // Measure against the display the item is actually on. Falling off every
        // display means it's been pushed past the end of the bar entirely.
        guard let display = displays.first(where: { $0.bounds.contains(frame.origin) })
        else { return true }

        // Otherwise it shows only if it fits entirely inside the drawable strip.
        let span = CGRect(x: frame.minX, y: display.drawable.minY,
                          width: frame.width, height: 1)
        return !display.drawable.contains(span)
    }
}
