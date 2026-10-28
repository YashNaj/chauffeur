import Testing

@testable import ChauffeurCore

/// What the golden report tests need of a report: the text an agent reads and the same report as data.
protocol ReportRendering: Sendable {
    func render() -> String
    var json: JSON { get }
}

extension ActionReport: ReportRendering {}
extension TypeReport: ReportRendering {}

/// Request items shared by the report tests: a failure, telemetry, and a reply still awaited.
enum ReportFixtures {
    static let fail = RequestItem(
        host: "localhost", port: 8765, path: "/fail", status: 500, ms: 481, serverMs: 1, sent: 206, received: 113,
        proto: "http/1.1", bodyBytes: 0)
    static let ping = RequestItem(host: "app-measurement.com", port: 443, path: "/a", status: 204, telemetry: true)
    static let open = RequestItem(host: "api.example.com", port: 443, path: "/login", waiting: true)
}

/// One report per shape the renderers have, built from fixed values so the goldens never move on their own.
enum ReportCases {
    private typealias F = ReportFixtures

    private static func action(
        _ outcome: Outcome, evidence: Evidence = .app("dev.chauffeur.fixture"), settled: Bool = true,
        diff: [String] = [], transport: String = "digitizer", retriedFrom: String? = nil, extraHints: [String] = [],
        requests: [RequestItem] = [], configure: (inout ActionReport) -> Void = { _ in }
    ) -> ActionReport {
        var r = ActionReport(
            action: "tap e4 \"Login\"", outcome: outcome, evidence: evidence, settledMs: 420, settled: settled,
            revBefore: 7, revAfter: outcome == .changed ? 8 : 7, diff: diff, transport: transport,
            retriedFrom: retriedFrom, hints: Verifier.hints(outcome: outcome, target: nil) + extraHints, capMs: 1500)
        r.requests = requests
        r.requestElapsedMs = 2200
        configure(&r)
        return r
    }

    private static func typed(
        _ verdict: TypeVerdict, value: String?, requests: [RequestItem] = []
    ) -> TypeReport {
        var r = TypeReport(
            action: "type e9 \"alice@example.com\"", method: "paste", verdict: verdict, value: value, settledMs: 420)
        r.requests = requests
        r.requestElapsedMs = 2200
        return r
    }

    private static var okWithStatus: RequestItem {
        var ok = F.fail
        ok.status = 200
        return ok
    }

    static let all: [(name: String, report: any ReportRendering)] = [
        (
            "changed-diff",
            action(.changed, diff: ["+ text \"Welcome\"", "- button \"Login\"", "~ e2 value \"\" → \"alice\""])
        ),
        ("changed-copy", action(.changed) { $0.copiedCharacters = 24 }),
        // Unsettled as well, so the "still changing at 1.5s" headline is pinned somewhere.
        ("changed-via-retry", action(.changed, settled: false, transport: "mouse", retriedFrom: "digitizer")),
        // The network note too, so the footer branch is pinned.
        (
            "noeffect-plain",
            action(.noEffect) {
                $0.evidenceShot = "$TMPDIR/shot.jpg"
                $0.networkNote = "no app process to watch"
            }
        ),
        (
            "noeffect-failed-request",
            action(.noEffect, extraHints: [RequestText.hint(F.fail) ?? ""], requests: [F.ping, F.fail])
        ),
        ("noeffect-success-no-change", action(.noEffect, requests: [okWithStatus])),
        ("noeffect-telemetry", action(.noEffect, requests: [F.ping])),
        ("pending", action(.pending, requests: [F.open])),
        ("intercepted", action(.intercepted("com.apple.springboard"), evidence: .system)),
        ("not-delivered", action(.notDelivered, evidence: .none)),
        // A custom reason, so the `note` key and its text are pinned rather than the default.
        ("unverified", action(.unverified, evidence: .unavailable) { $0.note = "the app was not running" }),
        // No custom reason, so the default "(touch log unavailable)" headline is pinned too.
        ("unverified-default", action(.unverified, evidence: .unavailable)),
        ("unattributed", action(.unattributed)),
        ("type-ok", typed(.ok, value: "alice@example.com")),
        ("type-mismatch", typed(.mismatch("alice@example.co"), value: "alice@example.co")),
        ("type-ok-with-request", typed(.ok, value: "alice@example.com", requests: [F.fail])),
    ]
}
