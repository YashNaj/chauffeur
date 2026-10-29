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

    // SwitchRetryPass

    /// A plain tap at `node`, as `tapCommand` sends one.
    static func tap(_ rig: ActRig, at node: Node) -> (any TouchTransport) -> Bool {
        let point = Geometry.tapPoint(role: node.role, frame: node.frame)
        return { [clock = rig.clock] in Gestures.tap($0, at: point, screen: Act.screen, clock: clock) }
    }

    /// The switch changed only after the act's 1.5 s: credited with the act's own settle (convention 2), no touch.
    @Test func aLateSwitchIsCreditedWithTheActsSettle() throws {
        let form = try Act.form()
        let rig = ActRig(frames: [form, form, try Act.formOn()])
        let before = try rig.s.observe(minMs: 0, capMs: 1500).snapshot
        let agree = try #require(before.find("Agree to terms").first)
        var r = Self.noEffect()
        r.settledMs = 420
        try SwitchRetryPass().apply(
            to: &r, context: rig.context(before: before, target: agree, gesture: Self.tap(rig, at: agree)),
            session: rig.s)
        #expect(r.outcome == .changed)
        #expect(r.hints == ["the switch changed only after 1.5s"])
        #expect(r.settledMs == 420)
        #expect(r.diff.contains { $0.hasPrefix("- ") && $0.hasSuffix("value=off") }, "\(r.diff)")
        #expect(r.diff.contains { $0.hasPrefix("+ ") && $0.hasSuffix("value=on") }, "\(r.diff)")
        #expect(rig.touches.requests.isEmpty)
        #expect(rig.inputs.fakes.allSatisfy { $0.touches.isEmpty })
    }

    /// The switch ignored the first touch: one more tap, through the pipeline without its shot.
    @Test func anIgnoredSwitchIsTappedOnceMoreWithoutAShot() throws {
        let form = try Act.form()
        // `before` 2 reads, the pass's baseline 4 (the screen changed when `before` was published, so the quiet sleep
        // runs), then the pass's act sees on.
        let rig = ActRig(frames: Array(repeating: form, count: 6) + [try Act.formOn()])
        let before = try rig.s.observe(minMs: 0, capMs: 1500).snapshot
        let agree = try #require(before.find("Agree to terms").first)
        var r = Self.noEffect()
        try SwitchRetryPass().apply(
            to: &r, context: rig.context(before: before, target: agree, gesture: Self.tap(rig, at: agree)),
            session: rig.s)
        #expect(r.outcome == .changed)
        #expect(r.hints.last == "the first touch reached the app but the switch ignored it; chauffeur tapped once more")
        #expect(rig.inputs.fakes[0].touches.count == 2)
        #expect(Self.shots(rig) == 0)
    }

    // ClipboardPass

    @Test func aChangedPasteboardIsACopy() throws {
        let udid = Act.udid()
        let rig = ActRig(
            frames: [try Act.home()], udid: udid,
            shell: RecordingShell(replies: [["pbpaste", udid]: [Act.out("hello, clipboard")]]))
        let before = try rig.s.observe(minMs: 0, capMs: 1500).snapshot
        var r = Self.noEffect()
        try ClipboardPass(before: ClipboardMark("")).apply(to: &r, context: rig.context(before: before), session: rig.s)
        #expect(r.outcome == .changed)
        #expect(r.copiedCharacters == 16)
        #expect(r.render().prefix { $0 != "\n" }.hasSuffix("→ changed · copied to clipboard (16 characters)"))
    }

    @Test func anUnchangedPasteboardLeavesTheReport() throws {
        let udid = Act.udid()
        let rig = ActRig(
            frames: [try Act.home()], udid: udid,
            shell: RecordingShell(replies: [["pbpaste", udid]: [Act.out("hello, clipboard")]]))
        let before = try rig.s.observe(minMs: 0, capMs: 1500).snapshot
        var r = Self.noEffect()
        try ClipboardPass(before: ClipboardMark("hello, clipboard")).apply(
            to: &r, context: rig.context(before: before), session: rig.s)
        #expect(r.outcome == .noEffect)
        #expect(r.copiedCharacters == nil)
        #expect(r.hints == Self.noEffect().hints)
    }

    // TypingNetworkPass

    /// One look after the grace, no window.
    @Test func typingLooksOnceAfterTheGrace() throws {
        let rig = ActRig(frames: [try Act.form()], flows: [[], [], [Act.done]])
        _ = try rig.s.observe(minMs: 0, capMs: 1500)  // connected: the app in front is the one watched
        var report = TypeReport(
            action: "type e2 \"alice\"", method: "keys", verdict: .ok, value: "alice", settledMs: 150)
        let net = rig.s.tapNet(rig.s.netStart())
        let t = rig.clock.now
        TypingNetworkPass().apply(to: &report, net: net, session: rig.s)
        #expect(rig.clock.now == t + NetJudge.graceMs)
        #expect(report.requests.count == 1)
        #expect(report.requestElapsedMs == NetJudge.graceMs)
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

    // The order: passes first, the shot last, so a NO EFFECT a pass upgraded never carries one.

    /// The `SessionUpgradeTests.aCopyWithARequestKeepsTheRequest` rig.
    @Test func aCopyTakesNoShot() throws {
        let home = try Act.home()
        let udid = Act.udid()
        let rig = ActRig(
            frames: [home], udid: udid,
            shell: RecordingShell(replies: [["pbpaste", udid]: [Act.out(""), Act.out("hello, clipboard")]]),
            flows: [[], [], [Act.done]])
        let out = rig.s.run(["tap", try Act.ref(home, "Show alert")])
        #expect(out.exit == 0, "\(out.text)")
        #expect(Self.shots(rig) == 0)
    }

    /// The `SessionUpgradeTests.anIgnoredSwitchIsTappedOnceMore` rig, the switch never on: two acts, one shot.
    @Test func aSwitchTappedTwiceTakesOneShot() throws {
        let form = try Act.form()
        let rig = ActRig(
            frames: [form],
            touches: ScriptedTouches(evidence: [.app(Act.fixtureBundle), .app(Act.fixtureBundle)], attached: true))
        let out = rig.s.run(["tap", try Act.ref(form, "Agree to terms")])
        #expect(out.exit == ExitCode.noEffect.rawValue, "\(out.text)")
        #expect(rig.inputs.fakes[0].touches.count == 4)
        #expect(Self.shots(rig) == 1)
    }
}
