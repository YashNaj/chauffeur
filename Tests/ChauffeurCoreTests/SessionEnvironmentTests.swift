import Foundation
import Testing

@testable import ChauffeurCore

/// `Session` built from an environment: everything it reaches outside itself is scripted.
@Suite @MainActor struct SessionEnvironmentTests {
    @Test func connectUsesTheEnvironmentsDeviceAndSource() throws {
        let shell = RecordingShell()
        let env = SessionEnvironment.scripted(ax: ScriptedAX(frames: [try Fixtures.ax("fixture-home")]), shell: shell)
        let s = Session(udid: "ZZ000000-TEST", environment: env)
        let out = s.run(["snapshot"])
        #expect(out.exit == 0 && out.text.contains("button \"Show alert\" [e"), "\(out.text)")
        // Connect's accessibility check goes through the environment's shell.
        let read = ["spawn", "ZZ000000-TEST", "defaults", "read", AXSettings.domain]
        #expect(shell.calls.contains(read), "\(shell.calls)")
    }
    @Test func aDeviceThatIsNotBootedIsReported() {
        var env = SessionEnvironment.scripted(ax: ScriptedAX(frames: []))
        env.device = { FakeDevice(udid: $0, booted: false, size: Size(w: 402, h: 874)) }
        let s = Session(udid: "ZZ000000-TEST", environment: env)
        #expect(s.run(["snapshot"]).text.contains("not booted"))
    }

    private func trackedSession(
        _ procs: FakeProcesses, booted: @escaping () -> Bool? = { true }
    ) -> (Session, TrackedApp) {
        let env = SessionEnvironment.scripted(
            ax: ScriptedAX(frames: []), processes: procs, simulatorBooted: booted)
        let s = Session(
            udid: "ZZ" + String(format: "%06X", UInt32.random(in: 0...0xFFFFFF)) + "-TEST", environment: env)
        let app = TrackedApp(
            bundle: "dev.chauffeur.fixture", executable: "Fixture", displayName: "Fixture", pid: 4321,
            launchedAt: Date())
        s.app = app
        s.logTapAttemptMs = s.clock.nowMs()  // no real `log stream` for a fake simulator
        return (s, app)
    }

    @Test func livenessComesFromTheEnvironmentsProcessTable() {
        let procs = FakeProcesses(alive: [4321])
        let (s, _) = trackedSession(procs)
        defer { TrackedApp.clear(StatePaths.app(s.udid)) }
        #expect(s.annotate(Output("snapshot"), since: 0, logs: false).exit == 0 && s.app != nil)
        procs.alive = []
        #expect(s.annotate(Output("snapshot"), since: 0, logs: false).exit == 5)
    }

    @Test func aShutDownSimulatorFromTheEnvironmentIsNotACrash() {
        let procs = FakeProcesses(alive: [4321])
        let (s, _) = trackedSession(procs, booted: { false })
        defer { TrackedApp.clear(StatePaths.app(s.udid)) }
        procs.alive = []
        #expect(s.annotate(Output("snapshot"), since: 0, logs: false).exit == 0 && s.app == nil)
    }

    @Test func aRebootedSimulatorForgetsTheAppAndReconnects() throws {
        let device = FakeDevice(udid: "ZZ000000-TEST", booted: true, size: Size(w: 402, h: 874))
        let procs = FakeProcesses(alive: [4321])
        var bootDate: Date?
        var env = SessionEnvironment.scripted(
            ax: ScriptedAX(frames: [try Act.home()]), processes: procs,
            simulatorBooted: { device.booted }, simulatorBootDate: { bootDate })
        env.device = { _ in device }
        let s = Session(udid: "ZZ000000-TEST", environment: env)
        defer { TrackedApp.clear(StatePaths.app(s.udid)) }
        s.app = TrackedApp(
            bundle: "dev.chauffeur.fixture", executable: "Fixture", displayName: "Fixture", pid: 4321,
            launchedAt: Date())
        s.logTapAttemptMs = s.clock.nowMs()
        #expect(s.run(["snapshot"]).exit == 0)
        device.booted = false
        procs.alive = []
        let down = s.run(["snapshot"])
        #expect(down.exit == 1 && down.text.contains("is not booted") && !down.text.contains("APP"), "\(down.text)")
        #expect(s.app == nil)
        device.booted = true
        bootDate = Date()
        #expect(s.run(["snapshot"]).exit == 0)
    }
}
