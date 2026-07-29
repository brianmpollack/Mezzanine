//
//  OverflowPanel.swift
//  Mezzanine
//
//  A borderless floating panel that drops down from our status item.
//

import AppKit
import SwiftUI

final class OverflowPanel: NSPanel {

    private var dismissMonitor: Any?
    private var onDismiss: (() -> Void)?

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 40),
            // .nonactivatingPanel keeps our app in the background, so pressing an
            // icon hands focus straight to the app that owns it.
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        // Menu level, matching where Bartender puts its bar — above the status
        // items so it can't end up behind them, and above ordinary windows.
        level = .popUpMenu
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        isMovable = false
        // Follow the user onto other Spaces and over full-screen apps.
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        animationBehavior = .utilityWindow
    }

    /// Borderless panels are refused key status by default; we need it so the
    /// strip can take clicks without activating the app.
    override var canBecomeKey: Bool { true }

    func show<Content: View>(
        _ content: Content,
        below statusItemButton: NSStatusBarButton,
        onDismiss: @escaping () -> Void
    ) {
        self.onDismiss = onDismiss

        // Lay the strip out before measuring it. Leaving this to
        // `sizingOptions` resizes the window a tick later, after we've already
        // positioned it, which walks the panel off the right edge of the screen.
        let hosting = NSHostingView(rootView: content)
        hosting.layoutSubtreeIfNeeded()
        let contentSize = hosting.fittingSize

        contentView = hosting
        setContentSize(contentSize)
        position(below: statusItemButton)
        orderFrontRegardless()
        installDismissMonitor()
    }

    func hide() {
        removeDismissMonitor()
        orderOut(nil)
    }

    /// Sits directly under the menu bar, centered on our own status item so the
    /// icons appear where the pointer already is.
    private func position(below button: NSStatusBarButton) {
        guard let buttonWindow = button.window,
              let screen = buttonWindow.screen ?? NSScreen.main else { return }
        let size = frame.size

        // Vertical spacing measured off Bartender: 5pt below a 32pt menu bar.
        let gapBelowMenuBar: CGFloat = 5
        let margin: CGFloat = 10

        let menuBarHeight = screen.safeAreaInsets.top > 0
            ? screen.safeAreaInsets.top
            : NSStatusBar.system.thickness

        // Cocoa's y grows upwards from the bottom of the screen.
        let y = screen.frame.maxY - menuBarHeight - gapBelowMenuBar - size.height

        // Center on the button, then keep the whole bar on screen — with enough
        // icons it grows past the edge and has to slide inwards.
        var x = buttonWindow.frame.midX - size.width / 2
        x = min(x, screen.frame.maxX - size.width - margin)
        x = max(x, screen.frame.minX + margin)

        setFrameOrigin(NSPoint(x: x, y: y))
    }

    private func installDismissMonitor() {
        removeDismissMonitor()
        // A click outside the panel closes it, the way a real menu behaves.
        //
        // The monitor sees clicks on the panel itself too, because a
        // non-activating panel never makes us the active app. Dismissing on
        // those would tear the panel down on mouse-down and the button would
        // never receive its mouse-up, so hit-test before closing.
        dismissMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            guard let self else { return }
            guard !self.frame.contains(NSEvent.mouseLocation) else { return }
            self.onDismiss?()
        }
    }

    private func removeDismissMonitor() {
        if let monitor = dismissMonitor {
            NSEvent.removeMonitor(monitor)
            dismissMonitor = nil
        }
    }

    override func resignKey() {
        super.resignKey()
        onDismiss?()
    }

    /// `isolated` so it can reach `dismissMonitor` at all: the panel is
    /// main-actor isolated, a plain `deinit` is not, and the monitor token is an
    /// opaque non-Sendable `Any?`.
    ///
    /// `hide()` already removes the monitor, and the one panel we make lives as
    /// long as the app does, so this is a net rather than a path anything takes.
    isolated deinit {
        if let dismissMonitor { NSEvent.removeMonitor(dismissMonitor) }
    }
}
