import Foundation
import Observation
import DiskEngine

/// What the screen needs from `CleanupEngine`. The real engine is the only thing that moves files.
protocol Cleaner: Sendable {
    func makeRequest(for candidate: CleanupCandidate) -> CleanupRequest?
    func clean(_ requests: [CleanupRequest]) -> [CleanupResult]
}

extension CleanupEngine: Cleaner {}

/// One line of the "what happened" list.
struct CleanupLine: Sendable, Equatable, Identifiable {
    enum Status: Sendable, Equatable {
        case trashed
        case skipped(String)
        case failed(String)
    }
    let path: String
    let name: String
    let size: Int64
    let status: Status
    var id: String { path }
}

/// Drives the cleanup review screen. It never touches files itself: it hands the ticked items
/// to a `Cleaner` (the `CleanupEngine`), which applies every safety check.
@MainActor
@Observable
final class CleanupViewModel {
    enum State: Equatable {
        case idle
        case ready(CleanupReport)
        case cleaning
        case done([CleanupLine])
        case failed(String)
    }

    private(set) var state: State = .idle
    /// Ids of the ticked items.
    private(set) var selected: Set<String> = []

    private let analyzer: CachesAnalyzer?
    private let loadError: String?
    private let cleaner: any Cleaner
    /// Fingerprints taken when the report was shown, so a change after review is caught.
    private var reviewed: [String: CleanupRequest] = [:]
    private var fingerprintTask: Task<Void, Never>?

    init(analyzer: CachesAnalyzer?, loadError: String? = nil, cleaner: any Cleaner = CleanupEngine()) {
        self.analyzer = analyzer
        self.loadError = loadError
        self.cleaner = cleaner
    }

    /// Reads the rules that ship inside the app.
    static func bundled(cleaner: any Cleaner = CleanupEngine()) -> CleanupViewModel {
        do {
            guard let url = Bundle.main.url(forResource: "cleanup-rules", withExtension: "json") else {
                return CleanupViewModel(analyzer: nil, loadError: "The cleanup rules file is missing from the app.", cleaner: cleaner)
            }
            let rules = try RuleSet.decode(Data(contentsOf: url))
            return CleanupViewModel(analyzer: CachesAnalyzer(rules: rules), cleaner: cleaner)
        } catch {
            return CleanupViewModel(analyzer: nil, loadError: "The cleanup rules could not be read.", cleaner: cleaner)
        }
    }

    // MARK: - Review

    func load(_ index: ScanIndex) {
        guard let analyzer else {
            state = .failed(loadError ?? "The cleanup rules are not available.")
            return
        }
        let report = analyzer.analyze(index)
        state = .ready(report)
        // Only safe items whose app is closed start ticked. Review-only items never do.
        selected = Set(report.groups.flatMap(\.items)
            .filter { $0.preselected && $0.candidate.risk == .safe && !$0.appRunning }.map(\.id))
        reviewed = [:]
        fingerprintTask?.cancel()
        let items = report.groups.flatMap(\.items).map(\.candidate)
        let cleaner = self.cleaner
        fingerprintTask = Task {
            let made = await Task.detached { () -> [String: CleanupRequest] in
                var out: [String: CleanupRequest] = [:]
                for candidate in items {
                    if Task.isCancelled { break }
                    if let request = cleaner.makeRequest(for: candidate) { out[candidate.id] = request }
                }
                return out
            }.value
            if !Task.isCancelled { self.reviewed = made }
        }
    }

    var report: CleanupReport? {
        if case .ready(let report) = state { return report }
        return nil
    }

    func isSelected(_ item: CleanupItem) -> Bool { selected.contains(item.id) }

    /// An item whose app is open cannot be ticked.
    func toggle(_ item: CleanupItem) {
        guard !item.appRunning else { return }
        if selected.contains(item.id) { selected.remove(item.id) } else { selected.insert(item.id) }
    }

    var selectedItems: [CleanupItem] {
        (report?.groups.flatMap(\.items) ?? []).filter { selected.contains($0.id) && !$0.appRunning }
    }

    var selectedSize: Int64 { selectedItems.reduce(0) { $0 + $1.candidate.size } }

    // MARK: - Cleaning

    /// Moves the ticked items to the Trash. Call only after the user confirms.
    func clean() async {
        let chosen = selectedItems
        guard case .ready = state, !chosen.isEmpty else { return }
        state = .cleaning
        fingerprintTask?.cancel()
        let cleaner = self.cleaner
        let known = reviewed
        let lines = await Task.detached { () -> [CleanupLine] in
            var requests: [CleanupRequest] = []
            var lines: [CleanupLine] = []
            for item in chosen {
                let c = item.candidate
                if let request = known[c.id] ?? cleaner.makeRequest(for: c) {
                    requests.append(request)
                } else {
                    lines.append(CleanupLine(path: c.path, name: c.name, size: c.size,
                                             status: .skipped(CleanupRefusal.missing.message)))
                }
            }
            for result in cleaner.clean(requests) {
                let item = chosen.first { $0.candidate.path == result.path }?.candidate
                let status: CleanupLine.Status
                switch result.outcome {
                case .trashed: status = .trashed
                case .refused(let why): status = .skipped(why.message)
                case .failed(let message): status = .failed(message)
                }
                lines.append(CleanupLine(path: result.path, name: item?.name ?? result.path,
                                         size: item?.size ?? 0, status: status))
            }
            return lines
        }.value
        selected = []
        state = .done(lines)
    }

    var freedBytes: Int64 {
        if case .done(let lines) = state {
            return lines.filter { $0.status == .trashed }.reduce(0) { $0 + $1.size }
        }
        return 0
    }
}
