import Foundation
import Testing
@testable import ChauffeurCore

@Suite(.enabled(if: Live.enabled), .serialized)
@MainActor struct LogTapLiveTests {
    @Test func followsTheFixturesUnifiedLog() throws {
        try Live.launchFixture()
        let tap = LogTap(udid: Live.udid!)
        defer { tap.stop() }
        #expect(tap.start(executable: "Fixture"), "log stream did not attach within 5 s")
        let s = Session(udid: Live.udid!)
        defer { s.shutdown() }
        #expect(s.run(["wait", "Show alert", "--timeout", "15"]).exit == 0)
        let cursor = tap.cursor
        #expect(s.run(["tap", try ref(s, "Show alert")]).exit == 0)
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline, !tap.since(cursor).contains(where: { $0.message == "fixture: show alert" }) { usleep(100_000) }
        let line = try #require(tap.since(cursor).first { $0.message == "fixture: show alert" }, "\(tap.since(cursor))")
        #expect(line.level == "info" && line.sender == nil)
        #expect(s.run(["tap", try ref(s, "button:OK")]).exit == 0)
    }
}
