#!/usr/bin/env swift

//
//  make-icon.swift
//  Mezzanine
//
//  Renders the app icon into Mezzanine/Assets.xcassets/AppIcon.appiconset.
//
//  The icon is the app's one gesture: the menu bar across the top, and the
//  mezzanine — the strip of icons the bar couldn't fit — floating below it.
//
//  Every size is drawn from the vector description rather than downscaled, so
//  the 16pt version keeps its edges. Run it after changing anything here:
//
//      swift scripts/make-icon.swift
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Geometry
//
// Everything is described against a 1024pt canvas and scaled on the way out.
// Apple's grid puts a macOS icon in the middle 824pt of that canvas, which is
// what keeps it the same visual weight as its neighbours in the Dock.

let canvas: CGFloat = 1024
let plateInset: CGFloat = 100
let plateSize: CGFloat = canvas - plateInset * 2
let plateTop: CGFloat = 96          // nudged up to leave room for the shadow
let plateCornerRadius: CGFloat = plateSize * 0.2246

func plateRect() -> CGRect {
    CGRect(x: plateInset, y: plateTop, width: plateSize, height: plateSize)
}

/// The continuous ("squircle") corner curve macOS uses, not a circular radius.
func squirclePath(in rect: CGRect, radius: CGFloat) -> CGPath {
    Path(roundedRect: rect, cornerRadius: radius, style: .continuous).cgPath
}

func color(_ hex: UInt32, alpha: CGFloat = 1) -> CGColor {
    CGColor(
        red: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: alpha
    )
}

let space = CGColorSpaceCreateDeviceRGB()

func gradient(_ stops: [(CGColor, CGFloat)]) -> CGGradient {
    CGGradient(
        colorsSpace: space,
        colors: stops.map { $0.0 } as CFArray,
        locations: stops.map { $0.1 }
    )!
}

// MARK: - Drawing

func drawIcon(in ctx: CGContext, scale: CGFloat) {
    ctx.saveGState()
    ctx.scaleBy(x: scale, y: scale)

    let plate = plateRect()
    let plateShape = squirclePath(in: plate, radius: plateCornerRadius)

    // Plate shadow. Soft and low, so the icon sits on the Dock rather than
    // hovering over it.
    ctx.saveGState()
    ctx.setShadow(
        offset: CGSize(width: 0, height: 20),
        blur: 34,
        color: color(0x000000, alpha: 0.35)
    )
    ctx.addPath(plateShape)
    ctx.setFillColor(color(0x1A2033))
    ctx.fillPath()
    ctx.restoreGState()

    // Everything from here on lives inside the plate.
    ctx.saveGState()
    ctx.addPath(plateShape)
    ctx.clip()

    // Background: a deep graphite-navy, lit from the top left.
    ctx.drawLinearGradient(
        gradient([(color(0x3C4766), 0), (color(0x232B44), 0.55), (color(0x161B2C), 1)]),
        start: CGPoint(x: plate.minX, y: plate.minY),
        end: CGPoint(x: plate.maxX, y: plate.maxY),
        options: []
    )

    // A cool glow behind the strip, to give the composition a center.
    let glowCenter = CGPoint(x: plate.midX + plate.width * 0.05, y: plate.minY + plate.height * 0.46)
    ctx.drawRadialGradient(
        gradient([(color(0x6E9CFF, alpha: 0.62), 0), (color(0x6E9CFF, alpha: 0), 1)]),
        startCenter: glowCenter,
        startRadius: 0,
        endCenter: glowCenter,
        endRadius: plate.width * 0.58,
        options: []
    )

    drawMenuBar(in: ctx, plate: plate)
    drawStrip(in: ctx, plate: plate)

    // Glass edge along the top of the plate.
    ctx.addPath(squirclePath(
        in: plate.insetBy(dx: 2, dy: 2),
        radius: plateCornerRadius - 2
    ))
    ctx.setStrokeColor(color(0xFFFFFF, alpha: 0.16))
    ctx.setLineWidth(3)
    ctx.strokePath()

    ctx.restoreGState()
    ctx.restoreGState()
}

/// The menu bar itself: a band across the top with a few icons crowded into
/// its right-hand end.
func drawMenuBar(in ctx: CGContext, plate: CGRect) {
    let bandHeight = plate.height * 0.17
    let band = CGRect(x: plate.minX, y: plate.minY, width: plate.width, height: bandHeight)

    ctx.saveGState()
    ctx.clip(to: band)
    ctx.drawLinearGradient(
        gradient([(color(0xFFFFFF, alpha: 0.27), 0), (color(0xFFFFFF, alpha: 0.15), 1)]),
        start: CGPoint(x: 0, y: band.minY),
        end: CGPoint(x: 0, y: band.maxY),
        options: []
    )
    ctx.restoreGState()

    // Hairline under the band.
    ctx.setFillColor(color(0x000000, alpha: 0.22))
    ctx.fill(CGRect(x: band.minX, y: band.maxY - 3, width: band.width, height: 3))

    // The icons that did fit, crowded into the right-hand end and fading out
    // to the left — the bar running out of room is the whole premise.
    let glyph: CGFloat = 44
    let gap: CGFloat = 32
    var x = band.maxX - 54 - glyph
    for i in 0..<5 {
        let rect = CGRect(x: x, y: band.midY - glyph / 2, width: glyph, height: glyph)
        ctx.addPath(squirclePath(in: rect, radius: glyph * 0.3))
        ctx.setFillColor(color(0xFFFFFF, alpha: 0.55 - CGFloat(i) * 0.09))
        ctx.fillPath()
        x -= glyph + gap
    }
}

/// The mezzanine: the strip of overflowed icons, floating below the bar.
func drawStrip(in ctx: CGContext, plate: CGRect) {
    let height = plate.height * 0.245
    let width = plate.width * 0.76
    let strip = CGRect(
        // Hung just under the bar and biased right, the way the real strip sits
        // under the status item rather than in the middle of the screen.
        x: plate.midX - width / 2 + plate.width * 0.045,
        y: plate.minY + plate.height * 0.335,
        width: width,
        height: height
    )
    let shape = squirclePath(in: strip, radius: height * 0.32)

    // Shadow first, so the strip reads as floating over the plate.
    ctx.saveGState()
    ctx.setShadow(
        offset: CGSize(width: 0, height: 16),
        blur: 40,
        color: color(0x000814, alpha: 0.55)
    )
    ctx.addPath(shape)
    ctx.setFillColor(color(0xFFFFFF))
    ctx.fillPath()
    ctx.restoreGState()

    // Face: near-white, very slightly cooled towards the bottom.
    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    ctx.drawLinearGradient(
        gradient([(color(0xFFFFFF), 0), (color(0xE8EDF7), 1)]),
        start: CGPoint(x: 0, y: strip.minY),
        end: CGPoint(x: 0, y: strip.maxY),
        options: []
    )
    ctx.restoreGState()

    // Four icons in the strip, in the plate's own ink.
    let glyph = height * 0.40
    let pitch = strip.width / 4
    for i in 0..<4 {
        let center = CGPoint(x: strip.minX + pitch * (CGFloat(i) + 0.5), y: strip.midY)
        let rect = CGRect(
            x: center.x - glyph / 2,
            y: center.y - glyph / 2,
            width: glyph,
            height: glyph
        )
        ctx.addPath(squirclePath(in: rect, radius: glyph * 0.3))
        ctx.setFillColor(color(0x2A3350, alpha: 0.92))
        ctx.fillPath()
    }
}

// MARK: - Output

func render(size: CGFloat) -> CGImage {
    let pixels = Int(size)
    let ctx = CGContext(
        data: nil,
        width: pixels,
        height: pixels,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: space,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!

    // Flip to a top-left origin, which is how the geometry above is written.
    ctx.translateBy(x: 0, y: CGFloat(pixels))
    ctx.scaleBy(x: 1, y: -1)
    ctx.setAllowsAntialiasing(true)
    ctx.interpolationQuality = .high

    drawIcon(in: ctx, scale: size / canvas)
    return ctx.makeImage()!
}

func write(_ image: CGImage, to url: URL) {
    let dest = CGImageDestinationCreateWithURL(
        url as CFURL, UTType.png.identifier as CFString, 1, nil
    )!
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else {
        FileHandle.standardError.write("failed to write \(url.path)\n".data(using: .utf8)!)
        exit(1)
    }
}

/// (point size, scale) pairs macOS asks for.
let variants: [(points: Int, scale: Int)] = [
    (16, 1), (16, 2),
    (32, 1), (32, 2),
    (128, 1), (128, 2),
    (256, 1), (256, 2),
    (512, 1), (512, 2),
]

let root = URL(fileURLWithPath: CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : FileManager.default.currentDirectoryPath)
let iconSet = root
    .appendingPathComponent("Mezzanine/Assets.xcassets/AppIcon.appiconset")

guard FileManager.default.fileExists(atPath: iconSet.path) else {
    FileHandle.standardError.write("no icon set at \(iconSet.path)\n".data(using: .utf8)!)
    exit(1)
}

// Each pixel size is rendered once, however many entries reference it.
var rendered: [Int: CGImage] = [:]
var entries: [String] = []

for variant in variants {
    let pixels = variant.points * variant.scale
    let image = rendered[pixels] ?? render(size: CGFloat(pixels))
    rendered[pixels] = image

    let name = "icon_\(pixels).png"
    write(image, to: iconSet.appendingPathComponent(name))
    entries.append("""
        {
          "filename" : "\(name)",
          "idiom" : "mac",
          "scale" : "\(variant.scale)x",
          "size" : "\(variant.points)x\(variant.points)"
        }
    """)
}

let contents = """
{
  "images" : [
\(entries.joined(separator: ",\n"))
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}

"""
try contents.write(
    to: iconSet.appendingPathComponent("Contents.json"),
    atomically: true,
    encoding: .utf8
)

print("wrote \(rendered.count) images to \(iconSet.path)")
