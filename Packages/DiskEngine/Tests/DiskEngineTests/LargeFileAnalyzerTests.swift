import Foundation
import Testing
@testable import DiskEngine

private func file(_ dir: String, _ name: String, _ size: Int64) -> FileNode {
    FileNode(name: name, path: "\(dir)/\(name)", isDirectory: false, size: size)
}

private func folder(_ path: String, _ children: [FileNode]) -> FileNode {
    FileNode(name: URL(fileURLWithPath: path).lastPathComponent, path: path, isDirectory: true, children: children)
}

private let MB: Int64 = 1_000_000

/// /h
///   Movies/film.mov 900MB, clip.MP4 150MB, tiny.mov 1MB
///   Downloads/old.dmg 400MB, setup.pkg 120MB, notes.txt 2MB
///   deep/a/b/huge.bin 2000MB
private func fixture() -> ScanIndex {
    let movies = folder("/h/Movies", [file("/h/Movies", "film.mov", 900 * MB),
                                      file("/h/Movies", "clip.MP4", 150 * MB),
                                      file("/h/Movies", "tiny.mov", 1 * MB)])
    let downloads = folder("/h/Downloads", [file("/h/Downloads", "old.dmg", 400 * MB),
                                            file("/h/Downloads", "setup.pkg", 120 * MB),
                                            file("/h/Downloads", "notes.txt", 2 * MB)])
    let deep = folder("/h/deep", [folder("/h/deep/a", [folder("/h/deep/a/b", [file("/h/deep/a/b", "huge.bin", 2000 * MB)])])])
    return ScanIndex(root: folder("/h", [movies, downloads, deep]))
}

private struct FakeDates: FileDateProvider {
    var dates: [String: Date]
    func lastOpened(path: String) -> Date? { dates[path] }
}

private func day(_ n: Int) -> Date { Date(timeIntervalSince1970: Double(n) * 86_400) }

@Test func classifiesByExtension() {
    #expect(FileKind.classify(name: "a.MOV") == .video)
    #expect(FileKind.classify(name: "a.dmg") == .diskImage)
    #expect(FileKind.classify(name: "a.pkg") == .installer)
    #expect(FileKind.classify(name: "a.tar") == .archive)
    #expect(FileKind.classify(name: "a.PDF") == .document)
    #expect(FileKind.classify(name: "noextension") == .other)
    #expect(FileKind.classify(name: "weird.xyz") == .other)
}

@Test func findsLargeFilesBiggestFirstFindingDeepOnes() {
    let found = LargeFileAnalyzer(dates: FakeDates(dates: [:])).find(in: fixture())   // default 100 MB
    #expect(found.map(\.name) == ["huge.bin", "film.mov", "old.dmg", "clip.MP4", "setup.pkg"])
    #expect(found[0].path == "/h/deep/a/b/huge.bin")
    #expect(found[0].kind == .other)
}

@Test func thresholdChangesResults() {
    let found = LargeFileAnalyzer(dates: FakeDates(dates: [:]))
        .find(in: fixture(), query: LargeFileQuery(minSize: 500 * MB))
    #expect(found.map(\.name) == ["huge.bin", "film.mov"])
    let small = LargeFileAnalyzer(dates: FakeDates(dates: [:]))
        .find(in: fixture(), query: LargeFileQuery(minSize: 1 * MB))
    #expect(small.count == 7)
}

@Test func filtersByKind() {
    let found = LargeFileAnalyzer(dates: FakeDates(dates: [:]))
        .find(in: fixture(), query: LargeFileQuery(minSize: 1 * MB, kinds: [.video]))
    #expect(found.map(\.name) == ["film.mov", "clip.MP4", "tiny.mov"])
    let installers = LargeFileAnalyzer(dates: FakeDates(dates: [:]))
        .find(in: fixture(), query: LargeFileQuery(kinds: [.installer, .diskImage]))
    #expect(installers.map(\.name) == ["old.dmg", "setup.pkg"])
}

@Test func onlyFilesNotOpenedSinceTheCutoff() {
    let dates = FakeDates(dates: [
        "/h/Movies/film.mov": day(100),       // opened after the cutoff
        "/h/Downloads/old.dmg": day(200),     // opened after the cutoff
        "/h/Movies/clip.MP4": day(50),        // opened before the cutoff
        // huge.bin and setup.pkg: unknown
    ])
    let query = LargeFileQuery(notOpenedSince: day(60))
    let found = LargeFileAnalyzer(dates: dates).find(in: fixture(), query: query)
    // Only clip.MP4 (day 50) was last opened before day 60; unknown dates are left out.
    #expect(found.map(\.name) == ["clip.MP4"])
    #expect(found[0].lastOpened == day(50))
}

@Test func unknownDatesAreKeptWhenThereIsNoDateFilter() {
    let found = LargeFileAnalyzer(dates: FakeDates(dates: [:])).find(in: fixture())
    #expect(found.allSatisfy { $0.lastOpened == nil })
    #expect(!found.isEmpty)
}

@Test func limitCapsTheList() {
    let found = LargeFileAnalyzer(dates: FakeDates(dates: [:]))
        .find(in: fixture(), query: LargeFileQuery(limit: 2))
    #expect(found.map(\.name) == ["huge.bin", "film.mov"])
    #expect(LargeFileAnalyzer(dates: FakeDates(dates: [:])).find(in: fixture(), query: LargeFileQuery(limit: 0)).isEmpty)
}

@Test func systemDateProviderReadsARealTempFile() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("LargeFileTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("f.bin")
    try Data(count: 10).write(to: url)
    let date = try #require(SystemFileDateProvider().lastOpened(path: url.path))
    #expect(abs(date.timeIntervalSinceNow) < 3600)
    #expect(SystemFileDateProvider().lastOpened(path: dir.appendingPathComponent("missing").path) == nil)
}
