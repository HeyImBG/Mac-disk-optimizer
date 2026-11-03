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
