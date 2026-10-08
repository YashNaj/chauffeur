import Foundation
import Testing

@testable import ChauffeurCore

@MainActor
func ref(_ session: Session, _ query: String) throws -> String {
    _ = session.run(["snapshot"])
    return try #require(session.last?.find(query).first?.ref, "no ref for \(query)")
}

@Suite(.enabled(if: Live.enabled), .serialized)
@MainActor struct SessionLiveTests {
    @Test func snapshotFindWait() throws {
        try Live.launchFixture()
        let session = Session(udid: Live.udid!)
        defer { session.shutdown() }
        #expect(session.run(["wait", "Show alert", "--timeout", "15"]).exit == 0)
        let snap = session.run(["snapshot"])
        #expect(snap.exit == 0)
        #expect(snap.text.hasPrefix("app \"Fixture\""))
        #expect(snap.text.contains("button \"Show alert\" [e"))
        #expect(snap.text.contains("group \"Tab Bar\"\n  tab"))  // bar sweep filled the tab bar (tabs: Task 10 ruling)
        #expect(session.run(["find", "button:alert"]).text.split(separator: "\n").count == 1)
        let missing = session.run(["wait", "No such thing", "--timeout", "1"])
        #expect(missing.exit == 4 && missing.text.hasPrefix("not found after 1s"))
        // An unchanged screen keeps its rev (launch-time changes may already have moved it past 1).
        let first = session.run(["snapshot"]).text.split(separator: "\n")[0]
        let second = session.run(["snapshot"]).text.split(separator: "\n")[0]
        #expect(first == second)
    }

    @Test func survivesASimulatorReboot() throws {
        let udid = Live.udid!
        try Live.launchFixture()
        let session = Session(udid: udid)
        defer { session.shutdown() }
        #expect(session.run(["snapshot"]).exit == 0)
        try SimCtl.run(["shutdown", udid], timeout: 120)
        let down = session.run(["snapshot"])
        #expect(down.exit == 1 && down.text.contains("is not booted"))
        try SimCtl.run(["boot", udid], timeout: 120)
        try SimCtl.run(["bootstatus", udid], timeout: 300)
        try Live.launchFixture()
        #expect(session.run(["wait", "Show alert", "--timeout", "30"]).exit == 0)
    }
}
