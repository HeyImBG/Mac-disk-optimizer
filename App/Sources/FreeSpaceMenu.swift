import SwiftUI

/// What the menu bar item shows when it is opened.
struct FreeSpaceMenu: View {
    let model: FreeSpaceViewModel

    var body: some View {
        if let info = model.info {
            Text("\(ScanViewModel.format(info.freeBytes)) free of \(ScanViewModel.format(info.totalBytes))")
            Text("\(ScanViewModel.format(info.usedBytes)) used")
        } else {
            Text("Free space is not available.")
        }
        Divider()
        Button("Refresh") { model.refresh() }
    }
}
