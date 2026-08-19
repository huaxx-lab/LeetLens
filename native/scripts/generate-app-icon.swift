#!/usr/bin/env swift

import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let scriptURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
let nativeURL = scriptURL.deletingLastPathComponent().deletingLastPathComponent()
let repositoryURL = nativeURL.deletingLastPathComponent()

let destinations: [(directory: URL, name: String, pixels: Int)] = [
    (nativeURL.appending(path: "IconSources/AppIcon.iconset"), "icon_16x16.png", 16),
    (nativeURL.appending(path: "IconSources/AppIcon.iconset"), "icon_16x16@2x.png", 32),
    (nativeURL.appending(path: "IconSources/AppIcon.iconset"), "icon_32x32.png", 32),
    (nativeURL.appending(path: "IconSources/AppIcon.iconset"), "icon_32x32@2x.png", 64),
    (nativeURL.appending(path: "IconSources/AppIcon.iconset"), "icon_128x128.png", 128),
    (nativeURL.appending(path: "IconSources/AppIcon.iconset"), "icon_128x128@2x.png", 256),
    (nativeURL.appending(path: "IconSources/AppIcon.iconset"), "icon_256x256.png", 256),
    (nativeURL.appending(path: "IconSources/AppIcon.iconset"), "icon_256x256@2x.png", 512),
    (nativeURL.appending(path: "IconSources/AppIcon.iconset"), "icon_512x512.png", 512),
    (nativeURL.appending(path: "IconSources/AppIcon.iconset"), "icon_512x512@2x.png", 1024),
    (repositoryURL.appending(path: "assets/AppIcon.iconset"), "icon_16x16.png", 16),
    (repositoryURL.appending(path: "assets/AppIcon.iconset"), "icon_16x16@2x.png", 32),
    (repositoryURL.appending(path: "assets/AppIcon.iconset"), "icon_32x32.png", 32),
    (repositoryURL.appending(path: "assets/AppIcon.iconset"), "icon_32x32@2x.png", 64),
    (repositoryURL.appending(path: "assets/AppIcon.iconset"), "icon_128x128.png", 128),
    (repositoryURL.appending(path: "assets/AppIcon.iconset"), "icon_128x128@2x.png", 256),
    (repositoryURL.appending(path: "assets/AppIcon.iconset"), "icon_256x256.png", 256),
    (repositoryURL.appending(path: "assets/AppIcon.iconset"), "icon_256x256@2x.png", 512),
    (repositoryURL.appending(path: "assets/AppIcon.iconset"), "icon_512x512.png", 512),
    (repositoryURL.appending(path: "assets/AppIcon.iconset"), "icon_512x512@2x.png", 1024),
]

func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat) -> CGColor {
    CGColor(red: red / 255, green: green / 255, blue: blue / 255, alpha: 1)
}

func renderIcon(pixels: Int) -> CGImage {
    let scale = CGFloat(pixels) / 1024
    let context = CGContext(
        data: nil,
        width: pixels,
        height: pixels,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.setAllowsAntialiasing(true)
    context.setShouldAntialias(true)
    context.interpolationQuality = .high

    // Dock does not mask a legacy .icns image while the app is running. Keep the
    // outer canvas transparent and draw the macOS icon silhouette ourselves so
    // the icon never flashes between square and rounded representations.
    let plateRect = CGRect(
        x: 64 * scale,
        y: 64 * scale,
        width: 896 * scale,
        height: 896 * scale
    )
    let plate = CGPath(
        roundedRect: plateRect,
        cornerWidth: 204 * scale,
        cornerHeight: 204 * scale,
        transform: nil
    )
    context.addPath(plate)
    context.setFillColor(color(248, 247, 243))
    context.fillPath()

    func drawBracket(start: CGPoint, control1: CGPoint, midpoint: CGPoint, control2: CGPoint, end: CGPoint, stroke: CGColor) {
        context.beginPath()
        context.move(to: CGPoint(x: start.x * scale, y: start.y * scale))
        context.addCurve(
            to: CGPoint(x: midpoint.x * scale, y: midpoint.y * scale),
            control1: CGPoint(x: control1.x * scale, y: control1.y * scale),
            control2: CGPoint(x: midpoint.x * scale, y: (midpoint.y - 92) * scale)
        )
        context.addCurve(
            to: CGPoint(x: end.x * scale, y: end.y * scale),
            control1: CGPoint(x: midpoint.x * scale, y: (midpoint.y + 92) * scale),
            control2: CGPoint(x: control2.x * scale, y: control2.y * scale)
        )
        context.setStrokeColor(stroke)
        context.setLineWidth(126 * scale)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.strokePath()
    }

    drawBracket(
        start: CGPoint(x: 405, y: 250),
        control1: CGPoint(x: 286, y: 346),
        midpoint: CGPoint(x: 214, y: 512),
        control2: CGPoint(x: 286, y: 678),
        end: CGPoint(x: 405, y: 774),
        stroke: color(54, 60, 66)
    )
    drawBracket(
        start: CGPoint(x: 619, y: 250),
        control1: CGPoint(x: 738, y: 346),
        midpoint: CGPoint(x: 810, y: 512),
        control2: CGPoint(x: 738, y: 678),
        end: CGPoint(x: 619, y: 774),
        stroke: color(39, 119, 232)
    )

    let dotRadius = 72 * scale
    context.setFillColor(color(255, 101, 74))
    context.fillEllipse(in: CGRect(
        x: CGFloat(pixels) / 2 - dotRadius,
        y: CGFloat(pixels) / 2 - dotRadius,
        width: dotRadius * 2,
        height: dotRadius * 2
    ))
    return context.makeImage()!
}

func writePNG(_ image: CGImage, to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        throw NSError(domain: "AppIconGenerator", code: 1)
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw NSError(domain: "AppIconGenerator", code: 2)
    }
}

let master = renderIcon(pixels: 1024)
try writePNG(master, to: nativeURL.appending(path: "IconSources/AppIcon-master.png"))
try writePNG(renderIcon(pixels: 64), to: nativeURL.appending(path: "IconSources/preview/AppIcon-64.png"))

for destination in destinations {
    try writePNG(renderIcon(pixels: destination.pixels), to: destination.directory.appending(path: destination.name))
}

print("Generated app icon assets.")
