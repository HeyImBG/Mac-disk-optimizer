import Foundation

public enum RiskLevel: String, Codable, Sendable, Equatable {
    /// Rebuilt by the owning app; nothing of the user's is lost.
    case safe
    /// Probably fine, but the user should look first.
    case review
    /// Could matter to the user; never pre-selected.
    case caution
}

/// One entry in the rules file (JSON, shipped in the app bundle). Rules only describe what to
/// suggest; they cannot delete anything. Deleting is `CleanupEngine`'s job (T18).
public struct CleanupRule: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    /// Absolute path or `~/...`. A segment is a literal name or contains `*`, which matches
    /// any characters inside that one segment. Each match is one suggestion.
    public let pattern: String
    public let category: String
    public let risk: RiskLevel
    /// Plain-English reason shown to the user.
    public let reason: String
    /// Bundle id of the app that must not be running while this is cleaned.
    public let bundleId: String?
    /// Use the matched folder's name as the bundle id (for `~/Library/Caches/<bundle id>`).
    public let bundleIdFromFolder: Bool?
    /// Names of matched items to skip.
    public let excludeNames: [String]?
    /// Set to false to keep a rule in the file but switch it off (for example while unverified).
    public let enabled: Bool?

    public var isEnabled: Bool { enabled ?? true }

    public init(id: String, pattern: String, category: String, risk: RiskLevel, reason: String,
                bundleId: String? = nil, bundleIdFromFolder: Bool? = nil,
                excludeNames: [String]? = nil, enabled: Bool? = nil) {
        self.id = id
        self.pattern = pattern
        self.category = category
        self.risk = risk
        self.reason = reason
        self.bundleId = bundleId
        self.bundleIdFromFolder = bundleIdFromFolder
        self.excludeNames = excludeNames
        self.enabled = enabled
    }
}

public enum RuleError: Error, Equatable {
    case unsupportedVersion(Int)
    case duplicateId(String)
    case invalidPattern(id: String)
    case safeRuleNeedsBundleId(id: String)
}

public struct RuleSet: Codable, Sendable, Equatable {
    public static let supportedVersion = 1

    public let version: Int
    public let rules: [CleanupRule]

    public init(version: Int = RuleSet.supportedVersion, rules: [CleanupRule]) {
        self.version = version
        self.rules = rules
    }

    /// Decodes and checks a rules file.
    public static func decode(_ data: Data) throws -> RuleSet {
        let set = try JSONDecoder().decode(RuleSet.self, from: data)
        try set.validate()
        return set
    }

    /// - The version must be known and ids unique.
    /// - Patterns must be absolute or start with `~/`, have no `..` or empty segments, and no `**`.
    /// - A `safe` rule must say which app has to be closed (a bundle id, or the folder name).
    public func validate() throws {
        guard version == RuleSet.supportedVersion else { throw RuleError.unsupportedVersion(version) }
        var seen = Set<String>()
        for rule in rules {
            guard seen.insert(rule.id).inserted else { throw RuleError.duplicateId(rule.id) }
            guard RuleSet.isValid(pattern: rule.pattern) else { throw RuleError.invalidPattern(id: rule.id) }
            if rule.risk == .safe, rule.bundleId == nil, rule.bundleIdFromFolder != true {
                throw RuleError.safeRuleNeedsBundleId(id: rule.id)
            }
        }
    }

    static func isValid(pattern: String) -> Bool {
        guard pattern.hasPrefix("/") || pattern.hasPrefix("~/") else { return false }
        let parts = pattern.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        let body = Array(parts.dropFirst())  // drops "" for "/..." and "~" for "~/..."
        guard body.count >= 2 else { return false }
        return body.allSatisfy { !$0.isEmpty && $0 != ".." && $0 != "." && !$0.contains("**") }
    }
}

/// One thing the user could clean, found by matching a rule against a scan.
public struct CleanupCandidate: Sendable, Equatable, Identifiable {
    public var id: String { "\(ruleId):\(path)" }
    public let ruleId: String
    public let path: String
    public let name: String
    public let isDirectory: Bool
    public let size: Int64
    public let category: String
    public let risk: RiskLevel
    public let reason: String
    /// App that must not be running during cleanup, if the rule names one.
    public let bundleId: String?
}

/// Matches rules against a scan. Read only.
public struct RuleEngine: Sendable {
    private let rules: [CleanupRule]
    private let home: String

    public init(ruleSet: RuleSet, home: String = NSHomeDirectory()) {
        self.rules = ruleSet.rules
        self.home = home.count > 1 && home.hasSuffix("/") ? String(home.dropLast()) : home
    }

    /// All suggestions, largest first. Disabled rules and empty items are skipped.
    public func candidates(in index: ScanIndex) -> [CleanupCandidate] {
        var result: [CleanupCandidate] = []
        for rule in rules where rule.isEnabled {
            for node in matches(of: rule, in: index) where node.size > 0 {
                result.append(CleanupCandidate(
                    ruleId: rule.id, path: node.path, name: node.name, isDirectory: node.isDirectory,
                    size: node.size, category: rule.category, risk: rule.risk, reason: rule.reason,
                    bundleId: rule.bundleId ?? (rule.bundleIdFromFolder == true ? node.name : nil)))
            }
        }
        return result.sorted { $0.size != $1.size ? $0.size > $1.size : $0.path < $1.path }
    }

    private func matches(of rule: CleanupRule, in index: ScanIndex) -> [FileNode] {
        let expanded = rule.pattern.hasPrefix("~/") ? home + String(rule.pattern.dropFirst(1)) : rule.pattern
        let segments = expanded.split(separator: "/").map(String.init)

        // Start at the deepest folder named without wildcards, then walk down one level per segment.
        var literal = 0
        while literal < segments.count, !segments[literal].contains("*") { literal += 1 }
        guard let start = index.node(at: "/" + segments[0..<literal].joined(separator: "/")) else { return [] }

        var level = [start]
        for segment in segments[literal...] {
            level = level.flatMap { parent in parent.children.filter { RuleEngine.glob(segment, $0.name) } }
        }
        let excluded = Set(rule.excludeNames ?? [])
        return level.filter { !excluded.contains($0.name) }
    }

    /// `*` matches any run of characters (including none) inside one name.
    static func glob(_ pattern: String, _ name: String) -> Bool {
        let p = Array(pattern), n = Array(name)
        var pi = 0, ni = 0, star = -1, mark = 0
        while ni < n.count {
            if pi < p.count, p[pi] == "*" {
                star = pi; mark = ni; pi += 1
            } else if pi < p.count, p[pi] == n[ni] {
                pi += 1; ni += 1
            } else if star >= 0 {
                pi = star + 1; mark += 1; ni = mark
            } else {
                return false
            }
        }
        while pi < p.count, p[pi] == "*" { pi += 1 }
        return pi == p.count
    }
}
