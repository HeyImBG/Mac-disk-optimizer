import Foundation
import Testing
@testable import DiskEngine

private let MB: Int64 = 1_000_000

private func file(_ dir: String, _ name: String, _ size: Int64) -> FileNode {
    FileNode(name: name, path: "\(dir)/\(name)", isDirectory: false, size: size)
}

private func folder(_ path: String, _ children: [FileNode]) -> FileNode {
    FileNode(name: URL(fileURLWithPath: path).lastPathComponent, path: path, isDirectory: true, children: children)
}

/// Content is looked up by path, so tests control which files match. Counts calls per mode.
private final class FakeReader: FileContentReader, @unchecked Sendable {
    private let lock = NSLock()
    let quick: [String: String]
    let full: [String: String]
    private(set) var quickCalls = 0
    private(set) var fullCalls = 0

    init(quick: [String: String], full: [String: String]) {
        self.quick = quick
        self.full = full
    }

    func hash(path: String, firstBytes: Int?) throws -> String {
        lock.lock(); defer { lock.unlock() }
        let table = firstBytes == nil ? full : quick
        if firstBytes == nil { fullCalls += 1 } else { quickCalls += 1 }
        guard let h = table[path] else { throw CocoaError(.fileReadNoSuchFile) }
        return h
    }
}

private struct FakeDates: FileDateProvider {
    var dates: [String: Date]
    func lastOpened(path: String) -> Date? { dates[path] }
}

private func day(_ n: Int) -> Date { Date(timeIntervalSince1970: Double(n) * 86_400) }

@Test func groupsOnlyFilesWithSameSizeAndSameContent() {
    // a1, a2, a3 are identical. b1 matches them in size and first 64 KB but not in full.
    // c1 and c2 share a size but differ in the first 64 KB. d is unique in size.
    let index = ScanIndex(root: folder("/h", [
        folder("/h/A", [file("/h/A", "a1", 5 * MB), file("/h/A", "a2", 5 * MB)]),
        folder("/h/B", [file("/h/B", "a3", 5 * MB), file("/h/B", "b1", 5 * MB)]),
        folder("/h/C", [file("/h/C", "c1", 3 * MB), file("/h/C", "c2", 3 * MB), file("/h/C", "d", 9 * MB)]),
    ]))
    let reader = FakeReader(
        quick: ["/h/A/a1": "q1", "/h/A/a2": "q1", "/h/B/a3": "q1", "/h/B/b1": "q1",
                "/h/C/c1": "q2", "/h/C/c2": "q3"],
        full: ["/h/A/a1": "f1", "/h/A/a2": "f1", "/h/B/a3": "f1", "/h/B/b1": "f2"])
    let groups = DuplicateFinder(reader: reader, dates: FakeDates(dates: [:])).find(in: index)

    #expect(groups.count == 1)
    #expect(groups[0].paths == ["/h/A/a1", "/h/A/a2", "/h/B/a3"])
    #expect(groups[0].size == 5 * MB)
    #expect(groups[0].wastedBytes == 10 * MB)
    // The full hash is only read for files that already matched on size and first 64 KB.
    #expect(reader.fullCalls == 4)
    #expect(reader.quickCalls == 6)
}

@Test func ignoresSmallFilesAndPackageContents() {
    let index = ScanIndex(root: folder("/h", [
        file("/h", "s1", 100), file("/h", "s2", 100),
        folder("/h/Foo.app", [file("/h/Foo.app", "x", 5 * MB)]),
        folder("/h/Lib.photoslibrary", [file("/h/Lib.photoslibrary", "y", 5 * MB)]),
        file("/h", "z", 5 * MB),
    ]))
    let same = ["/h/s1": "h", "/h/s2": "h", "/h/Foo.app/x": "h", "/h/Lib.photoslibrary/y": "h", "/h/z": "h"]
    let reader = FakeReader(quick: same, full: same)
    #expect(DuplicateFinder(reader: reader, dates: FakeDates(dates: [:])).find(in: index).isEmpty)
    #expect(reader.quickCalls == 0)
}

@Test func unreadableFilesAreLeftOut() {
    let index = ScanIndex(root: folder("/h", [file("/h", "a", 2 * MB), file("/h", "b", 2 * MB), file("/h", "c", 2 * MB)]))
    let reader = FakeReader(quick: ["/h/a": "q", "/h/b": "q"], full: ["/h/a": "f", "/h/b": "f"])
    let groups = DuplicateFinder(reader: reader, dates: FakeDates(dates: [:])).find(in: index)
    #expect(groups.map(\.paths) == [["/h/a", "/h/b"]])
}

@Test func largestWasteComesFirst() {
    let index = ScanIndex(root: folder("/h", [
        file("/h", "a1", 2 * MB), file("/h", "a2", 2 * MB),
        file("/h", "b1", 8 * MB), file("/h", "b2", 8 * MB),
    ]))
    let all = ["/h/a1": "a", "/h/a2": "a", "/h/b1": "b", "/h/b2": "b"]
    let groups = DuplicateFinder(reader: FakeReader(quick: all, full: all), dates: FakeDates(dates: [:])).find(in: index)
    #expect(groups.map(\.size) == [8 * MB, 2 * MB])
}

@Test func keepNewestOldestAndTies() {
    let group = DuplicateGroup(size: 1, paths: ["/h/a", "/h/b", "/h/c"])
    let finder = DuplicateFinder(reader: FakeReader(quick: [:], full: [:]),
                                 dates: FakeDates(dates: ["/h/a": day(1), "/h/b": day(5), "/h/c": day(3)]))
    #expect(finder.keep(in: group, rule: .newest) == "/h/b")
    #expect(finder.keep(in: group, rule: .oldest) == "/h/a")
    #expect(finder.removalSuggestions(for: group, rule: .newest) == ["/h/a", "/h/c"])

    // No dates at all: ties go to the first path, so the result is stable.
    let blank = DuplicateFinder(reader: FakeReader(quick: [:], full: [:]), dates: FakeDates(dates: [:]))
    #expect(blank.keep(in: group, rule: .newest) == "/h/a")
    // A copy with a date beats copies with none when keeping the newest.
    let partial = DuplicateFinder(reader: FakeReader(quick: [:], full: [:]), dates: FakeDates(dates: ["/h/c": day(2)]))
    #expect(partial.keep(in: group, rule: .newest) == "/h/c")
}

@Test func keepInFolderMatchesWholeFolderNamesOnly() {
    let group = DuplicateGroup(size: 1, paths: ["/h/Photos2/x", "/h/Photos/x", "/h/Photos/sub/x"])
    let finder = DuplicateFinder(reader: FakeReader(quick: [:], full: [:]), dates: FakeDates(dates: [:]))
    // The first copy inside the folder wins, and "/h/Photos2" is not inside "/h/Photos".
    #expect(finder.keep(in: group, rule: .inFolder("/h/Photos/")) == "/h/Photos/x")
    #expect(finder.keep(in: group, rule: .inFolder("/h/Photos")) == "/h/Photos/x")
    // No copy in the folder: no keeper, so no removals are suggested.
    #expect(finder.keep(in: group, rule: .inFolder("/elsewhere")) == nil)
    #expect(finder.removalSuggestions(for: group, rule: .inFolder("/elsewhere")).isEmpty)
    // Always at least one copy survives.
    let removed = finder.removalSuggestions(for: group, rule: .inFolder("/h/Photos"))
    #expect(removed.count == group.paths.count - 1)
}

@Test func findsRealDuplicatesInATempFolder() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("dupes-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    // Longer than 64 KB, and a "near duplicate" that differs only in its last byte.
    var bytes = [UInt8](repeating: 7, count: 200_000)
    let a = root.appendingPathComponent("a.bin"), b = root.appendingPathComponent("b.bin")
    let near = root.appendingPathComponent("near.bin")
    try Data(bytes).write(to: a)
    try Data(bytes).write(to: b)
    bytes[bytes.count - 1] = 8
    try Data(bytes).write(to: near)

    let size = Int64(200_000)
    let index = ScanIndex(root: folder(root.path, [
        file(root.path, "a.bin", size), file(root.path, "b.bin", size), file(root.path, "near.bin", size),
    ]))
    let groups = DuplicateFinder().find(in: index, minSize: 1000)
    #expect(groups.count == 1)
    #expect(groups[0].paths == [a.path, b.path].sorted())
}

@Test func systemReaderQuickHashIgnoresBytesAfterTheLimit() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("hash-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let x = root.appendingPathComponent("x"), y = root.appendingPathComponent("y")
    try Data([1, 2, 3, 4]).write(to: x)
    try Data([1, 2, 9, 9]).write(to: y)
    let reader = SystemFileContentReader()
    #expect(try reader.hash(path: x.path, firstBytes: 2) == reader.hash(path: y.path, firstBytes: 2))
    #expect(try reader.hash(path: x.path, firstBytes: nil) != reader.hash(path: y.path, firstBytes: nil))
    #expect(throws: (any Error).self) { try reader.hash(path: root.appendingPathComponent("missing").path, firstBytes: nil) }
}
