import Foundation
import Testing
@testable import ChauffeurCore

@MainActor
func waitForTree(_ ax: AXProvider, timeout: Double = 15, _ condition: (AXElement) -> Bool) -> AXElement? {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if let root = ax.read(), !root.frame.isEmpty, condition(root) { return root }
        usleep(100_000)
    }
    return nil
}

@Suite(.enabled(if: Live.enabled), .serialized)
@MainActor struct AXLiveTests {
    @Test func readsTheFixtureAndFillsItsTabBar() throws {
        try Live.launchFixture()
        let device = try Device(udid: Live.udid!)
        let ax = try AXProvider(sim: device.sim)
        let root = try #require(waitForTree(ax) { element($0, "Show alert") != nil })
        #expect(root.label == "Fixture")
        let start = Date()
        let full = ax.complete(root)
        let ms = Date().timeIntervalSince(start) * 1000
        print("sweep took \(Int(ms)) ms")
        #expect(ms < 1500)
        let bar = try #require(full.all.first { $0.label == "Tab Bar" })
        print("tab bar children: \(bar.children.map { "\($0.role) \($0.label ?? "-") \($0.value ?? "-")" })")
        #expect(bar.children.contains { $0.label == "Home" })
        #expect(bar.children.contains { $0.label == "Form" })
        #expect(ax.complete(root) == full)  // cached
    }

    /// Restarting the simulator's accessibility bridge (the cure for a poisoned one) must not break a running session.
    @Test func aBridgeRestartKeepsTheSessionReading() throws {
        try Live.launchFixture()
        let s = Session(udid: Live.udid!)
        defer { s.shutdown() }
        let up = s.run(["wait", "Show alert", "--timeout", "30"])  // a cold launch takes 5–15 s on the 8 GB host
        #expect(up.exit == 0, "\(up.text)")
        try SimCtl.run(["spawn", Live.udid!, "launchctl", "stop", "com.apple.CoreSimulator.bridge"])
        let after = s.run(["wait", "Show alert", "--timeout", "15"])
        #expect(after.exit == 0, "\(after.text)")
    }

    /// The by-pid read answers for SpringBoard whatever is in front: that is how a poisoned bridge is told apart.
    @Test func springBoardAnswersByPid() throws {
        let udid = Live.udid!
        let pid = try #require(SimApps.springBoardPID(try SimCtl.run(["spawn", udid, "launchctl", "list"]).out))
        let device = try Device(udid: udid)
        let tree = try AXProvider(sim: device.sim).read(pid: pid)
        #expect(tree != nil && !(tree?.frame.isEmpty ?? true))
    }

    /// Final review I2: healing re-polls right after restarting the bridge; it must read through a provider that works.
    @Test func healingReadsThroughTheRestartedBridge() throws {
        try Live.launchFixture()
        let s = Session(udid: Live.udid!)
        defer { s.shutdown() }
        #expect(s.run(["wait", "Show alert", "--timeout", "30"]).exit == 0)
        let ax = s.restartBridge()
        #expect(ax?.read().map { !$0.frame.isEmpty } == true, "the provider healing re-polls with must read after a restart")
    }

    /// Final review I5, seen live 2026-10-07: an app started (outside chauffeur) while the flags were off has no tree.
    /// chauffeur must say to relaunch it, not restart the bridge.
    @Test func anAppStartedWithTheFlagsOffIsToldToRelaunch() throws {
        let udid = Live.udid!
        for key in AXSettings.flags {
            try SimCtl.run(["spawn", udid, "defaults", "write", AXSettings.domain, key, "-bool", "false"])
        }
        try Live.launchFixture()
        sleep(8)
        let s = Session(udid: udid)
        defer { s.shutdown() }
        var out = s.run(["snapshot"])
        for _ in 0..<8 where !out.text.contains("relaunch it") { usleep(700_000); out = s.run(["snapshot"]) }
        #expect(out.text.contains("relaunch it: chauffeur launch <bundle>"), "\(out.text)")
        #expect(s.bridgeRestartedMs == nil)
        let relaunched = s.run(["launch", "dev.chauffeur.fixture"])
        #expect(relaunched.exit == 0 && relaunched.text.contains("app \"Fixture\""), "\(relaunched.text)")
    }
}

