#!/usr/bin/env swift
// Renders Zentic's app icon into App/Assets.xcassets/AppIcon.appiconset.
//
//   swift scripts/render-icon.swift            # write the icon set
//   swift scripts/render-icon.swift out.png    # also write a 1024px preview
//
// The icon is drawn in code rather than exported from a design tool so every
// size is rendered from the vectors at its own pixel size — a 16px icon
// downsampled from 1024px turns its rim highlights to mud — and so changing it
// is a reviewable diff.
//
// The mark is the half-filled circle the app uses for "Original / Clean": a disc
// that is half solid light and half clear glass, on the indigo of the default
// window tint.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: Geometry (Apple's macOS icon grid, in a 1024pt canvas)

let canvas: CGFloat = 1024
/// The rounded-rect body: 824pt with a 100pt margin for the shadow.
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let discCenter = CGPoint(x: 512, y: 512)
let discRadius: CGFloat = 268

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: r, green: g, blue: b, alpha: a)
}

/// The system's rounded-rect icon shape: 824pt body, 185pt corners.
let bodyPath = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)

/// Gradients fill past their end points, so a stroke or antialiased edge that
/// pokes past the shape it was measured from is never left unpainted.
let extend: CGGradientDrawingOptions = [.drawsBeforeStartLocation, .drawsAfterEndLocation]

func linear(_ colors: [CGColor], _ locations: [CGFloat]) -> CGGradient {
    CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: locations)!
}

// MARK: Drawing

func draw(in ctx: CGContext) {
    let disc = CGPath(
        ellipseIn: CGRect(
            x: discCenter.x - discRadius, y: discCenter.y - discRadius,
            width: discRadius * 2, height: discRadius * 2), transform: nil)

    // Shadow the body casts on the desktop, as the system template does.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: rgb(0, 0, 0, 0.32))
    ctx.addPath(bodyPath)
    ctx.setFillColor(rgb(0.16, 0.12, 0.42))
    ctx.fillPath()
    ctx.restoreGState()

    // Body: indigo, lit from above.
    ctx.saveGState()
    ctx.addPath(bodyPath)
    ctx.clip()
    ctx.drawLinearGradient(
        linear([rgb(0.39, 0.32, 0.95), rgb(0.24, 0.17, 0.71), rgb(0.10, 0.07, 0.33)], [0, 0.5, 1]),
        start: CGPoint(x: 512, y: body.maxY), end: CGPoint(x: 512, y: body.minY), options: extend)
    // A broad glow behind the disc, so the mark sits in light rather than on a flat field.
    ctx.drawRadialGradient(
        linear([rgb(0.66, 0.60, 1, 0.38), rgb(0.55, 0.48, 1, 0)], [0, 1]),
        startCenter: CGPoint(x: 470, y: 600), startRadius: 0,
        endCenter: CGPoint(x: 470, y: 600), endRadius: 470, options: extend)
    // Darken the lower corners a touch, for depth.
    ctx.drawRadialGradient(
        linear([rgb(0.05, 0.03, 0.18, 0), rgb(0.05, 0.03, 0.18, 0.45)], [0.55, 1]),
        startCenter: CGPoint(x: 512, y: 600), startRadius: 0,
        endCenter: CGPoint(x: 512, y: 600), endRadius: 640, options: extend)

    // The disc's shadow on the body.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -22), blur: 46, color: rgb(0.03, 0.01, 0.16, 0.55))
    ctx.addPath(disc)
    ctx.setFillColor(rgb(0.30, 0.24, 0.80, 1))
    ctx.fillPath()
    ctx.restoreGState()

    // Right half: clear glass. The body shows through, brightened and slightly
    // cooled, which is what reads as glass at Dock size.
    ctx.saveGState()
    ctx.addPath(disc)
    ctx.clip()
    ctx.drawLinearGradient(
        linear([rgb(0.62, 0.58, 1), rgb(0.38, 0.32, 0.90), rgb(0.24, 0.18, 0.66)], [0, 0.55, 1]),
        start: CGPoint(x: 512, y: discCenter.y + discRadius), end: CGPoint(x: 512, y: discCenter.y - discRadius),
        options: extend)
    // Frost: a pale veil, stronger at the top.
    ctx.drawLinearGradient(
        linear([rgb(1, 1, 1, 0.30), rgb(1, 1, 1, 0.06)], [0, 1]),
        start: CGPoint(x: 512, y: discCenter.y + discRadius), end: CGPoint(x: 512, y: discCenter.y - discRadius),
        options: extend)
    // Refraction: the lower edge of a glass lens gathers light.
    ctx.drawRadialGradient(
        linear([rgb(0.80, 0.78, 1, 0), rgb(0.85, 0.82, 1, 0.38)], [0.72, 1]),
        startCenter: CGPoint(x: discCenter.x, y: discCenter.y + 40), startRadius: 0,
        endCenter: CGPoint(x: discCenter.x, y: discCenter.y + 40), endRadius: discRadius + 40, options: extend)

    // Left half: solid light.
    ctx.saveGState()
    ctx.clip(to: CGRect(x: 0, y: 0, width: discCenter.x, height: canvas))
    ctx.drawLinearGradient(
        linear([rgb(1, 1, 1), rgb(0.93, 0.92, 1), rgb(0.80, 0.77, 1)], [0, 0.5, 1]),
        start: CGPoint(x: 400, y: discCenter.y + discRadius), end: CGPoint(x: 560, y: discCenter.y - discRadius),
        options: extend)
    ctx.restoreGState()

    // The seam: light spilling from the solid half into the glass.
    ctx.drawLinearGradient(
        linear([rgb(1, 1, 1, 0.42), rgb(1, 1, 1, 0)], [0, 1]),
        start: CGPoint(x: discCenter.x, y: 512), end: CGPoint(x: discCenter.x + 70, y: 512), options: extend)

    // Specular highlight across the top of the disc.
    ctx.saveGState()
    let highlight = CGPath(
        ellipseIn: CGRect(x: discCenter.x - 210, y: discCenter.y + 70, width: 420, height: 230), transform: nil)
    ctx.addPath(highlight)
    ctx.clip()
    ctx.drawLinearGradient(
        linear([rgb(1, 1, 1, 0.34), rgb(1, 1, 1, 0)], [0, 1]),
        start: CGPoint(x: 512, y: discCenter.y + 300), end: CGPoint(x: 512, y: discCenter.y + 90), options: extend)
    ctx.restoreGState()
    ctx.restoreGState()

    // Rim: a bright edge at the top fading out at the bottom.
    ctx.saveGState()
    ctx.addPath(disc)
    ctx.setLineWidth(7)
    ctx.replacePathWithStrokedPath()
    ctx.clip()
    ctx.drawLinearGradient(
        linear([rgb(1, 1, 1, 0.95), rgb(1, 1, 1, 0.35), rgb(1, 1, 1, 0.65)], [0, 0.6, 1]),
        start: CGPoint(x: 512, y: discCenter.y + discRadius), end: CGPoint(x: 512, y: discCenter.y - discRadius),
        options: extend)
    ctx.restoreGState()

    ctx.restoreGState()  // body clip

    // The body's own glass edge: a hairline catching light along the top.
    ctx.saveGState()
    ctx.addPath(bodyPath)
    ctx.setLineWidth(6)
    ctx.replacePathWithStrokedPath()
    ctx.addPath(bodyPath)
    ctx.clip(using: .evenOdd)  // the inner half of the stroke only
    ctx.drawLinearGradient(
        linear([rgb(1, 1, 1, 0.50), rgb(1, 1, 1, 0.06), rgb(1, 1, 1, 0.04)], [0, 0.5, 1]),
        start: CGPoint(x: 512, y: body.maxY), end: CGPoint(x: 512, y: body.minY), options: extend)
    ctx.restoreGState()
}

func render(pixels: Int) -> Data {
    let ctx = CGContext(
        data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    ctx.setShouldAntialias(true)
    ctx.scaleBy(x: CGFloat(pixels) / canvas, y: CGFloat(pixels) / canvas)
    draw(in: ctx)
    let data = NSMutableData()
    let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
    CGImageDestinationFinalize(dest)
    return data as Data
}

// MARK: Output

let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let set = root.appending(path: "App/Assets.xcassets/AppIcon.appiconset")
try FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)

var images: [[String: String]] = []
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        try render(pixels: points * scale).write(to: set.appending(path: name))
        images.append(["idiom": "mac", "size": "\(points)x\(points)", "scale": "\(scale)x", "filename": name])
    }
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
    .write(to: set.appending(path: "Contents.json"))
try #"{"info":{"author":"xcode","version":1}}"#.write(
    to: root.appending(path: "App/Assets.xcassets/Contents.json"), atomically: true, encoding: .utf8)

if CommandLine.arguments.count > 1 {
    try render(pixels: 1024).write(to: URL(filePath: CommandLine.arguments[1]))
}
print("Wrote \(set.path)")
