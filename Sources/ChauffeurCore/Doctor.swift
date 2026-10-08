import ChauffeurBridge
import Foundation

public struct Check: Equatable, Sendable {
    public enum Status: String, Sendable {
        case ok = "✓", warn = "!", fail = "✗"
        public var name: String { self == .ok ? "ok" : self == .warn ? "warn" : "fail" }
    }
    public var status: Status
    public var text: String
    public init(status: Status, text: String) { self.status = status; self.text = text }
}

public enum Doctor {
    public static func render(_ checks: [Check]) -> String {
        (["chauffeur \(Chauffeur.version)"] + checks.map { "\($0.status.rawValue) \($0.text)" }).joined(separator: "\n")
    }

    public static func exitCode(_ checks: [Check]) -> Int32 { checks.contains { $0.status == .fail } ? 1 : 0 }

    /// The report as text, exit code and `--json` data.
    public static func output(_ checks: [Check]) -> Output {
        Output(render(checks), exit: exitCode(checks),
               data: ["checks": .array(checks.map { ["status": .string($0.status.name), "text": .string($0.text)] })])
    }

    public static func levelCheck(level: String?, daemonRunning: Bool, udid: String) -> Check {
        guard let level else { return Check(status: .warn, text: "cannot read the BackBoard log level") }
        if level == "debug" && !daemonRunning {
            return Check(status: .warn, text: "BackBoard logging is still at debug with no daemon running (a previous run "
                         + "crashed). Fix: xcrun simctl spawn \(udid) log config --mode level:default --subsystem com.apple.BackBoard")
        }
        return Check(status: .ok, text: "BackBoard log level: \(level)" + (daemonRunning ? " (raised by the running daemon)" : ""))
    }

    /// Whether a daemon answers on the socket, plus its pid from the pidfile. The pidfile alone can lie: a crashed
    /// daemon's pid may now belong to another process, so only a listening socket counts as running.
    public static func daemonStatus(_ udid: String) -> (running: Bool, pid: Int32?) {
        guard let fd = try? UnixSocket.connect(path: StatePaths.socket(udid).path, timeout: 1) else { return (false, nil) }
        close(fd)
        let pid = (try? String(contentsOf: StatePaths.pidfile(udid), encoding: .utf8))
            .flatMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return (true, pid)
    }

    @MainActor public static func run(udidFlag: String?, live: Bool, env e: CLI.Environment) -> Output {
        var checks: [Check] = []
        let xcode = Shell.run("/usr/bin/xcrun", ["xcodebuild", "-version"], timeout: 30).out
            .split(separator: "\n").map(String.init).joined(separator: " ")
        let dir = Xcode.developerDir()
        checks.append(Check(status: xcode.isEmpty ? .fail : .ok, text: (xcode.isEmpty ? "no Xcode found" : xcode) + " at \(dir)"))
        do {
            checks.append(Check(status: .ok, text: "SimulatorKit: " + (try CHSimulator.loadFrameworks(developerDir: dir))))
        } catch {
            checks.append(Check(status: .fail, text: error.localizedDescription))
            return output(checks)
        }
        let udid: String
        do {
            let devices = try e.devices()
            udid = try Target.resolve(flag: udidFlag, env: e.env["CHAUFFEUR_UDID"], configUDID: Target.readConfig(from: e.cwd), devices: devices)
            let info = devices.first { $0.udid == udid }
            checks.append(Check(status: .ok, text: "target \(info?.summary ?? udid)"))
        } catch {
            checks.append(Check(status: .fail, text: "\(error)"))
            return output(checks)
        }
        let daemon = daemonStatus(udid)
        checks.append(Check(status: .ok, text: daemon.running ? "daemon running" + (daemon.pid.map { " (pid \($0))" } ?? "")
                            : "daemon not running (starts on the first command)"))
        do {
            let device = try Device(udid: udid)
            guard device.booted else { throw ChauffeurError.notBooted(udid) }
            let start = Date()
            let root = try AXProvider(sim: device.sim).read()
            let ms = Int(Date().timeIntervalSince(start) * 1000)
            if let root, !root.frame.isEmpty {
                let name = (root.label ?? "").trimmingCharacters(in: .whitespaces)
                checks.append(Check(status: .ok, text: "accessibility: \(name.isEmpty ? "SpringBoard" : "app \"\(name)\""), \(root.all.count) elements in \(ms)ms"))
            } else {
                let probe = (try? AXProvider(sim: device.sim))?.probe(center: Point(x: device.size.w / 2, y: device.size.h / 2))
                checks.append(Check(status: .fail, text: probe?.frontmostIsEmptyApp == true
                    ? "accessibility: the app in front has no accessibility server (it started while app accessibility was off, "
                        + "as an Xcode device session leaves it). Fix: relaunch it with chauffeur launch <bundle>"
                    : probe?.screenAnswers == true
                    ? "accessibility: the simulator's accessibility bridge is not answering (it was queried while booting). "
                        + "Fix: xcrun simctl spawn \(udid) launchctl stop com.apple.CoreSimulator.bridge (chauffeur does this itself after 4 s)"
                    : "accessibility: no tree (is the simulator still booting?)"))
            }
            if let read = try? SimCtl.run(["spawn", udid, "defaults", "read", AXSettings.domain]) {
                let off = AXSettings.off(read.out)
                checks.append(off.isEmpty ? Check(status: .ok, text: "app accessibility on")
                    : Check(status: .warn, text: "app accessibility off (\(off.joined(separator: ", "))), as an Xcode "
                        + "device session leaves it; chauffeur turns it back on, and apps opened since then need a relaunch"))
            }
            _ = try CHHIDClient(simulator: device.sim)
            checks.append(Check(status: .ok, text: "HID client ready"))
        } catch {
            checks.append(Check(status: .fail, text: "\(error)"))
            return output(checks)
        }
        checks.append(levelCheck(level: TouchLog.currentLevel(udid: udid), daemonRunning: daemon.running, udid: udid))
        if live {
            do {
                let result = try e.send(udid, ["selftest"])
                for line in result.text.split(separator: "\n").map(String.init) {
                    let status: Check.Status = line.hasPrefix("✓") ? .ok : line.hasPrefix("?") ? .warn : .fail
                    checks.append(Check(status: status, text: "live tap · " + line.drop(while: { $0 != " " }).trimmingCharacters(in: .whitespaces)))
                }
                if result.exit != 0 { checks.append(Check(status: .fail, text: "no transport delivered a touch; see `chauffeur doctor` above")) }
            } catch {
                checks.append(Check(status: .fail, text: "live self-test: \(error)"))
            }
        }
        return output(checks)
    }
}
