import Testing
@testable import ChauffeurCore

final class FakeClock: SettleClock {
    var now = 0
    func nowMs() -> Int { now }
    func sleep(ms: Int) { now += ms }
}

@Suite struct SettleTests {
    func run(_ hashes: [Int?], minMs: Int = 150, capMs: Int = 1500) -> (Settled<Int>, FakeClock) {
        let clock = FakeClock()
        var i = 0
        let result = Settle.wait(minMs: minMs, capMs: capMs, pollMs: 75, clock: clock) { () -> (value: Int, hash: Int)? in
            defer { i += 1 }
            let h = hashes[min(i, hashes.count - 1)]
            return h.map { (value: i, hash: $0) }
        }
        return (result, clock)
    }

    @Test func settlesOnTwoEqualReadsAfterMinimum() {
        let (r, _) = run([1, 2, 2])
        #expect(r.settled && r.elapsedMs == 150 && r.value == 2)
    }

    @Test func equalReadsBeforeMinimumKeepPolling() {
        let (r, _) = run([1, 1, 1], minMs: 150)
        #expect(r.settled && r.elapsedMs == 150)
    }

    @Test func zeroMinimumSettlesOnSecondRead() {
        let (r, _) = run([7, 7], minMs: 0)
        #expect(r.settled && r.elapsedMs == 75)
    }

    @Test func notReadyReadsDoNotCount() {
        let (r, _) = run([nil, nil, 5, 5], minMs: 0)
        #expect(r.settled && r.value == 3)
    }

    @Test func givesUpAtCapWithLastGoodValue() {
        var hashes: [Int?] = Array(0..<100)
        hashes.append(nil)
        let (r, _) = run(hashes, capMs: 300)
        #expect(!r.settled && r.elapsedMs >= 300 && r.value != nil)
    }

    @Test func nothingEverReady() {
        let (r, _) = run([nil], capMs: 300)
        #expect(!r.settled && r.value == nil)
    }
}
