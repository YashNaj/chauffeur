import ChauffeurBridge
import Foundation
import Testing
@testable import ChauffeurCore

@Suite(.enabled(if: Live.enabled), .serialized)
@MainActor struct TouchLogLiveTests {
    @Test func attributesTouchesAndRestoresTheLevel() throws {
        let udid = Live.udid!
        let before = try #require(TouchLog.currentLevel(udid: udid))
        try Live.launchFixture()
        let device = try Device(udid: udid)
        let ax = try AXProvider(sim: device.sim)
        let digitizer = DigitizerTransport(hid: try CHHIDClient(simulator: device.sim))
        let log = TouchLog(udid: udid, levelFile: StatePaths.level(udid))
        try log.start()
        #expect(TouchLog.currentLevel(udid: udid) == "debug")

        let home = try #require(waitForTree(ax) { element($0, "Show alert") != nil })
        var cursor = log.cursor
        #expect(Gestures.tap(digitizer, at: try #require(element(home, "Show alert")).frame.center, screen: device.size))
        #expect(log.evidence(since: cursor, waitMs: 500) == .app(Live.fixture))

        let alert = try #require(waitForTree(ax, timeout: 3) { element($0, "Fixture alert") != nil })
        usleep(600_000)  // a just-presented alert drops touches briefly (Task 11 ruling)
        _ = Gestures.tap(digitizer, at: try #require(alert.all.first { $0.label == "OK" }).frame.center, screen: device.size)
        try SimCtl.run(["terminate", udid, Live.fixture])
        _ = waitForTree(ax) { ($0.label ?? "").trimmingCharacters(in: .whitespaces).isEmpty }  // SpringBoard
        cursor = log.cursor
        _ = Gestures.tap(digitizer, at: Point(x: device.size.w / 2, y: 30), screen: device.size)
        #expect(log.evidence(since: cursor, waitMs: 500) == .system)

        log.stop()
        #expect(TouchLog.currentLevel(udid: udid) == before)
        #expect(!FileManager.default.fileExists(atPath: StatePaths.level(udid).path))
    }
}
