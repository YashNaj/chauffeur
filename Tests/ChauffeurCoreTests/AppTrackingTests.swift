import Foundation
import Testing
@testable import ChauffeurCore

@Suite @MainActor struct AppTrackingTests {
    static func fakeUDID() -> String { "ZZ" + String(format: "%06X", UInt32.random(in: 0...0xFFFFFF)) + "-TEST" }

    func snapshot(app name: String) -> Snapshot {
        var refs = RefTable()
        let root = AXElement(role: "AXApplication", label: name, frame: Rect(x: 0, y: 0, w: 402, h: 874), children: [
            AXElement(role: "AXButton", label: "OK", frame: Rect(x: 100, y: 400, w: 200, h: 44)),
        ])
        return Perception.build(root: root, size: Size(w: 402, h: 874), previous: nil, refs: &refs, rev: 1)
    }

    let fixture = TrackedApp(bundle: "dev.chauffeur.fixture", executable: "Fixture", displayName: "Fixture", pid: 4321, launchedAt: Date())

    @Test func theLaunchedAppIsExpectedOnlyWhileItIsInFront() {
        let s = Session(udid: Self.fakeUDID())
        #expect(s.expectedApp(on: snapshot(app: "Fixture")) == nil)  // nothing launched yet
        s.app = fixture
        #expect(s.expectedApp(on: snapshot(app: "Fixture")) == "dev.chauffeur.fixture")
        #expect(s.expectedApp(on: snapshot(app: "Settings")) == nil)  // another app is in front: no INTERCEPTED guesses
    }

    @Test func releasingTheLaunchedAppStopsFollowingIt() throws {
        let udid = Self.fakeUDID()
        try StatePaths.ensureDir()
        let s = Session(udid: udid)
        s.track(fixture)
        defer { TrackedApp.clear(StatePaths.app(udid)) }
        #expect(TrackedApp.load(StatePaths.app(udid)) == fixture)
        #expect(s.release("com.other") == nil && s.app == fixture)
        #expect(s.release("dev.chauffeur.fixture") == fixture)
        #expect(s.app == nil && TrackedApp.load(StatePaths.app(udid)) == nil)
    }

    @Test func aRestartedDaemonFollowsOnlyAnAppThatIsStillRunning() throws {
        let udid = Self.fakeUDID()
        try StatePaths.ensureDir()
        defer { TrackedApp.clear(StatePaths.app(udid)) }
        var alive = fixture
        alive.pid = getpid()
        alive.save(StatePaths.app(udid))
        #expect(Session(udid: udid).app == alive)
        var gone = fixture
        gone.pid = 999_999
        gone.save(StatePaths.app(udid))
        #expect(Session(udid: udid).app == nil)
        #expect(TrackedApp.load(StatePaths.app(udid)) == nil)
    }
}
