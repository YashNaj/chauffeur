import Foundation
import Testing
@testable import ChauffeurCore

@Suite struct DaemonTests {
    @Test func versionMismatchAsksTheClientToRestart() {
        var ran = false
        let (out, exitAfter) = Daemon.respond(to: Request(version: "0.0.1-old", args: ["snapshot"])) { _ in ran = true; return Output("x") }
        #expect(out.exit == Daemon.versionMismatchExit && exitAfter && !ran)
        let (ok, stay) = Daemon.respond(to: Request(version: Chauffeur.buildID, args: ["snapshot"])) { Output("ran \($0[0])") }
        #expect(ok == Output("ran snapshot") && !stay)
    }

    @Test func linesSurviveTheSocket() {
        var fds: [Int32] = [0, 0]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0)
        defer { close(fds[1]) }
        #expect(UnixSocket.writeAll(fds[0], Data("{\"a\":1}\n".utf8)))
        #expect(UnixSocket.readLine(fds[1]) == Data("{\"a\":1}".utf8))
        close(fds[0])
        #expect(UnixSocket.readLine(fds[1]) == nil)  // EOF
    }

    @Test func listenConnectRoundTrip() throws {
        let path = NSTemporaryDirectory() + "cht-\(UInt32.random(in: 0...UInt32.max)).sock"
        let server = try UnixSocket.listen(path: path)
        defer { close(server); unlink(path) }
        var mode = stat()
        #expect(stat(path, &mode) == 0 && mode.st_mode & 0o777 == 0o600)
        Thread {
            let c = accept(server, nil, nil)
            if let line = UnixSocket.readLine(c) { _ = UnixSocket.writeAll(c, line + Data("!\n".utf8)) }
            close(c)
        }.start()
        let client = try UnixSocket.connect(path: path, timeout: 5)
        defer { close(client) }
        #expect(UnixSocket.writeAll(client, Data("hi\n".utf8)))
        #expect(UnixSocket.readLine(client) == Data("hi!".utf8))
    }

    @Test func overlongPathsAreRejected() {
        #expect(throws: (any Error).self) { try UnixSocket.listen(path: "/tmp/" + String(repeating: "x", count: 120)) }
    }

    @Test func socketPathFitsTheLimit() {
        #expect(StatePaths.socket("AF7CFC76-936D-4E67-98F7-102C682E7ECD").path.utf8.count < 104)
    }
}
