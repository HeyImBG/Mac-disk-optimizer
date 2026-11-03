/// One file or folder in a scan. A value type, so a built tree is safe to share across tasks.
///
/// For a file, `size` is its allocated size in bytes. For a folder, `size` is the folder's own
/// allocated size before roll-up; `ScanIndex` replaces it with the total of the folder and
/// everything below it.
public struct FileNode: Sendable, Equatable {
    public let name: String
    public let path: String
    public let isDirectory: Bool
    public internal(set) var size: Int64
    /// Number of files (not folders) at or below this node. 1 for a file.
    public internal(set) var fileCount: Int
    public internal(set) var children: [FileNode]

    public init(
        name: String,
        path: String,
        isDirectory: Bool,
        size: Int64 = 0,
        children: [FileNode] = []
    ) {
        self.name = name
        self.path = path
        self.isDirectory = isDirectory
        self.size = size
        self.fileCount = isDirectory ? 0 : 1
        self.children = children
    }
}
