import Testing

@testable import ChauffeurCore

/// M4b spec §3: the result rules as text, JSON and exit codes.
@Suite struct ReportNetworkTests {
    func report(_ outcome: Outcome, requests: [RequestItem], diff: [String] = [], hints: [String] = []) -> ActionReport
    {
        var r = ActionReport(
            action: "tap e4 \"Login\"", outcome: outcome, evidence: .app("dev.chauffeur.fixture"), settledMs: 420,
            settled: true, revBefore: 7, revAfter: outcome == .changed ? 8 : 7, diff: diff, transport: "digitizer",
            retriedFrom: nil, hints: hints, capMs: 1500)
        r.requests = requests
        r.requestElapsedMs = 2200
        return r
    }
    let fail = RequestItem(
        host: "localhost", port: 8765, path: "/fail", status: 500, ms: 481, serverMs: 1, sent: 206, received: 113,
        proto: "http/1.1", bodyBytes: 0)
    let ping = RequestItem(host: "app-measurement.com", port: 443, path: "/a", status: 204, telemetry: true)
    let open = RequestItem(host: "api.example.com", port: 443, path: "/login", waiting: true)

    @Test func pending() {
        let r = report(.pending, requests: [open], hints: Verifier.hints(outcome: .pending, target: nil))
        #expect(
            r.render() == """
                tap e4 "Login" → PENDING · api.example.com/login still running after 2.2 s
                hint: run `chauffeur wait` for the result
                """)
        #expect(r.exitCode == 6)
        #expect(r.json["outcome"]?.string == "pending")
        #expect(r.json["requests"]?.array?.first?["waiting"]?.bool == true)
    }

    @Test func aFailureLeadsTheNoEffect() {
        let r = report(.noEffect, requests: [ping, fail], hints: [RequestText.hint(fail) ?? ""])
        #expect(
            r.render() == """
                tap e4 "Login" → NO EFFECT · localhost:8765/fail → 500 Internal Server Error in 481 ms (server 1 ms)
                request: sent 206 B, got 113 B · http/1.1
                telemetry: 1 request (app-measurement.com)
                hint: the server failed (500) and the app shows nothing for it; check the server or the app's error handling
                """)
        #expect(r.exitCode == 3)
    }

    @Test func aSuccessThatChangedNothing() {
        var ok = fail
        ok.status = 200
        #expect(
            report(.noEffect, requests: [ok]).render().hasPrefix(
                "tap e4 \"Login\" → NO EFFECT · localhost:8765/fail → 200 OK in 481 ms (server 1 ms), but nothing changed on screen"
            ))
    }

    @Test func aChangeListsItsRequests() {
        var created = fail
        created.status = 201
        let r = report(.changed, requests: [created], diff: ["+ text \"Welcome\""])
        #expect(
            r.render() == """
                tap e4 "Login" → changed · settled 420ms · rev 7→8
                + text "Welcome"
                request: localhost:8765/fail → 201 Created in 481 ms (server 1 ms) · sent 206 B, got 113 B · http/1.1
                """)
    }

    @Test func aCopyIsAChange() {
        var r = report(.changed, requests: [])
        r.copiedCharacters = 24
        #expect(r.render() == "tap e4 \"Login\" → changed · copied to clipboard (24 characters)")
        #expect(r.json["copied"]?.int == 24 && r.exitCode == 0)
    }

    @Test func anUnwatchedNetworkIsSaid() {
        var r = report(.noEffect, requests: [])
        r.networkNote = "no app process to watch"
        #expect(r.render().hasSuffix("\nnote: network not watched (no app process to watch)"))
    }

    @Test func plainNoEffectIsUnchanged() {
        #expect(
            report(.noEffect, requests: []).render()
                == "tap e4 \"Login\" → NO EFFECT · the accessibility tree did not change in 1.5s (touch reached dev.chauffeur.fixture)"
        )
    }
}
