import Foundation
import Testing
@testable import ChauffeurCore

@Suite(.enabled(if: Live.enabled), .serialized)
@MainActor struct ScrollLiveTests {
    @Test func scrollUntilAndTheEnd() throws {
        try Live.launchFixture()
        let s = Session(udid: Live.udid!); defer { s.shutdown() }
        #expect(s.run(["wait", "Long list", "--timeout", "15"]).exit == 0)
        #expect(s.run(["tap", try ref(s, "button:Long list")]).exit == 0)
        #expect(s.run(["wait", "Row 1", "--timeout", "5"]).exit == 0)

        let found = s.run(["scroll", "down", "--until", "Row 40"])
        #expect(found.exit == 0 && found.text.hasPrefix("found text \"Row 40\" after "), "\(found.text)")

        let up = s.run(["scroll", "up"])
        #expect(up.exit == 0 && up.text.hasPrefix("scroll up → changed"), "\(up.text)")

        let end = s.run(["scroll", "down", "--until", "Row 999"])
        #expect(end.exit == 4 && end.text.hasPrefix("reached the end after "), "\(end.text)")
    }
}
