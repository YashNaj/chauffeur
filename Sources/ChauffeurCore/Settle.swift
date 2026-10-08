import Foundation

public protocol SettleClock {
    func nowMs() -> Int
    func sleep(ms: Int)
}

public struct SystemClock: SettleClock {
    public init() {}
    public func nowMs() -> Int { Int(DispatchTime.now().uptimeNanoseconds / 1_000_000) }
    public func sleep(ms: Int) { usleep(UInt32(ms) * 1000) }
}

public struct Settled<T> {
    public var value: T?
    public var elapsedMs: Int
    public var settled: Bool
}

/// Polls until two consecutive reads hash the same and `minMs` has passed (spec §6.3).
public enum Settle {
    public static func wait<T>(
        minMs: Int = 150, capMs: Int, pollMs: Int = 75, clock: some SettleClock,
        read: () -> (value: T, hash: Int)?
    ) -> Settled<T> {
        let start = clock.nowMs()
        var previous: (value: T, hash: Int)?
        var lastGood: T?
        while true {
            let current = read()
            let elapsed = clock.nowMs() - start
            if let current {
                lastGood = current.value
                if let previous, previous.hash == current.hash, elapsed >= minMs {
                    return Settled(value: current.value, elapsedMs: elapsed, settled: true)
                }
            }
            previous = current
            if elapsed >= capMs { return Settled(value: lastGood, elapsedMs: elapsed, settled: false) }
            clock.sleep(ms: pollMs)
        }
    }
}
