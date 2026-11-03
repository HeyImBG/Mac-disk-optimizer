import DiskEngine
import Foundation

/// Turns engine results into plain text. Pure functions, so they are easy to test.
public enum CLIFormatter {
    public static func bytes(_ n: Int64) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var value = Double(max(0, n))
        var unit = 0
        while value >= 1000, unit < units.count - 1 {
            value /= 1000
            unit += 1
        }
        return unit == 0 ? "\(Int(value)) B" : String(format: "%.1f %@", value, units[unit])
    }

    private static func pad(_ s: String, _ width: Int) -> String {
        s.count >= width ? s : String(repeating: " ", count: width - s.count) + s
    }

    /// The biggest folders directly under `root`.
    public static func topFolders(_ index: ScanIndex, root: String, top: Int) -> String {
        let kids = index.children(of: root).sorted { $0.size > $1.size }.prefix(top)
        guard !kids.isEmpty else { return "Nothing found under \(root)." }
        return kids.map { "\(pad(bytes($0.size), 10))  \($0.path)\($0.isDirectory ? "/" : "")" }.joined(separator: "\n")
    }

    public static func largeFiles(_ files: [LargeFile], top: Int) -> String {
        guard !files.isEmpty else { return "No large files found." }
        return files.prefix(top).map { "\(pad(bytes($0.size), 10))  \($0.path)" }.joined(separator: "\n")
    }

    public static func volume(_ info: VolumeInfo) -> String {
        "Disk: \(bytes(info.totalBytes)) total, \(bytes(info.usedBytes)) used, \(bytes(info.freeBytes)) free"
    }

    public static func suggestions(_ report: CleanupReport) -> String {
        guard !report.isEmpty else { return "No cleanup suggestions." }
        var lines: [String] = []
        for group in report.groups {
            lines.append("\(group.category): \(bytes(group.totalSize))")
            for item in group.items {
                let c = item.candidate
                let note = item.appRunning ? " (app is open)" : ""
                lines.append("  \(pad(bytes(c.size), 10))  [\(c.risk.rawValue)]  \(c.path)\(note)")
                lines.append("              \(c.reason)")
            }
        }
        lines.append("")
        lines.append("Total: \(bytes(report.totalSize)). Nothing was removed. Use the app to clean up.")
        return lines.joined(separator: "\n")
    }
}
