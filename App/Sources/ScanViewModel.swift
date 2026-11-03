import Foundation
import Observation
import DiskEngine

/// Anything that can scan a folder and stream events. `DiskScanner` is the real one.
protocol ScanRunner: Sendable {
    func scan(root: URL) -> AsyncStream<ScanEvent>
}

extension DiskScanner: ScanRunner {}

enum SortKey: Equatable {
    case size
    case name
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
    private var task: Task<Void, Never>?

    init(runner: any ScanRunner = DiskScanner()) {
        self.runner = runner
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
            case .failed(let message):
                state = .failed(message)
            }
        }
        if Task.isCancelled, isScanning { state = .idle }
    }

    // MARK: - Browsing and sorting

    /// Shows the contents of a folder. Files are ignored.
    func open(_ node: FileNode) {
        guard node.isDirectory else { return }
        currentPath = node.path
    }

    func goUp() {
        guard canGoUp, let currentPath else { return }
        currentPath = URL(fileURLWithPath: currentPath).deletingLastPathComponent().path
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
