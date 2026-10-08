import Foundation

public enum CLI {
    /// Commands that run inside the daemon.
    public static let forwarded: Set<String> = [
        "snapshot", "find", "wait", "screenshot", "tap", "type", "scroll", "swipe", "button", "install", "launch",
        "terminate", "logs", "open",
        "permission", "location", "push", "appearance", "do",
    ]

    public struct Environment {
        public var env: [String: String]
        public var cwd: URL
        public var devices: () throws -> [DeviceInfo]
        public var send: (String, [String]) throws -> Output

        public init(
            env: [String: String], cwd: URL, devices: @escaping () throws -> [DeviceInfo],
            send: @escaping (String, [String]) throws -> Output
        ) {
            self.env = env
            self.cwd = cwd
            self.devices = devices
            self.send = send
        }

        public static func live(executable: String) -> Environment {
            let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            return Environment(
                env: ProcessInfo.processInfo.environment,
                cwd: cwd,
                devices: { try SimCtl.devices() },
                send: { udid, args in
                    try DaemonClient.send(udid: udid, args: args, cwd: cwd.path, executable: executable)
                })
        }
    }

    /// `--udid <udid>` and `--json` may appear anywhere before `--` (or `--args`, whose tokens belong to the app).
    static func globals(_ argv: [String]) throws -> (udid: String?, json: Bool, argv: [String]) {
        var udid: String?
        var json = false
        var rest: [String] = []
        var i = 0
        while i < argv.count {
            let token = argv[i]
            if token == "--" || token == "--args" {
                rest += argv[i...]
                break
            }
            if token == "--json" {
                json = true
                i += 1
                continue
            }
            if token == "--udid" {
                guard i + 1 < argv.count else { throw ChauffeurError.usage("--udid needs a value\n\n" + Usage.text) }
                udid = argv[i + 1]
                i += 2
                continue
            }
            rest.append(token)
            i += 1
        }
        return (udid, json, rest)
    }

    @MainActor public static func handle(_ argv: [String], _ e: Environment) -> Output {
        let json = argv.prefix { $0 != "--" && $0 != "--args" }.contains("--json")
        let out = handleText(argv, e)
        return json ? Output(out.jsonLine(), exit: out.exit, data: out.data) : out
    }

    @MainActor static func handleText(_ argv: [String], _ e: Environment) -> Output {
        do {
            let (udidFlag, _, rest) = try globals(argv)
            guard let command = rest.first else { return Output(Usage.text, exit: 64) }
            let tail = Array(rest.dropFirst())
            switch command {
            case "help", "--help", "-h":
                return Output(Usage.text)
            case "--version", "version":
                return Output("chauffeur \(Chauffeur.version)")
            case "use":
                var a = try Args(tail, usage: "usage: chauffeur use <name|udid>")
                guard let name = a.text() else { throw ChauffeurError.usage(a.usage) }
                let device = try Target.match(name, in: e.devices())
                try Target.writeConfig(udid: device.udid, in: e.cwd)
                return Output("using \(device.name) (\(device.runtime)) \(device.udid) for \(e.cwd.path)")
            case "doctor":
                let a = try Args(tail, flags: ["--live"], usage: "usage: chauffeur doctor [--live]")
                try a.done()
                return Doctor.run(udidFlag: udidFlag, live: a.flag("--live"), env: e)
            case "mcp":
                try Args(tail, usage: "usage: chauffeur mcp   (an MCP server on stdin/stdout; your agent starts it)")
                    .done()
                return Output("", exit: MCPStdio.serve(env: e))
            case "skill":
                var a = try Args(
                    tail, options: ["--agents"], usage: "usage: chauffeur skill install [--agents claude,codex,cursor]")
                guard a.next() == "install" else { throw ChauffeurError.usage(a.usage) }
                try a.done()
                let agents = (a.option("--agents") ?? Skill.agents.joined(separator: ","))
                    .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                if let unknown = agents.first(where: { !Skill.agents.contains($0) }) {
                    throw ChauffeurError.usage(
                        "unknown agent \(Perception.quote(unknown)); choose from claude, codex, cursor\n" + a.usage)
                }
                let lines = try Skill.install(agents: agents, in: e.cwd)
                return Output(
                    (lines + ["optional MCP server: chauffeur mcp (e.g. claude mcp add chauffeur -- chauffeur mcp)"])
                        .joined(separator: "\n"))
            case _ where forwarded.contains(command):
                let udid = try Target.resolve(
                    flag: udidFlag, env: e.env["CHAUFFEUR_UDID"],
                    configUDID: Target.readConfig(from: e.cwd), devices: e.devices())
                return try e.send(udid, [command] + tail)
            default:
                return Output("unknown command \"\(command)\"\n\n" + Usage.text, exit: 64)
            }
        } catch ChauffeurError.usage(let text) {
            return Output(text, exit: 64)
        } catch let error as ChauffeurError {
            return Output(error.description, exit: 1)
        } catch {
            return Output("\(error)", exit: 1)
        }
    }
}
