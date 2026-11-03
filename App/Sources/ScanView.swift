import SwiftUI
import AppKit
import QuickLook
import DiskEngine

struct ScanView: View {
    let location: ScanLocation
    @State private var model = ScanViewModel()
    @State private var selection: String?
    @State private var quickLookURL: URL?

    var body: some View {
        VStack(spacing: 0) {
            statusBar
            Divider()
            sortHeader
            Divider()
            List(model.rows, selection: $selection) { node in
                row(node)
            }
        }
        .quickLookPreview($quickLookURL)
        .navigationTitle(location.name)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button { model.goUp() } label: { Image(systemName: "chevron.up") }
                    .help("Up one folder")
                    .disabled(!model.canGoUp)
            }
            ToolbarItem {
                if model.isScanning {
                    Button("Stop") { model.cancel() }
                } else {
                    Button("Scan") { model.startScan(root: location.url) }
                }
            }
        }
    }

    @ViewBuilder private var statusBar: some View {
        HStack {
            switch model.state {
            case .idle:
                Text("Press Scan to measure \(location.name).")
            case .scanning(let p):
                ProgressView().controlSize(.small)
                Text("\(p.filesScanned) files, \(ScanViewModel.format(p.bytesScanned))")
            case .finished(let unreadable):
                if let index = model.index {
                    Text("\(ScanViewModel.format(index.totalSize)) in \(index.root.fileCount) files")
                }
                if unreadable > 0 {
                    Text("\(unreadable) folders could not be read").foregroundStyle(.orange)
                }
            case .failed(let message):
                Text(message).foregroundStyle(.red)
            }
            Spacer()
        }
        .font(.callout)
        .padding(10)
    }

    private var sortHeader: some View {
        HStack {
            sortButton("Name", .name)
            Spacer()
            sortButton("Size", .size)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
    }

    private func sortButton(_ title: String, _ key: SortKey) -> some View {
        Button {
            model.toggleSort(key)
        } label: {
            HStack(spacing: 4) {
                Text(title)
                if model.sortKey == key {
                    Image(systemName: model.ascending ? "chevron.up" : "chevron.down")
                }
            }
        }
        .buttonStyle(.plain)
        .font(.caption.bold())
    }

    private func row(_ node: FileNode) -> some View {
        HStack {
            Image(systemName: node.isDirectory ? "folder" : "doc")
            Text(node.name).lineLimit(1)
            Spacer()
            Text(ScanViewModel.format(node.size)).monospacedDigit().foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { model.open(node) }
        .contextMenu {
            if node.isDirectory {
                Button("Open") { model.open(node) }
            }
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: node.path)])
            }
            Button("Quick Look") { quickLookURL = URL(fileURLWithPath: node.path) }
        }
    }
}
