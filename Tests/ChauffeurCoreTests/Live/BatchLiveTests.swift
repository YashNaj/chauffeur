import Foundation
import Testing
@testable import ChauffeurCore

@Suite(.enabled(if: Live.enabled), .serialized)
@MainActor struct BatchLiveTests {
    @Test func aBatchRunsInOrderAndStopsAtTheFirstFailure() throws {
        try Live.launchFixture()
        let s = Session(udid: Live.udid!)
        defer { s.shutdown() }
        #expect(s.run(["wait", "Show alert", "--timeout", "15"]).exit == 0)
        let form = try ref(s, "tab:Form")
        // Refs of the tab bar are not kept across a tab switch (the Home tab gets a new ref), so the batch looks it up.
        let ok = s.run(["do", "tap \(form); wait Submit --timeout 5; find tab:Home"])
        #expect(ok.exit == 0, "\(ok.text)")
        #expect(ok.text.hasPrefix("[1/3] tap \(form) \"Form\" → changed"), "\(ok.text)")
        #expect(ok.text.contains("\n[3/3] tab \"Home\" ["), "\(ok.text)")
        #expect(s.run(["tap", try ref(s, "tab:Home")]).exit == 0)

        let stopped = s.run(["do", "wait \"No such thing\" --timeout 1; tap \(form)"])
        #expect(stopped.exit == 4 && stopped.text.hasSuffix("stopped at [1/2] (exit 4); not run: tap \(form)"), "\(stopped.text)")
        #expect(s.run(["find", "Show alert"]).exit == 0, "the second command did not run: Home is still in front")
    }
}
