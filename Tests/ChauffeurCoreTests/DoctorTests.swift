import Testing

@testable import ChauffeurCore

@Suite struct DoctorTests {
    @Test func rendersAndScores() {
        let checks = [Check(status: .ok, text: "Xcode 27.0"), Check(status: .warn, text: "level debug")]
        #expect(Doctor.render(checks) == "chauffeur \(Chauffeur.version)\n✓ Xcode 27.0\n! level debug")
        #expect(Doctor.exitCode(checks) == .ok)
        #expect(Doctor.exitCode(checks + [Check(status: .fail, text: "x")]) == .error)
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

    // Doctor's accessibility findings (spec §9): a missing tree reads as the note a result carries for it.

    typealias Probe = (frontmostIsEmptyApp: Bool, screenAnswers: Bool)
    static let relaunch = AXHealth.message(
        AXHealth.Plan(enableFlags: [], restartBridge: false, relaunchApp: true), recovered: false)
    static let noTree = AXHealth.message(
        AXHealth.Plan(enableFlags: [], restartBridge: false, relaunchApp: false), recovered: false)

    static func noTreeChecks(_ probe: Probe, flagsOff: [String]? = []) -> [Check] {
        Doctor.accessibilityChecks(root: nil, ms: 0, flagsOff: flagsOff, udid: "U") { probe }
    }

    @Test func anEmptyAppInFrontReadsAsTheRelaunchNote() {
        #expect(
            Self.noTreeChecks((true, false))
                == [Check(status: .fail, text: Self.relaunch), Check(status: .ok, text: "app accessibility on")])
        #expect(Self.noTreeChecks((true, true)).first == Check(status: .fail, text: Self.relaunch))
    }

    /// `Session` relaunches when the flags are off, so Doctor says the same; it turns no flag on itself, so its
    /// relaunch text names none, and the flags line that follows does.
    @Test func flagsOffWithNoTreeReadsAsTheRelaunchNote() {
        let checks = Self.noTreeChecks((false, true), flagsOff: ["AutomationEnabled"])
        #expect(checks.first == Check(status: .fail, text: Self.relaunch))
        #expect(checks.last?.status == .warn)
        #expect(checks.last?.text.hasPrefix("app accessibility off (AutomationEnabled), as an Xcode") == true)
    }

    @Test func nothingAnsweringReadsAsTheNoTreeNote() {
        #expect(Self.noTreeChecks((false, false)).first == Check(status: .fail, text: Self.noTree))
        #expect(Self.noTreeChecks((false, false), flagsOff: nil) == [Check(status: .fail, text: Self.noTree)])
    }

    /// `AXHealth`'s bridge texts report a restart Doctor never makes, so the poisoned-bridge finding keeps its own.
    @Test func aPoisonedBridgeKeepsItsFix() {
        let check = Self.noTreeChecks((false, true)).first
        #expect(check?.status == .fail)
        #expect(check?.text.contains("xcrun simctl spawn U launchctl stop com.apple.CoreSimulator.bridge") == true)
    }

    @Test func aTreeIsNotProbed() {
        let root = AXElement(
            role: "AXApplication", label: "Fixture", frame: Rect(x: 0, y: 0, w: 402, h: 874), children: [])
        let checks = Doctor.accessibilityChecks(root: root, ms: 12, flagsOff: ["AutomationEnabled"], udid: "U") {
            Issue.record("probed with a tree")
            return (false, false)
        }
        #expect(checks.first == Check(status: .ok, text: "accessibility: app \"Fixture\", 1 elements in 12ms"))
        #expect(checks.last?.status == .warn)
    }

    @Test func accessibilityGoldens() {
        func line(_ check: Check?) -> String { check.map { "\($0.status.rawValue) \($0.text)" } ?? "" }
        Golden.check("doctor-relaunch.txt", line(Self.noTreeChecks((true, false)).first))
        Golden.check("doctor-no-tree.txt", line(Self.noTreeChecks((false, false)).first))
        Golden.check("doctor-bridge.txt", line(Self.noTreeChecks((false, true)).first))
        Golden.check(
            "doctor-flags-off.txt", line(Self.noTreeChecks((false, true), flagsOff: ["AutomationEnabled"]).last))
    }
}
