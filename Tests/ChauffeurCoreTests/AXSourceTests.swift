import Testing

@testable import ChauffeurCore

@Suite @MainActor struct AXSourceTests {
    @Test func aScriptedSourceReplaysItsFramesAndHolds() throws {
        let home = try Fixtures.ax("fixture-home")
        let form = try Fixtures.ax("fixture-form")
        let ax = ScriptedAX(frames: [home, form])
        #expect(ax.read() == home)
        #expect(ax.read() == form)
        #expect(ax.read() == form)
    }
}
