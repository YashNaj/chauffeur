import Foundation
import Security

/// What the running binary's code signature says about it. A key is only read or written by a build with the
/// hardened runtime and without `get-task-allow`: otherwise an injected library runs under the build's keychain
/// identity and skips the presence check.
public protocol BuildIdentity: Sendable {
    var hardenedRuntime: Bool { get }
    var debuggable: Bool { get }
}

/// The running process's own signature, read with the public Security framework. Anything that can't be read
/// counts as unhardened and debuggable.
public struct LiveBuildIdentity: BuildIdentity {
    public let hardenedRuntime: Bool
    public let debuggable: Bool

    public init() {
        self.init(signingInformation: Self.ownSigningInformation())
    }

    /// Reads the flags and entitlements out of `SecCodeCopySigningInformation`'s dictionary; `nil` fails closed.
    public init(signingInformation info: [String: Any]?) {
        guard let info, let flags = info[kSecCodeInfoFlags as String] as? UInt32 else {
            hardenedRuntime = false
            debuggable = true
            return
        }
        hardenedRuntime = flags & SecCodeSignatureFlags.runtime.rawValue != 0
        debuggable = Self.getTaskAllow(info)
    }

    private static func getTaskAllow(_ info: [String: Any]) -> Bool {
        let entitlements = info[kSecCodeInfoEntitlementsDict as String] as? [String: Any]
        return entitlements?["com.apple.security.get-task-allow"] as? Bool == true
    }

    private static func ownSigningInformation() -> [String: Any]? {
        var code: SecCode?
        guard SecCodeCopySelf(SecCSFlags(), &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, SecCSFlags(), &staticCode) == errSecSuccess, let staticCode else {
            return nil
        }
        var info: CFDictionary?
        let status = SecCodeCopySigningInformation(
            staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info)
        guard status == errSecSuccess else { return nil }
        return info as? [String: Any]
    }
}
