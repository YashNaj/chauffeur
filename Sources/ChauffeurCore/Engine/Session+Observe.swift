import Foundation

extension Session {
    /// Polls the raw tree until it settles, completes it (bar sweep) and publishes a snapshot.
    /// No tree within the cap: reconnect once (SpringBoard restart), then give up.
    func observe(minMs: Int, capMs: Int) throws -> (snapshot: Snapshot, settle: Settled<AXElement>) {
        let started = clock.nowMs()
        var (device, ax) = try connect()
        var result = poll(ax, minMs: minMs, capMs: capMs)
        if result.value == nil {
            drop()
            (device, ax) = try connect()
            result = poll(ax, minMs: minMs, capMs: capMs)
        }
        if result.value == nil {
            let now = clock.nowMs()
            let since = AXHealth.episodeStart(
                current: noTreeSinceMs, lastFailureMs: lastNoTreeMs,
                attemptStartedMs: started, nowMs: now)
            noTreeSinceMs = since
            lastNoTreeMs = now
            let plan = heal(noTreeForMs: now - since, ax: ax, screen: device.size)
            if plan.relaunchApp {
                let why = AXHealth.message(plan, recovered: false)
                if let bundle = relaunchCandidate(ax) { throw ChauffeurError.needsRelaunch(bundle: bundle, why: why) }
                throw ChauffeurError.blind(why)
            }
            if plan.restartBridge {
                result = poll(ax, minMs: minMs, capMs: max(capMs, 3000))
                if result.value == nil { throw ChauffeurError.blind(AXHealth.message(plan, recovered: false)) }
                healNote = AXHealth.message(plan, recovered: true)
            }
        }
        guard let root = result.value else { throw ChauffeurError.noTree }
        noTreeSinceMs = nil
        guard Geometry.orientation(root: root.frame, screen: device.size) == .portrait else {
            throw ChauffeurError.landscape
        }
        return (publish(ax.complete(root), size: device.size), result)
    }

    private func poll(_ ax: any AXSource, minMs: Int, capMs: Int) -> Settled<AXElement> {
        Settle.wait(minMs: minMs, capMs: capMs, clock: clock) { () -> (value: AXElement, hash: Int)? in
            guard let root = ax.read(), !root.frame.isEmpty else { return nil }  // 0×0 root = not settled (decision 3)
            return (root, root.hashValue)
        }
    }

    /// rev increases only when what the agent can see changed.
    private func publish(_ root: AXElement, size: Size) -> Snapshot {
        var snap = Perception.build(root: root, size: size, previous: last?.kind, refs: &refs, rev: rev)
        if snap.hash != last?.hash {
            rev += 1
            lastChangeMs = clock.nowMs()
        }
        snap.rev = rev
        last = snap
        return snap
    }
}
