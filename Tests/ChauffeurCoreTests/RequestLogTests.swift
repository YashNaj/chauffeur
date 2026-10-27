import Testing

@testable import ChauffeurCore

/// M4b spec §2 (detail layer) on lines recorded in step 0 (Findings §4).
@Suite struct RequestLogTests {
    @Test func recordedRequestsOnIOS27() throws {
        let r = RequestLog.parse(try Fixtures.network("ios27-requests"))
        #expect(r.count == 5)
        #expect(
            r[0]
                == RequestRecord(
                    task: "A450514C-ADE9-4A5B-8EB7-AEC43FD10CDB.1", scheme: "http", host: "localhost", port: 8765,
                    path: "/fail", status: 500, finished: true, ms: 481, serverMs: 1, sent: 206, received: 113,
                    proto: "http/1.1", bodyBytes: 0))
        #expect(
            r[1]
                == RequestRecord(
                    task: "846CF447-8C22-4037-91D1-264405128DE8.2", scheme: "https", host: "example.com", port: 443,
                    path: "/a/{id}", status: 404, finished: true, ms: 239, serverMs: 31, sent: 115, received: 487,
                    proto: "h2", bodyBytes: 0))
        #expect(
            r[2]
                == RequestRecord(
                    task: "E8F6340D-1EB2-4D9F-8010-8B310302409F.3", scheme: "http", host: "localhost", port: 8765,
                    path: "/fast", errorCode: -1004, finished: true, ms: 107, sent: 0, received: 0))
        #expect(
            r[3]
                == RequestRecord(
                    task: "F8F70ACA-50C3-48C8-BD85-08965D45B2E2.1", scheme: "http", host: "localhost", port: 8765,
                    path: "/fast", status: 201, finished: true, ms: 175, serverMs: 1, sent: 300, received: 104,
                    proto: "http/1.1", bodyBytes: 14))
        #expect(r[4].path == "/slow" && r[4].status == 200 && r[4].serverMs == 2511 && r[4].ms == 2525)
    }

    @Test func aReusedConnectionGivesTheHostButNoPath() throws {
        let r = RequestLog.parse(try Fixtures.network("ios26-keepalive"))
        #expect(r.map(\.path) == ["/fast", nil])
        #expect(r.map(\.host) == ["localhost", "localhost"])
        #expect(r.map(\.status) == [200, 500])
        #expect(r[1].port == 8765)
    }

    @Test func tasksThatStartedEarlierAreIgnored() throws {
        let lines = try Fixtures.network("ios26-keepalive")
        // Task 6's `resuming` line came before this action's cursor: its later lines are not this action's.
        let r = RequestLog.parse(Array(lines.dropFirst()))
        #expect(r.map(\.task) == ["F230B378-BAE0-497B-9678-B5343E934411.7"])
    }

    @Test func aTaskWithoutItsEndIsStillRunning() throws {
        let slow = try Fixtures.network("ios27-requests").filter {
            $0.message.contains("FE43492F") || $0.message.hasPrefix("[C2 9838CC02")
        }
        // resuming, the connection's url line, setting up, now using, sent request: no reply yet.
        let r = RequestLog.parse(Array(slow.prefix(5)))
        #expect(r.count == 1 && !r[0].finished && r[0].path == "/slow" && r[0].status == nil)
    }

    @Test func otherLinesAreIgnored() {
        let lines = [
            LogLine(time: "t", level: "error", message: "Task <AB>.<1> resuming", sender: nil),  // the app's own
            LogLine(time: "t", level: "default", message: "[C1.1.1 IPv6#5dac:8765 failed]", sender: "Network"),
        ]
        #expect(RequestLog.parse(lines).isEmpty)
    }
}
