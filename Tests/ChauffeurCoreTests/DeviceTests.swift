import Foundation
import Testing

@testable import ChauffeurCore

/// Argument checks for the simulator-setting commands; all of them fail before touching a simulator.
@Suite @MainActor struct DeviceTests {
    let s = Session(udid: "ZZ000000-TEST")

    @Test func permissionArgumentsAreChecked() throws {
        #expect(throws: ChauffeurError.self) { try s.permissionCommand(["allow", "location", "dev.x"]) }
        #expect(throws: ChauffeurError.self) { try s.permissionCommand(["grant", "camera", "dev.x"]) }
        #expect(throws: ChauffeurError.self) { try s.permissionCommand(["grant", "location"]) }  // grant needs a bundle
        let notifications = try s.permissionCommand(["grant", "notifications", "dev.x"])
        #expect(notifications.exit == 1 && notifications.text.contains("simctl cannot change notification permission"))
    }

    @Test func anAppEndedByAPermissionChangeIsNotACrash() throws {
        try StatePaths.ensureDir()
        defer { TrackedApp.clear(StatePaths.app(s.udid)) }
        let fixture = TrackedApp(
            bundle: "dev.chauffeur.fixture", executable: "Fixture", displayName: "Fixture", pid: 4321,
            launchedAt: Date())
        s.isAlive = { _ in false }
        let note = s.afterPermissionChange(fixture, waitMs: 0)
        #expect(
            note
                == "note: the change ended dev.chauffeur.fixture (pid 4321); relaunch it: chauffeur launch dev.chauffeur.fixture"
        )
        #expect(
            s.app == nil
                && s.annotate(Output("permission grant location dev.chauffeur.fixture → granted"), since: 0, logs: true)
                    .exit == 0
        )
        s.isAlive = { _ in true }
        #expect(s.afterPermissionChange(fixture, waitMs: 0) == nil && s.app == fixture)  // it survived: followed again
    }

    @Test func locationsAreRangeChecked() {
        for bad in ["91,0", "0,181", "abc", "1,2,3", "1,", "nan,0"] {
            #expect(throws: ChauffeurError.self, "\(bad)") { try s.locationCommand([bad]) }
        }
    }

    @Test func pushPayloadsFollowSimctlsRules() {
        #expect(Session.pushProblem(Data(#"{"aps":{"alert":"Hi"}}"#.utf8)) == nil)
        #expect(Session.pushProblem(Data(#"["aps"]"#.utf8)) == "the payload is not a JSON object")
        #expect(
            Session.pushProblem(Data(#"{"alert":"Hi"}"#.utf8))?.hasPrefix(#"the payload needs an "aps" object"#) == true
        )
        #expect(Session.pushProblem(Data(repeating: 32, count: 5000))?.hasSuffix("at most 4096") == true)
    }

    @Test func pushReadsItsPayloadFromTheCallersDirectory() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cht-push-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data(#"{"alert":"no aps"}"#.utf8).write(to: dir.appendingPathComponent("payload.json"))
        s.cwd = dir.path
        let found = try s.pushCommand(["dev.chauffeur.fixture", "payload.json"])
        // it read the file
        #expect(found.exit == 1 && found.text.hasPrefix(#"push: the payload needs an "aps" object"#))
        let missing = try s.pushCommand(["dev.chauffeur.fixture", "missing.json"])
        #expect(missing.text == "push: cannot read \(dir.standardizedFileURL.path)/missing.json")
    }

    @Test func appearanceIsLightOrDark() {
        #expect(throws: ChauffeurError.self) { try s.appearanceCommand(["blue"]) }
    }
}
