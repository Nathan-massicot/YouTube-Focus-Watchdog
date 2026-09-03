// YouTube Full Focus — icon generator.
//
// Renders the app icon at every size the .iconset format needs, using only
// CoreGraphics, so the repository carries no binary image assets and the icon
// can be regenerated (or restyled) from source. Run via build.sh:
//
//     swift app/make-icon.swift <output.icns>
//
// It writes a temporary .iconset directory next to the output and folds it into
// an .icns with iconutil.

import AppKit
import CoreGraphics
import Foundation

// MARK: - Palette

private func srgb(_ hex: UInt32, alpha: CGFloat = 1) -> CGColor {
    CGColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: alpha
    )
}

private let plateTop = srgb(0x33363C)
private let plateBottom = srgb(0x17181B)
private let accent = srgb(0x4C8DFF)
private let accentDeep = srgb(0x2F6BE0)

// MARK: - Drawing

/// Draws the icon into `ctx` on a `size` x `size` canvas. All geometry is
/// expressed as a fraction of the canvas so every export is pixel-consistent.
private func drawIcon(in ctx: CGContext, size: CGFloat) {
    let u = size / 1024  // one design unit == 1/1024 of the canvas

    ctx.setShouldAntialias(true)
    ctx.interpolationQuality = .high

    // --- The rounded plate ---------------------------------------------------
    // macOS icons sit on a squircle inset from the canvas edge, leaving room
    // for the system's drop shadow.
    let inset = 100 * u
    let plate = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let platePath = CGPath(
        roundedRect: plate,
        cornerWidth: 185 * u,
        cornerHeight: 185 * u,
        transform: nil
    )

    ctx.saveGState()
    ctx.addPath(platePath)
    ctx.clip()
    if let gradient = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [plateTop, plateBottom] as CFArray,
        locations: [0, 1]
    ) {
        ctx.drawLinearGradient(
            gradient,
            start: CGPoint(x: 0, y: plate.maxY),
            end: CGPoint(x: 0, y: plate.minY),
            options: []
        )
    }
    ctx.restoreGState()

    // A hairline highlight along the top edge gives the plate some depth.
    ctx.saveGState()
    ctx.addPath(platePath)
    ctx.setStrokeColor(srgb(0xFFFFFF, alpha: 0.10))
    ctx.setLineWidth(3 * u)
    ctx.strokePath()
    ctx.restoreGState()

    let center = CGPoint(x: size / 2, y: size / 2)

    // --- Outer "focus" ring --------------------------------------------------
    // A faint second ring reads as a target/reticle: attention narrowed down.
    ctx.setStrokeColor(srgb(0xFFFFFF, alpha: 0.14))
    ctx.setLineWidth(20 * u)
    ctx.addArc(center: center, radius: 300 * u, startAngle: 0, endAngle: .pi * 2, clockwise: false)
    ctx.strokePath()

    // --- Main accent ring ----------------------------------------------------
    ctx.saveGState()
    ctx.setLineWidth(54 * u)
    ctx.setLineCap(.round)
    ctx.addArc(center: center, radius: 232 * u, startAngle: 0, endAngle: .pi * 2, clockwise: false)
    ctx.replacePathWithStrokedPath()
    ctx.clip()
    if let gradient = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [accent, accentDeep] as CFArray,
        locations: [0, 1]
    ) {
        ctx.drawLinearGradient(
            gradient,
            start: CGPoint(x: 0, y: center.y + 260 * u),
            end: CGPoint(x: 0, y: center.y - 260 * u),
            options: []
        )
    }
    ctx.restoreGState()

    // --- Play triangle -------------------------------------------------------
    // Rounded corners so it does not read as a sharp arrow at 16pt.
    let r = 128 * u                 // circumradius of the triangle
    let nudge = 14 * u              // optical centring: a triangle looks left-heavy
    let points = (0..<3).map { i -> CGPoint in
        let angle = CGFloat(i) * (.pi * 2 / 3)
        return CGPoint(x: center.x + nudge + r * cos(angle), y: center.y + r * sin(angle))
    }

    let triangle = CGMutablePath()
    triangle.move(to: CGPoint(x: (points[0].x + points[1].x) / 2, y: (points[0].y + points[1].y) / 2))
    for i in 0..<3 {
        triangle.addArc(
            tangent1End: points[(i + 1) % 3],
            tangent2End: points[(i + 2) % 3],
            radius: 26 * u
        )
    }
    triangle.closeSubpath()

    ctx.setFillColor(srgb(0xFFFFFF))
    ctx.addPath(triangle)
    ctx.fillPath()
}

// MARK: - Export

private func renderPNG(size: Int, to url: URL) throws {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(
        data: nil,
        width: size,
        height: size,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        throw IconError.message("Could not create a \(size)x\(size) bitmap context")
    }

    drawIcon(in: ctx, size: CGFloat(size))

    guard let image = ctx.makeImage() else {
        throw IconError.message("Could not snapshot the \(size)x\(size) context")
    }
    let rep = NSBitmapImageRep(cgImage: image)
    rep.size = NSSize(width: size, height: size)
    guard let data = rep.representation(using: .png, properties: [:]) else {
        throw IconError.message("Could not PNG-encode the \(size)x\(size) image")
    }
    try data.write(to: url)
}

enum IconError: Error, CustomStringConvertible {
    case message(String)
    var description: String {
        switch self { case .message(let text): return text }
    }
}

// Every (size, filename) pair `iconutil` expects in an .iconset.
private let variants: [(Int, String)] = [
    (16, "icon_16x16.png"),
    (32, "icon_16x16@2x.png"),
    (32, "icon_32x32.png"),
    (64, "icon_32x32@2x.png"),
    (128, "icon_128x128.png"),
    (256, "icon_128x128@2x.png"),
    (256, "icon_256x256.png"),
    (512, "icon_256x256@2x.png"),
    (512, "icon_512x512.png"),
    (1024, "icon_512x512@2x.png"),
]

private func run() throws {
    let args = CommandLine.arguments
    guard args.count == 2 else {
        throw IconError.message("usage: swift make-icon.swift <output.icns>")
    }

    let output = URL(fileURLWithPath: args[1])
    let fm = FileManager.default
    let iconset = output.deletingPathExtension().appendingPathExtension("iconset")

    if fm.fileExists(atPath: iconset.path) {
        try fm.removeItem(at: iconset)
    }
    try fm.createDirectory(at: iconset, withIntermediateDirectories: true)

    for (size, name) in variants {
        try renderPNG(size: size, to: iconset.appendingPathComponent(name))
    }

    let iconutil = Process()
    iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    iconutil.arguments = ["-c", "icns", iconset.path, "-o", output.path]
    try iconutil.run()
    iconutil.waitUntilExit()
    guard iconutil.terminationStatus == 0 else {
        throw IconError.message("iconutil failed with status \(iconutil.terminationStatus)")
    }

    try fm.removeItem(at: iconset)
    print("Icon written to \(output.path)")
}

do {
    try run()
} catch {
    FileHandle.standardError.write("make-icon: \(error)\n".data(using: .utf8)!)
    exit(1)
}
