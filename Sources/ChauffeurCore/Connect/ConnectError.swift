import Foundation
import Security

/// One entry of Apple's `{"errors":[…]}` body. Every field is untrusted text.
public struct AppleError: Equatable, Sendable {
    public var status: String
    public var code: String
    public var title: String
    public var detail: String?

    public init(status: String, code: String, title: String, detail: String? = nil) {
        self.status = status
        self.code = code
        self.title = title
        self.detail = detail
    }

    /// The errors in `body`; `[]` when it is not Apple's error shape.
    public static func parse(_ body: Data) -> [AppleError] {
        struct Envelope: Decodable {
            struct Entry: Decodable {
                var status: String?
                var code: String?
                var title: String?
                var detail: String?
            }
            var errors: [Entry]
        }
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: body) else { return [] }
        return envelope.errors.map {
            AppleError(status: $0.status ?? "", code: $0.code ?? "", title: $0.title ?? "", detail: $0.detail)
        }
    }
}

public enum ConnectError: Error, Equatable, CustomStringConvertible {
    case badKeyFile(String)
    case unauthorized
    case forbidden(shape: String, needs: ConnectRole, have: ConnectRole)
    case rateLimited(remaining: Int)
    case conflict(shape: String, errors: [AppleError])
    case apple(status: Int, shape: String, errors: [AppleError])
    case transport(String)
    case unexpectedBody(shape: String)
    case noKey(known: [String])
    case unknownKey(String, known: [String])
    case duplicateKey(String)
    case presenceDenied(String)
    case keychain(OSStatus, String)
    case unhardenedBuild

    private static func esc(_ s: String) -> String { Perception.escape(s, limit: 200) }

    public var description: String {
        switch self {
        case .badKeyFile(let text):
            return text
        case .unauthorized:
            return "App Store Connect rejected the key: check --issuer and --key-id, and that the key is not revoked"
        case .forbidden(let shape, let needs, let have):
            return
                "App Store Connect refused \(shape) (403): it needs the \(needs.title) role and this key is \(have.title)"
        case .rateLimited(let remaining):
            return "rate limited by App Store Connect: \(remaining) requests left this hour; try again later"
        case .conflict(let shape, let errors):
            let lines = errors.map { Self.esc($0.detail ?? $0.title) }
            return "App Store Connect refused \(shape) (409): " + lines.joined(separator: "\n")
        case .apple(let status, let shape, let errors):
            var text = "App Store Connect answered \(status) to \(shape)"
            if let first = errors.first {
                text += ": \(Self.esc(first.code)) \(Self.esc(first.title))"
                if let detail = first.detail { text += ": \(Self.esc(detail))" }
            }
            return text
        case .transport(let text):
            return "could not reach App Store Connect: \(text)"
        case .unexpectedBody(let shape):
            return "App Store Connect answered \(shape) with a body chauffeur can't read"
        case .noKey(let known):
            if known.isEmpty {
                return
                    "no App Store Connect key: chauffeur keys add <AuthKey.p8> --issuer <uuid> --key-id <id> --role app-manager"
            }
            return "several keys stored (\(known.joined(separator: ", "))): pin one with chauffeur keys use <id>"
        case .unknownKey(let id, let known):
            return "no stored key \(id); stored: \(known.isEmpty ? "none" : known.joined(separator: ", "))"
        case .duplicateKey(let id):
            return "key \(id) is already stored; run chauffeur keys remove \(id) first"
        case .presenceDenied(let reason):
            return "not confirmed: \(reason). Nothing was read"
        case .keychain(let status, let what):
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "unknown error"
            return "keychain: \(message) (\(status)) while \(what)"
        case .unhardenedBuild:
            return
                "this build can't hold an App Store Connect key: it isn't hardened. Build and sign a release: "
                + "swift build -c release && scripts/sign.sh"
        }
    }
}
