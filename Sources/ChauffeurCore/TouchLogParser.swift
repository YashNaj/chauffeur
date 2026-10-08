import Foundation

public struct TouchRecord: Equatable, Sendable {
    public var context: String
    public var point: Point
    public init(context: String, point: Point) { self.context = context; self.point = point }
}

public enum ContextOwner: Equatable, Sendable {
    case scene(String)
    case touchStream
}

/// Turns backboardd TouchEvents messages into touch records and owners (S3).
public struct TouchLogParser: Sendable {
    public private(set) var owners: [String: ContextOwner] = [:]

    public init() {}

    public mutating func consume(_ message: String) -> TouchRecord? {
        for m in message.matches(of: /contextID: 0x([0-9A-Fa-f]+);[^,]*?sceneID:([^ >;]+)/) {
            owners[String(m.1).uppercased()] = .scene(String(m.2))
        }
        for m in message.matches(of: /\(touchStream[^)]*\); contextID: 0x([0-9A-Fa-f]+)/) {
            owners[String(m.1).uppercased()] = .touchStream
        }
        guard let m = message.firstMatch(of: /Digitizer token: 0x([0-9A-Fa-f]+);.*?subevents: \[path: \d+; \{([\d.]+), ([\d.]+)\}/),
              let x = Double(m.2), let y = Double(m.3) else { return nil }
        return TouchRecord(context: String(m.1).uppercased(), point: Point(x: x, y: y))
    }

    /// A scene-owned context means an app got the touch; an unknown context means SpringBoard.
    public func evidence(_ records: [TouchRecord]) -> Evidence {
        var sawUnowned = false
        for r in records {
            switch owners[r.context] {
            case .scene(let scene)?: return .app(Self.bundle(fromScene: scene))
            case .touchStream?: continue
            case nil: sawUnowned = true
            }
        }
        return sawUnowned ? .system : .none
    }

    public static func bundle(fromScene scene: String) -> String {
        scene.hasSuffix("-default") ? String(scene.dropLast("-default".count)) : scene
    }
}

public enum BackBoardLevel {
    public static let subsystem = "com.apple.BackBoard"

    /// `Mode for 'com.apple.BackBoard'  INFO PERSIST_DEFAULT` → `info`.
    public static func parse(_ status: String) -> String? {
        let words = status.split(whereSeparator: \.isWhitespace)
        guard let i = words.firstIndex(where: { $0.hasPrefix("PERSIST") }), i > 0 else { return nil }
        return words[i - 1].lowercased()
    }
}

/// The level to restore when the daemon exits. `log config --reset` restores the factory level, not the
/// previous one (S3), so the prior level is saved to a file that outlives a crashed daemon.
public enum PriorLevel {
    public static func choose(saved: String?, current: String) -> String {
        if let saved { return saved }
        return current == "debug" ? "default" : current
    }

    public static func load(_ url: URL) -> String? {
        (try? String(contentsOf: url, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func save(_ level: String, to url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? level.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Clear the saved level only once the restore demonstrably worked (I4).
    public static func restored(status: Int32, levelAfter: String?, prior: String) -> Bool {
        status == 0 && levelAfter == prior
    }

    public static func clear(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}
