import Testing

@testable import ChauffeurCore

/// M4b spec §2: activity belongs to the tap when it started after the touch.
@Suite struct ConnectionWatchTests {
    func flow(_ id: Int, tx: Int, rx: Int, open: Bool = true, remote: String = "127.0.0.1:8765") -> Flow {
        Flow(
            id: id, pid: 1, process: "Fixture", proto: "tcp", remote: remote, tx: tx, rx: rx, openedMs: id,
            closedMs: open ? nil : 99)
    }

    @Test func aNewConnectionWaitingForItsReply() {
        let a = ConnectionWatch.activity(earlier: [], atTouch: [], now: [flow(1, tx: 206, rx: 0)])
        #expect(a.count == 1 && a[0].isNew && a[0].sent == 206 && a[0].waiting)
    }

    @Test func aReplyEndsTheWait() {
        let a = ConnectionWatch.activity(earlier: [], atTouch: [], now: [flow(1, tx: 206, rx: 94, open: false)])
        #expect(a.count == 1 && !a[0].waiting)
    }

    @Test func socketsThatMovedNoBytesAreDropped() {
        #expect(ConnectionWatch.activity(earlier: [], atTouch: [], now: [flow(1, tx: 0, rx: 0)]).isEmpty)
    }

    @Test func aReusedConnectionCountsWhatItSentAfterTheTouch() {
        let a = ConnectionWatch.activity(
            earlier: [flow(1, tx: 100, rx: 500)], atTouch: [flow(1, tx: 100, rx: 500)],
            now: [flow(1, tx: 300, rx: 500)])
        #expect(a.count == 1 && !a[0].isNew && a[0].sent == 200 && a[0].received == 0 && a[0].waiting)
    }

    @Test func alreadyFlowingIsNotTheTaps() {
        // A feed that was loading between the first sample and the touch keeps loading: someone else's traffic.
        let a = ConnectionWatch.activity(
            earlier: [flow(1, tx: 100, rx: 100)], atTouch: [flow(1, tx: 100, rx: 400)],
            now: [flow(1, tx: 200, rx: 600)])
        #expect(a.isEmpty)
    }

    @Test func aReplyToAnEarlierRequestIsNotTheTaps() {
        let a = ConnectionWatch.activity(
            earlier: [flow(1, tx: 100, rx: 0)], atTouch: [flow(1, tx: 100, rx: 0)], now: [flow(1, tx: 100, rx: 94)])
        #expect(a.isEmpty)
    }

    @Test func aConnectionThatKeepsReceivingIsStreaming() {
        let first = ConnectionWatch.activity(earlier: [], atTouch: [], now: [flow(1, tx: 200, rx: 20)])
        let later = ConnectionWatch.activity(earlier: [], atTouch: [], now: [flow(1, tx: 200, rx: 60)])
        #expect(ConnectionWatch.streaming(previous: first, now: later).map(\.flow.id) == [1])
        // Still sending, or closed: not a stream.
        let sending = ConnectionWatch.activity(earlier: [], atTouch: [], now: [flow(1, tx: 300, rx: 60)])
        #expect(ConnectionWatch.streaming(previous: first, now: sending).isEmpty)
        let closed = ConnectionWatch.activity(earlier: [], atTouch: [], now: [flow(1, tx: 200, rx: 60, open: false)])
        #expect(ConnectionWatch.streaming(previous: first, now: closed).isEmpty)
    }
}
