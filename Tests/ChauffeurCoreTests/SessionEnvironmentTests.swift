import Foundation
import Testing

@testable import ChauffeurCore

/// `Session` built from an environment: everything it reaches outside itself is scripted.
@Suite @MainActor struct SessionEnvironmentTests {
    @Test func connectUsesTheEnvironmentsDeviceAndSource() throws {
        let env = SessionEnvironment.scripted(ax: ScriptedAX(frames: [try Fixtures.ax("fixture-home")]))
        let s = Session(udid: "ZZ000000-TEST", environment: env)
        let out = s.run(["snapshot"])
        #expect(out.exit == 0 && out.text.contains("button \"Show alert\" [e"), "\(out.text)")
    }
    @Test func aDeviceThatIsNotBootedIsReported() {
        var env = SessionEnvironment.scripted(ax: ScriptedAX(frames: []))
        env.device = { FakeDevice(udid: $0, booted: false, size: Size(w: 402, h: 874)) }
        let s = Session(udid: "ZZ000000-TEST", environment: env)
        #expect(s.run(["snapshot"]).text.contains("not booted"))
    }
}
