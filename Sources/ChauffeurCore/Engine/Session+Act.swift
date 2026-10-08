import ChauffeurBridge
import Foundation

extension Session {
    /// The pre-action snapshot, taken once the screen has been quiet for 500 ms: freshly presented UI drops
    /// touches (Task 11), and a baseline captured before that wait would credit later changes to the action (I1).
    func baseline() throws -> (snapshot: Snapshot, settled: Bool) {
        var result = try observe(minMs: 0, capMs: 1500)
        for _ in 0..<4 {
            let quietMs = clock.nowMs() - lastChangeMs
            if quietMs >= 500 { break }
            clock.sleep(ms: 500 - quietMs)
            result = try observe(minMs: 0, capMs: 1500)
        }
        return (result.snapshot, result.settle.settled)
    }

    /// HID client and transports, built on first use; touch log started if it can be (else outcomes are UNVERIFIED).
    func transportsReady() throws -> [TouchTransport] {
        let (device, _) = try connect()
        if transports.isEmpty {
            do {
                let client = try CHHIDClient(simulator: device.sim)
                hid = client
                transports = [DigitizerTransport(hid: client), MouseTransport(hid: client)]
                preferred = 0
            } catch {
                throw ChauffeurError.bridge(error.localizedDescription)
            }
        }
        if !touchLog.isAttached, touchLogAttemptMs.map({ clock.nowMs() - $0 >= 30_000 }) ?? true {
            touchLogAttemptMs = clock.nowMs()
            try? touchLog.start()
        }
        return transports
    }

    /// Sends a gesture and reports what really happened (spec §6.2).
    func act(
        _ label: String, target: Node?, before: Snapshot, baselineSettled: Bool = true, capMs: Int = 1500,
        needsMove: Bool = false, gesture: (TouchTransport) -> Bool
    ) throws -> ActionReport {
        let all = try transportsReady()
        let order = (all[preferred...] + all[..<preferred]).filter { !needsMove || $0.supportsMove }
        guard !order.isEmpty else { throw ChauffeurError.bridge("no input transport supports this gesture") }
        var index = 0
        var retriedFrom: String?
        while true {
            let transport = order[index]
            let cursor = touchLog.cursor
            let sent = gesture(transport)
            let (after, settle) = try observe(minMs: 150, capMs: capMs)
            let evidence: Evidence =
                !touchLog.isAttached
                ? .unavailable
                : sent ? touchLog.evidence(since: cursor, waitMs: 200) : .none
            var outcome = Verifier.classify(
                treeChanged: after.hash != before.hash, evidence: evidence,
                expectedApp: expectedApp(on: before),
                systemFrontmost: before.kind.isSystem, retried: retriedFrom != nil,
                baselineSettled: baselineSettled)
            if outcome == .retry {
                if index + 1 < order.count {
                    retriedFrom = transport.name
                    index += 1
                    continue
                }
                outcome = .notDelivered
            }
            if !sent {
                hid = nil
                transports = []
            }  // rebuild the HID client next time
            if outcome != .notDelivered, let i = all.firstIndex(where: { $0 === transport }) { preferred = i }
            var report = ActionReport(
                action: label, outcome: outcome, evidence: evidence, settledMs: settle.elapsedMs,
                settled: settle.settled,
                revBefore: before.rev, revAfter: after.rev,
                diff: outcome == .changed ? Diff.lines(from: before, to: after) : [],
                transport: transport.name, retriedFrom: retriedFrom,
                hints: Verifier.hints(outcome: outcome, target: target), capMs: capMs)
            if outcome == .noEffect, let frame = target?.frame,
                let shot = try? capture(
                    screen: before.size, zoom: Verifier.evidenceRegion(target: frame, screen: before.size))
            {
                report.evidenceShot = shot.path
            }
            return report
        }
    }

    /// A ref or `x,y` → where to touch, the node (for hints), and the label for the report.
    func aim(_ target: String, in snap: Snapshot) throws -> (point: Point, node: Node?, label: String) {
        if target.wholeMatch(of: /e\d+/) != nil {
            let node = try snap.resolve(ref: target, refs: refs)
            traceTarget = node
            let f = node.frame
            let x0 = max(f.x, 0)
            let y0 = max(f.y, 0)
            let visible = Rect(x: x0, y: y0, w: min(f.maxX, snap.size.w) - x0, h: min(f.maxY, snap.size.h) - y0)
            return (
                Geometry.tapPoint(role: node.role, frame: visible), node,
                target + (node.name.map { " " + Perception.quote($0) } ?? "")
            )
        }
        guard let point = Self.point(target) else {
            throw ChauffeurError.usage(
                "expected a ref like e4 or a point like 201,344; got \(Perception.quote(target))")
        }
        return (point, nil, "(\(Geometry.fmt(point.x)),\(Geometry.fmt(point.y)))")
    }

    func tapCommand(_ argv: [String]) throws -> Output {
        var a = try Args(
            argv, flags: ["--edge"], options: ["--long"], usage: "usage: chauffeur tap <ref|x,y> [--long <s>] [--edge]")
        let holdMs = try a.number("--long", in: 0.05...30).map { Int($0 * 1000) } ?? 50
        let allowEdge = a.flag("--edge")
        guard let target = a.next() else { throw ChauffeurError.usage(a.usage) }
        try a.done()
        let (device, _) = try connect()
        let (before, settled) = try baseline()
        let aimed = try aim(target, in: before)
        if let refusal = Geometry.refusal(for: aimed.point, screen: device.size, allowEdge: allowEdge) {
            return Output("tap \(aimed.label) refused: \(refusal)", exit: 1)
        }
        var report = try act("tap \(aimed.label)", target: aimed.node, before: before, baselineSettled: settled) {
            Gestures.tap($0, at: aimed.point, screen: device.size, holdMs: holdMs)
        }
        // Right after typing, a switch can ignore the first touch that reaches the app (F1, M2 dogfood; reproduced in
        // M3a Task 7, no keyboard or overlay on screen). Its value is in the tree and did not change, so one more touch
        // cannot toggle it twice unnoticed.
        if report.outcome == .noEffect, aimed.node?.role == "switch", holdMs == 50 {
            let (again, settledAgain) = try baseline()
            if again.hash != before.hash {  // the first touch did work, only later than 1.5 s: never toggle it back
                report.outcome = .changed
                report.revAfter = again.rev
                report.diff = Diff.lines(from: before, to: again)
                report.hints = ["the switch changed only after 1.5s"]
                report.evidenceShot = nil
                return Output(report.render(), exit: report.exitCode, data: report.json)
            }
            var second = try act("tap \(aimed.label)", target: aimed.node, before: again, baselineSettled: settledAgain)
            {
                Gestures.tap($0, at: aimed.point, screen: device.size, holdMs: holdMs)
            }
            if second.outcome == .changed {
                second.hints.append(
                    "the first touch reached the app but the switch ignored it; chauffeur tapped once more")
            }
            report = second
        }
        return Output(report.render(), exit: report.exitCode, data: report.json)
    }

    /// `doctor --live`: one harmless tap per transport near the top centre (status bar), reporting delivery.
    func selftestCommand() throws -> Output {
        let (device, _) = try connect()
        let all = try transportsReady()
        guard touchLog.isAttached else { return Output("touch log unavailable: cannot verify delivery", exit: 1) }
        let point = Point(x: device.size.w / 2, y: 20)
        var lines: [String] = []
        var anyDelivered = false
        for transport in all {
            let cursor = touchLog.cursor
            let start = clock.nowMs()
            let sent = Gestures.tap(transport, at: point, screen: device.size)
            let evidence = touchLog.evidence(since: cursor, waitMs: 500)
            let ms = clock.nowMs() - start
            switch evidence {
            case .app(let bundle):
                lines.append("✓ \(transport.name): delivered to \(bundle) in \(ms)ms")
                anyDelivered = true
            case .system:
                lines.append("✓ \(transport.name): delivered to system UI in \(ms)ms")
                anyDelivered = true
            case .none:
                lines.append(
                    "✗ \(transport.name): " + (sent ? "sent, but no touch reached the simulator" : "send failed"))
            case .unavailable: lines.append("? \(transport.name): touch log stopped")
            }
            usleep(300_000)
        }
        return Output(lines.joined(separator: "\n"), exit: anyDelivered ? 0 : 3)
    }

    func typeCommand(_ argv: [String]) throws -> Output {
        var a = try Args(argv, flags: ["--submit"], usage: "usage: chauffeur type <ref> \"<text>\" [--submit]")
        let submit = a.flag("--submit")
        guard let ref = a.next(), let text = a.text(), !text.isEmpty else { throw ChauffeurError.usage(a.usage) }
        let (device, _) = try connect()
        let (before, settled) = try baseline()
        let field = try before.resolve(ref: ref, refs: refs)
        guard Perception.textEntry.contains(field.role) else {
            return Output(
                "\(ref) is a \(field.role), not a text field; type needs a textfield, securefield or searchfield ref",
                exit: 1)
        }
        let secure = field.role == "securefield"
        let label = "type \(ref)" + (secure ? " (\(text.count) characters)" : " " + Perception.quote(text))
        // `runOne` traced a provisional, text-free `type` until the field is known; a plain field may show its text.
        traceArgs = secure ? Self.redactedType(ref: ref, characters: text.count, submit: submit) : nil

        let aimed = try aim(ref, in: before)
        let focus = try act("tap \(aimed.label)", target: field, before: before, baselineSettled: settled) {
            Gestures.tap($0, at: aimed.point, screen: device.size)
        }
        switch focus.outcome {
        case .notDelivered, .intercepted:
            return Output(
                "\(label) → not typed: focusing the field failed\n" + focus.render(), exit: 3,
                data: ["focus": focus.json])
        default:
            break
        }
        let focused = last ?? before
        guard let hid else { throw ChauffeurError.bridge("HID client lost after focusing") }
        let keyboard = Keyboard(hid: hid)
        let method: String
        let sent: Bool
        if Keys.typeable(text) && text.count <= 15 {
            method = "keys"
            sent = keyboard.type(text)
        } else {
            method = "paste"
            let copied = try SimCtl.run(["pbcopy", udid], stdin: text, timeout: 15)
            guard copied.status == 0 else {
                return Output("\(label) → not typed: simctl pbcopy exited \(copied.status)", exit: 1)
            }
            sent = keyboard.press(Keys.v, modifiers: [Keys.command])
        }
        defer {
            // A pasted password must not stay on the simulator's pasteboard (M1 review minor); cleared once verified.
            if secure && method == "paste" { _ = try? SimCtl.run(["pbcopy", udid], stdin: "", timeout: 15) }
        }
        guard sent else {
            return Output(
                "\(label) → NOT DELIVERED: key events failed to send\nhint: input transport unhealthy — run `chauffeur doctor --live`",
                exit: 3)
        }

        // Verify the text before Return, so a submit that navigates away can't hide a failed entry (I2).
        let (typed, settle) = try observe(minMs: 150, capMs: 1500)
        let now = typed.node(identity: field.identity)
        let verdict = TypeCheck.verify(
            typed: text, before: focused.node(identity: field.identity) ?? field,
            after: now, submitted: false)
        let report = TypeReport(
            action: label, method: method, verdict: verdict, value: now?.value, settledMs: settle.elapsedMs)
        guard submit, verdict == .ok else { return Output(report.render(), exit: report.exitCode, data: report.json) }

        guard keyboard.press(Keys.returnKey) else {
            return Output(
                report.render() + "\nsubmit → NOT DELIVERED: Return failed to send", exit: 3,
                data: report.json.merging(["submit": "notDelivered"]))
        }
        let after = try observe(minMs: 150, capMs: 1500).snapshot
        let changed = after.hash != typed.hash
        let submitted =
            changed
            ? "submit → changed · rev \(typed.rev)→\(after.rev)\n"
                + Diff.lines(from: typed, to: after).joined(separator: "\n")
            : "submit → NO EFFECT · nothing changed after Return"
        return Output(
            report.render() + "\n" + submitted, exit: changed ? 0 : 3,
            data: report.json.merging(["submit": changed ? "changed" : "noEffect"]))
    }

    /// What the trace keeps of `type` into a secure field: everything but the text.
    nonisolated static func redactedType(ref: String, characters: Int, submit: Bool) -> [String] {
        ["type"] + (submit ? ["--submit"] : []) + ["--", ref, "<secret: \(characters) characters>"]
    }

    /// A `type` command line with its text hidden, for the trace and for batch reports: the text may be a password and
    /// it is only known to be harmless once the field resolves to a non-secure one. Lenient: it never throws.
    nonisolated static func provisionalType(_ argv: [String]) -> [String] {
        var submit = false
        var dataOnly = false
        var words: [String] = []
        for token in argv.dropFirst() {
            if !dataOnly, token == "--" {
                dataOnly = true
                continue
            }
            if !dataOnly, token.hasPrefix("--"), token.count > 2 {
                if token == "--submit" { submit = true }
                continue
            }
            words.append(token)
        }
        var out = ["type"] + (submit ? ["--submit"] : []) + ["--"]
        if let ref = words.first { out.append(ref) }
        let text = words.dropFirst().joined(separator: " ")
        if !text.isEmpty { out.append("<text: \(text.count) characters>") }
        return out
    }

    /// `argv` as it may be shown or traced before anything is known about its target.
    nonisolated static func shown(_ argv: [String]) -> [String] {
        argv.first == "type" ? provisionalType(argv) : argv
    }

    func scrollCommand(_ argv: [String]) throws -> Output {
        var a = try Args(
            argv, options: ["--in", "--until"],
            usage: "usage: chauffeur scroll <up|down|left|right> [--in <ref>] [--until \"<query>\"]")
        let inRef = a.option("--in")
        let until = a.option("--until")
        guard let direction = a.next() else { throw ChauffeurError.usage(a.usage) }
        try a.done()
        let (device, _) = try connect()
        var (snap, settled) = try baseline()
        let container = try inRef.map { try snap.resolve(ref: $0, refs: refs) }
        traceTarget = container
        let region =
            container.map { ScrollPlan.region($0.frame, screen: device.size) }
            ?? ScrollPlan.defaultRegion(screen: device.size)
        guard let drag = ScrollPlan.drag(direction, in: region) else { throw ChauffeurError.usage(a.usage) }
        // A drag that starts or ends at an edge triggers system gestures (I5).
        for p in [drag.from, drag.to] {
            if let refusal = Geometry.refusal(for: p, screen: device.size, allowEdge: false) {
                return Output(
                    "scroll \(direction) refused: \(refusal); the visible part of the region is too small", exit: 1)
            }
        }

        if let until, let hit = snap.find(until).first {
            return Output(
                "found \(snap.line(hit, all: false).trimmingCharacters(in: .whitespaces)) after 0 scrolls",
                data: ["found": hit.json(all: false), "scrolls": 0])
        }
        for n in 1...(until == nil ? 1 : 15) {
            var report = try act(
                "scroll \(direction)", target: nil, before: snap, baselineSettled: settled, needsMove: true
            ) {
                Gestures.drag($0, from: drag.from, to: drag.to, screen: device.size)
            }
            if report.outcome == .noEffect { report.hints = ["nothing moved: already at the end in that direction"] }
            guard let until else { return Output(report.render(), exit: report.exitCode, data: report.json) }
            let after = last ?? snap
            if let hit = after.find(until).first {
                return Output(
                    "found \(after.line(hit, all: false).trimmingCharacters(in: .whitespaces)) after \(n) scroll\(n == 1 ? "" : "s") \(direction)",
                    data: ["found": hit.json(all: false), "scrolls": JSON(n)])
            }
            if report.outcome != .changed {
                return Output(
                    "reached the end after \(n - 1) scrolls \(direction); no match for \(Perception.quote(until))\n"
                        + report.render(), exit: 4, data: report.json.merging(["found": .null, "scrolls": JSON(n - 1)]))
            }
            snap = after
            settled = true  // the previous scroll's observe settled before we got here
        }
        return Output("no match for \(Perception.quote(until ?? "")) after 15 scrolls \(direction)", exit: 4)
    }
}
