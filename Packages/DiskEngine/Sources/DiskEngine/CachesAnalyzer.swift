import Foundation
#if canImport(AppKit)
import AppKit
#endif

/// Which apps are running right now, by bundle id. Used to warn before cleaning an app's files
/// (and by `CleanupEngine` to refuse).
public protocol RunningAppProvider: Sendable {
    func runningBundleIDs() -> Set<String>
}

public struct SystemRunningApps: RunningAppProvider {
    public init() {}

    public func runningBundleIDs() -> Set<String> {
        #if canImport(AppKit)
        return Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleIdentifier?.lowercased() })
        #else
        return []
        #endif
    }
}

/// One suggestion plus what the screen needs to show it.
public struct CleanupItem: Sendable, Equatable, Identifiable {
    public var id: String { candidate.id }
    public let candidate: CleanupCandidate
    /// The app that owns these files is open right now, so cleaning must wait.
    public let appRunning: Bool
    /// Ticked by default: only `safe` items whose app is closed.
    public let preselected: Bool
}

public struct CleanupGroup: Sendable, Equatable, Identifiable {
    public var id: String { category }
    public let category: String
    public let items: [CleanupItem]
    public var totalSize: Int64 { items.reduce(0) { $0 + $1.candidate.size } }
    public var preselectedSize: Int64 { items.filter(\.preselected).reduce(0) { $0 + $1.candidate.size } }
}

public struct CleanupReport: Sendable, Equatable {
    public let groups: [CleanupGroup]
    public var totalSize: Int64 { groups.reduce(0) { $0 + $1.totalSize } }
    public var preselectedSize: Int64 { groups.reduce(0) { $0 + $1.preselectedSize } }
    public var isEmpty: Bool { groups.isEmpty }
}

/// Turns the rule matches for a scan into a report grouped by category. Read only.
public struct CachesAnalyzer: Sendable {
    private let engine: RuleEngine
    private let runningApps: any RunningAppProvider

    public init(rules: RuleSet, runningApps: any RunningAppProvider = SystemRunningApps(),
                home: String = NSHomeDirectory()) {
        self.engine = RuleEngine(ruleSet: rules, home: home)
        self.runningApps = runningApps
    }

    /// Groups are largest first, and so are the items inside them.
    public func analyze(_ index: ScanIndex) -> CleanupReport {
        let running = runningApps.runningBundleIDs()
        let candidates = CachesAnalyzer.withoutNested(engine.candidates(in: index))

        var byCategory: [String: [CleanupItem]] = [:]
        for candidate in candidates {
            let appRunning = candidate.bundleId.map { running.contains($0.lowercased()) } ?? false
            byCategory[candidate.category, default: []].append(CleanupItem(
                candidate: candidate, appRunning: appRunning,
                preselected: candidate.risk == .safe && !appRunning))
        }
        let groups = byCategory.map { CleanupGroup(category: $0.key, items: $0.value) }   // items arrive largest first
        return CleanupReport(groups: groups.sorted {
            $0.totalSize != $1.totalSize ? $0.totalSize > $1.totalSize : $0.category < $1.category
        })
    }

    /// Drops a candidate that lies inside another one, so its bytes are not counted twice.
    /// Keeps the order (largest first) of what remains.
    static func withoutNested(_ candidates: [CleanupCandidate]) -> [CleanupCandidate] {
        let parents = candidates.map(\.path).sorted()
        var nested = Set<String>()
        var lastKept: String?
        for path in parents {
            if let kept = lastKept, path.hasPrefix(kept + "/") {
                nested.insert(path)
            } else {
                lastKept = path
            }
        }
        return candidates.filter { !nested.contains($0.path) }
    }
}
