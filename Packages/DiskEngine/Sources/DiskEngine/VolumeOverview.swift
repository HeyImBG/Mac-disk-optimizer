import Foundation

/// Raw capacity numbers for one volume, in bytes.
public struct VolumeCapacities: Sendable, Equatable {
    public var total: Int64
    /// Plain free space (`volumeAvailableCapacityKey`). Excludes purgeable space.
    public var available: Int64
    /// Free space macOS could make available if it purged caches and snapshots
    /// (`volumeAvailableCapacityForImportantUsageKey`).
    public var availableForImportantUsage: Int64

    public init(total: Int64, available: Int64, availableForImportantUsage: Int64) {
        self.total = total
        self.available = available
        self.availableForImportantUsage = availableForImportantUsage
    }
}

/// Volume totals shown to the user.
public struct VolumeInfo: Sendable, Equatable {
    public let totalBytes: Int64
    public let freeBytes: Int64
    public let usedBytes: Int64
    /// Estimate: important-usage free space minus plain free space. Apple has no public
    /// purgeable key, so this is an inference that still needs checking against Finder.
    public let purgeableBytes: Int64

    public init(_ c: VolumeCapacities) {
        let total = max(0, c.total)
        let free = min(max(0, c.available), total)
        totalBytes = total
        freeBytes = free
        usedBytes = total - free
        purgeableBytes = max(0, c.availableForImportantUsage - c.available)
    }
}

/// One APFS local snapshot as listed by `tmutil listlocalsnapshots`.
public struct LocalSnapshot: Sendable, Equatable {
    public let name: String
    /// Parsed from the name when it has the form `...YYYY-MM-DD-HHMMSS...`, in local time.
    public let date: Date?
}

/// Pure parser for `tmutil listlocalsnapshots` output.
public enum SnapshotListParser {
    public static func parse(_ output: String, calendar: Calendar = .current) -> [LocalSnapshot] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            guard let token = line.split(separator: " ").first,
                  token.hasPrefix("com.apple.") else { return nil }
            let name = String(token)
            return LocalSnapshot(name: name, date: date(in: name, calendar: calendar))
        }
    }

    private static func date(in name: String, calendar: Calendar) -> Date? {
        for part in name.split(separator: ".") {
            let pieces = part.split(separator: "-")
            // Expect YYYY-MM-DD-HHMMSS
            guard pieces.count >= 4, pieces[0].count == 4, pieces[3].count == 6,
                  let y = Int(pieces[0]), let mo = Int(pieces[1]), let d = Int(pieces[2]),
                  let hms = Int(pieces[3]) else { continue }
            var c = DateComponents()
            c.year = y; c.month = mo; c.day = d
            c.hour = hms / 10_000; c.minute = (hms / 100) % 100; c.second = hms % 100
            return calendar.date(from: c)
        }
        return nil
    }
}

public protocol VolumeCapacityProvider: Sendable {
    func capacities() throws -> VolumeCapacities
}

public protocol SnapshotProvider: Sendable {
    func listLocalSnapshots() async throws -> [LocalSnapshot]
}

public struct VolumeOverview: Sendable, Equatable {
    public let info: VolumeInfo
    public let snapshots: [LocalSnapshot]
    /// Set when the snapshot list could not be read; the rest of the overview is still valid.
    public let snapshotError: String?
}

/// Combines capacity numbers and the snapshot list. Read only.
public struct VolumeOverviewService: Sendable {
    private let volume: any VolumeCapacityProvider
    private let snapshots: any SnapshotProvider

    public init(volume: any VolumeCapacityProvider = SystemVolumeProvider(),
                snapshots: any SnapshotProvider = TmutilSnapshotProvider()) {
        self.volume = volume
        self.snapshots = snapshots
    }

    public func load() async throws -> VolumeOverview {
        let info = VolumeInfo(try volume.capacities())
        do {
            let list = try await snapshots.listLocalSnapshots()
            return VolumeOverview(info: info, snapshots: list, snapshotError: nil)
        } catch {
            return VolumeOverview(info: info, snapshots: [], snapshotError: "\(error)")
        }
    }
}

public enum VolumeError: Error, Equatable {
    case capacityUnavailable
    case tmutilFailed(status: Int32)
    case tmutilUnavailable
}

/// Reads capacities from the volume that holds the home folder. The home folder is used
/// because the important-usage key has been reported to return 0 for `/` on iOS.
public struct SystemVolumeProvider: VolumeCapacityProvider {
    public init() {}

    public func capacities() throws -> VolumeCapacities {
        let url = FileManager.default.homeDirectoryForCurrentUser
        let v = try url.resourceValues(forKeys: [
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
        ])
        guard let total = v.volumeTotalCapacity,
              let available = v.volumeAvailableCapacity else { throw VolumeError.capacityUnavailable }
        return VolumeCapacities(
            total: Int64(total), available: Int64(available),
            availableForImportantUsage: v.volumeAvailableCapacityForImportantUsage ?? Int64(available))
    }
}

/// Runs `/usr/bin/tmutil listlocalsnapshots /`. Listing only; never deletes or thins snapshots.
/// Not verified yet on a real Mac (see docs/research/apis.md, section 3).
public struct TmutilSnapshotProvider: SnapshotProvider {
    public init() {}

    public func listLocalSnapshots() async throws -> [LocalSnapshot] {
        #if os(macOS)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tmutil")
        process.arguments = ["listlocalsnapshots", "/"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do { try process.run() } catch { throw VolumeError.tmutilUnavailable }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw VolumeError.tmutilFailed(status: process.terminationStatus)
        }
        return SnapshotListParser.parse(String(decoding: data, as: UTF8.self))
        #else
        throw VolumeError.tmutilUnavailable
        #endif
    }
}
