import Darwin
import Foundation
import Testing

@testable import ChauffeurCore

@Suite struct FlowTests {
    @Test func aFlowFromTheBridge() throws {
        let d: [String: Any] = [
            "id": NSNumber(value: 7), "pid": NSNumber(value: 4321), "process": "Fixture", "provider": "TCP",
            "remote": "127.0.0.1:8765", "tx": NSNumber(value: 206), "rx": NSNumber(value: 0),
            "openedMs": NSNumber(value: 1000),
        ]
        let f = try #require(Flow(dictionary: d))
        #expect(
            f
                == Flow(
                    id: 7, pid: 4321, process: "Fixture", proto: "tcp", remote: "127.0.0.1:8765", tx: 206, rx: 0,
                    openedMs: 1000, closedMs: nil))
        #expect(f.isOpen && f.remoteHost == "127.0.0.1" && f.remotePort == 8765)
    }

    @Test func ipv6AndUnknownRemotes() {
        let v6 = Flow(
            id: 1, pid: 1, process: "", proto: "tcp", remote: "[::1]:8765", tx: 0, rx: 0, openedMs: 0,
            closedMs: 5)
        #expect(v6.remoteHost == "::1" && v6.remotePort == 8765 && !v6.isOpen)
        let none = Flow(
            id: 2, pid: 1, process: "", proto: "udp", remote: "", tx: 0, rx: 0, openedMs: 0,
            closedMs: nil)
        #expect(none.remoteHost == "" && none.remotePort == nil)
        #expect(Flow(dictionary: ["id": NSNumber(value: 1)]) == nil)  // no pid
    }

    @Test func processTree() throws {
        #expect(Proc.parent(getpid()) == getppid())
        let me = try #require(Proc.name(getpid()))
        #expect(Proc.children(of: getppid(), named: me).contains(getpid()))
        #expect(Proc.children(of: getppid(), named: "no-such-process-name").isEmpty)
    }
}
