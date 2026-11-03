import CryptoKit
import Foundation

/// Reads file contents for duplicate detection. Kept behind a protocol so the finder can be tested
/// without a disk. Implementations must only read.
public protocol FileContentReader: Sendable {
    /// Hex hash of the file's first `firstBytes` bytes, or of the whole file when `firstBytes` is nil.
    /// Throws if the file cannot be read.
    func hash(path: String, firstBytes: Int?) throws -> String
}

/// SHA-256 over the real file, read in chunks so big files never sit in memory.
public struct SystemFileContentReader: FileContentReader {
    public init() {}

    public func hash(path: String, firstBytes: Int?) throws -> String {
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        defer { try? handle.close() }
        var hasher = SHA256()
        var remaining = firstBytes ?? Int.max
        let chunkSize = 1 << 20
        while remaining > 0 {
            let want = min(chunkSize, remaining)
            guard let data = try handle.read(upToCount: want), !data.isEmpty else { break }
            hasher.update(data: data)
            remaining -= data.count
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// Uses the file's modification date (the "which copy is newest" question). Read only.
public struct SystemModificationDateProvider: FileDateProvider {
    public init() {}

    public func lastOpened(path: String) -> Date? {
        try? URL(fileURLWithPath: path).resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }
}

/// Files with identical content.
public struct DuplicateGroup: Sendable, Equatable, Identifiable {
    public var id: String { paths.first ?? "" }
    /// Size of each copy in bytes.
    public let size: Int64
    /// Every copy, sorted by path. Always two or more.
    public let paths: [String]

    /// Space that keeping a single copy would free.
    public var wastedBytes: Int64 { size * Int64(paths.count - 1) }
}

/// Which copy to keep when suggesting removals.
public enum DuplicateKeepRule: Sendable, Equatable {
    /// Keep the copy with the latest date from the date provider.
    case newest
    /// Keep the copy with the earliest date from the date provider.
    case oldest
    /// Keep a copy inside this folder. If no copy is inside it, there is no suggestion.
    case inFolder(String)
}

/// Finds files with the same content in a scan: group by size, then by a hash of the first 64 KB,
/// then by a hash of the whole file. Read only: it never changes or removes anything. Removing a
/// suggested copy is a separate step that only `CleanupEngine` may do.
public struct DuplicateFinder: Sendable {
    /// Bytes hashed in the quick check.
    public static let quickHashBytes = 64 * 1024

    private let reader: any FileContentReader
    private let dates: any FileDateProvider

    public init(reader: any FileContentReader = SystemFileContentReader(),
                dates: any FileDateProvider = SystemModificationDateProvider()) {
        self.reader = reader
        self.dates = dates
    }

    /// Groups of identical files, most wasted space first. Files smaller than `minSize` are ignored
    /// (the saved scan already skips files under 1 MB). Files that cannot be read are left out.
    public func find(in index: ScanIndex, minSize: Int64 = 1_000_000) -> [DuplicateGroup] {
        var bySize: [Int64: [String]] = [:]
        var stack = [index.root]
        while let node = stack.popLast() {
            if node.isDirectory {
                stack.append(contentsOf: node.children)
            } else if node.size >= max(1, minSize), !Self.isInsidePackage(node.path) {
                bySize[node.size, default: []].append(node.path)
            }
        }

        var groups: [DuplicateGroup] = []
        for (size, paths) in bySize where paths.count > 1 {
            let quick = split(paths, firstBytes: Self.quickHashBytes)
            for candidates in quick where candidates.count > 1 {
                for same in split(candidates, firstBytes: nil) where same.count > 1 {
                    groups.append(DuplicateGroup(size: size, paths: same.sorted()))
                }
            }
        }
        groups.sort { a, b in
            a.wastedBytes != b.wastedBytes ? a.wastedBytes > b.wastedBytes : a.id < b.id
        }
        return groups
    }

    /// The copy to keep under `rule`, or nil when the rule picks none.
    public func keep(in group: DuplicateGroup, rule: DuplicateKeepRule) -> String? {
        switch rule {
        case .newest:
            return pick(group.paths) { $0 > $1 }
        case .oldest:
            return pick(group.paths) { $0 < $1 }
        case .inFolder(let folder):
            var prefix = folder
            while prefix.count > 1 && prefix.hasSuffix("/") { prefix.removeLast() }
            return group.paths.first { $0 == prefix || $0.hasPrefix(prefix == "/" ? "/" : prefix + "/") }
        }
    }

    /// Every copy except the one to keep. Empty when the rule picks no copy, so a suggestion can
    /// never include all copies.
    public func removalSuggestions(for group: DuplicateGroup, rule: DuplicateKeepRule) -> [String] {
        guard let kept = keep(in: group, rule: rule) else { return [] }
        return group.paths.filter { $0 != kept }
    }

    // MARK: - Private

    /// Splits paths into sets with the same hash. Unreadable files are dropped.
    private func split(_ paths: [String], firstBytes: Int?) -> [[String]] {
        var byHash: [String: [String]] = [:]
        for path in paths {
            guard let h = try? reader.hash(path: path, firstBytes: firstBytes) else { continue }
            byHash[h, default: []].append(path)
        }
        return Array(byHash.values)
    }

    /// Best path by date; a missing date counts as oldest. Ties go to the smaller path.
    private func pick(_ paths: [String], isBetter: (Date, Date) -> Bool) -> String? {
        var best: (path: String, date: Date)?
        for path in paths.sorted() {
            let date = dates.lastOpened(path: path) ?? .distantPast
            if let current = best {
                if isBetter(date, current.date) { best = (path, date) }
            } else {
                best = (path, date)
            }
        }
        return best?.path
    }

    /// Copies inside an app or a photo library are not user duplicates.
    private static func isInsidePackage(_ path: String) -> Bool {
        path.contains(".app/") || path.contains(".photoslibrary/") || path.contains(".photolibrary/")
    }
}
