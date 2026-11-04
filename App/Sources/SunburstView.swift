import SwiftUI
import DiskEngine

/// Draws the sunburst chart. The center hole goes up one folder; a folder slice drills in.
struct SunburstView: View {
    let arcs: [SunburstArc]
    /// Name and size of the folder being shown, written in the center hole.
    let centerName: String
    let centerSize: Int64
    let maxDepth: Int
    let onSelect: (SunburstArc) -> Void
    let onCenter: () -> Void

    private let innerFraction = 0.18
    @State private var hovered: SunburstArc?

    var body: some View {
        GeometryReader { proxy in
            let geo = Geometry(size: proxy.size, maxDepth: maxDepth, innerFraction: innerFraction)
            Canvas { context, _ in
                for arc in arcs {
                    let path = Self.path(for: arc, center: geo.center, inner: geo.inner, ring: geo.ring)
                    context.fill(path, with: .color(Self.color(for: arc)))
                    context.stroke(path, with: .color(.black.opacity(0.25)), lineWidth: 0.5)
                }
                if let hovered {
                    let outline = Self.path(for: hovered, center: geo.center, inner: geo.inner, ring: geo.ring)
                    context.stroke(outline, with: .color(.white), lineWidth: 2)
                }
            }
            .overlay { centerLabel(geo) }
            .overlay(alignment: .top) { hoverCaption }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    let dx = Double(location.x - geo.center.x)
                    let dy = Double(location.y - geo.center.y)
                    hovered = SunburstLayout.hit(in: arcs, dx: dx, dy: dy, innerRadius: geo.inner, ringWidth: geo.ring)
                case .ended:
                    hovered = nil
                }
            }
            .gesture(
                SpatialTapGesture().onEnded { tap in
                    let dx = Double(tap.location.x - geo.center.x)
                    let dy = Double(tap.location.y - geo.center.y)
                    if (dx * dx + dy * dy).squareRoot() < geo.inner {
                        onCenter()
                    } else if let arc = SunburstLayout.hit(
                        in: arcs, dx: dx, dy: dy, innerRadius: geo.inner, ringWidth: geo.ring) {
                        onSelect(arc)
                    }
                }
            )
        }
    }

    /// Folder name and total in the middle, so it is clear what the whole circle stands for.
    private func centerLabel(_ geo: Geometry) -> some View {
        VStack(spacing: 2) {
            Text(centerName).font(.caption.bold()).lineLimit(1)
            Text(ByteCountFormatter.string(fromByteCount: centerSize, countStyle: .file)).font(.caption2)
        }
        .foregroundStyle(.secondary)
        .frame(width: geo.inner * 1.7)
        .position(geo.center)
        .allowsHitTesting(false)
    }

    /// Name, size and share of the slice under the pointer, or a hint when nothing is hovered.
    private var hoverCaption: some View {
        let text: String
        if let hovered {
            text = SunburstLayout.caption(for: hovered, total: centerSize) {
                ByteCountFormatter.string(fromByteCount: $0, countStyle: .file)
            }
        } else {
            text = "Point at a slice to see what it is. Click a folder to open it, or the middle to go back."
        }
        return Text(text)
            .font(.callout)
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(.regularMaterial, in: Capsule())
            .padding(.top, 4)
            .allowsHitTesting(false)
    }

    struct Geometry {
        let center: CGPoint
        let inner: Double
        let ring: Double

        init(size: CGSize, maxDepth: Int, innerFraction: Double) {
            center = CGPoint(x: size.width / 2, y: size.height / 2)
            let radius = max(0, Double(min(size.width, size.height)) / 2 - 8)
            inner = radius * innerFraction
            ring = (radius - inner) / Double(max(1, maxDepth))
        }
    }

    static func color(for arc: SunburstArc) -> Color {
        let brightness = max(0.45, 0.95 - 0.12 * Double(arc.depth - 1))
        return Color(hue: arc.hue, saturation: arc.isDirectory ? 0.55 : 0.3, brightness: brightness)
    }

    /// Ring segment built from short straight pieces, so the angle convention is unambiguous:
    /// 0 at 12 o'clock, clockwise.
    static func path(for arc: SunburstArc, center: CGPoint, inner: Double, ring: Double) -> Path {
        let r0 = inner + ring * Double(arc.depth - 1)
        let r1 = r0 + ring
        let steps = max(2, Int(((arc.endAngle - arc.startAngle) / (2 * .pi)) * 180) + 1)
        func point(_ radius: Double, _ angle: Double) -> CGPoint {
            CGPoint(x: center.x + CGFloat(radius * sin(angle)), y: center.y - CGFloat(radius * cos(angle)))
        }
        var path = Path()
        for i in 0...steps {
            let a = arc.startAngle + (arc.endAngle - arc.startAngle) * Double(i) / Double(steps)
            if i == 0 { path.move(to: point(r1, a)) } else { path.addLine(to: point(r1, a)) }
        }
        for i in stride(from: steps, through: 0, by: -1) {
            let a = arc.startAngle + (arc.endAngle - arc.startAngle) * Double(i) / Double(steps)
            path.addLine(to: point(r0, a))
        }
        path.closeSubpath()
        return path
    }
}
