import SwiftUI
import DiskEngine

/// "What grew since the last scan", shown as a sheet.
struct GrowthView: View {
    let location: ScanLocation
    @State private var model = GrowthViewModel()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("What changed in \(location.name)").font(.title2.bold())
            content
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 520, minHeight: 360)
        .task { await model.load(rootPath: location.url.path) }
    }

    @ViewBuilder private var content: some View {
        switch model.state {
        case .idle, .loading:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        case .needsTwoScans:
            Text("Scan this location at least twice. Then this list shows which folders grew or shrank between the last two scans.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        case .failed(let message):
            Text(message).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        case .ready(let older, let newer, let changes):
            Text("Between \(older.formatted(date: .abbreviated, time: .shortened)) and \(newer.formatted(date: .abbreviated, time: .shortened)). Only folders that changed by 100 MB or more are listed.")
                .font(.callout).foregroundStyle(.secondary)
            if changes.isEmpty {
                Text("No folder changed by 100 MB or more.").frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                List(changes) { change in
                    HStack {
                        Text(GrowthViewModel.signedSize(change.delta))
                            .monospacedDigit()
                            .foregroundStyle(change.delta > 0 ? Color.orange : Color.green)
                            .frame(width: 90, alignment: .trailing)
                        Text(change.path).lineLimit(1).truncationMode(.middle)
                        if change.isNew { Text("new").font(.caption).foregroundStyle(.secondary) }
                    }
                }
            }
        }
    }
}
