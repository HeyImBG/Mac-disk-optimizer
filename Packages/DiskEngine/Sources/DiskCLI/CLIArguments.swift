import Foundation

/// What the user asked the command line tool to do.
public enum CLICommand: Sendable, Equatable {
    /// Show the biggest folders under a path.
    case scan(path: String, top: Int)
    /// Show volume space, the biggest folders and the biggest files.
    case report(path: String, top: Int)
    /// Show cleanup suggestions. Nothing is deleted.
    case suggest(path: String, rulesPath: String?)
    case help
}

public enum CLIParseError: Error, Equatable, CustomStringConvertible {
    case unknownCommand(String)
    case unknownOption(String)
    case missingValue(String)
    case badNumber(String)

    public var description: String {
        switch self {
        case .unknownCommand(let c): return "Unknown command \"\(c)\". Run `diskopt help`."
        case .unknownOption(let o): return "Unknown option \"\(o)\". Run `diskopt help`."
        case .missingValue(let o): return "Option \(o) needs a value."
        case .badNumber(let v): return "\"\(v)\" is not a positive whole number."
        }
    }
}

public enum CLIArguments {
    public static let usage = """
    diskopt: look at what uses your disk. It only reads and suggests; it never deletes anything.

    Usage:
      diskopt scan    [--path FOLDER] [--top N]      Biggest folders (default: your home folder, top 10)
      diskopt report  [--path FOLDER] [--top N]      Free space, biggest folders and biggest files
      diskopt suggest [--path FOLDER] [--rules FILE] Cleanup suggestions. Nothing is removed.
      diskopt help

    To remove anything, use the DiskOptimizer app: it asks you first and moves files to the Trash.
    """

    public static func parse(_ args: [String], home: String = NSHomeDirectory()) throws -> CLICommand {
        guard let name = args.first else { return .help }
        var path = home
        var top = 10
        var rules: String?
        var index = 1
        while index < args.count {
            let option = args[index]
            func value() throws -> String {
                guard index + 1 < args.count else { throw CLIParseError.missingValue(option) }
                index += 1
                return args[index]
            }
            switch option {
            case "--path": path = try value()
            case "--top":
                let text = try value()
                guard let n = Int(text), n > 0 else { throw CLIParseError.badNumber(text) }
                top = n
            case "--rules": rules = try value()
            default: throw CLIParseError.unknownOption(option)
            }
            index += 1
        }
        switch name {
        case "scan": return .scan(path: path, top: top)
        case "report": return .report(path: path, top: top)
        case "suggest": return .suggest(path: path, rulesPath: rules)
        case "help", "--help", "-h": return .help
        default: throw CLIParseError.unknownCommand(name)
        }
    }
}
