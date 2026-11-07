import Foundation
import Testing

@testable import ChauffeurCore

/// M4b spec §8: an app opened from its icon has no accessibility tree; chauffeur relaunches it once, never in a batch.
@Suite @MainActor struct RecoverTests {
    let list = """
        PID\tStatus\tLabel
        412\t0\tcom.apple.SpringBoard
        9031\t0\tUIKitApplication:dev.chauffeur.fixture[5b1c][rb-legacy]
        -\t0\tUIKitApplication:com.apple.mobilesafari[77aa][rb-legacy]
        9120\t0\tUIKitApplication:com.apple.Preferences[0c3d][rb-legacy]
        """

    @Test func runningAppsAreTheUIKitApplicationsWithAPid() {
        let apps = SimApps.runningApps(list)
        #expect(apps.map(\.bundle) == ["dev.chauffeur.fixture", "com.apple.Preferences"])
        #expect(apps.map(\.pid) == [9031, 9120])
    }

    /// An app opened without accessibility has an empty, unlabeled root, so it is found by the pid the bridge reports.
    @Test func theFrontAppIsFoundByItsPid() {
        #expect(SimApps.runningApp(pid: 9031, in: list) == "dev.chauffeur.fixture")
    }

    @Test func anUnknownPidIsNotRelaunched() {
        #expect(SimApps.runningApp(pid: 412, in: list) == nil)  // SpringBoard is not an app to relaunch
        #expect(SimApps.runningApp(pid: 7777, in: list) == nil)
    }

    /// A session over a scripted simulator showing the fixture, whose shell answers an offline `launch` of `bundle`
    /// (`launch`: its `simctl launch` reply instead): the relaunch is the real `launch` command; the shell records it.
    func session(bundle: String = Act.fixtureBundle, launch: ProcessResult? = nil) throws -> (Session, RecordingShell) {
        let udid = Act.udid()
        var replies = Act.launchReplies(udid: udid, bundle: bundle)
        if let launch { replies[["launch", udid, bundle]] = [launch] }
        let shell = RecordingShell(replies: replies)
        let s = Session(
            udid: udid,
            environment: .scripted(
                ax: ScriptedAX(frames: [try Act.home()]), shell: shell, processes: FakeProcesses(alive: [4321])))
        return (s, shell)
    }

    func launches(_ shell: RecordingShell, _ udid: String) -> Int {
        shell.calls.filter { $0 == ["launch", udid, Act.fixtureBundle] }.count
    }

    @Test func aBlindAppIsRelaunchedOnceAndTheCommandRetried() throws {
        let (s, shell) = try session()
        defer { TrackedApp.clear(StatePaths.app(s.udid)) }
        var calls = 0
        let out = try s.withRelaunch {
            calls += 1
            if calls == 1 { throw ChauffeurError.needsRelaunch(bundle: "dev.chauffeur.fixture", why: "blind") }
            return Output("app \"Fixture\" · rev 1")
        }
        #expect(shell.calls.contains(["launch", s.udid, "dev.chauffeur.fixture"]) && calls == 2)
        #expect(
            out.text == "app \"Fixture\" · rev 1\nnote: relaunched dev.chauffeur.fixture — it was opened from its "
                + "icon without accessibility; its in-app state was reset")
        // The same app going blind again in this session is not relaunched a second time.
        #expect(throws: ChauffeurError.blind("blind")) {
            try s.withRelaunch { throw ChauffeurError.needsRelaunch(bundle: "dev.chauffeur.fixture", why: "blind") }
        }
        #expect(launches(shell, s.udid) == 1)
    }

    @Test func neverInsideABatch() throws {
        let (s, shell) = try session()
        s.inBatch = true
        #expect(throws: ChauffeurError.blind("blind")) {
            try s.withRelaunch { throw ChauffeurError.needsRelaunch(bundle: "x.y", why: "blind") }
        }
        #expect(!shell.calls.contains { $0.first == "launch" })
    }

    @Test func aFailedRelaunchGivesTodaysMessage() throws {
        let (s, shell) = try session(bundle: "x.y", launch: Act.out("", status: 1))
        #expect(throws: ChauffeurError.blind("blind")) {
            try s.withRelaunch { throw ChauffeurError.needsRelaunch(bundle: "x.y", why: "blind") }
        }
        #expect(shell.calls.contains(["launch", s.udid, "x.y"]))  // it failed at `simctl launch`
    }

    @Test func needsRelaunchReadsAsItsReason() {
        #expect(ChauffeurError.needsRelaunch(bundle: "x.y", why: "relaunch it").description == "relaunch it")
    }

    /// `launch` and `wait` poll through a slow first tree; recovery must not cut them short (final review, item 1).
    @Test func aBlindAppStillLaunchingIsWaitedFor() {
        #expect(ChauffeurError.noTree.appNotUpYet)
        #expect(ChauffeurError.blind("b").appNotUpYet)
        #expect(ChauffeurError.needsRelaunch(bundle: "x.y", why: "b").appNotUpYet)
        #expect(!ChauffeurError.landscape.appNotUpYet)
    }

    /// An app chauffeur launched itself started with accessibility on: an empty tree there is the app's own (a game,
    /// a custom-drawn screen), so it is not reset on a guess (final review, item 2).
    @Test func anAppChauffeurLaunchedIsNotRelaunched() {
        #expect(Session.relaunchBundle(frontPID: 9031, launchctlList: list, launchedPID: 9031) == nil)
        #expect(Session.relaunchBundle(frontPID: 9031, launchctlList: list, launchedPID: 5) == "dev.chauffeur.fixture")
        #expect(
            Session.relaunchBundle(frontPID: 9031, launchctlList: list, launchedPID: nil) == "dev.chauffeur.fixture")
        #expect(Session.relaunchBundle(frontPID: nil, launchctlList: list, launchedPID: nil) == nil)
    }

    /// The agent learns its app was reset even when the retried command then fails (final review, item 3).
    @Test func aFailedRetryStillReportsTheRelaunch() throws {
        let (s, _) = try session(bundle: "x.y")
        defer { TrackedApp.clear(StatePaths.app(s.udid)) }
        var calls = 0
        let out = try s.withRelaunch {
            calls += 1
            if calls == 1 { throw ChauffeurError.needsRelaunch(bundle: "x.y", why: "blind") }
            throw ChauffeurError.failed("no element e9")
        }
        #expect(out.exit == 1)
        #expect(out.text.hasPrefix("no element e9\nnote: relaunched x.y"))
    }
}
