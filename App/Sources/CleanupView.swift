import SwiftUI
import DiskEngine

/// Review screen: shows what could be cleaned, lets the user tick items, and asks before anything
/// is moved to the Trash.
struct CleanupView: View {
    let index: ScanIndex
    @State private var model = CleanupViewModel.bundled()
    @State private var confirming = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            content
            Divider()
            footer
        }
        .frame(minWidth: 560, minHeight: 460)
        .task { model.load(index) }
        .confirmationDialog(
            "Move \(model.selectedItems.count) items to the Trash?", isPresented: $confirming) {
            Button("Move to Trash") { Task { await model.clean() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(format(model.selectedSize)) will be moved to the Trash. You can put it back from there.")
        }
    }

    @ViewBuilder private var content: some View {
        switch model.state {
        case .idle, .cleaning:
            ProgressView(model.state == .cleaning ? "Moving to the Trash…" : "Looking…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            Text(message).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
        case .ready(let report):
            if report.isEmpty {
                Text("Nothing to clean was found in this scan.").foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(report.groups) { group in
                        Section("\(group.category) · \(format(group.totalSize))") {
                            ForEach(group.items) { item in row(item) }
                        }
                    }
                }
            }
        case .done(let lines):
            List(lines) { line in
                HStack {
                    Image(systemName: icon(line.status)).foregroundStyle(color(line.status))
                    VStack(alignment: .leading) {
                        Text(line.name)
                        Text(detail(line.status)).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(format(line.size)).monospacedDigit().foregroundStyle(.secondary)
                }
            }
        }
    }

    private func row(_ item: CleanupItem) -> some View {
        HStack(alignment: .top) {
            Toggle("", isOn: Binding(get: { model.isSelected(item) }, set: { _ in model.toggle(item) }))
                .labelsHidden()
                .disabled(item.appRunning)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.candidate.name)
                Text(item.candidate.reason).font(.caption).foregroundStyle(.secondary)
                if item.appRunning {
                    Text("This app is open. Quit it to clean this.").font(.caption).foregroundStyle(.orange)
                } else if item.candidate.risk != .safe {
                    Text("Take a look first: this is not ticked for you.").font(.caption).foregroundStyle(.orange)
                }
            }
            Spacer()
            Text(format(item.candidate.size)).monospacedDigit().foregroundStyle(.secondary)
        }
    }

    private var footer: some View {
        HStack {
            if case .done = model.state {
                Text("\(format(model.freedBytes)) moved to the Trash.")
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            } else {
                Text("\(model.selectedItems.count) selected · \(format(model.selectedSize))")
                Spacer()
                Button("Close") { dismiss() }
                Button("Move to Trash…") { confirming = true }
                    .disabled(model.selectedItems.isEmpty || model.report == nil)
            }
        }
        .padding(12)
    }

    private func icon(_ s: CleanupLine.Status) -> String {
        switch s {
        case .trashed: return "checkmark.circle.fill"
        case .skipped: return "minus.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }

    private func color(_ s: CleanupLine.Status) -> Color {
        switch s {
        case .trashed: return .green
        case .skipped: return .secondary
        case .failed: return .red
        }
    }

    private func detail(_ s: CleanupLine.Status) -> String {
        switch s {
        case .trashed: return "Moved to the Trash"
        case .skipped(let why): return "Left alone: \(why)"
        case .failed(let why): return "Could not move it: \(why)"
        }
    }

    private func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
