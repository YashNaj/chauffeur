import Foundation

/// The network half of a tap's verdict, once the screen has settled (M4b spec §3, Findings §6).
public enum NetJudge {
    /// Log lines arrive 0–10 ms after the event (Findings §6): the most a dead tap pays.
    public static let graceMs = 20
    /// How long a missing reply is waited for before the tap is PENDING.
    public static let requestWindowMs = 2000
    /// A debounced request (search as you type) starts after the screen settled (spec §2, "Delayed requests").
    public static let textFieldWindowMs = 500
    /// After every reply arrived, one more look: a stream shows itself by still receiving, and a reply may start the
    /// next request of a chain.
    public static let confirmMs = 300
    static let pollMs = 100

    /// `sample` reads both layers afresh and merges them. Nothing the tap caused → `.none` after the grace, with no
    /// window and no second look.
    public static func judge(
        clock: some SettleClock, extraWindowMs: Int = 0, sample: () -> [RequestItem]
    ) -> NetVerdict {
        clock.sleep(ms: graceMs)
        var verdict = RequestEvidence.verdict(sample())
        let lateUntil = clock.nowMs() + extraWindowMs
        while case .none = verdict, clock.nowMs() < lateUntil {
            clock.sleep(ms: pollMs)
            verdict = RequestEvidence.verdict(sample())
        }
        var deadline = clock.nowMs() + requestWindowMs
        var confirmed = false
        while true {
            switch verdict {
            case .pending where clock.nowMs() < deadline:
                clock.sleep(ms: pollMs)
                verdict = RequestEvidence.verdict(sample())
            case .settled where !confirmed:
                confirmed = true
                clock.sleep(ms: confirmMs)
                verdict = RequestEvidence.verdict(sample())
                if case .pending = verdict { deadline = clock.nowMs() + requestWindowMs }
            default:
                return verdict
            }
        }
    }
}
