import Foundation

/// A point in the icon's own coordinate space, which is always y-down so the
/// same numbers describe the shape in CoreGraphics and in SVG.
public struct IconPoint: Equatable, Sendable {
    public var x: Double
    public var y: Double

    public init(_ x: Double, _ y: Double) {
        self.x = x
        self.y = y
    }
}

/// A resolution-independent outline.
///
/// Everything the icon needs is expressed with move / line / cubic / close, so
/// a single description can be replayed into a `CGPath` for rasterising and
/// serialised to SVG without either backend re-deriving the geometry.
public struct IconPath: Equatable, Sendable {
    public enum Element: Equatable, Sendable {
        case move(IconPoint)
        case line(IconPoint)
        case cubic(to: IconPoint, control1: IconPoint, control2: IconPoint)
        case close
    }

    public var elements: [Element]

    public init(_ elements: [Element] = []) {
        self.elements = elements
    }
}

extension IconPath {
    /// Circular arc, swept from `fromDegrees` to `toDegrees` around `center`.
    ///
    /// Angles are measured from the +x axis and increase towards +y, which in
    /// this y-down space reads as clockwise on screen. The sweep is split into
    /// quarter-turn cubics using the standard `4/3·tan(Δ/4)` handle length,
    /// which is accurate to well under a pixel at 1024 px.
    public static func arc(
        center: IconPoint,
        radius: Double,
        fromDegrees: Double,
        toDegrees: Double
    ) -> IconPath {
        let sweep = toDegrees - fromDegrees
        let segmentCount = max(1, Int(ceil(abs(sweep) / 90)))
        let step = sweep / Double(segmentCount)
        let handle = (4.0 / 3.0) * tan((step * .pi / 180) / 4)

        var elements: [Element] = [.move(Self.point(center, radius, fromDegrees))]
        for index in 0..<segmentCount {
            let start = fromDegrees + step * Double(index)
            let end = start + step
            let startPoint = Self.point(center, radius, start)
            let endPoint = Self.point(center, radius, end)
            let startTangent = Self.tangent(radius, start)
            let endTangent = Self.tangent(radius, end)
            elements.append(
                .cubic(
                    to: endPoint,
                    control1: IconPoint(
                        startPoint.x + handle * startTangent.x,
                        startPoint.y + handle * startTangent.y
                    ),
                    control2: IconPoint(
                        endPoint.x - handle * endTangent.x,
                        endPoint.y - handle * endTangent.y
                    )
                )
            )
        }
        return IconPath(elements)
    }

    /// Axis-aligned rounded square, built from the same circular-arc handles.
    public static func roundedSquare(
        center: IconPoint,
        side: Double,
        cornerRadius: Double
    ) -> IconPath {
        let half = side / 2
        let radius = min(cornerRadius, half)
        let handle = 0.552_284_749_830_793_6 * radius

        let left = center.x - half
        let right = center.x + half
        let top = center.y - half
        let bottom = center.y + half

        func corner(
            from start: IconPoint,
            around pivot: IconPoint,
            to end: IconPoint
        ) -> Element {
            .cubic(
                to: end,
                control1: IconPoint(
                    start.x + handle * (pivot.x - start.x) / radius,
                    start.y + handle * (pivot.y - start.y) / radius
                ),
                control2: IconPoint(
                    end.x + handle * (pivot.x - end.x) / radius,
                    end.y + handle * (pivot.y - end.y) / radius
                )
            )
        }

        return IconPath([
            .move(IconPoint(left + radius, top)),
            .line(IconPoint(right - radius, top)),
            corner(
                from: IconPoint(right - radius, top),
                around: IconPoint(right, top),
                to: IconPoint(right, top + radius)
            ),
            .line(IconPoint(right, bottom - radius)),
            corner(
                from: IconPoint(right, bottom - radius),
                around: IconPoint(right, bottom),
                to: IconPoint(right - radius, bottom)
            ),
            .line(IconPoint(left + radius, bottom)),
            corner(
                from: IconPoint(left + radius, bottom),
                around: IconPoint(left, bottom),
                to: IconPoint(left, bottom - radius)
            ),
            .line(IconPoint(left, top + radius)),
            corner(
                from: IconPoint(left, top + radius),
                around: IconPoint(left, top),
                to: IconPoint(left + radius, top)
            ),
            .close
        ])
    }

    /// Superellipse `|x/a|^n + |y/a|^n = 1`.
    ///
    /// At `n = 5` this sits within ~1% of Apple's macOS icon plate while being
    /// continuously curved by construction, so the corners never show the
    /// curvature break a circular rounded rectangle has.
    public static func superellipse(
        center: IconPoint,
        halfSize: Double,
        exponent: Double,
        sampleCount: Int
    ) -> IconPath {
        precondition(sampleCount >= 8, "a superellipse needs a usable sample count")
        let power = 2 / exponent
        var elements: [Element] = []
        for index in 0..<sampleCount {
            let angle = 2 * Double.pi * Double(index) / Double(sampleCount)
            let cosine = cos(angle)
            let sine = sin(angle)
            let point = IconPoint(
                center.x + halfSize * copysign(pow(abs(cosine), power), cosine),
                center.y + halfSize * copysign(pow(abs(sine), power), sine)
            )
            elements.append(index == 0 ? .move(point) : .line(point))
        }
        elements.append(.close)
        return IconPath(elements)
    }

    private static func point(_ center: IconPoint, _ radius: Double, _ degrees: Double) -> IconPoint {
        let radians = degrees * .pi / 180
        return IconPoint(center.x + radius * cos(radians), center.y + radius * sin(radians))
    }

    private static func tangent(_ radius: Double, _ degrees: Double) -> IconPoint {
        let radians = degrees * .pi / 180
        return IconPoint(-radius * sin(radians), radius * cos(radians))
    }
}
