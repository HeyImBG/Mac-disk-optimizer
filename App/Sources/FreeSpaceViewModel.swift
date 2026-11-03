import Foundation
import Observation
import DiskEngine

/// Free space on the startup disk for the menu bar. Read only.
@MainActor
@Observable
final class FreeSpaceViewModel {
    private(set) var info: VolumeInfo?
    private let provider: any VolumeCapacityProvider

    init(provider: any VolumeCapacityProvider = SystemVolumeProvider()) {
        self.provider = provider
        refresh()
    }

    func refresh() {
        if let capacities = try? provider.capacities() {
            info = VolumeInfo(capacities)
        } else {
            info = nil
        }
    }

    /// Short text for the menu bar.
    var title: String {
        guard let info else { return "Disk" }
        return ScanViewModel.format(info.freeBytes) + " free"
    }

    /// Share of the disk that is used, from 0 to 1.
    var usedFraction: Double {
        guard let info, info.totalBytes > 0 else { return 0 }
        return min(1, Double(info.usedBytes) / Double(info.totalBytes))
    }
}
