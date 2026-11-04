import Foundation
import Testing
@testable import DiskEngine

private func file(_ dir: String, _ name: String, _ size: Int64) -> FileNode {
    FileNode(name: name, path: "\(dir)/\(name)", isDirectory: false, size: size)
}

/// /r (600): a.bin 300, b/ 200 (x 150, y 50), c.bin 100
private func sample() -> FileNode {
    let b = FileNode(name: "b", path: "/r/b", isDirectory: true,
                     children: [file("/r/b", "x", 150), file("/r/b", "y", 50)])
    let root = FileNode(name: "r", path: "/r", isDirectory: true,
                        children: [file("/r", "a.bin", 300), b, file("/r", "c.bin", 100)])
    return ScanIndex(root: root).root
}

private let fullCircle = 2 * Double.pi

@Test func firstRingSharesAreProportional() throws {
    let arcs = SunburstLayout.arcs(for: sample())
    let ring1 = arcs.filter { $0.depth == 1 }
    #expect(ring1.map(\.name) == ["a.bin", "b", "c.bin"])
    let a = try #require(ring1.first)
    #expect(a.startAngle == 0)
    #expect(abs(a.endAngle - fullCircle * 0.5) < 1e-9)
    let last = try #require(ring1.last)
    #expect(abs(last.endAngle - fullCircle) < 1e-9)
}

@Test func childRingStaysInsideParent() throws {
    let arcs = SunburstLayout.arcs(for: sample())
    let b = try #require(arcs.first { $0.name == "b" })
    let kids = arcs.filter { $0.depth == 2 }
    #expect(kids.map(\.name) == ["x", "y"])
    #expect(kids.allSatisfy { $0.startAngle >= b.startAngle - 1e-9 && $0.endAngle <= b.endAngle + 1e-9 })
    #expect(abs(kids[0].startAngle - b.startAngle) < 1e-9)
    #expect(abs(kids[0].hue - b.hue) < 1e-9)
}

@Test func depthLimitStopsRings() {
    let arcs = SunburstLayout.arcs(for: sample(), maxDepth: 1)
    #expect(arcs.allSatisfy { $0.depth == 1 })
    #expect(arcs.count == 3)
}

@Test func thinSlicesAreSkipped() {
    let arcs = SunburstLayout.arcs(for: sample(), minAngle: 1.0)
    // y is 50/600 of the circle (about 0.52 rad), below 1.0; c.bin is about 1.05 rad and stays.
    #expect(!arcs.contains { $0.name == "y" })
    #expect(arcs.contains { $0.name == "c.bin" })
}

@Test func emptyFolderHasNoArcs() {
    let empty = FileNode(name: "e", path: "/e", isDirectory: true)
    #expect(SunburstLayout.arcs(for: empty).isEmpty)
}

@Test func hitTestFindsSlices() throws {
    let arcs = SunburstLayout.arcs(for: sample())
    // Ring 1 spans radius 20 to 60 (inner 20, ring width 40).
    // Straight up (angle 0) is the start of a.bin.
    #expect(SunburstLayout.hit(in: arcs, dx: 0, dy: -40, innerRadius: 20, ringWidth: 40)?.name == "a.bin")
    // Straight down is half way round (angle pi): the start of b.
    #expect(SunburstLayout.hit(in: arcs, dx: 0, dy: 40, innerRadius: 20, ringWidth: 40)?.name == "b")
    // Up and a little left of center (angle about 5.8 rad, radius 40): c.bin.
    #expect(SunburstLayout.hit(in: arcs, dx: -18.6, dy: -35.4, innerRadius: 20, ringWidth: 40)?.name == "c.bin")
    // Second ring, straight down: x, the first child of b.
    #expect(SunburstLayout.hit(in: arcs, dx: 0, dy: 80, innerRadius: 20, ringWidth: 40)?.name == "x")
}

@Test func hitTestMissesCenterAndOutside() {
    let arcs = SunburstLayout.arcs(for: sample())
    #expect(SunburstLayout.hit(in: arcs, dx: 5, dy: 5, innerRadius: 20, ringWidth: 40) == nil)
    #expect(SunburstLayout.hit(in: arcs, dx: 0, dy: -500, innerRadius: 20, ringWidth: 40) == nil)
}

@Test func captionShowsNameSizeAndShare() {
    func arc(_ size: Int64) -> SunburstArc {
        SunburstArc(path: "/r/Downloads", name: "Downloads", isDirectory: true, size: size,
                    depth: 1, startAngle: 0, endAngle: 1, hue: 0)
    }
    let fmt: (Int64) -> String = { "\($0) B" }
    #expect(SunburstLayout.caption(for: arc(250), total: 1_000, format: fmt) == "Downloads · 250 B · 25%")
    #expect(SunburstLayout.caption(for: arc(2), total: 1_000, format: fmt) == "Downloads · 2 B · <1%")
    #expect(SunburstLayout.caption(for: arc(5), total: 0, format: fmt) == "Downloads · 5 B")
}
