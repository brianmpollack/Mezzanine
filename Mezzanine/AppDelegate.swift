//
//  AppDelegate.swift
//  Mezzanine
//

import AppKit
import ApplicationServices
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem!
    private let panel = OverflowPanel()
    private let stripModel = StripModel()
    private var refreshTimer: Timer?
    private var glyphTimer: Timer?
    private var hiddenItems: [MenuBarItem] = []
    private var isPanelOpen = false
    private var isScanning = false
    private var hasRequestedScreenRecording = false
    /// Serial, because the scanner's empty-app cache expects one caller.
    private let scanQueue = DispatchQueue(label: "Mezzanine.scan",
                                          qos: .utility)

    /// How often we re-scan while idle. Cheap enough to be unnoticeable, and
    /// items appear or vanish whenever the frontmost app's menus change width.
    private let refreshInterval: TimeInterval = 2.0

    func applicationDidFinishLaunching(_ notification: Notification) {
        setUpStatusItem()
        requestAccessibilityPermissionIfNeeded()
        startRefreshing()
    }

    func applicationWillTerminate(_ notification: Notification) {
        refreshTimer?.invalidate()
        glyphTimer?.invalidate()
    }

    // MARK: - Status item

    private func setUpStatusItem() {
        pinStatusItemToRightEdge()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.autosaveName = Self.statusItemAutosaveName
        statusItem.button?.image = NSImage(
            systemSymbolName: "chevron.left.circle",
            accessibilityDescription: "Hidden menu bar icons"
        )
        statusItem.button?.imagePosition = .imageLeading
        statusItem.button?.target = self
        statusItem.button?.action = #selector(statusItemClicked)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    private static let statusItemAutosaveName = "MezzanineControl"

    /// macOS orders status items by a saved preferred position and drops the
    /// leftmost ones first. Ours is the one icon that must never be dropped —
    /// it's the way back to all the others.
    ///
    /// The saved position is measured leftwards from the right end of the bar,
    /// so 0 claims the rightmost slot available to a third-party item, just
    /// inboard of the system ones.
    private func pinStatusItemToRightEdge() {
        let key = "NSStatusItem Preferred Position \(Self.statusItemAutosaveName)"
        UserDefaults.standard.set(0, forKey: key)
    }

    @objc private func statusItemClicked() {
        if let event = NSApp.currentEvent, event.type == .rightMouseUp {
            showContextMenu()
        } else {
            togglePanel()
        }
    }

    private func showContextMenu() {
        let menu = NSMenu()
        menu.addItem(
            withTitle: "Mezzanine \(Bundle.main.shortVersion)",
            action: nil, keyEquivalent: ""
        ).isEnabled = false
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        // Attaching the menu makes the next click open it; detach right after so
        // left-clicks keep toggling the panel.
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    // MARK: - Panel

    private func togglePanel() {
        isPanelOpen ? closePanel() : openPanel()
    }

    private func openPanel() {
        guard AXIsProcessTrusted() else {
            requestAccessibilityPermissionIfNeeded(force: true)
            return
        }
        guard let button = statusItem.button else { return }

        // Show what the last scan found rather than blocking on a fresh one;
        // it's at most a couple of seconds old. This also starts the next scan.
        refresh()
        stripModel.items = hiddenItems

        let view = OverflowStripView(model: stripModel) { [weak self] item in
            self?.activate(item)
        }
        panel.show(view, below: button) { [weak self] in
            self?.closePanel()
        }
        isPanelOpen = true
        startGlyphRefresh()
    }

    private func closePanel() {
        guard isPanelOpen else { return }
        stopGlyphRefresh()
        panel.hide()
        isPanelOpen = false
    }

    // MARK: - Glyphs

    /// Captured glyphs go stale the moment an app redraws its icon — Docker's
    /// update badge, a sync spinner, a battery level. Re-capturing while the
    /// strip is open keeps what's on screen honest, including animation.
    private func startGlyphRefresh() {
        requestScreenRecordingIfNeeded()
        captureGlyphs()
        glyphTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            MainActor.assumeIsolated { self.captureGlyphs() }
        }
    }

    private func stopGlyphRefresh() {
        glyphTimer?.invalidate()
        glyphTimer = nil
    }

    /// Asked for on first use rather than at launch, so the prompt has context.
    /// macOS only shows the dialog once; after that it's System Settings.
    private func requestScreenRecordingIfNeeded() {
        guard !GlyphCapture.isAuthorized, !hasRequestedScreenRecording else { return }
        hasRequestedScreenRecording = true
        GlyphCapture.requestAccess()
    }

    private func captureGlyphs() {
        guard GlyphCapture.isAuthorized else { return }
        let items = stripModel.items
        Task { [weak self] in
            let captured = await GlyphCapture.glyphs(for: items)
            guard let self, !captured.isEmpty else { return }
            // Merge rather than replace, so an item that failed this round keeps
            // the glyph it had instead of flickering back to its app icon.
            self.stripModel.glyphs.merge(captured) { _, new in new }
        }
    }

    private func activate(_ item: MenuBarItem) {
        // Build the menu before dismissing the strip, so the click position is
        // still meaningful when we pop it up.
        let mirrored = MirroredMenu.build(for: item)
        let location = NSEvent.mouseLocation
        closePanel()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            if let mirrored {
                // The item has a menu. It can't open its own while hidden, so
                // show our copy instead — picking an entry is forwarded to the
                // real menu item.
                mirrored.popUp(positioning: nil, at: location, in: nil)
            } else if !item.press() {
                // No menu, and the click didn't take. Best effort.
                item.activateOwningApp()
            }
        }
    }

    // MARK: - Refresh

    private func startRefreshing() {
        refresh()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { _ in
            MainActor.assumeIsolated { self.refresh() }
        }
    }

    /// Scans on a background queue. The Accessibility round trips are far too
    /// slow to sit on the main thread — every unresponsive process costs us its
    /// full messaging timeout, and there are a lot of processes.
    private func refresh() {
        guard !isScanning else { return }
        isScanning = true

        let geometry = MenuBarGeometry()
        scanQueue.async {
            let scanned = MenuBarItemScanner.scanRaw(geometry: geometry)
            DispatchQueue.main.async {
                self.isScanning = false
                self.hiddenItems = MenuBarItemScanner.decorate(scanned).filter(\.isHidden)
                self.updateBadge()
            }
        }
    }

    private func updateBadge() {
        guard let button = statusItem.button else { return }
        let count = hiddenItems.count

        button.title = count > 0 ? " \(count)" : ""
        button.toolTip = count > 0
            ? "\(count) menu bar icon\(count == 1 ? "" : "s") hidden"
            : "No hidden menu bar icons"
        // Dim the chevron when there's nothing stashed away.
        button.appearsDisabled = count == 0
    }

    // MARK: - Permission

    /// Spelled out rather than read from `kAXTrustedCheckOptionPrompt`.
    ///
    /// The header declares it `extern CFStringRef` with no `const`, so Swift
    /// imports it as a mutable global and refuses to read it from an isolated
    /// context under strict concurrency — and there's no way to launder that:
    /// the reference itself is the violation, wherever you put it.
    ///
    /// The value has been this string since 10.9. To confirm it against the SDK
    /// you're building on:
    ///
    ///     echo 'import ApplicationServices
    ///     print(kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String)' | swift -
    static let axPromptOption = "AXTrustedCheckOptionPrompt"

    private func requestAccessibilityPermissionIfNeeded(force: Bool = false) {
        let trusted = AXIsProcessTrustedWithOptions(
            [Self.axPromptOption: true] as CFDictionary
        )
        guard !trusted else { return }

        if force {
            let alert = NSAlert()
            alert.messageText = "Accessibility access needed"
            alert.informativeText = """
                Mezzanine reads the menu bar through the Accessibility API \
                so it can find icons macOS has hidden and click them for you.

                Enable it under Privacy & Security ▸ Accessibility, then reopen the panel.
                """
            alert.addButton(withTitle: "Open Settings")
            alert.addButton(withTitle: "Later")
            NSApp.activate(ignoringOtherApps: true)
            if alert.runModal() == .alertFirstButtonReturn,
               let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                NSWorkspace.shared.open(url)
            }
        }
    }
}

private extension Bundle {
    var shortVersion: String {
        object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }
}
