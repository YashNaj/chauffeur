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

/// Records the probes' answers from a real key, for the owner, by hand: GET requests only, and no keychain (the key
/// is read from the file and never stored). Needs CHAUFFEUR_RECORD_PROBES=<label>, CHAUFFEUR_LIVE_P8 (a path),
/// CHAUFFEUR_LIVE_ISSUER and CHAUFFEUR_LIVE_KEY_ID. Writes under Fixtures/connect; rename the files before use.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["CHAUFFEUR_RECORD_PROBES"] != nil))
struct ConnectRecordingTests {
    @Test func recordProbes() throws {
        let env = ProcessInfo.processInfo.environment
        let label = try #require(env["CHAUFFEUR_RECORD_PROBES"])
        let path = try #require(env["CHAUFFEUR_LIVE_P8"])
        let key = try ConnectKey(
            pem: try String(contentsOfFile: path, encoding: .utf8), keyID: try #require(env["CHAUFFEUR_LIVE_KEY_ID"]),
            issuer: try #require(env["CHAUFFEUR_LIVE_ISSUER"]))
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/connect")
        let transport = RecordingTransport(label: label, directory: directory)
        let client = ConnectClient(key: key, role: .appManager, transport: transport)
        let verdict = try Probe.run(client, now: Date())
        #expect(!transport.written.isEmpty, "\(verdict)")
    }
}
