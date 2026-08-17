import CoreGraphics
import XCTest
@testable import BobbinIcon

final class IconTests: XCTestCase {
    // MARK: - Geometry

    func testMarkIsTwoOpposingArcsAroundACentredCore() {
        let spec = MarkSpec.standard
        let arcs = spec.arcs
        XCTAssertEqual(arcs.count, 2)

        // The second arc must be the first rotated by exactly half a turn, which
        // is what keeps the loop optically balanced.
        let first = endpoints(of: arcs[0])
        let second = endpoints(of: arcs[1])
        assertRotatedHalfTurn(second.start, from: first.start)
        assertRotatedHalfTurn(second.end, from: first.end)

        // Both gaps are the same width, so neither side reads heavier.
        let gapA = distance(first.end, second.start)
        let gapB = distance(second.end, first.start)
        XCTAssertEqual(gapA, gapB, accuracy: 1e-9)
    }

    func testMarkFitsItsDeclaredBoundsExactly() {
        let spec = MarkSpec.standard
        let bounds = spec.bounds
        XCTAssertEqual(bounds.size, 2 * spec.outerRadius, accuracy: 1e-12)

        // Every arc endpoint sits on the loop centreline, half a stroke inside
        // the declared bounds, so fitting the bounds to a box never clips.
        for arc in spec.arcs {
            for point in [endpoints(of: arc).start, endpoints(of: arc).end] {
                let radius = distance(point, MarkSpec.center)
                XCTAssertEqual(radius, spec.loopRadius, accuracy: 1e-9)
            }
        }
    }

    func testGapAndCoreStaySeparatedAtSixteenPixels() {
        let spec = MarkSpec.standard

        // The glyph is fitted to its bounds, so a unit length is worth
        // `16 / bounds.size` pixels on a 16 px menu bar glyph.
        let pixelsPerUnit = 16.0 / spec.bounds.size
        XCTAssertGreaterThan(
            spec.gapClearance * pixelsPerUnit,
            1.5,
            "the loop must still read as open at 16 px"
        )
        XCTAssertGreaterThan(
            spec.coreClearance * pixelsPerUnit,
            1.0,
            "the core must not touch the loop at 16 px"
        )
    }

    func testIconsetCoversEveryRepresentationIconutilNeeds() throws {
        let entries = AppIconSpec.iconsetEntries
        XCTAssertEqual(entries.count, 10)
        XCTAssertEqual(Set(entries.map(\.name)).count, entries.count)
        XCTAssertEqual(entries.map(\.pixels).max(), 1024)

        // Each @2x entry must be exactly twice its @1x sibling.
        for entry in entries where entry.name.contains("@2x") {
            let base = entry.name.replacingOccurrences(of: "@2x", with: "")
            let sibling = try XCTUnwrap(entries.first { $0.name == base }, entry.name)
            XCTAssertEqual(sibling.pixels * 2, entry.pixels, entry.name)
        }
    }

    // MARK: - Rendering

    func testMenuBarSilhouetteIsATrueMonochromeTemplate() throws {
        let data = try IconRenderer.templatePNG(pixels: 32)
        let pixels = try readPixels(data, size: 32)

        var covered = 0
        for pixel in pixels where pixel.alpha > 0 {
            covered += 1
            // Template images must carry shape in alpha only. Premultiplied
            // black keeps every colour channel at zero.
            XCTAssertEqual(pixel.red, 0, "template pixels must not carry colour")
            XCTAssertEqual(pixel.green, 0, "template pixels must not carry colour")
            XCTAssertEqual(pixel.blue, 0, "template pixels must not carry colour")
        }
        XCTAssertGreaterThan(covered, 100, "the glyph must actually draw something")
        XCTAssertLessThan(covered, pixels.count, "the glyph must not fill its whole frame")
    }

    func testMenuBarImageIsFlaggedAsTemplate() {
        let image = IconRenderer.menuBarImage()
        XCTAssertTrue(image.isTemplate)
        XCTAssertEqual(image.size.width, 18)
        XCTAssertEqual(image.size.height, 18)
    }

    func testAppIconRendersPlateAndCoreColours() throws {
        let spec = AppIconSpec.standard
        let data = try IconRenderer.appIconPNG(pixels: 256, spec: spec)
        let pixels = try readPixels(data, size: 256)

        // Dead centre is the lime core.
        let center = pixels[128 * 256 + 128]
        XCTAssertEqual(Double(center.red) / 255, spec.coreColor.red, accuracy: 0.02)
        XCTAssertEqual(Double(center.green) / 255, spec.coreColor.green, accuracy: 0.02)

        // A point inside the plate but clear of the mark is warm graphite.
        let plate = pixels[30 * 256 + 128]
        XCTAssertEqual(Double(plate.red) / 255, spec.plateColor.red, accuracy: 0.02)
        XCTAssertGreaterThan(
            plate.red,
            plate.blue,
            "the plate should be warm, not neutral or cool"
        )

        // The canvas corner stays transparent so macOS masks the squircle.
        XCTAssertEqual(pixels[0].alpha, 0)
    }

    func testSVGExportIsDeterministicAndWellFormed() {
        let spec = AppIconSpec.standard
        let first = SVGExport.mark(
            spec: spec.mark,
            loopColor: spec.loopColor,
            coreColor: spec.coreColor
        )
        let second = SVGExport.mark(
            spec: spec.mark,
            loopColor: spec.loopColor,
            coreColor: spec.coreColor
        )
        XCTAssertEqual(first, second)
        XCTAssertTrue(first.hasPrefix("<svg"))
        XCTAssertTrue(first.contains("</svg>"))
        XCTAssertFalse(first.lowercased().contains("nan"))
        XCTAssertFalse(first.lowercased().contains("inf"))
        // Two stroked arcs plus one filled core.
        XCTAssertEqual(first.components(separatedBy: "<path").count - 1, 3)
    }

    // MARK: - Helpers

    private struct Pixel {
        var red: UInt8
        var green: UInt8
        var blue: UInt8
        var alpha: UInt8
    }

    private func readPixels(_ data: Data, size: Int) throws -> [Pixel] {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(image.width, size)
        XCTAssertEqual(image.height, size)

        var raw = [UInt8](repeating: 0, count: size * size * 4)
        let context = try XCTUnwrap(
            CGContext(
                data: &raw,
                width: size,
                height: size,
                bitsPerComponent: 8,
                bytesPerRow: size * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        )
        context.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
        return stride(from: 0, to: raw.count, by: 4).map {
            Pixel(red: raw[$0], green: raw[$0 + 1], blue: raw[$0 + 2], alpha: raw[$0 + 3])
        }
    }

    private func endpoints(of path: IconPath) -> (start: IconPoint, end: IconPoint) {
        var start: IconPoint?
        var end: IconPoint?
        for element in path.elements {
            switch element {
            case .move(let point):
                start = start ?? point
                end = point
            case .line(let point):
                end = point
            case .cubic(let point, _, _):
                end = point
            case .close:
                break
            }
        }
        return (start!, end!)
    }

    private func distance(_ lhs: IconPoint, _ rhs: IconPoint) -> Double {
        ((lhs.x - rhs.x) * (lhs.x - rhs.x) + (lhs.y - rhs.y) * (lhs.y - rhs.y)).squareRoot()
    }

    private func assertRotatedHalfTurn(
        _ point: IconPoint,
        from original: IconPoint,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let center = MarkSpec.center
        XCTAssertEqual(point.x, 2 * center.x - original.x, accuracy: 1e-9, file: file, line: line)
        XCTAssertEqual(point.y, 2 * center.y - original.y, accuracy: 1e-9, file: file, line: line)
    }
}
