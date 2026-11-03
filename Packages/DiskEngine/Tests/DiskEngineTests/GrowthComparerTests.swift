import Foundation
import Testing
@testable import DiskEngine

@Suite struct GrowthComparerTests {
    private func file(_ path: String, _ size: Int64) -> FileNode {
        FileNode(name: (path as NSString).lastPathComponent, path: path, isDirectory: false, size: size)
    }

    private func dir(_ path: String, _ kids: [FileNode]) -> FileNode {
        FileNode(name: (path as NSString).lastPathComponent, path: path, isDirectory: true, children: kids)
    }

    private func tree(movies: Int64, docs: Int64) -> ScanIndex {
        ScanIndex(root: dir("/h", [
            dir("/h/Movies", [dir("/h/Movies/Trips", [file("/h/Movies/Trips/a.mov", movies)])]),
            dir("/h/Docs", [file("/h/Docs/b.pdf", docs)]),
        ]))
    }

    @Test func pointsAtTheFolderThatGrewNotItsParents() {
        let changes = GrowthComparer.compare(old: tree(movies: 1_000, docs: 500), new: tree(movies: 5_000, docs: 500), minChange: 1_000)
        #expect(changes.map(\.path) == ["/h/Movies/Trips"])
        #expect(changes[0].delta == 4_000)
        #expect(changes[0].isNew == false)
    }

    @Test func smallChangesAreIgnored() {
        let changes = GrowthComparer.compare(old: tree(movies: 1_000, docs: 500), new: tree(movies: 1_100, docs: 500), minChange: 1_000)
        #expect(changes.isEmpty)
    }

    @Test func shrinkingFoldersAreReportedWithNegativeDelta() {
        let changes = GrowthComparer.compare(old: tree(movies: 5_000, docs: 500), new: tree(movies: 1_000, docs: 500), minChange: 1_000)
        #expect(changes.first?.delta == -4_000)
    }

    @Test func newFolderIsMarkedNew() {
        let old = ScanIndex(root: dir("/h", [dir("/h/Docs", [file("/h/Docs/b.pdf", 500)])]))
        let new = ScanIndex(root: dir("/h", [dir("/h/Docs", [file("/h/Docs/b.pdf", 500)]),
                                            dir("/h/Games", [file("/h/Games/g.bin", 9_000)])]))
        let changes = GrowthComparer.compare(old: old, new: new, minChange: 1_000)
        #expect(changes.map(\.path) == ["/h/Games"])
        #expect(changes[0].isNew)
    }

    @Test func differentRootsGiveNoResult() {
        let other = ScanIndex(root: dir("/x", [file("/x/a", 9_000)]))
        #expect(GrowthComparer.compare(old: tree(movies: 1, docs: 1), new: other, minChange: 1).isEmpty)
    }

    @Test func splitGrowthKeepsTheParent() {
        // Two folders each grow by half, so neither explains the parent alone.
        let old = ScanIndex(root: dir("/h", [dir("/h/P", [dir("/h/P/A", [file("/h/P/A/a", 100)]), dir("/h/P/B", [file("/h/P/B/b", 100)])])]))
        let new = ScanIndex(root: dir("/h", [dir("/h/P", [dir("/h/P/A", [file("/h/P/A/a", 5_100)]), dir("/h/P/B", [file("/h/P/B/b", 5_100)])])]))
        let paths = GrowthComparer.compare(old: old, new: new, minChange: 1_000).map(\.path)
        #expect(paths.contains("/h/P"))
        #expect(paths.contains("/h/P/A"))
    }
}

@Suite struct ScanHistoryTests {
    @Test func historyListsNewestFirstAndLoadsByID() throws {
        let store = try ScanStore()
        let t0 = Date(timeIntervalSince1970: 1_000)
        let one = ScanIndex(root: FileNode(name: "h", path: "/h", isDirectory: true, children: [
            FileNode(name: "a", path: "/h/a", isDirectory: false, size: 2_000_000)]))
        let two = ScanIndex(root: FileNode(name: "h", path: "/h", isDirectory: true, children: [
            FileNode(name: "a", path: "/h/a", isDirectory: false, size: 5_000_000)]))
        let id1 = try store.save(one, at: t0, keep: 5)
        let id2 = try store.save(two, at: t0.addingTimeInterval(60), keep: 5)
        let history = try store.history(rootPath: "/h")
        #expect(history.map(\.id) == [id2, id1])
        #expect(history.map(\.totalSize) == [5_000_000, 2_000_000])
        #expect(try store.load(id: id1)?.index.totalSize == 2_000_000)
        #expect(try store.load(id: 9_999) == nil)
        #expect(try store.loadLatest()?.id == id2)
    }
}
