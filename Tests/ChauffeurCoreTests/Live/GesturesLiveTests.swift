import Foundation
import Testing
@testable import ChauffeurCore

@Suite(.enabled(if: Live.enabled), .serialized)
@MainActor struct GesturesLiveTests {
    @Test func swipeMovesTheListAndRespectsTheEdgeGuard() throws {
        try Live.launchFixture()
        let s = Session(udid: Live.udid!)
        defer { s.shutdown() }
        #expect(s.run(["wait", "Long list", "--timeout", "15"]).exit == 0)
        #expect(s.run(["tap", try ref(s, "button:Long list")]).exit == 0)
        #expect(s.run(["wait", "Row 1", "--timeout", "5"]).exit == 0)
        let swipe = s.run(["swipe", "201,650", "201,250"])
        #expect(swipe.exit == 0 && swipe.text.hasPrefix("swipe (201,650)→(201,250) → changed"), "\(swipe.text)")
        let edge = s.run(["swipe", "2,400", "300,400"])
        #expect(edge.exit == 1 && edge.text.contains("from the left edge"), "\(edge.text)")
    }

    /// Home returns to SpringBoard; the accessibility tree lags the screen by about a second, so the verifier keeps looking.
    @Test func homeLeavesTheAppAndVolumeIsHonest() throws {
        try Live.launchFixture()
        let s = Session(udid: Live.udid!)
        defer { s.shutdown() }
        #expect(s.run(["wait", "Show alert", "--timeout", "15"]).exit == 0)
        let home = s.run(["button", "home"])
        #expect(home.exit == 0 && home.text.hasPrefix("button home → changed"), "\(home.text)")
        #expect(s.last?.kind == .springboard)
        let volume = s.run(["button", "volume-up"])
        // The volume HUD may not be in the accessibility tree: changed or UNVERIFIED, never a silent "ok".
        #expect(volume.exit == 0 || volume.text.contains("→ UNVERIFIED: no visible change (a button press leaves no touch evidence)"),
                "\(volume.text)")
    }
}
