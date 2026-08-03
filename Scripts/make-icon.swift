#!/usr/bin/env swift
//
// make-icon.swift — draws the OpenTab application icon and writes OpenTab.icns.
//
// The artwork is generated procedurally from the code in this file. It is our own
// design: a squircle in a deep indigo-to-blue gradient carrying three offset window
// cards, the frontmost one lit, which reads as "step through your windows".
//
// Usage:  swift Scripts/make-icon.swift [output-directory]
// Default output directory is Resources/Assets.

import AppKit
import Foundation

// MARK: - Palette

// Colours are defined as sRGB triples so the rendering is independent of the
// display profile of whatever machine happens to run this script.
private func srgb(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> NSColor {
    NSColor(srgbRed: r, green: g, blue: b, alpha: a)
}

private let gradientTop = srgb(0.36, 0.42, 0.95)
private let gradientBottom = srgb(0.18, 0.20, 0.60)
private let cardFar = srgb(1.0, 1.0, 1.0, 0.28)
private let cardMid = srgb(1.0, 1.0, 1.0, 0.48)
private let cardNearFill = srgb(0.99, 0.99, 1.0, 0.97)
private let cardNearBar = srgb(0.36, 0.42, 0.95, 0.85)
private let accent = srgb(0.42, 0.85, 1.0)

// MARK: - Drawing

/// Draws the icon into the current graphics context at `size` x `size` points.
private func drawIcon(size S: CGFloat, into ctx: CGContext) {
    ctx.saveGState()

    // macOS icons sit inside a safe area rather than bleeding to the edge.
    let inset = S * 0.055
    let rect = CGRect(x: inset, y: inset, width: S - inset * 2, height: S - inset * 2)
    let corner = rect.width * 0.2237 // Apple's continuous-corner ratio for app icons.

    let squircle = NSBezierPath(roundedRect: rect, xRadius: corner, yRadius: corner)

    // Backdrop gradient.
    ctx.saveGState()
    squircle.addClip()
    let gradient = NSGradient(colors: [gradientTop, gradientBottom])!
    gradient.draw(in: rect, angle: -90)

    // A soft highlight arc across the top third gives the surface some depth.
    let sheen = NSGradient(colors: [srgb(1, 1, 1, 0.22), srgb(1, 1, 1, 0.0)])!
    sheen.draw(in: CGRect(x: rect.minX, y: rect.midY, width: rect.width, height: rect.height / 2),
               angle: -90)
    ctx.restoreGState()

    // Three window cards, drawn back to front with a diagonal offset.
    let cardW = rect.width * 0.60
    let cardH = cardW * 0.68
    let cardCorner = cardW * 0.10
    let step = rect.width * 0.075
    let centre = CGPoint(x: rect.midX, y: rect.midY)

    func cardRect(offsetIndex i: CGFloat, scale: CGFloat) -> CGRect {
        let w = cardW * scale
        let h = cardH * scale
        return CGRect(x: centre.x - w / 2 - step * i,
                      y: centre.y - h / 2 + step * i,
                      width: w, height: h)
    }

    // Back card.
    let farPath = NSBezierPath(roundedRect: cardRect(offsetIndex: -1.0, scale: 0.86),
                               xRadius: cardCorner * 0.86, yRadius: cardCorner * 0.86)
    cardFar.setFill()
    farPath.fill()

    // Middle card.
    let midPath = NSBezierPath(roundedRect: cardRect(offsetIndex: -0.5, scale: 0.93),
                               xRadius: cardCorner * 0.93, yRadius: cardCorner * 0.93)
    cardMid.setFill()
    midPath.fill()

    // Front card: opaque, with a title bar and three traffic-light dots.
    let nearRect = cardRect(offsetIndex: 0.35, scale: 1.0)
    let nearPath = NSBezierPath(roundedRect: nearRect, xRadius: cardCorner, yRadius: cardCorner)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -S * 0.012),
                  blur: S * 0.03,
                  color: srgb(0, 0, 0, 0.35).cgColor)
    cardNearFill.setFill()
    nearPath.fill()
    ctx.restoreGState()

    // Title bar clipped to the card's rounded top.
    ctx.saveGState()
    nearPath.addClip()
    let barH = nearRect.height * 0.26
    cardNearBar.setFill()
    NSBezierPath(rect: CGRect(x: nearRect.minX, y: nearRect.maxY - barH,
                              width: nearRect.width, height: barH)).fill()

    let dotR = barH * 0.20
    let dotY = nearRect.maxY - barH / 2
    for i in 0..<3 {
        let x = nearRect.minX + barH * 0.55 + CGFloat(i) * dotR * 3.1
        srgb(1, 1, 1, 0.85).setFill()
        NSBezierPath(ovalIn: CGRect(x: x - dotR, y: dotY - dotR,
                                    width: dotR * 2, height: dotR * 2)).fill()
    }
    ctx.restoreGState()

    // Accent arrow on the front card body, pointing right: "advance to the next window".
    let bodyRect = CGRect(x: nearRect.minX, y: nearRect.minY,
                          width: nearRect.width, height: nearRect.height - barH)
    let a = bodyRect.height * 0.34
    let ax = bodyRect.midX
    let ay = bodyRect.midY
    let arrow = NSBezierPath()
    arrow.lineWidth = max(1, a * 0.30)
    arrow.lineCapStyle = .round
    arrow.lineJoinStyle = .round
    arrow.move(to: CGPoint(x: ax - a * 0.95, y: ay))
    arrow.line(to: CGPoint(x: ax + a * 0.75, y: ay))
    arrow.move(to: CGPoint(x: ax + a * 0.10, y: ay + a * 0.62))
    arrow.line(to: CGPoint(x: ax + a * 0.78, y: ay))
    arrow.line(to: CGPoint(x: ax + a * 0.10, y: ay - a * 0.62))
    accent.blended(withFraction: 0.45, of: gradientBottom)!.setStroke()
    arrow.stroke()

    ctx.restoreGState()
}

// MARK: - Rasterising

private func renderPNG(size: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                              pixelsWide: size, pixelsHigh: size,
                              bitsPerSample: 8, samplesPerPixel: 4,
                              hasAlpha: true, isPlanar: false,
                              colorSpaceName: .deviceRGB,
                              bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: size, height: size)

    NSGraphicsContext.saveGraphicsState()
    let gctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = gctx
    gctx.cgContext.setShouldAntialias(true)
    gctx.imageInterpolation = .high
    drawIcon(size: CGFloat(size), into: gctx.cgContext)
    NSGraphicsContext.restoreGraphicsState()

    guard let data = rep.representation(using: .png, properties: [:]) else {
        FileHandle.standardError.write("make-icon: PNG encoding failed at \(size)px\n".data(using: .utf8)!)
        exit(1)
    }
    return data
}

// MARK: - Main

let args = CommandLine.arguments
let outDir = args.count > 1 ? args[1] : "Resources/Assets"
let fm = FileManager.default
try? fm.createDirectory(atPath: outDir, withIntermediateDirectories: true)

let iconsetDir = (outDir as NSString).appendingPathComponent("OpenTab.iconset")
try? fm.removeItem(atPath: iconsetDir)
try fm.createDirectory(atPath: iconsetDir, withIntermediateDirectories: true)

// (point size, scale) pairs required by iconutil.
let variants: [(Int, Int)] = [
    (16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2),
    (256, 1), (256, 2), (512, 1), (512, 2),
]

for (pt, scale) in variants {
    let px = pt * scale
    let name = scale == 1 ? "icon_\(pt)x\(pt).png" : "icon_\(pt)x\(pt)@2x.png"
    let data = renderPNG(size: px)
    try data.write(to: URL(fileURLWithPath: (iconsetDir as NSString).appendingPathComponent(name)))
}

// A standalone 1024px PNG is handy for the README and the GitHub social preview.
try renderPNG(size: 1024)
    .write(to: URL(fileURLWithPath: (outDir as NSString).appendingPathComponent("icon-1024.png")))

let icnsPath = (outDir as NSString).appendingPathComponent("OpenTab.icns")
let proc = Process()
proc.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
proc.arguments = ["-c", "icns", iconsetDir, "-o", icnsPath]
try proc.run()
proc.waitUntilExit()
guard proc.terminationStatus == 0 else {
    FileHandle.standardError.write("make-icon: iconutil failed\n".data(using: .utf8)!)
    exit(1)
}

try? fm.removeItem(atPath: iconsetDir)
print("make-icon: wrote \(icnsPath)")
