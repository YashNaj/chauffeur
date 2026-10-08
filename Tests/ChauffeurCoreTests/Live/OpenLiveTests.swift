import Foundation
import Testing

@testable import ChauffeurCore

@Suite(.enabled(if: Live.enabled), .serialized)
@MainActor struct OpenLiveTests {
    @Test func deepLinksAreVerifiedByTheScreen() throws {
        let s = Session(udid: Live.udid!)
        defer { s.shutdown() }
        // A confirmation left by an earlier run belongs to SpringBoard and survives relaunches: clear it first.
        if s.run(["snapshot"]).text.contains("Open in "), let cancel = try? ref(s, "button:Cancel") {
            _ = s.run(["tap", cancel])
        }
        #expect(s.run(["install", try Live.buildFixture()]).exit == 0)
        #expect(s.run(["launch", "dev.chauffeur.fixture"]).exit == 0)
        let form = s.run(["open", "chauffeur-fixture://form"])
        #expect(form.exit == 0 && form.text.hasPrefix("open \"chauffeur-fixture://form\" → changed"), "\(form.text)")
        // iOS 26.2 asks `Open in "Fixture"?` first; opening again while it is up changes nothing visible.
        let again = s.run(["open", "chauffeur-fixture://form"])
        #expect(
            again.exit == 3 && again.text.contains("→ UNVERIFIED: no visible change (the URL was delivered"),
            "\(again.text)")
        confirmOpen(s)
        #expect(s.last?.find("textfield:email").isEmpty == false, "the Form tab is in front")
        let nobody = s.run(["open", "nosuchscheme-xyz://x"])
        #expect(
            nobody.exit == 1 && nobody.text.contains("→ FAILED: no installed app handles nosuchscheme-xyz: URLs"),
            "\(nobody.text)")
        #expect(s.run(["open", "chauffeur-fixture://home"]).exit == 0)
        confirmOpen(s)
    }

    /// iOS 26.2 asks `Open in "Fixture"?` (SpringBoard) before a simctl-opened custom scheme: tap its Open button.
    func confirmOpen(_ s: Session) {
        for _ in 0..<3 {
            let snapshot = s.run(["snapshot"])
            guard snapshot.text.contains("Open in "), let open = try? ref(s, "button:Open") else { return }
            #expect(s.run(["tap", open]).exit == 0)
        }
    }
}
