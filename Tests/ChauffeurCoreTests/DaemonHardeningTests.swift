import Darwin
import Foundation
import Testing

@testable import ChauffeurCore

/// M1 review minors folded into M2: request udid/cwd, state-dir checks, daemon status by socket.
@Suite struct DaemonHardeningTests {
    @Test func requestsFromOlderClientsStillGetTheVersionHandshake() throws {
        let old = try JSONDecoder().decode(
            Request.self, from: Data(#"{"version":"0.0.1-old","args":["snapshot"]}"#.utf8))
        #expect(old.udid == nil && old.cwd == nil)
        let (out, exitAfter) = Daemon.respond(to: old, serving: "AAAA-1") { _ in Output("ran") }
        #expect(out.exit == Daemon.versionMismatchExit && exitAfter)
    }

    @Test func aDaemonRefusesRequestsForAnotherSimulator() {
        var ran = false
        let wrong = Request(version: Chauffeur.buildID, args: ["tap", "e1"], udid: "AF7CFC76-OTHER", cwd: "/tmp")
        let (out, exitAfter) = Daemon.respond(to: wrong, serving: "AF7CFC76-936D") { _ in
            ran = true
            return Output("x")
        }
        #expect(out.exit == 1 && !exitAfter && !ran)
        #expect(out.text.hasPrefix("this daemon serves AF7CFC76-936D, not AF7CFC76-OTHER"))
        let right = Request(version: Chauffeur.buildID, args: ["tap"], udid: "af7cfc76-936d", cwd: nil)
        #expect(Daemon.respond(to: right, serving: "AF7CFC76-936D") { _ in Output("ran") }.0 == Output("ran"))
    }

    func tempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cht-dir-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func mode(_ url: URL) -> mode_t {
        var st = stat()
        lstat(url.path, &st)
        return st.st_mode & 0o777
    }

    @Test func stateDirIsCreatedPrivateAndTightened() throws {
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let fresh = root.appendingPathComponent("chauffeur")
        try StatePaths.ensureDir(fresh)
        #expect(mode(fresh) == 0o700)
        chmod(fresh.path, 0o755)
        try StatePaths.ensureDir(fresh)
        #expect(mode(fresh) == 0o700)
    }

    @Test func aSymlinkedStateDirIsRefused() throws {
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let real = root.appendingPathComponent("elsewhere")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        let link = root.appendingPathComponent("chauffeur")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        #expect(throws: ChauffeurError.self) { try StatePaths.ensureDir(link) }
    }

    @Test func daemonStatusNeedsAListeningSocketNotJustAPidfile() throws {
        let udid = "ZZ" + String(format: "%06X", UInt32.random(in: 0...0xFFFFFF)) + "-TEST"
        try StatePaths.ensureDir()
        try "\(getpid())".write(to: StatePaths.pidfile(udid), atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: StatePaths.pidfile(udid)) }
        #expect(Doctor.daemonStatus(udid).running == false)  // a live pid in the pidfile is not enough
        let listener = try UnixSocket.listen(path: StatePaths.socket(udid).path)
        defer {
            close(listener)
            unlink(StatePaths.socket(udid).path)
        }
        let status = Doctor.daemonStatus(udid)
        #expect(status.running && status.pid == getpid())
    }

    @Test @MainActor func relativePathsResolveAgainstTheClientDirectory() {
        let s = Session(udid: "ZZ000000-TEST")
        s.cwd = "/Users/someone/project"
        #expect(s.resolvePath("build/App.app").path == "/Users/someone/project/build/App.app")
        #expect(s.resolvePath("../other/App.app").path == "/Users/someone/other/App.app")
        #expect(s.resolvePath("/abs/App.app").path == "/abs/App.app")
        #expect(s.resolvePath("~/App.app").path == NSHomeDirectory() + "/App.app")
    }
}
