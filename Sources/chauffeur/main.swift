import ChauffeurCore
import Foundation

let argv = Array(CommandLine.arguments.dropFirst())
if argv.first == "daemon" {
    guard let a = try? Args(Array(argv.dropFirst()), options: ["--udid"], usage: ""), let udid = a.option("--udid")
    else {
        print("usage: chauffeur daemon --udid <udid> (started automatically; you should not need this)")
        exit(64)
    }
    Daemon.serve(udid: udid)
}
let executable = Bundle.main.executablePath ?? CommandLine.arguments[0]
let output = CLI.handle(argv, .live(executable: executable))
if !output.text.isEmpty { print(output.text) }
exit(output.exit)
