import Foundation
import Testing
import DiskEngine
@testable import DiskOptimizer

@Test func engineIsLinked() {
    #expect(DiskEngine.version == "0.1.0")
}

private struct FakeVolume: VolumeCapacityProvider {
    var ok: Bool
    func capacities() throws -> VolumeCapacities {
        if ok { return VolumeCapacities(total: 1000, available: 400, availableForImportantUsage: 500) }
        throw VolumeError.capacityUnavailable
    }
}

private struct FakeSnapshots: SnapshotProvider {
    func listLocalSnapshots() async throws -> [LocalSnapshot] { [] }
}

@MainActor
@Test func volumeViewModelLoads() async {
    let model = VolumeDebugViewModel(
        service: VolumeOverviewService(volume: FakeVolume(ok: true), snapshots: FakeSnapshots()))
    #expect(model.state == .idle)
    await model.load()
    guard case .loaded(let overview) = model.state else {
        Issue.record("expected loaded state"); return
    }
    #expect(overview.info.usedBytes == 600)
    #expect(overview.info.purgeableBytes == 100)
}

private final class ChangingVolume: VolumeCapacityProvider, @unchecked Sendable {
    let lock = NSLock()
    var available: Int64 = 300
    func capacities() throws -> VolumeCapacities {
        lock.withLock { VolumeCapacities(total: 1_000, available: available, availableForImportantUsage: available) }
    }
}

@MainActor
@Test func volumeViewModelReloadPicksUpNewFreeSpace() async {
    let volume = ChangingVolume()
    let model = VolumeDebugViewModel(service: VolumeOverviewService(volume: volume, snapshots: FakeSnapshots()))
    await model.load()
    volume.lock.withLock { volume.available = 450 }
    await model.load()
    guard case .loaded(let overview) = model.state else {
        Issue.record("expected loaded state"); return
    }
    #expect(overview.info.freeBytes == 450)
}

@MainActor
@Test func volumeViewModelReportsFailure() async {
    let model = VolumeDebugViewModel(
        service: VolumeOverviewService(volume: FakeVolume(ok: false), snapshots: FakeSnapshots()))
    await model.load()
    guard case .failed = model.state else {
        Issue.record("expected failed state"); return
    }
}

private struct FakeReader: ProtectedPathReader {
    var result: ProbeResult
    func probe(path: String) -> ProbeResult { result }
}

@MainActor
private func makeOnboarding(_ result: ProbeResult, opener: @escaping (URL) -> Bool = { _ in true })
    -> OnboardingViewModel {
    OnboardingViewModel(
        checker: FullDiskAccessChecker(reader: FakeReader(result: result), paths: ["/x"]),
        opener: opener)
}

@MainActor
@Test func onboardingShownUntilAccessGranted() {
    #expect(makeOnboarding(.denied).needsOnboarding)
    #expect(makeOnboarding(.missing).needsOnboarding)
    #expect(!makeOnboarding(.readable).needsOnboarding)
}

@MainActor
@Test func onboardingOpensSettingsLink() {
    var opened: [URL] = []
    let model = makeOnboarding(.denied) { opened.append($0); return true }
    #expect(model.openSettings() == FullDiskAccessLinks.urls[0])
    #expect(opened.count == 1)
}

// MARK: - ScanViewModel

private struct FakeRunner: ScanRunner {
    var events: [ScanEvent]
    func scan(root: URL) -> AsyncStream<ScanEvent> {
        AsyncStream { continuation in
            for event in events { continuation.yield(event) }
            continuation.finish()
        }
    }
}

private func sampleIndex() -> ScanIndex {
    func file(_ dir: String, _ name: String, _ size: Int64) -> FileNode {
        FileNode(name: name, path: "\(dir)/\(name)", isDirectory: false, size: size)
    }
    let sub = FileNode(name: "sub", path: "/r/sub", isDirectory: true, children: [file("/r/sub", "z.bin", 50)])
    let root = FileNode(name: "r", path: "/r", isDirectory: true, children: [
        file("/r", "b.txt", 300), file("/r", "a.txt", 100), sub,
    ])
    return ScanIndex(root: root)
}

@MainActor
private func scanned(events: [ScanEvent]? = nil) async -> ScanViewModel {
    let finished = ScanEvent.finished(ScanResult(index: sampleIndex()))
    let model = ScanViewModel(runner: FakeRunner(events: events ?? [finished]))
    await model.scan(root: URL(fileURLWithPath: "/r"))
    return model
}

@MainActor
@Test func scanFinishesAndListsBySizeDescending() async {
    let progress = ScanEvent.progress(ScanProgress(filesScanned: 2, bytesScanned: 400, currentPath: "/r"))
    let model = await scanned(events: [
        progress, .finished(ScanResult(index: sampleIndex(), unreadablePaths: ["/r/locked"])),
    ])
    #expect(model.state == .finished(unreadable: 1))
    #expect(model.rows.map(\.name) == ["b.txt", "a.txt", "sub"])
    #expect(model.canGoUp == false)
}

@MainActor
@Test func sortingByNameAndFlipping() async {
    let model = await scanned()
    model.toggleSort(.name)
    #expect(model.rows.map(\.name) == ["a.txt", "b.txt", "sub"])
    model.toggleSort(.name)
    #expect(model.rows.map(\.name) == ["sub", "b.txt", "a.txt"])
    model.toggleSort(.size)
    #expect(model.rows.map(\.name) == ["b.txt", "a.txt", "sub"])
    model.toggleSort(.size)
    #expect(model.rows.map(\.name) == ["sub", "a.txt", "b.txt"])
}

@MainActor
@Test func opensFolderAndGoesUp() async throws {
    let model = await scanned()
    let sub = try #require(model.rows.first { $0.name == "sub" })
    model.open(sub)
    #expect(model.rows.map(\.name) == ["z.bin"])
    #expect(model.canGoUp)
    model.goUp()
    #expect(model.currentPath == "/r")
    #expect(!model.canGoUp)
}

@MainActor
@Test func openingAFileDoesNothing() async throws {
    let model = await scanned()
    let file = try #require(model.rows.first { $0.name == "a.txt" })
    model.open(file)
    #expect(model.currentPath == "/r")
}

@MainActor
@Test func failedScanShowsMessage() async {
    let model = await scanned(events: [.failed("Cannot read /nope")])
    #expect(model.state == .failed("Cannot read /nope"))
    #expect(model.rows.isEmpty)
}

@MainActor
@Test func breadcrumbsAndNavigate() async throws {
    let model = await scanned()
    #expect(model.breadcrumbs == [Crumb(name: "r", path: "/r")])
    model.navigate(to: "/r/sub")
    #expect(model.breadcrumbs == [Crumb(name: "r", path: "/r"), Crumb(name: "sub", path: "/r/sub")])
    model.navigate(to: "/r")
    #expect(model.currentPath == "/r")
}

@MainActor
@Test func navigateIgnoresFilesAndUnknownPaths() async {
    let model = await scanned()
    model.navigate(to: "/r/a.txt")
    #expect(model.currentPath == "/r")
    model.navigate(to: "/nope")
    #expect(model.currentPath == "/r")
}

@MainActor
@Test func chartArcsFollowCurrentFolder() async throws {
    let model = await scanned()
    #expect(model.chartArcs.filter { $0.depth == 1 }.count == 3)
    model.navigate(to: "/r/sub")
    #expect(model.chartArcs.map(\.name) == ["z.bin"])
}

@MainActor
@Test func chartCenterNamesTheFolderShown() async throws {
    let model = await scanned()
    #expect(model.chartCenterName == "r")
    #expect(model.chartCenterSize > 0)
    model.navigate(to: "/r/sub")
    #expect(model.chartCenterName == "sub")
}

// MARK: - Saved scans

private final class FakeStore: ScanPersisting, @unchecked Sendable {
    private let lock = NSLock()
    private var saved: [ScanIndex] = []
    var stored: ScanIndex?

    var savedCount: Int { lock.withLock { saved.count } }

    func save(_ index: ScanIndex) throws { lock.withLock { saved.append(index) } }
    func loadLatest(rootPath: String) throws -> ScanIndex? { stored }
}

@MainActor
@Test func finishedScanIsSaved() async {
    let store = FakeStore()
    let finished = ScanEvent.finished(ScanResult(index: sampleIndex()))
    let model = ScanViewModel(runner: FakeRunner(events: [finished]), store: store)
    await model.scan(root: URL(fileURLWithPath: "/r"))
    #expect(store.savedCount == 1)
}

@MainActor
@Test func lastScanLoadsWithoutScanning() async {
    let store = FakeStore()
    store.stored = sampleIndex()
    let model = ScanViewModel(runner: FakeRunner(events: []), store: store)
    await model.loadLastScan(root: URL(fileURLWithPath: "/r"))
    #expect(model.state == .finished(unreadable: 0))
    #expect(model.rows.map(\.name) == ["b.txt", "a.txt", "sub"])
}

@MainActor
@Test func lastScanDoesNotReplaceAFreshScan() async {
    let store = FakeStore()
    store.stored = ScanIndex(root: FileNode(name: "old", path: "/old", isDirectory: true))
    let finished = ScanEvent.finished(ScanResult(index: sampleIndex()))
    let model = ScanViewModel(runner: FakeRunner(events: [finished]), store: store)
    await model.scan(root: URL(fileURLWithPath: "/r"))
    await model.loadLastScan(root: URL(fileURLWithPath: "/r"))
    #expect(model.currentPath == "/r")
}

@MainActor
@Test func missingSavedScanLeavesIdle() async {
    let model = ScanViewModel(runner: FakeRunner(events: []), store: FakeStore())
    await model.loadLastScan(root: URL(fileURLWithPath: "/r"))
    #expect(model.state == .idle)
}

// MARK: - Cleanup review (T20)

private struct FakeApps: RunningAppProvider {
    var ids: Set<String>
    func runningBundleIDs() -> Set<String> { ids }
    var notInstalled: Set<String> = []
    func isInstalledApp(_ bundleId: String) -> Bool { !notInstalled.contains(bundleId) }
}

private final class FakeCleaner: Cleaner, @unchecked Sendable {
    private let lock = NSLock()
    private var _cleaned: [[String]] = []
    private var _requested: [String] = []
    var refuse: Set<String> = []
    var cleaned: [[String]] { lock.lock(); defer { lock.unlock() }; return _cleaned }
    var requested: [String] { lock.lock(); defer { lock.unlock() }; return _requested }

    func makeRequest(for candidate: CleanupCandidate) -> CleanupRequest? {
        lock.lock(); _requested.append(candidate.path); lock.unlock()
        return CleanupRequest(path: candidate.path, bundleId: candidate.bundleId,
                       fingerprint: ItemFingerprint(isDirectory: true, size: candidate.size, fileCount: 1, newestModified: 0))
    }

    func clean(_ requests: [CleanupRequest]) -> [CleanupResult] {
        lock.lock(); _cleaned.append(requests.map(\.path)); lock.unlock()
        return requests.map {
            refuse.contains($0.path)
                ? CleanupResult(path: $0.path, outcome: .refused(.changedSinceReview))
                : CleanupResult(path: $0.path, outcome: .trashed(trashedTo: nil))
        }
    }
}

private let cleanHome = "/Users/test"

private func cleanIndex() -> ScanIndex {
    func f(_ dir: String, _ n: String, _ s: Int64) -> FileNode {
        FileNode(name: n, path: "\(dir)/\(n)", isDirectory: false, size: s)
    }
    func d(_ p: String, _ c: [FileNode]) -> FileNode {
        FileNode(name: URL(fileURLWithPath: p).lastPathComponent, path: p, isDirectory: true, children: c)
    }
    let c = "\(cleanHome)/Library/Caches", l = "\(cleanHome)/Library/Logs"
    let caches = d(c, [d("\(c)/com.big", [f("\(c)/com.big", "x", 900)]),
                       d("\(c)/com.open", [f("\(c)/com.open", "x", 400)])])
    let logs = d(l, [f(l, "app.log", 300)])
    return ScanIndex(root: d(cleanHome, [d("\(cleanHome)/Library", [caches, logs])]))
}

private let cleanRules = RuleSet(rules: [
    CleanupRule(id: "caches", pattern: "~/Library/Caches/*", category: "App caches", risk: .safe,
                reason: "Rebuilt.", bundleIdFromFolder: true),
    CleanupRule(id: "logs", pattern: "~/Library/Logs/*", category: "Logs", risk: .review, reason: "Logs."),
])

@MainActor
private func cleanModel(_ cleaner: FakeCleaner, running: Set<String> = ["com.open"]) -> CleanupViewModel {
    let analyzer = CachesAnalyzer(rules: cleanRules, runningApps: FakeApps(ids: running), home: cleanHome)
    return CleanupViewModel(analyzer: analyzer, cleaner: cleaner)
}

@MainActor
@Test func onlySafeItemsWithClosedAppsStartTicked() {
    let model = cleanModel(FakeCleaner())
    model.load(cleanIndex())
    #expect(model.selectedItems.map(\.candidate.name) == ["com.big"])   // review-only logs and the open app stay unticked
    #expect(model.selectedSize == 900)
}

@MainActor
@Test func itemsOfARunningAppCannotBeTicked() {
    let model = cleanModel(FakeCleaner())
    model.load(cleanIndex())
    let open = model.report!.groups[0].items.first { $0.candidate.name == "com.open" }!
    model.toggle(open)
    #expect(!model.isSelected(open))
}

@MainActor
@Test func selectAllSkipsOpenAppsAndDeselectAllClears() {
    let model = cleanModel(FakeCleaner())
    model.load(cleanIndex())
    #expect(!model.allSelected)
    model.toggleAll()
    #expect(model.allSelected)
    #expect(Set(model.selectedItems.map(\.candidate.name)) == ["com.big", "app.log"])   // com.open is running
    #expect(model.selectedSize == 1200)
    model.toggleAll()
    #expect(model.selectedItems.isEmpty)
    #expect(!model.allSelected)
}

@MainActor
@Test func userCanTickAndUntick() {
    let model = cleanModel(FakeCleaner())
    model.load(cleanIndex())
    let logs = model.report!.groups.first { $0.category == "Logs" }!.items[0]
    model.toggle(logs)
    #expect(model.selectedSize == 1200)
    model.toggle(logs)
    #expect(model.selectedSize == 900)
}

@MainActor
@Test func cleanSendsOnlyTickedItemsToTheEngine() async {
    let cleaner = FakeCleaner()
    let model = cleanModel(cleaner)
    model.load(cleanIndex())
    await model.clean()
    #expect(cleaner.cleaned == [["\(cleanHome)/Library/Caches/com.big"]])
    guard case .done(let lines) = model.state else { Issue.record("expected done"); return }
    #expect(lines.map(\.status) == [.trashed])
    #expect(model.freedBytes == 900)
}

@MainActor
@Test func refusalsAreShownAndNotCountedAsFreed() async {
    let cleaner = FakeCleaner()
    cleaner.refuse = ["\(cleanHome)/Library/Caches/com.big"]
    let model = cleanModel(cleaner)
    model.load(cleanIndex())
    await model.clean()
    guard case .done(let lines) = model.state, case .skipped(let why) = lines[0].status else {
        Issue.record("expected a skipped line"); return
    }
    #expect(why.contains("changed"))
    #expect(model.freedBytes == 0)
}

@MainActor
@Test func nothingTickedMeansNothingIsCleaned() async {
    let cleaner = FakeCleaner()
    let model = cleanModel(cleaner)
    model.load(cleanIndex())
    model.toggle(model.selectedItems[0])
    await model.clean()
    #expect(cleaner.cleaned.isEmpty)
    guard case .ready = model.state else { Issue.record("should stay on the review"); return }
}

@MainActor
@Test func missingRulesShowAnError() {
    let model = CleanupViewModel(analyzer: nil, loadError: "no rules", cleaner: FakeCleaner())
    model.load(cleanIndex())
    #expect(model.state == .failed("no rules"))
}

@MainActor
@Test func cleanUsesTheFingerprintsTakenAtReview() async {
    let cleaner = FakeCleaner()
    let model = cleanModel(cleaner)
    model.load(cleanIndex())
    await model.clean()
    // One fingerprint per item at review time, none taken again while cleaning.
    #expect(cleaner.requested.count == 3)
    #expect(cleaner.cleaned == [["\(cleanHome)/Library/Caches/com.big"]])
}

// MARK: - Release review (T29)

@MainActor
@Test func everyUntickedItemSaysWhy() {
    let apps = FakeApps(ids: ["com.open"], notInstalled: ["com.big"])
    let model = CleanupViewModel(analyzer: CachesAnalyzer(rules: cleanRules, runningApps: apps, home: cleanHome),
                                 cleaner: FakeCleaner())
    model.load(cleanIndex())
    let items = model.report!.groups.flatMap(\.items)
    #expect(model.selectedItems.isEmpty)   // com.big has no installed owner, so nothing starts ticked
    for item in items where !model.isSelected(item) {
        #expect(CleanupViewModel.note(for: item) != nil, "\(item.candidate.name) is unticked with no reason")
    }
    let big = items.first { $0.candidate.name == "com.big" }!
    #expect(CleanupViewModel.note(for: big)!.contains("background service"))
    let open = items.first { $0.candidate.name == "com.open" }!
    #expect(CleanupViewModel.note(for: open)!.contains("Quit it"))
}

@MainActor
@Test func aTickedSafeItemHasNoWarning() {
    let model = cleanModel(FakeCleaner())
    model.load(cleanIndex())
    let big = model.report!.groups.flatMap(\.items).first { $0.candidate.name == "com.big" }!
    #expect(model.isSelected(big))
    #expect(CleanupViewModel.note(for: big) == nil)
}

// MARK: - What grew and menu bar free space

private struct FakeHistory: ScanHistorySource {
    var scans: [Int64: ScanIndex]
    func recentScans(rootPath: String) throws -> [ScanSummary] {
        scans.keys.sorted(by: >).map {
            ScanSummary(id: $0, rootPath: rootPath, createdAt: Date(timeIntervalSince1970: Double($0)), totalSize: 0)
        }
    }
    func scanIndex(id: Int64) throws -> ScanIndex? { scans[id] }
}

private func growthTree(_ size: Int64) -> ScanIndex {
    ScanIndex(root: FileNode(name: "h", path: "/h", isDirectory: true, children: [
        FileNode(name: "Games", path: "/h/Games", isDirectory: true, children: [
            FileNode(name: "g.bin", path: "/h/Games/g.bin", isDirectory: false, size: size)]),
    ]))
}

@MainActor
@Test func growthNeedsTwoScans() async {
    let model = GrowthViewModel(source: FakeHistory(scans: [1: growthTree(10)]))
    await model.load(rootPath: "/h")
    #expect(model.state == .needsTwoScans)
}

@MainActor
@Test func growthListsTheFolderThatGrew() async {
    let model = GrowthViewModel(source: FakeHistory(scans: [1: growthTree(100), 2: growthTree(900_000_000)]))
    await model.load(rootPath: "/h")
    guard case .ready(_, _, let changes) = model.state else {
        Issue.record("expected a comparison")
        return
    }
    #expect(changes.map(\.path) == ["/h/Games"])
}

@MainActor
@Test func growthWithoutHistoryFails() async {
    let model = GrowthViewModel(source: nil)
    await model.load(rootPath: "/h")
    guard case .failed = model.state else {
        Issue.record("expected a failure")
        return
    }
}

@Test func signedSizeShowsDirection() {
    #expect(GrowthViewModel.signedSize(1_000_000).hasPrefix("+"))
    #expect(GrowthViewModel.signedSize(-1_000_000).hasPrefix("-"))
}

private struct FixedVolume: VolumeCapacityProvider {
    var fails = false
    func capacities() throws -> VolumeCapacities {
        if fails { throw VolumeError.capacityUnavailable }
        return VolumeCapacities(total: 1000, available: 250, availableForImportantUsage: 250)
    }
}

@MainActor
@Test func freeSpaceTitleAndFraction() {
    let model = FreeSpaceViewModel(provider: FixedVolume())
    #expect(model.title.hasSuffix("free"))
    #expect(model.usedFraction == 0.75)
}

@MainActor
@Test func freeSpaceFallsBackWhenUnavailable() {
    let model = FreeSpaceViewModel(provider: FixedVolume(fails: true))
    #expect(model.title == "Disk")
    #expect(model.usedFraction == 0)
}
