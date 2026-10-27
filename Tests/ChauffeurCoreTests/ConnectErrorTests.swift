import Foundation
import Testing

@testable import ChauffeurCore

@Suite struct ConnectErrorTests {
    @Test func parsesAppleErrors() {
        let body = Data(
            #"{"errors":[{"id":"x","status":"403","code":"FORBIDDEN_ERROR","title":"This request is forbidden for security reasons","detail":"The API key in use does not allow this request"}]}"#
                .utf8)
        #expect(
            AppleError.parse(body) == [
                AppleError(
                    status: "403", code: "FORBIDDEN_ERROR",
                    title: "This request is forbidden for security reasons",
                    detail: "The API key in use does not allow this request")
            ])
        #expect(AppleError.parse(Data("<html>".utf8)) == [])
    }

    @Test func messagesSayWhatToDo() {
        #expect(
            ConnectError.forbidden(shape: "POST /v1/reviewSubmissions", needs: .appManager, have: .developer)
                .description
                == "App Store Connect refused POST /v1/reviewSubmissions (403): it needs the App Manager role and this key is Developer"
        )
        #expect(
            ConnectError.rateLimited(remaining: 0).description
                == "rate limited by App Store Connect: 0 requests left this hour; try again later")
        let e = AppleError(status: "409", code: "STATE_ERROR", title: "t", detail: "Build \"7\" is\nalready attached")
        #expect(
            ConnectError.conflict(shape: "PATCH /v1/x", errors: [e]).description
                == #"App Store Connect refused PATCH /v1/x (409): Build \"7\" is\nalready attached"#)
        #expect(ConnectError.noKey(known: []).description.hasPrefix("no App Store Connect key: chauffeur keys add"))
        #expect(
            ConnectError.noKey(known: ["A", "B"]).description
                == "several keys stored (A, B): pin one with chauffeur keys use <id>")
        #expect(
            ConnectError.duplicateKey("A").description
                == "key A is already stored; run chauffeur keys remove A first")
    }

    @Test func remainingMessages() {
        #expect(
            ConnectError.unauthorized.description
                == "App Store Connect rejected the key: check --issuer and --key-id, and that the key is not revoked")
        let a = AppleError(status: "500", code: "UNEXPECTED", title: "Bad \"x\"", detail: "line\none")
        #expect(
            ConnectError.apple(status: 500, shape: "GET /v1/apps", errors: [a]).description
                == #"App Store Connect answered 500 to GET /v1/apps: UNEXPECTED Bad \"x\": line\none"#)
        let b = AppleError(status: "500", code: "UNEXPECTED", title: "T", detail: nil)
        #expect(
            ConnectError.apple(status: 500, shape: "GET /v1/apps", errors: [b]).description
                == "App Store Connect answered 500 to GET /v1/apps: UNEXPECTED T")
        #expect(
            ConnectError.apple(status: 502, shape: "GET /v1/apps", errors: []).description
                == "App Store Connect answered 502 to GET /v1/apps")
        let c = AppleError(status: "409", code: "C", title: "Only title", detail: nil)
        #expect(
            ConnectError.conflict(shape: "PATCH /v1/x", errors: [c, e2]).description
                == "App Store Connect refused PATCH /v1/x (409): Only title\nsecond")
        #expect(
            ConnectError.transport("offline").description == "could not reach App Store Connect: offline")
        #expect(
            ConnectError.unexpectedBody(shape: "GET /v1/apps").description
                == "App Store Connect answered GET /v1/apps with a body chauffeur can't read")
        #expect(
            ConnectError.noKey(known: []).description
                == "no App Store Connect key: chauffeur keys add <AuthKey.p8> --issuer <uuid> --key-id <id> --role app-manager"
        )
        #expect(ConnectError.unknownKey("Z", known: ["A", "B"]).description == "no stored key Z; stored: A, B")
        #expect(ConnectError.unknownKey("Z", known: []).description == "no stored key Z; stored: none")
        #expect(
            ConnectError.presenceDenied("cancelled").description == "not confirmed: cancelled. Nothing was read")
        #expect(
            ConnectError.keychain(-25300, "reading key A").description
                .hasSuffix("(-25300) while reading key A"))
        #expect(ConnectError.keychain(-25300, "reading key A").description.hasPrefix("keychain: "))
        #expect(ConnectError.badKeyFile("x").description == "x")
    }

    private let e2 = AppleError(status: "409", code: "C", title: "t", detail: "second")
}
