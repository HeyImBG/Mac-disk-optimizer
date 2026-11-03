import Foundation
import Testing
@testable import DiskEngine

@Test func volumeInfoComputesUsedAndPurgeable() {
    let info = VolumeInfo(VolumeCapacities(total: 1000, available: 200, availableForImportantUsage: 350))
    #expect(info.totalBytes == 1000)
    #expect(info.freeBytes == 200)
    #expect(info.usedBytes == 800)
    #expect(info.purgeableBytes == 150)
}

@Test func volumeInfoClampsOddValues() {
    // Important-usage below plain free must not give negative purgeable space.
    let a = VolumeInfo(VolumeCapacities(total: 1000, available: 300, availableForImportantUsage: 0))
    #expect(a.purgeableBytes == 0)
    // Free larger than total is clamped.
    let b = VolumeInfo(VolumeCapacities(total: 100, available: 500, availableForImportantUsage: 500))
    #expect(b.freeBytes == 100)
    #expect(b.usedBytes == 0)
}

@Test func parsesSnapshotList() throws {
    let output = """
    Snapshots for volume group containing disk /:
    com.apple.TimeMachine.2026-11-03-120000.local
    com.apple.TimeMachine.2026-11-02-090530.local (dataless)

    """
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "UTC")!
    let list = SnapshotListParser.parse(output, calendar: cal)
    #expect(list.map(\.name) == [
        "com.apple.TimeMachine.2026-11-03-120000.local",
        "com.apple.TimeMachine.2026-11-02-090530.local",
    ])
    let first = try #require(list.first?.date)
    let c = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: first)
    #expect(c.year == 2026 && c.month == 11 && c.day == 3)
    #expect(c.hour == 12 && c.minute == 0 && c.second == 0)
    let second = try #require(list.last?.date)
    #expect(cal.component(.minute, from: second) == 5)
    #expect(cal.component(.second, from: second) == 30)
}

@Test func parserHandlesEmptyAndUnknownOutput() {
    #expect(SnapshotListParser.parse("").isEmpty)
    #expect(SnapshotListParser.parse("Snapshots for volume group containing disk /:\n").isEmpty)
    let odd = SnapshotListParser.parse("com.apple.os.update-ABCDEF")
    #expect(odd.count == 1)
    #expect(odd[0].date == nil)
}

private struct FakeVolume: VolumeCapacityProvider {
    var result: Result<VolumeCapacities, VolumeError>
    func capacities() throws -> VolumeCapacities { try result.get() }
}

private struct FakeSnapshots: SnapshotProvider {
    var result: Result<[LocalSnapshot], VolumeError>
    func listLocalSnapshots() async throws -> [LocalSnapshot] { try result.get() }
}

@Test func serviceCombinesVolumeAndSnapshots() async throws {
    let snap = LocalSnapshot(name: "com.apple.TimeMachine.x.local", date: nil)
    let service = VolumeOverviewService(
        volume: FakeVolume(result: .success(VolumeCapacities(total: 10, available: 4, availableForImportantUsage: 6))),
        snapshots: FakeSnapshots(result: .success([snap])))
    let overview = try await service.load()
    #expect(overview.info.usedBytes == 6)
    #expect(overview.info.purgeableBytes == 2)
    #expect(overview.snapshots == [snap])
    #expect(overview.snapshotError == nil)
}

@Test func snapshotFailureKeepsVolumeNumbers() async throws {
    let service = VolumeOverviewService(
        volume: FakeVolume(result: .success(VolumeCapacities(total: 10, available: 4, availableForImportantUsage: 4))),
        snapshots: FakeSnapshots(result: .failure(.tmutilFailed(status: 1))))
    let overview = try await service.load()
    #expect(overview.info.totalBytes == 10)
    #expect(overview.snapshots.isEmpty)
    #expect(overview.snapshotError != nil)
}

@Test func volumeFailureThrows() async {
    let service = VolumeOverviewService(
        volume: FakeVolume(result: .failure(.capacityUnavailable)),
        snapshots: FakeSnapshots(result: .success([])))
    await #expect(throws: VolumeError.capacityUnavailable) { try await service.load() }
}
