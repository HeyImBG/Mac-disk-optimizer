import Foundation
import Observation
import DiskEngine

/// Where saved scans can be listed and read back. `ScanStore` (SQLite) is the real one.
protocol ScanHistorySource: Sendable {
    func recentScans(rootPath: String) throws -> [ScanSummary]
    func scanIndex(id: Int64) throws -> ScanIndex?
}

extension ScanStore: ScanHistorySource {
    func recentScans(rootPath: String) throws -> [ScanSummary] {
        try history(rootPath: Optional(rootPath), limit: 10)
    }

    func scanIndex(id: Int64) throws -> ScanIndex? {
        let stored: StoredScan? = try load(id: id)
        return stored?.index
    }
}

/// Drives the "what grew" sheet: compares the two newest saved scans of a folder. Read only.
@MainActor
@Observable
final class GrowthViewModel {
    enum State: Equatable {
        case idle
        case loading
        /// Fewer than two saved scans, so there is nothing to compare yet.
        case needsTwoScans
        case ready(older: Date, newer: Date, changes: [FolderChange])
        case failed(String)
    }

    private(set) var state: State = .idle
    private let source: (any ScanHistorySource)?

    init(source: (any ScanHistorySource)? = AppStore.history) {
        self.source = source
    }

    func load(rootPath: String) async {
        guard let source else {
            state = .failed("Scan history is not available.")
            return
        }
        state = .loading
        do {
            state = try await Task.detached { try Self.compute(source: source, rootPath: rootPath) }.value
        } catch {
            state = .failed("The scan history could not be read.")
        }
    }

    nonisolated static func compute(source: any ScanHistorySource, rootPath: String) throws -> State {
        let list = try source.recentScans(rootPath: rootPath)
        guard list.count >= 2,
              let new = try source.scanIndex(id: list[0].id),
              let old = try source.scanIndex(id: list[1].id) else { return .needsTwoScans }
        let changes = GrowthComparer.compare(old: old, new: new)
        return .ready(older: list[1].createdAt, newer: list[0].createdAt, changes: changes)
    }

    /// "+1.2 GB" or "-300 MB".
    nonisolated static func signedSize(_ delta: Int64) -> String {
        let text = ByteCountFormatter.string(fromByteCount: abs(delta), countStyle: .file)
        return (delta < 0 ? "-" : "+") + text
    }
}
