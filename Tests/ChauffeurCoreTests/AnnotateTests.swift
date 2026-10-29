import Foundation
import Testing

@testable import ChauffeurCore

/// Spec §5.4 and §6.8: action results carry new error lines; a vanished app is APP CRASHED, once.
@Suite @MainActor struct AnnotateTests {
    let fixture = TrackedApp(
        bundle: "dev.chauffeur.fixture", executable: "Fixture", displayName: "Fixture", pid: 4321,
        launchedAt: Date())

    /// A session whose launched app is `fixture`, with a fake clock and a fake liveness check: `procs` (alive: just the
    /// app's pid) is what a test changes between commands. Without `screen` there is no simulator; with it, a booted one
    /// showing `screen`, whose `simctl` is `shell`.
    func session(
        alive: Bool, report: CrashReport? = nil, booted: Bool? = true, bootDate: Date? = nil,
        procs: FakeProcesses? = nil, findReport: ((TrackedApp) -> CrashReport?)? = nil, udid: String = Act.udid(),
        screen: AXElement? = nil, shell: RecordingShell = RecordingShell()
    ) -> Session {
        var env = SessionEnvironment.scripted(
            ax: ScriptedAX(frames: screen.map { [$0] } ?? []), shell: shell,
            processes: procs ?? FakeProcesses(alive: alive ? [4321] : []),
            simulatorBooted: { booted }, simulatorBootDate: { bootDate }, findCrashReport: findReport ?? { _ in report }
        )
        if screen == nil {
            // The fake udid has no simulator: connecting fails, as it does for the real device.
            env.device = { FakeDevice(udid: $0, booted: false, size: Size(w: 402, h: 874)) }
        }
        let s = Session(udid: udid, environment: env)
        s.app = fixture
        s.logTapAttemptMs = s.clock.nowMs()  // no real `log stream` for a fake simulator
        return s
    }

    let tapped = Output(
        "tap e5 \"Crash\" → changed · settled 610ms · rev 3→4\n+ button \"Phone\" [e9]\n- button \"Crash\" [e5]")

    @Test func actionsGetTheirNewErrorLines() {
        let s = session(alive: true)
        s.logs.append(LogLine(time: "t", level: "error", message: "before the action"))
        let cursor = s.logs.cursor
        s.logs.append(LogLine(time: "t", level: "info", message: "fine"))
        s.logs.append(LogLine(time: "t", level: "error", message: "save failed"))
        let out = s.annotate(Output("tap e2 \"Save\" → changed · settled 200ms · rev 1→2"), since: cursor, logs: true)
        #expect(out.text == "tap e2 \"Save\" → changed · settled 200ms · rev 1→2\nlogs: [error] \"save failed\"")
        #expect(out.exit == 0 && out.data?["logs"]?.array?.count == 1)
        #expect(
            s.annotate(Output("app \"Fixture\" · rev 2"), since: cursor, logs: false).text == "app \"Fixture\" · rev 2")
    }

    @Test func aVanishedAppIsACrashReportedOnce() {
        let s = session(alive: false)
        let cursor = s.logs.cursor
        s.logs.append(LogLine(time: "t", level: "fault", message: "fixture: crashing"))
        let out = s.annotate(tapped, since: cursor, logs: true)
        #expect(out.exit == 5)
        #expect(
            out.text == """
                tap e5 "Crash" → APP CRASHED: dev.chauffeur.fixture (pid 4321) · crash report not written yet (macOS can take a minute)
                reason: "fixture: crashing"
                logs: [fault] "fixture: crashing"
                hint: after fixing it, rebuild, chauffeur install <path.app>, then chauffeur launch dev.chauffeur.fixture
                """)
        #expect(out.data?["crash"]?["pid"]?.int == 4321)
        #expect(s.app == nil && s.crash?.app == fixture)
        #expect(s.annotate(Output("app \"SpringBoard\""), since: cursor, logs: false) == Output("app \"SpringBoard\""))
    }

    @Test func aCrashNoticedByALaterCommandStillShowsTheLastActionsErrors() {
        let s = session(alive: false)
        s.logs.append(LogLine(time: "t", level: "error", message: "long before"))
        s.lastActionLogCursor = s.logs.cursor  // the tap that triggered the crash started here
        s.logs.append(LogLine(time: "t", level: "fault", message: "fixture: crashing"))
        let later = s.logs.cursor  // a snapshot starts after the crash was logged
        let out = s.annotate(Output("app \"SpringBoard\" · rev 9"), since: later, logs: false)
        #expect(out.exit == 5 && out.text.contains("\nlogs: [fault] \"fixture: crashing\"\n"))
        #expect(!out.text.contains("long before"))
    }

    @Test func readOnlyCommandsKeepTheirOutputWhenTheyNoticeACrash() {
        let s = session(alive: false)
        let out = s.annotate(Output("app \"SpringBoard\" · rev 9\nbutton \"Phone\" [e9]"), since: 0, logs: false)
        #expect(out.exit == 5 && out.text.hasPrefix("app \"SpringBoard\" · rev 9\nbutton \"Phone\" [e9]\nAPP EXITED: "))
    }

    @Test func aReadReportIsShownWithItsFrames() throws {
        let report = try #require(CrashReport.parse(try Fixtures.crash("Fixture-sample"), path: "/r/Fixture.ips"))
        let out = session(alive: false, report: report).annotate(tapped, since: 0, logs: true)
        #expect(
            out.text.hasPrefix(
                "tap e5 \"Crash\" → APP CRASHED: dev.chauffeur.fixture (pid 4321) · EXC_BREAKPOINT (SIGTRAP)\nreport: /r/Fixture.ips\n  libswiftCore.dylib"
            ))
    }

    @Test func aResultWithoutAnArrowKeepsItsFirstLine() {
        let out = session(alive: false).annotate(Output("done\nmore"), since: 0, logs: true)
        #expect(out.text.hasPrefix("done\nAPP EXITED: dev.chauffeur.fixture (pid 4321)"))
    }

    @Test func endingTheAppOnPurposeIsNotACrash() {
        let s = session(alive: false)
        s.release("dev.chauffeur.fixture")  // what terminate, install and launch do first
        #expect(s.annotate(tapped, since: 0, logs: true) == tapped)
    }

    @Test func anAppThatDiesSlowlyAfterAPermissionChangeIsNotACrash() throws {
        let procs = FakeProcesses(alive: [4321])
        let s = session(alive: true, procs: procs)
        defer { TrackedApp.clear(StatePaths.app(s.udid)) }
        let ended = try #require(s.release("dev.chauffeur.fixture"))  // what `permission grant` does first
        procs.alive = [4321]  // still alive when the 1 s grace window ends: followed again
        #expect(s.afterPermissionChange(ended, waitMs: 0) == nil && s.app == ended)
        procs.alive = []  // …and it dies a little later, because chauffeur's change ended it
        let out = s.annotate(Output("snapshot"), since: 0, logs: false)
        #expect(out == Output("snapshot") && s.app == nil && s.crash == nil)
    }

    @Test func aDeathLongAfterChauffeurEndedItIsStillACrash() throws {
        let procs = FakeProcesses(alive: [4321])
        let s = session(alive: true, procs: procs)
        defer { TrackedApp.clear(StatePaths.app(s.udid)) }
        let ended = try #require(s.release("dev.chauffeur.fixture"))
        s.endedByChauffeur[ended.pid] = s.clock.nowMs() - 11_000
        s.track(ended)
        procs.alive = []
        #expect(s.annotate(Output("snapshot"), since: 0, logs: false).exit == 5)
    }

    @Test func aShutDownSimulatorIsNotACrash() {
        let s = session(alive: false, booted: false)
        #expect(s.annotate(tapped, since: 0, logs: true) == tapped)
        #expect(s.app == nil && s.crash == nil)
        let logs = try? s.logsCommand([])
        #expect(logs?.exit == 1 && logs?.text.contains("APP CRASHED") == false)
    }

    @Test func logsAfterAShutdownDoesNotReportACrash() throws {
        let s = session(alive: false, booted: false)
        defer { try? FileManager.default.removeItem(at: StatePaths.artifacts(s.udid)) }
        let logs = try s.logsCommand([])
        #expect(logs.exit == 1 && !logs.text.contains("APP CRASHED") && s.crash == nil)
    }

    @Test func aRebootedSimulatorIsNotACrash() {
        // booted again after the app launched
        let s = session(alive: false, bootDate: fixture.launchedAt.addingTimeInterval(5))
        #expect(s.annotate(tapped, since: 0, logs: true) == tapped && s.app == nil && s.crash == nil)
        // same boot: a real crash
        let steady = session(alive: false, bootDate: fixture.launchedAt.addingTimeInterval(-600))
        #expect(steady.annotate(tapped, since: 0, logs: true).exit == 5)
    }

    @Test func bootTimeComesFromTheSimulatorsLaunchdProcess() {
        let ps = """
            Wed Oct  7 01:13:54 2026     launchd_sim /Users/u/Library/Developer/CoreSimulator/Devices/AF7CFC76-936D-4E67-98F7-102C682E7ECD/data/var/run/launchd_bootstrap
            Wed Oct  7 01:28:31 2026     /bin/zsh -c grep launchd_sim AF7CFC76-936D-4E67-98F7-102C682E7ECD
            Wed Oct  7 02:00:00 2026     launchd_sim /Users/u/Library/Developer/CoreSimulator/Devices/4474DB35-730B-4017-AAB3-367700816901/data/var/run/launchd_bootstrap
            """
        let boot = SimBoot.parse(ps, udid: "af7cfc76-936d-4e67-98f7-102c682e7ecd")
        var parts = DateComponents()
        parts.year = 2026
        parts.month = 10
        parts.day = 7
        parts.hour = 1
        parts.minute = 13
        parts.second = 54
        #expect(boot == Calendar.current.date(from: parts))
        #expect(SimBoot.parse(ps, udid: "ZZZZ") == nil)
    }

    /// A booted simulator showing the fixture, whose `simctl` answers `launch dev.chauffeur.fixture` up to its last
    /// step: `simctl launch` fails, after `launch` has stopped following the app and before a new launch would
    /// supersede the crash.
    func endingSession() throws -> (Session, RecordingShell) {
        let udid = Act.udid()
        var replies = Act.launchReplies(udid: udid)
        replies[["launch", udid, Act.fixtureBundle]] = [Act.out("", status: 1)]
        let shell = RecordingShell(replies: replies)
        return (session(alive: false, udid: udid, screen: try Act.home(), shell: shell), shell)
    }

    /// The next command after a crash must say so, even when it is the one that stops following the app.
    @Test func aCrashBetweenCommandsIsReportedByTheNextCommandThatEndsTheApp() throws {
        for command in [
            ["terminate", "dev.chauffeur.fixture"], ["launch", "dev.chauffeur.fixture"],
            ["install", "/no/such/Fixture.app"], ["permission", "grant", "location", "dev.chauffeur.fixture"],
        ] {
            let (s, shell) = try endingSession()
            defer { try? FileManager.default.removeItem(at: StatePaths.artifacts(s.udid)) }
            s.logs.append(LogLine(time: "t", level: "fault", message: "fixture: crashing"))
            // These commands stop following the app (`release`) as soon as they run; that must not hide the crash.
            let out = s.run(command)
            // Each but `install` (there is no such app) got past its `release`, as far as `simctl`.
            let verb = ["terminate": "terminate", "launch": "launch", "permission": "privacy"][command[0]]
            #expect(verb.map { verb in shell.calls.contains { $0.first == verb } } ?? true, "\(command)")
            #expect(
                out.exit == 5 && out.text.contains("APP CRASHED: dev.chauffeur.fixture (pid 4321)"),
                "\(command): \(out.text)")
            #expect(out.text.contains("[fault] \"fixture: crashing\""), "\(command)")
            #expect(s.crash?.app == fixture, "\(command)")
        }
        let (s, _) = try endingSession()
        defer { try? FileManager.default.removeItem(at: StatePaths.artifacts(s.udid)) }
        _ = s.run(["terminate", "dev.chauffeur.fixture"])
        // no fault line logged
        #expect(try s.logsCommand([]).text.contains("\nAPP EXITED: dev.chauffeur.fixture (pid 4321)"))
    }

    @Test func logsShowsTheReportOnceMacOSHasWrittenIt() throws {
        let report = try #require(CrashReport.parse(try Fixtures.crash("Fixture-sample"), path: "/r/Fixture.ips"))
        var written = false
        let s = session(alive: false, findReport: { _ in written ? report : nil })
        defer { try? FileManager.default.removeItem(at: StatePaths.artifacts(s.udid)) }
        s.logs.append(LogLine(time: "22:31:04.120", level: "fault", message: "fixture: crashing"))
        #expect(
            s.annotate(tapped, since: 0, logs: true).text.contains(
                "APP CRASHED: dev.chauffeur.fixture (pid 4321) · crash report not written yet"))
        written = true
        let logs = try s.logsCommand(["--level", "error"])
        #expect(
            logs.text.hasPrefix(
                "logs · dev.chauffeur.fixture (pid 4321, not running) · 1 of 1 lines (latest, errors only)"))
        #expect(logs.text.contains("\n22:31:04.120 [fault] \"fixture: crashing\"\n"))
        #expect(logs.text.contains("\nreport: /r/Fixture.ips\n"))
        #expect(logs.data?["crash"]?["report"]?.string == "/r/Fixture.ips")
    }

    @Test func logsNeedsALaunchedAppAndValidOptions() throws {
        let s = Session(udid: "ZZ" + String(format: "%06X", UInt32.random(in: 0...0xFFFFFF)) + "-TEST")
        defer { try? FileManager.default.removeItem(at: StatePaths.artifacts(s.udid)) }
        #expect(try s.logsCommand([]).exit == 1)
        #expect(throws: ChauffeurError.self) { try s.logsCommand(["--level", "debug"]) }
        #expect(throws: ChauffeurError.self) { try s.logsCommand(["--last", "0"]) }
    }

    /// M2 transcripts: agents asked for `--since-last --last 40` and got a usage error.
    @Test func logsTakesSinceLastWithACount() throws {
        let s = session(alive: true)
        s.lastActionLogCursor = s.logs.cursor
        for i in 1...3 { s.logs.append(LogLine(time: "t", level: "error", message: "line \(i)")) }
        let out = try s.logsCommand(["--since-last", "--last", "2"])
        #expect(
            out.text.contains("2 of 3 lines (since the last action)") && !out.text.contains("line 1"), "\(out.text)")
    }
    /// Final review I3: a fatal line from an earlier launch, or a framework's fault, must not make an outside kill a crash.
    @Test func onlyThisLaunchsOwnFatalLinesMakeACrash() {
        let s = session(alive: false)
        defer { try? FileManager.default.removeItem(at: StatePaths.artifacts(s.udid)) }
        s.logs.append(
            LogLine(
                time: "t", level: "default", message: "Fixture/FixtureApp.swift:57: Fatal error: fixture crash",
                sender: "libswiftCore"))
        s.appLogCursor = s.logs.cursor  // the relaunch
        s.logs.append(LogLine(time: "t", level: "fault", message: "UIKit fault", sender: "UIKitCore"))
        #expect(s.annotate(Output("ok"), since: 0, logs: false).text.contains("APP EXITED"))
    }

    /// Task 18: the crash lead is placed by one function on `Output`: what precedes the first " → " stays, the rest of the
    /// result goes, and `exit` and `data` are kept; a first line with no arrow cannot take a lead.
    @Test func theCrashLeadReplacesTheVerdictAndTheRest() {
        let led = Output("tap e4 \"Pay\" → NO EFFECT · x\nhint: y", exit: 3, data: ["a": 1]).withLead("APP CRASHED: z")
        #expect(led == Output("tap e4 \"Pay\" → APP CRASHED: z", exit: 3, data: ["a": 1]), "\(String(describing: led))")
        #expect(Output("nothing to wait for\nmore").withLead("APP CRASHED: z") == nil)
    }
}
