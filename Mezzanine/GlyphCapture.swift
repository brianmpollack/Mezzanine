//
//  GlyphCapture.swift
//  Mezzanine
//
//  Grabs the real menu bar glyph for each hidden item.
//
//  A hidden status item still owns a live window with a valid backing store —
//  macOS just isn't compositing it. ScreenCaptureKit will hand us that window's
//  contents anyway, which is how we show the actual icon (with whatever badge or
//  state the app has drawn into it) instead of substituting the app's icon.
//
//  This is the one feature that needs Screen Recording permission. Without it we
//  fall back to app icons and everything else still works.
//

import AppKit
import ScreenCaptureKit

@MainActor
enum GlyphCapture {

    /// True when we're allowed to read the menu bar's pixels.
    static var isAuthorized: Bool { CGPreflightScreenCaptureAccess() }

    /// Prompts for Screen Recording. macOS only shows the dialog once per app;
    /// after that the user has to grant it in System Settings themselves.
    @discardableResult
    static func requestAccess() -> Bool { CGRequestScreenCaptureAccess() }

    /// Captures the on-screen glyph for each item, keyed by item id. Items whose
    /// window can't be found or captured are simply absent from the result, and
    /// the strip falls back to their app icon.
    static func glyphs(for items: [MenuBarItem]) async -> [String: NSImage] {
        guard isAuthorized, !items.isEmpty else { return [:] }

        let windowIDs = statusItemWindowIDs()
        guard !windowIDs.isEmpty else { return [:] }

        // One listing serves the whole batch; fetching it per item is slow.
        guard let content = try? await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: false
        ) else { return [:] }

        var result: [String: NSImage] = [:]
        for item in items {
            guard let id = windowID(matching: item, in: windowIDs),
                  let window = content.windows.first(where: { $0.windowID == id }),
                  let image = await capture(window)
            else { continue }
            result[item.id] = image
        }
        return result
    }

    // MARK: - Matching items to windows

    /// Status item windows sit at the status window level. We only need their
    /// bounds, which are readable without Screen Recording.
    private static func statusItemWindowIDs() -> [(id: CGWindowID, centerX: CGFloat)] {
        guard let infos = CGWindowListCopyWindowInfo(
            [.optionAll, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else { return [] }

        let statusLevel = Int(CGWindowLevelForKey(.statusWindow))
        return infos.compactMap { info in
            guard (info[kCGWindowLayer as String] as? Int) == statusLevel,
                  let id = info[kCGWindowNumber as String] as? CGWindowID,
                  let bounds = info[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = bounds["X"], let width = bounds["Width"], width > 0
            else { return nil }
            return (id, x + width / 2)
        }
    }

    /// The window is a few points wider than the Accessibility element, but the
    /// two are centered on each other exactly, so match on center x.
    private static func windowID(
        matching item: MenuBarItem,
        in windows: [(id: CGWindowID, centerX: CGFloat)]
    ) -> CGWindowID? {
        let target = item.frame.midX
        guard let best = windows.min(by: {
            abs($0.centerX - target) < abs($1.centerX - target)
        }), abs(best.centerX - target) <= 4 else { return nil }
        return best.id
    }

    // MARK: - Capture

    private static func capture(_ window: SCWindow) async -> NSImage? {
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let configuration = SCStreamConfiguration()
        configuration.width = Int(window.frame.width * scale)
        configuration.height = Int(window.frame.height * scale)
        configuration.showsCursor = false
        configuration.ignoreShadowsSingleWindow = true
        configuration.captureResolution = .best

        let filter = SCContentFilter(desktopIndependentWindow: window)
        guard let cgImage = try? await SCScreenshotManager.captureImage(
            contentFilter: filter, configuration: configuration
        ) else { return nil }

        // The window is padded well beyond the glyph. Trim to the drawn pixels
        // so it can be sized like a native menu bar image instead of shrinking
        // to fit its own empty margins.
        let trimmed = trimToContent(cgImage) ?? cgImage
        let size = NSSize(width: CGFloat(trimmed.width) / scale,
                          height: CGFloat(trimmed.height) / scale)
        let image = NSImage(cgImage: trimmed, size: size)
        // Already the right color for the current menu bar; don't let AppKit or
        // SwiftUI re-tint it as a template, which flips white glyphs to dark.
        image.isTemplate = false
        return image
    }

    /// Crops fully transparent rows and columns from the edges.
    private static func trimToContent(_ image: CGImage) -> CGImage? {
        let width = image.width, height = image.height
        guard width > 0, height > 0 else { return nil }

        var alpha = [UInt8](repeating: 0, count: width * height)
        guard let context = CGContext(
            data: &alpha, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue
        ) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        var minX = width, maxX = -1, minY = height, maxY = -1
        for y in 0..<height {
            let row = y * width
            for x in 0..<width where alpha[row + x] > 8 {
                if x < minX { minX = x }
                if x > maxX { maxX = x }
                if y < minY { minY = y }
                if y > maxY { maxY = y }
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }

        // A little breathing room so glyphs don't look clipped.
        let pad = 1
        let rect = CGRect(
            x: max(0, minX - pad), y: max(0, minY - pad),
            width: min(width, maxX + pad + 1) - max(0, minX - pad),
            height: min(height, maxY + pad + 1) - max(0, minY - pad)
        )
        return image.cropping(to: rect)
    }
}
