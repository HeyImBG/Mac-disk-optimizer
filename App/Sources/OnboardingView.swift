import SwiftUI
import AppKit
import Observation
import DiskEngine

/// Tracks Full Disk Access and opens the System Settings pane. Read only.
@MainActor
@Observable
final class OnboardingViewModel {
    private(set) var status: FullDiskAccessStatus
    private let checker: FullDiskAccessChecker
    private let opener: (URL) -> Bool

    init(checker: FullDiskAccessChecker = FullDiskAccessChecker(),
         opener: @escaping (URL) -> Bool = { NSWorkspace.shared.open($0) }) {
        self.checker = checker
        self.opener = opener
        self.status = checker.check()
    }

    var needsOnboarding: Bool { status != .granted }

    func refresh() { status = checker.check() }

    /// Returns the link that opened, or nil if none worked.
    @discardableResult
    func openSettings() -> URL? { FullDiskAccessLinks.open(using: opener) }
}

struct OnboardingView: View {
    let model: OnboardingViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Allow Full Disk Access").font(.title2.bold())
            Text("To measure your whole disk, Disk Optimizer needs Full Disk Access. "
                 + "It only reads sizes. You confirm every cleanup, and files go to the Trash.")
            Text("In System Settings, go to Privacy & Security > Full Disk Access, "
                 + "add Disk Optimizer, and switch it on. You may need to restart the app.")
                .foregroundStyle(.secondary)
            if model.status == .denied {
                Text("Access is not granted yet.").foregroundStyle(.orange)
            } else if model.status == .unknown {
                Text("Could not tell whether access is granted.").foregroundStyle(.secondary)
            }
            HStack {
                Button("Open System Settings") { model.openSettings() }
                Button("Check again") { model.refresh() }
            }
        }
        .padding(24)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refresh()
        }
    }
}
