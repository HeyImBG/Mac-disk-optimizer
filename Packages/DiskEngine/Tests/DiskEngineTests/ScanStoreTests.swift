import Foundation
import Testing
@testable import DiskEngine

private func file(_ dir: String, _ name: String, _ size: Int64) -> FileNode {
    FileNode(name: name, path: "\(dir)/\(name)", isDirectory: false, size: size)
}

private func sampleIndex(root: String = "/r", extra: Int64 = 0) -> ScanIndex {
    let sub = FileNode(name: "sub", path: "\(root)/sub", isDirectory: true, size: 4,
                       children: [file("\(root)/sub", "z.bin", 500 + extra), file("\(root)/sub", "y.bin", 100)])
    let empty = FileNode(name: "empty", path: "\(root)/empty", isDirectory: true)
    let top = FileNode(name: URL(fileURLWithPath: root).lastPathComponent, path: root, isDirectory: true,
                       children: [file(root, "a.txt", 10), sub, empty])
    return ScanIndex(root: top)
}

@Test func saveThenLoadRoundTripsTheSameTree() throws {
    let store = try ScanStore()
    let original = sampleIndex()
    let id = try store.save(original)
    let loaded = try #require(try store.loadLatest())
    #expect(loaded.id == id)
    #expect(loaded.rootPath == "/r")
    #expect(loaded.index.root == original.root)
    #expect(loaded.index.totalSize == original.totalSize)
    #expect(loaded.index.node(at: "/r/sub/z.bin")?.size == 500)
    #expect(loaded.index.children(of: "/r/sub").map(\.name) == ["z.bin", "y.bin"])
}

@Test func emptyStoreHasNoLatest() throws {
    #expect(try ScanStore().loadLatest() == nil)
}

@Test func latestWinsAndRootFilterWorks() throws {
    let store = try ScanStore()
    try store.save(sampleIndex(root: "/a"), at: Date(timeIntervalSince1970: 100))
    try store.save(sampleIndex(root: "/b"), at: Date(timeIntervalSince1970: 200))
    try store.save(sampleIndex(root: "/a", extra: 1_000), at: Date(timeIntervalSince1970: 300))

    #expect(try store.loadLatest()?.rootPath == "/a")
    let a = try #require(try store.loadLatest(rootPath: "/a"))
    #expect(a.index.node(at: "/a/sub/z.bin")?.size == 1_500)
    #expect(a.createdAt == Date(timeIntervalSince1970: 300))
    #expect(try store.loadLatest(rootPath: "/b")?.rootPath == "/b")
    #expect(try store.loadLatest(rootPath: "/missing") == nil)
}

@Test func oldScansOfTheSameRootArePruned() throws {
    let store = try ScanStore()
    var ids: [Int64] = []
    for i in 0..<4 {
        ids.append(try store.save(sampleIndex(extra: Int64(i)), keep: 2))
    }
    // Only the newest 2 remain; the latest is the last one saved.
    #expect(try store.loadLatest()?.id == ids[3])
    #expect(try store.loadLatest()?.index.node(at: "/r/sub/z.bin")?.size == 503)
}

@Test func scanSurvivesReopeningTheFile() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("ScanStoreTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let path = dir.appendingPathComponent("scans.sqlite").path

    let original = sampleIndex()
    try ScanStore(path: path).save(original)
    let reopened = try ScanStore(path: path)
    #expect(try reopened.loadLatest()?.index.root == original.root)
}
