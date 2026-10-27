import Darwin
import Foundation
import Testing

@testable import ChauffeurCore

@Suite(.enabled(if: Live.enabled))
@MainActor struct NetStatsLiveTests {
    /// A listening socket on 127.0.0.1 and its port.
    func listener() -> (fd: Int32, addr: sockaddr_in, port: Int) {
        let server = socket(AF_INET, SOCK_STREAM, 0)
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(server, $0, len) }
        }
        listen(server, 1)
        _ = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(server, $0, &len) }
        }
        return (server, addr, Int(UInt16(bigEndian: addr.sin_port)))
    }

    func connect(_ client: Int32, to addr: sockaddr_in) -> Int32 {
        var addr = addr
        return withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(client, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
    }

    @Test func seesThisProcesssConnection() throws {
        let source = try NetStatsSource()
        let (server, addr, port) = listener()
        defer { close(server) }
        let client = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(client) }
        #expect(connect(client, to: addr) == 0)
        let bytes = [UInt8](repeating: 65, count: 100)
        #expect(send(client, bytes, bytes.count, 0) == 100)
        usleep(300_000)
        let flows = source.flows(pids: [getpid()])
        #expect(flows.contains { $0.remotePort == port && $0.tx >= 100 && $0.isOpen }, "\(flows)")
    }

    /// The kernel reports a socket as soon as it exists, before it has a remote address (M4b live run, 2026-10-27:
    /// a WebSocket and a web view's request showed as "a request"). A later sample must learn where it went.
    @Test func aSocketSeenBeforeItConnectedGetsItsRemoteLater() throws {
        let source = try NetStatsSource()
        let (server, addr, port) = listener()
        defer { close(server) }
        let client = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(client) }
        usleep(300_000)
        _ = source.flows(pids: [getpid()])  // seen while unconnected
        #expect(connect(client, to: addr) == 0)
        let bytes = [UInt8](repeating: 65, count: 100)
        #expect(send(client, bytes, bytes.count, 0) == 100)
        usleep(300_000)
        _ = source.flows(pids: [getpid()])  // asks again for what it didn't know
        usleep(200_000)
        let flows = source.flows(pids: [getpid()])
        #expect(flows.contains { $0.remotePort == port && $0.tx >= 100 && $0.isOpen }, "\(flows)")
    }
}
