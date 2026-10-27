import Foundation
import Security

/// Keys as generic passwords in the login keychain (spec §5, Findings 1): the PEM is the item's data, the
/// `StoredKey` JSON its comment. No data-protection keychain (an unsigned CLI gets -34018) and no access control
/// (the login keychain drops it).
public struct KeychainStore: KeyStore {
    public static let service = "chauffeur.appstoreconnect"
    public let service: String

    public init(service: String = KeychainStore.service) {
        self.service = service
    }

    public func add(_ key: StoredKey, pem: String) throws {
        if try list().contains(where: { $0.keyID == key.keyID }) {
            throw ConnectError.duplicateKey(key.keyID)
        }
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: key.keyID,
            kSecAttrComment: try key.commentJSON(),
            kSecAttrLabel: "App Store Connect key \(key.keyID) (chauffeur)",
            kSecValueData: Data(pem.utf8),
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        switch status {
        case errSecSuccess: return
        case errSecDuplicateItem: throw ConnectError.duplicateKey(key.keyID)
        default: throw ConnectError.keychain(status, "adding key \(key.keyID)")
        }
    }

    public func list() throws -> [StoredKey] {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecReturnAttributes: true,
            kSecMatchLimit: kSecMatchLimitAll,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess: break
        case errSecItemNotFound: return []
        default: throw ConnectError.keychain(status, "listing keys")
        }
        let items = result as? [[CFString: Any]] ?? []
        return
            items
            .compactMap { ($0[kSecAttrComment] as? String).flatMap(StoredKey.from(comment:)) }
            .sorted { $0.keyID < $1.keyID }
    }

    public func pem(for keyID: String) throws -> String {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: keyID,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess: break
        case errSecItemNotFound: throw ConnectError.unknownKey(keyID, known: try list().map(\.keyID))
        default: throw ConnectError.keychain(status, "reading key \(keyID)")
        }
        guard let data = result as? Data, let pem = String(data: data, encoding: .utf8) else {
            throw ConnectError.keychain(errSecDecode, "reading key \(keyID)")
        }
        return pem
    }

    public func remove(_ keyID: String) throws {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: keyID,
        ]
        let status = SecItemDelete(query as CFDictionary)
        switch status {
        case errSecSuccess: return
        case errSecItemNotFound: throw ConnectError.unknownKey(keyID, known: try list().map(\.keyID))
        default: throw ConnectError.keychain(status, "removing key \(keyID)")
        }
    }
}
