import Foundation

public enum FootprintKind: String, Sendable, Equatable {
    case game
    case virtualMachine
}

/// One game, game bottle or virtual machine and how much room it takes.
public struct AppFootprint: Sendable, Equatable, Identifiable {
    public var id: String { path }
    public let kind: FootprintKind
    /// The launcher or VM app, for example "Steam" or "Parallels Desktop".
    public let source: String
    public let name: String
    public let path: String
    /// Allocated bytes of everything inside.
    public let size: Int64
    /// `review` for games that can be downloaded again, `caution` for bottles and VMs, which hold
    /// installs and saves that cannot be rebuilt. Never `safe`.
    public let risk: RiskLevel
    /// Plain-English advice for the screen.
    public let note: String
}

public struct FootprintReport: Sendable, Equatable {
    /// Largest first.
    public let games: [AppFootprint]
    /// Largest first.
    public let virtualMachines: [AppFootprint]
    public var gamesSize: Int64 { games.reduce(0) { $0 + $1.size } }
    public var virtualMachinesSize: Int64 { virtualMachines.reduce(0) { $0 + $1.size } }
    public var isEmpty: Bool { games.isEmpty && virtualMachines.isEmpty }
}

/// Shows how much room each game and each virtual machine takes. Read only, and it makes no cleanup
/// suggestions: removing a game or a VM is done in its own app (Steam, UTM, Parallels, ...), so
/// the app's library stays consistent. The folders it looks in are listed in
/// `docs/research/games.md` and `docs/research/vms.md`; several are unverified.
public struct GamesAndVMsAnalyzer: Sendable {
    private struct Place {
        let source: String
        let kind: FootprintKind
        /// Folder whose children are the items. `~/` is the home folder.
        let folder: String
        /// Only children whose name ends with this (lowercase), if set.
        let suffix: String?
        let risk: RiskLevel
        let note: String
    }

    private static let gameNote = "You can download this game again, but local-only saves may be lost. Remove it from the launcher, not from Finder."
    private static let bottleNote = "A bottle holds Windows installs and saves that cannot be rebuilt. Remove it from the app that made it."
    private static let vmNote = "A virtual machine holds a whole computer and cannot be rebuilt. Remove it from the app that made it, after saving anything you need."

    private static let places: [Place] = [
        Place(source: "Steam", kind: .game, folder: "~/Library/Application Support/Steam/steamapps/common",
              suffix: nil, risk: .review, note: gameNote),
        Place(source: "Epic Games", kind: .game, folder: "/Users/Shared/Epic Games",
              suffix: nil, risk: .review, note: gameNote),
        Place(source: "CrossOver", kind: .game, folder: "~/Library/Application Support/CrossOver/Bottles",
              suffix: nil, risk: .caution, note: bottleNote),
        Place(source: "Whisky", kind: .game, folder: "~/Library/Containers/com.isaacmarovitz.Whisky/Bottles",
              suffix: nil, risk: .caution, note: bottleNote),
        Place(source: "UTM", kind: .virtualMachine, folder: "~/Library/Containers/com.utmapp.UTM/Data/Documents",
              suffix: ".utm", risk: .caution, note: vmNote),
        Place(source: "Parallels Desktop", kind: .virtualMachine, folder: "~/Parallels",
              suffix: ".pvm", risk: .caution, note: vmNote),
        Place(source: "VMware Fusion", kind: .virtualMachine, folder: "~/Virtual Machines.localized",
              suffix: ".vmwarevm", risk: .caution, note: vmNote),
        Place(source: "VMware Fusion", kind: .virtualMachine, folder: "~/Virtual Machines",
              suffix: ".vmwarevm", risk: .caution, note: vmNote),
        Place(source: "VMware Fusion", kind: .virtualMachine, folder: "~/Documents/Virtual Machines.localized",
              suffix: ".vmwarevm", risk: .caution, note: vmNote),
        Place(source: "VirtualBox", kind: .virtualMachine, folder: "~/VirtualBox VMs",
              suffix: nil, risk: .caution, note: vmNote),
    ]

    /// VM bundles are also found by extension anywhere, because every VM app lets the user pick a folder.
    private static let bundleSources: [String: String] = [
        ".utm": "UTM", ".pvm": "Parallels Desktop", ".vmwarevm": "VMware Fusion",
    ]

    private let home: String

    public init(home: String = NSHomeDirectory()) {
        self.home = home.count > 1 && home.hasSuffix("/") ? String(home.dropLast()) : home
    }

    public func analyze(_ index: ScanIndex) -> FootprintReport {
        var seen = Set<String>()
        var items: [AppFootprint] = []

        func add(_ node: FileNode, source: String, kind: FootprintKind, risk: RiskLevel, note: String) {
            guard node.size > 0, seen.insert(node.path).inserted else { return }
            items.append(AppFootprint(kind: kind, source: source, name: Self.displayName(node.name),
                                      path: node.path, size: node.size, risk: risk, note: note))
        }

        for place in Self.places {
            let folder = place.folder.hasPrefix("~/") ? home + place.folder.dropFirst() : place.folder
            guard let parent = index.node(at: String(folder)), parent.isDirectory else { continue }
            for child in parent.children where !child.name.hasPrefix(".") {
                if let suffix = place.suffix, !child.name.lowercased().hasSuffix(suffix) { continue }
                add(child, source: place.source, kind: place.kind, risk: place.risk, note: place.note)
            }
        }

        // VM bundles outside the usual folders.
        var stack = [index.root]
        while let folder = stack.popLast() {
            for child in folder.children where child.isDirectory {
                let lower = child.name.lowercased()
                if let ext = Self.bundleSources.keys.first(where: { lower.hasSuffix($0) }) {
                    add(child, source: Self.bundleSources[ext] ?? "", kind: .virtualMachine, risk: .caution, note: Self.vmNote)
                } else if !lower.hasSuffix(".app"), child.name != ".Trash" {
                    stack.append(child)
                }
            }
        }

        // A folder whose name only happens to end in ".utm" (for example com.utmapp.UTM, UTM's own
        // container) holds the real VMs: list the VMs, not the folder. Then drop anything nested in a kept item.
        let paths = items.map(\.path)
        items = items.filter { item in !paths.contains { $0.hasPrefix(item.path + "/") } }
        let keptPaths = items.map(\.path)
        items = items.filter { item in !keptPaths.contains { item.path.hasPrefix($0 + "/") } }

        func order(_ a: AppFootprint, _ b: AppFootprint) -> Bool {
            a.size != b.size ? a.size > b.size : a.path < b.path
        }
        return FootprintReport(games: items.filter { $0.kind == .game }.sorted(by: order),
                               virtualMachines: items.filter { $0.kind == .virtualMachine }.sorted(by: order))
    }

    /// "Windows 11.utm" shows as "Windows 11".
    private static func displayName(_ name: String) -> String {
        let lower = name.lowercased()
        for ext in bundleSources.keys where lower.hasSuffix(ext) {
            return String(name.dropLast(ext.count))
        }
        return name
    }
}
