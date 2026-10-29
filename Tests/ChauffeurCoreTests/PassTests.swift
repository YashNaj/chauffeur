import Foundation
import Testing

@testable import ChauffeurCore

/// The evidence passes on their own (Task 16a), over a context built from a scripted session, and the shot that runs
/// after them. Frames: see `Act`'s reads per observe.
@Suite @MainActor struct PassTests {
    /// A tap on "Login" that changed nothing, as `SessionNetworkTests.report` builds one.
    static func noEffect(requests: [RequestItem] = []) -> ActionReport {
        var r = ActionReport(
            action: "tap e4 \"Login\"", outcome: .noEffect, evidence: .app("dev.chauffeur.fixture"), settledMs: 400,
            settled: true, revBefore: 3, revAfter: 3, diff: [], transport: "digitizer", retriedFrom: nil,
            hints: Verifier.hints(outcome: .noEffect, target: nil), capMs: 1500)
        r.requests = requests
        return r
    }

    /// A tap's network state with no connection to watch, its touch `ago` ms before now.
    static func net(_ rig: ActRig, touchedAgo ago: Int) -> TapNet {
        rig.clock.sleep(ms: ago)
        return TapNet(pids: [], earlier: [], atTouch: [], logCursor: rig.logs.cursor, touchMs: rig.clock.now - ago)
    }

    // NetworkPass

    /// A raw socket sent and not answered within the window: the NO EFFECT becomes PENDING, and is kept for `wait`.
    @Test func aRawSocketWaitingIsPending() throws {
        let rig = ActRig(frames: [try Act.home()], flows: [[], [], [Act.waiting]])
        let before = try rig.s.observe(minMs: 0, capMs: 1500).snapshot
        let net = rig.s.tapNet(rig.s.netStart())
        var r = Self.noEffect()
        try NetworkPass().apply(to: &r, context: rig.context(before: before, net: net), session: rig.s)
        #expect(r.outcome == .pending && r.exitCode == .pending)
        #expect(r.render().hasPrefix("tap e4 \"Login\" → PENDING · 127.0.0.1:8765 · sent 58 B, no reply after 2."))
        #expect(rig.s.pendingTap != nil)
    }

    @Test func withoutANetworkThePassDoesNothing() throws {
        let rig = ActRig(frames: [try Act.home()], flows: [[Act.waiting]])
        let before = try rig.s.observe(minMs: 0, capMs: 1500).snapshot
        var r = Self.noEffect()
        let started = rig.clock.now
        try NetworkPass().apply(to: &r, context: rig.context(before: before), session: rig.s)
        #expect(r.outcome == .noEffect && r.requests.isEmpty && r.networkNote == nil)
        #expect(rig.clock.now == started)
    }

    // ScreenAgainPass

    /// A reply that is not telemetry: the screen is judged again, and the change is credited with the time since the
    /// touch (convention 1).
    @Test func aReplyThenAChangeIsCreditedFromTheTouch() throws {
        let home = try Act.home()
        let rig = ActRig(frames: [home, home, try Act.form()])
        let before = try rig.s.observe(minMs: 0, capMs: 1500).snapshot
        let net = Self.net(rig, touchedAgo: 600)
        var r = Self.noEffect(requests: [ReportFixtures.fail])
        try ScreenAgainPass().apply(to: &r, context: rig.context(before: before, net: net), session: rig.s)
        let form = try #require(rig.s.last)
        #expect(r.outcome == .changed)
        #expect(form.hash != before.hash)
        #expect(r.diff == Diff.lines(from: before, to: form))
        #expect(r.revAfter == form.rev)
        #expect(r.settledMs == rig.clock.now - net.touchMs)
        #expect(r.hints == [])
    }

    /// The pass-level twin of `SessionUpgradeTests.aTelemetryOnlyReplyIsNotJudgedAgain`: the form behind a telemetry
    /// reply is never looked at.
    @Test func aTelemetryReplyIsNotJudgedAgain() throws {
        let home = try Act.home()
        let rig = ActRig(frames: [home, home, try Act.form()])
        let before = try rig.s.observe(minMs: 0, capMs: 1500).snapshot
        let rev = rig.s.rev
        var r = Self.noEffect(requests: [ReportFixtures.ping])
        try ScreenAgainPass().apply(
            to: &r, context: rig.context(before: before, net: Self.net(rig, touchedAgo: 600)), session: rig.s)
        #expect(r.outcome == .noEffect)
        #expect(rig.s.rev == rev)
    }

    // The shot: `capture` calls the shell before it loads the file, so offline the shell call is the evidence.

    static func shots(_ rig: ActRig) -> Int {
        rig.shell.calls.filter { $0.prefix(3) == ["io", rig.s.udid, "screenshot"] }.count
    }

    @Test func aPlainNoEffectTakesOneShot() throws {
        let home = try Act.home()
        let rig = ActRig(frames: [home])
        let out = rig.s.run(["tap", try Act.ref(home, "Show alert")])
        #expect(out.exit == ExitCode.noEffect.rawValue, "\(out.text)")
        #expect(Self.shots(rig) == 1)
    }

    /// The `SessionUpgradeTests.aReplyThenAChangeIsJudgedAgain` rig: the passes credit the change before the shot.
    @Test func aScreenJudgedAgainTakesNoShot() throws {
        let home = try Act.home()
        let rig = ActRig(
            frames: Array(repeating: home, count: 7) + [try Act.form()], flows: [[], [], [Act.waiting], [Act.done]])
        let out = rig.s.run(["tap", try Act.ref(home, "Show alert")])
        #expect(out.exit == 0, "\(out.text)")
        #expect(Self.shots(rig) == 0)
    }
}
