import Foundation
import LocalAuthentication

/// Where stored App Store Connect keys live. `list` reads only the records beside the keys, never a key itself.
public protocol KeyStore: Sendable {
    /// Throws `ConnectError.duplicateKey` when `key.keyID` is already stored.
    func add(_ key: StoredKey, pem: String) throws
    /// Every stored record, sorted by key id. Reads no key data.
    func list() throws -> [StoredKey]
    /// The PEM for `keyID`; throws `ConnectError.unknownKey` when it isn't stored.
    func pem(for keyID: String) throws -> String
    /// Throws `ConnectError.unknownKey` when `keyID` isn't stored.
    func remove(_ keyID: String) throws
}

/// Asks the person at the Mac to confirm before a key is read. Throws `ConnectError.presenceDenied`.
public protocol Presence: Sendable {
    func confirm(reason: String) throws
}

public enum KeyLoader {
    /// The one place presence is asked: one ask and one data read per command, and the ask comes first.
    public static func load(keyID: String, store: KeyStore, presence: Presence) throws -> (
        key: ConnectKey, stored: StoredKey
    ) {
        let all = try store.list()
        guard let stored = all.first(where: { $0.keyID == keyID }) else {
            throw ConnectError.unknownKey(keyID, known: all.map(\.keyID))
        }
        if stored.presence {
            try presence.confirm(reason: "use App Store Connect key \(keyID)")
        }
        let pem = try store.pem(for: keyID)
        let key = try ConnectKey(pem: pem, keyID: stored.keyID, issuer: stored.issuer)
        return (key, stored)
    }
}

/// Touch ID or the login password, through LocalAuthentication.
public struct LocalPresence: Presence {
    public static let timeout: TimeInterval = 60
    private static let hint = "run this at the Mac, or store the key with --no-presence"

    public init() {}

    public func confirm(reason: String) throws {
        let context = LAContext()
        var canError: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &canError) else {
            let text = canError?.localizedDescription ?? "authentication is not available"
            throw ConnectError.presenceDenied("\(text); \(Self.hint)")
        }
        let outcome = Outcome()
        let done = DispatchSemaphore(value: 0)
        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { success, error in
            outcome.set(success: success, error: error)
            done.signal()
        }
        guard done.wait(timeout: .now() + Self.timeout) == .success else {
            context.invalidate()
            throw ConnectError.presenceDenied("no answer in \(Int(Self.timeout)) s; \(Self.hint)")
        }
        let (success, error) = outcome.get()
        if success { return }
        if let laError = error as? LAError, laError.code == .userCancel {
            throw ConnectError.presenceDenied("cancelled")
        }
        let text = error?.localizedDescription ?? "not confirmed"
        throw ConnectError.presenceDenied("\(text); \(Self.hint)")
    }

    /// Carries the reply from LocalAuthentication's queue to the waiting thread.
    private final class Outcome: @unchecked Sendable {
        private let lock = NSLock()
        private var success = false
        private var error: Error?

        func set(success: Bool, error: Error?) {
            lock.lock()
            defer { lock.unlock() }
            self.success = success
            self.error = error
        }

        func get() -> (Bool, Error?) {
            lock.lock()
            defer { lock.unlock() }
            return (success, error)
        }
    }
}
