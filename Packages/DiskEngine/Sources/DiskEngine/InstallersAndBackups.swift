import Foundation

// MARK: - Old installers in Downloads

/// Finds installer files (`.dmg`, `.pkg`, `.mpkg`) and zip files that have sat in the top level of
/// `~/Downloads` unopened for a while. Read only: it only suggests. Anything it finds still goes through
/// `CleanupEngine` (Trash only, with its checks) after the user confirms.
public struct OldInstallerFinder: Sendable {
    /// Not opened for this many days (default 30).
    public let minAgeDays: Int
    private let dates: any FileDateProvider
    private let home: String

    public init(minAgeDays: Int = 30, dates: any FileDateProvider = SystemFileDateProvider(),
                home: String = NSHomeDirectory()) {
        self.minAgeDays = max(0, minAgeDays)
        self.dates = dates
        self.home = home.count > 1 && home.hasSuffix("/") ? String(home.dropLast()) : home
    }

    /// Largest first. Only files directly inside `~/Downloads`; folders inside it are not searched,
    /// and files with no known date are left out. Installers are `review`; zip files are `caution`
    /// because they may hold something the user has nowhere else.
    public func candidates(in index: ScanIndex, now: Date = Date()) -> [CleanupCandidate] {
        guard let downloads = index.node(at: home + "/Downloads"), downloads.isDirectory else { return [] }
        let cutoff = now.addingTimeInterval(-Double(minAgeDays) * 86_400)
        var result: [CleanupCandidate] = []
        for file in downloads.children where !file.isDirectory && file.size > 0 && !file.name.hasPrefix(".") {
            let ext = (file.name as NSString).pathExtension.lowercased()
            let isZip = ext == "zip"
            guard isZip || ["dmg", "pkg", "mpkg"].contains(ext) else { continue }
            guard let opened = dates.lastOpened(path: file.path), opened < cutoff else { continue }
            let days = max(0, Int(now.timeIntervalSince(opened) / 86_400))
            let reason = isZip
                ? "A zip file in Downloads that has not been opened for about \(days) days. It may hold something you only have here, so look inside before you remove it."
                : "An installer in Downloads that has not been opened for about \(days) days. You can download it again from the developer if you ever need it."
            result.append(CleanupCandidate(
                ruleId: "old-installers", path: file.path, name: file.name, isDirectory: false, size: file.size,
                category: "Old installers", risk: isZip ? .caution : .review, reason: reason, bundleId: nil))
        }
        return result.sorted { $0.size != $1.size ? $0.size > $1.size : $0.path < $1.path }
    }
}

// MARK: - iPhone and iPad backups

/// Reads the device name and backup date of a backup folder, if it can. Behind a protocol so tests need no disk.
public protocol BackupInfoProvider: Sendable {
    func info(forBackupAt path: String) -> (deviceName: String?, lastBackup: Date?)
}

/// Reads `Info.plist` inside a backup folder. The keys are not documented by Apple, so a missing
/// or odd file simply gives nil values. Read only.
public struct SystemBackupInfoProvider: BackupInfoProvider {
    public init() {}

    public func info(forBackupAt path: String) -> (deviceName: String?, lastBackup: Date?) {
        let url = URL(fileURLWithPath: path).appendingPathComponent("Info.plist")
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return (nil, nil) }
        return (plist["Device Name"] as? String, plist["Last Backup Date"] as? Date)
    }
}

public struct IOSBackup: Sendable, Equatable, Identifiable {
    public var id: String { path }
    public let path: String
    /// The device's name when the backup says it (for example "Berat's iPhone").
    public let deviceName: String?
    public let lastBackup: Date?
    public let size: Int64
}

/// Lists local iPhone and iPad backups and their sizes, for `~/Library/Application Support/MobileSync/Backup`
/// (the location in [Apple's guide](https://support.apple.com/108809)). Report only, on purpose:
/// that folder is protected by `CleanupEngine`, and Apple says to delete a backup from Finder
/// (the device's General tab, Manage Backups), so the screen should explain that instead of offering the Trash.
public struct IOSBackupFinder: Sendable {
    private let info: any BackupInfoProvider
    private let home: String

    public init(info: any BackupInfoProvider = SystemBackupInfoProvider(), home: String = NSHomeDirectory()) {
        self.info = info
        self.home = home.count > 1 && home.hasSuffix("/") ? String(home.dropLast()) : home
    }

    /// Largest first. One entry per folder directly inside the Backup folder.
    public func find(in index: ScanIndex) -> [IOSBackup] {
        let folder = home + "/Library/Application Support/MobileSync/Backup"
        guard let backups = index.node(at: folder), backups.isDirectory else { return [] }
        return backups.children
            .filter { $0.isDirectory && $0.size > 0 && !$0.name.hasPrefix(".") }
            .map { node -> IOSBackup in
                let details = info.info(forBackupAt: node.path)
                return IOSBackup(path: node.path, deviceName: details.deviceName,
                                 lastBackup: details.lastBackup, size: node.size)
            }
            .sorted { $0.size != $1.size ? $0.size > $1.size : $0.path < $1.path }
    }
}
