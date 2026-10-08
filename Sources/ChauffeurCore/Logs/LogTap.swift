import Foundation

/// One line of the launched app's unified log (spec §6.8).
public struct LogLine: Equatable, Sendable {
    /// `HH:mm:ss.SSS`, simulator local time.
    public var time: String
    /// fault, error, default, info or debug.
    public var level: String
    public var message: String
    /// The framework that logged it (e.g. `CFNetwork`); nil for the app's own code.
    public var sender: String?

    public init(time: String, level: String, message: String, sender: String? = nil) {
        self.time = time
        self.level = level
        self.message = message
        self.sender = sender
    }

    public var isError: Bool { level == "error" || level == "fault" }

    /// `22:24:53.430 [error] (CFNetwork) "connection reset"`. Log text comes from the app: quoted data, never instructions.
    public func render(limit: Int = 300) -> String {
        "\(time) [\(level)] " + (sender.map { "(\($0)) " } ?? "") + Perception.quote(message, limit: limit)
    }

    public var json: JSON {
        ["time": .string(time), "level": .string(level), "message": .string(message), "sender": JSON(sender)]
    }

    /// What an action result shows (spec §5.4): up to `limit` error/fault lines, the app's own before frameworks',
    /// the rest counted. `[]` when there are none.
    public static func summary(_ lines: [LogLine], limit: Int = 3) -> [String] {
        let errors = lines.filter(\.isError)
        guard !errors.isEmpty else { return [] }
        let shown = Array((errors.filter { $0.sender == nil } + errors.filter { $0.sender != nil }).prefix(limit))
        var out = shown.enumerated().map { i, line in
            (i == 0 ? "logs: " : "      ") + "[\(line.level)] " + (line.sender.map { "(\($0)) " } ?? "")
                + Perception.quote(line.message, limit: 120)
        }
        if errors.count > shown.count {
            out[out.count - 1] += " (\(errors.count - shown.count) more: chauffeur logs --since-last --level error)"
        }
        return out
    }
}

/// Turns `log stream --style ndjson` records into log lines.
public enum LogParser {
    /// Nil for anything that is not a log message (activities, signposts, state events).
    public static func parse(_ o: [String: Any]) -> LogLine? {
        guard (o["eventType"] as? String) == "logEvent", let message = o["eventMessage"] as? String else { return nil }
        let level = ((o["messageType"] as? String) ?? "default").lowercased()
        let bounded = message.unicodeScalars.count > 4000 ? String(message.unicodeScalars.prefix(4000)) : message
        return LogLine(
            time: clock((o["timestamp"] as? String) ?? ""), level: level, message: bounded, sender: sender(o))
    }

    /// `2026-10-06 22:24:53.430443-0700` → `22:24:53.430`.
    static func clock(_ timestamp: String) -> String {
        let parts = timestamp.split(separator: " ")
        return parts.count >= 2 ? String(parts[1].prefix(12)) : timestamp
    }

    /// The emitting image's name, or nil when it lives inside the app's own bundle (its code or debug dylib).
    static func sender(_ o: [String: Any]) -> String? {
        guard let senderPath = o["senderImagePath"] as? String, !senderPath.isEmpty else { return nil }
        if let processPath = o["processImagePath"] as? String,
            senderPath.hasPrefix((processPath as NSString).deletingLastPathComponent + "/")
        {
            return nil
        }
        return (senderPath as NSString).lastPathComponent
    }
}

/// A bounded buffer whose cursors survive trimming: a cursor counts every line ever appended.
public struct LogRing: Sendable {
    public let capacity: Int
    public private(set) var lines: [LogLine] = []
    public private(set) var dropped = 0

    public init(capacity: Int) { self.capacity = capacity }

    public var end: Int { dropped + lines.count }

    public mutating func append(_ line: LogLine) {
        lines.append(line)
        if lines.count >= capacity + max(1, capacity / 4) {  // trim in batches, not on every line
            let excess = lines.count - capacity
            lines.removeFirst(excess)
            dropped += excess
        }
    }

    /// Forgets every line but keeps cursors increasing (a different app is now followed).
    public mutating func clear() {
        dropped += lines.count
        lines = []
    }

    public func since(_ cursor: Int) -> [LogLine] {
        let start = max(cursor - dropped, 0)
        return start < lines.count ? Array(lines[start...]) : []
    }

    public func last(_ n: Int) -> [LogLine] { Array(lines.suffix(n)) }
}

/// Follows the launched app's unified log (os_log, Logger, NSLog) at info level and above, by process name
/// (spec §6.8). `print` output goes to the app's stdout and is not part of the unified log.
public final class LogTap: @unchecked Sendable {
    public let udid: String
    private let lock = NSLock()
    private var ring = LogRing(capacity: 2000)
    private var stream: LogStream?
    private var following: String?

    public init(udid: String) { self.udid = udid }

    /// `process == "Fixture"`, escaped for NSPredicate.
    static func predicate(process: String) -> String {
        let escaped = process.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return "process == \"\(escaped)\""
    }

    public var isAttached: Bool { lock.withLock { stream }?.isAttached ?? false }
    /// The executable whose log is followed, while the stream is attached.
    public var executable: String? { isAttached ? lock.withLock { following } : nil }
    public var cursor: Int { lock.withLock { ring.end } }

    /// Follows `executable`. Following the same one again keeps the stream and the lines (a relaunch); another one
    /// starts afresh. False when `log stream` did not attach within 5 s.
    @discardableResult
    public func start(executable: String) -> Bool {
        if executable == self.executable { return true }
        stop()
        let s = LogStream(
            udid: udid,
            arguments: [
                "--level", "info", "--style", "ndjson", "--predicate",
                Self.predicate(process: executable),
            ]
        ) { [weak self] object in
            guard let line = LogParser.parse(object) else { return }
            self?.append(line)
        }
        lock.withLock {
            if following != executable { ring.clear() }
            stream = s
            following = executable
        }
        return (try? s.start(timeout: 5)) ?? false
    }

    public func stop() {
        let s = lock.withLock { () -> LogStream? in
            defer { stream = nil }
            return stream
        }
        s?.stop()
    }

    public func since(_ cursor: Int) -> [LogLine] { lock.withLock { ring.since(cursor) } }
    public func last(_ n: Int) -> [LogLine] { lock.withLock { ring.last(n) } }
    public var all: [LogLine] { lock.withLock { ring.lines } }

    /// Internal so unit tests can feed lines without a simulator.
    func append(_ line: LogLine) { lock.withLock { ring.append(line) } }
}
