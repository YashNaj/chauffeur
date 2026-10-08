import Foundation
import Testing

@testable import ChauffeurCore

@Suite(.enabled(if: Live.enabled), .serialized)
@MainActor struct TypeLiveTests {
    @Test func formFlow() throws {
        try Live.launchFixture()
        let s = Session(udid: Live.udid!)
        defer { s.shutdown() }
        #expect(s.run(["wait", "Show alert", "--timeout", "15"]).exit == 0)
        #expect(s.run(["tap", try ref(s, "tab:Form")]).exit == 0)

        let email = try ref(s, "textfield:email")
        let typed = s.run(["type", email, "Ab@1.test_X"])
        #expect(typed.exit == 0 && typed.text.contains("typed via keys · value=\"Ab@1.test_X\""), "\(typed.text)")

        let unicode = s.run(["type", email, " café 🚕"])
        #expect(unicode.exit == 0 && unicode.text.contains("typed via paste"), "\(unicode.text)")

        let password = s.run(["type", try ref(s, "securefield:"), "hunter2"])
        #expect(password.exit == 0, "\(password.text)")
        #expect(!password.text.contains("hunter2"))

        let notAField = s.run(["type", try ref(s, "button:Submit"), "x"])
        #expect(notAField.exit == 1 && notAField.text.contains("not a text field"))

        let agree = s.run(["tap", try ref(s, "switch:Agree")])
        #expect(agree.text.contains("value=on"), "\(agree.text)")
        let submit = s.run(["tap", try ref(s, "button:Submit")])
        #expect(submit.exit == 0 && submit.text.contains("Submitted: Ab@1.test_X café 🚕"), "\(submit.text)")
    }

    /// F1 (M2 dogfood): `type` into Email, then tap the "Agree to terms" switch in the same batch, keyboard still up.
    @Test func aSwitchTapAfterTypingToggles() throws {
        try Live.launchFixture()
        let s = Session(udid: Live.udid!)
        defer { s.shutdown() }
        #expect(s.run(["wait", "Show alert", "--timeout", "15"]).exit == 0)
        let form = s.run(["tap", try ref(s, "tab:Form")])
        #expect(form.exit == 0, "\(form.text)")
        let email = try ref(s, "textfield:email")
        let agree = try ref(s, "switch:Agree")
        let r = s.run(["do", "type \(email) \"dogfood@example.com\"; tap \(agree)"])
        #expect(r.text.contains("value=off") && r.text.contains("value=on"), "\(r.text)")
    }
}
