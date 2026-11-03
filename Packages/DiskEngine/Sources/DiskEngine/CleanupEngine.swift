import Foundation

// CleanupEngine is the ONLY place in the app that removes anything from the user's disk.
// It moves items to the Trash (never deletes them for good), refuses anything on the hard
// denylist or outside the allowed folders, and writes a JSONL log of every attempt.

/// What an item looked like when the user reviewed it. Cleaning is refused if it has changed since.
public struct ItemFingerprint: Sendable, Equatable, Codable {
    public let isDirectory: Bool
    /// Allocated bytes of the item and everything inside it.
    public let size: Int64
    /// Files (not folders) inside; 1 for a file.
    public let fileCount: Int
    /// Newest modification time of the item and everything inside it (seconds since 1970).
    public let newestModified: Double
    /// Wrapping sum of every modification time in milliseconds. Catches an older file being edited,
    /// which the newest time alone would miss.
    public var modifiedSum: Int64 = 0

    public init(isDirectory: Bool, size: Int64, fileCount: Int, newestModified: Double, modifiedSum: Int64 = 0) {
        self.isDirectory = isDirectory
        self.size = size
        self.fileCount = fileCount
        self.newestModified = newestModified
        self.modifiedSum = modifiedSum
    }
}

public struct CleanupRequest: Sendable, Equatable {
    public let path: String
    /// App that must not be running, if any.
    public let bundleId: String?
    public let fingerprint: ItemFingerprint

    public init(path: String, bundleId: String?, fingerprint: ItemFingerprint) {
        self.path = path
        self.bundleId = bundleId
        self.fingerprint = fingerprint
    }
}

public enum CleanupRefusal: Sendable, Equatable {
    case badPath
    case protectedPath
    case outsideAllowedFolders
    case missing
    case isSymlink
    case symlinkedParent
    case appRunning(bundleId: String)
    case changedSinceReview
    case logUnavailable

    /// Plain-English reason for the screen and the log.
    public var message: String {
        switch self {
        case .badPath: return "The path is not a clean absolute path."
        case .protectedPath: return "This location is protected and is never cleaned."
        case .outsideAllowedFolders: return "This is outside the folders the app may clean."
        case .missing: return "It no longer exists."
        case .isSymlink: return "It is a shortcut (symbolic link), so it is left alone."
        case .symlinkedParent: return "A folder on the way to it is a shortcut (symbolic link), so it is left alone."
        case .appRunning(let id): return "The app \(id) is open. Quit it first."
        case .changedSinceReview: return "It changed after you reviewed it. Scan again to see the new size."
        case .logUnavailable: return "The cleanup log could not be written, so nothing was cleaned."
        }
    }
}

public enum CleanupOutcome: Sendable, Equatable {
    case trashed(trashedTo: String?)
    case refused(CleanupRefusal)
    case failed(String)
}

public struct CleanupResult: Sendable, Equatable {
    public let path: String
    public let outcome: CleanupOutcome

    public init(path: String, outcome: CleanupOutcome) {
        self.path = path
        self.outcome = outcome
    }
}

/// Moves one item to the Trash.
public protocol Trasher: Sendable {
    /// Returns where the item ended up, if known.
    func trash(path: String) throws -> String?
}

public struct FileManagerTrasher: Trasher {
    public init() {}

    public func trash(path: String) throws -> String? {
        var result: NSURL?
        try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: &result)
        return (result as URL?)?.path
    }
}

public struct CleanupEngine: Sendable {
    private let home: String
    private let allowedRoots: [String]
    private let runningApps: any RunningAppProvider
    private let trasher: any Trasher
    private let logURL: URL
    private let now: @Sendable () -> Date

    /// `~/Library/Application Support/DiskOptimizer/cleanup-log.jsonl`
    public static func defaultLogURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("DiskOptimizer/cleanup-log.jsonl")
    }

    /// - Parameters:
    ///   - home: the user's real home folder (no symlinks in the path).
    ///   - allowedRoots: only items inside these folders may be cleaned. Defaults to the home folder.
    public init(home: String = NSHomeDirectory(), allowedRoots: [String]? = nil,
                runningApps: any RunningAppProvider = SystemRunningApps(),
                trasher: any Trasher = FileManagerTrasher(),
                logURL: URL = CleanupEngine.defaultLogURL(),
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.home = home
        self.allowedRoots = allowedRoots ?? [home]
        self.runningApps = runningApps
        self.trasher = trasher
        self.logURL = logURL
        self.now = now
    }

    // MARK: - Reviewing

    /// Snapshot of an item as it is now, or nil if it is missing or a symlink.
    public func fingerprint(of path: String) -> ItemFingerprint? {
        guard let root = FileStat(path: path), root.kind != .symlink else { return nil }
        if root.kind == .other {
            return ItemFingerprint(isDirectory: false, size: root.allocated, fileCount: 1, newestModified: root.modified,
                                   modifiedSum: Self.millis(root.modified))
        }
        var total = root.allocated, files = 0, newest = root.modified, sum = Self.millis(root.modified)
        walk(path, dev: root.dev, total: &total, files: &files, newest: &newest, sum: &sum)
        return ItemFingerprint(isDirectory: true, size: total, fileCount: files, newestModified: newest, modifiedSum: sum)
    }

    /// A request for a suggestion, fingerprinted right now. Call this when the user reviews the item.
    public func makeRequest(for candidate: CleanupCandidate) -> CleanupRequest? {
        fingerprint(of: candidate.path).map {
            CleanupRequest(path: candidate.path, bundleId: candidate.bundleId, fingerprint: $0)
        }
    }

    private static func millis(_ t: Double) -> Int64 { Int64(t * 1000) }

    private func walk(_ path: String, dev: Int64, total: inout Int64, files: inout Int, newest: inout Double, sum: inout Int64) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: path) else { return }
        for name in names {
            let child = path == "/" ? "/" + name : path + "/" + name
            guard let st = FileStat(path: child), st.kind != .symlink else { continue }
            if st.kind == .directory && st.dev != dev { continue }
            total += st.allocated
            newest = max(newest, st.modified)
            sum = sum &+ Self.millis(st.modified)
            if st.kind == .directory {
                walk(child, dev: dev, total: &total, files: &files, newest: &newest, sum: &sum)
            } else {
                files += 1
            }
        }
    }

    // MARK: - Cleaning

    /// Checks and trashes each request in turn. A refusal or failure never stops the rest.
    /// Nothing is cleaned unless the log can be written.
    public func clean(_ requests: [CleanupRequest]) -> [CleanupResult] {
        let log = CleanupLog(url: logURL)
        guard log.isWritable() else {
            return requests.map { CleanupResult(path: $0.path, outcome: .refused(.logUnavailable)) }
        }
        let running = Set(runningApps.runningBundleIDs().map { $0.lowercased() })
        return requests.map { request in
            let outcome: CleanupOutcome
            if let refusal = check(request, running: running) {
                outcome = .refused(refusal)
            } else {
                do {
                    outcome = .trashed(trashedTo: try trasher.trash(path: request.path))
                } catch {
                    outcome = .failed(error.localizedDescription)
                }
            }
            log.append(request: request, outcome: outcome, at: now())
            return CleanupResult(path: request.path, outcome: outcome)
        }
    }

    /// The first reason to refuse, or nil if the item may be trashed.
    func check(_ request: CleanupRequest, running: Set<String>) -> CleanupRefusal? {
        let path = request.path
        guard CleanupEngine.isCleanAbsolute(path) else { return .badPath }
        if isProtected(path) { return .protectedPath }
        guard allowedRoots.contains(where: { CleanupEngine.key(path).hasPrefix(CleanupEngine.key($0) + "/") }) else {
            return .outsideAllowedFolders
        }
        guard let stat = FileStat(path: path) else { return .missing }
        if stat.kind == .symlink { return .isSymlink }
        let parent = (path as NSString).deletingLastPathComponent
        if CleanupEngine.realPath(parent).map(CleanupEngine.key) != CleanupEngine.key(parent) { return .symlinkedParent }
        if let id = request.bundleId, running.contains(id.lowercased()) { return .appRunning(bundleId: id) }
        guard fingerprint(of: path) == request.fingerprint else { return .changedSinceReview }
        return nil
    }

    // MARK: - Hard denylist

    /// Never cleaned, nor anything inside.
    private var protectedSubtrees: [String] {
        let system = ["/System", "/usr", "/bin", "/sbin", "/dev", "/etc", "/private/etc",
                      "/private/var/db", "/var/db", "/Library", "/Applications", "/Volumes", "/cores"]
        let userData = ["Library/Keychains", "Library/Application Support", "Library/Mail", "Library/Messages",
                        "Library/Safari", "Library/Preferences", "Library/Containers", "Library/Group Containers",
                        "Library/Mobile Documents", "Library/CloudStorage", "Library/Accounts",
                        "Library/Cookies", ".ssh", ".gnupg"]
        return system + userData.map { home + "/" + $0 }
    }

    /// The folder itself is never cleaned, but items inside it can be. Anything that contains
    /// one of these (like `/Users`) is protected too.
    private var protectedFolders: [String] {
        let system = ["/", "/Users", "/private", "/private/var", "/var", "/tmp", "/private/tmp"]
        let userFolders = ["Library", "Library/Caches", "Library/Logs", "Desktop", "Documents", "Downloads",
                           "Movies", "Music", "Pictures", "Public", "Applications"]
        return system + [home] + userFolders.map { home + "/" + $0 }
    }

    func isProtected(_ path: String) -> Bool {
        let p = CleanupEngine.key(path)
        if p == "/" { return true }
        for subtree in protectedSubtrees.map(CleanupEngine.key) where p == subtree || p.hasPrefix(subtree + "/") {
            return true
        }
        for folder in protectedFolders.map(CleanupEngine.key) where p == folder || folder.hasPrefix(p + "/") {
            return true
        }
        return CleanupEngine.isProtectedByName(p)
    }

    /// Protected wherever they are: a Photos library and anything inside it, anything inside an
    /// app bundle (the bundle itself may still be trashed), and iCloud placeholder files.
    static func isProtectedByName(_ path: String) -> Bool {
        let parts = key(path).split(separator: "/")
        for (i, part) in parts.enumerated() {
            if part.hasSuffix(".photoslibrary") || part.hasSuffix(".photolibrary") { return true }
            if part.hasSuffix(".app") && i < parts.count - 1 { return true }
        }
        if let last = parts.last, last.hasPrefix("."), last.hasSuffix(".icloud") { return true }
        return false
    }

    // MARK: - Helpers

    /// Case-insensitive, Unicode-normalized form, because the usual macOS disk ignores case.
    static func key(_ s: String) -> String {
        s.precomposedStringWithCanonicalMapping.lowercased()
    }

    /// Absolute, no empty, `.` or `..` parts, no trailing slash, no NUL.
    static func isCleanAbsolute(_ path: String) -> Bool {
        // A NUL would cut the path short when it reaches the file system, so it is never clean.
        guard path.hasPrefix("/"), path.count > 1, !path.contains("\u{0}") else { return false }
        return path.dropFirst().split(separator: "/", omittingEmptySubsequences: false)
            .allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    /// The path with every symlink resolved (`realpath`), or nil if it can't be resolved.
    static func realPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}

/// Append-only JSON Lines log: one object per attempt, including refusals.
struct CleanupLog: Sendable {
    let url: URL

    private struct Entry: Codable {
        let time: String
        let path: String
        let outcome: String
        let detail: String?
        let size: Int64
        let bundleId: String?
        let trashedTo: String?
    }

    func isWritable() -> Bool {
        (try? write(Data())) != nil
    }

    func append(request: CleanupRequest, outcome: CleanupOutcome, at date: Date) {
        let (kind, detail, trashedTo): (String, String?, String?) = {
            switch outcome {
            case .trashed(let to): return ("trashed", nil, to)
            case .refused(let why): return ("refused", why.message, nil)
            case .failed(let message): return ("failed", message, nil)
            }
        }()
        let entry = Entry(time: ISO8601DateFormatter().string(from: date), path: request.path, outcome: kind,
                          detail: detail, size: request.fingerprint.size, bundleId: request.bundleId,
                          trashedTo: trashedTo)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard var line = try? encoder.encode(entry) else { return }
        line.append(0x0A)
        try? write(line)
    }

    private func write(_ data: Data) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: url.path), !fm.createFile(atPath: url.path, contents: nil) {
            throw CocoaError(.fileWriteUnknown)
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }
}
