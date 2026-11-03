import Foundation

/// A `node_modules` folder and the project it belongs to.
public struct NodeModulesProject: Sendable, Equatable, Identifiable {
    public var id: String { path }
    /// The `node_modules` folder.
    public let path: String
    /// The project folder that holds it.
    public let projectPath: String
    /// Allocated bytes of the `node_modules` folder.
    public let size: Int64
    /// When the project was last changed (its `package.json` if it has one, otherwise the folder).
    public let lastTouched: Date?
    /// The project has a lockfile, so a package manager can rebuild `node_modules` exactly.
    public let hasLockfile: Bool

    /// Whole days from `lastTouched` to `now`, or nil if the date is unknown.
    public func daysSinceTouched(now: Date) -> Int? {
        lastTouched.map { max(0, Int(now.timeIntervalSince($0) / 86_400)) }
    }
}

/// Finds `node_modules` folders in a scan, with how long each project has been untouched. Read only.
public struct NodeModulesFinder: Sendable {
    static let lockfiles: Set<String> = [
        "package-lock.json", "npm-shrinkwrap.json", "yarn.lock", "pnpm-lock.yaml", "bun.lock", "bun.lockb",
    ]

    private let dates: any FileDateProvider
    private let home: String

    public init(dates: any FileDateProvider = SystemModificationDateProvider(), home: String = NSHomeDirectory()) {
        self.dates = dates
        self.home = home.count > 1 && home.hasSuffix("/") ? String(home.dropLast()) : home
    }

    /// Largest first. With `requireLockfile` (the default), projects without a lockfile are left out,
    /// because nothing could rebuild their dependencies exactly.
    /// Only looks inside the home folder (everything else is refused by `CleanupEngine` anyway, and
    /// holds things like global npm packages). Does not look inside hidden folders (`~/.vscode`,
    /// `~/.nvm` and other tools keep `node_modules` there that `npm install` would not restore),
    /// app bundles, photo libraries, the Trash or `~/Library`, and does not look inside a
    /// `node_modules` folder (so nested ones are not counted twice).
    public func find(in index: ScanIndex, requireLockfile: Bool = true) -> [NodeModulesProject] {
        var found: [NodeModulesProject] = []
        let root = index.root
        let start: FileNode?
        if root.path == home || root.path.hasPrefix(home + "/") {
            start = root
        } else if home.hasPrefix(root.path == "/" ? "/" : root.path + "/") {
            start = index.node(at: home)
        } else {
            start = nil
        }
        guard let start, !isHiddenBelowHome(start.path) else { return [] }
        var stack = [start]
        while let folder = stack.popLast() {
            for child in folder.children where child.isDirectory {
                if child.name == "node_modules" {
                    let hasLock = folder.children.contains { !$0.isDirectory && Self.lockfiles.contains($0.name) }
                    guard child.size > 0, hasLock || !requireLockfile else { continue }
                    let manifest = folder.children.first { !$0.isDirectory && $0.name == "package.json" }
                    found.append(NodeModulesProject(
                        path: child.path, projectPath: folder.path, size: child.size,
                        lastTouched: dates.lastOpened(path: manifest?.path ?? folder.path), hasLockfile: hasLock))
                } else if !isSkipped(child) {
                    stack.append(child)
                }
            }
        }
        return found.sorted { $0.size != $1.size ? $0.size > $1.size : $0.path < $1.path }
    }

    /// The same folders as review suggestions, so they can sit beside the rule matches.
    public func candidates(in index: ScanIndex, now: Date = Date()) -> [CleanupCandidate] {
        find(in: index).map { project in
            let name = URL(fileURLWithPath: project.projectPath).lastPathComponent
            var reason = "Dependencies for the project \"\(name)\". Run npm install (or yarn or pnpm) in the project to get them back."
            if let days = project.daysSinceTouched(now: now) {
                reason += days == 0 ? " The project changed today." : " The project has not changed for \(days) day\(days == 1 ? "" : "s")."
            }
            return CleanupCandidate(
                ruleId: "node-modules", path: project.path, name: "node_modules (\(name))", isDirectory: true,
                size: project.size, category: "Developer projects", risk: .review, reason: reason, bundleId: nil)
        }
    }

    private func isSkipped(_ node: FileNode) -> Bool {
        let name = node.name.lowercased()
        return node.name.hasPrefix(".") || name.hasSuffix(".app") || name.hasSuffix(".photoslibrary") || name.hasSuffix(".photolibrary")
            || node.path == home + "/Library"
    }

    /// A scan started inside a hidden folder of home, such as `~/.vscode/extensions`.
    private func isHiddenBelowHome(_ path: String) -> Bool {
        guard path.hasPrefix(home + "/") else { return false }
        return path.dropFirst(home.count + 1).split(separator: "/").contains { $0.hasPrefix(".") }
    }
}
