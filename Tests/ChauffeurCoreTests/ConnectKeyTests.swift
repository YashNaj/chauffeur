import Foundation
import Testing

@testable import ChauffeurCore

@Suite struct ConnectKeyTests {
    @Test func parsesAPKCS8Key() throws {
        let key = try ConnectKey(pem: TestKeys.pem(), keyID: TestKeys.keyID, issuer: TestKeys.issuer)
        #expect(key.keyID == "7X2K9ABC1D" && "\(key)" == "key 7X2K9ABC1D")
        #expect(!"\(key)".contains("PRIVATE KEY"))
    }

    @Test func rejectsFilesThatAreNotKeys() {
        for bad in ["", "usage: chauffeur <command>", "-----BEGIN CERTIFICATE-----\nAAAA\n-----END CERTIFICATE-----"] {
            #expect(throws: ConnectError.self) {
                try ConnectKey(pem: bad, keyID: TestKeys.keyID, issuer: TestKeys.issuer)
            }
        }
        #expect(throws: ConnectError.badKeyFile("abc is not a key id (10 letters and digits, as in AuthKey_<id>.p8)")) {
            try ConnectKey(pem: TestKeys.pem(), keyID: "abc", issuer: TestKeys.issuer)
        }
        #expect(throws: ConnectError.self) {
            try ConnectKey(pem: TestKeys.pem(), keyID: TestKeys.keyID, issuer: "team")
        }
    }

    @Test func storedKeyRoundTripsAsComment() throws {
        let k = StoredKey(
            keyID: "7X2K9ABC1D", issuer: TestKeys.issuer, role: .appManager,
            apps: ["Fixture (dev.chauffeur.fixture)"], added: "2026-10-26T20:00:00Z", presence: true)
        let json = try k.commentJSON()
        #expect(json.hasPrefix(#"{"added":"2026-10-26T20:00:00Z","apps":["#))
        #expect(StoredKey.from(comment: json) == k && StoredKey.from(comment: "not json") == nil)
    }

    @Test func rolesFromFlags() {
        #expect(ConnectRole(flag: "app-manager") == .appManager && ConnectRole(flag: "developer") == .developer)
        #expect(ConnectRole(flag: "admin") == nil && ConnectRole.appManager.title == "App Manager")
    }
}
