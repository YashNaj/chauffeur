import CryptoKit
import Foundation
import Testing

@testable import ChauffeurCore

enum TestKeys {
    static let issuer = "69a6de70-03db-47e3-a96a-7ee2dc5a4c3b"
    static let keyID = "7X2K9ABC1D"

    static func pem() -> String {
        P256.Signing.PrivateKey().pemRepresentation
    }

    static func key() throws -> ConnectKey {
        try ConnectKey(pem: pem(), keyID: keyID, issuer: issuer)
    }
}

/// Answers by request shape and records what it was asked. No test touches the network.
final class ScriptedTransport: ConnectTransport, @unchecked Sendable {
    private let answers: [String: ConnectResponse]
    private let lock = NSLock()
    private var seen: [ConnectRequest] = []

    init(_ answers: [String: ConnectResponse]) { self.answers = answers }

    var requests: [ConnectRequest] {
        lock.lock()
        defer { lock.unlock() }
        return seen
    }

    func perform(_ request: ConnectRequest) throws -> ConnectResponse {
        lock.lock()
        seen.append(request)
        lock.unlock()
        guard let answer = answers[request.shape] else { throw ConnectError.transport("unscripted \(request.shape)") }
        return answer
    }

    static func response(_ status: Int, _ json: String, rateLimit: String? = nil) -> ConnectResponse {
        var headers: [String: String] = [:]
        if let rateLimit { headers["X-Rate-Limit"] = rateLimit }
        return ConnectResponse(status: status, headers: headers, body: Data(json.utf8))
    }
}

extension Fixtures {
    /// A recorded App Store Connect answer (`Fixtures/connect/<name>.json`: `status`, `headers`, `body`).
    static func connect(_ name: String) throws -> ConnectResponse {
        struct Recorded: Decodable {
            var status: Int
            var headers: [String: String]?
            var body: JSON
        }
        let url = try #require(
            Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures/connect"))
        let recorded = try JSONDecoder().decode(Recorded.self, from: Data(contentsOf: url))
        let body = Data(recorded.body.line().utf8)
        return ConnectResponse(status: recorded.status, headers: recorded.headers ?? [:], body: body)
    }
}

/// Keys in a dictionary. Counts data reads so tests can prove `list` and a denied ask read nothing.
final class MemoryKeyStore: KeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var keys: [String: (stored: StoredKey, pem: String)] = [:]
    private var reads = 0

    var dataReads: Int {
        lock.lock()
        defer { lock.unlock() }
        return reads
    }

    func add(_ key: StoredKey, pem: String) throws {
        lock.lock()
        defer { lock.unlock() }
        guard keys[key.keyID] == nil else { throw ConnectError.duplicateKey(key.keyID) }
        keys[key.keyID] = (key, pem)
    }

    func list() throws -> [StoredKey] {
        lock.lock()
        defer { lock.unlock() }
        return keys.values.map(\.stored).sorted { $0.keyID < $1.keyID }
    }

    func pem(for keyID: String) throws -> String {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = keys[keyID] else { throw ConnectError.unknownKey(keyID, known: keys.keys.sorted()) }
        reads += 1
        return entry.pem
    }

    func remove(_ keyID: String) throws {
        lock.lock()
        defer { lock.unlock() }
        guard keys.removeValue(forKey: keyID) != nil else {
            throw ConnectError.unknownKey(keyID, known: keys.keys.sorted())
        }
    }
}

/// Answers every ask the same way and records the reasons it was given.
final class ScriptedPresence: Presence, @unchecked Sendable {
    private let allow: Bool
    private let lock = NSLock()
    private var reasons: [String] = []

    init(allow: Bool) { self.allow = allow }

    var asked: [String] {
        lock.lock()
        defer { lock.unlock() }
        return reasons
    }

    func confirm(reason: String) throws {
        lock.lock()
        reasons.append(reason)
        lock.unlock()
        guard allow else { throw ConnectError.presenceDenied("cancelled") }
    }
}

/// Wraps the real transport and writes each answer to `Fixtures/connect/<label>-<resource>-<status>.json`, with the
/// headers cut to `X-Rate-Limit` and `Content-Type`. A body that isn't JSON (a gzip report) is stored as `{}`. Never
/// writes the request: it carries the token.
final class RecordingTransport: ConnectTransport, @unchecked Sendable {
    private let inner: ConnectTransport
    private let label: String
    private let directory: URL
    private let lock = NSLock()
    private var paths: [URL] = []

    init(label: String, directory: URL, inner: ConnectTransport = URLSessionTransport()) {
        self.label = label
        self.directory = directory
        self.inner = inner
    }

    var written: [URL] {
        lock.lock()
        defer { lock.unlock() }
        return paths
    }

    func perform(_ request: ConnectRequest) throws -> ConnectResponse {
        let response = try inner.perform(request)
        let resource = request.url.path.split(separator: "/").dropFirst().first.map(String.init) ?? "unknown"
        var headers: [String: String] = [:]
        for name in ["X-Rate-Limit", "Content-Type"] { headers[name] = response.header(name) }
        let body = (try? JSONSerialization.jsonObject(with: response.body)) ?? [String: Any]()
        let day = ISO8601DateFormatter.string(
            from: Date(), timeZone: TimeZone(identifier: "UTC") ?? .current,
            formatOptions: [.withFullDate])
        let record: [String: Any] = [
            "status": response.status, "headers": headers, "body": body, "source": "recorded \(day)",
        ]
        let data = try JSONSerialization.data(
            withJSONObject: record, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        let url = directory.appendingPathComponent("\(label)-\(resource)-\(response.status).json")
        try (data + Data("\n".utf8)).write(to: url)
        lock.lock()
        paths.append(url)
        lock.unlock()
        return response
    }
}
