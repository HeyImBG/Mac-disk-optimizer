import SwiftUI
import Observation
import DiskEngine

/// Loads the volume overview for the debug view. Read only.
@MainActor
@Observable
final class VolumeDebugViewModel {
    enum State: Equatable {
        case idle
        case loading
        case loaded(VolumeOverview)
        case failed(String)
    }

    private(set) var state: State = .idle
    private let service: VolumeOverviewService

    init(service: VolumeOverviewService = VolumeOverviewService()) {
        self.service = service
    }

    func load() async {
        state = .loading
        do {
            state = .loaded(try await service.load())
        } catch {
            state = .failed("\(error)")
        }
    }

    static func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

struct VolumeDebugView: View {
    @State private var model = VolumeDebugViewModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Volume (debug)").font(.headline)
            switch model.state {
            case .idle, .loading:
                ProgressView()
            case .failed(let message):
                Text("Could not read the volume: \(message)").foregroundStyle(.red)
            case .loaded(let overview):
                row("Total", overview.info.totalBytes)
                row("Used", overview.info.usedBytes)
                row("Free", overview.info.freeBytes)
                row("Purgeable (estimate)", overview.info.purgeableBytes)
                Text("Local snapshots: \(overview.snapshots.count)")
                ForEach(overview.snapshots, id: \.name) { Text($0.name).font(.caption) }
                if let error = overview.snapshotError {
                    Text("Snapshot list failed: \(error)").font(.caption).foregroundStyle(.orange)
                }
            }
        }
        .task { await model.load() }
    }

    private func row(_ label: String, _ bytes: Int64) -> some View {
        HStack { Text(label); Spacer(); Text(VolumeDebugViewModel.format(bytes)).monospacedDigit() }
    }
}
