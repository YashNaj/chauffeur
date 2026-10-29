import Testing

@testable import ChauffeurCore

/// M4b spec §3: the request window only runs while the app waits for a reply.
@Suite struct NetJudgeTests {
    let open = RequestItem(host: "api.example.com", port: 443, path: "/login", waiting: true)
    let done = RequestItem(host: "api.example.com", port: 443, path: "/login", status: 200)

    @Test func aTrueNoOpIsNotDelayed() {
        let clock = FakeClock()
        #expect(NetJudge.judge(clock: clock, touchMs: 0) { [] } == .none([]))
        #expect(clock.now == NetJudge.graceMs)
    }

    @Test func telemetryOnlyIsNoEffect() {
        let clock = FakeClock()
        let ping = RequestItem(host: "app-measurement.com", waiting: true, telemetry: true)
        #expect(NetJudge.judge(clock: clock, touchMs: 0) { [ping] } == .none([ping]))
        #expect(clock.now == NetJudge.graceMs)
    }

    @Test func aReplyWithinTheWindowSettles() {
        let clock = FakeClock()
        let verdict = NetJudge.judge(clock: clock, touchMs: 0) { clock.now < 300 ? [open] : [done] }
        #expect(verdict == .settled([done]))
        #expect(clock.now < 300 + NetJudge.confirmMs + 200)
    }

    @Test func noReplyWithinTheWindowIsPending() {
        let clock = FakeClock()
        #expect(NetJudge.judge(clock: clock, touchMs: 0) { [open] } == .pending([open]))
        #expect(clock.now == NetJudge.graceMs + NetJudge.requestWindowMs)
    }

    /// The window counts from the touch (spec §3: "still running after 2.2 s"), so a screen that is slow to settle
    /// doesn't push a 2.5 s reply inside it. Here the settle took 1.5 s.
    @Test func aSlowSettleDoesNotExtendTheWindow() {
        let clock = FakeClock()
        clock.now = 1500
        #expect(NetJudge.judge(clock: clock, touchMs: 0) { [open] } == .pending([open]))
        #expect(clock.now == 1500 + NetJudge.graceMs + 500)
    }

    @Test func aRequestChainedOnTheReplyIsWaitedFor() {
        let clock = FakeClock()
        let next = RequestItem(host: "api.example.com", port: 443, path: "/profile", waiting: true)
        // /login answers at once; its reply starts /profile, which never answers.
        let verdict = NetJudge.judge(clock: clock, touchMs: 0) { clock.now < 100 ? [done] : [done, next] }
        #expect(verdict == .pending([done, next]))
    }

    @Test func aDebouncedRequestIsCaughtOnlyWithTheTextFieldWindow() {
        let late = FakeClock()
        #expect(
            NetJudge.judge(clock: late, touchMs: 0, extraWindowMs: NetJudge.textFieldWindowMs) {
                late.now < 320 ? [] : [open]
            } == .pending([open]))
        let plain = FakeClock()
        #expect(NetJudge.judge(clock: plain, touchMs: 0) { plain.now < 320 ? [] : [open] } == .none([]))
    }

    // `finish`: a bare `wait` (M4b spec §9).

    /// It samples every 200 ms until the reply arrives, and returns then: no grace, no confirm look.
    @Test func finishReturnsWhenTheReplyArrivesAndNeverConfirms() {
        let clock = FakeClock()
        let verdict = NetJudge.finish(clock: clock, timeoutMs: 30_000) { clock.now < 1000 ? [open] : [done] }
        #expect(verdict == .settled([done]))
        #expect(clock.now <= 1200)
    }

    @Test func finishStopsAtTheTimeout() {
        let clock = FakeClock()
        #expect(NetJudge.finish(clock: clock, timeoutMs: 30_000) { [open] } == .pending([open]))
        #expect(clock.now == 30_000)
    }
}
