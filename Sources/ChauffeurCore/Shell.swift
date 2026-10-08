import Foundation

public struct ProcessResult: Sendable {
    public var status: Int32
    public var out: String
    public var timedOut: Bool
    /// What the process wrote to stderr (simctl puts its error explanations there).
    public var err: String = ""
}

private final class Box<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}

public enum Shell {
    /// Runs a process, capturing stdout and stderr. Kills it after `timeout` seconds (decision 9: never hang).
    public static func run(_ path: String, _ args: [String], stdin: String? = nil, timeout: Double = 30) -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        let input = Pipe()
        process.standardInput = stdin == nil ? FileHandle.nullDevice : input
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do { try process.run() } catch {
            return ProcessResult(status: -1, out: "", timedOut: false, err: "cannot run \(path): \(error)")
        }
        // Readers start only once the process exists: if it cannot start, no thread is left blocked on a pipe.
        let outData = Box(Data()), errData = Box(Data())
        let reads = DispatchGroup()
        for (handle, box) in [(out.fileHandleForReading, outData), (err.fileHandleForReading, errData)] {
            reads.enter()
            DispatchQueue.global().async {
                box.value = handle.readDataToEndOfFile()
                reads.leave()
            }
        }
        if let stdin {
            input.fileHandleForWriting.write(Data(stdin.utf8))
            try? input.fileHandleForWriting.close()
        }
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            if exited.wait(timeout: .now() + 1) == .timedOut { kill(process.processIdentifier, SIGKILL) }
            return ProcessResult(status: -1, out: "", timedOut: true)
        }
        _ = reads.wait(timeout: .now() + 2)
        return ProcessResult(status: process.terminationStatus, out: String(decoding: outData.value, as: UTF8.self),
                             timedOut: false, err: String(decoding: errData.value, as: UTF8.self))
    }
}

public enum Xcode {
    public static func developerDir() -> String {
        Shell.run("/usr/bin/xcode-select", ["-p"], timeout: 10).out.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public struct DeviceInfo: Equatable, Sendable {
    public var udid: String
    public var name: String
    public var runtime: String
    public var state: String

    public init(udid: String, name: String, runtime: String, state: String) {
        self.udid = udid; self.name = name; self.runtime = runtime; self.state = state
    }

    public var booted: Bool { state == "Booted" }
    public var summary: String { "\(name) (\(runtime)) \(udid) \(state)" }
}

public enum SimCtl {
    /// The useful part of a failed call: simctl's explanation without its generic first line and repeats.
    public static func message(_ r: ProcessResult) -> String {
        var lines: [String] = []
        for raw in r.err.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("An error was encountered processing the command")
                || line.hasPrefix("Underlying error") || lines.contains(line) { continue }
            lines.append(line)
        }
        guard !lines.isEmpty else { return "simctl exited \(r.status)" }
        return Perception.escape(lines.prefix(2).joined(separator: " · "), limit: 300)
    }

    @discardableResult
    public static func run(_ args: [String], stdin: String? = nil, timeout: Double = 30) throws -> ProcessResult {
        let r = Shell.run("/usr/bin/xcrun", ["simctl"] + args, stdin: stdin, timeout: timeout)
        if r.timedOut { throw ChauffeurError.simulatorServiceUnresponsive(command: "simctl " + args.prefix(2).joined(separator: " ")) }
        return r
    }

    public static func devices() throws -> [DeviceInfo] {
        try parseDevices(Data(run(["list", "devices", "-j"]).out.utf8))
    }

    public static func parseDevices(_ json: Data) throws -> [DeviceInfo] {
        struct Listing: Decodable {
            struct Device: Decodable { var udid: String; var name: String; var state: String; var isAvailable: Bool? }
            var devices: [String: [Device]]
        }
        let listing = try JSONDecoder().decode(Listing.self, from: json)
        return listing.devices.keys.sorted().flatMap { key in
            listing.devices[key, default: []].filter { $0.isAvailable ?? true }.map {
                DeviceInfo(udid: $0.udid, name: $0.name, runtime: runtimeName(key), state: $0.state)
            }
        }
    }

    /// `com.apple.CoreSimulator.SimRuntime.iOS-26-2` → `iOS 26.2`.
    static func runtimeName(_ key: String) -> String {
        let parts = (key.split(separator: ".").last.map(String.init) ?? key).split(separator: "-").map(String.init)
        guard let platform = parts.first, parts.count > 1 else { return key }
        return platform + " " + parts.dropFirst().joined(separator: ".")
    }
}
