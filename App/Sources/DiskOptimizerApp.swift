import SwiftUI
import DiskEngine

@main
struct DiskOptimizerApp: App {
    @State private var freeSpace = FreeSpaceViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        MenuBarExtra {
            FreeSpaceMenu(model: freeSpace)
        } label: {
            Label(freeSpace.title, systemImage: "internaldrive")
                .task {
                    // Keep the number fresh while the app runs.
                    while !Task.isCancelled {
                        freeSpace.refresh()
                        try? await Task.sleep(for: .seconds(60))
                    }
                }
        }
    }
}

struct ContentView: View {
    @State private var onboarding = OnboardingViewModel()
    @State private var location: ScanLocation? = ScanLocation.defaults[0]

    var body: some View {
        if onboarding.needsOnboarding {
            OnboardingView(model: onboarding)
        } else {
            main
        }
    }

    private var main: some View {
        NavigationSplitView {
            VStack(alignment: .leading) {
                List(ScanLocation.defaults, selection: $location) { loc in
                    Label(loc.name, systemImage: loc.url.path == "/" ? "internaldrive" : "house")
                        .tag(loc)
                }
                VolumeDebugView().padding()
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 240)
        } detail: {
            if let location {
                ScanView(location: location).id(location.id)
            } else {
                Text("Choose a location in the sidebar.").foregroundStyle(.secondary)
            }
        }
    }
}
