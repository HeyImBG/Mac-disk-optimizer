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

/// Caches: com.big (900), com.open (400), com.small (50). Logs: app.log (300).
private func fixture() -> ScanIndex {
    let c = "\(home)/Library/Caches"
    let caches = folder(c, [
        folder("\(c)/com.big", [file("\(c)/com.big", "x", 900)]),
        folder("\(c)/com.open", [file("\(c)/com.open", "x", 400)]),
        folder("\(c)/com.small", [file("\(c)/com.small", "x", 50)]),
    ])
    let l = "\(home)/Library/Logs"
    let logs = folder(l, [file(l, "app.log", 300)])
    return ScanIndex(root: folder(home, [folder("\(home)/Library", [caches, logs])]))
}

private struct FakeApps: RunningAppProvider {
    var ids: Set<String>
    func runningBundleIDs() -> Set<String> { ids }
    var notInstalled: Set<String> = []
    func isInstalledApp(_ bundleId: String) -> Bool { !notInstalled.contains(bundleId) }
}

private let rules = RuleSet(rules: [
    CleanupRule(id: "caches", pattern: "~/Library/Caches/*", category: "App caches", risk: .safe,
                reason: "Rebuilt.", bundleIdFromFolder: true),
    CleanupRule(id: "logs", pattern: "~/Library/Logs/*", category: "Logs", risk: .review, reason: "Logs."),
])

private func analyzer(running: Set<String> = []) -> CachesAnalyzer {
    CachesAnalyzer(rules: rules, runningApps: FakeApps(ids: running), home: home)
}

@Test func groupsByCategoryLargestFirst() {
    let report = analyzer().analyze(fixture())
    #expect(report.groups.map(\.category) == ["App caches", "Logs"])      // 1350 vs 300
    #expect(report.groups[0].items.map(\.candidate.name) == ["com.big", "com.open", "com.small"])
    #expect(report.groups[0].totalSize == 1350)
    #expect(report.totalSize == 1650)
}

@Test func onlySafeItemsWithClosedAppsArePreselected() {
    let report = analyzer(running: ["com.open"]).analyze(fixture())
    let caches = report.groups[0]
    let big = caches.items[0], open = caches.items[1]
    #expect(big.preselected && !big.appRunning)
    #expect(open.appRunning && !open.preselected)
    #expect(caches.preselectedSize == 950)         // big + small, not the open app
    // Review-level items are never preselected.
    #expect(report.groups[1].items.allSatisfy { !$0.preselected })
    #expect(report.preselectedSize == 950)
}

@Test func runningAppMatchIsCaseInsensitive() {
    let upper = CachesAnalyzer(rules: rules, runningApps: FakeApps(ids: ["com.open"]), home: home)
    let c = "\(home)/Library/Caches"
    let index = ScanIndex(root: folder(home, [folder("\(home)/Library", [
        folder(c, [folder("\(c)/Com.Open", [file("\(c)/Com.Open", "x", 10)])]),
    ])]))
    #expect(upper.analyze(index).groups[0].items[0].appRunning)
}

@Test func emptyReportWhenNothingMatches() {
    let index = ScanIndex(root: folder(home, [folder("\(home)/Documents", [file("\(home)/Documents", "a", 5)])]))
    let report = analyzer().analyze(index)
    #expect(report.isEmpty)
    #expect(report.totalSize == 0)
}

@Test func nestedMatchesAreNotCountedTwice() {
    let c = "\(home)/Library/Caches"
    let overlapping = RuleSet(rules: [
        CleanupRule(id: "outer", pattern: "~/Library/Caches/*", category: "A", risk: .review, reason: "r"),
        CleanupRule(id: "inner", pattern: "~/Library/Caches/*/x", category: "B", risk: .review, reason: "r"),
    ])
    let a = CachesAnalyzer(rules: overlapping, runningApps: FakeApps(ids: []), home: home)
    let report = a.analyze(fixture())
    #expect(!report.groups.flatMap(\.items).contains { $0.candidate.path.hasPrefix(c + "/") && $0.candidate.ruleId == "inner" })
    #expect(report.totalSize == 1350)   // the three cache folders, not their files again
    #expect(report.groups.map(\.category) == ["A"])
}

@Test func shippedRulesProduceAReport() throws {
    var url = URL(fileURLWithPath: #filePath)
    for _ in 0..<5 { url.deleteLastPathComponent() }
    let data = try Data(contentsOf: url.appendingPathComponent("App/Resources/cleanup-rules.json"))
    let shipped = try RuleSet.decode(data)
    let report = CachesAnalyzer(rules: shipped, runningApps: FakeApps(ids: []), home: home).analyze(fixture())
    #expect(report.groups.map(\.category) == ["App caches", "Logs"])
    #expect(report.preselectedSize == 1350)
}

@Test func cachesOfThingsThatAreNotInstalledAppsAreNotPreselected() {
    var apps = FakeApps(ids: [])
    apps.notInstalled = ["com.small"]
    let report = CachesAnalyzer(rules: rules, runningApps: apps, home: home).analyze(fixture())
    let small = report.groups[0].items.first { $0.candidate.name == "com.small" }!
    #expect(!small.preselected && !small.appRunning)
    #expect(report.groups[0].preselectedSize == 1300)   // big + open, not the helper's cache
}
