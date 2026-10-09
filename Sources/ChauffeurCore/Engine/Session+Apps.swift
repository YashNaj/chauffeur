import Foundation

extension Session {
    /// Stops following `bundle` when it is the launched app, because chauffeur itself is about to end it
    /// (terminate, reinstall, relaunch, permission change): that exit is not a crash.
    @discardableResult
    func release(_ bundle: String) -> TrackedApp? {
        guard let tracked = app, tracked.bundle == bundle else { return nil }
        let now = clock.nowMs()
        endedByChauffeur = endedByChauffeur.filter { now - $0.value < Self.endedGraceMs }
        endedByChauffeur[tracked.pid] = now
        app = nil
        TrackedApp.clear(StatePaths.app(udid))
        return tracked
    }

    func track(_ tracked: TrackedApp) {
        app = tracked
        tracked.save(StatePaths.app(udid))
    }

    /// The launched app's bundle while it is the app in front, so a touch landing in another app's scene is
    /// INTERCEPTED rather than NO EFFECT (spec §6.2).
    func expectedApp(on snap: Snapshot) -> String? {
        guard let app, case .app(let name) = snap.kind, name == app.displayName else { return nil }
        return app.bundle
    }

    /// A bundle id argument: letters, digits, dots and hyphens.
    func bundleArgument(_ a: inout Args) throws -> String {
        guard let bundle = a.next(), bundle.wholeMatch(of: /[A-Za-z0-9][A-Za-z0-9.\-]*/) != nil else {
            throw ChauffeurError.usage(a.usage)
        }
        return bundle
    }

    func installCommand(_ argv: [String]) throws -> Output {
        var a = try Args(argv, usage: "usage: chauffeur install <path.app>")
        guard let raw = a.text() else { throw ChauffeurError.usage(a.usage) }
        let url = resolvePath(raw)
        var isDirectory: ObjCBool = false
        guard url.pathExtension == "app", FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
            isDirectory.boolValue
        else {
            return Output(
                "install: \(url.path) is not an .app directory. Build for the simulator, then install "
                    + "Build/Products/Debug-iphonesimulator/<App>.app", exit: 1)
        }
        guard let bundle = SimApps.bundle(at: url) else {
            return Output("install: \(url.lastPathComponent) has no Info.plist with a bundle id", exit: 1)
        }
        _ = try connect()
        release(bundle.identifier)  // installing replaces, and so ends, a running copy
        let start = clock.nowMs()
        let r = try SimCtl.run(["install", udid, url.path], timeout: 300)
        guard r.status == 0 else {
            return Output("install \(url.lastPathComponent) → FAILED: \(SimCtl.message(r))", exit: 1)
        }
        let seconds = String(format: "%.1f", Double(clock.nowMs() - start) / 1000)
        return Output(
            "install \(url.lastPathComponent) → installed \(bundle.identifier) \(bundle.version) in \(seconds)s\n"
                + "next: chauffeur launch \(bundle.identifier)",
            data: ["bundle": .string(bundle.identifier), "version": .string(bundle.version), "path": .string(url.path)])
    }

    /// A cold launch took 5–13 s on iOS 27 on an 8 GB host (M2 dogfood); launch returns as soon as the app is in front.
    nonisolated static let launchWaitMs = 15_000

    func launchCommand(_ argv: [String]) throws -> Output {
        var a = try Args(argv, restOption: "--args", usage: "usage: chauffeur launch <bundle> [--args <arg>…]")
        let bundle = try bundleArgument(&a)
        try a.done()
        _ = try connect()
        let info = try SimCtl.run(["appinfo", udid, bundle], timeout: 30)
        guard info.status == 0, let appInfo = SimApps.appInfo(info.out) else {
            return Output(
                "\(bundle) is not installed on this simulator. Install it first: chauffeur install <path.app>", exit: 1)
        }
        // What was in front before: until it is replaced, the launch has not shown anything yet.
        let previous = try? observe(minMs: 0, capMs: 500).snapshot.kind
        let relaunching = app?.bundle == bundle ? app : nil
        // `simctl launch` on a running app just brings it forward with its old state (M1): end it first.
        release(bundle)
        _ = try SimCtl.run(["terminate", udid, bundle], timeout: 30)
        let reenabled = try ensureAccessibility()
        let following = logTap.start(executable: appInfo.executable)  // before launch, so launch-time lines are kept
        appLogCursor = logTap.cursor  // crash evidence comes from this launch's lines only
        let r = try SimCtl.run(["launch", udid, bundle] + a.rest, timeout: 60)
        guard r.status == 0, let pid = SimApps.launchedPID(r.out) else {
            return Output("launch \(bundle) → FAILED: \(SimCtl.message(r))", exit: 1)
        }
        var tracked = TrackedApp(
            bundle: bundle, executable: appInfo.executable, displayName: appInfo.displayName,
            pid: pid, launchedAt: Date())
        track(tracked)
        crash = nil  // a new launch supersedes an old crash
        let stale = Self.staleKind(
            previous: previous, relaunched: [appInfo.displayName] + (relaunching.map { [$0.displayName] } ?? []))
        let front = try waitForApp(capMs: Self.launchWaitMs, notShowing: stale)
        let after = String(format: "%.1fs", Double(front.waitedMs) / 1000)
        var lines: [String]
        var exit: Int32 = 0
        if !Self.showsLaunchedApp(front.snapshot.kind, stale: stale) {
            let alive = isAlive(pid)
            lines = [
                alive
                    ? "launch \(bundle) → UNVERIFIED: pid \(pid) is running, but after \(after) the accessibility tree still shows \(Self.describe(front.snapshot.kind))"
                    : "launch \(bundle) → FAILED: pid \(pid) exited during launch",
                alive
                    ? "hint: run: chauffeur wait \"<text on its first screen>\"; if it never appears, run: chauffeur doctor"
                    : "hint: run: chauffeur logs",
            ]
            exit = alive ? 3 : 1
        } else {
            // A localized display name differs from Info.plist: follow what the screen calls it.
            if case .app(let name) = front.snapshot.kind, name != tracked.displayName {
                tracked.displayName = name
                track(tracked)
            }
            lines = ["launch \(bundle) → running (pid \(pid)) after \(after)", front.snapshot.header]
        }
        if !reenabled.isEmpty {
            lines.append(
                "note: turned the simulator's accessibility back on (\(reenabled.joined(separator: ", ")) were off, "
                    + "as an Xcode device-interaction session leaves them); apps launched while they were off need a relaunch"
            )
        }
        if !following {
            lines.append("note: the app's log stream did not attach; logs are unavailable until the next launch")
        }
        return Output(
            lines.joined(separator: "\n"), exit: exit,
            data: [
                "bundle": .string(bundle), "pid": JSON(Int(pid)), "waitedMs": JSON(front.waitedMs),
                "screen": .string(front.snapshot.header),
            ])
    }

    /// Turns on the accessibility flags an app needs at launch to serve its tree; returns the ones that were off.
    /// `force: false` checks at most every 60 s (the per-command path); launch always checks.
    func ensureAccessibility(force: Bool = true) throws -> [String] {
        if !force, let last = axCheckedMs, clock.nowMs() - last < 60_000 { return [] }
        axCheckedMs = clock.nowMs()
        return try AXSettings.ensure(udid: udid)
    }

    /// What was in front before a launch, unless it is the app being relaunched (under its Info.plist name or the name
    /// its tree shows): that one coming back proves nothing stale.
    nonisolated static func staleKind(previous: ScreenKind?, relaunched names: [String]) -> ScreenKind? {
        if case .app(let name)? = previous, names.contains(name) { return nil }
        return previous
    }

    /// Whether the screen shows the launched app: not SpringBoard, and not what was in front before the launch.
    nonisolated static func showsLaunchedApp(_ kind: ScreenKind, stale: ScreenKind?) -> Bool {
        kind != .springboard && kind != stale
    }

    nonisolated static func describe(_ kind: ScreenKind) -> String {
        switch kind {
        case .springboard: return "SpringBoard"
        case .app(let name): return "app \"\(name)\""
        case .systemAlert(let over): return "a system alert over \(over)"
        }
    }

    /// After a launch: polls until the launched app is in front (see `showsLaunchedApp`) or `capMs` passes, then settles.
    func waitForApp(capMs: Int, notShowing stale: ScreenKind? = nil) throws -> (snapshot: Snapshot, waitedMs: Int) {
        let start = clock.nowMs()
        var latest: Snapshot?
        while clock.nowMs() - start < capMs {
            do {
                let snap = try observe(minMs: 0, capMs: 500).snapshot
                latest = snap
                if Self.showsLaunchedApp(snap.kind, stale: stale) {
                    let settled = try observe(minMs: 150, capMs: 1500).snapshot
                    return (settled, clock.nowMs() - start)
                }
            } catch let error as ChauffeurError where error.appNotUpYet {
                // the app's first tree is not up yet (healing judges a launch slower than its patience as blind)
            }
            clock.sleep(ms: 150)
        }
        guard let latest else { throw ChauffeurError.noTree }
        return (latest, clock.nowMs() - start)
    }

    func openCommand(_ argv: [String]) throws -> Output {
        var a = try Args(argv, usage: "usage: chauffeur open <url>")
        guard let url = a.next(), let scheme = URL(string: url)?.scheme, !scheme.isEmpty else {
            throw ChauffeurError.usage(a.usage)
        }
        try a.done()
        return try actWithoutTouch(
            "open \(Perception.quote(url, limit: 120))", capMs: 3000,
            note: "the URL was delivered; nothing visible changed in 3s",
            hints: ["the app may handle this link without a visible change; run snapshot to check"]
        ) {
            let r = try SimCtl.run(["openurl", udid, url], timeout: 30)
            guard r.status != 0 else { return nil }
            // iOS 26.2 exits 194 with OSStatus -10814 (kLSApplicationNotFoundErr); earlier plans measured 115.
            return r.status == 115 || r.err.contains("-10814")
                ? "no installed app handles \(Perception.escape(scheme)): URLs" : SimCtl.message(r)
        }
    }

    /// An action with no touch evidence (a URL, a hardware button): a settled screen change is `changed`, a change on
    /// an unsettled screen is unattributed, and no change is UNVERIFIED with `note` (spec §6.2, last row).
    /// `perform` returns nil when the action was sent, or why it could not be.
    func actWithoutTouch(
        _ label: String, capMs: Int, note: String, hints: [String],
        perform: () throws -> String?
    ) throws -> Output {
        let (before, settled) = try baseline()
        if let failure = try perform() { return Output("\(label) → FAILED: \(failure)", exit: 1) }
        // The accessibility tree can lag the screen (SpringBoard after `button home` took over a second to show up), so
        // a tree that is merely stable is not "no change": keep looking until it differs or `capMs` has passed.
        let started = clock.nowMs()
        var (after, settle) = try observe(minMs: 150, capMs: min(capMs, 600))
        while after.hash == before.hash, clock.nowMs() - started < capMs {
            (after, settle) = try observe(minMs: 150, capMs: min(capMs, 600))
        }
        if after.hash != before.hash { (after, settle) = try observe(minMs: 150, capMs: 1500) }
        let outcome: Outcome = after.hash == before.hash ? .unverified : settled ? .changed : .unattributed
        var report = ActionReport(
            action: label, outcome: outcome, evidence: .unavailable, settledMs: settle.elapsedMs,
            settled: settle.settled,
            revBefore: before.rev, revAfter: after.rev,
            diff: outcome == .changed ? Diff.lines(from: before, to: after) : [],
            transport: "none", retriedFrom: nil,
            hints: outcome == .unverified ? hints : Verifier.hints(outcome: outcome, target: nil), capMs: capMs)
        report.note = note
        return Output(report.render(), exit: report.exitCode, data: report.json)
    }

    func terminateCommand(_ argv: [String]) throws -> Output {
        var a = try Args(argv, usage: "usage: chauffeur terminate <bundle>")
        let bundle = try bundleArgument(&a)
        try a.done()
        _ = try connect()
        let tracked = release(bundle)
        let r = try SimCtl.run(["terminate", udid, bundle], timeout: 30)
        guard r.status == 0 else {
            if r.err.contains("found nothing to terminate") { return Output("terminate \(bundle) → was not running") }
            if let tracked { track(tracked) }
            return Output("terminate \(bundle) → FAILED: \(SimCtl.message(r))", exit: 1)
        }
        let snap = try observe(minMs: 150, capMs: 1500).snapshot
        return Output("terminate \(bundle) → stopped" + (tracked.map { " (pid \($0.pid))" } ?? "") + "\n" + snap.header)
    }
}
