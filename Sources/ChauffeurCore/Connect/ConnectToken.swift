import CryptoKit
import Foundation

/// How long a token lives. A call's token covers one request; a session's covers a run of them.
public enum TokenLifetime: Sendable {
    case call
    case session

    public var seconds: TimeInterval {
        switch self {
        case .call: return 120
        case .session: return 1200
        }
    }
}

/// The JSON Web Token App Store Connect expects in `Authorization: Bearer`. Never printed or described.
public enum ConnectToken {
    private struct Header: Encodable {
        let alg = "ES256"
        let kid: String
        let typ = "JWT"
    }

    private struct Claims: Encodable {
        let iss: String
        let iat: Int
        let exp: Int
        let aud = "appstoreconnect-v1"
        let scope: [String]?
    }

    public static func mint(
        _ key: ConnectKey, lifetime: TokenLifetime, scope: [String]?, now: Date
    ) throws -> String {
        let issued = Int(now.timeIntervalSince1970.rounded(.down))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let header = base64url(try encoder.encode(Header(kid: key.keyID)))
        let claims = base64url(
            try encoder.encode(
                Claims(iss: key.issuer, iat: issued, exp: issued + Int(lifetime.seconds), scope: scope)))
        let signingInput = "\(header).\(claims)"
        let signature = try key.signingKey.signature(for: Data(signingInput.utf8))
        return "\(signingInput).\(base64url(signature.rawRepresentation))"
    }

    static func base64url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// Hands out one token and mints a fresh one when fewer than a minute remains.
public struct TokenSession: Sendable, CustomStringConvertible {
    private let key: ConnectKey
    private let lifetime: TokenLifetime
    private let scope: [String]?
    private var current: String?
    public private(set) var expiry: Date = .distantPast

    public init(key: ConnectKey, lifetime: TokenLifetime, scope: [String]?) {
        self.key = key
        self.lifetime = lifetime
        self.scope = scope
    }

    public mutating func token(now: Date) throws -> String {
        if let current, expiry.timeIntervalSince(now) >= 60 { return current }
        let minted = try ConnectToken.mint(key, lifetime: lifetime, scope: scope, now: now)
        current = minted
        expiry = now + lifetime.seconds
        return minted
    }

    public var description: String { "token session for \(key)" }
}
