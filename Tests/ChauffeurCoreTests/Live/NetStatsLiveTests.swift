import Darwin
import Foundation
import Testing

@testable import ChauffeurCore

@Suite(.enabled(if: Live.enabled))
@MainActor struct NetStatsLiveTests {
    @Test func seesThisProcesssConnection() throws {
        let source = try NetStatsSource()
        let server = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(server) }
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
        let port = Int(UInt16(bigEndian: addr.sin_port))
        let client = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(client) }
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(client, $0, len) }
        }
        #expect(connected == 0)
        let bytes = [UInt8](repeating: 65, count: 100)
        #expect(send(client, bytes, bytes.count, 0) == 100)
        usleep(300_000)
        let flows = source.flows(pids: [getpid()])
        #expect(flows.contains { $0.remotePort == port && $0.tx >= 100 && $0.isOpen }, "\(flows)")
    }
}
