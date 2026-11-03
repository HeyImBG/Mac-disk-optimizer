import Foundation
import Testing
@testable import DiskEngine

private let home = "/Users/test"

private func file(_ dir: String, _ name: String, _ size: Int64) -> FileNode {
    FileNode(name: name, path: "\(dir)/\(name)", isDirectory: false, size: size)
}

private func folder(_ path: String, _ children: [FileNode]) -> FileNode {
    FileNode(name: URL(fileURLWithPath: path).lastPathComponent, path: path, isDirectory: true, children: children)
}

/// A fake home folder:
///   Library/Caches/com.example.big (900), com.example.small (50), empty (0)
///   Library/Logs/app.log (300), DiagnosticReports/crash.ips (70)
///   Documents/report.pdf (5000)
private func fixture() -> ScanIndex {
    let caches = folder("\(home)/Library/Caches", [
        folder("\(home)/Library/Caches/com.example.big", [file("\(home)/Library/Caches/com.example.big", "blob", 900)]),
        folder("\(home)/Library/Caches/com.example.small", [file("\(home)/Library/Caches/com.example.small", "x", 50)]),
        folder("\(home)/Library/Caches/empty", []),
    ])
    let logs = folder("\(home)/Library/Logs", [
        file("\(home)/Library/Logs", "app.log", 300),
        folder("\(home)/Library/Logs/DiagnosticReports", [file("\(home)/Library/Logs/DiagnosticReports", "crash.ips", 70)]),
    ])
    let docs = folder("\(home)/Documents", [file("\(home)/Documents", "report.pdf", 5000)])
    let lib = folder("\(home)/Library", [caches, logs])
    return ScanIndex(root: folder(home, [lib, docs]))
}

private let cacheRule = CleanupRule(
    id: "caches", pattern: "~/Library/Caches/*", category: "App caches", risk: .safe,
    reason: "Rebuilt by the app.", bundleIdFromFolder: true)
private let logRule = CleanupRule(
    id: "logs", pattern: "~/Library/Logs/*", category: "Logs", risk: .review,
    reason: "Old logs.", excludeNames: ["DiagnosticReports"])
private let crashRule = CleanupRule(
    id: "crash", pattern: "~/Library/Logs/DiagnosticReports/*", category: "Crash reports", risk: .review,
    reason: "Crash reports.")

private func engine(_ rules: [CleanupRule]) -> RuleEngine {
    RuleEngine(ruleSet: RuleSet(rules: rules), home: home)
}

// MARK: - Matching

@Test func cacheRuleMatchesEachBundleFolder() {
    let found = engine([cacheRule]).candidates(in: fixture())
    #expect(found.map(\.name) == ["com.example.big", "com.example.small"])   // empty folder skipped
    #expect(found[0].size == 900)
    #expect(found[0].bundleId == "com.example.big")
    #expect(found[0].risk == .safe)
    #expect(found[0].category == "App caches")
    #expect(found[0].path == "\(home)/Library/Caches/com.example.big")
}

@Test func excludedNamesMatchWildcards() {
    let rule = CleanupRule(id: "caches", pattern: "~/Library/Caches/*", category: "App caches", risk: .safe,
                           reason: "Rebuilt by the app.", bundleIdFromFolder: true, excludeNames: ["com.example.b*"])
    #expect(engine([rule]).candidates(in: fixture()).map(\.name) == ["com.example.small"])
}

@Test func bundledRulesSkipAppleSystemCaches() throws {
    let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().appendingPathComponent("../../../../App/Resources/cleanup-rules.json")
    let rules = try RuleSet.decode(Data(contentsOf: url))
    let caches = try #require(rules.rules.first { $0.id == "user-app-caches" })
    let excluded = caches.excludeNames ?? []
    for name in ["com.apple.Safari", "CloudKit", "GeoServices"] {
        #expect(excluded.contains { RuleEngine.glob($0, name) })
    }
    #expect(!excluded.contains { RuleEngine.glob($0, "com.spotify.client") })
}

@Test func excludedNamesAreSkipped() {
    let found = engine([logRule]).candidates(in: fixture())
    #expect(found.map(\.name) == ["app.log"])
    #expect(found[0].bundleId == nil)
}

@Test func disabledRulesAreIgnored() {
    let off = CleanupRule(id: "crash", pattern: crashRule.pattern, category: "Crash reports",
                          risk: .review, reason: "x", enabled: false)
    #expect(engine([off]).candidates(in: fixture()).isEmpty)
    #expect(engine([crashRule]).candidates(in: fixture()).map(\.name) == ["crash.ips"])
}

@Test func candidatesAreSortedLargestFirst() {
    let found = engine([cacheRule, logRule, crashRule]).candidates(in: fixture())
    #expect(found.map(\.size) == [900, 300, 70, 50])
}

@Test func fixedBundleIdIsUsed() {
    let rule = CleanupRule(id: "r", pattern: "~/Library/Logs/*", category: "Logs", risk: .review,
                           reason: "x", bundleId: "com.example.app")
    #expect(engine([rule]).candidates(in: fixture()).allSatisfy { $0.bundleId == "com.example.app" })
}

@Test func patternWithoutMatchesOrOutsideTheScanFindsNothing() {
    let rule = CleanupRule(id: "r", pattern: "~/Nope/*", category: "x", risk: .review, reason: "x")
    #expect(engine([rule]).candidates(in: fixture()).isEmpty)
    let outside = CleanupRule(id: "o", pattern: "/Library/Caches/*", category: "x", risk: .review, reason: "x")
    #expect(engine([outside]).candidates(in: fixture()).isEmpty)
}

@Test func wildcardInTheMiddleAndInsideNames() {
    let rule = CleanupRule(id: "w", pattern: "~/Library/*/com.example.*", category: "x", risk: .review, reason: "x")
    #expect(engine([rule]).candidates(in: fixture()).map(\.name) == ["com.example.big", "com.example.small"])
}

@Test func globBehaves() {
    #expect(RuleEngine.glob("*", "anything"))
    #expect(RuleEngine.glob("a*c", "abbbc"))
    #expect(RuleEngine.glob("a*c", "ac"))
    #expect(!RuleEngine.glob("a*c", "abd"))
    #expect(RuleEngine.glob("*.log", "app.log"))
    #expect(!RuleEngine.glob("*.log", "app.log.txt"))
    #expect(RuleEngine.glob("exact", "exact"))
    #expect(!RuleEngine.glob("exact", "exactly"))
}

// MARK: - Rules file

private func json(_ rules: String, version: Int = 1) -> Data {
    Data("{\"version\": \(version), \"rules\": [\(rules)]}".utf8)
}

private let goodRule = """
{"id":"a","pattern":"~/Library/Caches/*","category":"c","risk":"safe","reason":"r","bundleIdFromFolder":true}
"""

@Test func validFileDecodes() throws {
    let set = try RuleSet.decode(json(goodRule))
    #expect(set.rules.count == 1)
    #expect(set.rules[0].risk == .safe)
    #expect(set.rules[0].isEnabled)
}

@Test func unknownVersionIsRejected() {
    #expect(throws: RuleError.unsupportedVersion(2)) { try RuleSet.decode(json(goodRule, version: 2)) }
}

@Test func duplicateIdsAreRejected() {
    #expect(throws: RuleError.duplicateId("a")) { try RuleSet.decode(json("\(goodRule),\(goodRule)")) }
}

@Test func badPatternsAreRejected() {
    for bad in ["relative/path/*", "~/*", "/", "~/Library/../x/*", "~//x", "~/a/**/b"] {
        let rule = """
        {"id":"p","pattern":"\(bad)","category":"c","risk":"review","reason":"r"}
        """
        #expect(throws: RuleError.invalidPattern(id: "p"), "\(bad)") { try RuleSet.decode(json(rule)) }
    }
}

@Test func safeRuleNeedsABundleId() {
    let rule = """
    {"id":"s","pattern":"~/Library/Caches/*","category":"c","risk":"safe","reason":"r"}
    """
    #expect(throws: RuleError.safeRuleNeedsBundleId(id: "s")) { try RuleSet.decode(json(rule)) }
}

@Test func malformedJsonThrows() {
    #expect(throws: (any Error).self) { try RuleSet.decode(Data("not json".utf8)) }
}

// MARK: - The shipped file

private func shippedRules() throws -> RuleSet {
    var url = URL(fileURLWithPath: #filePath)
    for _ in 0..<5 { url.deleteLastPathComponent() }   // up to the repo root
    let file = url.appendingPathComponent("App/Resources/cleanup-rules.json")
    return try RuleSet.decode(try Data(contentsOf: file))
}

@Test func shippedRulesFileIsValid() throws {
    let set = try shippedRules()
    #expect(!set.rules.isEmpty)
    #expect(set.rules.allSatisfy { !$0.reason.isEmpty && !$0.category.isEmpty })
}

@Test func shippedRulesKeepUnverifiedPathsOut() throws {
    let set = try shippedRules()
    // /Library/Caches is not researched yet, and crash reports are unverified (docs/research/caches.md).
    #expect(!set.rules.contains { $0.pattern.hasPrefix("/Library") || $0.pattern.hasPrefix("/System") })
    #expect(set.rules.first { $0.id == "user-crash-reports" }?.isEnabled == false)
    // Only user cache folders named by bundle id are safe.
    #expect(set.rules.filter { $0.risk == .safe }.allSatisfy { $0.pattern.hasPrefix("~/Library/Caches/") })
}

@Test func shippedRulesFindCachesInAFixture() throws {
    let found = RuleEngine(ruleSet: try shippedRules(), home: home).candidates(in: fixture())
    #expect(found.map(\.name) == ["com.example.big", "app.log", "com.example.small"])
    #expect(!found.contains { $0.name == "crash.ips" })
}

@Test func folderNamesThatAreNotBundleIdsAreSkipped() {
    let c = "\(home)/Library/Caches"
    let names = ["CloudKit", "GeoServices", "Google", "com.", ".hidden", "com..x", "com.vendor app", "com.vendor.app"]
    let index = ScanIndex(root: folder(home, [folder("\(home)/Library", [
        folder(c, names.map { folder("\(c)/\($0)", [file("\(c)/\($0)", "x", 10)]) }),
    ])]))
    #expect(engine([cacheRule]).candidates(in: index).map(\.name) == ["com.vendor.app"])
}

@Test func excludedNamesIgnoreCase() {
    let rule = CleanupRule(id: "caches", pattern: "~/Library/Caches/*", category: "App caches", risk: .safe,
                           reason: "Rebuilt by the app.", bundleIdFromFolder: true, excludeNames: ["COM.EXAMPLE.B*"])
    #expect(engine([rule]).candidates(in: fixture()).map(\.name) == ["com.example.small"])
}
