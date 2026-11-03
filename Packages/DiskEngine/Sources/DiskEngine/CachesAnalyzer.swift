import Foundation
#if canImport(AppKit)
import AppKit
#endif

/// Which apps are running right now, by bundle id. Used to warn before cleaning an app's files
/// (and by `CleanupEngine` to refuse).
public protocol RunningAppProvider: Sendable {
    func runningBundleIDs() -> Set<String>
    /// Whether an app with this bundle id is installed. Only then can the running-app check see
    /// whoever writes its cache; background services and helpers are invisible to it.
    func isInstalledApp(_ bundleId: String) -> Bool
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

    public func isInstalledApp(_ bundleId: String) -> Bool {
        #if canImport(AppKit)
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) != nil
        #else
        return false
        #endif
    }
}

/// One suggestion plus what the screen needs to show it.
public struct CleanupItem: Sendable, Equatable, Identifiable {
    public var id: String { candidate.id }
    public let candidate: CleanupCandidate
    /// The app that owns these files is open right now, so cleaning must wait.
    public let appRunning: Bool
    /// Ticked by default: only `safe` items whose app is installed and closed.
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
            // A cache whose owner is not an installed app may belong to a background service that
            // is running right now, which the running-app check cannot see. Never tick it for the user.
            let ownerIsApp = candidate.bundleId.map { runningApps.isInstalledApp($0) } ?? false
            byCategory[candidate.category, default: []].append(CleanupItem(
                candidate: candidate, appRunning: appRunning,
                preselected: candidate.risk == .safe && !appRunning && ownerIsApp))
        }
        let groups = byCategory.map { CleanupGroup(category: $0.key, items: $0.value) }   // items arrive largest first
        return CleanupReport(groups: groups.sorted {
            $0.totalSize != $1.totalSize ? $0.totalSize > $1.totalSize : $0.category < $1.category
        })
    }

    /// Drops a candidate that lies inside another one, so its bytes are not counted twice.
    /// Keeps the order (largest first) of what remains.
    static func withoutNested(_ candidates: [CleanupCandidate]) -> [CleanupCandidate] {
        let paths = Set(candidates.map(\.path))
        func hasCandidateAncestor(_ path: String) -> Bool {
            var parts = path.split(separator: "/").map(String.init)
            while parts.count > 1 {
                parts.removeLast()
                if paths.contains("/" + parts.joined(separator: "/")) { return true }
            }
            return false
        }
        return candidates.filter { !hasCandidateAncestor($0.path) }
    }
}
