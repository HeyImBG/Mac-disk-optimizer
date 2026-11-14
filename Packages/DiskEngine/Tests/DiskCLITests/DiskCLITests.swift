@testable import DiskEngine
import Foundation
import Testing
@testable import DiskCLI

@Suite struct CLIArgumentsTests {
    @Test func parsesScanWithOptions() throws {
        let cmd = try CLIArguments.parse(["scan", "--path", "/tmp/x", "--top", "3"], home: "/h")
        #expect(cmd == .scan(path: "/tmp/x", top: 3))
    }

    @Test func defaultsToHomeAndTopTen() throws {
        #expect(try CLIArguments.parse(["report"], home: "/h") == .report(path: "/h", top: 10))
        #expect(try CLIArguments.parse(["suggest"], home: "/h") == .suggest(path: "/h", rulesPath: nil))
    }

    @Test func noArgumentsShowsHelp() throws {
        #expect(try CLIArguments.parse([]) == .help)
    }

    @Test func rejectsBadInput() {
        #expect(throws: CLIParseError.unknownCommand("delete")) { try CLIArguments.parse(["delete"]) }
        #expect(throws: CLIParseError.unknownOption("--force")) { try CLIArguments.parse(["scan", "--force"]) }
        #expect(throws: CLIParseError.missingValue("--path")) { try CLIArguments.parse(["scan", "--path"]) }
        #expect(throws: CLIParseError.badNumber("0")) { try CLIArguments.parse(["scan", "--top", "0"]) }
    }
}

@Suite struct CLIFormatterTests {
    @Test func formatsBytes() {
        #expect(CLIFormatter.bytes(0) == "0 B")
        #expect(CLIFormatter.bytes(999) == "999 B")
        #expect(CLIFormatter.bytes(1_500_000) == "1.5 MB")
    }

    @Test func listsBiggestFoldersFirst() {
        let small = FileNode(name: "a", path: "/r/a", isDirectory: false, size: 10)
        let big = FileNode(name: "b", path: "/r/b", isDirectory: false, size: 5_000)
        let index = ScanIndex(root: FileNode(name: "r", path: "/r", isDirectory: true, children: [small, big]))
        let text = CLIFormatter.topFolders(index, root: "/r", top: 1)
        #expect(text.contains("/r/b"))
        #expect(!text.contains("/r/a"))
    }

    @Test func emptyReportSaysSo() {
        #expect(CLIFormatter.suggestions(CleanupReport(groups: [])) == "No cleanup suggestions.")
    }

    @Test func largeFilesRespectsTop() {
        #expect(CLIFormatter.largeFiles([], top: 5) == "No large files found.")

        let files = [
            LargeFile(path: "/tmp/a.iso", name: "a.iso", size: 2_000_000_000, kind: .diskImage, lastOpened: nil),
            LargeFile(path: "/tmp/b.mov", name: "b.mov", size: 500_000_000, kind: .video, lastOpened: nil),
            LargeFile(path: "/tmp/c.zip", name: "c.zip", size: 100_000_000, kind: .archive, lastOpened: nil),
        ]
        let text = CLIFormatter.largeFiles(files, top: 2)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        #expect(lines.count == 2)
        #expect(text.contains("/tmp/a.iso"))
        #expect(text.contains("/tmp/b.mov"))
        #expect(!text.contains("/tmp/c.zip"))
        #expect(lines[0].contains(CLIFormatter.bytes(files[0].size)))
        #expect(lines[1].contains(CLIFormatter.bytes(files[1].size)))
    }

    @Test func formatsVolume() {
        let info = VolumeInfo(VolumeCapacities(
            total: 1_000_000_000,
            available: 400_000_000,
            availableForImportantUsage: 500_000_000
        ))
        #expect(CLIFormatter.volume(info) == "Disk: 1.0 GB total, 600.0 MB used, 400.0 MB free")
    }

    @Test func suggestionsListsGroupsAndTotal() {
        func item(_ id: String, _ path: String, _ size: Int64, _ category: String, _ risk: RiskLevel,
                  _ reason: String, running: Bool) -> CleanupItem {
            CleanupItem(
                candidate: CleanupCandidate(
                    ruleId: id, path: path, name: (path as NSString).lastPathComponent, isDirectory: true,
                    size: size, category: category, risk: risk, reason: reason, bundleId: "com.example.\(id)"),
                appRunning: running, preselected: false)
        }
        let browser1 = item("one", "/fake/home/Library/Caches/com.example.one", 3_000_000,
                            "Browser caches", .safe, "Rebuilt by the browser.", running: true)
        let browser2 = item("two", "/fake/home/Library/Caches/com.example.two", 1_500_000,
                            "Browser caches", .review, "Pages load slower once.", running: false)
        let dev = item("three", "/fake/home/Library/Developer/Xcode/DerivedData", 2_000,
                       "Developer files", .caution, "Old build output.", running: true)
        let report = CleanupReport(groups: [
            CleanupGroup(category: "Browser caches", items: [browser1, browser2]),
            CleanupGroup(category: "Developer files", items: [dev]),
        ])

        let text = CLIFormatter.suggestions(report)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        #expect(lines.count == 10)

        // Group headers.
        #expect(lines[0] == "Browser caches: 4.5 MB")
        #expect(lines[5] == "Developer files: 2.0 KB")

        // Each item: size, [risk] and path on one line, the reason on the next.
        let expected: [(Int, CleanupItem)] = [(1, browser1), (3, browser2), (6, dev)]
        for (index, entry) in expected {
            let c = entry.candidate
            #expect(lines[index].contains(CLIFormatter.bytes(c.size)))
            #expect(lines[index].contains("[\(c.risk.rawValue)]"))
            #expect(lines[index].contains(c.path))
            #expect(lines[index + 1].contains(c.reason))
        }
        #expect(lines[1].contains("3.0 MB") && lines[1].contains("[safe]"))
        #expect(lines[3].contains("1.5 MB") && lines[3].contains("[review]"))
        #expect(lines[6].contains("2.0 KB") && lines[6].contains("[caution]"))

        // Only items whose app is running end with the note.
        #expect(lines[1].hasSuffix(" (app is open)"))
        #expect(!lines[3].hasSuffix(" (app is open)"))
        #expect(lines[6].hasSuffix(" (app is open)"))

        // Blank line, then the closing line.
        #expect(lines[8].isEmpty)
        #expect(lines[9] == "Total: 4.5 MB. Nothing was removed. Use the app to clean up.")
        #expect(lines.last == "Total: \(CLIFormatter.bytes(report.totalSize)). Nothing was removed. Use the app to clean up.")
    }
}

@Suite struct CLIRunnerTests {
    @Test func helpExitsZeroAndMentionsNoDelete() async {
        let box = Box()
        let code = await CLIRunner.run(arguments: ["help"], out: { box.add($0) }, err: { _ in })
        #expect(code == 0)
        #expect(box.text.contains("never deletes"))
    }

    @Test func unknownCommandExitsTwo() async {
        let code = await CLIRunner.run(arguments: ["nope"], out: { _ in }, err: { _ in })
        #expect(code == 2)
    }

    @Test func scansATempFolder() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data(count: 100_000).write(to: dir.appendingPathComponent("big.bin"))
        let box = Box()
        let code = await CLIRunner.run(arguments: ["scan", "--path", dir.path], out: { box.add($0) }, err: { _ in })
        #expect(code == 0)
        #expect(box.text.contains("big.bin"))
    }

    @Test func missingFolderExitsOne() async {
        let code = await CLIRunner.run(arguments: ["scan", "--path", "/no/such/\(UUID().uuidString)"], out: { _ in }, err: { _ in })
        #expect(code == 1)
    }
}

final class Box: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    func add(_ s: String) { lock.lock(); lines.append(s); lock.unlock() }
    var text: String { lock.lock(); defer { lock.unlock() }; return lines.joined(separator: "\n") }
}
