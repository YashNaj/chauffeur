import Testing

@testable import ChauffeurCore

@Suite struct RequestEvidenceTests {
    func activity(_ id: Int, remote: String, tx: Int, rx: Int, open: Bool = true) -> FlowActivity {
        FlowActivity(
            flow: Flow(
                id: id, pid: 1, process: "Fixture", proto: "tcp", remote: remote, tx: tx, rx: rx, openedMs: id,
                closedMs: open ? nil : 99), sent: tx, received: rx, isNew: true)
    }
    let api = RequestRecord(task: "A.1", scheme: "https", host: "api.example.com", port: 443, path: "/login")

    @Test func aRecordExplainsItsConnection() {
        let items = RequestEvidence.merge(
            records: [api], activity: [activity(1, remote: "93.184.215.14:443", tx: 900, rx: 0)], streaming: [],
            telemetryExtra: [])
        #expect(items == [RequestItem(host: "api.example.com", port: 443, path: "/login", waiting: true)])
    }

    @Test func aConnectionNoRecordExplainsIsItsOwnItem() {
        let items = RequestEvidence.merge(
            records: [], activity: [activity(1, remote: "127.0.0.1:8765", tx: 58, rx: 0)], streaming: [],
            telemetryExtra: [])
        #expect(
            items == [
                RequestItem(
                    host: "127.0.0.1", port: 8765, sent: 58, received: 0, proto: "tcp", waiting: true,
                    hostKnown: false)
            ])
    }

    @Test func oneConnectionPerRecord() {
        let items = RequestEvidence.merge(
            records: [api],
            activity: [
                activity(1, remote: "93.184.215.14:443", tx: 900, rx: 0),
                activity(2, remote: "10.0.0.9:443", tx: 300, rx: 0),
            ], streaming: [], telemetryExtra: [])
        #expect(items.map(\.host) == ["api.example.com", "10.0.0.9"])
    }

    @Test func telemetryIsMarkedAndDoesNotCount() {
        var ping = api
        ping.host = "app-measurement.com"
        let items = RequestEvidence.merge(records: [ping], activity: [], streaming: [], telemetryExtra: [])
        #expect(items.map(\.telemetry) == [true])
        #expect(RequestEvidence.verdict(items) == .none(items))
    }

    @Test func projectEntriesAreTelemetryToo() {
        var metrics = api
        metrics.path = "/metrics/event"
        let items = RequestEvidence.merge(
            records: [metrics], activity: [], streaming: [], telemetryExtra: ["api.example.com/metrics"])
        #expect(items.map(\.telemetry) == [true])
    }

    @Test func streamingIsNotPending() {
        let socket = activity(1, remote: "127.0.0.1:8766", tx: 200, rx: 60)
        let items = RequestEvidence.merge(records: [], activity: [socket], streaming: [socket], telemetryExtra: [])
        #expect(items.map(\.streaming) == [true] && items.map(\.waiting) == [false])
        #expect(RequestEvidence.verdict(items) == .settled(items))
    }

    @Test func anyMissingReplyIsPending() {
        var done = api
        done.finished = true
        done.status = 200
        var open = api
        open.task = "A.2"
        let items = RequestEvidence.merge(records: [done, open], activity: [], streaming: [], telemetryExtra: [])
        #expect(RequestEvidence.verdict(items) == .pending(items))
        #expect(RequestEvidence.verdict([]) == .none([]))
    }
}
