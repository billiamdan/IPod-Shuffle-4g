// SPDX-FileCopyrightText: 2026 billiamdan
// SPDX-License-Identifier: GPL-2.0-or-later

// Draws the app icon and writes it as an .iconset folder (turned into .icns by `iconutil`).
// usage: swift scripts/make-icon.swift <output.iconset>
import AppKit

func drawIcon(size: CGFloat) -> NSBitmapImageRep {
    let pixels = Int(size)
    let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    let context = NSGraphicsContext.current!.cgContext
    let unit = size / 1024

    // Rounded square in the proportions macOS icons use, with a soft shadow.
    let body = CGRect(x: 100 * unit, y: 100 * unit, width: 824 * unit, height: 824 * unit)
    let shape = CGPath(roundedRect: body, cornerWidth: 185 * unit, cornerHeight: 185 * unit, transform: nil)
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -12 * unit), blur: 28 * unit, color: NSColor.black.withAlphaComponent(0.35).cgColor)
    context.addPath(shape)
    context.setFillColor(NSColor.black.cgColor)
    context.fillPath()
    context.restoreGState()

    context.saveGState()
    context.addPath(shape)
    context.clip()
    let gradient = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [NSColor(red: 0.20, green: 0.78, blue: 0.80, alpha: 1).cgColor, NSColor(red: 0.10, green: 0.42, blue: 0.86, alpha: 1).cgColor] as CFArray,
        locations: [0, 1]
    )!
    context.drawLinearGradient(gradient, start: CGPoint(x: body.midX, y: body.maxY), end: CGPoint(x: body.midX, y: body.minY), options: [])
    context.restoreGState()

    // A control ring: white disc, tinted centre button.
    let center = CGPoint(x: size / 2, y: size / 2)
    func disc(_ radius: CGFloat, _ color: NSColor) {
        context.setFillColor(color.cgColor)
        context.fillEllipse(in: CGRect(x: center.x - radius * unit, y: center.y - radius * unit, width: 2 * radius * unit, height: 2 * radius * unit))
    }
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -6 * unit), blur: 18 * unit, color: NSColor.black.withAlphaComponent(0.25).cgColor)
    disc(292, NSColor.white.withAlphaComponent(0.96))
    context.restoreGState()
    disc(118, NSColor(red: 0.12, green: 0.50, blue: 0.84, alpha: 1))

    // Play triangle in the centre.
    context.setFillColor(NSColor.white.cgColor)
    context.move(to: CGPoint(x: center.x - 34 * unit, y: center.y + 52 * unit))
    context.addLine(to: CGPoint(x: center.x - 34 * unit, y: center.y - 52 * unit))
    context.addLine(to: CGPoint(x: center.x + 56 * unit, y: center.y))
    context.closePath()
    context.fillPath()

    // Plus and minus on the ring, like volume buttons.
    let ink = NSColor(red: 0.16, green: 0.45, blue: 0.80, alpha: 1).cgColor
    context.setFillColor(ink)
    let stroke = 22 * unit
    let arm = 34 * unit
    let top = CGPoint(x: center.x, y: center.y + 205 * unit)
    let bottom = CGPoint(x: center.x, y: center.y - 205 * unit)
    context.fill(CGRect(x: top.x - arm, y: top.y - stroke / 2, width: 2 * arm, height: stroke))
    context.fill(CGRect(x: top.x - stroke / 2, y: top.y - arm, width: stroke, height: 2 * arm))
    context.fill(CGRect(x: bottom.x - arm, y: bottom.y - stroke / 2, width: 2 * arm, height: stroke))

    // Skip arrows left and right.
    func arrows(at x: CGFloat, direction: CGFloat) {
        for shift in [-22.0, 22.0] {
            let tip = x + (CGFloat(shift) + 24) * direction * unit
            let base = x + (CGFloat(shift) - 20) * direction * unit
            context.move(to: CGPoint(x: base, y: center.y + 30 * unit))
            context.addLine(to: CGPoint(x: base, y: center.y - 30 * unit))
            context.addLine(to: CGPoint(x: tip, y: center.y))
            context.closePath()
            context.fillPath()
        }
    }
    arrows(at: center.x + 205 * unit, direction: 1)
    arrows(at: center.x - 205 * unit, direction: -1)

    NSGraphicsContext.restoreGraphicsState()
    return bitmap
}

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: make-icon.swift <output.iconset>\n".utf8))
    exit(2)
}
let folder = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
for (points, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)] {
    let bitmap = drawIcon(size: CGFloat(points * scale))
    let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
    try bitmap.representation(using: .png, properties: [:])!.write(to: folder.appendingPathComponent(name))
}
