import Testing

@testable import ChauffeurCore

@Suite struct DoctorTests {
    @Test func rendersAndScores() {
        let checks = [Check(status: .ok, text: "Xcode 27.0"), Check(status: .warn, text: "level debug")]
        #expect(Doctor.render(checks) == "chauffeur \(Chauffeur.version)\n✓ Xcode 27.0\n! level debug")
        #expect(Doctor.exitCode(checks) == 0)
        #expect(Doctor.exitCode(checks + [Check(status: .fail, text: "x")]) == 1)
    }

    @Test func raisedLevelWithoutADaemonIsFlagged() {
        let stale = Doctor.levelCheck(level: "debug", daemonRunning: false, udid: "U")
        #expect(stale.status == .warn)
        #expect(
            stale.text.contains("xcrun simctl spawn U log config --mode level:default --subsystem com.apple.BackBoard"))
        #expect(Doctor.levelCheck(level: "debug", daemonRunning: true, udid: "U").status == .ok)
        #expect(Doctor.levelCheck(level: "info", daemonRunning: false, udid: "U").status == .ok)
        #expect(Doctor.levelCheck(level: nil, daemonRunning: false, udid: "U").status == .warn)
    }
}
