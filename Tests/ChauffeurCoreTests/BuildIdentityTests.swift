import Foundation
import Security
import Testing

@testable import ChauffeurCore

@Suite struct BuildIdentityTests {
    let runtime = SecCodeSignatureFlags.runtime.rawValue
    let flagsKey = kSecCodeInfoFlags as String
    let entitlementsKey = kSecCodeInfoEntitlementsDict as String

    @Test func aHardenedBuildWithoutGetTaskAllowMayHoldAKey() {
        let identity = LiveBuildIdentity(signingInformation: [flagsKey: runtime | 0x2, entitlementsKey: [:]])
        #expect(identity.hardenedRuntime && !identity.debuggable)
        let bare = LiveBuildIdentity(signingInformation: [flagsKey: runtime])
        #expect(bare.hardenedRuntime && !bare.debuggable)
    }

    @Test func aLinkerSignedAdHocBuildIsNotHardened() {
        // What Step 0 saw on the release build: flags=0x20002(adhoc,linker-signed).
        let identity = LiveBuildIdentity(signingInformation: [flagsKey: UInt32(0x20002)])
        #expect(!identity.hardenedRuntime && !identity.debuggable)
    }

    @Test func getTaskAllowMakesABuildDebuggable() {
        let identity = LiveBuildIdentity(signingInformation: [
            flagsKey: runtime, entitlementsKey: ["com.apple.security.get-task-allow": true],
        ])
        #expect(identity.hardenedRuntime && identity.debuggable)
        let off = LiveBuildIdentity(signingInformation: [
            flagsKey: runtime, entitlementsKey: ["com.apple.security.get-task-allow": false],
        ])
        #expect(!off.debuggable)
    }

    @Test func anUnreadableSignatureFailsClosed() {
        let none = LiveBuildIdentity(signingInformation: nil)
        #expect(!none.hardenedRuntime && none.debuggable)
        let wrongType = LiveBuildIdentity(signingInformation: [flagsKey: "runtime"])
        #expect(!wrongType.hardenedRuntime && wrongType.debuggable)
    }

    @Test func theLiveReadDoesNotThrowOrCrash() {
        // The test host isn't chauffeur, so only the shape is checked here; scripts/sign.sh checks the real binary.
        let identity = LiveBuildIdentity()
        _ = identity.hardenedRuntime && identity.debuggable
    }
}
