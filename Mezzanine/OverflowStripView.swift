//
//  OverflowStripView.swift
//  Mezzanine
//
//  The floating strip of hidden menu bar icons.
//

import Combine
import SwiftUI

/// Backs the strip so captured glyphs can replace the placeholder app icons as
/// they arrive, and refresh underneath the user while the strip is open.
@MainActor
final class StripModel: ObservableObject {
    @Published var items: [MenuBarItem] = []
    @Published var glyphs: [String: NSImage] = [:]
}

struct OverflowStripView: View {
    @ObservedObject var model: StripModel
    let onSelect: (MenuBarItem) -> Void

    /// Past this many icons the strip stops growing and starts scrolling.
    private static let maxVisibleIcons = 14
    /// Dimensions measured off the Bartender Bar: a 33pt-tall row with roughly
    /// 38pt per icon, so it reads as a continuation of the menu bar rather than
    /// a popover.
    private static let barHeight: CGFloat = 33
    private static let cellWidth: CGFloat = 38
    private static let glyphHeight: CGFloat = 18
    private static let cornerRadius: CGFloat = 9

    @State private var hoveredID: String?

    var body: some View {
        Group {
            if model.items.isEmpty {
                Text("No hidden menu bar icons")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.7))
                    .padding(.horizontal, 14)
                    .frame(height: Self.barHeight)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 2) {
                        ForEach(model.items) { item in
                            iconCell(for: item)
                        }
                    }
                    .padding(.horizontal, 8)
                }
                .frame(width: stripWidth, height: Self.barHeight)
            }
        }
        // The menu bar renders as a dark translucent scrim over the desktop,
        // and the glyphs we capture are colored to sit on that. `.bar` material
        // resolves light here and would leave white glyphs invisible, so match
        // the bar's own treatment directly.
        .background {
            RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                .fill(.black.opacity(0.22))
                .background(.ultraThinMaterial.opacity(0.35),
                            in: RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
        }
        .overlay(
            RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 0.5)
        )
        .fixedSize()
    }

    private var stripWidth: CGFloat {
        let count = min(model.items.count, Self.maxVisibleIcons)
        return CGFloat(count) * Self.cellWidth + 16
    }

    private func iconCell(for item: MenuBarItem) -> some View {
        Button {
            onSelect(item)
        } label: {
            artwork(for: item)
                .frame(width: Self.cellWidth, height: Self.barHeight - 4)
                .background {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(hoveredID == item.id ? AnyShapeStyle(.selection) : AnyShapeStyle(.clear))
                }
                .contentShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hoveredID = $0 ? item.id : (hoveredID == item.id ? nil : hoveredID) }
        .help(helpText(for: item))
        .accessibilityLabel(item.appName)
    }

    @ViewBuilder
    private func artwork(for item: MenuBarItem) -> some View {
        if let glyph = model.glyphs[item.id] {
            // The real menu bar glyph, captured from the item's own window. It
            // already carries the app's current state and light/dark styling.
            Image(nsImage: glyph)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: Self.cellWidth - 12, maxHeight: Self.glyphHeight)
        } else if let icon = item.icon {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .frame(width: Self.glyphHeight + 2, height: Self.glyphHeight + 2)
        } else {
            Image(systemName: "app.dashed")
                .font(.system(size: Self.glyphHeight - 2))
                .foregroundStyle(.secondary)
        }
    }

    private func helpText(for item: MenuBarItem) -> String {
        guard let tooltip = item.tooltip?.trimmingCharacters(in: .whitespacesAndNewlines),
              !tooltip.isEmpty, tooltip != item.appName
        else { return item.appName }
        return "\(item.appName) — \(tooltip)"
    }
}
