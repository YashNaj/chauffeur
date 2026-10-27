import Foundation
import Testing

@testable import ChauffeurCore

/// Runs only with CHAUFFEUR_LIVE_KEYCHAIN set: it writes to and removes from the login keychain, under a test
/// service, a record that asks for no presence. The same binary stores and reads, so no dialog appears.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["CHAUFFEUR_LIVE_KEYCHAIN"] != nil))
struct ConnectLiveTests {
    @Test func keychainRoundTrip() throws {
        let s = KeychainStore(service: "chauffeur.appstoreconnect.test")
        let id = "TEST" + String(UUID().uuidString.prefix(6)).uppercased()
        try? s.remove(id)
        try s.add(
            StoredKey(
                keyID: id, issuer: TestKeys.issuer, role: .developer, apps: ["A (a)"], added: "2026-10-26T20:00:00Z",
                presence: false), pem: TestKeys.pem())
        defer { try? s.remove(id) }
        #expect(try s.list().contains { $0.keyID == id && $0.apps == ["A (a)"] })
        #expect(try s.pem(for: id).hasPrefix("-----BEGIN PRIVATE KEY-----"))
        try s.remove(id)
        #expect(!(try s.list().contains { $0.keyID == id }))
    }
}
