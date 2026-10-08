import Testing
@testable import ChauffeurCore

@Suite struct AXHealthTests {
    let none = AXHealth.Plan(enableFlags: [], restartBridge: false, relaunchApp: false)

    @Test func aSlowLaunchIsNotAnIllness() {
        let p = AXHealth.plan(noTreeForMs: 3999, frontmostIsEmptyApp: false, screenAnswers: true, flagsOff: [], msSinceBridgeRestart: nil)
        #expect(p == none)
    }

    /// Frontmost answers nothing while a hit-test on screen still answers: the bridge is poisoned (2026-10-07 root cause).
    @Test func aPoisonedBridgeIsRestarted() {
        let p = AXHealth.plan(noTreeForMs: 5000, frontmostIsEmptyApp: false, screenAnswers: true, flagsOff: [], msSinceBridgeRestart: nil)
        #expect(p == AXHealth.Plan(enableFlags: [], restartBridge: true, relaunchApp: false))
    }

    /// Final review I1: an app still launching has nothing on screen to hit-test yet; restarting the bridge won't help.
    @Test func aLaunchThatOutlastsThePatienceIsNotRestarted() {
        let p = AXHealth.plan(noTreeForMs: 9000, frontmostIsEmptyApp: false, screenAnswers: false, flagsOff: [], msSinceBridgeRestart: nil)
        #expect(p == none)
    }

    @Test func atMostOneRestartAMinute() {
        let soon = AXHealth.plan(noTreeForMs: 9000, frontmostIsEmptyApp: false, screenAnswers: true, flagsOff: [], msSinceBridgeRestart: 59_999)
        #expect(!soon.restartBridge)
        let later = AXHealth.plan(noTreeForMs: 9000, frontmostIsEmptyApp: false, screenAnswers: true, flagsOff: [], msSinceBridgeRestart: 60_000)
        #expect(later.restartBridge)
    }

    /// Final review I5 (seen live 2026-10-07): an app started while the flags were off is an empty application element
    /// with nothing to hit-test. Only a relaunch helps, whether or not the flags are back on by now.
    @Test func anAppWithoutAnAccessibilityServerNeedsARelaunchNotARestart() {
        let p = AXHealth.plan(noTreeForMs: 5000, frontmostIsEmptyApp: true, screenAnswers: false, flagsOff: [], msSinceBridgeRestart: nil)
        #expect(p == AXHealth.Plan(enableFlags: [], restartBridge: false, relaunchApp: true))
    }

    @Test func flagsAreTurnedOnWheneverTheyAreOffAndTheAppNeedsARelaunch() {
        let p = AXHealth.plan(noTreeForMs: 5000, frontmostIsEmptyApp: false, screenAnswers: true, flagsOff: ["AutomationEnabled"], msSinceBridgeRestart: nil)
        #expect(p == AXHealth.Plan(enableFlags: ["AutomationEnabled"], restartBridge: false, relaunchApp: true))
    }

    /// Nothing answers at all: the simulator itself is not answering (booting, starved); wait.
    @Test func nothingAnswersMeansWait() {
        let p = AXHealth.plan(noTreeForMs: 20_000, frontmostIsEmptyApp: false, screenAnswers: false, flagsOff: [], msSinceBridgeRestart: nil)
        #expect(p == none)
    }

    /// Final review I6: "no tree for 4 s" means failures back to back (the next attempt began within 2 s of the last
    /// failure), not since the first failure ever. An attempt itself takes seconds, so the gap ends where it began.
    @Test func aGapBetweenFailuresStartsANewEpisode() {
        #expect(AXHealth.episodeStart(current: nil, lastFailureMs: nil, attemptStartedMs: 9000, nowMs: 10_000) == 10_000)
        #expect(AXHealth.episodeStart(current: 10_000, lastFailureMs: 11_000, attemptStartedMs: 11_700, nowMs: 14_900) == 10_000)
        #expect(AXHealth.episodeStart(current: 10_000, lastFailureMs: 11_000, attemptStartedMs: 39_000, nowMs: 40_000) == 40_000)
    }

    @Test func messagesSayWhatHappened() {
        let restart = AXHealth.Plan(enableFlags: [], restartBridge: true, relaunchApp: false)
        #expect(AXHealth.message(restart, recovered: true)
            == "the simulator's accessibility bridge had stopped answering; chauffeur restarted it")
        #expect(AXHealth.message(restart, recovered: false).hasPrefix("no accessibility tree even after restarting"))
        let relaunch = AXHealth.Plan(enableFlags: ["AutomationEnabled"], restartBridge: false, relaunchApp: true)
        #expect(AXHealth.message(relaunch, recovered: false).contains("relaunch it: chauffeur launch <bundle>"))
        #expect(AXHealth.message(relaunch, recovered: false).contains("AutomationEnabled"))
    }
}
