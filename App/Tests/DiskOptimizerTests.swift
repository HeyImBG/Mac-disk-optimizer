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
