import Darwin
import Foundation

/// The element a command acted on, by identity rather than ref, so a later export can find it again.
public struct TraceTarget: Codable, Equatable, Sendable {
    public var ref: String?
    public var role: String
    public var name: String?
    public var id: String?

    public init(ref: String?, role: String, name: String?, id: String?) {
        self.ref = ref
        self.role = role
        self.name = name
        self.id = id
    }

    public init(_ node: Node) { self.init(ref: node.ref, role: node.role, name: node.name, id: node.identifier) }
}

/// One trace line: a command and what came of it (spec §4 Trace).
public struct TraceEntry: Codable, Equatable, Sendable {
    /// ISO 8601 with milliseconds.
    public var time: String
    public var udid: String
    /// The command as run; text typed into secure fields is replaced by `<secret: N characters>`.
    public var args: [String]
    public var exit: Int32
    public var ms: Int
    /// The first line of the output.
    public var result: String
    public var target: TraceTarget?
    /// The launched app at the time.
    public var app: String?

    public init(
        time: String, udid: String, args: [String], exit: Int32, ms: Int, result: String,
        target: TraceTarget?, app: String?
    ) {
        self.time = time
        self.udid = udid
        self.args = args
        self.exit = exit
        self.ms = ms
        self.result = result
        self.target = target
        self.app = app
    }
}

/// Append-only JSONL of every command a daemon ran, for later export as UI tests.
public enum Trace {
    public static let rotateBytes = 8 << 20

    public static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    /// Appends one line (file mode 0600). Past `rotateBytes` the file first becomes `<name>.1`. Failures are ignored:
    /// tracing never breaks a command.
    public static func append(_ entry: TraceEntry, to url: URL, rotateBytes: Int = Trace.rotateBytes) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard var line = try? encoder.encode(entry) else { return }
        line.append(0x0A)
        if let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int,
            size + line.count > rotateBytes
        {
            let old = url.appendingPathExtension("1")
            try? FileManager.default.removeItem(at: old)
            try? FileManager.default.moveItem(at: url, to: old)
        }
        let fd = open(url.path, O_WRONLY | O_CREAT | O_APPEND, 0o600)
        guard fd >= 0 else { return }
        defer { close(fd) }
        _ = line.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
    }
}
