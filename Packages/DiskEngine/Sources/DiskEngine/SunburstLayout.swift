import Foundation

/// One slice of the sunburst chart. Angles are in radians, 0 at 12 o'clock, growing clockwise.
public struct SunburstArc: Sendable, Equatable, Identifiable {
    public var id: String { path }
    public let path: String
    public let name: String
    public let isDirectory: Bool
    public let size: Int64
    /// 1 for the ring next to the center, 2 for the next ring out, and so on.
    public let depth: Int
    public let startAngle: Double
    public let endAngle: Double
    /// 0 to 1. Inherited from the top-level slice, so each branch keeps one color family.
    public let hue: Double
}

/// Pure layout math for the sunburst chart; no drawing code.
public enum SunburstLayout {
    /// Slices for the children of `node`, up to `maxDepth` rings. A slice's angle is its share
    /// of its parent's size; slices narrower than `minAngle` are left out (their space stays empty).
    public static func arcs(for node: FileNode, maxDepth: Int = 4, minAngle: Double = 0.01) -> [SunburstArc] {
        var result: [SunburstArc] = []
        add(children: node, start: 0, span: 2 * .pi, depth: 1, hue: nil,
            maxDepth: maxDepth, minAngle: minAngle, into: &result)
        return result
    }

    /// The slice under a point, given as an offset from the chart center (x right, y down).
    /// Nil inside the center hole, outside the rings, or over an empty gap.
    public static func hit(in arcs: [SunburstArc], dx: Double, dy: Double,
                           innerRadius: Double, ringWidth: Double) -> SunburstArc? {
        let radius = (dx * dx + dy * dy).squareRoot()
        guard ringWidth > 0, radius >= innerRadius else { return nil }
        let depth = Int((radius - innerRadius) / ringWidth) + 1
        var angle = atan2(dx, -dy)
        if angle < 0 { angle += 2 * .pi }
        return arcs.first { $0.depth == depth && angle >= $0.startAngle && angle < $0.endAngle }
    }

    /// One line for a slice, for example `Downloads · 42 GB · 13%`. `total` is the size of the
    /// folder the chart is showing, so the percentage is a share of that folder.
    public static func caption(for arc: SunburstArc, total: Int64, format: (Int64) -> String) -> String {
        guard total > 0 else { return "\(arc.name) · \(format(arc.size))" }
        let percent = Double(arc.size) / Double(total) * 100
        let shown = percent < 1 ? "<1%" : "\(Int(percent.rounded()))%"
        return "\(arc.name) · \(format(arc.size)) · \(shown)"
    }

    private static func add(children parent: FileNode, start: Double, span: Double, depth: Int,
                            hue: Double?, maxDepth: Int, minAngle: Double,
                            into out: inout [SunburstArc]) {
        guard depth <= maxDepth, parent.size > 0 else { return }
        var cursor = start
        let count = max(1, parent.children.count)
        for (index, child) in parent.children.enumerated() {
            guard child.size > 0 else { continue }
            let childSpan = span * Double(child.size) / Double(parent.size)
            defer { cursor += childSpan }
            if childSpan < minAngle { continue }
            let childHue = hue ?? Double(index) / Double(count)
            out.append(SunburstArc(
                path: child.path, name: child.name, isDirectory: child.isDirectory, size: child.size,
                depth: depth, startAngle: cursor, endAngle: cursor + childSpan, hue: childHue))
            if child.isDirectory {
                add(children: child, start: cursor, span: childSpan, depth: depth + 1, hue: childHue,
                    maxDepth: maxDepth, minAngle: minAngle, into: &out)
            }
        }
    }
}
