import Foundation

public struct IconColor: Equatable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    public init(hex: UInt32, alpha: Double = 1) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            alpha: alpha
        )
    }

    public static let black = IconColor(hex: 0x000000)
}

/// The Tiny Harness mark: two opposing thick rounded arcs forming an open loop
/// around a small central square.
///
/// Defined in a unit box with the loop centred on (0.5, 0.5), so one
/// description drives the 1024 px app icon and the 16 pt menu bar glyph.
public struct MarkSpec: Equatable, Sendable {
    /// Centreline radius of the loop.
    public var loopRadius: Double
    /// Stroke weight of each arc.
    public var loopWidth: Double
    /// Half the angular width of each of the two gaps.
    public var gapHalfAngle: Double
    /// Where the first gap is centred. The second sits exactly opposite, which
    /// is what makes the two arcs read as one loop rather than two crescents.
    public var gapAxis: Double
    public var coreSide: Double
    public var coreCornerRadius: Double

    public init(
        loopRadius: Double = 0.294,
        loopWidth: Double = 0.132,
        gapHalfAngle: Double = 23,
        gapAxis: Double = -45,
        coreSide: Double = 0.216,
        coreCornerRadius: Double = 0.046
    ) {
        self.loopRadius = loopRadius
        self.loopWidth = loopWidth
        self.gapHalfAngle = gapHalfAngle
        self.gapAxis = gapAxis
        self.coreSide = coreSide
        self.coreCornerRadius = coreCornerRadius
    }

    public static let standard = MarkSpec()

    public static let center = IconPoint(0.5, 0.5)

    /// Outer edge of the stroked loop; the mark's true visual extent.
    public var outerRadius: Double { loopRadius + loopWidth / 2 }

    /// Inner edge of the stroked loop.
    public var innerRadius: Double { loopRadius - loopWidth / 2 }

    /// The mark's bounding box in unit space, used to fit it into any target.
    public var bounds: (origin: IconPoint, size: Double) {
        (IconPoint(0.5 - outerRadius, 0.5 - outerRadius), 2 * outerRadius)
    }

    /// The two arcs, to be stroked at `loopWidth` with round caps.
    public var arcs: [IconPath] {
        [
            .arc(
                center: Self.center,
                radius: loopRadius,
                fromDegrees: gapAxis + gapHalfAngle,
                toDegrees: gapAxis + 180 - gapHalfAngle
            ),
            .arc(
                center: Self.center,
                radius: loopRadius,
                fromDegrees: gapAxis + 180 + gapHalfAngle,
                toDegrees: gapAxis + 360 - gapHalfAngle
            )
        ]
    }

    /// The central square, to be filled.
    public var core: IconPath {
        .roundedSquare(center: Self.center, side: coreSide, cornerRadius: coreCornerRadius)
    }

    /// Straight-line clearance between the two round arc caps across a gap.
    ///
    /// This is the measurement that decides whether the loop still reads as
    /// open at 16 px, so it is derived rather than eyeballed.
    public var gapClearance: Double {
        2 * loopRadius * sin(gapHalfAngle * .pi / 180) - loopWidth
    }

    /// Clearance between the central square's corners and the loop's inner edge.
    public var coreClearance: Double {
        innerRadius - (coreSide / 2) * 2.0.squareRoot()
    }
}

/// The macOS app icon: the mark on a flat warm-graphite squircle plate.
public struct AppIconSpec: Equatable, Sendable {
    public var mark: MarkSpec
    /// Fraction of the full canvas occupied by the plate. Apple's macOS grid
    /// puts an 824 pt plate on a 1024 pt canvas.
    public var plateFraction: Double
    public var plateExponent: Double
    /// Width of the mark as a fraction of the plate.
    public var markFraction: Double
    public var plateColor: IconColor
    public var loopColor: IconColor
    public var coreColor: IconColor

    public init(
        mark: MarkSpec = .standard,
        plateFraction: Double = 824.0 / 1024.0,
        plateExponent: Double = 5,
        markFraction: Double = 0.54,
        plateColor: IconColor = IconColor(hex: 0x24211D),
        loopColor: IconColor = IconColor(hex: 0xF4F1E8),
        coreColor: IconColor = IconColor(hex: 0xB4CE55)
    ) {
        self.mark = mark
        self.plateFraction = plateFraction
        self.plateExponent = plateExponent
        self.markFraction = markFraction
        self.plateColor = plateColor
        self.loopColor = loopColor
        self.coreColor = coreColor
    }

    public static let standard = AppIconSpec()

    /// The `.iconset` members `iconutil` requires for a complete macOS icon.
    /// Each entry is a file name and the pixel size it must be rendered at.
    public static let iconsetEntries: [(name: String, pixels: Int)] = [
        ("icon_16x16.png", 16),
        ("icon_16x16@2x.png", 32),
        ("icon_32x32.png", 32),
        ("icon_32x32@2x.png", 64),
        ("icon_128x128.png", 128),
        ("icon_128x128@2x.png", 256),
        ("icon_256x256.png", 256),
        ("icon_256x256@2x.png", 512),
        ("icon_512x512.png", 512),
        ("icon_512x512@2x.png", 1024)
    ]
}
