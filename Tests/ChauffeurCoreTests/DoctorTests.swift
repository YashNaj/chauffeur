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

    @Test func connectKeyLine() {
        let k = StoredKey(keyID: "7X2K9ABC1D", issuer: "", role: .appManager, apps: [], added: "", presence: true)
        let n = StoredKey(keyID: "NFC334SLRJ", issuer: "", role: .developer, apps: [], added: "", presence: false)
        #expect(
            Doctor.connectCheck(keys: [], pinned: nil)
                == Check(status: .ok, text: "connect key: none (chauffeur keys add)"))
        #expect(
            Doctor.connectCheck(keys: [k], pinned: "7X2K9ABC1D")
                == Check(status: .ok, text: "connect key: 7X2K9ABC1D (App Manager, presence) · pinned for this project")
        )
        #expect(Doctor.connectCheck(keys: [k], pinned: "ZZZZZZZZZZ").status == .fail)
        #expect(
            Doctor.connectCheck(keys: [k], pinned: nil)
                == Check(status: .ok, text: "connect key: 7X2K9ABC1D (App Manager, presence)"))
        #expect(
            Doctor.connectCheck(keys: [k, n], pinned: nil)
                == Check(
                    status: .warn,
                    text: "connect keys: 7X2K9ABC1D, NFC334SLRJ · none pinned (chauffeur keys use <key-id>)"))
    }
}
