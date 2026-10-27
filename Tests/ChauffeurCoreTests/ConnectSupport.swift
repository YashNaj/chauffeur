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
            var body: JSONValue
        }
        let url = try #require(
            Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures/connect"))
        let recorded = try JSONDecoder().decode(Recorded.self, from: Data(contentsOf: url))
        let body = try JSONEncoder().encode(recorded.body)
        return ConnectResponse(status: recorded.status, headers: recorded.headers ?? [:], body: body)
    }
}

/// Any JSON value, so a fixture's `body` can be re-encoded as bytes.
enum JSONValue: Codable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .null
        } else if let v = try? c.decode(Bool.self) {
            self = .bool(v)
        } else if let v = try? c.decode(Double.self) {
            self = .number(v)
        } else if let v = try? c.decode(String.self) {
            self = .string(v)
        } else if let v = try? c.decode([JSONValue].self) {
            self = .array(v)
        } else {
            self = .object(try c.decode([String: JSONValue].self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }
}
