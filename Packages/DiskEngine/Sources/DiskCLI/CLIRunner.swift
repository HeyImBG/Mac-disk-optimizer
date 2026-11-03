import DiskEngine
import Foundation

/// Runs the command line tool. Everything here is read only.
public enum CLIRunner {
    /// Returns the process exit code. Normal output goes to stdout, problems to stderr.
    public static func run(
        arguments: [String],
        out: @Sendable (String) -> Void = { print($0) },
        err: @Sendable (String) -> Void = { FileHandle.standardError.write(Data(($0 + "\n").utf8)) }
    ) async -> Int32 {
        let command: CLICommand
        do { command = try CLIArguments.parse(arguments) } catch {
            err("\(error)")
            return 2
        }
        switch command {
        case .help:
            out(CLIArguments.usage)
            return 0
        case .scan(let path, let top):
            guard let result = await scan(path, err: err) else { return 1 }
            out(CLIFormatter.topFolders(result.index, root: path, top: top))
            return 0
        case .report(let path, let top):
            if let overview = try? await VolumeOverviewService().load() {
                out(CLIFormatter.volume(overview.info))
                out("")
            }
            guard let result = await scan(path, err: err) else { return 1 }
            out("Biggest folders in \(path):")
            out(CLIFormatter.topFolders(result.index, root: path, top: top))
            out("")
            out("Biggest files:")
            let files = LargeFileAnalyzer().find(in: result.index, query: LargeFileQuery(limit: top))
            out(CLIFormatter.largeFiles(files, top: top))
            return 0
        case .suggest(let path, let rulesPath):
            guard let rules = loadRules(rulesPath, err: err) else { return 1 }
            guard let result = await scan(path, err: err) else { return 1 }
            let analyzer = CachesAnalyzer(rules: rules, nodeModules: NodeModulesFinder(), installers: OldInstallerFinder())
            out(CLIFormatter.suggestions(analyzer.analyze(result.index)))
            return 0
        }
    }

    private static func scan(_ path: String, err: @Sendable (String) -> Void) async -> ScanResult? {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else {
            err("\(path) is not a folder.")
            return nil
        }
        for await event in DiskScanner().scan(root: URL(fileURLWithPath: path)) {
            switch event {
            case .progress: continue
            case .finished(let result):
                if !result.unreadablePaths.isEmpty {
                    err("Note: \(result.unreadablePaths.count) folders could not be read (grant Full Disk Access to your terminal to include them).")
                }
                return result
            case .failed(let message):
                err("Scan failed: \(message)")
                return nil
            }
        }
        err("Scan ended without a result.")
        return nil
    }

    private static func loadRules(_ path: String?, err: @Sendable (String) -> Void) -> RuleSet? {
        let file = path ?? "App/Resources/cleanup-rules.json"
        guard let data = FileManager.default.contents(atPath: file) else {
            err("Cannot read the rules file \(file). Pass one with --rules FILE.")
            return nil
        }
        do { return try RuleSet.decode(data) } catch {
            err("The rules file \(file) is not valid: \(error)")
            return nil
        }
    }
}
