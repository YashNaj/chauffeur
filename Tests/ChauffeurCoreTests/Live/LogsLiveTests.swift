import Foundation
import Testing

@testable import ChauffeurCore

@Suite(.enabled(if: Live.enabled), .serialized)
@MainActor struct LogsLiveTests {
    func launched() throws -> Session {
        let s = Session(udid: Live.udid!)
        #expect(s.run(["install", try Live.buildFixture()]).exit == 0)
        let launch = s.run(["launch", "dev.chauffeur.fixture"])
        #expect(launch.exit == 0, "\(launch.text)")
        return s
    }

    @Test func actionResultsCarryTheAppsErrorLines() throws {
        let s = try launched()
        defer { s.shutdown() }
        let out = s.run(["tap", try ref(s, "Log errors")])
        #expect(out.exit == 0, "\(out.text)")
        #expect(out.text.contains("\nlogs: [error] \"fixture: error 1\""), "\(out.text)")
        #expect(out.text.contains("(1 more: chauffeur logs --since-last --level error)"), "\(out.text)")
        let logs = s.run(["logs", "--since-last", "--level", "error"])
        #expect(logs.exit == 0 && logs.text.contains("[error] \"fixture: error 4\""), "\(logs.text)")
        #expect(logs.text.contains(" · full log: /"), "\(logs.text)")
    }

    @Test func aCrashIsReportedAtOnceAndItsReportLater() throws {
        let s = try launched()
        defer { s.shutdown() }
        let out = s.run(["tap", try ref(s, "button:Crash")])
        #expect(out.exit == 5, "\(out.text)")
        #expect(out.text.contains("\nAPP CRASHED: dev.chauffeur.fixture (pid "), "\(out.text)")
        #expect(out.text.contains("[fault] \"fixture: crashing\""), "\(out.text)")
        #expect(s.run(["snapshot"]).exit == 0, "a crash is reported once")
        // macOS wrote reports 17–70 s after a crash on the 8 GB Mac: poll `logs` for up to 3 minutes.
        let deadline = Date().addingTimeInterval(180)
        var logs = s.run(["logs"])
        while Date() < deadline, !logs.text.contains("\nreport: /") {
            sleep(5)
            logs = s.run(["logs"])
        }
        #expect(logs.text.contains("\nreport: /") && logs.text.contains("EXC_BREAKPOINT"), "\(logs.text)")
    }

    @Test func terminatingIsNotACrash() throws {
        let s = try launched()
        defer { s.shutdown() }
        let out = s.run(["terminate", "dev.chauffeur.fixture"])
        #expect(out.exit == 0 && !out.text.contains("APP CRASHED") && !out.text.contains("APP EXITED"), "\(out.text)")
        #expect(s.run(["snapshot"]).exit == 0)
    }
}
