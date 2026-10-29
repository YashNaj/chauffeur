import Foundation
import Testing

@testable import ChauffeurCore

/// The four places a tap's NO EFFECT is upgraded, and `finishPending`, pinned line by line (Task 12): Stage 2 rewrites
/// them as evidence passes and must reproduce every line, `settledMs`, the hints and the request lines included.
/// Frames: see `Act`'s reads per observe.
@Suite @MainActor struct SessionUpgradeTests {
    /// `judgeScreenAgain`: a reply arrived inside the window, so the screen is judged again and the change is the tap's.
    @Test func aReplyThenAChangeIsJudgedAgain() throws {
        let home = try Act.home()
        let showAlert = try Act.ref(home, "Show alert")
        // Baseline 4, the NO EFFECT act 3, then the second look sees the form. Flows: netStart, the touch, after the
        // grace (waiting), then every poll and the confirm (done).
        let rig = ActRig(
            frames: Array(repeating: home, count: 7) + [try Act.form()], flows: [[], [], [Act.waiting], [Act.done]])
        let out = rig.s.run(["tap", showAlert])
        #expect(out.exit == 0, "\(out.text)")
        Golden.check("sessions/tap-screen-again.txt", out.text)
    }

    /// The switch changed only after the act's 1.5 s: credited with the first act's settle, never toggled back.
    @Test func aLateSwitchIsCreditedNotTappedAgain() throws {
        let form = try Act.form()
        let agree = try Act.ref(form, "Agree to terms")
        // Baseline 4, the NO EFFECT act 3, then the second baseline sees on.
        let rig = ActRig(frames: Array(repeating: form, count: 7) + [try Act.formOn()])
        let out = rig.s.run(["tap", agree])
        #expect(out.exit == 0, "\(out.text)")
        #expect(rig.touches.requests.count == 1)
        Golden.check("sessions/tap-late-switch.txt", out.text)
    }

    /// The switch ignored the first touch that reached the app: chauffeur taps once more and says so.
    @Test func anIgnoredSwitchIsTappedOnceMore() throws {
        let form = try Act.form()
        let agree = try Act.ref(form, "Agree to terms")
        // Baseline 4, the NO EFFECT act 3, the second baseline 2 (quiet ≥ 500 ms), then the second act sees on.
        let rig = ActRig(
            frames: Array(repeating: form, count: 9) + [try Act.formOn()],
            touches: ScriptedTouches(evidence: [.app(Act.fixtureBundle), .app(Act.fixtureBundle)], attached: true))
        let out = rig.s.run(["tap", agree])
        #expect(out.exit == 0, "\(out.text)")
        #expect(rig.touches.requests.count == 2)
        #expect(rig.inputs.fakes[0].touches.count == 4)
        Golden.check("sessions/tap-second-tap.txt", out.text)
    }

    /// A copy changes nothing on screen; the pasteboard changed, so the tap did, and its request line stays.
    @Test func aCopyWithARequestKeepsTheRequest() throws {
        let home = try Act.home()
        let showAlert = try Act.ref(home, "Show alert")
        let udid = Act.udid()
        let rig = ActRig(
            frames: [home], udid: udid,
            shell: RecordingShell(replies: [["pbpaste", udid]: [Act.out(""), Act.out("hello, clipboard")]]),
            flows: [[], [], [Act.done]])
        let out = rig.s.run(["tap", showAlert])
        #expect(out.exit == 0, "\(out.text)")
        Golden.check("sessions/tap-clipboard-with-requests.txt", out.text)
    }

    /// A PENDING tap, then a bare `wait`: the wait's own observe gives the settle, not the time since the touch.
    @Test func waitFinishesThePendingTap() throws {
        let home = try Act.home()
        let showAlert = try Act.ref(home, "Show alert")
        let form = try Act.form()
        // Baseline 4 reads of home. The PENDING act reads 4: home, a flicker of the form, home, home, so it settles at
        // 225 ms on the unchanged home; the wait's observe then settles on the form in 150 ms. The two settles differ,
        // so the golden's can only be the wait's own (`finishPending` sets it from its observe).
        let rig = ActRig(
            frames: Array(repeating: home, count: 5) + [form, home, home, form], flows: [[], [], [Act.waiting]])
        let tapped = rig.s.run(["tap", showAlert])
        #expect(tapped.exit == ExitCode.pending.rawValue, "\(tapped.text)")
        #expect(
            ActRig.head(tapped).hasPrefix(
                "tap \(showAlert) \"Show alert\" → PENDING · 127.0.0.1:8765 · sent 58 B, no reply after 2."),
            "\(tapped.text)")
        rig.flows.samples = [[Act.done]]
        let out = rig.s.run(["wait"])
        #expect(out.exit == 0, "\(out.text)")
        #expect(rig.s.pendingTap == nil)
        Golden.check("sessions/wait-finishes-pending.txt", out.text)
    }

    // The upgrades do not fire when they should not.

    /// A button is not tapped twice, and a NO EFFECT without a request is not judged again (the form behind it is
    /// never looked at).
    @Test func aButtonsNoEffectIsTappedOnceAndNotJudgedAgain() throws {
        let home = try Act.home()
        let showAlert = try Act.ref(home, "Show alert")
        let rig = ActRig(frames: Array(repeating: home, count: 7) + [try Act.form()])
        let out = rig.s.run(["tap", showAlert])
        #expect(
            ActRig.head(out)
                == "tap \(showAlert) \"Show alert\" → NO EFFECT · the accessibility tree did not change in 1.5s "
                + "(touch reached dev.chauffeur.fixture)",
            "\(out.text)")
        #expect(rig.touches.requests.count == 1)
        #expect(rig.inputs.fakes[0].touches.count == 2)
    }

    @Test func anUnchangedPasteboardStaysNoEffect() throws {
        let home = try Act.home()
        let showAlert = try Act.ref(home, "Show alert")
        let udid = Act.udid()
        let rig = ActRig(
            frames: [home], udid: udid,
            shell: RecordingShell(replies: [["pbpaste", udid]: [Act.out("hello, clipboard")]]))
        let out = rig.s.run(["tap", showAlert])
        #expect(
            ActRig.head(out)
                == "tap \(showAlert) \"Show alert\" → NO EFFECT · the accessibility tree did not change in 1.5s "
                + "(touch reached dev.chauffeur.fixture)",
            "\(out.text)")
        #expect(rig.shell.calls.filter { $0 == ["pbpaste", udid] }.count == 2)
    }

    @Test func aSwitchHeldLongIsNotTappedAgain() throws {
        let form = try Act.form()
        let agree = try Act.ref(form, "Agree to terms")
        let rig = ActRig(frames: Array(repeating: form, count: 7) + [try Act.formOn()])
        let out = rig.s.run(["tap", agree, "--long", "1"])
        #expect(ActRig.head(out).contains(" → NO EFFECT · "), "\(out.text)")
        #expect(rig.touches.requests.count == 1)
    }

    @Test func aBareWaitWithNothingPendingSaysSo() throws {
        let rig = ActRig(frames: [try Act.home()])
        let out = rig.s.run(["wait"])
        #expect(out.exit == ExitCode.error.rawValue && out.text.hasPrefix("nothing to wait for: "), "\(out.text)")
    }
}
