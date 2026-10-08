import Darwin
import Foundation

/// Process liveness from the host: simulator apps are ordinary macOS processes.
public enum Proc {
    /// True while `pid` exists and is not a zombie (`kill(pid, 0)` alone also succeeds on zombies).
    public static func isAlive(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return false }
        return info.kp_proc.p_stat != SZOMB
    }
}

/// The app chauffeur launched and follows: its logs, its crashes, and the Verifier's expected app (spec §6.2, §6.8).
public struct TrackedApp: Codable, Equatable, Sendable {
    public var bundle: String
    public var executable: String
    /// The app's accessibility root label (its display name): how a snapshot shows it is in front.
    public var displayName: String
    public var pid: Int32
    public var launchedAt: Date

    public init(bundle: String, executable: String, displayName: String, pid: Int32, launchedAt: Date) {
        self.bundle = bundle; self.executable = executable; self.displayName = displayName
        self.pid = pid; self.launchedAt = launchedAt
    }

    /// Saved beside the socket, so a restarted daemon (upgrade, idle exit) keeps following the app.
    public static func load(_ url: URL) -> TrackedApp? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(TrackedApp.self, from: data)
    }

    public func save(_ url: URL) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        try? data.write(to: url, options: .atomic)
    }

    public static func clear(_ url: URL) { try? FileManager.default.removeItem(at: url) }
}

/// A crash report (`.ips`: one JSON header line, then a JSON body) reduced to what an agent needs.
public struct CrashReport: Equatable, Sendable {
    public var path: String
    public var bundle: String
    public var pid: Int32?
    public var procPath: String
    /// `EXC_BREAKPOINT (SIGTRAP)`, or the termination indicator.
    public var exception: String?
    /// The first application-specific message (`asi`), e.g. a Swift fatal error, when the report has one.
    public var reason: String?
    /// The crashed thread, top first: `libswiftCore.dylib _assertionFailure(…) + 156`.
    public var frames: [String]

    static func header(_ data: Data) -> [String: Any]? {
        guard let nl = data.firstIndex(of: 0x0A) else { return nil }
        return try? JSONSerialization.jsonObject(with: data[data.startIndex..<nl]) as? [String: Any]
    }

    public static func parse(_ data: Data, path: String) -> CrashReport? {
        guard let nl = data.firstIndex(of: 0x0A), let header = header(data),
              let body = try? JSONSerialization.jsonObject(with: data[(nl + 1)...]) as? [String: Any],
              body["threads"] != nil else { return nil }
        let info = body["bundleInfo"] as? [String: Any]
        let exception = body["exception"] as? [String: Any]
        let kind = [exception?["type"] as? String, (exception?["signal"] as? String).map { "(\($0))" }]
            .compactMap { $0 }.joined(separator: " ")
        let termination = (body["termination"] as? [String: Any])?["indicator"] as? String
        return CrashReport(
            path: path,
            bundle: (header["bundleID"] as? String) ?? (info?["CFBundleIdentifier"] as? String) ?? "",
            pid: (body["pid"] as? Int).map { Int32($0) },
            procPath: (body["procPath"] as? String) ?? "",
            exception: kind.isEmpty ? termination : kind,
            reason: reason(body),
            frames: frames(body))
    }

    static func reason(_ body: [String: Any]) -> String? {
        guard let asi = body["asi"] as? [String: Any] else { return nil }
        for key in asi.keys.sorted() {
            if let first = (asi[key] as? [String])?.first { return first }
        }
        return nil
    }

    static func frames(_ body: [String: Any], limit: Int = 8) -> [String] {
        guard let threads = body["threads"] as? [[String: Any]], !threads.isEmpty else { return [] }
        let faulting = (body["faultingThread"] as? Int).flatMap { threads.indices.contains($0) ? $0 : nil }
        let index = faulting ?? threads.firstIndex { ($0["triggered"] as? Bool) == true } ?? 0
        let images = (body["usedImages"] as? [[String: Any]]) ?? []
        let frames = (threads[index]["frames"] as? [[String: Any]]) ?? []
        return frames.prefix(limit).map { f in
            let i = (f["imageIndex"] as? Int) ?? -1
            let image = images.indices.contains(i) ? ((images[i]["name"] as? String) ?? "???") : "???"
            let symbol = (f["symbol"] as? String) ?? "0x" + String((f["imageOffset"] as? Int) ?? 0, radix: 16)
            let location = (f["symbolLocation"] as? Int).map { " + \($0)" } ?? ""
            return Perception.escape("\(image) \(symbol)\(location)", limit: 160)
        }
    }
}

/// Finds the report macOS writes for a crashed simulator app. On the 8 GB test Mac reports appeared 17–70 s after
/// the crash, so callers look more than once.
public enum CrashFinder {
    public static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/DiagnosticReports", isDirectory: true)
    }

    /// The newest `.ips` modified since `since` for `bundle`, with this pid, from simulator `udid`.
    public static func find(bundle: String, pid: Int32, udid: String, since: Date, in dir: URL = directory) -> CrashReport? {
        let key = URLResourceKey.contentModificationDateKey
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [key]) else { return nil }
        let recent = files.compactMap { url -> (URL, Date)? in
            guard url.pathExtension == "ips",
                  let date = try? url.resourceValues(forKeys: [key]).contentModificationDate,
                  date >= since.addingTimeInterval(-5) else { return nil }
            return (url, date)
        }.sorted { $0.1 > $1.1 }
        for (url, _) in recent {
            guard let data = try? Data(contentsOf: url), CrashReport.header(data)?["bundleID"] as? String == bundle,
                  let report = CrashReport.parse(data, path: url.path), report.pid == pid,
                  report.procPath.range(of: "/Devices/\(udid)/", options: .caseInsensitive) != nil else { continue }
            return report
        }
        return nil
    }
}

/// The launched app's process disappeared without chauffeur stopping it (spec §6.8).
public struct CrashInfo: Equatable, Sendable {
    public var app: TrackedApp
    public var detectedAt: Date
    public var report: CrashReport?
    /// The log line that says the process died on its own, while the report is not written yet.
    public var fatalLine: String?

    public init(app: TrackedApp, detectedAt: Date, report: CrashReport?) {
        self.app = app; self.detectedAt = detectedAt; self.report = report
    }

    /// The line that says the process died on its own: Swift's `Fatal error`, else the last fault the app's own code
    /// logged (frameworks log faults routinely).
    public static func fatalLine(in lines: [LogLine]) -> String? {
        lines.last { $0.message.contains("Fatal error") }?.message ?? lines.last { $0.level == "fault" && $0.sender == nil }?.message
    }

    /// The `APP CRASHED` block. Frames are code identifiers, escaped but not quoted.
    public func render(frames limit: Int = 3) -> [String] {
        guard let report else {
            guard let fatalLine else {
                return ["APP EXITED: \(app.bundle) (pid \(app.pid)) is gone · no crash report or fatal log line "
                        + "(ended from outside chauffeur?); if it crashed, chauffeur logs shows the report when macOS writes it"]
            }
            return ["APP CRASHED: \(app.bundle) (pid \(app.pid)) · crash report not written yet (macOS can take a minute)",
                    "reason: " + Perception.quote(fatalLine, limit: 160)]
        }
        var lines = ["APP CRASHED: \(app.bundle) (pid \(app.pid))" + (report.exception.map { " · \($0)" } ?? "")]
        if let reason = report.reason { lines.append("reason: " + Perception.quote(reason, limit: 160)) }
        lines.append("report: \(report.path)")
        lines += report.frames.prefix(limit).map { "  " + $0 }
        return lines
    }

    public var json: JSON {
        ["bundle": .string(app.bundle), "pid": JSON(Int(app.pid)), "report": JSON(report?.path),
         "exception": JSON(report?.exception), "reason": JSON(report?.reason), "frames": JSON(report?.frames ?? [])]
    }
}

/// When the simulator's current boot started: the start time of its `launchd_sim` process. A simulator that was shut
/// down or rebooted since an app launched explains that app's disappearance (not a crash).
public enum SimBoot {
    /// `ps -ww -axo lstart=,command=` output → the start of `launchd_sim` for `udid`.
    static func parse(_ ps: String, udid: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        for line in ps.split(separator: "\n") where line.count > 25 {
            let start = String(line.prefix(24)).split(separator: " ").joined(separator: " ")
            let command = line.dropFirst(24).drop { $0 == " " }
            guard command.hasPrefix("launchd_sim "), command.range(of: "/Devices/\(udid)/", options: .caseInsensitive) != nil else { continue }
            return formatter.date(from: start)
        }
        return nil
    }

    /// Nil when it cannot be told (no launchd_sim: the simulator is not booted).
    static func date(udid: String) -> Date? {
        parse(Shell.run("/bin/ps", ["-ww", "-axo", "lstart=,command="], timeout: 10).out, udid: udid)
    }

    /// Whether simctl lists the simulator as booted; nil when simctl could not be asked.
    static func booted(udid: String) -> Bool? {
        guard let devices = try? SimCtl.devices() else { return nil }
        return devices.first { $0.udid.caseInsensitiveCompare(udid) == .orderedSame }?.booted
    }
}
