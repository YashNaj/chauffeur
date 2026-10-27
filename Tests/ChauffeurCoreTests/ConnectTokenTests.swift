import CryptoKit
import Foundation
import Testing

@testable import ChauffeurCore

@Suite struct ConnectTokenTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func decode(_ segment: Substring) throws -> Data {
        var text = segment.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while text.count % 4 != 0 { text += "=" }
        return try #require(Data(base64Encoded: text))
    }

    func parts(_ jwt: String) throws -> (header: JSON, claims: JSON, input: String, signature: Data) {
        let pieces = jwt.split(separator: ".", omittingEmptySubsequences: false)
        try #require(pieces.count == 3)
        return (
            try JSON.parse(try decode(pieces[0])),
            try JSON.parse(try decode(pieces[1])),
            "\(pieces[0]).\(pieces[1])",
            try decode(pieces[2])
        )
    }

    @Test func mintsAVerifiableES256Token() throws {
        let pem = TestKeys.pem()
        let key = try ConnectKey(pem: pem, keyID: TestKeys.keyID, issuer: TestKeys.issuer)
        let jwt = try ConnectToken.mint(key, lifetime: .call, scope: ["GET /v1/apps?limit=200"], now: now)
        let p = try parts(jwt)
        #expect(p.header == ["alg": "ES256", "kid": "7X2K9ABC1D", "typ": "JWT"])
        #expect(p.claims["iss"]?.string == TestKeys.issuer && p.claims["aud"]?.string == "appstoreconnect-v1")
        #expect(p.claims["iat"]?.int == 1_800_000_000 && p.claims["exp"]?.int == 1_800_000_120)
        #expect(p.claims["scope"] == ["GET /v1/apps?limit=200"])
        #expect(p.signature.count == 64)
        let publicKey = try P256.Signing.PrivateKey(pemRepresentation: pem).publicKey
        let signature = try P256.Signing.ECDSASignature(rawRepresentation: p.signature)
        #expect(publicKey.isValidSignature(signature, for: Data(p.input.utf8)))
        #expect(!jwt.contains("=") && !jwt.contains("+") && !jwt.contains("/"))
    }

    @Test func sessionTokensLastTwentyMinutesAndNoScope() throws {
        let jwt = try ConnectToken.mint(try TestKeys.key(), lifetime: .session, scope: nil, now: now)
        let p = try parts(jwt)
        let iat = try #require(p.claims["iat"]?.int)
        let exp = try #require(p.claims["exp"]?.int)
        #expect(exp - iat == 1200)
        #expect(p.claims["scope"] == nil)
    }

    @Test func sessionRemintsBeforeExpiry() throws {
        var s = TokenSession(key: try TestKeys.key(), lifetime: .session, scope: nil)
        let first = try s.token(now: now)
        #expect(try s.token(now: now + 1000) == first)
        #expect(try s.token(now: now + 1141) != first)  // 59 s left: re-minted
        #expect(s.expiry == now + 1141 + 1200)
    }

    @Test func aSessionPrintsNoToken() throws {
        var s = TokenSession(key: try TestKeys.key(), lifetime: .session, scope: nil)
        let token = try s.token(now: now)
        #expect(token.split(separator: ".").count == 3)
        #expect(!String(reflecting: s).contains(token))
        #expect(Mirror(reflecting: s).children.isEmpty)
        var dumped = ""
        dump(s, to: &dumped)
        #expect(!dumped.contains(token))
    }
}
