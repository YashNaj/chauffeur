import Foundation
import Testing

@testable import ChauffeurCore

@Suite struct ConnectKeysTests {
    let cwd = FileManager.default.temporaryDirectory

    func env(
        users: String = "users-403", certificates: String = "certificates-403", apps: String = "apps-200",
        store: MemoryKeyStore = MemoryKeyStore(), presence: Bool = true, file: String? = nil
    ) throws -> (ConnectKeys.Environment, MemoryKeyStore, ScriptedTransport) {
        let t = ScriptedTransport([
            "GET /v1/users": try Fixtures.connect(users),
            "GET /v1/certificates": try Fixtures.connect(certificates),
            "GET /v1/apps": try Fixtures.connect(apps),
        ])
        let e = ConnectKeys.Environment(
            store: store, presence: ScriptedPresence(allow: presence), transport: t,
            readFile: { _ in file ?? TestKeys.pem() }, now: { Date(timeIntervalSince1970: 1_800_000_000) })
        return (e, store, t)
    }

    let add = { (e: ConnectKeys.Environment, cwd: URL) in
        try ConnectKeys.add(
            file: "AuthKey_7X2K9ABC1D.p8", issuer: TestKeys.issuer, keyID: TestKeys.keyID, role: .appManager,
            presence: true, cwd: cwd, env: e)
    }

    @Test func addProbesPrintsTheSheetAndStores() throws {
        let (e, store, t) = try env()
        let out = try add(e, cwd)
        #expect(
            out.exit == 0
                && out.text.hasPrefix(
                    "key 7X2K9ABC1D · App Manager · issuer 69a6de70… · apps: Fixture (dev.chauffeur.fixture), ")
        )
        #expect(
            out.text.contains(
                "\nstored key 7X2K9ABC1D (App Manager, 2 apps) in your login keychain, Touch ID to use\nhint: AuthKey_7X2K9ABC1D.p8 is still on disk; keep a copy somewhere safe, then delete it\n"
            ))
        #expect(
            try store.list() == [
                StoredKey(
                    keyID: "7X2K9ABC1D", issuer: TestKeys.issuer, role: .appManager,
                    apps: ["Fixture (dev.chauffeur.fixture)", #"Notes \"quoted\" (dev.x.notes)"#],
                    added: "2027-01-15T08:00:00Z", presence: true)
            ])
        #expect(t.requests.map(\.shape) == ["GET /v1/users", "GET /v1/certificates", "GET /v1/apps"])
        #expect(!out.text.contains("PRIVATE KEY") && out.data?["keyID"] == "7X2K9ABC1D")
    }

    @Test func addRefusesAnAdminKeyAndStoresNothing() throws {
        let (e, store, t) = try env(users: "users-200")
        let out = try add(e, cwd)
        #expect(out.exit == 1 && out.text.hasPrefix("refused: Admin key. This key can remove every other Admin"))
        #expect(try store.list().isEmpty && t.requests.count == 1)
    }

    @Test func addRefusesACertificatesKey() throws {
        let (e, store, _) = try env(certificates: "certificates-200")
        let out = try add(e, cwd)
        #expect(
            out.exit == 1
                && out.text.hasPrefix("refused: this key reaches Certificates, Identifiers & Profiles"))
        #expect(try store.list().isEmpty)
    }

    @Test func addRefusesABadFileBeforeAnyRequest() throws {
        let (e, store, t) = try env(file: "usage: chauffeur <command>")
        #expect(throws: ConnectError.self) { try add(e, cwd) }
        #expect(try store.list().isEmpty && t.requests.isEmpty)
    }

    @Test func addRefusesADuplicateId() throws {
        let (e, _, t) = try env()
        _ = try add(e, cwd)
        #expect(throws: ConnectError.duplicateKey("7X2K9ABC1D")) { try add(e, cwd) }
        #expect(t.requests.count == 3)
    }

    @Test func addStoresNothingWhenTheProbeCannotRun() throws {
        let (e, store, _) = try env(users: "server-500")
        #expect(throws: ConnectError.self) { try add(e, cwd) }
        #expect(try store.list().isEmpty)
        let (e2, store2, _) = try env(users: "unauthorized-401")
        let out = try add(e2, cwd)
        #expect(try out.exit == 1 && out.text == ConnectError.unauthorized.description && store2.list().isEmpty)
    }

    @Test func addStoresNothingWhenRateLimited() throws {
        let (e, store, _) = try env(users: "rate-limited-429")
        let out = try add(e, cwd)
        #expect(
            try out.exit == 1 && out.text.hasPrefix("rate limited by App Store Connect") && store.list().isEmpty)
    }

    @Test func noPresenceIsSaidOutLoud() throws {
        let (e, store, _) = try env()
        let out = try ConnectKeys.add(
            file: "k.p8", issuer: TestKeys.issuer, keyID: TestKeys.keyID, role: .developer, presence: false,
            cwd: cwd, env: e)
        #expect(out.text.contains("in your login keychain (no presence: any process running as you can read it)"))
        #expect(try store.list()[0].presence == false && out.text.contains("can:    upload builds · read builds"))
    }

    @Test func checkAsksForPresenceAndReprobes() throws {
        let (e, _, t) = try env()
        _ = try add(e, cwd)
        let presence = ScriptedPresence(allow: true)
        var e2 = e
        e2.presence = presence
        let out = try ConnectKeys.check(keyID: nil, config: nil, env: e2)
        #expect(
            out.exit == 0 && out.text.hasSuffix("\nkey 7X2K9ABC1D: ok (2 apps)") && presence.asked.count == 1
                && t.requests.count == 6)
    }

    @Test func checkReportsARevokedKey() throws {
        let (e, store, _) = try env()
        _ = try add(e, cwd)
        let (e2, _, _) = try env(users: "unauthorized-401", store: store)
        let out = try ConnectKeys.check(keyID: "7X2K9ABC1D", config: nil, env: e2)
        #expect(out.exit == 1 && out.text == ConnectError.unauthorized.description)
    }

    @Test func removeSaysItDoesNotRevoke() throws {
        let (e, store, _) = try env()
        _ = try add(e, cwd)
        let out = try ConnectKeys.remove(keyID: "7X2K9ABC1D", env: e)
        #expect(
            try out.text.hasPrefix("removed key 7X2K9ABC1D from your login keychain. It is not revoked")
                && store.list().isEmpty)
        #expect(throws: ConnectError.unknownKey("7X2K9ABC1D", known: [])) {
            try ConnectKeys.remove(keyID: "7X2K9ABC1D", env: e)
        }
    }

    @Test func resolution() throws {
        let a = StoredKey(keyID: "A", issuer: "", role: .developer, apps: [], added: "", presence: true)
        let b = StoredKey(keyID: "B", issuer: "", role: .developer, apps: [], added: "", presence: true)
        #expect(try ConnectKeys.resolve(flag: "B", config: "A", stored: [a, b]).keyID == "B")
        #expect(try ConnectKeys.resolve(flag: nil, config: "A", stored: [a, b]).keyID == "A")
        #expect(try ConnectKeys.resolve(flag: nil, config: nil, stored: [a]).keyID == "A")
        #expect(throws: ConnectError.noKey(known: ["A", "B"])) {
            try ConnectKeys.resolve(flag: nil, config: nil, stored: [a, b])
        }
        #expect(throws: ConnectError.noKey(known: [])) { try ConnectKeys.resolve(flag: nil, config: nil, stored: []) }
        #expect(throws: ConnectError.unknownKey("Z", known: ["A"])) {
            try ConnectKeys.resolve(flag: nil, config: "Z", stored: [a])
        }
    }
}
