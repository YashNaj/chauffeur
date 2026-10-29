import Foundation
import Testing

@testable import ChauffeurCore

/// The classify step on its own (Task 15): what an action without a touch and a touch are called, from the screen and
/// the touch log, over a context for a scripted session. Frames: see `Act`'s reads per observe.
@Suite @MainActor struct ClassifierTests {
    static let note = "the URL was delivered; nothing visible changed in 3s"
    static let hints = ["the app may handle this link without a visible change; run snapshot to check"]

    @Test func noTouchCreditsATreeThatChanges() throws {
        let home = try Act.home()
        let rig = ActRig(frames: [home, home, try Act.form()])
        let before = try rig.s.observe(minMs: 0, capMs: 1500).snapshot
        let report = try NoTouchClassifier(note: Self.note, hints: Self.hints)
            .classify(context: rig.context(before: before, capMs: 3000), attempt: .noTouch, session: rig.s)
        #expect(report.outcome == .changed)
        #expect(!report.diff.isEmpty)
        #expect(report.transport == "none")
        #expect(report.evidence == .unavailable)
        #expect(rig.s.last?.hash != before.hash)
    }

    /// A change on a screen that was not settled when the action began cannot be pinned on the action.
    @Test func noTouchOnAnUnsettledBaselineIsUnattributed() throws {
        let home = try Act.home()
        let rig = ActRig(frames: [home, home, try Act.form()])
        let before = try rig.s.observe(minMs: 0, capMs: 1500).snapshot
        let report = try NoTouchClassifier(note: Self.note, hints: Self.hints)
            .classify(
                context: rig.context(before: before, capMs: 3000, baselineSettled: false), attempt: .noTouch,
                session: rig.s)
        #expect(report.outcome == .unattributed)
        #expect(report.diff.isEmpty)
        #expect(report.transport == "none")
        #expect(report.evidence == .unavailable)
        #expect(report.hints == Verifier.hints(outcome: .unattributed, target: nil))
        #expect(rig.s.last?.hash != before.hash)
    }

    @Test func noTouchIsUnverifiedOnceTheCapRunsOut() throws {
        let rig = ActRig(frames: [try Act.home()])
        let before = try rig.s.observe(minMs: 0, capMs: 1500).snapshot
        let started = rig.clock.now
        let report = try NoTouchClassifier(note: Self.note, hints: Self.hints)
            .classify(context: rig.context(before: before, capMs: 3000), attempt: .noTouch, session: rig.s)
        #expect(report.outcome == .unverified)
        #expect(rig.clock.now - started >= 3000)
        #expect(report.note == Self.note)
        #expect(report.hints == Self.hints)
    }

    static func sent(isLast: Bool, sent: Bool = true) -> Attempt {
        Attempt(sent: sent, touchCursor: 0, transport: "digitizer", retriedFrom: nil, isLast: isLast)
    }

    @Test func aTouchTheAppGotWithNoChangeIsNoEffect() throws {
        let home = try Act.home()
        let rig = ActRig(frames: [home])
        let before = try rig.s.observe(minMs: 0, capMs: 1500).snapshot
        let report = try TouchClassifier().classify(
            context: rig.context(before: before), attempt: Self.sent(isLast: false), session: rig.s)
        #expect(report.outcome == .noEffect)
        #expect(report.transport == "digitizer")
    }

    @Test func noTouchEvidenceIsRetryWhileATransportIsLeftThenNotDelivered() throws {
        let home = try Act.home()
        let rig = ActRig(frames: [home], touches: ScriptedTouches(evidence: [], attached: true))
        let before = try rig.s.observe(minMs: 0, capMs: 1500).snapshot
        let context = rig.context(before: before)
        let retry = try TouchClassifier().classify(context: context, attempt: Self.sent(isLast: false), session: rig.s)
        #expect(retry.outcome == .retry)
        let last = try TouchClassifier().classify(context: context, attempt: Self.sent(isLast: true), session: rig.s)
        #expect(last.outcome == .notDelivered)
        #expect(last.hints == ["input transport unhealthy — run `chauffeur doctor --live`"])
    }

    @Test func anUnattachedTouchLogIsUnverifiedWithoutAsking() throws {
        let home = try Act.home()
        let rig = ActRig(frames: [home], touches: ScriptedTouches(evidence: [], attached: false))
        let before = try rig.s.observe(minMs: 0, capMs: 1500).snapshot
        let report = try TouchClassifier().classify(
            context: rig.context(before: before), attempt: Self.sent(isLast: false), session: rig.s)
        #expect(report.outcome == .unverified)
        #expect(rig.touches.requests.isEmpty)
    }

    /// An observe that reconnects (`drop()`) stops the touch log, so the classifier reads `isAttached` after the screen:
    /// a send that failed during that reconnect is UNVERIFIED, not NOT DELIVERED (Review Focus 1).
    @Test func aTouchLogThatStopsDuringTheObserveIsUnverified() throws {
        let home = try Act.home()
        let rig = ActRig(frames: [home], touches: ScriptedTouches(evidence: [], attached: true))
        let before = try rig.s.observe(minMs: 0, capMs: 1500).snapshot
        rig.ax.onRead = { [touches = rig.touches] in touches.isAttached = false }
        let report = try TouchClassifier().classify(
            context: rig.context(before: before), attempt: Self.sent(isLast: true, sent: false), session: rig.s)
        #expect(report.outcome == .unverified)
        #expect(rig.touches.requests.isEmpty)
    }
}
