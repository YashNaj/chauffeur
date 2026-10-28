import Foundation
import Testing

@testable import ChauffeurCore

/// `type` and `type --submit` offline (Task 12): the focus tap, the paste path, the secure paste's cleanup, and what
/// Return did. Frames: baseline 4 reads, the focus tap's act 3, then the typed field (see `Act`'s reads per observe).
@Suite @MainActor struct SessionTypeTests {
    let longText = "alice@example.com"  // 17 characters: more than 15, so it is pasted

    func typedFrames(_ after: [AXElement]) throws -> [AXElement] {
        Array(repeating: try Act.form(), count: 7) + after
    }

    @Test func aLongTextIsPastedWithCommandV() throws {
        let email = try Act.ref(try Act.form(), "email")
        let udid = Act.udid()
        let rig = ActRig(frames: try typedFrames([try Act.formTyped()]), udid: udid)
        let out = rig.s.run(["type", email, longText])
        #expect(out.exit == 0 && out.text.contains("typed via paste"), "\(out.text)")
        #expect(
            rig.shell.recorded.contains { $0.args == ["pbcopy", udid] && $0.stdin == longText },
            "\(rig.shell.calls)")
        #expect(rig.inputs.keyboard.pressed.map(\.usage) == [Keys.v])
        #expect(rig.inputs.keyboard.pressed.map(\.modifiers) == [[Keys.command]])
        #expect(rig.inputs.keyboard.typed.isEmpty)
    }

    @Test func submitThatChangesTheScreen() throws {
        let email = try Act.ref(try Act.form(), "email")
        let typed = try Act.formTyped()
        // The typed field settles on 3 reads, then Return lands on home.
        let rig = ActRig(frames: try typedFrames([typed, typed, typed, try Act.home()]))
        let out = rig.s.run(["type", email, longText, "--submit"])
        #expect(out.exit == 0, "\(out.text)")
        #expect(rig.inputs.keyboard.pressed.map(\.usage) == [Keys.v, Keys.returnKey])
        Golden.check("sessions/type-submit-changed.txt", out.text)
    }

    @Test func submitThatChangesNothing() throws {
        let email = try Act.ref(try Act.form(), "email")
        let rig = ActRig(frames: try typedFrames([try Act.formTyped()]))
        let out = rig.s.run(["type", email, longText, "--submit"])
        #expect(out.exit == ExitCode.noEffect.rawValue, "\(out.text)")
        Golden.check("sessions/type-submit-noeffect.txt", out.text)
    }

    @Test func submitWhoseReturnFailsToSend() throws {
        let email = try Act.ref(try Act.form(), "email")
        // The paste's ⌘V sends; Return does not.
        let inputs = FakeInputs(keyboard: FakeTextInput(presses: [true, false]))
        let rig = ActRig(frames: try typedFrames([try Act.formTyped()]), inputs: inputs)
        let out = rig.s.run(["type", email, longText, "--submit"])
        #expect(out.exit == 3, "\(out.text)")
        Golden.check("sessions/type-submit-notdelivered.txt", out.text)
    }

    @Test func aSecurePasteIsCountedClearedAndRedacted() throws {
        let password = try Act.ref(try Act.form(), "password")
        let secret = "correct horse battery"  // 21 characters
        let udid = Act.udid()
        let rig = ActRig(frames: try typedFrames([try Act.formSecure()]), udid: udid)
        let out = rig.s.run(["type", password, secret])
        #expect(out.exit == 0, "\(out.text)")
        #expect(out.text.hasPrefix("type \(password) (21 characters) → "), "\(out.text)")
        #expect(!out.text.contains(secret))
        #expect(rig.shell.recorded.filter { $0.args == ["pbcopy", udid] }.map(\.stdin) == [secret, ""])
        #expect(rig.s.traceArgs == Session.redactedType(ref: password, characters: 21, submit: false))
    }

    @Test func aFocusTapThatReachesNothingTypesNothing() throws {
        let email = try Act.ref(try Act.form(), "email")
        let rig = ActRig(
            frames: [try Act.form()], touches: ScriptedTouches(evidence: [.none, .none], attached: true))
        let out = rig.s.run(["type", email, longText])
        #expect(
            out.exit == ExitCode.noEffect.rawValue
                && out.text.hasPrefix("type \(email) \"\(longText)\" → not typed: focusing the field failed\n"),
            "\(out.text)")
        #expect(rig.inputs.keyboard.pressed.isEmpty && rig.inputs.keyboard.typed.isEmpty)
        #expect(!rig.shell.calls.contains { $0.first == "pbcopy" })
    }

    @Test func aSwitchIsNotATextField() throws {
        let form = try Act.form()
        let agree = try Act.ref(form, "Agree to terms")
        let rig = ActRig(frames: [form])
        let out = rig.s.run(["type", agree, "hello"])
        #expect(out.exit == ExitCode.error.rawValue && out.text.contains("not a text field"), "\(out.text)")
        #expect(rig.touches.requests.isEmpty)
    }
}
