import Testing
@testable import DiskEngine

private func file(_ dir: String, _ name: String, _ size: Int64) -> FileNode {
    FileNode(name: name, path: "\(dir)/\(name)", isDirectory: false, size: size)
}

private func sampleTree() -> FileNode {
    // /root
    //   a.txt (10)
    //   big/        (folder, own size 4)
    //     x.bin (500)
    //     deep/
    //       y.bin (100)
    //   small/
    //     z.txt (20)
    //   empty/
    let deep = FileNode(name: "deep", path: "/root/big/deep", isDirectory: true,
                        children: [file("/root/big/deep", "y.bin", 100)])
    let big = FileNode(name: "big", path: "/root/big", isDirectory: true, size: 4,
                       children: [file("/root/big", "x.bin", 500), deep])
    let small = FileNode(name: "small", path: "/root/small", isDirectory: true,
                         children: [file("/root/small", "z.txt", 20)])
    let empty = FileNode(name: "empty", path: "/root/empty", isDirectory: true)
    return FileNode(name: "root", path: "/root", isDirectory: true,
                    children: [file("/root", "a.txt", 10), small, big, empty])
}

@Test func rollUpSumsEveryFolder() {
    let index = ScanIndex(root: sampleTree())
    #expect(index.node(at: "/root/big/deep")?.size == 100)
    #expect(index.node(at: "/root/big")?.size == 604)   // 4 own + 500 + 100
    #expect(index.node(at: "/root/small")?.size == 20)
    #expect(index.node(at: "/root/empty")?.size == 0)
    #expect(index.totalSize == 634)
    #expect(index.root.size == 634)
}

@Test func fileCountsRollUp() {
    let index = ScanIndex(root: sampleTree())
    #expect(index.root.fileCount == 4)
    #expect(index.node(at: "/root/big")?.fileCount == 2)
    #expect(index.node(at: "/root/empty")?.fileCount == 0)
    #expect(index.node(at: "/root/a.txt")?.fileCount == 1)
}

@Test func childrenAreSortedLargestFirst() {
    let index = ScanIndex(root: sampleTree())
    let names = index.children(of: "/root").map(\.name)
    #expect(names == ["big", "small", "a.txt", "empty"])
    #expect(index.children(of: "/root/big").map(\.name) == ["x.bin", "deep"])
}

@Test func equalSizesSortByName() {
    let root = FileNode(name: "r", path: "/r", isDirectory: true, children: [
        file("/r", "b", 5), file("/r", "a", 5), file("/r", "c", 5),
    ])
    let index = ScanIndex(root: root)
    #expect(index.children(of: "/r").map(\.name) == ["a", "b", "c"])
}

@Test func lookupByPath() {
    let index = ScanIndex(root: sampleTree())
    #expect(index.node(at: "/root/big/x.bin")?.name == "x.bin")
    #expect(index.node(at: "/root/big/")?.name == "big")   // trailing slash ignored
    #expect(index.node(at: "/root")?.name == "root")
    #expect(index.node(at: "/nope") == nil)
    #expect(index.children(of: "/root/a.txt").isEmpty)
    #expect(index.children(of: "/nope").isEmpty)
}

@Test func singleFileRoot() {
    let index = ScanIndex(root: file("", "only", 7))
    #expect(index.totalSize == 7)
    #expect(index.root.fileCount == 1)
}
