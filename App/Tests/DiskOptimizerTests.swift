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
