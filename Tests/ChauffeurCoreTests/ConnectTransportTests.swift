import Foundation
import Testing

@testable import ChauffeurCore

@Suite struct ConnectTransportTests {
    @Test func requestsOnlyGoToAppStoreConnect() {
        let r = ConnectRequest(
            method: .get, pathAndQuery: "/v1/apps?limit=200", shape: "GET /v1/apps", token: "tok", body: nil)
        #expect(r.url.absoluteString == "https://api.appstoreconnect.apple.com/v1/apps?limit=200")
        #expect(r.headers["Authorization"] == "Bearer tok" && r.headers["Accept"] == "application/json")
    }

    @Test func aRequestPrintsAsItsShapeOnly() {
        let r = ConnectRequest(
            method: .get, pathAndQuery: "/v1/builds/b1", shape: "GET /v1/builds/{id}", token: "tok-secret", body: nil)
        #expect("\(r)" == "GET /v1/builds/{id}")
        #expect(!String(reflecting: r).contains("tok-secret"))
        #expect(!String(describing: Mirror(reflecting: r).children.map { "\($0.value)" }).contains("tok-secret"))
        var dumped = ""
        dump(r, to: &dumped)
        #expect(!dumped.contains("tok-secret"))
    }

    @Test func aPathCannotMoveTheHost() {
        for path in ["@evil.example/x", ".evil.example/x"] {
            let r = ConnectRequest(method: .get, pathAndQuery: path, shape: "GET x", token: "t", body: nil)
            #expect(r.url.host == "api.appstoreconnect.apple.com")
        }
    }

    @Test func aFilterQueryIsNotDoubleEncoded() {
        let q = "/v1/apps?filter[bundleId]=dev.x&limit=200"
        let r = ConnectRequest(method: .get, pathAndQuery: q, shape: "GET x", token: "t", body: nil)
        // Foundation always writes brackets as %5B/%5D (equivalent on the wire); nothing is double-encoded.
        #expect(
            r.url.absoluteString
                == "https://api.appstoreconnect.apple.com/v1/apps?filter%5BbundleId%5D=dev.x&limit=200")
    }

    @Test func aBodyAddsAContentType() {
        let r = ConnectRequest(
            method: .post, pathAndQuery: "/v1/x", shape: "POST /v1/x", token: "t", body: Data("{}".utf8))
        #expect(r.headers["Content-Type"] == "application/json")
    }

    @Test func parsesTheRateLimitHeader() {
        #expect(RateLimit.parse("user-hour-lim:3600;user-hour-rem:3599") == RateLimit(limit: 3600, remaining: 3599))
        #expect(RateLimit.parse(" user-hour-rem:5 ; user-hour-lim:100") == RateLimit(limit: 100, remaining: 5))
        #expect(RateLimit.parse("user-hour-lim:3600") == nil && RateLimit.parse(nil) == nil)
        #expect(RateLimit.parse("user-hour-lim:x;user-hour-rem:1") == nil)
    }

    @Test func headersAreCaseInsensitive() {
        let r = ConnectResponse(status: 200, headers: ["x-rate-limit": "user-hour-lim:1;user-hour-rem:0"], body: Data())
        #expect(r.header("X-Rate-Limit") == "user-hour-lim:1;user-hour-rem:0")
    }
}
