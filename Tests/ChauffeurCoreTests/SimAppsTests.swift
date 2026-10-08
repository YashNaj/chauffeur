import Foundation
import Testing

@testable import ChauffeurCore

@Suite struct SimAppsTests {
    /// `xcrun simctl appinfo <udid> dev.chauffeur.fixture` on iOS 27.0, trimmed.
    static let fixtureInfo = """
        {
            ApplicationType = User;
            CFBundleDisplayName = Fixture;
            CFBundleExecutable = Fixture;
            CFBundleIdentifier = "dev.chauffeur.fixture";
            CFBundleName = Fixture;
            Path = "/Users/u/Library/Developer/CoreSimulator/Devices/4474DB35/data/Containers/Bundle/Application/FB8B/Fixture.app";
        }
        """

    @Test func appInfoGivesTheExecutableAndTheNameOnScreen() {
        #expect(SimApps.appInfo(Self.fixtureInfo) == SimApps.AppInfo(executable: "Fixture", displayName: "Fixture"))
        let settings = "{\n    CFBundleDisplayName = Settings;\n    CFBundleExecutable = Preferences;\n}"
        #expect(SimApps.appInfo(settings) == SimApps.AppInfo(executable: "Preferences", displayName: "Settings"))
        #expect(SimApps.appInfo("") == nil)
    }

    @Test func launchPrintsBundleAndPid() {
        #expect(SimApps.launchedPID("dev.chauffeur.fixture: 4321\n") == 4321)
        #expect(SimApps.launchedPID("garbage") == nil)
    }

    @Test func builtAppBundleIdAndVersion() throws {
        let app = FileManager.default.temporaryDirectory.appendingPathComponent("cht-\(UUID().uuidString)/Fixture.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: app.deletingLastPathComponent()) }
        let plist: [String: Any] = [
            "CFBundleIdentifier": "dev.chauffeur.fixture", "CFBundleShortVersionString": "0.1", "CFBundleVersion": "1",
        ]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0).write(
            to: app.appendingPathComponent("Info.plist"))
        #expect(SimApps.bundle(at: app) == SimApps.AppBundle(identifier: "dev.chauffeur.fixture", version: "0.1 (1)"))
        #expect(SimApps.bundle(at: app.deletingLastPathComponent()) == nil)
    }

    @Test func simctlErrorsAreShortened() {
        let notRunning = ProcessResult(
            status: 3, out: "", timedOut: false,
            err: """
                An error was encountered processing the command (domain=NSPOSIXErrorDomain, code=3):
                Simulator device failed to terminate com.does.not.exist.
                found nothing to terminate
                Underlying error (domain=NSPOSIXErrorDomain, code=3):
                \tThe request to terminate "com.does.not.exist" failed. found nothing to terminate
                \tfound nothing to terminate
                """)
        #expect(
            SimCtl.message(notRunning)
                == "Simulator device failed to terminate com.does.not.exist. · found nothing to terminate")
        #expect(SimCtl.message(ProcessResult(status: 9, out: "", timedOut: false)) == "simctl exited 9")
    }

    /// `simctl spawn <udid> launchctl list`, trimmed (iOS 27.0).
    @Test func springBoardPIDFromLaunchctl() {
        let list =
            "PID\tStatus\tLabel\n80378\t0\tcom.apple.SpringBoard\n-\t0\tcom.apple.accessibility.heard\n81606\t0\tUIKitApplication:dev.chauffeur.fixture[0edc][rb-legacy]\n"
        #expect(SimApps.springBoardPID(list) == 80378)
        #expect(SimApps.springBoardPID("PID\tStatus\tLabel\n-\t0\tcom.apple.SpringBoard\n") == nil)
        #expect(SimApps.springBoardPID("") == nil)
    }
}
