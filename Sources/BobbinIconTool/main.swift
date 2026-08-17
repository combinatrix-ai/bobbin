import AppKit
import Foundation
import BobbinIcon

// Deterministic icon generator. Every artefact the app ships or the reader
// reviews comes from `MarkSpec`, so the Dock icon, the menu bar glyph, the SVG
// and the preview sheet can never disagree with each other.

let usage = """
Usage: bobbin-icon <command> [path]

  iconset <dir>    Write the .iconset PNGs iconutil needs for AppIcon.icns
  template <dir>   Write the monochrome menu bar silhouette at @1x and @2x
  svg <file>       Write the mark as a vector source
  preview <file>   Write the visual-verification sheet
"""

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.count == 2 else { fail(usage) }
let command = arguments[0]
let target = URL(fileURLWithPath: arguments[1])

let iconSpec = AppIconSpec.standard

func writeIconset(to directory: URL) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    for entry in AppIconSpec.iconsetEntries {
        let data = try IconRenderer.appIconPNG(pixels: entry.pixels, spec: iconSpec)
        try data.write(to: directory.appendingPathComponent(entry.name), options: .atomic)
    }
}

/// Mirrors `IconRenderer.menuBarImage`: a 15 pt mark inside an 18 pt frame.
func writeTemplates(to directory: URL) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let padding = (18.0 - 15.0) / 2 / 18.0
    for (name, pixels) in [("menubar.png", 18), ("menubar@2x.png", 36)] {
        let data = try IconRenderer.templatePNG(
            pixels: pixels,
            spec: iconSpec.mark,
            padding: padding
        )
        try data.write(to: directory.appendingPathComponent(name), options: .atomic)
    }
}

func writeSVG(to file: URL) throws {
    let svg = SVGExport.mark(
        spec: iconSpec.mark,
        size: 512,
        loopColor: iconSpec.loopColor,
        coreColor: iconSpec.coreColor
    )
    try FileManager.default.createDirectory(
        at: file.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try Data(svg.utf8).write(to: file, options: .atomic)
}

// MARK: - Preview sheet

private func draw(
    _ text: String,
    at point: CGPoint,
    size: CGFloat,
    weight: NSFont.Weight,
    color: NSColor,
    in context: CGContext
) {
    context.saveGState()
    // The sheet is drawn y-down; flip back so glyphs are not mirrored.
    context.translateBy(x: 0, y: point.y)
    context.scaleBy(x: 1, y: -1)
    let graphics = NSGraphicsContext(cgContext: context, flipped: false)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphics
    NSAttributedString(
        string: text,
        attributes: [
            .font: NSFont.systemFont(ofSize: size, weight: weight),
            .foregroundColor: color
        ]
    ).draw(at: CGPoint(x: point.x, y: 0))
    NSGraphicsContext.restoreGraphicsState()
    context.restoreGState()
}

private func fill(_ rect: CGRect, _ color: IconColor, radius: CGFloat, in context: CGContext) {
    context.saveGState()
    context.setFillColor(
        red: color.red,
        green: color.green,
        blue: color.blue,
        alpha: color.alpha
    )
    context.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
    context.fillPath()
    context.restoreGState()
}

/// Draws the menu bar silhouette at true pixel size on a given background.
private func drawGlyph(
    box: CGRect,
    color: IconColor,
    in context: CGContext
) {
    IconRenderer.drawMark(
        in: context,
        fitting: box,
        spec: iconSpec.mark,
        loopColor: color,
        coreColor: color
    )
}

func writePreview(to file: URL) throws {
    let width = 1180
    let height = 720
    let context = try IconRenderer.makeContext(pixelWidth: width, pixelHeight: height)

    let page = IconColor(hex: 0xF2F1EE)
    let ink = NSColor(calibratedWhite: 0.18, alpha: 1)
    let subtle = NSColor(calibratedWhite: 0.44, alpha: 1)
    fill(CGRect(x: 0, y: 0, width: width, height: height), page, radius: 0, in: context)

    draw(
        "Bobbin — icon concept A",
        at: CGPoint(x: 64, y: 58),
        size: 26,
        weight: .semibold,
        color: ink,
        in: context
    )
    draw(
        "Dock icon and menu bar glyph, generated from one MarkSpec",
        at: CGPoint(x: 64, y: 94),
        size: 13,
        weight: .regular,
        color: subtle,
        in: context
    )

    // Dock icon, large.
    let iconSize: CGFloat = 420
    let iconOrigin = CGPoint(x: 64, y: 150)
    context.saveGState()
    context.translateBy(x: iconOrigin.x, y: iconOrigin.y)
    IconRenderer.drawAppIcon(in: context, canvas: iconSize, spec: iconSpec)
    context.restoreGState()
    draw(
        "App icon — 420 px (renders 16 → 1024)",
        at: CGPoint(x: 64, y: iconOrigin.y + iconSize + 6),
        size: 12,
        weight: .medium,
        color: subtle,
        in: context
    )

    // Menu bar strips at realistic scale.
    let stripX: CGFloat = 560
    let stripWidth: CGFloat = 556
    var cursorY: CGFloat = 168

    for (title, barColor, glyphColor) in [
        ("Light menu bar", IconColor(hex: 0xE9E8E5), IconColor(hex: 0x000000, alpha: 0.86)),
        ("Dark menu bar", IconColor(hex: 0x2A2926), IconColor(hex: 0xFFFFFF, alpha: 0.92))
    ] {
        draw(
            title,
            at: CGPoint(x: stripX, y: cursorY),
            size: 12,
            weight: .medium,
            color: subtle,
            in: context
        )
        cursorY += 22

        let bar = CGRect(x: stripX, y: cursorY, width: stripWidth, height: 30)
        fill(bar, barColor, radius: 7, in: context)

        // 16 px and 32 px, drawn at their true size inside the bar.
        drawGlyph(
            box: CGRect(x: bar.minX + 22, y: bar.midY - 8, width: 16, height: 16),
            color: glyphColor,
            in: context
        )
        drawGlyph(
            box: CGRect(x: bar.minX + 78, y: bar.midY - 16, width: 32, height: 32),
            color: glyphColor,
            in: context
        )
        cursorY += 30 + 34
    }

    // Magnified silhouette so the shape can be judged as well as the scale.
    draw(
        "Silhouette — 16 px, 32 px, 128 px (template, no colour)",
        at: CGPoint(x: stripX, y: cursorY),
        size: 12,
        weight: .medium,
        color: subtle,
        in: context
    )
    cursorY += 24

    let plate = CGRect(x: stripX, y: cursorY, width: stripWidth, height: 196)
    fill(plate, IconColor(hex: 0xFFFFFF), radius: 10, in: context)
    let glyphInk = IconColor(hex: 0x1A1A1A)
    drawGlyph(
        box: CGRect(x: plate.minX + 26, y: plate.midY - 8, width: 16, height: 16),
        color: glyphInk,
        in: context
    )
    drawGlyph(
        box: CGRect(x: plate.minX + 78, y: plate.midY - 16, width: 32, height: 32),
        color: glyphInk,
        in: context
    )
    drawGlyph(
        box: CGRect(x: plate.minX + 160, y: plate.midY - 64, width: 128, height: 128),
        color: glyphInk,
        in: context
    )
    cursorY += 196 + 30

    draw(
        "Inspect: gap legibility at 16 px, optical balance of the two arcs, square centring.",
        at: CGPoint(x: stripX, y: cursorY),
        size: 12,
        weight: .regular,
        color: subtle,
        in: context
    )

    let data = try IconRenderer.pngData(from: context)
    try FileManager.default.createDirectory(
        at: file.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try data.write(to: file, options: .atomic)
}

do {
    switch command {
    case "iconset":
        try writeIconset(to: target)
    case "template":
        try writeTemplates(to: target)
    case "svg":
        try writeSVG(to: target)
    case "preview":
        try writePreview(to: target)
    default:
        fail(usage)
    }
    print(target.path)
} catch {
    fail("bobbin-icon: \(error.localizedDescription)")
}
