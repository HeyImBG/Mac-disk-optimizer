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
    @State private var onboarding = OnboardingViewModel()

    var body: some View {
        if onboarding.needsOnboarding {
            OnboardingView(model: onboarding)
        } else {
            main
        }
    }

    private var main: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Disk Optimizer \(DiskEngine.version)")
            VolumeDebugView()
        }
        .padding(40)
    }
}
