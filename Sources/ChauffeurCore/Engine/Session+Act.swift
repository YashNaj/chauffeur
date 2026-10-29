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

    /// The input device, built on first use from the connected simulator.
    func inputDeviceReady() throws -> any InputDevice {
        if let inputDevice { return inputDevice }
        let (device, _) = try connect()
        let made = try environment.inputs(device)
        inputDevice = made
        preferred = 0
        return made
    }

    /// The input device's transports; touch log started if it can be (else outcomes are UNVERIFIED).
    func transportsReady() throws -> [any TouchTransport] {
        _ = try connect()
        let transports = try inputDeviceReady().transports()
        if !touchLog.isAttached, touchLogAttemptMs.map({ clock.nowMs() - $0 >= 30_000 }) ?? true {
            touchLogAttemptMs = clock.nowMs()
            try? touchLog.start()
        }
        return transports
    }

    /// Sends a gesture and reports what really happened (spec §6.2): the classifier reads the screen and the evidence,
    /// then each pass may upgrade the report. Without a gesture, one attempt and no transport.
    func act(
        _ label: String, target: Node?, before: Snapshot, baselineSettled: Bool = true, capMs: Int = 1500,
        needsMove: Bool = false, network: NetStart? = nil, classifier: any Classifier = TouchClassifier(),
        passes: [any EvidencePass] = [], shot: Bool = true, gesture: ((any TouchTransport) -> Bool)?
    ) throws -> ActionReport {
        let all = try gesture == nil ? [] : transportsReady()
        let order = all.isEmpty ? [] : (all[preferred...] + all[..<preferred]).filter { !needsMove || $0.supportsMove }
        guard gesture == nil || !order.isEmpty else {
            throw ChauffeurError.bridge("no input transport supports this gesture")
        }
        var index = 0
        var retriedFrom: String?
        while true {
            let transport = gesture == nil ? nil : order[index]
            let cursor = touchLog.cursor
            let net = network.map { tapNet($0) }
            let touchMs = net?.touchMs ?? clock.nowMs()
            let attempt =
                if let gesture, let transport {
                    Attempt(
                        sent: gesture(transport), touchCursor: cursor, transport: transport.name,
                        retriedFrom: retriedFrom, isLast: index + 1 == order.count)
                } else {
                    Attempt.noTouch
                }
            let context = ActionContext(
                label: label, before: before, baselineSettled: baselineSettled, target: target, capMs: capMs,
                touchMs: touchMs, net: net, expectedApp: expectedApp(on: before),
                isTouchLogAttached: { [self] in touchLog.isAttached }, clock: clock,
                observe: { [self] in try observe(minMs: $0, capMs: $1) },
                touchEvidence: { [self] in touchLog.evidence(since: $0, waitMs: 200) }, gesture: gesture)
            var (report, _) = try classifier.classify(context: context, attempt: attempt)
            if let transport {
                if report.outcome == .retry {
                    retriedFrom = transport.name
                    index += 1
                    continue
                }
                if report.outcome != .notDelivered, let i = all.firstIndex(where: { $0 === transport }) {
                    preferred = i
                }
                if !attempt.sent {
                    // The device rebuilds its client on the next action, which starts again on the first transport.
                    inputDevice?.reset()
                    inputDeviceLost = true
                    preferred = 0
                }
            }
            for pass in passes { try pass.apply(to: &report, context: context, session: self) }
            if let net {
                applyNetwork(&report, net: net, target: target)
                if report.outcome == .pending {
                    pendingTap = PendingTap(report: report, before: before, net: net, target: target)
                }
                try judgeScreenAgain(&report, before: before, net: net, capMs: capMs)
            }
            if report.outcome == .noEffect, let frame = target?.frame,
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
        let network = netStart()
        let peek: @Sendable () -> ClipboardMark? = { [udid, shell] in Self.readClipboard(udid: udid, shell: shell) }
        let clipboard = Background(peek)
        let (before, settled) = try baseline()
        let aimed = try aim(target, in: before)
        if let refusal = Geometry.refusal(for: aimed.point, screen: device.size, allowEdge: allowEdge) {
            return Output("tap \(aimed.label) refused: \(refusal)", exit: .error)
        }
        let clipboardBefore = clipboard.result(waitingAtMost: 2000) ?? nil
        var report = try act(
            "tap \(aimed.label)", target: aimed.node, before: before, baselineSettled: settled, network: network
        ) { [self] in
            Gestures.tap($0, at: aimed.point, screen: device.size, holdMs: holdMs, clock: clock)
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
            var second = try act(
                "tap \(aimed.label)", target: aimed.node, before: again, baselineSettled: settledAgain,
                network: netStart()
            ) { [self] in
                Gestures.tap($0, at: aimed.point, screen: device.size, holdMs: holdMs, clock: clock)
            }
            if second.outcome == .changed {
                second.hints.append(
                    "the first touch reached the app but the switch ignored it; chauffeur tapped once more")
            }
            report = second
        }
        // A copy changes nothing on screen; read the pasteboard again only then (spec §7: a read costs ~100 ms).
        if report.outcome == .noEffect,
            let copied = ClipboardMark.copied(before: clipboardBefore, after: peek())
        {
            report.outcome = .changed
            report.copiedCharacters = copied
            report.hints = []
            report.evidenceShot = nil
        }
        return Output(report.render(), exit: report.exitCode, data: report.json)
    }

    /// `doctor --live`: one harmless tap per transport near the top centre (status bar), reporting delivery.
    func selftestCommand() throws -> Output {
        let (device, _) = try connect()
        let all = try transportsReady()
        guard touchLog.isAttached else { return Output("touch log unavailable: cannot verify delivery", exit: .error) }
        let point = Point(x: device.size.w / 2, y: 20)
        var lines: [String] = []
        var anyDelivered = false
        for transport in all {
            let cursor = touchLog.cursor
            let start = clock.nowMs()
            let sent = Gestures.tap(transport, at: point, screen: device.size, clock: clock)
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
            clock.sleep(ms: 300)
        }
        return Output(lines.joined(separator: "\n"), exit: anyDelivered ? .ok : .noEffect)
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
                    "scroll \(direction) refused: \(refusal); the visible part of the region is too small", exit: .error
                )
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
            ) { [self] in
                Gestures.drag($0, from: drag.from, to: drag.to, screen: device.size, clock: clock)
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
                        + report.render(), exit: .notFound,
                    data: report.json.merging(["found": .null, "scrolls": JSON(n - 1)]))
            }
            snap = after
            settled = true  // the previous scroll's observe settled before we got here
        }
        return Output("no match for \(Perception.quote(until ?? "")) after 15 scrolls \(direction)", exit: .notFound)
    }
}
