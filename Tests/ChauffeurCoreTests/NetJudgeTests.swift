import Testing

@testable import ChauffeurCore

/// M4b spec §3: the request window only runs while the app waits for a reply.
@Suite struct NetJudgeTests {
    let open = RequestItem(host: "api.example.com", port: 443, path: "/login", waiting: true)
    let done = RequestItem(host: "api.example.com", port: 443, path: "/login", status: 200)

    @Test func aTrueNoOpIsNotDelayed() {
        let clock = FakeClock()
        #expect(NetJudge.judge(clock: clock) { [] } == .none([]))
        #expect(clock.now == NetJudge.graceMs)
    }

    @Test func telemetryOnlyIsNoEffect() {
        let clock = FakeClock()
        let ping = RequestItem(host: "app-measurement.com", waiting: true, telemetry: true)
        #expect(NetJudge.judge(clock: clock) { [ping] } == .none([ping]))
        #expect(clock.now == NetJudge.graceMs)
    }

    @Test func aReplyWithinTheWindowSettles() {
        let clock = FakeClock()
        let verdict = NetJudge.judge(clock: clock) { clock.now < 300 ? [open] : [done] }
        #expect(verdict == .settled([done]))
        #expect(clock.now < 300 + NetJudge.confirmMs + 200)
    }

    @Test func noReplyWithinTheWindowIsPending() {
        let clock = FakeClock()
        #expect(NetJudge.judge(clock: clock) { [open] } == .pending([open]))
        #expect(clock.now == NetJudge.graceMs + NetJudge.requestWindowMs)
    }

    @Test func aRequestChainedOnTheReplyIsWaitedFor() {
        let clock = FakeClock()
        let next = RequestItem(host: "api.example.com", port: 443, path: "/profile", waiting: true)
        // /login answers at once; its reply starts /profile, which never answers.
        let verdict = NetJudge.judge(clock: clock) { clock.now < 100 ? [done] : [done, next] }
        #expect(verdict == .pending([done, next]))
    }

    @Test func aDebouncedRequestIsCaughtOnlyWithTheTextFieldWindow() {
        let late = FakeClock()
        #expect(
            NetJudge.judge(clock: late, extraWindowMs: NetJudge.textFieldWindowMs) {
                late.now < 320 ? [] : [open]
            } == .pending([open]))
        let plain = FakeClock()
        #expect(NetJudge.judge(clock: plain) { plain.now < 320 ? [] : [open] } == .none([]))
    }
}
