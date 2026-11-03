import Foundation
import Testing
@testable import DiskEngine

private let home = "/Users/test"

private func file(_ dir: String, _ name: String, _ size: Int64) -> FileNode {
    FileNode(name: name, path: "\(dir)/\(name)", isDirectory: false, size: size)
}

private func folder(_ path: String, _ children: [FileNode]) -> FileNode {
    FileNode(name: URL(fileURLWithPath: path).lastPathComponent, path: path, isDirectory: true, children: children)
}

/// A directory chain with one file of `size` at the bottom, so every folder on the way exists.
private func chain(_ path: String, size: Int64) -> FileNode {
    folder(path, [file(path, "data", size)])
}

private func tree(_ nodes: [FileNode]) -> ScanIndex {
    // Builds /Users/test/... from nodes given with absolute paths under home.
    ScanIndex(root: folder(home, nodes))
}

private let steam = "\(home)/Library/Application Support/Steam/steamapps/common"

private func fixture() -> ScanIndex {
    let lib = "\(home)/Library"
    return tree([
        folder("\(lib)", [
            folder("\(lib)/Application Support", [
                folder("\(lib)/Application Support/Steam", [folder("\(lib)/Application Support/Steam/steamapps", [
                    folder(steam, [chain("\(steam)/Big Game", size: 900), chain("\(steam)/Small Game", size: 100),
                                   file(steam, ".DS_Store", 5)]),
                    folder("\(lib)/Application Support/Steam/steamapps/downloading", [file("\(lib)/Application Support/Steam/steamapps/downloading", "x", 70)]),
                ])]),
                folder("\(lib)/Application Support/CrossOver", [folder("\(lib)/Application Support/CrossOver/Bottles", [
                    chain("\(lib)/Application Support/CrossOver/Bottles/Win10", size: 400)])]),
            ]),
            folder("\(lib)/Containers", [folder("\(lib)/Containers/com.utmapp.UTM", [folder("\(lib)/Containers/com.utmapp.UTM/Data", [
                folder("\(lib)/Containers/com.utmapp.UTM/Data/Documents", [
                    chain("\(lib)/Containers/com.utmapp.UTM/Data/Documents/Kali.utm", size: 3000),
                    file("\(lib)/Containers/com.utmapp.UTM/Data/Documents", "notes.txt", 2)])])])]),
        ]),
        folder("\(home)/Parallels", [chain("\(home)/Parallels/Windows 11.pvm", size: 5000)]),
        folder("\(home)/VirtualBox VMs", [chain("\(home)/VirtualBox VMs/Ubuntu", size: 1500)]),
        // Not in a known folder, found by its extension.
        folder("\(home)/Projects", [chain("\(home)/Projects/lab.vmwarevm", size: 800)]),
        // Inside an app: ignored.
        folder("\(home)/Tools.app", [chain("\(home)/Tools.app/x.utm", size: 9999)]),
    ])
}

@Test func listsGamesAndBottlesLargestFirst() {
    let report = GamesAndVMsAnalyzer(home: home).analyze(fixture())
    #expect(report.games.map(\.name) == ["Big Game", "Win10", "Small Game"])
    #expect(report.games.map(\.source) == ["Steam", "CrossOver", "Steam"])
    #expect(report.gamesSize == 1400)
}

@Test func listsVirtualMachinesIncludingOnesInOtherFolders() {
    let report = GamesAndVMsAnalyzer(home: home).analyze(fixture())
    #expect(report.virtualMachines.map(\.name) == ["Windows 11", "Kali", "Ubuntu", "lab"])
    #expect(report.virtualMachines.map(\.source) == ["Parallels Desktop", "UTM", "VirtualBox", "VMware Fusion"])
    #expect(report.virtualMachinesSize == 5000 + 3000 + 1500 + 800)
}

@Test func nothingIsEverSafeAndNoteSaysWhereToRemoveIt() {
    let report = GamesAndVMsAnalyzer(home: home).analyze(fixture())
    let all = report.games + report.virtualMachines
    #expect(all.allSatisfy { $0.risk != .safe && !$0.note.isEmpty })
    #expect(report.games.first { $0.name == "Big Game" }?.risk == .review)
    #expect(report.games.first { $0.name == "Win10" }?.risk == .caution)
    #expect(report.virtualMachines.allSatisfy { $0.risk == .caution })
}

@Test func ignoresHiddenFilesOtherFilesInVMFoldersAndAppBundles() {
    let report = GamesAndVMsAnalyzer(home: home).analyze(fixture())
    let names = (report.games + report.virtualMachines).map(\.name)
    #expect(!names.contains(".DS_Store"))
    #expect(!names.contains("notes.txt"))
    #expect(!names.contains("x"))
    #expect(!(report.games + report.virtualMachines).contains { $0.path.contains(".app/") })
    // Steam's download folder is not a game.
    #expect(!names.contains("downloading"))
}

@Test func eachItemIsListedOnce() {
    let report = GamesAndVMsAnalyzer(home: home).analyze(fixture())
    let paths = (report.games + report.virtualMachines).map(\.path)
    #expect(Set(paths).count == paths.count)
}

@Test func emptyWhenThereAreNoGamesOrVMs() {
    let index = tree([folder("\(home)/Documents", [file("\(home)/Documents", "a", 5)])])
    let report = GamesAndVMsAnalyzer(home: home).analyze(index)
    #expect(report.isEmpty)
    #expect(report.gamesSize == 0)
}

@Test func aContainerFolderThatEndsInUtmIsNotListedAsAVM() {
    // com.utmapp.UTM ends in ".utm" when the case is ignored, but it only holds the real VMs.
    let report = GamesAndVMsAnalyzer(home: home).analyze(fixture())
    #expect(!report.virtualMachines.contains { $0.name.hasPrefix("com.utmapp") })
    #expect(report.virtualMachines.filter { $0.source == "UTM" }.count == 1)
}
