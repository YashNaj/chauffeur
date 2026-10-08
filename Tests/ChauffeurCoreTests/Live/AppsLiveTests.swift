import Foundation
import Testing

@testable import ChauffeurCore

@Suite(.enabled(if: Live.enabled), .serialized)
@MainActor struct AppsLiveTests {
    @Test func installLaunchRelaunchTerminate() throws {
        let app = try Live.buildFixture()
        let s = Session(udid: Live.udid!)
        defer { s.shutdown() }
        let installed = s.run(["install", app])
        #expect(
            installed.exit == 0 && installed.text.contains("→ installed dev.chauffeur.fixture 0.1 (1)"),
            "\(installed.text)")

        let first = s.run(["launch", "dev.chauffeur.fixture"])
        #expect(
            first.exit == 0 && first.text.hasPrefix("launch dev.chauffeur.fixture → running (pid "), "\(first.text)")
        #expect(first.text.contains("\napp \"Fixture\""), "\(first.text)")
        let pid = try #require(s.app?.pid)
        #expect(s.logTap.executable == "Fixture")

        let second = s.run(["launch", "dev.chauffeur.fixture"])
        #expect(second.exit == 0, "\(second.text)")
        #expect(s.app?.pid != pid && !Proc.isAlive(pid), "a relaunch must start a fresh process")

        let stopped = s.run(["terminate", "dev.chauffeur.fixture"])
        #expect(
            stopped.exit == 0 && stopped.text.hasPrefix("terminate dev.chauffeur.fixture → stopped (pid "),
            "\(stopped.text)")
        #expect(s.app == nil)
        #expect(
            s.run(["terminate", "dev.chauffeur.fixture"]).text == "terminate dev.chauffeur.fixture → was not running")

        let missing = s.run(["launch", "com.does.not.exist"])
        #expect(missing.exit == 1 && missing.text.hasPrefix("com.does.not.exist is not installed"), "\(missing.text)")
        let notAnApp = s.run(["install", "/tmp"])
        #expect(notAnApp.exit == 1 && notAnApp.text.contains("is not an .app directory"))
    }

    /// Xcode 27's device-interaction session turns the simulator's accessibility flags off when it ends; an app
    /// launched while they are off never starts its accessibility server, so it has no tree until relaunched.
    @Test func launchTurnsAccessibilityBackOn() throws {
        let udid = Live.udid!
        let s = Session(udid: udid)
        defer { s.shutdown() }
        _ = s.run(["snapshot"])  // connected: the gated per-command check has run, so launch's own check finds them off
        for key in AXSettings.flags {
            try SimCtl.run(["spawn", udid, "defaults", "write", AXSettings.domain, key, "-bool", "false"])
        }
        let launched = s.run(["launch", "dev.chauffeur.fixture"])
        #expect(launched.exit == 0 && launched.text.contains("\napp \"Fixture\""), "\(launched.text)")
        #expect(launched.text.contains("note: turned the simulator's accessibility back on"), "\(launched.text)")
        #expect(s.run(["snapshot"]).text.contains("Show alert"))
        #expect(!s.run(["launch", "dev.chauffeur.fixture"]).text.contains("note: turned"), "flags already on: no note")
    }

    /// An app the agent opens from the home screen (no `chauffeur launch`) after an Xcode session switched the flags off.
    @Test func anAppOpenedFromItsIconIsReadableAfterTheFlagsWereSwitchedOff() throws {
        let udid = Live.udid!
        let s = Session(udid: udid)
        defer { s.shutdown() }
        _ = s.run(["terminate", "dev.chauffeur.fixture"])
        for key in AXSettings.flags {
            try SimCtl.run(["spawn", udid, "defaults", "write", AXSettings.domain, key, "-bool", "false"])
        }
        s.axCheckedMs = nil  // as for a daemon that has not checked yet
        #expect(s.run(["button", "home"]).exit == 0)
        _ = s.run(["wait", "Safari", "--timeout", "10"])  // the home screen's icons are in the tree
        var found = s.run(["find", "button:Fixture"])
        if !found.text.contains("[e") {  // page 2 of the home screen on iOS 27
            _ = s.run(["swipe", "350,450", "50,450"])
            _ = s.run(["wait", "Fixture", "--timeout", "5"])
            found = s.run(["find", "button:Fixture"])
        }
        let ref = try #require(
            found.text.firstMatch(of: /\[(e\d+)\]/).map { String($0.1) },
            "\(found.text)\n\(s.run(["snapshot"]).text)")
        _ = s.run(["tap", ref])
        let shown = s.run(["wait", "Show alert", "--timeout", "15"])
        #expect(shown.exit == 0, "\(shown.text)")
    }

    /// A cold iOS 27 launch took 5–13 s on the 8 GB host; launch waits up to 15 s and returns as soon as the app is in front.
    @Test func aColdSettingsLaunchIsVerified() throws {
        let s = Session(udid: Live.udid!)
        defer { s.shutdown() }
        _ = s.run(["terminate", "com.apple.Preferences"])
        let r = s.run(["launch", "com.apple.Preferences"])
        #expect(r.exit == 0 && r.text.contains("→ running"), "\(r.text)")
    }

    /// M3a Task 2 finding: with another app in front, launch said "running" while that other app was still showing.
    @Test func anotherAppInFrontDoesNotVerifyALaunch() throws {
        let udid = Live.udid!
        try SimCtl.run(["launch", udid, "com.apple.Preferences"], timeout: 60)
        let s = Session(udid: udid)
        defer { s.shutdown() }
        #expect(s.run(["wait", "Settings", "--timeout", "15"]).exit == 0)
        let r = s.run(["launch", "dev.chauffeur.fixture"])
        #expect(r.exit == 0 && r.text.contains("\napp \"Fixture\""), "\(r.text)")
    }
}
