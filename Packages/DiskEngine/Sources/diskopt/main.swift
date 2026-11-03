import DiskCLI
import Foundation

let code = await CLIRunner.run(arguments: Array(CommandLine.arguments.dropFirst()))
exit(code)
