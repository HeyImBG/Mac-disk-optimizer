import Foundation

public enum FileKind: String, Sendable, CaseIterable {
    case video, audio, image, archive, diskImage, installer, document, other

    private static let byExtension: [String: FileKind] = {
        let table: [FileKind: [String]] = [
            .video: ["mp4", "mov", "mkv", "avi", "m4v", "wmv", "webm"],
            .audio: ["mp3", "wav", "aiff", "flac", "m4a", "aac"],
            .image: ["jpg", "jpeg", "png", "heic", "gif", "tiff", "raw", "dng", "psd"],
            .archive: ["zip", "tar", "gz", "tgz", "bz2", "xz", "7z", "rar"],
            .diskImage: ["dmg", "iso", "img", "vmdk", "vdi", "qcow2"],
            .installer: ["pkg", "mpkg"],
            .document: ["pdf", "doc", "docx", "ppt", "pptx", "xls", "xlsx", "pages", "numbers", "key", "txt"],
        ]
        var map: [String: FileKind] = [:]
        for (kind, exts) in table { for ext in exts { map[ext] = kind } }
        return map
    }()

    /// Guesses the kind from the file name's extension.
    public static func classify(name: String) -> FileKind {
        let ext = (name as NSString).pathExtension.lowercased()
        return byExtension[ext] ?? .other
    }
}

/// What to look for.
public struct LargeFileQuery: Sendable, Equatable {
    /// Files smaller than this (bytes) are ignored.
    public var minSize: Int64
    /// Only these kinds; nil means all.
    public var kinds: Set<FileKind>?
    /// Only files last opened before this date. Files with no known date are left out.
    public var notOpenedSince: Date?
    public var limit: Int

    public init(minSize: Int64 = 100_000_000, kinds: Set<FileKind>? = nil,
                notOpenedSince: Date? = nil, limit: Int = 200) {
        self.minSize = minSize
        self.kinds = kinds
        self.notOpenedSince = notOpenedSince
        self.limit = limit
    }
}

public struct LargeFile: Sendable, Equatable, Identifiable {
    public var id: String { path }
    public let path: String
    public let name: String
    public let size: Int64
    public let kind: FileKind
    /// When the file was last opened, if known (see `FileDateProvider`).
    public let lastOpened: Date?
}

/// Looks up when a file was last opened. Kept separate so the analyzer can be tested without a disk.
public protocol FileDateProvider: Sendable {
    func lastOpened(path: String) -> Date?
}

/// Uses the file's access date, falling back to its modification date. Read only.
/// Access dates are only a hint: macOS can update them lazily, so the UI should say "last opened (approx.)".
public struct SystemFileDateProvider: FileDateProvider {
    public init() {}

    public func lastOpened(path: String) -> Date? {
        let values = try? URL(fileURLWithPath: path)
            .resourceValues(forKeys: [.contentAccessDateKey, .contentModificationDateKey])
        return values?.contentAccessDate ?? values?.contentModificationDate
    }
}

/// Finds big and/or long-unused files in a scan. Read only; it never touches the files themselves.
public struct LargeFileAnalyzer: Sendable {
    private let dates: any FileDateProvider

    public init(dates: any FileDateProvider = SystemFileDateProvider()) {
        self.dates = dates
    }

    /// Results are largest first, at most `query.limit`.
    public func find(in index: ScanIndex, query: LargeFileQuery = LargeFileQuery()) -> [LargeFile] {
        var matches: [FileNode] = []
        var stack = [index.root]
        while let node = stack.popLast() {
            // A folder smaller than the threshold cannot hold a file that reaches it.
            if node.size < query.minSize { continue }
            if node.isDirectory {
                stack.append(contentsOf: node.children)
            } else if query.kinds?.contains(FileKind.classify(name: node.name)) ?? true {
                matches.append(node)
            }
        }
        matches.sort { $0.size != $1.size ? $0.size > $1.size : $0.path < $1.path }

        var result: [LargeFile] = []
        for node in matches {
            if result.count >= max(0, query.limit) { break }
            let opened = dates.lastOpened(path: node.path)
            if let cutoff = query.notOpenedSince {
                guard let opened, opened < cutoff else { continue }
            }
            result.append(LargeFile(path: node.path, name: node.name, size: node.size,
                                    kind: FileKind.classify(name: node.name), lastOpened: opened))
        }
        return result
    }
}
