import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum IconRenderError: LocalizedError {
    case contextUnavailable
    case encodingFailed

    public var errorDescription: String? {
        switch self {
        case .contextUnavailable: "Could not create the drawing context."
        case .encodingFailed: "Could not encode the rendered icon as PNG."
        }
    }
}

public enum IconRenderer {
    // MARK: - Path replay

    /// Maps unit-space geometry onto `box` and appends it to a `CGPath`.
    private static func cgPath(_ path: IconPath, scale: Double, offset: IconPoint) -> CGPath {
        let result = CGMutablePath()
        func map(_ point: IconPoint) -> CGPoint {
            CGPoint(x: offset.x + point.x * scale, y: offset.y + point.y * scale)
        }
        for element in path.elements {
            switch element {
            case .move(let point):
                result.move(to: map(point))
            case .line(let point):
                result.addLine(to: map(point))
            case .cubic(let point, let control1, let control2):
                result.addCurve(to: map(point), control1: map(control1), control2: map(control2))
            case .close:
                result.closeSubpath()
            }
        }
        return result
    }

    private static func setFill(_ context: CGContext, _ color: IconColor) {
        context.setFillColor(
            red: color.red,
            green: color.green,
            blue: color.blue,
            alpha: color.alpha
        )
    }

    private static func setStroke(_ context: CGContext, _ color: IconColor) {
        context.setStrokeColor(
            red: color.red,
            green: color.green,
            blue: color.blue,
            alpha: color.alpha
        )
    }

    // MARK: - Drawing

    /// Draws the mark so its outer extent exactly fills `box`.
    ///
    /// The caller supplies both colours, which is what lets the app icon use
    /// off-white plus lime and the menu bar template use a single flat black
    /// for the identical silhouette.
    public static func drawMark(
        in context: CGContext,
        fitting box: CGRect,
        spec: MarkSpec = .standard,
        loopColor: IconColor,
        coreColor: IconColor
    ) {
        let bounds = spec.bounds
        let scale = Double(box.width) / bounds.size
        let offset = IconPoint(
            Double(box.minX) - bounds.origin.x * scale,
            Double(box.minY) - bounds.origin.y * scale
        )

        context.saveGState()
        setStroke(context, loopColor)
        context.setLineWidth(spec.loopWidth * scale)
        context.setLineCap(.round)
        for arc in spec.arcs {
            context.addPath(cgPath(arc, scale: scale, offset: offset))
            context.strokePath()
        }
        setFill(context, coreColor)
        context.addPath(cgPath(spec.core, scale: scale, offset: offset))
        context.fillPath()
        context.restoreGState()
    }

    /// Draws the full app icon — plate plus mark — into a square canvas.
    public static func drawAppIcon(
        in context: CGContext,
        canvas: CGFloat,
        spec: AppIconSpec = .standard
    ) {
        let plateSize = Double(canvas) * spec.plateFraction
        let center = IconPoint(Double(canvas) / 2, Double(canvas) / 2)

        context.saveGState()
        setFill(context, spec.plateColor)
        let plate = IconPath.superellipse(
            center: center,
            halfSize: plateSize / 2,
            exponent: spec.plateExponent,
            sampleCount: 720
        )
        context.addPath(cgPath(plate, scale: 1, offset: IconPoint(0, 0)))
        context.fillPath()
        context.restoreGState()

        let markSize = plateSize * spec.markFraction
        drawMark(
            in: context,
            fitting: CGRect(
                x: center.x - markSize / 2,
                y: center.y - markSize / 2,
                width: markSize,
                height: markSize
            ),
            spec: spec.mark,
            loopColor: spec.loopColor,
            coreColor: spec.coreColor
        )
    }

    // MARK: - Rasterising

    /// A bitmap context whose coordinates are y-down, matching the geometry.
    public static func makeContext(pixelWidth: Int, pixelHeight: Int) throws -> CGContext {
        guard
            let context = CGContext(
                data: nil,
                width: pixelWidth,
                height: pixelHeight,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else {
            throw IconRenderError.contextUnavailable
        }
        context.translateBy(x: 0, y: CGFloat(pixelHeight))
        context.scaleBy(x: 1, y: -1)
        context.setAllowsAntialiasing(true)
        context.interpolationQuality = .high
        return context
    }

    public static func pngData(from context: CGContext) throws -> Data {
        guard let image = context.makeImage() else { throw IconRenderError.encodingFailed }
        let data = NSMutableData()
        guard
            let destination = CGImageDestinationCreateWithData(
                data,
                UTType.png.identifier as CFString,
                1,
                nil
            )
        else {
            throw IconRenderError.encodingFailed
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw IconRenderError.encodingFailed }
        return data as Data
    }

    public static func appIconPNG(pixels: Int, spec: AppIconSpec = .standard) throws -> Data {
        let context = try makeContext(pixelWidth: pixels, pixelHeight: pixels)
        drawAppIcon(in: context, canvas: CGFloat(pixels), spec: spec)
        return try pngData(from: context)
    }

    /// The menu bar silhouette: the same mark, flat black on transparency, so
    /// it can be used as a template image.
    public static func templatePNG(
        pixels: Int,
        spec: MarkSpec = .standard,
        padding: Double = 0
    ) throws -> Data {
        let context = try makeContext(pixelWidth: pixels, pixelHeight: pixels)
        let inset = Double(pixels) * padding
        drawMark(
            in: context,
            fitting: CGRect(
                x: inset,
                y: inset,
                width: Double(pixels) - 2 * inset,
                height: Double(pixels) - 2 * inset
            ),
            spec: spec,
            loopColor: .black,
            coreColor: .black
        )
        return try pngData(from: context)
    }
}

extension IconRenderer {
    /// The status-item glyph.
    ///
    /// Built in code from the same `MarkSpec` as the app icon and flagged as a
    /// template, so AppKit tints it for light and dark menu bars and inverts it
    /// while the popover is open. Nothing here carries colour.
    public static func menuBarImage(
        pointSize: CGFloat = 18,
        markSize: CGFloat = 15,
        spec: MarkSpec = .standard
    ) -> NSImage {
        let image = NSImage(
            size: NSSize(width: pointSize, height: pointSize),
            flipped: false
        ) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.translateBy(x: 0, y: rect.height)
            context.scaleBy(x: 1, y: -1)
            let inset = (rect.width - markSize) / 2
            drawMark(
                in: context,
                fitting: CGRect(x: inset, y: inset, width: markSize, height: markSize),
                spec: spec,
                loopColor: .black,
                coreColor: .black
            )
            return true
        }
        image.isTemplate = true
        return image
    }
}
