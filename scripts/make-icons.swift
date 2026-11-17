#!/usr/bin/env swift
// Draws the QuickNews icons: a newspaper front page leaning forward with speed
// lines, on crimson.
//
//   swift scripts/make-icons.swift
//
// Writes App/Assets.xcassets/AppIcon.appiconset/icon.png (1024, full bleed, opaque;
// iOS applies the mask), mac-<size>.png beside it (rounded, inset to the macOS icon
// grid), Extension/Resources/icons/<size>.png (rounded) and gray-<size>.png, the
// toolbar icon for pages Apple News doesn't have.

import AppKit

struct Palette {
    var top: UInt32, bottom: UInt32, tint: UInt32
    static let crimson = Palette(top: 0xEE2A48, bottom: 0xB30C2E, tint: 0xCF1838)
    static let gray = Palette(top: 0x9C9CA3, bottom: 0x6C6C73, tint: 0x6C6C73)
}

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255,
            blue: CGFloat(hex & 255) / 255, alpha: alpha)
}

func draw(size canvas: CGFloat, rounded: Bool, inset: CGFloat = 0, palette: Palette = .crimson) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(canvas), pixelsHigh: Int(canvas),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let cg = NSGraphicsContext.current!.cgContext
    let size = canvas * (1 - 2 * inset)
    cg.translateBy(x: canvas * inset, y: canvas * inset)
    cg.scaleBy(x: size / 1024, y: size / 1024) // everything below is on a 1024 grid

    if rounded {
        cg.addPath(CGPath(roundedRect: CGRect(x: 0, y: 0, width: 1024, height: 1024), cornerWidth: 230, cornerHeight: 230, transform: nil))
        cg.clip()
    }
    let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                              colors: [color(palette.top), color(palette.bottom)] as CFArray, locations: [0, 1])!
    cg.drawLinearGradient(gradient, start: CGPoint(x: 0, y: 1024), end: .zero, options: [])

    // Everything leans forward 8° like italic type, for acceleration. The shear
    // pivots on the page's middle; the shift keeps the balance of the upright design.
    let lean = tan(8 * CGFloat.pi / 180)
    cg.concatenate(CGAffineTransform(a: 1, b: 0, c: lean, d: 1, tx: -lean * 510 - 22, ty: 0))

    func fillRounded(_ rect: CGRect, _ radius: CGFloat, _ fill: CGColor) {
        cg.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
        cg.setFillColor(fill)
        cg.fillPath()
    }

    // The page.
    let page = CGRect(x: 380, y: 190, width: 470, height: 640)
    fillRounded(page, 30, color(0xFFFFFF))

    // Speed lines, trailing off to the left.
    cg.setLineCap(.round)
    cg.setLineWidth(52)
    for (y, length, alpha) in [(640.0, 190.0, 0.95), (510.0, 250.0, 0.75), (380.0, 150.0, 0.55)] {
        cg.setStrokeColor(color(0xFFFFFF, alpha))
        cg.move(to: CGPoint(x: 330 - length, y: y))
        cg.addLine(to: CGPoint(x: 330, y: y))
        cg.strokePath()
    }

    // Masthead, photo and three lines of text, all one tint. Toolbar sizes get
    // stronger fills, or the pale ones vanish.
    let small = canvas <= 48
    let fill = color(palette.tint, small ? 0.45 : 0.26), masthead = color(palette.tint, small ? 0.65 : 0.40)
    let margin: CGFloat = 48, x = page.minX + margin, width = page.width - 2 * margin, top = page.maxY - margin
    fillRounded(CGRect(x: x, y: top - 64, width: width, height: 64), 10, masthead)
    fillRounded(CGRect(x: x, y: top - 300, width: width, height: 200), 12, fill)
    for (i, share) in [1.0, 1.0, 0.6].enumerated() {
        fillRounded(CGRect(x: x, y: top - 370 - CGFloat(i) * 62, width: width * share, height: 30), 10, fill)
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

/// The same PNG without an alpha channel, which App Store Connect requires of the iOS icon.
func opaque(_ png: Data) -> Data {
    let image = NSBitmapImageRep(data: png)!.cgImage!
    let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    return NSBitmapImageRep(cgImage: context.makeImage()!).representation(using: .png, properties: [:])!
}

let root = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent()
try opaque(draw(size: 1024, rounded: false))
    .write(to: root.appendingPathComponent("App/Assets.xcassets/AppIcon.appiconset/icon.png"))
for size in [16, 32, 64, 128, 256, 512, 1024] {
    try draw(size: CGFloat(size), rounded: true, inset: 100.0 / 1024)
        .write(to: root.appendingPathComponent("App/Assets.xcassets/AppIcon.appiconset/mac-\(size).png"))
}
for size in [16, 32, 48, 96, 128, 256, 512] {
    try draw(size: CGFloat(size), rounded: true)
        .write(to: root.appendingPathComponent("Extension/Resources/icons/\(size).png"))
}
for size in [16, 32, 48] {
    try draw(size: CGFloat(size), rounded: true, palette: .gray)
        .write(to: root.appendingPathComponent("Extension/Resources/icons/gray-\(size).png"))
}
print("icons written")
