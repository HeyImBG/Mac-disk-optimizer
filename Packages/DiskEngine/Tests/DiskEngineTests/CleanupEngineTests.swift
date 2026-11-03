import Foundation
import Testing
@testable import DiskEngine

// Every test works inside a temp folder it creates, with a fake home folder and a fake Trash.
// Nothing here touches the real home folder or the real Trash.

private final class Sandbox: @unchecked Sendable {
    let root: String       // real path of the temp folder
    let home: String
    let trash: String
    let logURL: URL

    init() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("CleanupEngineTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        root = CleanupEngine.realPath(base.path)!
        home = root + "/home"
        trash = root + "/trash"
        logURL = URL(fileURLWithPath: root + "/logs/cleanup-log.jsonl")
        for dir in [home + "/Library/Caches", home + "/Library/Logs", home + "/Documents", trash] {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }
    }

    deinit { try? FileManager.default.removeItem(atPath: root) }

    @discardableResult
    func write(_ relative: String, bytes: Int = 5_000) throws -> String {
        let path = home + "/" + relative
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try Data(count: bytes).write(to: URL(fileURLWithPath: path))
        return path
    }

    func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: path) }
    func trashContents() -> [String] { (try? FileManager.default.contentsOfDirectory(atPath: trash)) ?? [] }

    func logLines() throws -> [[String: Any]] {
        guard let text = try? String(contentsOf: logURL, encoding: .utf8) else { return [] }
        return try text.split(separator: "\n").map {
            try #require(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
        }
    }
}

/// Moves items into the sandbox's fake Trash instead of the real one.
private struct FakeTrasher: Trasher {
    let trash: String
    var failing = false
    func trash(path: String) throws -> String? {
        if failing { throw CocoaError(.fileWriteNoPermission) }
        let target = trash + "/" + UUID().uuidString + "-" + (path as NSString).lastPathComponent
        try FileManager.default.moveItem(atPath: path, toPath: target)
        return target
    }
}

private struct RecordingTrasher: Trasher {
    // Used where nothing may be trashed: a call would be a test failure.
    func trash(path: String) throws -> String? {
        Issue.record("trash was called for \(path)")
        return nil
    }
}

private struct FakeApps: RunningAppProvider {
    var ids: Set<String> = []
    func runningBundleIDs() -> Set<String> { ids }
    var notInstalled: Set<String> = []
    func isInstalledApp(_ bundleId: String) -> Bool { !notInstalled.contains(bundleId) }
}

private func engine(_ box: Sandbox, apps: Set<String> = [], trasher: (any Trasher)? = nil,
                    allowed: [String]? = nil) -> CleanupEngine {
    CleanupEngine(home: box.home, allowedRoots: allowed, runningApps: FakeApps(ids: apps),
                  trasher: trasher ?? FakeTrasher(trash: box.trash), logURL: box.logURL,
                  now: { Date(timeIntervalSince1970: 1_700_000_000) })
}

private func request(_ e: CleanupEngine, _ path: String, bundleId: String? = nil) throws -> CleanupRequest {
    CleanupRequest(path: path, bundleId: bundleId, fingerprint: try #require(e.fingerprint(of: path)))
}

private func refusal(_ results: [CleanupResult]) -> CleanupRefusal? {
    if case .refused(let why) = results.first?.outcome { return why }
    return nil
}

// MARK: - Success

@Test func trashesAFileAndAFolderAndLogsIt() throws {
    let box = try Sandbox()
    let file = try box.write("Library/Caches/com.example.app/blob.bin")
    let folder = box.home + "/Library/Caches/com.example.app"
    let other = try box.write("Library/Logs/old.log")
    let e = engine(box)

    let results = e.clean([try request(e, folder, bundleId: "com.example.app"), try request(e, other)])
    #expect(results.count == 2)
    for r in results { if case .trashed(let to) = r.outcome { #expect(to != nil) } else { Issue.record("not trashed: \(r)") } }
    #expect(!box.exists(folder) && !box.exists(file) && !box.exists(other))
    #expect(box.trashContents().count == 2)
    // The cache folder itself was left in place.
    #expect(box.exists(box.home + "/Library/Caches"))

    let lines = try box.logLines()
    #expect(lines.count == 2)
    #expect(lines[0]["outcome"] as? String == "trashed")
    #expect(lines[0]["path"] as? String == folder)
    #expect(lines[0]["bundleId"] as? String == "com.example.app")
    #expect((lines[0]["size"] as? Int ?? 0) >= 5_000)
    #expect(lines[0]["time"] as? String == "2023-11-14T22:13:20Z")
}

@Test func oneRefusalDoesNotStopTheOthers() throws {
    let box = try Sandbox()
    let good = try box.write("Library/Caches/a.bin")
    let e = engine(box)
    let ok = try request(e, good)
    let bad = CleanupRequest(path: box.home + "/Library/Caches/missing", bundleId: nil, fingerprint: ok.fingerprint)
    let results = e.clean([bad, ok])
    #expect(refusal([results[0]]) == .missing)
    if case .trashed = results[1].outcome {} else { Issue.record("second item should be trashed") }
}

@Test func failedTrashIsReportedAndLogged() throws {
    let box = try Sandbox()
    let path = try box.write("Library/Caches/a.bin")
    let e = engine(box, trasher: FakeTrasher(trash: box.trash, failing: true))
    let results = e.clean([try request(e, path)])
    if case .failed = results[0].outcome {} else { Issue.record("expected failure") }
    #expect(box.exists(path))
    #expect(try box.logLines().first?["outcome"] as? String == "failed")
}

// MARK: - Refusals

@Test func refusesPathsThatAreNotCleanAbsolute() throws {
    let box = try Sandbox()
    let e = engine(box, trasher: RecordingTrasher())
    let fp = ItemFingerprint(isDirectory: false, size: 1, fileCount: 1, newestModified: 0)
    for bad in ["relative/path", "", "/", box.home + "/Library/Caches/../../Documents",
                box.home + "/Library/Caches/", box.home + "//Library/Caches/x", box.home + "/Library/./Caches/x",
                box.home + "/Documents\u{0}", box.home + "/Library/Caches/x\u{0}/y"] {
        let r = e.clean([CleanupRequest(path: bad, bundleId: nil, fingerprint: fp)])
        #expect(refusal(r) == .badPath, "\(bad)")
    }
}

@Test func refusesProtectedPathsEvenIfTheyExist() throws {
    let box = try Sandbox()
    try box.write("Library/Keychains/login.keychain-db")
    try box.write("Library/Application Support/Thing/data.db")
    try box.write(".ssh/id_ed25519")
    try box.write("Documents/thesis.pdf")
    let e = engine(box, trasher: RecordingTrasher())
    let fp = ItemFingerprint(isDirectory: true, size: 1, fileCount: 1, newestModified: 0)

    let protected = [
        box.home, box.home + "/Library", box.home + "/Library/Caches", box.home + "/Library/Logs",
        box.home + "/Documents", box.home + "/Desktop", box.home + "/Downloads",
        box.home + "/Library/Keychains", box.home + "/Library/Keychains/login.keychain-db",
        box.home + "/Library/Application Support", box.home + "/Library/Application Support/Thing",
        box.home + "/Library/Application Support/Thing/data.db",
        box.home + "/.ssh", box.home + "/.ssh/id_ed25519",
        box.home + "/Library/Mail/V10/x", box.home + "/Library/Messages/chat.db",
        box.home + "/Library/Containers/com.x/Data", box.home + "/Library/Mobile Documents/x",
        // Case does not get around it (the usual macOS disk ignores case).
        box.home + "/LIBRARY/KEYCHAINS/login.keychain-db", box.home + "/library/caches",
        // Parents of protected folders.
        box.root, "/Users", "/private", "/var",
        // System locations.
        "/System/Library/CoreServices", "/usr/bin/ls", "/bin/sh", "/etc/hosts", "/private/etc/hosts",
        "/Library/Caches/com.apple.x", "/Applications/Safari.app", "/Volumes/External/stuff",
    ]
    for path in protected {
        let r = e.clean([CleanupRequest(path: path, bundleId: nil, fingerprint: fp)])
        #expect(refusal(r) == .protectedPath, "\(path)")
    }
    #expect(box.exists(box.home + "/Library/Keychains/login.keychain-db"))
}

@Test func refusesAnythingOutsideTheAllowedFolders() throws {
    let box = try Sandbox()
    let outside = box.root + "/elsewhere/file.bin"
    try FileManager.default.createDirectory(atPath: box.root + "/elsewhere", withIntermediateDirectories: true)
    try Data(count: 100).write(to: URL(fileURLWithPath: outside))
    // A sibling whose name starts with the home folder's name must not count as inside it.
    let lookalike = box.home + "2/file.bin"
    try FileManager.default.createDirectory(atPath: box.home + "2", withIntermediateDirectories: true)
    try Data(count: 100).write(to: URL(fileURLWithPath: lookalike))

    let e = engine(box, trasher: RecordingTrasher())
    let fp = ItemFingerprint(isDirectory: false, size: 1, fileCount: 1, newestModified: 0)
    for path in [outside, lookalike, "/opt/thing"] {
        #expect(refusal(e.clean([CleanupRequest(path: path, bundleId: nil, fingerprint: fp)])) == .outsideAllowedFolders, "\(path)")
    }
    #expect(box.exists(outside) && box.exists(lookalike))
}

@Test func allowedRootsNarrowWhatCanBeCleaned() throws {
    let box = try Sandbox()
    let cache = try box.write("Library/Caches/a.bin")
    let log = try box.write("Library/Logs/b.log")
    let e = engine(box, trasher: FakeTrasher(trash: box.trash), allowed: [box.home + "/Library/Caches"])
    let results = e.clean([try request(e, cache), try request(e, log)])
    if case .trashed = results[0].outcome {} else { Issue.record("cache should be trashed") }
    #expect(refusal([results[1]]) == .outsideAllowedFolders)
    #expect(box.exists(log))
}

@Test func refusesMissingItems() throws {
    let box = try Sandbox()
    let path = try box.write("Library/Caches/a.bin")
    let e = engine(box, trasher: RecordingTrasher())
    let req = try request(e, path)
    try FileManager.default.removeItem(atPath: path)
    #expect(refusal(e.clean([req])) == .missing)
}

@Test func refusesSymlinks() throws {
    let box = try Sandbox()
    let target = try box.write("Documents/precious.txt")
    let link = box.home + "/Library/Caches/shortcut"
    try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: target)
    let e = engine(box, trasher: RecordingTrasher())
    let fp = ItemFingerprint(isDirectory: false, size: 1, fileCount: 1, newestModified: 0)
    #expect(refusal(e.clean([CleanupRequest(path: link, bundleId: nil, fingerprint: fp)])) == .isSymlink)
    #expect(box.exists(target))
    #expect(e.fingerprint(of: link) == nil)
}

@Test func refusesWhenAFolderOnTheWayIsASymlink() throws {
    let box = try Sandbox()
    let target = try box.write("Documents/project/file.bin")
    let link = box.home + "/Library/Caches/viaLink"
    try FileManager.default.createSymbolicLink(
        atPath: link, withDestinationPath: box.home + "/Documents/project")
    let e = engine(box, trasher: RecordingTrasher())
    let fp = ItemFingerprint(isDirectory: false, size: 1, fileCount: 1, newestModified: 0)
    let r = e.clean([CleanupRequest(path: link + "/file.bin", bundleId: nil, fingerprint: fp)])
    #expect(refusal(r) == .symlinkedParent)
    #expect(box.exists(target))
}

@Test func refusesWhileTheAppIsRunning() throws {
    let box = try Sandbox()
    let path = try box.write("Library/Caches/com.example.app/blob.bin")
    let folder = box.home + "/Library/Caches/com.example.app"
    let e = engine(box, apps: ["com.example.app"], trasher: RecordingTrasher())
    #expect(refusal(e.clean([try request(e, folder, bundleId: "com.example.app")])) == .appRunning(bundleId: "com.example.app"))
    // Bundle ids match without regard to case.
    let e2 = engine(box, apps: ["com.example.app"], trasher: RecordingTrasher())
    #expect(refusal(e2.clean([try request(e2, folder, bundleId: "COM.Example.App")])) == .appRunning(bundleId: "COM.Example.App"))
    #expect(box.exists(path))
}

@Test func refusesWhenSizeChangedSinceReview() throws {
    let box = try Sandbox()
    let path = try box.write("Library/Caches/a.bin", bytes: 5_000)
    let e = engine(box, trasher: RecordingTrasher())
    let req = try request(e, path)
    try Data(count: 50_000).write(to: URL(fileURLWithPath: path))
    #expect(refusal(e.clean([req])) == .changedSinceReview)
    #expect(box.exists(path))
}

@Test func refusesWhenModifiedDateChangedSinceReview() throws {
    let box = try Sandbox()
    let path = try box.write("Library/Caches/a.bin")
    let e = engine(box, trasher: RecordingTrasher())
    let req = try request(e, path)
    try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_000_000)], ofItemAtPath: path)
    #expect(refusal(e.clean([req])) == .changedSinceReview)
}

@Test func refusesWhenSomethingInsideAFolderChanged() throws {
    let box = try Sandbox()
    try box.write("Library/Caches/com.x/a.bin")
    let folder = box.home + "/Library/Caches/com.x"
    let e = engine(box, trasher: RecordingTrasher())
    let req = try request(e, folder)

    // A new file appears.
    try box.write("Library/Caches/com.x/new.bin")
    #expect(refusal(e.clean([req])) == .changedSinceReview)

    // Something deep inside is edited, same size, different date.
    let e2 = engine(box, trasher: RecordingTrasher())
    let req2 = try request(e2, folder)
    try FileManager.default.setAttributes(
        [.modificationDate: Date(timeIntervalSince1970: 1_000_000)], ofItemAtPath: folder + "/a.bin")
    #expect(refusal(e2.clean([req2])) != nil)
    #expect(box.exists(folder + "/a.bin"))
}

@Test func nothingIsCleanedWhenTheLogCannotBeWritten() throws {
    let box = try Sandbox()
    let path = try box.write("Library/Caches/a.bin")
    // The log's parent "folder" is really a file, so it can't be created.
    let blocker = box.root + "/blocker"
    try Data().write(to: URL(fileURLWithPath: blocker))
    let e = CleanupEngine(home: box.home, runningApps: FakeApps(), trasher: RecordingTrasher(),
                          logURL: URL(fileURLWithPath: blocker + "/cleanup-log.jsonl"))
    let results = e.clean([try request(e, path)])
    #expect(refusal(results) == .logUnavailable)
    #expect(box.exists(path))
}

@Test func refusalsAreLoggedWithAReason() throws {
    let box = try Sandbox()
    let path = try box.write("Library/Caches/com.x/a.bin")
    let folder = box.home + "/Library/Caches/com.x"
    let e = engine(box, apps: ["com.x"], trasher: RecordingTrasher())
    _ = e.clean([try request(e, folder, bundleId: "com.x")])
    let line = try #require(try box.logLines().first)
    #expect(line["outcome"] as? String == "refused")
    #expect((line["detail"] as? String)?.contains("com.x") == true)
    #expect(box.exists(path))
}

// MARK: - Fingerprints

@Test func fingerprintCountsEverythingInsideAFolder() throws {
    let box = try Sandbox()
    try box.write("Library/Caches/com.x/a.bin", bytes: 10_000)
    try box.write("Library/Caches/com.x/sub/b.bin", bytes: 20_000)
    let e = engine(box)
    let fp = try #require(e.fingerprint(of: box.home + "/Library/Caches/com.x"))
    #expect(fp.isDirectory)
    #expect(fp.fileCount == 2)
    #expect(fp.size >= 30_000)
    #expect(e.fingerprint(of: box.home + "/Library/Caches/missing") == nil)
}

@Test func makeRequestUsesTheCandidateAndFingerprint() throws {
    let box = try Sandbox()
    let path = try box.write("Library/Caches/com.x/a.bin")
    let folder = box.home + "/Library/Caches/com.x"
    _ = path
    let candidate = CleanupCandidate(ruleId: "r", path: folder, name: "com.x", isDirectory: true, size: 5_000,
                                     category: "App caches", risk: .safe, reason: "r", bundleId: "com.x")
    let e = engine(box)
    let req = try #require(e.makeRequest(for: candidate))
    #expect(req.path == folder && req.bundleId == "com.x" && req.fingerprint.fileCount == 1)
    let gone = CleanupCandidate(ruleId: "r", path: folder + "/nope", name: "nope", isDirectory: false, size: 1,
                                category: "c", risk: .safe, reason: "r", bundleId: nil)
    #expect(e.makeRequest(for: gone) == nil)
}

@Test func refusesPhotosLibrariesAppBundleInsidesAndICloudPlaceholders() throws {
    let box = try Sandbox()
    try box.write("Pictures/Photos Library.photoslibrary/database/Photos.sqlite")
    try box.write("Pictures/Old.photolibrary/AlbumData.xml")
    try box.write("Applications/Tool.app/Contents/Resources/big.bin")
    try box.write("Projects/Thing.app/Contents/MacOS/Thing")
    try box.write("Projects/.report.pdf.icloud")
    let e = engine(box, trasher: RecordingTrasher())
    let protected = [
        box.home + "/Pictures/Photos Library.photoslibrary",
        box.home + "/Pictures/Photos Library.photoslibrary/database/Photos.sqlite",
        box.home + "/Pictures/Old.photolibrary/AlbumData.xml",
        box.home + "/Applications/Tool.app/Contents/Resources/big.bin",
        box.home + "/Projects/Thing.app/Contents",
        box.home + "/PROJECTS/THING.APP/Contents/MacOS/Thing",
        box.home + "/Projects/.report.pdf.icloud",
    ]
    for path in protected {
        let fp = try #require(e.fingerprint(of: path))
        let r = e.clean([CleanupRequest(path: path, bundleId: nil, fingerprint: fp)])
        #expect(refusal(r) == .protectedPath, "\(path)")
    }
    #expect(box.exists(box.home + "/Pictures/Photos Library.photoslibrary/database/Photos.sqlite"))
}

@Test func aWholeAppBundleInTheHomeFolderCanStillBeTrashed() throws {
    let box = try Sandbox()
    try box.write("Projects/Thing.app/Contents/MacOS/Thing")
    let e = engine(box)
    let path = box.home + "/Projects/Thing.app"
    let r = e.clean([try request(e, path)])
    guard case .trashed = r.first?.outcome else {
        Issue.record("expected trashed, got \(String(describing: r.first?.outcome))")
        return
    }
    #expect(!box.exists(path))
}

@Test func refusesApplesOwnCachesButNotOtherApps() throws {
    let box = try Sandbox()
    try box.write("Library/Caches/com.apple.Safari/cache.db")
    try box.write("Library/Caches/com.spotify.client/data")
    let e = engine(box, trasher: RecordingTrasher())
    for path in [box.home + "/Library/Caches/com.apple.Safari", box.home + "/Library/Caches/COM.APPLE.Safari/cache.db"] {
        let fp = ItemFingerprint(isDirectory: true, size: 1, fileCount: 1, newestModified: 0)
        #expect(refusal(e.clean([CleanupRequest(path: path, bundleId: nil, fingerprint: fp)])) == .protectedPath, "\(path)")
    }
    #expect(!e.isProtected(box.home + "/Library/Caches/com.spotify.client"))
}
