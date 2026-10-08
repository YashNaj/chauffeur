import ChauffeurBridge
import Foundation

/// Warm per-simulator state: bridge objects, refs, the latest snapshot, the touch log.
@MainActor
public final class Session {
    public let udid: String
    var device: Device?
    var ax: AXProvider?
    var hid: CHHIDClient?
    var transports: [TouchTransport] = []
    var preferred = 0
    let touchLog: TouchLog
    /// The launched app's unified log (spec §6.8).
    let logTap: LogTap
    /// The app `chauffeur launch` started; its exit without chauffeur ending it is a crash.
    var app: TrackedApp?
    /// The last crash noticed, kept for `logs`, which keeps looking for its report.
    var crash: CrashInfo?
    /// The log cursor when the last action started (`logs --since-last`).
    var lastActionLogCursor = 0
    /// How long a result waits for the crash report (macOS took 17–70 s on the 8 GB Mac; `logs` looks again later).
    var crashReportWaitMs = 3000
    /// When the log tap was last (re)started for a restored app; retried at most every 30 s.
    var logTapAttemptMs: Int?
    /// Where commands are traced; the daemon sets it, tests and other callers leave it nil.
    public var traceFile: URL?
    /// Set by a command while it runs: the element it acted on, and its arguments with secrets removed.
    var traceTarget: Node?
    var traceArgs: [String]?
    /// When chauffeur itself ended an app (pid → clock ms): its exit within `endedGraceMs` is not a crash.
    var endedByChauffeur: [Int32: Int] = [:]
    nonisolated static let endedGraceMs = 10_000
    /// Test seam: runs inside a command, just before it executes (stands in for what it does to the launched app).
    var commandHook: ((String) -> Void)?
    /// Seams for unit tests: is the simulator booted (nil: could not tell), and when did its current boot start.
    var simulatorBooted: () -> Bool? = { nil }
    var simulatorBootDate: () -> Date? = { nil }
    /// Seams for unit tests: process liveness and the crash-report lookup.
    var isAlive: (Int32) -> Bool = Proc.isAlive
    var findCrashReport: (TrackedApp) -> CrashReport?
    var refs = RefTable()
    var rev = 0
    var last: Snapshot?
    /// When a screen change was last observed. Freshly presented UI (alerts) drops touches for a few hundred ms.
    var lastChangeMs = 0
    /// The requesting client's working directory, for relative paths.
    var cwd: String?
    /// When the touch log was last started; a stream that will not attach is retried at most every 30 s.
    var touchLogAttemptMs: Int?
    /// When the app-accessibility flags were last checked; rechecked at most every 60 s while chauffeur is in use.
    var axCheckedMs: Int?
    /// Healing state (Task 4, M3a): when the tree first went missing, when chauffeur last restarted the simulator's
    /// accessibility bridge, and a note for the next result when healing recovered.
    var noTreeSinceMs: Int?
    var lastNoTreeMs: Int?
    var bridgeRestartedMs: Int?
    var healNote: String?
    /// Where the launched app's log lines start in `logTap` (crash evidence is this launch's lines only).
    var appLogCursor: Int?
    let clock = SystemClock()

    public init(udid: String) {
        self.udid = udid
        touchLog = TouchLog(udid: udid, levelFile: StatePaths.level(udid))
        logTap = LogTap(udid: udid)
        simulatorBooted = { SimBoot.booted(udid: udid) }
        simulatorBootDate = { SimBoot.date(udid: udid) }
        findCrashReport = { app in CrashFinder.find(bundle: app.bundle, pid: app.pid, udid: udid, since: app.launchedAt) }
        // A restarted daemon (upgrade, idle exit) keeps following an app that is still running.
        if let saved = TrackedApp.load(StatePaths.app(udid)) {
            if Proc.isAlive(saved.pid) { app = saved } else { TrackedApp.clear(StatePaths.app(udid)) }
        }
    }

    public func shutdown() {
        touchLog.stop()
        logTap.stop()
    }

    /// Connects lazily; after the device stops being booted, drops everything (spec §6.9).
    func connect() throws -> (Device, AXProvider) {
        if let device, let ax {
            if device.booted {
                _ = try? ensureAccessibility(force: false)  // an Xcode session may have switched them off since
                return (device, ax)
            }
            simulatorWentDown()
            throw ChauffeurError.notBooted(udid)
        }
        let d = try Device(udid: udid)
        guard d.booted else {
            simulatorWentDown()  // an app that was running there is gone, not crashed
            throw ChauffeurError.notBooted(udid)
        }
        let a = try AXProvider(sim: d.sim)
        device = d
        ax = a
        _ = try? ensureAccessibility(force: false)  // an Xcode session may have switched them off since
        return (d, a)
    }

    /// The simulator went down: the launched app is gone (not crashed) and its log stream is over.
    func simulatorWentDown() {
        noTreeSinceMs = nil
        lastNoTreeMs = nil
        logTap.stop()
        if app != nil {
            app = nil
            TrackedApp.clear(StatePaths.app(udid))
        }
        drop()
    }

    /// Drops the bridge objects and the touch log. Also used to reconnect after a SpringBoard restart, when the
    /// launched app and its log stream must stay as they are.
    func drop() {
        touchLog.stop()
        device = nil; ax = nil; hid = nil; transports = []
    }

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
            let since = AXHealth.episodeStart(current: noTreeSinceMs, lastFailureMs: lastNoTreeMs,
                                               attemptStartedMs: started, nowMs: now)
            noTreeSinceMs = since
            lastNoTreeMs = now
            let plan = heal(noTreeForMs: now - since, ax: ax, screen: device.size)
            if plan.relaunchApp { throw ChauffeurError.blind(AXHealth.message(plan, recovered: false)) }
            if plan.restartBridge {
                result = poll(ax, minMs: minMs, capMs: max(capMs, 3000))
                if result.value == nil { throw ChauffeurError.blind(AXHealth.message(plan, recovered: false)) }
                healNote = AXHealth.message(plan, recovered: true)
            }
        }
        guard let root = result.value else { throw ChauffeurError.noTree }
        noTreeSinceMs = nil
        guard Geometry.orientation(root: root.frame, screen: device.size) == .portrait else { throw ChauffeurError.landscape }
        return (publish(ax.complete(root), size: device.size), result)
    }

    /// Diagnoses a missing tree and applies the cure: flags back on, and a poisoned bridge restarted (at most once a minute).
    func heal(noTreeForMs: Int, ax: AXProvider, screen: Size) -> AXHealth.Plan {
        guard noTreeForMs >= AXHealth.patienceMs else { return AXHealth.Plan(enableFlags: [], restartBridge: false, relaunchApp: false) }
        let flagsOff = (try? SimCtl.run(["spawn", udid, "defaults", "read", AXSettings.domain]).out).map(AXSettings.off) ?? []
        let probe = ax.probe(center: Point(x: screen.w / 2, y: screen.h / 2))
        let plan = AXHealth.plan(noTreeForMs: noTreeForMs, frontmostIsEmptyApp: probe.frontmostIsEmptyApp,
                                 screenAnswers: probe.screenAnswers, flagsOff: flagsOff,
                                 msSinceBridgeRestart: bridgeRestartedMs.map { clock.nowMs() - $0 })
        if !plan.enableFlags.isEmpty { _ = try? ensureAccessibility() }
        if plan.restartBridge { _ = restartBridge() }
        return plan
    }

    /// Restarts the simulator's accessibility bridge (launchd brings it back at once); returns the provider to read with.
    func restartBridge() -> AXProvider? {
        _ = try? SimCtl.run(["spawn", udid, "launchctl", "stop", "com.apple.CoreSimulator.bridge"])
        bridgeRestartedMs = clock.nowMs()
        clock.sleep(ms: 1500)  // give it a moment to come up
        return ax
    }

    private func poll(_ ax: AXProvider, minMs: Int, capMs: Int) -> Settled<AXElement> {
        Settle.wait(minMs: minMs, capMs: capMs, clock: clock) { () -> (value: AXElement, hash: Int)? in
            guard let root = ax.read(), !root.frame.isEmpty else { return nil }  // 0×0 root = not settled (decision 3)
            return (root, root.hashValue)
        }
    }

    /// rev increases only when what the agent can see changed.
    private func publish(_ root: AXElement, size: Size) -> Snapshot {
        var snap = Perception.build(root: root, size: size, previous: last?.kind, refs: &refs, rev: rev)
        if snap.hash != last?.hash { rev += 1; lastChangeMs = clock.nowMs() }
        snap.rev = rev
        last = snap
        return snap
    }

    public func run(_ argv: [String], cwd: String? = nil) -> Output {
        self.cwd = cwd
        return runOne(argv)
    }

    /// Actions: their result gets the launched app's new error lines (spec §5.4). Names of commands added by later
    /// tasks are listed here once.
    static let logged: Set<String> = [
        "tap", "type", "scroll", "swipe", "button", "open", "install", "launch", "terminate",
        "permission", "location", "push", "appearance",
    ]
    /// Commands that report the launched app's crash (`logs` shows it itself).
    static let watched: Set<String> = logged.union(["snapshot", "find", "wait", "screenshot"])

    /// One command, then what the launched app logged and whether it crashed (spec §6.8), then the trace.
    func runOne(_ argv: [String]) -> Output {
        guard let command = argv.first else { return Output(Usage.text, exit: 64) }
        let started = clock.nowMs()
        traceTarget = nil
        traceArgs = command == "type" ? Self.provisionalType(argv) : nil
        if Self.logged.contains(command) || command == "logs" { followLaunchedApp() }
        let cursor = logTap.cursor
        let previousActionCursor = lastActionLogCursor
        if Self.logged.contains(command) { lastActionLogCursor = cursor }
        // A crash since the previous command must be noticed before this command can stop following the app
        // (launch, install, terminate and permission changes all do) and so hide it.
        let noticed = Self.watched.contains(command) ? detectCrash() : nil
        var output = guarded { commandHook?(command); return try dispatch(command, Array(argv.dropFirst())) }
        if Self.watched.contains(command) { output = annotate(output, since: cursor, logs: Self.logged.contains(command), actionCursor: previousActionCursor, noticed: noticed) }
        if command != "do" { record(traceArgs ?? argv, output, ms: clock.nowMs() - started) }  // a batch traces its commands
        return output
    }

    /// Appends the command to the trace when this session keeps one.
    func record(_ args: [String], _ output: Output, ms: Int) {
        guard let traceFile else { return }
        let entry = TraceEntry(time: Trace.timestamp(Date()), udid: udid, args: args, exit: output.exit, ms: ms,
                               result: String(output.text.prefix { $0 != "\n" }), target: traceTarget.map(TraceTarget.init),
                               app: app?.bundle ?? crash?.app.bundle)
        Trace.append(entry, to: traceFile)
    }

    func dispatch(_ command: String, _ argv: [String]) throws -> Output {
        switch command {
        case "snapshot": return try snapshotCommand(argv)
        case "find": return try findCommand(argv)
        case "wait": return try waitCommand(argv)
        case "tap": return try tapCommand(argv)
        case "type": return try typeCommand(argv)
        case "scroll": return try scrollCommand(argv)
        case "swipe": return try swipeCommand(argv)
        case "screenshot": return try screenshotCommand(argv)
        case "button": return try buttonCommand(argv)
        case "install": return try installCommand(argv)
        case "launch": return try launchCommand(argv)
        case "terminate": return try terminateCommand(argv)
        case "logs": return try logsCommand(argv)
        case "open": return try openCommand(argv)
        case "permission": return try permissionCommand(argv)
        case "location": return try locationCommand(argv)
        case "push": return try pushCommand(argv)
        case "appearance": return try appearanceCommand(argv)
        case "do": return try batchCommand(argv)
        case "selftest": return try selftestCommand()
        default: return Output("unknown command \"\(command)\"\n\n" + Usage.text, exit: 64)
        }
    }

    /// `path` made absolute: `~` expanded, relative paths taken from the client's directory (not the daemon's).
    func resolvePath(_ path: String) -> URL {
        let expanded = (path as NSString).expandingTildeInPath
        let base = URL(fileURLWithPath: cwd ?? FileManager.default.currentDirectoryPath, isDirectory: true)
        return URL(fileURLWithPath: expanded, relativeTo: base).standardizedFileURL
    }

    /// Errors become outputs: usage mistakes exit 64, everything else 1.
    func guarded(_ body: () throws -> Output) -> Output {
        do {
            return try body()
        } catch ChauffeurError.usage(let text) {
            return Output(text, exit: 64)
        } catch let error as ChauffeurError {
            return Output(error.description, exit: 1)
        } catch let error as RefError {
            return Output(error.description, exit: 1)
        } catch {
            return Output("\(error)", exit: 1)
        }
    }

    func snapshotCommand(_ argv: [String]) throws -> Output {
        let a = try Args(argv, flags: ["--all", "--screenshot"], usage: "usage: chauffeur snapshot [--all] [--screenshot]")
        try a.done()
        let snap = try observe(minMs: 0, capMs: 1500).snapshot
        let text = snap.render(all: a.flag("--all"))
        guard a.flag("--screenshot"), let device else { return Output(text, data: snap.json(all: a.flag("--all"))) }
        let shot = try capture(screen: device.size, zoom: nil)
        return Output(text + "\nscreenshot → " + shot.line, data: snap.json(all: a.flag("--all")).merging(["screenshot": shot.json]))
    }

    func findCommand(_ argv: [String]) throws -> Output {
        var a = try Args(argv, usage: "usage: chauffeur find \"<text>|<role>:<text>\"")
        guard let query = a.text() else { throw ChauffeurError.usage(a.usage) }
        let snap = try observe(minMs: 0, capMs: 1500).snapshot
        let hits = snap.find(query)
        guard !hits.isEmpty else {
            return Output("no match for \(Perception.quote(query)) on: \(snap.header)\nrun snapshot to see the screen", exit: 4,
                          data: ["matches": [], "screen": .string(snap.header)])
        }
        return Output(hits.map { snap.line($0, all: false).trimmingCharacters(in: .whitespaces) }.joined(separator: "\n"),
                      data: ["matches": .array(hits.map { $0.json(all: false) })])
    }

    /// Waits stay below the client's reply timeout, so a long wait can't look like a dead daemon (C1).
    nonisolated static let maxWaitSeconds = 300.0
    nonisolated static func waitTimeout(_ seconds: Double?) -> Double {
        min(seconds ?? 10, maxWaitSeconds)
    }

    func waitCommand(_ argv: [String]) throws -> Output {
        var a = try Args(argv, flags: ["--gone"], options: ["--timeout"],
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
                if gone && hits.isEmpty { return Output("gone after \(elapsed)ms", data: ["gone": true, "elapsedMs": JSON(elapsed)]) }
                if !gone && !hits.isEmpty {
                    return Output("found after \(elapsed)ms\n" + hits.map { snap.line($0, all: false).trimmingCharacters(in: .whitespaces) }.joined(separator: "\n"),
                                  data: ["found": true, "elapsedMs": JSON(elapsed), "matches": .array(hits.map { $0.json(all: false) })])
                }
            } catch ChauffeurError.noTree, ChauffeurError.blind {
                // app still launching; keep waiting
            }
            if Double(clock.nowMs() - start) >= timeout * 1000 {
                return Output((gone ? "still present" : "not found") + " after \(Geometry.fmt(timeout))s: "
                              + Perception.quote(query) + "\nscreen: " + lastHeader, exit: 4,
                              data: [gone ? "gone" : "found": false, "screen": .string(lastHeader)])
            }
            clock.sleep(ms: 100)
        }
    }
}
