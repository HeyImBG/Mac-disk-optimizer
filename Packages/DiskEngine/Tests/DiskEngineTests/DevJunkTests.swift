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

private struct FakeDates: FileDateProvider {
    var dates: [String: Date]
    func lastOpened(path: String) -> Date? { dates[path] }
}

private struct NoApps: RunningAppProvider {
    func runningBundleIDs() -> Set<String> { [] }
    func isInstalledApp(_ bundleId: String) -> Bool { true }
}

private let now = Date(timeIntervalSince1970: 100 * 86_400)
private func daysAgo(_ n: Int) -> Date { now.addingTimeInterval(-Double(n) * 86_400) }

/// ~/code
///   web/       package.json, package-lock.json, node_modules (500) holding a nested node_modules (50)
///   api/       package.json, yarn.lock, node_modules (300)
///   scratch/   package.json only, node_modules (200)         <- no lockfile
///   Tool.app/  node_modules (999)                            <- inside an app
/// ~/Library/x/node_modules (700)                             <- Library is skipped
private func fixture() -> ScanIndex {
    let c = "\(home)/code"
    let web = folder("\(c)/web", [
        file("\(c)/web", "package.json", 1), file("\(c)/web", "package-lock.json", 1),
        folder("\(c)/web/node_modules", [
            file("\(c)/web/node_modules", "a.js", 450),
            folder("\(c)/web/node_modules/dep", [folder("\(c)/web/node_modules/dep/node_modules", [
                file("\(c)/web/node_modules/dep/node_modules", "b.js", 50)])]),
        ]),
    ])
    let api = folder("\(c)/api", [
        file("\(c)/api", "package.json", 1), file("\(c)/api", "yarn.lock", 1),
        folder("\(c)/api/node_modules", [file("\(c)/api/node_modules", "c.js", 300)]),
    ])
    let scratch = folder("\(c)/scratch", [
        file("\(c)/scratch", "package.json", 1),
        folder("\(c)/scratch/node_modules", [file("\(c)/scratch/node_modules", "d.js", 200)]),
    ])
    let app = folder("\(c)/Tool.app", [folder("\(c)/Tool.app/node_modules", [file("\(c)/Tool.app/node_modules", "e.js", 999)])])
    let lib = folder("\(home)/Library", [folder("\(home)/Library/x", [
        file("\(home)/Library/x", "package-lock.json", 1),
        folder("\(home)/Library/x/node_modules", [file("\(home)/Library/x/node_modules", "f.js", 700)]),
    ])])
    return ScanIndex(root: folder(home, [folder(c, [web, api, scratch, app]), lib]))
}

private let finder = NodeModulesFinder(
    dates: FakeDates(dates: ["\(home)/code/web/package.json": daysAgo(40), "\(home)/code/api/package.json": daysAgo(3)]),
    home: home)

@Test func findsRebuildableNodeModulesLargestFirst() {
    let found = finder.find(in: fixture())
    #expect(found.map(\.path) == ["\(home)/code/web/node_modules", "\(home)/code/api/node_modules"])
    #expect(found[0].size == 500)                       // the nested one is inside, not counted again
    #expect(found[0].projectPath == "\(home)/code/web")
    #expect(found.allSatisfy(\.hasLockfile))
}

@Test func reportsHowLongSinceTheProjectWasTouched() {
    let found = finder.find(in: fixture())
    #expect(found[0].daysSinceTouched(now: now) == 40)
    #expect(found[1].daysSinceTouched(now: now) == 3)
    #expect(found[0].lastTouched == daysAgo(40))
}

@Test func projectsWithoutALockfileAreOnlyListedOnRequest() {
    let all = finder.find(in: fixture(), requireLockfile: false)
    let scratch = all.first { $0.projectPath.hasSuffix("scratch") }
    #expect(scratch?.hasLockfile == false)
    #expect(scratch?.lastTouched == nil)                // no date for it in the fake provider
    #expect(scratch?.daysSinceTouched(now: now) == nil)
    #expect(!finder.find(in: fixture()).contains { $0.projectPath.hasSuffix("scratch") })
}

@Test func skipsAppBundlesAndLibrary() {
    let all = finder.find(in: fixture(), requireLockfile: false).map(\.path)
    #expect(!all.contains { $0.contains(".app/") })
    #expect(!all.contains { $0.hasPrefix("\(home)/Library") })
}

@Test func futureDatesCountAsZeroDays() {
    let project = NodeModulesProject(path: "/a/node_modules", projectPath: "/a", size: 1,
                                     lastTouched: now.addingTimeInterval(86_400), hasLockfile: true)
    #expect(project.daysSinceTouched(now: now) == 0)
}

@Test func candidatesAreReviewLevelAndNeverNameAnApp() {
    let candidates = finder.candidates(in: fixture(), now: now)
    #expect(candidates.count == 2)
    #expect(candidates.allSatisfy { $0.risk == .review && $0.bundleId == nil && $0.isDirectory })
    #expect(candidates[0].category == "Developer projects")
    #expect(candidates[0].reason.contains("40 days"))
    #expect(candidates[1].reason.contains("3 days"))
}

@Test func analyzerAddsNodeModulesWithoutPreselectingThem() {
    let analyzer = CachesAnalyzer(rules: RuleSet(rules: []), runningApps: NoApps(), home: home, nodeModules: finder)
    let report = analyzer.analyze(fixture())
    #expect(report.groups.map(\.category) == ["Developer projects"])
    #expect(report.totalSize == 800)
    #expect(report.preselectedSize == 0)
    // Without a finder, nothing is suggested.
    #expect(CachesAnalyzer(rules: RuleSet(rules: []), runningApps: NoApps(), home: home).analyze(fixture()).isEmpty)
}

// MARK: - Shipped developer rules

private func shippedRules() throws -> RuleSet {
    var url = URL(fileURLWithPath: #filePath)
    for _ in 0..<5 { url.deleteLastPathComponent() }
    return try RuleSet.decode(try Data(contentsOf: url.appendingPathComponent("App/Resources/cleanup-rules.json")))
}

@Test func shippedDeveloperRulesAreReviewOnlyAndKeepUnverifiedPathsOff() throws {
    let dev = try shippedRules().rules.filter { $0.category == "Developer caches" }
    #expect(!dev.isEmpty)
    #expect(dev.allSatisfy { $0.risk == .review })
    // Unverified in docs/research/dev.md until checked on a Mac.
    for id in ["dev-xcode-derived-data", "dev-xcode-device-support", "dev-yarn-classic-cache", "dev-pip-cache"] {
        #expect(dev.first { $0.id == id }?.isEnabled == false, "\(id)")
    }
    // Never aimed at things the notes say to leave alone.
    #expect(!dev.contains { $0.pattern.contains("Archives") || $0.pattern.contains("CoreSimulator") || $0.pattern.contains("Docker") })
}

@Test func shippedDeveloperRulesFindToolCaches() throws {
    let tree = folder(home, [
        folder("\(home)/.npm", [folder("\(home)/.npm/_cacache", [file("\(home)/.npm/_cacache", "x", 400)])]),
        folder("\(home)/.cargo", [folder("\(home)/.cargo/registry", [
            folder("\(home)/.cargo/registry/cache", [folder("\(home)/.cargo/registry/cache/index.crates.io-1", [
                file("\(home)/.cargo/registry/cache/index.crates.io-1", "a.crate", 300)])]),
            folder("\(home)/.cargo/registry/index", [file("\(home)/.cargo/registry/index", "i", 90)]),
        ])]),
        folder("\(home)/Library", [folder("\(home)/Library/Developer", [folder("\(home)/Library/Developer/Xcode", [
            folder("\(home)/Library/Developer/Xcode/DerivedData", [
                folder("\(home)/Library/Developer/Xcode/DerivedData/App-abc", [
                    file("\(home)/Library/Developer/Xcode/DerivedData/App-abc", "o", 800)])])])])]),
    ])
    let found = RuleEngine(ruleSet: try shippedRules(), home: home).candidates(in: ScanIndex(root: tree))
    #expect(found.map(\.ruleId) == ["dev-npm-cache", "dev-cargo-registry-cache"])   // DerivedData rule is off; cargo index is left alone
}

// MARK: - Where node_modules are looked for (T25 safety review)

private func project(_ dir: String) -> FileNode {
    folder(dir, [file(dir, "package.json", 1), file(dir, "package-lock.json", 1),
                 folder("\(dir)/node_modules", [file("\(dir)/node_modules", "x.js", 100)])])
}

@Test func hiddenToolFoldersAreSkipped() {
    let ext = "\(home)/.vscode/extensions/some.ext"
    let nvm = "\(home)/.nvm/versions/node/v22/lib"
    let index = ScanIndex(root: folder(home, [
        folder("\(home)/.vscode", [folder("\(home)/.vscode/extensions", [project(ext)])]),
        folder("\(home)/.nvm", [folder("\(home)/.nvm/versions", [folder("\(home)/.nvm/versions/node", [
            folder("\(home)/.nvm/versions/node/v22", [project(nvm)])])])]),
        folder("\(home)/code", [project("\(home)/code/site")]),
    ]))
    #expect(finder.find(in: index).map(\.path) == ["\(home)/code/site/node_modules"])
    // A scan that starts inside a hidden folder finds nothing either.
    let inside = ScanIndex(root: folder("\(home)/.vscode", [folder("\(home)/.vscode/extensions", [project(ext)])]))
    #expect(finder.find(in: inside).isEmpty)
}

@Test func onlyTheHomeFolderIsSearched() {
    let global = "/usr/local/lib"
    let users = folder("/Users", [folder(home, [folder("\(home)/code", [project("\(home)/code/site")])])])
    let disk = ScanIndex(root: folder("/", [
        folder("/usr", [folder("/usr/local", [project(global)])]), users,
        folder("/Applications", [project("/Applications/Thing")]),
    ]))
    #expect(finder.find(in: disk).map(\.path) == ["\(home)/code/site/node_modules"])
    let outside = ScanIndex(root: folder("/opt", [project("/opt/tool")]))
    #expect(finder.find(in: outside).isEmpty)
}
