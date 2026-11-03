import SwiftUI
import DiskEngine

@main
struct DiskOptimizerApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

struct ContentView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Disk Optimizer \(DiskEngine.version)")
            VolumeDebugView()
        }
        .padding(40)
    }
}
