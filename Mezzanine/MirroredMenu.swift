//
//  MirroredMenu.swift
//  Mezzanine
//
//  Rebuilds a hidden status item's menu as one of our own.
//
//  A hidden item can't be pressed — AppKit won't open an NSMenu with nowhere on
//  screen to anchor it. But the menu's *contents* stay readable through the
//  Accessibility API whether the item is drawn or not, and the individual
//  AXMenuItems can be pressed directly. So instead of trying to make the real
//  item visible, we copy its menu, show that from our own icon, and forward the
//  chosen item back to the app.
//

import AppKit
import ApplicationServices

@MainActor
enum MirroredMenu {

    /// Builds a copy of `item`'s menu, or nil if it has none — items that run a
    /// target/action on click have no menu to mirror and should just be pressed.
    static func build(for item: MenuBarItem) -> NSMenu? {
        guard let source = menuElement(of: item.element) else { return nil }
        let menu = NSMenu()
        // We're copying state the other app already decided on, so AppKit must
        // not run its own validation — left on, it grays out anything whose
        // action it can't validate, submenu parents included.
        menu.autoenablesItems = false
        menu.addHeader(item.appName)
        populate(menu, from: source)
        return menu.items.isEmpty ? nil : menu
    }

    // MARK: - Reading the original

    /// A status item's menu hangs off it as a single AXMenu child.
    private static func menuElement(of statusItem: AXUIElement) -> AXUIElement? {
        guard let children: [AXUIElement] = copy(statusItem, kAXChildrenAttribute) else { return nil }
        return children.first { (copy($0, kAXRoleAttribute) as String?) == kAXMenuRole }
    }

    private static func populate(_ menu: NSMenu, from source: AXUIElement) {
        guard let entries: [AXUIElement] = copy(source, kAXChildrenAttribute) else { return }

        for entry in entries {
            let title = (copy(entry, kAXTitleAttribute) as String?) ?? ""

            // AppKit exposes separators as untitled menu items.
            guard !title.isEmpty else {
                menu.addItem(.separator())
                continue
            }

            let mirrored = MirroredMenuItem(title: title, element: entry)
            mirrored.isEnabled = (copy(entry, kAXEnabledAttribute) as Bool?) ?? true
            if let mark = copy(entry, kAXMenuItemMarkCharAttribute) as String?, !mark.isEmpty {
                mirrored.state = .on
            }
            applyShortcut(from: entry, to: mirrored)

            // A submenu shows up as an AXMenu child of the item.
            if let submenuSource = menuElement(of: entry) {
                let submenu = NSMenu()
                submenu.autoenablesItems = false
                populate(submenu, from: submenuSource)
                if !submenu.items.isEmpty {
                    mirrored.submenu = submenu
                    // Parents of submenus open them rather than acting themselves.
                    mirrored.action = nil
                    mirrored.isEnabled = true
                }
            }

            menu.addItem(mirrored)
        }
    }

    private static func applyShortcut(from entry: AXUIElement, to item: NSMenuItem) {
        guard let key = copy(entry, kAXMenuItemCmdCharAttribute) as String?, !key.isEmpty
        else { return }
        item.keyEquivalent = key.lowercased()

        // Command is implied unless the "no command" bit is set.
        let raw = (copy(entry, kAXMenuItemCmdModifiersAttribute) as Int?) ?? 0
        var flags: NSEvent.ModifierFlags = raw & 0x8 != 0 ? [] : [.command]
        if raw & 0x1 != 0 { flags.insert(.shift) }
        if raw & 0x2 != 0 { flags.insert(.option) }
        if raw & 0x4 != 0 { flags.insert(.control) }
        item.keyEquivalentModifierMask = flags
    }

    private static func copy<T>(_ element: AXUIElement, _ attribute: String) -> T? {
        // Built on the main thread in response to a click, so keep it snappy —
        // a deep menu means a lot of these round trips.
        AXUIElementSetMessagingTimeout(element, 0.2)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success
        else { return nil }
        return value as? T
    }
}

/// A menu item that remembers the real AXMenuItem it stands for, so choosing it
/// can be handed straight back to the owning app.
///
/// `nonisolated` because `NSMenuItem`'s designated initializers are, and the
/// project's default main-actor isolation would otherwise put the override on a
/// different actor from the declaration it overrides. Nothing here touches
/// isolated state — it stores an element and presses it.
nonisolated final class MirroredMenuItem: NSMenuItem {

    private let element: AXUIElement

    init(title: String, element: AXUIElement) {
        self.element = element
        super.init(title: title, action: #selector(invoke), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("not supported") }

    @objc private func invoke() {
        AXUIElementSetMessagingTimeout(element, 1.0)
        AXUIElementPerformAction(element, kAXPressAction as CFString)
    }
}

private extension NSMenu {
    /// Keeps the owning app's name visible at the top, since the menu is no
    /// longer attached to that app's own icon.
    func addHeader(_ appName: String) {
        let header = NSMenuItem(title: appName, action: nil, keyEquivalent: "")
        header.isEnabled = false
        addItem(header)
        addItem(.separator())
    }
}
