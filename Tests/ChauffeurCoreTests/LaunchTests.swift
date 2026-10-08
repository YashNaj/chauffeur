import Testing

@testable import ChauffeurCore

@Suite struct LaunchTests {
    /// Final review I4: relaunching the app in front must not wait for its own screen to go away, under either the
    /// Info.plist name or the name its tree shows (localised).
    @Test func theRelaunchedAppIsNeverStale() {
        #expect(Session.staleKind(previous: .app("Réglages"), relaunched: ["Settings", "Réglages"]) == nil)
        #expect(Session.staleKind(previous: .app("Settings"), relaunched: ["Settings"]) == nil)
        #expect(Session.staleKind(previous: .app("Maps"), relaunched: ["Fixture"]) == .app("Maps"))
        #expect(Session.staleKind(previous: .springboard, relaunched: ["Fixture"]) == .springboard)
        #expect(Session.staleKind(previous: nil, relaunched: ["Fixture"]) == nil)
    }
}
