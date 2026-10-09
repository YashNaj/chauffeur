import Foundation

extension Session {
    /// Waits stay below the client's reply timeout, so a long wait can't look like a dead daemon (C1).
    nonisolated static let maxWaitSeconds = 300.0
    nonisolated static func waitTimeout(_ seconds: Double?) -> Double {
        min(seconds ?? 10, maxWaitSeconds)
    }

    func waitCommand(_ argv: [String]) throws -> Output {
        var a = try Args(
            argv, flags: ["--gone"], options: ["--timeout"],
            usage: "usage: chauffeur wait \"<query>\" [--gone] [--timeout <s>]")
        let gone = a.flag("--gone")
        let timeout = Self.waitTimeout(try a.number("--timeout", in: 0...86_400))
        guard let query = a.text() else { throw ChauffeurError.usage(a.usage) }
        let start = clock.nowMs()
        var lastHeader = "no tree yet"
        while true {
            do {
                let snap = try observe(minMs: 0, capMs: 500).snapshot
                lastHeader = snap.header
                let hits = snap.find(query)
                let elapsed = clock.nowMs() - start
                if gone && hits.isEmpty {
                    return Output("gone after \(elapsed)ms", data: ["gone": true, "elapsedMs": JSON(elapsed)])
                }
                if !gone && !hits.isEmpty {
                    return Output(
                        "found after \(elapsed)ms\n"
                            + hits.map { snap.line($0, all: false).trimmingCharacters(in: .whitespaces) }.joined(
                                separator: "\n"),
                        data: [
                            "found": true, "elapsedMs": JSON(elapsed),
                            "matches": .array(hits.map { $0.json(all: false) }),
                        ])
                }
            } catch let error as ChauffeurError where error.appNotUpYet {
                // app still launching; keep waiting
            }
            if Double(clock.nowMs() - start) >= timeout * 1000 {
                return Output(
                    (gone ? "still present" : "not found") + " after \(Geometry.fmt(timeout))s: "
                        + Perception.quote(query) + "\nscreen: " + lastHeader, exit: 4,
                    data: [gone ? "gone" : "found": false, "screen": .string(lastHeader)])
            }
            clock.sleep(ms: 100)
        }
    }
}
