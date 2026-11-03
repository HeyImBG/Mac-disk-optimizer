import Foundation

/// One folder whose size changed between two scans.
public struct FolderChange: Sendable, Equatable, Identifiable {
    public var id: String { path }
    public let path: String
    public let oldSize: Int64
    public let newSize: Int64
    /// The folder did not exist in the older scan (or was below its size cut-off).
    public let isNew: Bool
    public var delta: Int64 { newSize - oldSize }
}

/// Answers "what grew since last time". Read only.
public enum GrowthComparer {
    /// Folders whose total size changed by at least `minChange`, biggest change first.
    ///
    /// A parent is left out when one folder inside it explains most (80%) of its change, so the
    /// list points at the folder that actually grew instead of repeating every parent above it.
    /// Folders that disappeared are not listed. Scans of different roots are not comparable and give no result.
    public static func compare(old: ScanIndex, new: ScanIndex, minChange: Int64 = 100_000_000,
                               limit: Int = 20) -> [FolderChange] {
        guard old.root.path == new.root.path else { return [] }
        var result: [FolderChange] = []
        visit(new.root, old.root, minChange: max(1, minChange), out: &result)
        return Array(result.sorted { abs($0.delta) > abs($1.delta) }.prefix(max(0, limit)))
    }

    private static func visit(_ node: FileNode, _ old: FileNode?, minChange: Int64, out: inout [FolderChange]) {
        guard node.isDirectory else { return }
        var below: [FolderChange] = []
        let oldKids = Dictionary((old?.children ?? []).map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        for child in node.children { visit(child, oldKids[child.path], minChange: minChange, out: &below) }
        let delta = node.size - (old?.size ?? 0)
        if abs(delta) >= minChange {
            let explained = below.contains { $0.delta.signum() == delta.signum() && abs($0.delta) * 10 >= abs(delta) * 8 }
            if !explained {
                out.append(FolderChange(path: node.path, oldSize: old?.size ?? 0, newSize: node.size, isNew: old == nil))
            }
        }
        out.append(contentsOf: below)
    }
}
