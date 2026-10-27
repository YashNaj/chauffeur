import Testing

@testable import ChauffeurCore

/// M4b spec §9 and §3 ("Batches").
@Suite @MainActor struct WaitTests {
    func session() -> Session {
        Session(udid: "ZZ" + String(format: "%06X", UInt32.random(in: 0...0xFFFFFF)) + "-TEST")
    }

    @Test func aBareWaitWithNothingPendingSaysSo() {
        let out = session().run(["wait"])
        #expect(out.exit == 1)
        #expect(out.text.hasPrefix("nothing to wait for: no tap came back PENDING"))
    }

    @Test func goneNeedsAQuery() {
        #expect(session().run(["wait", "--gone"]).exit == 64)
    }

    @Test func aPendingStepIsFinishedBeforeTheBatchJudgesIt() {
        let pending = Output("tap e4 → PENDING · a still running after 2.1 s", exit: 6)
        let out = Session.throughPending(pending) { Output("tap e4 → changed · settled 300ms · rev 3→4") }
        #expect(out.exit == 0)
        #expect(
            out.text == "tap e4 → PENDING · a still running after 2.1 s\ntap e4 → changed · settled 300ms · rev 3→4")
        let plain = Output("tap e5 → changed")
        #expect(Session.throughPending(plain) { Output("never", exit: 1) } == plain)
    }

    @Test func aBareWaitHasALongerDefault() {
        #expect(Session.pendingWaitSeconds == 30)
    }
}
