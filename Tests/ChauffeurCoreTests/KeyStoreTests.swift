import Foundation
import Testing

@testable import ChauffeurCore

@Suite struct KeyStoreTests {
    func stored(_ id: String, presence: Bool = true) -> StoredKey {
        StoredKey(
            keyID: id, issuer: TestKeys.issuer, role: .appManager, apps: [], added: "2026-10-26T20:00:00Z",
            presence: presence)
    }

    @Test func memoryStoreBehavesLikeTheProtocolSays() throws {
        let s = MemoryKeyStore()
        try s.add(stored("B"), pem: TestKeys.pem())
        try s.add(stored("A"), pem: TestKeys.pem())
        #expect(try s.list().map(\.keyID) == ["A", "B"] && s.dataReads == 0)
        #expect(throws: ConnectError.duplicateKey("A")) { try s.add(stored("A"), pem: "x") }
        #expect(throws: ConnectError.unknownKey("Z", known: ["A", "B"])) { try s.pem(for: "Z") }
        try s.remove("A")
        #expect(try s.list().map(\.keyID) == ["B"])
    }

    // The loader builds a ConnectKey, which needs a real 10-character key id, so these use TestKeys.keyID.
    @Test func loadAsksForPresenceThenReads() throws {
        let id = TestKeys.keyID
        let s = MemoryKeyStore()
        try s.add(stored(id), pem: TestKeys.pem())
        let p = ScriptedPresence(allow: true)
        let loaded = try KeyLoader.load(keyID: id, store: s, presence: p)
        #expect(loaded.key.keyID == id && p.asked == ["use App Store Connect key \(id)"] && s.dataReads == 1)
    }

    @Test func presenceDeniedReadsNothing() throws {
        let id = TestKeys.keyID
        let s = MemoryKeyStore()
        try s.add(stored(id), pem: TestKeys.pem())
        #expect(throws: ConnectError.presenceDenied("cancelled")) {
            try KeyLoader.load(keyID: id, store: s, presence: ScriptedPresence(allow: false))
        }
        #expect(s.dataReads == 0)
    }

    @Test func noPresenceKeysSkipTheAsk() throws {
        let id = TestKeys.keyID
        let s = MemoryKeyStore()
        try s.add(stored(id, presence: false), pem: TestKeys.pem())
        let p = ScriptedPresence(allow: false)
        #expect(try KeyLoader.load(keyID: id, store: s, presence: p).stored.presence == false && p.asked.isEmpty)
    }

    @Test func loadingAnUnknownKeyNamesTheStoredOnes() throws {
        let s = MemoryKeyStore()
        try s.add(stored(TestKeys.keyID), pem: TestKeys.pem())
        let p = ScriptedPresence(allow: true)
        #expect(throws: ConnectError.unknownKey("ZZZZZZZZZZ", known: [TestKeys.keyID])) {
            try KeyLoader.load(keyID: "ZZZZZZZZZZ", store: s, presence: p)
        }
        #expect(p.asked.isEmpty && s.dataReads == 0)
    }
}
