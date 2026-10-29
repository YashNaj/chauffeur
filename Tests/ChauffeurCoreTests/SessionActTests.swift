import Foundation
import Testing

@testable import ChauffeurCore

/// `act` offline (Task 12): how a tap is classified from the screen and the touch log, how delivery is retried and the
/// input device rebuilt, and a touch that landed in another app. Frames: see `Act`'s reads per observe.
@Suite @MainActor struct SessionActTests {
    @Test func aChangeOnTheNextFrameIsCredited() throws {
        let home = try Act.home()
        let showAlert = try Act.ref(home, "Show alert")
        // Baseline 4 reads of home, then the act's observe sees the form.
        let rig = ActRig(frames: [home, home, home, home, try Act.form()])
        let out = rig.s.run(["tap", showAlert])
        #expect(
            out.exit == 0 && out.text.hasPrefix("tap \(showAlert) \"Show alert\" → changed · settled"), "\(out.text)")
        #expect(rig.inputs.resetCount == 0)
    }

    @Test func noTouchEvidenceRetriesOnTheNextTransportThenNotDelivered() throws {
        let home = try Act.home()
        let showAlert = try Act.ref(home, "Show alert")
        let inputs = FakeInputs()
        let rig = ActRig(
            frames: [home], touches: ScriptedTouches(evidence: [.none, .none], attached: true), inputs: inputs)
        let out = rig.s.run(["tap", showAlert])
        #expect(out.text.contains("NOT DELIVERED · retried via mouse"), "\(out.text)")
        #expect(inputs.fakes.map(\.touches.count) == [2, 2])
    }

    @Test func anUnattachedTouchLogIsUnverified() throws {
        let home = try Act.home()
        let showAlert = try Act.ref(home, "Show alert")
        let rig = ActRig(frames: [home], touches: ScriptedTouches(evidence: [], attached: false))
        let out = rig.s.run(["tap", showAlert])
        #expect(
            ActRig.head(out)
                == "tap \(showAlert) \"Show alert\" → UNVERIFIED: no visible change (touch log unavailable)",
            "\(out.text)")
        #expect(out.exit == ExitCode.noEffect.rawValue)
        #expect(rig.touches.requests.isEmpty)
    }

    @Test func aFailedSendDropsTheClientAndRebuildsIt() throws {
        let home = try Act.home()
        let showAlert = try Act.ref(home, "Show alert")
        let inputs = FakeInputs(transports: [
            FakeTransport(name: "digitizer", supportsMove: true, sends: false),
            FakeTransport(name: "mouse", supportsMove: false, sends: false),
        ])
        let rig = ActRig(frames: [home], inputs: inputs)
        let out = rig.s.run(["tap", showAlert])
        #expect(out.text.contains("NOT DELIVERED"), "\(out.text)")
        #expect(inputs.resetCount == 1)
    }

    @Test func theTransportOrderStartsOverAfterAFailedSend() throws {
        let home = try Act.home()
        let showAlert = try Act.ref(home, "Show alert")
        let inputs = FakeInputs()
        let (digitizer, mouse) = (inputs.fakes[0], inputs.fakes[1])
        // Tap 1: the digitizer's touch leaves no evidence and the mouse's reaches the app; later touches hold that.
        let rig = ActRig(
            frames: [home], touches: ScriptedTouches(evidence: [.none, .app(Act.fixtureBundle)], attached: true),
            inputs: inputs)
        let first = rig.s.run(["tap", showAlert])
        #expect(first.text.contains("NO EFFECT"), "\(first.text)")
        #expect(inputs.fakes.map(\.touches.count) == [2, 2])
        #expect(rig.s.preferred == 1)
        #expect(inputs.resetCount == 0)

        // Tap 2: both sends fail, so the client is dropped.
        digitizer.sends = false
        mouse.sends = false
        let second = rig.s.run(["tap", showAlert])
        #expect(second.text.contains("NOT DELIVERED"), "\(second.text)")
        #expect(inputs.resetCount == 1)

        // Tap 3: the rebuilt device starts on its first transport, the digitizer, which delivers.
        digitizer.sends = true
        mouse.sends = true
        let touched = (digitizer: digitizer.touches.count, mouse: mouse.touches.count)
        let third = rig.s.run(["tap", showAlert])
        #expect(digitizer.touches.count == touched.digitizer + 2, "\(third.text)")
        #expect(mouse.touches.count == touched.mouse, "\(third.text)")
    }

    @Test func aTouchThatLandedInAnotherAppIsIntercepted() throws {
        let home = try Act.home()
        let showAlert = try Act.ref(home, "Show alert")
        let udid = Act.udid()
        let rig = ActRig(
            frames: [home], udid: udid,
            touches: ScriptedTouches(evidence: [.app("com.apple.springboard")], attached: true),
            shell: RecordingShell(replies: Act.launchReplies(udid: udid)), processes: FakeProcesses(alive: [4321]))
        defer { TrackedApp.clear(StatePaths.app(rig.s.udid)) }
        let launched = rig.s.run(["launch", Act.fixtureBundle])
        #expect(
            launched.exit == 0 && launched.text.hasPrefix("launch dev.chauffeur.fixture → running (pid 4321)"),
            "\(launched.text)")
        let out = rig.s.run(["tap", showAlert])
        #expect(out.text.contains("INTERCEPTED by com.apple.springboard"), "\(out.text)")
    }

    @Test func theSwitchIsTappedAgainWhenTheFirstTouchWasIgnored() throws {
        let form = try Act.form()
        let agree = try Act.ref(form, "Agree to terms")
        // Baseline 4, the first act 3, the second baseline 2 (the screen has been quiet), then the second act sees on.
        let rig = ActRig(
            frames: Array(repeating: form, count: 9) + [try Act.formOn()],
            touches: ScriptedTouches(evidence: [.app(Act.fixtureBundle), .app(Act.fixtureBundle)], attached: true))
        _ = rig.s.run(["tap", agree])
        #expect(rig.touches.requests.count == 2)
        #expect(rig.inputs.fakes[0].touches.map { $0.1 } == [.down, .up, .down, .up])
    }

    /// A classifier that asks for `.retry` on the last transport too (`TouchClassifier` never does): the attempt is
    /// NOT DELIVERED, with `Verifier`'s hints, and the transport is not preferred. One transport: the only one that moves.
    @Test func aRetryOnTheLastTransportIsNotDelivered() throws {
        let inputs = FakeInputs(transports: [
            FakeTransport(name: "mouse", supportsMove: false), FakeTransport(name: "digitizer", supportsMove: true),
        ])
        let rig = ActRig(frames: [try Act.home()], inputs: inputs)
        let before = try rig.s.observe(minMs: 0, capMs: 1500).snapshot
        let report = try rig.s.act("drag", target: nil, before: before, needsMove: true, classifier: AlwaysRetry()) {
            _ in true
        }
        #expect(report.outcome == .notDelivered)
        #expect(report.hints == Verifier.hints(outcome: .notDelivered, target: nil))
        #expect(rig.s.preferred == 0)
    }
}

/// Asks for another transport every time.
private struct AlwaysRetry: Classifier {
    func classify(context: ActionContext, attempt: Attempt) throws -> (report: ActionReport, after: Snapshot) {
        let report = ActionReport(
            action: context.label, outcome: .retry, evidence: .none, settledMs: 0, settled: true,
            revBefore: context.before.rev, revAfter: context.before.rev, diff: [], transport: attempt.transport,
            retriedFrom: attempt.retriedFrom, hints: [], capMs: context.capMs)
        return (report, context.before)
    }
}
