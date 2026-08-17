import Foundation

/// Serialises the mark to SVG.
///
/// The SVG is generated from the same `MarkSpec` the app renders, so it is a
/// faithful vector source for design review rather than a hand-kept parallel
/// copy that can drift.
public enum SVGExport {
    public static func mark(
        spec: MarkSpec = .standard,
        size: Double = 512,
        loopColor: IconColor,
        coreColor: IconColor
    ) -> String {
        let bounds = spec.bounds
        let scale = size / bounds.size
        let offset = IconPoint(-bounds.origin.x * scale, -bounds.origin.y * scale)

        let arcs = spec.arcs
            .map { pathData($0, scale: scale, offset: offset) }
            .map { data in
                """
                  <path d="\(data)" fill="none" stroke="\(hex(loopColor))" \
                stroke-width="\(number(spec.loopWidth * scale))" stroke-linecap="round"/>
                """
            }
            .joined(separator: "\n")

        let core = """
          <path d="\(pathData(spec.core, scale: scale, offset: offset))" fill="\(hex(coreColor))"/>
        """

        return """
        <svg xmlns="http://www.w3.org/2000/svg" width="\(number(size))" height="\(number(size))" \
        viewBox="0 0 \(number(size)) \(number(size))">
          <title>Bobbin mark</title>
        \(arcs)
        \(core)
        </svg>

        """
    }

    private static func pathData(_ path: IconPath, scale: Double, offset: IconPoint) -> String {
        var parts: [String] = []
        func map(_ point: IconPoint) -> String {
            "\(number(offset.x + point.x * scale)) \(number(offset.y + point.y * scale))"
        }
        for element in path.elements {
            switch element {
            case .move(let point):
                parts.append("M \(map(point))")
            case .line(let point):
                parts.append("L \(map(point))")
            case .cubic(let point, let control1, let control2):
                parts.append("C \(map(control1)) \(map(control2)) \(map(point))")
            case .close:
                parts.append("Z")
            }
        }
        return parts.joined(separator: " ")
    }

    /// Fixed three-decimal formatting keeps the export byte-identical across
    /// runs and machines.
    private static func number(_ value: Double) -> String {
        let rounded = (value * 1000).rounded() / 1000
        let text = String(format: "%.3f", rounded)
        guard text.contains(".") else { return text }
        var trimmed = text
        while trimmed.hasSuffix("0") { trimmed.removeLast() }
        if trimmed.hasSuffix(".") { trimmed.removeLast() }
        return trimmed.isEmpty ? "0" : trimmed
    }

    private static func hex(_ color: IconColor) -> String {
        let red = Int((color.red * 255).rounded())
        let green = Int((color.green * 255).rounded())
        let blue = Int((color.blue * 255).rounded())
        return String(format: "#%02X%02X%02X", red, green, blue)
    }
}
