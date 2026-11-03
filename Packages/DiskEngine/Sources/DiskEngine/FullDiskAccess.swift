import Foundation

public enum FullDiskAccessStatus: Sendable, Equatable {
    case granted
    case denied
    /// None of the probe folders exist, so access can't be judged.
    case unknown
}

public enum ProbeResult: Sendable, Equatable {
    case readable
    case denied
    case missing
}

public protocol ProtectedPathReader: Sendable {
    func probe(path: String) -> ProbeResult
}

/// Tries to list a folder with `opendir`. Never writes anything.
public struct SystemProtectedPathReader: ProtectedPathReader {
    public init() {}

    public func probe(path: String) -> ProbeResult {
        guard let dir = opendir(path) else {
            switch errno {
            case EPERM, EACCES: return .denied
            default: return .missing
            }
        }
        closedir(dir)
        return .readable
    }
}

/// Decides whether the app has Full Disk Access by reading folders macOS protects.
public struct FullDiskAccessChecker: Sendable {
    /// Folders in the user's home that need Full Disk Access to list on macOS 14 and later.
    /// Not every account has all of them, so several are tried.
    public static func defaultProbePaths(home: String = NSHomeDirectory()) -> [String] {
        ["Library/Safari", "Library/Mail", "Library/Messages", "Library/Suggestions"].map { home + "/" + $0 }
    }

    private let reader: any ProtectedPathReader
    private let paths: [String]

    public init(reader: any ProtectedPathReader = SystemProtectedPathReader(),
                paths: [String] = FullDiskAccessChecker.defaultProbePaths()) {
        self.reader = reader
        self.paths = paths
    }

    /// Granted if any probe folder is readable, denied if one exists but is blocked,
    /// unknown if none exist.
    public func check() -> FullDiskAccessStatus {
        var sawDenied = false
        for path in paths {
            switch reader.probe(path: path) {
            case .readable: return .granted
            case .denied: sawDenied = true
            case .missing: continue
            }
        }
        return sawDenied ? .denied : .unknown
    }
}

/// Links that open the Full Disk Access pane, most specific first.
/// The first link is untested on macOS 14, 15 and 26, so the others are fallbacks
/// (see docs/research/apis.md, section 4).
public enum FullDiskAccessLinks {
    public static let urls: [URL] = [
        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!,
        URL(string: "x-apple.systempreferences:com.apple.preference.security")!,
        URL(fileURLWithPath: "/System/Applications/System Settings.app"),
    ]

    /// Tries each link in order with `open` (which returns whether it worked) and stops at the
    /// first success. Returns the link that worked, or nil.
    @discardableResult
    public static func open(using open: (URL) -> Bool) -> URL? {
        urls.first { open($0) }
    }
}
