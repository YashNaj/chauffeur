import CryptoKit
import Foundation

/// What an App Store Connect API key is allowed to do. Chosen when the key is created in App Store Connect.
public enum ConnectRole: String, Codable, Sendable, CaseIterable {
    case developer
    case appManager = "app-manager"

    public var title: String {
        switch self {
        case .developer: return "Developer"
        case .appManager: return "App Manager"
        }
    }

    public init?(flag: String) {
        self.init(rawValue: flag)
    }
}

/// The JSON stored beside the key in the keychain (in the item's comment). It never holds the key itself.
public struct StoredKey: Codable, Equatable, Sendable {
    public var keyID: String
    public var issuer: String
    public var role: ConnectRole
    /// Entries read `Name (bundle.id)`.
    public var apps: [String]
    public var added: String
    public var presence: Bool

    public init(keyID: String, issuer: String, role: ConnectRole, apps: [String], added: String, presence: Bool) {
        self.keyID = keyID
        self.issuer = issuer
        self.role = role
        self.apps = apps
        self.added = added
        self.presence = presence
    }

    public func commentJSON() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }

    public static func from(comment: String) -> StoredKey? {
        try? JSONDecoder().decode(StoredKey.self, from: Data(comment.utf8))
    }
}

/// A parsed P-256 API key. Its description is the key id only; the key material is never printed.
public struct ConnectKey: Sendable, CustomStringConvertible {
    public let keyID: String
    public let issuer: String
    let signingKey: P256.Signing.PrivateKey

    public init(pem: String, keyID: String, issuer: String) throws {
        let idCharacters = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        guard keyID.count == 10, keyID.allSatisfy({ idCharacters.contains($0) }) else {
            throw ConnectError.badKeyFile("\(keyID) is not a key id (10 letters and digits, as in AuthKey_<id>.p8)")
        }
        guard UUID(uuidString: issuer) != nil else {
            throw ConnectError.badKeyFile(
                "\(issuer) is not an issuer id (a UUID from Users and Access ▸ Integrations)")
        }
        guard let key = try? P256.Signing.PrivateKey(pemRepresentation: pem) else {
            throw ConnectError.badKeyFile(
                "the file is not a PEM private key (expected -----BEGIN PRIVATE KEY-----; "
                    + "download AuthKey_<id>.p8 from App Store Connect)")
        }
        self.keyID = keyID
        self.issuer = issuer
        self.signingKey = key
    }

    public var description: String { "key \(keyID)" }
}
