/// An immutable index over a scan tree: sizes rolled up to every folder, children sorted
/// largest first, and lookup by path.
public struct ScanIndex: Sendable {
    public let root: FileNode
    private let nodesByPath: [String: FileNode]

    /// Builds the index. Folder sizes become the sum of their own size and all descendants.
    public init(root: FileNode) {
        let rolled = ScanIndex.rollUp(root)
        var map: [String: FileNode] = [:]
        ScanIndex.collect(rolled, into: &map)
        self.root = rolled
        self.nodesByPath = map
    }

    /// Wraps a tree whose sizes are already rolled up and whose children are already sorted,
    /// such as one loaded from `ScanStore`. Skips the roll-up pass.
    public init(alreadyRolledUp root: FileNode) {
        var map: [String: FileNode] = [:]
        ScanIndex.collect(root, into: &map)
        self.root = root
        self.nodesByPath = map
    }

    /// Total size in bytes of everything under the root.
    public var totalSize: Int64 { root.size }

    /// Finds a node by its full path. A trailing slash is ignored.
    public func node(at path: String) -> FileNode? {
        nodesByPath[ScanIndex.normalize(path)]
    }

    /// Children of the node at `path`, largest first. Empty for files and unknown paths.
    public func children(of path: String) -> [FileNode] {
        node(at: path)?.children ?? []
    }

    // MARK: - Private

    /// Largest first; ties broken by name so the order is stable.
    static func sortedLargestFirst(_ nodes: [FileNode]) -> [FileNode] {
        nodes.sorted { a, b in
            a.size != b.size ? a.size > b.size : a.name < b.name
        }
    }

    private static func normalize(_ path: String) -> String {
        var p = path
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        return p
    }

    private static func rollUp(_ node: FileNode) -> FileNode {
        guard node.isDirectory else { return node }
        var result = node
        var total = node.size
        var files = 0
        var kids: [FileNode] = []
        kids.reserveCapacity(node.children.count)
        for child in node.children {
            let rolled = rollUp(child)
            total += rolled.size
            files += rolled.fileCount
            kids.append(rolled)
        }
        result.size = total
        result.fileCount = files
        result.children = sortedLargestFirst(kids)
        return result
    }

    private static func collect(_ node: FileNode, into map: inout [String: FileNode]) {
        map[normalize(node.path)] = node
        for child in node.children { collect(child, into: &map) }
    }
}
