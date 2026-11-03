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
        Text("Disk Optimizer \(DiskEngine.version)")
            .padding(40)
    }
}
