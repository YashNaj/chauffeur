import Foundation

extension Session {
    /// After a daemon restart the launched app is known but its log is not followed yet; retried every 30 s at most.
    func followLaunchedApp() {
        guard let app, logTap.executable != app.executable else { return }
        if let last = logTapAttemptMs, clock.nowMs() - last < 30_000 { return }
        logTapAttemptMs = clock.nowMs()
        logTap.start(executable: app.executable)
    }

    /// Notices that the launched app is gone without chauffeur ending it. Reported once: the app stops being
    /// followed, and the crash is kept for `logs`, which keeps looking for the report.
    func detectCrash() -> CrashInfo? {
        guard let gone = app, !isAlive(gone.pid) else { return nil }
        // A simulator that was shut down, or rebooted since the app launched, explains the missing process.
        if simulatorBooted() == false || simulatorBootDate().map({ $0 > gone.launchedAt }) == true {
            simulatorWentDown()
            return nil
        }
        app = nil
        TrackedApp.clear(StatePaths.app(udid))
        // chauffeur ended it (a permission change can take more than the 1 s grace window to kill the app).
        if let endedAt = endedByChauffeur[gone.pid], clock.nowMs() - endedAt < Self.endedGraceMs { return nil }
        var info = CrashInfo(app: gone, detectedAt: Date(), report: nil)
        let deadline = clock.nowMs() + crashReportWaitMs
        while true {
            info.report = findCrashReport(gone)
            if info.report != nil || clock.nowMs() >= deadline { break }
            clock.sleep(ms: 250)
        }
        // After the wait: under load the log stream lags the exit.
        info.fatalLine = CrashInfo.fatalLine(in: Array(logTap.since(appLogCursor ?? 0).suffix(50)))
        crash = info
        return info
    }

    /// Adds the launched app's new error lines (actions) and, when its process is gone, `APP CRASHED` with exit 5
    /// (every watched command). In an action's result the crash replaces the diff, which would only show the home
    /// screen; read-only commands keep their output.
    func annotate(_ output: Output, since cursor: Int, logs: Bool, actionCursor: Int? = nil, noticed: CrashInfo? = nil) -> Output {
        var out = output
        var extra: [String] = []
        var data: [String: JSON] = [:]
        let crashed = noticed ?? detectCrash()
        if let crashed {
            // An action's diff after a crash would only show the home screen; a crash noticed before the command ran
            // leaves the command's own result (launch, terminate…) intact.
            if logs && noticed == nil { out.text = String(out.text.prefix { $0 != "\n" }) }
            extra += crashed.render()
            data["crash"] = crashed.json
        }
        if logs || crashed != nil {
            // A crash noticed by a later command still shows what the last action logged before the app died.
            let from = crashed == nil ? cursor : min(cursor, actionCursor ?? lastActionLogCursor)
            let errors = logTap.since(from).filter(\.isError)
            extra += LogLine.summary(errors)
            if !errors.isEmpty { data["logs"] = .array(errors.prefix(20).map(\.json)) }
        }
        if let crashed {
            extra.append("hint: after fixing it, rebuild, chauffeur install <path.app>, then chauffeur launch \(crashed.app.bundle)")
            out.exit = 5
        }
        if let note = healNote { extra.append("note: " + note); healNote = nil }
        guard !extra.isEmpty else { return out }
        out.text += "\n" + extra.joined(separator: "\n")
        out.data = (out.data ?? .null).merging(data)
        return out
    }

    func logsCommand(_ argv: [String]) throws -> Output {
        let a = try Args(argv, flags: ["--since-last"], options: ["--last", "--level"],
                         usage: "usage: chauffeur logs [--since-last] [--last <n>] [--level error|info]")
        try a.done()
        let count = try a.integer("--last", in: 1...500)
        let sinceLast = a.flag("--since-last")
        let level = a.option("--level") ?? "info"
        guard level == "error" || level == "info" else { throw ChauffeurError.usage("--level expects error or info\n" + a.usage) }

        _ = detectCrash()
        if var c = crash, c.report == nil, let report = findCrashReport(c.app) {
            c.report = report
            crash = c
        }
        guard let followed = app ?? crash?.app else {
            return Output("no app launched through chauffeur yet: logs follow the app started with chauffeur launch <bundle>", exit: 1)
        }
        let pool = sinceLast ? logTap.since(lastActionLogCursor) : logTap.all
        let filtered = level == "error" ? pool.filter(\.isError) : pool
        let lines = Array(filtered.suffix(count ?? (sinceLast ? 200 : 30)))
        let file = writeLogFile()
        let state = app != nil ? "running" : "not running"
        let scope = (sinceLast ? "since the last action" : "latest") + (level == "error" ? ", errors only" : "")
        var text = ["logs · \(followed.bundle) (pid \(followed.pid), \(state)) · \(lines.count) of \(filtered.count) lines (\(scope))"
                    + (file.map { " · full log: \($0.path)" } ?? "")]
        if app != nil && !logTap.isAttached { text.append("note: the log stream is not attached; recent lines may be missing") }
        text += lines.map { $0.render() }
        var data: [String: JSON] = ["bundle": .string(followed.bundle), "pid": JSON(Int(followed.pid)),
                                    "running": .bool(app != nil), "lines": .array(lines.map(\.json)),
                                    "file": JSON(file?.path)]
        if let c = crash, c.app.pid == followed.pid {
            text += c.render(frames: 8)
            data["crash"] = c.json
        }
        return Output(text.joined(separator: "\n"), data: .object(data))
    }

    /// Every buffered line, full length: big outputs are files (spec §5.1).
    func writeLogFile() -> URL? {
        let dir = StatePaths.artifacts(udid)
        guard (try? StatePaths.ensureDir(StatePaths.dir)) != nil, (try? StatePaths.ensureDir(dir)) != nil else { return nil }
        let url = dir.appendingPathComponent("logs.txt")
        let text = logTap.all.map { $0.render(limit: 4000) }.joined(separator: "\n") + "\n"
        return (try? text.write(to: url, atomically: true, encoding: .utf8)) != nil ? url : nil
    }
}
