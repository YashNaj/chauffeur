import Foundation
import Testing

@testable import ChauffeurCore

@Suite(.enabled(if: Live.enabled), .serialized)
@MainActor struct TapLiveTests {
    func fresh() throws -> Session {
        try Live.launchFixture()
        let s = Session(udid: Live.udid!)
        #expect(s.run(["wait", "Show alert", "--timeout", "15"]).exit == 0)
        return s
    }

    @Test func tapByRefIsVerifiedChanged() throws {
        let s = try fresh()
        defer { s.shutdown() }
        let showAlert = try ref(s, "Show alert")
        let out = s.run(["tap", showAlert])
        #expect(out.exit == 0)
        #expect(out.text.hasPrefix("tap \(showAlert) \"Show alert\" → changed"))
        #expect(out.text.contains("Fixture alert"))
        let ok = s.run(["tap", try ref(s, "button:OK")])
        #expect(ok.exit == 0, "\(ok.text)")
    }

    @Test func disabledButtonIsNoEffectWithHint() throws {
        let s = try fresh()
        defer { s.shutdown() }
        #expect(s.run(["tap", try ref(s, "tab:Form")]).exit == 0)
        let out = s.run(["tap", try ref(s, "button:Submit")])
        #expect(out.exit == 3)
        #expect(out.text.contains("→ NO EFFECT · the accessibility tree did not change"), "\(out.text)")
        #expect(out.text.contains("\nscreen: "), "\(out.text)")
        #expect(out.text.contains("is disabled"))
    }

    @Test func staleRefIsRefusedWithoutTouching() throws {
        let s = try fresh()
        defer { s.shutdown() }
        let showAlert = try ref(s, "Show alert")
        #expect(s.run(["tap", try ref(s, "tab:Form")]).exit == 0)
        let cursor = s.touchLog.cursor
        let out = s.run(["tap", showAlert])
        #expect(out.exit == 1)
        #expect(out.text == "stale ref \(showAlert) (\"Show alert\") — not on screen; run snapshot")
        #expect(s.touchLog.cursor == cursor)
    }

    @Test func coordinatesAndTheEdgeGuard() throws {
        let s = try fresh()
        defer { s.shutdown() }
        let refused = s.run(["tap", "3,400"])
        #expect(refused.exit == 1 && refused.text.contains("3pt from the left edge"))
        let center = try #require(s.last?.find("Show alert").first?.frame.center)
        let out = s.run(["tap", "\(Int(center.x)),\(Int(center.y))"])
        #expect(out.exit == 0 && out.text.contains("→ changed"))
    }

    @Test func backToBackTapsSurviveTheAlertPresentation() throws {
        // A just-presented alert drops touches for a few hundred ms (Task 11). Tap OK immediately after the
        // tap that opened it, with no extra snapshot in between; the Session must still land it.
        for _ in 0..<3 {
            let s = try fresh()
            defer { s.shutdown() }
            #expect(s.run(["tap", try ref(s, "Show alert")]).exit == 0)
            let okRef = try #require(s.last?.find("button:OK").first?.ref)
            let ok = s.run(["tap", okRef])
            #expect(ok.exit == 0, "\(ok.text)")
        }
    }
}
