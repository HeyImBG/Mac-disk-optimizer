import Foundation
import Testing
@testable import DiskEngine

/// Makes a fresh folder inside the system temp directory. Tests only touch files under it.
private func makeTempRoot() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("DiskScannerTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func write(_ url: URL, bytes: Int) throws {
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(count: bytes).write(to: url)
}

private func runScan(_ scanner: DiskScanner, _ root: URL) async -> (events: [ScanEvent], result: ScanResult?) {
    var events: [ScanEvent] = []
    var result: ScanResult?
    for await event in scanner.scan(root: root) {
        events.append(event)
        if case .finished(let r) = event { result = r }
    }
    return (events, result)
}

@Test func scansSizesAndRollsUp() async throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try write(root.appendingPathComponent("a.bin"), bytes: 10_000)
    try write(root.appendingPathComponent("sub/b.bin"), bytes: 20_000)
    try write(root.appendingPathComponent("sub/deeper/c.bin"), bytes: 30_000)

    let (_, result) = await runScan(DiskScanner(denylist: []), root)
    let index = try #require(result?.index)
    let a = try #require(index.node(at: root.resolvingSymlinksInPath().path + "/a.bin"))
    #expect(a.size >= 10_000 && a.size % 512 == 0)
    #expect(index.root.fileCount == 3)
    #expect(index.totalSize >= 60_000)
    let sub = try #require(index.node(at: root.resolvingSymlinksInPath().path + "/sub"))
    #expect(sub.size >= 50_000)
    #expect(sub.size < index.totalSize)
}

@Test func skipsSymlinks() async throws {
    let root = try makeTempRoot()
    let outside = try makeTempRoot()
    defer {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: outside)
    }
    try write(root.appendingPathComponent("real.bin"), bytes: 5_000)
    try write(outside.appendingPathComponent("big.bin"), bytes: 100_000)
    try FileManager.default.createSymbolicLink(
        at: root.appendingPathComponent("linkToDir"), withDestinationURL: outside)
    try FileManager.default.createSymbolicLink(
        at: root.appendingPathComponent("linkToFile"),
        withDestinationURL: outside.appendingPathComponent("big.bin"))

    let (_, result) = await runScan(DiskScanner(denylist: []), root)
    let index = try #require(result?.index)
    let base = root.resolvingSymlinksInPath().path
    #expect(index.node(at: base + "/linkToDir") == nil)
    #expect(index.node(at: base + "/linkToFile") == nil)
    #expect(index.node(at: base + "/real.bin") != nil)
    #expect(index.totalSize < 100_000)
}

@Test func countsHardLinkOnce() async throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let original = root.appendingPathComponent("original.bin")
    try write(original, bytes: 40_000)
    try FileManager.default.linkItem(at: original, to: root.appendingPathComponent("link.bin"))

    let (_, result) = await runScan(DiskScanner(denylist: []), root)
    let index = try #require(result?.index)
    let base = root.resolvingSymlinksInPath().path
    let sizes = [index.node(at: base + "/original.bin")?.size, index.node(at: base + "/link.bin")?.size]
    #expect(sizes.compactMap { $0 }.sorted().first == 0)
    #expect(sizes.compactMap { $0 }.max() ?? 0 >= 40_000)
    // Root folder block + one copy of the file, not two copies.
    #expect(index.totalSize < 80_000)
}

@Test func skipsDenylistedFolders() async throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let base = root.resolvingSymlinksInPath().path
    try write(root.appendingPathComponent("keep/k.bin"), bytes: 1_000)
    try write(root.appendingPathComponent("skip/s.bin"), bytes: 1_000)

    let (_, result) = await runScan(DiskScanner(denylist: [base + "/skip"]), root)
    let index = try #require(result?.index)
    #expect(index.node(at: base + "/skip") == nil)
    #expect(index.node(at: base + "/skip/s.bin") == nil)
    #expect(index.node(at: base + "/keep/k.bin") != nil)
}

@Test func streamsProgressThenFinishes() async throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    for i in 0..<5 { try write(root.appendingPathComponent("d\(i)/f.bin"), bytes: 100) }

    let (events, result) = await runScan(DiskScanner(denylist: [], progressInterval: 1), root)
    #expect(result != nil)
    var last: ScanProgress?
    var progressCount = 0
    for case .progress(let p) in events { last = p; progressCount += 1 }
    #expect(progressCount >= 2)
    #expect(last?.filesScanned == 5)
    if case .finished = events.last { } else { Issue.record("finished must be the last event") }
}

@Test func missingRootFails() async {
    let missing = FileManager.default.temporaryDirectory
        .appendingPathComponent("does-not-exist-\(UUID().uuidString)")
    let (events, result) = await runScan(DiskScanner(), missing)
    #expect(result == nil)
    if case .failed = events.last { } else { Issue.record("expected .failed") }
}

@Test func rootThatIsAFileIsReported() async throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("one.bin")
    try write(file, bytes: 2_000)
    let (_, result) = await runScan(DiskScanner(denylist: []), file)
    #expect(result?.index.root.isDirectory == false)
    #expect((result?.index.totalSize ?? 0) >= 2_000)
}
