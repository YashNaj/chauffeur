import Foundation
import Testing

@testable import ChauffeurCore

/// M4b spec "Testing → Live": every row of the network table on the fixture's Network tab.
@Suite(.enabled(if: Live.enabled), .serialized)
@MainActor struct NetworkLiveTests {
    static func server() throws -> Process {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["python3", "-I", Live.repo.path + "/Tests/FixtureApp/netserver.py"]
        try p.run()
        usleep(500_000)
        return p
    }

    /// The fixture on its Network tab, with the server up; `telemetry` replaces the project's telemetry entries.
    func onNetworkTab(telemetry: ((URL) -> [String])? = nil) throws -> (Session, Process) {
        let server = try Self.server()
        var env = SessionEnvironment.live(udid: Live.udid!)
        if let telemetry { env.telemetry = telemetry }
        let s = Session(udid: Live.udid!, environment: env)
        #expect(s.run(["install", try Live.buildFixture()]).exit == 0)
        #expect(s.run(["launch", Live.fixture]).exit == 0)
        #expect(s.run(["tap", try ref(s, "Network")]).exit == 0)
        print("live: load \(Live.load())")
        return (s, server)
    }

    func done(_ s: Session, _ server: Process) {
        s.shutdown()
        server.terminate()
    }

    @Test func aSlowAPIIsPendingThenWaitFinishesIt() throws {
        let (s, server) = try onNetworkTab()
        defer { done(s, server) }
        let out = s.run(["tap", try ref(s, "Slow API")])
        #expect(out.exit == 6, "\(out.text)")
        #expect(out.text.contains("→ PENDING · 127.0.0.1:8765/slow still running after"), "\(out.text)")
        let waited = s.run(["wait"])
        #expect(waited.exit == 0, "\(waited.text)")
        #expect(
            waited.text.contains("→ changed") && waited.text.contains("request: 127.0.0.1:8765/slow → 200 OK"),
            "\(waited.text)")
    }

    @Test func aFastAPIChangesWithARequestLine() throws {
        let (s, server) = try onNetworkTab()
        defer { done(s, server) }
        let out = s.run(["tap", try ref(s, "Fast API")])
        #expect(out.exit == 0 && out.text.contains("request: 127.0.0.1:8765/fast → 200 OK"), "\(out.text)")
    }

    /// Spec §3: a reply that arrives inside the request window is judged again on the screen as it is then; the
    /// Result row changes only after the 1.2 s reply, well after the screen first settled.
    @Test func aReplyInsideTheWindowThatChangesTheScreenIsAChange() throws {
        let (s, server) = try onNetworkTab()
        defer { done(s, server) }
        let out = s.run(["tap", try ref(s, "Medium API")])
        #expect(out.exit == 0, "\(out.text)")
        #expect(
            out.text.contains("+ text \"Result: medium 200\"")
                && out.text.contains("request: 127.0.0.1:8765/medium → 200 OK"), "\(out.text)")
    }

    @Test func aFailingAPIExplainsTheNoEffect() throws {
        let (s, server) = try onNetworkTab()
        defer { done(s, server) }
        let out = s.run(["tap", try ref(s, "Failing API")])
        #expect(out.exit == 3, "\(out.text)")
        #expect(out.text.contains("→ NO EFFECT · 127.0.0.1:8765/fail → 500 Internal Server Error"), "\(out.text)")
        #expect(out.text.contains("hint: the server failed (500)"), "\(out.text)")
    }

    @Test func analyticsAloneStaysNoEffect() throws {
        let (s, server) = try onNetworkTab(telemetry: { _ in ["127.0.0.1/metrics"] })
        defer { done(s, server) }
        let out = s.run(["tap", try ref(s, "Analytics only")])
        #expect(out.exit == 3 && out.text.contains("telemetry: 1 request (127.0.0.1)"), "\(out.text)")
    }

    @Test func aRawSocketIsPendingFromTheActivityLayer() throws {
        let (s, server) = try onNetworkTab()
        defer { done(s, server) }
        let out = s.run(["tap", try ref(s, "Raw socket")])
        #expect(out.exit == 6 && out.text.contains("→ PENDING · 127.0.0.1:8765 · sent"), "\(out.text)")
    }

    @Test func anOpenWebSocketIsDataFlowing() throws {
        let (s, server) = try onNetworkTab()
        defer { done(s, server) }
        let out = s.run(["tap", try ref(s, "Open WebSocket")])
        #expect(out.exit == 3 && out.text.contains("connected, data flowing"), "\(out.text)")
    }

    /// The link is tapped by a point: the web view's row sits under the search field, and web content is not in
    /// the tree (ruling in Plan 2, Task 12). The WebKit networking process's request is the activity layer's.
    @Test func aWebViewLinkToASlowPageIsPending() throws {
        let (s, server) = try onNetworkTab()
        defer { done(s, server) }
        sleep(2)  // the page loads once the row is on screen
        _ = try ref(s, "Search")
        let field = try #require(s.last?.find("Search").first?.frame)
        let out = s.run(["tap", "\(Int(field.x + 30)),\(Int(field.maxY + 40))"])
        #expect(out.exit == 6 && out.text.contains("→ PENDING"), "\(out.text)")
    }

    @Test func aCopyIsAChange() throws {
        let (s, server) = try onNetworkTab()
        defer { done(s, server) }
        // A copy is a change of the pasteboard: an earlier run may have left the same code there.
        try SimCtl.run(["pbcopy", Live.udid!], stdin: "not the code")
        let out = s.run(["tap", try ref(s, "Copy code")])
        #expect(out.exit == 0 && out.text.contains("copied to clipboard (17 characters)"), "\(out.text)")
    }

    @Test func aDeadButtonIsPlainAndNotSlower() throws {
        let (s, server) = try onNetworkTab()
        defer { done(s, server) }
        // The web view loads its page once its row is on screen; that load must not land in a dead tap's window
        // (Stage 5 names it; it stays a request line).
        sleep(2)
        let dead = try ref(s, "Dead network button")
        var times: [Int] = []
        for _ in 0..<3 {
            let start = Date()
            let out = s.run(["tap", dead])
            times.append(Int(Date().timeIntervalSince(start) * 1000))
            #expect(out.exit == 3 && !out.text.contains("request:") && !out.text.contains("PENDING"), "\(out.text)")
        }
        // Step 0 measured 0.98–1.02 s for a dead tap before M4b; the grace adds 20 ms plus one sample.
        #expect(times.sorted()[1] < 1500, "\(times) at load \(Live.load())")
    }

    @Test func typingIntoSearchIsNeverAFalseNoEffect() throws {
        let (s, server) = try onNetworkTab()
        defer { done(s, server) }
        let out = s.run(["type", try ref(s, "search"), "abc"])
        #expect(out.exit == 0, "\(out.text)")
    }

    @Test func aBatchGoesThroughPending() throws {
        let (s, server) = try onNetworkTab()
        defer { done(s, server) }
        let out = s.run(["do", "tap \(try ref(s, "Slow API")); snapshot"])
        #expect(out.exit == 0 && out.text.contains("→ PENDING") && out.text.contains("→ changed"), "\(out.text)")
    }
}
