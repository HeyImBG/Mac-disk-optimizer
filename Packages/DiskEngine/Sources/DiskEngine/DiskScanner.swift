import Foundation

/// Running totals reported while a scan is in progress.
public struct ScanProgress: Sendable, Equatable {
    public var filesScanned: Int
    public var bytesScanned: Int64
    public var currentPath: String

    public init(filesScanned: Int, bytesScanned: Int64, currentPath: String) {
        self.filesScanned = filesScanned
        self.bytesScanned = bytesScanned
        self.currentPath = currentPath
    }
}

/// The finished scan.
public struct ScanResult: Sendable {
    public let index: ScanIndex
    /// Folders that could not be read (for example because of missing permission).
    public let unreadablePaths: [String]

    public init(index: ScanIndex, unreadablePaths: [String] = []) {
        self.index = index
        self.unreadablePaths = unreadablePaths
    }
}

public enum ScanEvent: Sendable {
    case progress(ScanProgress)
    case finished(ScanResult)
    case failed(String)
}

/// Read-only parallel disk scanner. It never modifies, moves or deletes anything.
///
/// - Sizes are allocated bytes on disk (`st_blocks * 512`), like `du`.
/// - Symlinks are skipped, as are folders on a different volume than the root and anything
///   under a denylist path.
/// - A file with several hard links is counted once; the other names appear with size 0.
public struct DiskScanner: Sendable {
    public static let defaultDenylist: [String] = [
        "/dev", "/Volumes", "/System/Volumes", "/private/var/vm", "/.Spotlight-V100", "/.fseventsd",
    ]

    public let denylist: [String]
    /// A progress event is sent after this many more files have been seen.
    public let progressInterval: Int
    /// Folders nearer the root than this depth are scanned in parallel; deeper ones run serially.
    private let parallelDepth = 3

    public init(denylist: [String] = DiskScanner.defaultDenylist, progressInterval: Int = 500) {
        self.denylist = denylist
        self.progressInterval = max(1, progressInterval)
    }

    /// Scans `root` and streams progress, ending with `.finished` (or `.failed`).
    /// Cancelling the consuming task stops the scan.
    public func scan(root: URL) -> AsyncStream<ScanEvent> {
        AsyncStream<ScanEvent> { continuation in
            let task = Task {
                await self.run(rootPath: root.resolvingSymlinksInPath().path, continuation: continuation)
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Private

    private func run(rootPath: String, continuation: AsyncStream<ScanEvent>.Continuation) async {
        guard let rootStat = FileStat(path: rootPath) else {
            continuation.yield(.failed("Cannot read \(rootPath)"))
            return
        }
        let state = ScanState(interval: progressInterval, continuation: continuation)
        let name = URL(fileURLWithPath: rootPath).lastPathComponent
        let node: FileNode
        if rootStat.kind == .directory {
            node = await scanDirectory(path: rootPath, name: name.isEmpty ? rootPath : name,
                                       stat: rootStat, rootDev: rootStat.dev, depth: 0, state: state)
        } else {
            node = FileNode(name: name, path: rootPath, isDirectory: false, size: rootStat.allocated)
        }
        if Task.isCancelled { return }
        await state.finish(path: rootPath)
        let result = ScanResult(index: ScanIndex(root: node), unreadablePaths: await state.unreadable)
        continuation.yield(.finished(result))
    }

    private func isDenied(_ path: String) -> Bool {
        denylist.contains { path == $0 || path.hasPrefix($0 + "/") }
    }

    private func scanDirectory(
        path: String, name: String, stat dirStat: FileStat,
        rootDev: Int64, depth: Int, state: ScanState
    ) async -> FileNode {
        var names: [String] = []
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: path)
        } catch {
            await state.noteUnreadable(path)
        }

        var children: [FileNode] = []
        var subdirs: [(path: String, name: String, stat: FileStat)] = []
        var fileCount = 0
        var bytes: Int64 = 0

        for childName in names {
            if Task.isCancelled { break }
            let childPath = path == "/" ? "/" + childName : path + "/" + childName
            if isDenied(childPath) { continue }
            guard let st = FileStat(path: childPath) else { continue }
            switch st.kind {
            case .symlink:
                continue
            case .directory:
                if st.dev == rootDev { subdirs.append((childPath, childName, st)) }
            case .other:
                var size = st.allocated
                if st.nlink > 1, await state.seenBefore(dev: st.dev, ino: st.ino) { size = 0 }
                children.append(FileNode(name: childName, path: childPath, isDirectory: false, size: size))
                fileCount += 1
                bytes += size
            }
        }
        await state.report(files: fileCount, bytes: bytes, path: path)

        let pending = subdirs
        if depth < parallelDepth {
            await withTaskGroup(of: FileNode.self) { group in
                for sub in pending {
                    group.addTask {
                        await self.scanDirectory(path: sub.path, name: sub.name, stat: sub.stat,
                                                 rootDev: rootDev, depth: depth + 1, state: state)
                    }
                }
                for await node in group { children.append(node) }
            }
        } else {
            for sub in pending {
                if Task.isCancelled { break }
                children.append(await scanDirectory(path: sub.path, name: sub.name, stat: sub.stat,
                                                    rootDev: rootDev, depth: depth + 1, state: state))
            }
        }
        return FileNode(name: name, path: path, isDirectory: true, size: dirStat.allocated, children: children)
    }
}

/// `lstat` result reduced to what the scanner needs. Never follows symlinks.
struct FileStat: Sendable {
    enum Kind: Sendable { case directory, symlink, other }
    let kind: Kind
    let dev: Int64
    let ino: UInt64
    let nlink: UInt64
    let allocated: Int64
    /// Modification time in seconds since 1970, with nanoseconds.
    let modified: Double

    init?(path: String) {
        var st = stat()
        guard lstat(path, &st) == 0 else { return nil }
        let type = st.st_mode & S_IFMT
        kind = type == S_IFDIR ? .directory : (type == S_IFLNK ? .symlink : .other)
        dev = Int64(st.st_dev)
        ino = UInt64(st.st_ino)
        nlink = UInt64(st.st_nlink)
        allocated = Int64(st.st_blocks) * 512
        #if canImport(Darwin)
        modified = Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) / 1e9
        #else
        modified = Double(st.st_mtim.tv_sec) + Double(st.st_mtim.tv_nsec) / 1e9
        #endif
    }
}

/// Shared state for one scan: hard-link tracking and progress counters.
actor ScanState {
    private struct InodeKey: Hashable { let dev: Int64; let ino: UInt64 }

    private var seen = Set<InodeKey>()
    private var files = 0
    private var bytes: Int64 = 0
    private var lastEmitted = 0
    private(set) var unreadable: [String] = []
    private let interval: Int
    private let continuation: AsyncStream<ScanEvent>.Continuation

    init(interval: Int, continuation: AsyncStream<ScanEvent>.Continuation) {
        self.interval = interval
        self.continuation = continuation
    }

    /// True if this inode was already counted. The first caller gets false.
    func seenBefore(dev: Int64, ino: UInt64) -> Bool {
        !seen.insert(InodeKey(dev: dev, ino: ino)).inserted
    }

    func noteUnreadable(_ path: String) { unreadable.append(path) }

    func report(files newFiles: Int, bytes newBytes: Int64, path: String) {
        files += newFiles
        bytes += newBytes
        if files - lastEmitted >= interval { emit(path) }
    }

    func finish(path: String) { emit(path) }

    private func emit(_ path: String) {
        lastEmitted = files
        continuation.yield(.progress(ScanProgress(filesScanned: files, bytesScanned: bytes, currentPath: path)))
    }
}
