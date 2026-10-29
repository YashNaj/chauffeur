import Foundation
import Testing

@testable import ChauffeurCore

/// Gated by CHAUFFEUR_LIVE_REBOOT as well as the UDID: `scripts/live.sh` runs this suite alone, after the others.
@Suite(.enabled(if: Live.reboot), .serialized)
@MainActor struct RebootLiveTests {
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
        #expect(Live.waitForQuietHost() != nil, "the host did not quiet down after the boot")
    }
}
