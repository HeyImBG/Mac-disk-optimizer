import Foundation
import Testing
@testable import DiskEngine

private struct FakeReader: ProtectedPathReader {
    var results: [String: ProbeResult]
    func probe(path: String) -> ProbeResult { results[path] ?? .missing }
}

private func checker(_ results: [String: ProbeResult]) -> FullDiskAccessChecker {
    FullDiskAccessChecker(reader: FakeReader(results: results), paths: ["/a", "/b", "/c"])
}

@Test func grantedWhenAnyProbeIsReadable() {
    #expect(checker(["/a": .denied, "/b": .readable]).check() == .granted)
    #expect(checker(["/c": .readable]).check() == .granted)
}

@Test func deniedWhenExistingFolderIsBlocked() {
    #expect(checker(["/a": .missing, "/b": .denied]).check() == .denied)
}

@Test func unknownWhenNothingExists() {
    #expect(checker([:]).check() == .unknown)
}

@Test func defaultPathsAreInHome() {
    let paths = FullDiskAccessChecker.defaultProbePaths(home: "/Users/test")
    #expect(paths.contains("/Users/test/Library/Safari"))
    #expect(paths.allSatisfy { $0.hasPrefix("/Users/test/") })
}

@Test func systemReaderReportsReadableAndMissing() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("FDATests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let reader = SystemProtectedPathReader()
    #expect(reader.probe(path: dir.path) == .readable)
    #expect(reader.probe(path: dir.appendingPathComponent("nope").path) == .missing)
}

@Test func linkOpenStopsAtFirstSuccess() {
    var tried: [URL] = []
    let used = FullDiskAccessLinks.open { url in
        tried.append(url)
        return tried.count == 2
    }
    #expect(used == FullDiskAccessLinks.urls[1])
    #expect(tried.count == 2)
}

@Test func linkOpenReturnsNilWhenAllFail() {
    var count = 0
    let used = FullDiskAccessLinks.open { _ in count += 1; return false }
    #expect(used == nil)
    #expect(count == FullDiskAccessLinks.urls.count)
}
