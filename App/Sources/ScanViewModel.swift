import Foundation
import Observation
import DiskEngine

/// Anything that can scan a folder and stream events. `DiskScanner` is the real one.
protocol ScanRunner: Sendable {
    func scan(root: URL) -> AsyncStream<ScanEvent>
}

extension DiskScanner: ScanRunner {}

/// Where finished scans are kept. `ScanStore` (SQLite) is the real one.
protocol ScanPersisting: Sendable {
    func save(_ index: ScanIndex) throws
    func loadLatest(rootPath: String) throws -> ScanIndex?
}

extension ScanStore: ScanPersisting {
    func save(_ index: ScanIndex) throws {
        try save(index, at: Date(), keep: 3)
    }

    func loadLatest(rootPath: String) throws -> ScanIndex? {
        try loadLatest(rootPath: Optional(rootPath))?.index
    }
}

enum AppStore {
    /// The app's scan database, or nil if it could not be opened (the app still works without it).
    private static let store: ScanStore? = try? ScanStore.openDefault()
    static let shared: (any ScanPersisting)? = store
    /// The same database, for listing older scans.
    static let history: (any ScanHistorySource)? = store
}

enum SortKey: Equatable {
    case size
    case name
}

struct Crumb: Equatable, Identifiable {
    let name: String
    let path: String
    var id: String { path }
}

struct ScanLocation: Identifiable, Hashable {
    let name: String
    let url: URL
    var id: String { url.path }

    static var defaults: [ScanLocation] {
        [
            ScanLocation(name: "Home", url: FileManager.default.homeDirectoryForCurrentUser),
            ScanLocation(name: "Macintosh HD", url: URL(fileURLWithPath: "/")),
        ]
    }
}

/// Drives the scan screen: runs a scan, keeps the result, and lists one folder at a time.
/// Read only; it never changes files.
@MainActor
@Observable
final class ScanViewModel {
    enum State: Equatable {
        case idle
        case scanning(ScanProgress)
        case finished(unreadable: Int)
        case failed(String)
    }

    private(set) var state: State = .idle
    private(set) var index: ScanIndex?
    /// Folder currently shown in the list.
    private(set) var currentPath: String?
    private(set) var sortKey: SortKey = .size
    private(set) var ascending = false

    private let runner: any ScanRunner
    private let store: (any ScanPersisting)?
    private var task: Task<Void, Never>?

    init(runner: any ScanRunner = DiskScanner(), store: (any ScanPersisting)? = nil) {
        self.runner = runner
        self.store = store
    }

    var isScanning: Bool {
        if case .scanning = state { return true }
        return false
    }

    var canGoUp: Bool {
        guard let index, let currentPath else { return false }
        return currentPath != index.root.path
    }

    /// Children of the current folder in the chosen order.
    var rows: [FileNode] {
        guard let index, let currentPath, let node = index.node(at: currentPath) else { return [] }
        let sorted: [FileNode]
        switch sortKey {
        case .size:
            sorted = node.children.sorted { $0.size != $1.size ? $0.size > $1.size : $0.name < $1.name }
        case .name:
            sorted = node.children.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
        return ascending ? sorted.reversed() : sorted
    }

    /// Path from the scan root down to the folder being shown, for the breadcrumb bar.
    var breadcrumbs: [Crumb] {
        guard let index, let currentPath else { return [] }
        var crumbs: [Crumb] = []
        var path = currentPath
        while path != index.root.path {
            crumbs.append(Crumb(name: URL(fileURLWithPath: path).lastPathComponent, path: path))
            let parent = URL(fileURLWithPath: path).deletingLastPathComponent().path
            if parent == path { break }
            path = parent
        }
        crumbs.append(Crumb(name: index.root.name, path: index.root.path))
        return crumbs.reversed()
    }

    /// Chart slices for the folder being shown.
    var chartArcs: [SunburstArc] {
        guard let index, let currentPath, let node = index.node(at: currentPath) else { return [] }
        return SunburstLayout.arcs(for: node)
    }

    // MARK: - Scanning

    /// Starts a scan in the background, replacing any scan in progress.
    func startScan(root: URL) {
        task?.cancel()
        task = Task { await scan(root: root) }
    }

    func cancel() {
        task?.cancel()
        task = nil
        if isScanning { state = .idle }
    }

    /// Runs a scan to the end (or until cancelled). Exposed so tests can await it.
    func scan(root: URL) async {
        state = .scanning(ScanProgress(filesScanned: 0, bytesScanned: 0, currentPath: root.path))
        for await event in runner.scan(root: root) {
            if Task.isCancelled { break }
            switch event {
            case .progress(let p):
                state = .scanning(p)
            case .finished(let result):
                index = result.index
                currentPath = result.index.root.path
                state = .finished(unreadable: result.unreadablePaths.count)
                if let store {
                    let saved = result.index
                    // Writing a big tree takes a moment, so do it off the main actor.
                    await Task.detached { try? store.save(saved) }.value
                }
            case .failed(let message):
                state = .failed(message)
            }
        }
        if Task.isCancelled, isScanning { state = .idle }
    }

    /// Shows the last saved scan of `root` straight away, if there is one and nothing else has
    /// been scanned yet.
    func loadLastScan(root: URL) async {
        guard let store, index == nil else { return }
        let path = root.path
        let saved = await Task.detached { try? store.loadLatest(rootPath: path) }.value
        guard let saved, index == nil, !isScanning else { return }
        index = saved
        currentPath = saved.root.path
        state = .finished(unreadable: 0)
    }

    // MARK: - Browsing and sorting

    /// Shows the contents of a folder. Files are ignored.
    func open(_ node: FileNode) {
        guard node.isDirectory else { return }
        currentPath = node.path
    }

    /// Jumps to a folder that exists in the scan (used by the breadcrumb and the chart).
    func navigate(to path: String) {
        guard let index, index.node(at: path)?.isDirectory == true else { return }
        currentPath = path
    }

    func goUp() {
        guard canGoUp, let here = currentPath else { return }
        currentPath = URL(fileURLWithPath: here).deletingLastPathComponent().path
    }

    /// Choosing the active column flips its direction; a new column starts with its natural one
    /// (largest first for size, A to Z for name).
    func toggleSort(_ key: SortKey) {
        if key == sortKey {
            ascending.toggle()
        } else {
            sortKey = key
            ascending = false
        }
    }

    static func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
