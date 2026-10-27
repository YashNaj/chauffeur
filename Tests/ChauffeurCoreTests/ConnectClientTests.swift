import Foundation
import Testing

@testable import ChauffeurCore

@Suite struct ConnectClientTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func client(_ answers: [String: ConnectResponse]) throws -> (ConnectClient, ScriptedTransport) {
        let transport = ScriptedTransport(answers)
        let now = self.now
        let client = ConnectClient(key: try TestKeys.key(), role: .appManager, transport: transport, now: { now })
        return (client, transport)
    }

    /// The claims of the JWT in a request's `Authorization: Bearer` header.
    func claims(_ request: ConnectRequest) throws -> JSON {
        let header = try #require(request.headers["Authorization"])
        let jwt = String(header.dropFirst("Bearer ".count))
        let parts = jwt.split(separator: ".", omittingEmptySubsequences: false)
        try #require(parts.count == 3)
        var text = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while text.count % 4 != 0 { text += "=" }
        return try JSON.parse(try #require(Data(base64Encoded: text)))
    }

    @Test func eachReadGetsItsOwnScopedTwoMinuteToken() throws {
        let (c, t) = try client(["GET /v1/apps": ScriptedTransport.response(200, #"{"data":[]}"#)])
        _ = try c.send(.apps(bundleID: nil))
        let claims = try claims(t.requests[0])
        #expect(claims["scope"] == ["GET /v1/apps?limit=200"] && claims["exp"]?.int == 1_800_000_120)
        #expect(t.requests[0].url.host == "api.appstoreconnect.apple.com")
    }

    @Test func statusesBecomeErrors() throws {
        let forbidden = ScriptedTransport.response(
            403, #"{"errors":[{"status":"403","code":"FORBIDDEN_ERROR","title":"forbidden"}]}"#)
        let (c, _) = try client([
            "GET /v1/users": forbidden, "GET /v1/builds/{id}": ScriptedTransport.response(401, "{}"),
            "GET /v1/apps": ScriptedTransport.response(429, "{}", rateLimit: "user-hour-lim:3600;user-hour-rem:0"),
            "GET /v1/betaGroups": ScriptedTransport.response(
                500, #"{"errors":[{"status":"500","code":"UNEXPECTED_ERROR","title":"An unexpected \"error\""}]}"#),
        ])
        // The key's role covers the row, so the refusal is Apple's, with Apple's reason.
        #expect(
            throws: ConnectError.apple(
                status: 403, shape: "GET /v1/users",
                errors: [AppleError(status: "403", code: "FORBIDDEN_ERROR", title: "forbidden", detail: nil)])
        ) { try c.send(.probeUsers) }
        #expect(throws: ConnectError.unauthorized) { try c.send(.build(id: "b")) }
        #expect(throws: ConnectError.rateLimited(remaining: 0)) { try c.send(.probeApps) }
        #expect(
            throws: ConnectError.apple(
                status: 500, shape: "GET /v1/betaGroups",
                errors: [
                    AppleError(status: "500", code: "UNEXPECTED_ERROR", title: "An unexpected \"error\"", detail: nil)
                ])
        ) { try c.send(.betaGroups(appID: "a")) }
    }

    @Test func rateLimitIsReadOnEveryResponseAndEnsureStops() throws {
        let (c, _) = try client([
            "GET /v1/apps": ScriptedTransport.response(
                200, #"{"data":[]}"#, rateLimit: "user-hour-lim:3600;user-hour-rem:2")
        ])
        _ = try c.send(.probeApps)
        #expect(c.rateLimit == RateLimit(limit: 3600, remaining: 2))
        #expect(throws: ConnectError.rateLimited(remaining: 2)) { try c.ensure(requests: 3) }
        try c.ensure(requests: 2)
    }

    @Test func theLogHasShapesAndNoSecrets() throws {
        let (c, _) = try client(["GET /v1/builds/{id}": ScriptedTransport.response(200, #"{"data":{}}"#)])
        _ = try c.send(.build(id: "b1"))
        #expect(c.log.count == 1 && c.log[0].hasPrefix("GET /v1/builds/{id} 200 "))
        #expect(!c.log[0].contains("b1") && !c.log[0].contains("Bearer"))
    }

    @Test func transportErrorsPassThrough() throws {
        let (c, _) = try client([:])
        #expect(throws: ConnectError.transport("unscripted GET /v1/users")) { try c.send(.probeUsers) }
    }

    /// One operation of every kind, with every optional filter set.
    static let sample: [ChauffeurCore.Operation] = [
        .probeUsers, .probeCertificates, .probeApps, .apps(bundleID: "dev.x"),
        .builds(appID: "a1", version: "1.0", buildNumber: "7"), .build(id: "b1"), .buildBetaDetail(buildID: "b1"),
        .betaGroups(appID: "a1"), .preReleaseVersions(appID: "a1"), .appStoreVersions(appID: "a1"),
        .appStoreVersion(id: "v1"), .appStoreVersionLocalizations(versionID: "v1"), .reviewSubmissions(appID: "a1"),
        .reviewSubmission(id: "r1"), .buildUpload(id: "u1"), .buildUploadFiles(uploadID: "u1"),
    ]

    @Test func everyOperationBuildsTheURLTheTableDescribes() throws {
        #expect(Self.sample.map(\.kind) == ChauffeurCore.Operation.Kind.allCases)
        let (c, _) = try client([:])
        for op in Self.sample {
            let request = try c.request(for: op, now: now)
            let prefix = "https://api.appstoreconnect.apple.com" + RequestTable.path(for: op)
            #expect(request.url.absoluteString.hasPrefix(prefix), "\(op.kind)")
            #expect((request.url.query != nil) == !op.query.isEmpty, "\(op.kind)")
        }
    }
}
