import Foundation
import Testing
@testable import DiskEngine

private let home = "/Users/test"
private let now = Date(timeIntervalSince1970: 200 * 86_400)
private func daysAgo(_ n: Int) -> Date { now.addingTimeInterval(-Double(n) * 86_400) }

private func file(_ dir: String, _ name: String, _ size: Int64) -> FileNode {
    FileNode(name: name, path: "\(dir)/\(name)", isDirectory: false, size: size)
}

private func folder(_ path: String, _ children: [FileNode]) -> FileNode {
    FileNode(name: URL(fileURLWithPath: path).lastPathComponent, path: path, isDirectory: true, children: children)
}

private struct FakeDates: FileDateProvider {
    var dates: [String: Date]
    func lastOpened(path: String) -> Date? { dates[path] }
}

private struct NoApps: RunningAppProvider {
    func runningBundleIDs() -> Set<String> { [] }
    func isInstalledApp(_ bundleId: String) -> Bool { true }
}

// MARK: - Old installers

private let dl = "\(home)/Downloads"

/// Downloads: old.dmg 500 (90 days), old.pkg 300 (45), recent.dmg 700 (5), data.zip 200 (60),
/// photo.jpg 900 (400), nodate.dmg 100 (unknown), .hidden.dmg 50, sub/deep.dmg 800 (a subfolder), empty.pkg 0
/// Elsewhere: ~/Documents/other.dmg 600 (400)
private func downloadsFixture() -> ScanIndex {
    ScanIndex(root: folder(home, [
        folder(dl, [
            file(dl, "old.dmg", 500), file(dl, "old.pkg", 300), file(dl, "recent.dmg", 700),
            file(dl, "data.zip", 200), file(dl, "photo.jpg", 900), file(dl, "nodate.dmg", 100),
            file(dl, ".hidden.dmg", 50), file(dl, "empty.pkg", 0), file(dl, "Setup.MPKG", 120),
            folder("\(dl)/sub", [file("\(dl)/sub", "deep.dmg", 800)]),
        ]),
        folder("\(home)/Documents", [file("\(home)/Documents", "other.dmg", 600)]),
    ]))
}

private let installerDates = FakeDates(dates: [
    "\(dl)/old.dmg": daysAgo(90), "\(dl)/old.pkg": daysAgo(45), "\(dl)/recent.dmg": daysAgo(5),
    "\(dl)/data.zip": daysAgo(60), "\(dl)/photo.jpg": daysAgo(400), "\(dl)/.hidden.dmg": daysAgo(90),
    "\(dl)/empty.pkg": daysAgo(90), "\(dl)/Setup.MPKG": daysAgo(31),
    "\(dl)/sub/deep.dmg": daysAgo(90), "\(home)/Documents/other.dmg": daysAgo(400),
])

@Test func findsOnlyOldInstallersAndZipsDirectlyInDownloads() {
    let found = OldInstallerFinder(dates: installerDates, home: home).candidates(in: downloadsFixture(), now: now)
    #expect(found.map(\.name) == ["old.dmg", "old.pkg", "data.zip", "Setup.MPKG"])
    // Not: recent, a non-installer, no date, hidden, empty, inside a subfolder, outside Downloads.
}

@Test func installersAreReviewAndZipsAreCautionAndNothingIsSafe() {
    let found = OldInstallerFinder(dates: installerDates, home: home).candidates(in: downloadsFixture(), now: now)
    #expect(found.first { $0.name == "old.dmg" }?.risk == .review)
    #expect(found.first { $0.name == "data.zip" }?.risk == .caution)
    #expect(found.allSatisfy { $0.risk != .safe && $0.bundleId == nil && !$0.isDirectory && $0.category == "Old installers" })
}

@Test func reasonSaysHowLongAndZipsWarnToLookInside() {
    let found = OldInstallerFinder(dates: installerDates, home: home).candidates(in: downloadsFixture(), now: now)
    #expect(found.first { $0.name == "old.dmg" }!.reason.contains("90 days"))
    #expect(found.first { $0.name == "data.zip" }!.reason.contains("look inside"))
}

@Test func theAgeLimitCanBeChanged() {
    let strict = OldInstallerFinder(minAgeDays: 60, dates: installerDates, home: home)
    #expect(strict.candidates(in: downloadsFixture(), now: now).map(\.name) == ["old.dmg"])   // 90 days; the 60-day zip is not older than 60
    let loose = OldInstallerFinder(minAgeDays: 1, dates: installerDates, home: home)
    #expect(loose.candidates(in: downloadsFixture(), now: now).contains { $0.name == "recent.dmg" })
}

@Test func noDownloadsFolderGivesNothing() {
    let index = ScanIndex(root: folder(home, [folder("\(home)/Documents", [file("\(home)/Documents", "a.dmg", 5)])]))
    #expect(OldInstallerFinder(dates: installerDates, home: home).candidates(in: index, now: now).isEmpty)
}

@Test func analyzerShowsInstallersButNeverPreselectsThem() {
    let analyzer = CachesAnalyzer(rules: RuleSet(rules: []), runningApps: NoApps(), home: home,
                                  installers: OldInstallerFinder(dates: installerDates, home: home))
    let report = analyzer.analyze(downloadsFixture())
    #expect(report.groups.map(\.category) == ["Old installers"])
    #expect(report.totalSize == 500 + 300 + 200 + 120)
    #expect(report.preselectedSize == 0)
}

// MARK: - iOS backups

private struct FakeBackupInfo: BackupInfoProvider {
    var byFolder: [String: (String?, Date?)]
    func info(forBackupAt path: String) -> (deviceName: String?, lastBackup: Date?) {
        byFolder[URL(fileURLWithPath: path).lastPathComponent] ?? (nil, nil)
    }
}

private let backupRoot = "\(home)/Library/Application Support/MobileSync/Backup"

private func backupsFixture() -> ScanIndex {
    ScanIndex(root: folder(home, [folder("\(home)/Library", [folder("\(home)/Library/Application Support", [
        folder("\(home)/Library/Application Support/MobileSync", [folder(backupRoot, [
            folder("\(backupRoot)/AAA", [file("\(backupRoot)/AAA", "x", 4000)]),
            folder("\(backupRoot)/BBB", [file("\(backupRoot)/BBB", "x", 9000)]),
            folder("\(backupRoot)/.hidden", [file("\(backupRoot)/.hidden", "x", 1)]),
            file(backupRoot, "stray.txt", 7),
        ])]),
    ])])]))
}

@Test func listsBackupsLargestFirstWithDeviceNames() {
    let info = FakeBackupInfo(byFolder: ["BBB": ("Berat's iPhone", daysAgo(10))])
    let backups = IOSBackupFinder(info: info, home: home).find(in: backupsFixture())
    #expect(backups.map(\.path) == ["\(backupRoot)/BBB", "\(backupRoot)/AAA"])
    #expect(backups[0].deviceName == "Berat's iPhone")
    #expect(backups[0].lastBackup == daysAgo(10))
    #expect(backups[0].size == 9000)
    #expect(backups[1].deviceName == nil)       // no info for it: still listed
}

@Test func noBackupFolderGivesNothing() {
    let index = ScanIndex(root: folder(home, [folder("\(home)/Documents", [file("\(home)/Documents", "a", 5)])]))
    #expect(IOSBackupFinder(info: FakeBackupInfo(byFolder: [:]), home: home).find(in: index).isEmpty)
}

@Test func systemInfoProviderReadsAPlistAndToleratesMissingOnes() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("backup-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    let plist: [String: Any] = ["Device Name": "Test iPad", "Last Backup Date": date]
    try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        .write(to: root.appendingPathComponent("Info.plist"))
    let provider = SystemBackupInfoProvider()
    let read = provider.info(forBackupAt: root.path)
    #expect(read.deviceName == "Test iPad")
    #expect(read.lastBackup == date)
    let missing = provider.info(forBackupAt: root.appendingPathComponent("nope").path)
    #expect(missing.deviceName == nil && missing.lastBackup == nil)
}
