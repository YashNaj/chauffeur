import Testing

@testable import ChauffeurCore

@Suite struct RequestTextTests {
    let fail = RequestItem(
        host: "localhost", port: 8765, path: "/fail", status: 500, ms: 481, serverMs: 1, sent: 206, received: 113,
        proto: "http/1.1", bodyBytes: 0)
    let post = RequestItem(
        host: "localhost", port: 8765, path: "/fast", status: 201, ms: 175, serverMs: 1, sent: 300, received: 104,
        proto: "http/1.1", bodyBytes: 14)
    let refused = RequestItem(
        host: "localhost", port: 8765, path: "/fast", errorCode: -1004, ms: 107, sent: 0,
        received: 0)

    @Test func aStatusInWords() {
        #expect(
            RequestText.outcome(fail, elapsedMs: 600)
                == "localhost:8765/fail → 500 Internal Server Error in 481 ms (server 1 ms)")
        #expect(RequestText.details(fail) == "sent 206 B, got 113 B · http/1.1")
        #expect(RequestText.details(post) == "sent 300 B (body 14 B), got 104 B · http/1.1")
    }

    @Test func anErrorInWords() {
        #expect(
            RequestText.outcome(refused, elapsedMs: 200)
                == "localhost:8765/fast failed: could not connect to the server (-1004) after 107 ms")
        #expect(RequestText.details(refused) == "")
        #expect(
            RequestText.hint(refused) == "nothing accepted the connection at localhost:8765; is the server running?")
    }

    @Test func stillRunning() {
        let open = RequestItem(host: "api.example.com", port: 443, path: "/login", waiting: true)
        #expect(RequestText.outcome(open, elapsedMs: 2200) == "api.example.com/login still running after 2.2 s")
        let raw = RequestItem(
            host: "127.0.0.1", port: 8765, sent: 58, received: 0, proto: "tcp", waiting: true,
            hostKnown: false)
        #expect(RequestText.outcome(raw, elapsedMs: 2100) == "127.0.0.1:8765 · sent 58 B, no reply after 2.1 s")
        #expect(RequestText.details(raw) == "telemetry filter unavailable for 127.0.0.1")
    }

    @Test func aStream() {
        let socket = RequestItem(
            host: "127.0.0.1", port: 8766, sent: 200, received: 1200, proto: "tcp",
            streaming: true, hostKnown: false)
        #expect(
            RequestText.line(socket, elapsedMs: 900)
                == "request: 127.0.0.1:8766 · connected, data flowing · got 1.2 KB · telemetry filter unavailable for 127.0.0.1"
        )
    }

    @Test func hints() {
        #expect(
            RequestText.hint(fail)
                == "the server failed (500) and the app shows nothing for it; check the server or the app's error handling"
        )
        var unauthorized = fail
        unauthorized.status = 401
        #expect(RequestText.hint(unauthorized) == "the server refused the request (401); the app may be signed out")
        #expect(
            RequestText.hint(post)
                == "the request succeeded but the screen didn't change; the app may not update the screen for this response"
        )
    }

    @Test func telemetryAndLines() {
        let ping = RequestItem(host: "app-measurement.com", port: 443, path: "/a", status: 204, telemetry: true)
        let sentry = RequestItem(host: "o1.ingest.sentry.io", port: 443, status: 200, telemetry: true)
        #expect(
            RequestText.telemetry([fail, ping, sentry])
                == "telemetry: 2 requests (app-measurement.com, o1.ingest.sentry.io)")
        #expect(
            RequestText.lines([fail, post, ping], elapsedMs: 600, except: fail) == [
                "request: localhost:8765/fast → 201 Created in 175 ms (server 1 ms) · sent 300 B (body 14 B), got 104 B · http/1.1",
                "telemetry: 1 request (app-measurement.com)",
            ])
    }

    @Test func hostsAndPathsAreEscaped() {
        let hostile = RequestItem(host: "evil\"\ncom", port: 443, path: "/x", status: 200)
        #expect(RequestText.target(hostile) == "evil\\\"\\ncom/x")
    }

    @Test func jsonLeavesOutWhatIsUnknown() {
        let raw = RequestItem(
            host: "127.0.0.1", port: 8765, sent: 58, received: 0, proto: "tcp", waiting: true,
            hostKnown: false)
        let json = RequestText.json(raw)
        #expect(json["host"]?.string == "127.0.0.1" && json["port"]?.int == 8765 && json["waiting"]?.bool == true)
        #expect(json["status"] == nil && json["path"] == nil)
        #expect(RequestText.json(fail)["status"]?.int == 500)
    }

    @Test func sizesAndTimes() {
        #expect(
            RequestText.bytes(94) == "94 B" && RequestText.bytes(1234) == "1.2 KB"
                && RequestText.bytes(3_400_000) == "3.4 MB")
        #expect(RequestText.duration(180) == "180 ms" && RequestText.duration(2500) == "2.5 s")
    }
}
