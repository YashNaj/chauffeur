import Darwin
import Foundation
import Testing
@testable import ChauffeurCore

@Suite struct CrashTests {
    static let udid = "AF7CFC76-936D-4E67-98F7-102C682E7ECD"

    @Test func parsesTheFixtureCrash() throws {
        let report = try #require(CrashReport.parse(try Fixtures.crash("Fixture-sample"), path: "/r/Fixture.ips"))
        #expect(report.bundle == "dev.chauffeur.fixture" && report.pid == 39261)
        #expect(report.exception == "EXC_BREAKPOINT (SIGTRAP)")
        #expect(report.reason == nil)
        #expect(report.frames.first == "libswiftCore.dylib _assertionFailure(_:_:file:line:flags:) + 156")
        #expect(report.frames[1] == "Fixture closure #5 in closure #2 in closure #1 in HomeView.body.getter + 268")
        #expect(report.frames.count == 5)
    }

    @Test func applicationSpecificInfoBecomesTheReason() {
        let text = #"{"bundleID":"com.x"}"# + "\n" + #"{"pid":7,"asi":{"libswiftCore.dylib":["Fatal error: Index out of range"]},"threads":[]}"#
        #expect(CrashReport.parse(Data(text.utf8), path: "p")?.reason == "Fatal error: Index out of range")
        #expect(CrashReport.parse(Data("not a report".utf8), path: "p") == nil)
    }

    func write(_ data: Data, _ name: String, in dir: URL, age: TimeInterval = 0) throws {
        let url = dir.appendingPathComponent(name)
        try data.write(to: url)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-age)], ofItemAtPath: url.path)
    }

    @Test func finderMatchesBundlePidAndSimulator() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cht-crash-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let sample = try Fixtures.crash("Fixture-sample")
        let text = String(decoding: sample, as: UTF8.self)
        try write(Data(text.replacingOccurrences(of: "39261", with: "1111").utf8), "Fixture-other-pid.ips", in: dir)
        try write(Data(text.replacingOccurrences(of: Self.udid, with: "4474DB35-730B-4017-AAB3-367700816901").utf8), "Fixture-other-sim.ips", in: dir)
        try write(Data(text.replacingOccurrences(of: "\"dev.chauffeur.fixture\"", with: "\"com.other\"").utf8), "Other.ips", in: dir)
        try write(sample, "Fixture-old.ips", in: dir, age: 3600)
        #expect(CrashFinder.find(bundle: "dev.chauffeur.fixture", pid: 39261, udid: Self.udid, since: Date().addingTimeInterval(-60), in: dir) == nil)
        try write(sample, "Fixture-2026-10-06-113443.ips", in: dir)
        let found = CrashFinder.find(bundle: "dev.chauffeur.fixture", pid: 39261, udid: Self.udid.lowercased(),
                                     since: Date().addingTimeInterval(-60), in: dir)
        #expect(found?.path.hasSuffix("Fixture-2026-10-06-113443.ips") == true)
    }

    @Test func zombiesAreNotAlive() throws {
        #expect(Proc.isAlive(getpid()))
        #expect(!Proc.isAlive(0) && !Proc.isAlive(-1))
        var pid: pid_t = 0
        let argv: [UnsafeMutablePointer<CChar>?] = [strdup("/usr/bin/true"), nil]
        defer { argv.forEach { free($0) } }
        #expect(posix_spawn(&pid, "/usr/bin/true", nil, nil, argv, environ) == 0)
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, Proc.isAlive(pid) { usleep(20_000) }
        #expect(!Proc.isAlive(pid) && kill(pid, 0) == 0)  // exited, unreaped: kill() still says it exists
        #expect(waitpid(pid, nil, 0) == pid)
    }

    @Test func trackedAppSurvivesADaemonRestart() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cht-\(UUID().uuidString).app.json")
        let app = TrackedApp(bundle: "dev.chauffeur.fixture", executable: "Fixture", displayName: "Fixture", pid: 42,
                             launchedAt: Date(timeIntervalSince1970: 1_800_000_000))
        app.save(url)
        #expect(TrackedApp.load(url) == app)
        TrackedApp.clear(url)
        #expect(TrackedApp.load(url) == nil)
    }

    @Test func anExitWithoutReportOrFatalLineIsNotCalledACrash() {
        let app = TrackedApp(bundle: "dev.chauffeur.fixture", executable: "Fixture", displayName: "Fixture", pid: 81606, launchedAt: Date())
        let info = CrashInfo(app: app, detectedAt: Date(), report: nil)
        #expect(info.render().first == "APP EXITED: dev.chauffeur.fixture (pid 81606) is gone · no crash report or fatal "
            + "log line (ended from outside chauffeur?); if it crashed, chauffeur logs shows the report when macOS writes it")
    }

    @Test func aFatalLineKeepsItACrash() {
        let lines = [LogLine(time: "12:16:25.1", level: "default", message: "fine"),
                     LogLine(time: "12:16:25.2", level: "fault", message: "fixture: crashing"),
                     LogLine(time: "12:16:25.3", level: "default", message: "Fixture/FixtureApp.swift:57: Fatal error: fixture crash", sender: "libswiftCore")]
        #expect(CrashInfo.fatalLine(in: lines) == "Fixture/FixtureApp.swift:57: Fatal error: fixture crash")
        #expect(CrashInfo.fatalLine(in: Array(lines.prefix(2))) == "fixture: crashing")
        #expect(CrashInfo.fatalLine(in: [lines[0]]) == nil)
        let app = TrackedApp(bundle: "dev.chauffeur.fixture", executable: "Fixture", displayName: "Fixture", pid: 72935, launchedAt: Date())
        var info = CrashInfo(app: app, detectedAt: Date(), report: nil)
        info.fatalLine = CrashInfo.fatalLine(in: lines)
        #expect(info.render().first?.hasPrefix("APP CRASHED: dev.chauffeur.fixture (pid 72935) · ") == true)
        #expect(info.render().contains { $0.contains("Fatal error: fixture crash") })
    }

    @Test func crashBlockWithAndWithoutAReport() throws {
        let app = TrackedApp(bundle: "dev.chauffeur.fixture", executable: "Fixture", displayName: "Fixture", pid: 39261, launchedAt: Date())
        #expect(CrashInfo(app: app, detectedAt: Date(), report: nil).render()
                == ["APP EXITED: dev.chauffeur.fixture (pid 39261) is gone · no crash report or fatal log line (ended from outside chauffeur?); if it crashed, chauffeur logs shows the report when macOS writes it"])
        let report = try #require(CrashReport.parse(try Fixtures.crash("Fixture-sample"), path: "/r/Fixture.ips"))
        #expect(CrashInfo(app: app, detectedAt: Date(), report: report).render() == [
            "APP CRASHED: dev.chauffeur.fixture (pid 39261) · EXC_BREAKPOINT (SIGTRAP)",
            "report: /r/Fixture.ips",
            "  libswiftCore.dylib _assertionFailure(_:_:file:line:flags:) + 156",
            "  Fixture closure #5 in closure #2 in closure #1 in HomeView.body.getter + 268",
            "  SwiftUI <deduplicated_symbol> + 24",
        ])
    }
}
