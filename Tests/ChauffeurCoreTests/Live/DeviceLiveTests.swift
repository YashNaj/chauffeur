import Foundation
import Testing

@testable import ChauffeurCore

@Suite(.enabled(if: Live.enabled), .serialized)
@MainActor struct DeviceLiveTests {
    @Test func permissionLocationPushAppearance() throws {
        let s = Session(udid: Live.udid!)
        defer {
            _ = s.run(["appearance", "light"])
            _ = s.run(["location", "clear"])
            s.shutdown()
        }
        #expect(s.run(["install", try Live.buildFixture()]).exit == 0)
        #expect(s.run(["permission", "reset", "location", "dev.chauffeur.fixture"]).exit == 0)
        #expect(s.run(["launch", "dev.chauffeur.fixture"]).exit == 0)

        let granted = s.run(["permission", "grant", "location", "dev.chauffeur.fixture"])
        #expect(
            granted.exit == 0 && granted.text.hasPrefix("permission grant location dev.chauffeur.fixture → granted"),
            "\(granted.text)")
        if s.app == nil { #expect(s.run(["launch", "dev.chauffeur.fixture"]).exit == 0) }  // the change may end the app
        let asked = s.run(["tap", try ref(s, "Request location")])
        #expect(
            asked.exit == 0 && !asked.text.contains("system alert"), "granted in advance, so no prompt:\n\(asked.text)")
        #expect(!s.run(["snapshot"]).text.contains("APP CRASHED"))

        #expect(s.run(["location", "37.3349,-122.009"]).text == "location → set to 37.3349,-122.009")
        #expect(s.run(["location", "91,0"]).exit == 64)

        let payload = FileManager.default.temporaryDirectory.appendingPathComponent(
            "cht-push-\(UUID().uuidString).json")
        try Data(#"{"aps":{"alert":"chauffeur push test"}}"#.utf8).write(to: payload)
        defer { try? FileManager.default.removeItem(at: payload) }
        let push = s.run(["push", "dev.chauffeur.fixture", payload.path])
        // iOS 27.0 refuses a push for an app that was never granted notification permission (simctl cannot grant it, S2).
        #expect(
            (push.exit == 0 && push.text.hasPrefix("push dev.chauffeur.fixture → sent ("))
                || (push.exit == 1 && push.text.contains("Source is not authorized")), "\(push.text)")

        let dark = s.run(["appearance", "dark"])
        #expect(dark.exit == 0 && dark.text.hasPrefix("appearance → dark"), "\(dark.text)")
    }
}
