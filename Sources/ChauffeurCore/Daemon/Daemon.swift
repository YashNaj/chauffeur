import Darwin
import Foundation

public struct Request: Codable, Sendable {
    public var version: String
    public var args: [String]
    /// The simulator the client means. Socket names use 8 udid characters, so a daemon checks it serves this one.
    public var udid: String?
    /// The client's working directory: relative paths (`install`, `push`) resolve against it, not the daemon's.
    public var cwd: String?

    public init(version: String, args: [String], udid: String? = nil, cwd: String? = nil) {
        self.version = version
        self.args = args
        self.udid = udid
        self.cwd = cwd
    }
}

/// Exclusive per-simulator lock: at most one daemon serves a simulator (C1).
final class DaemonLock: @unchecked Sendable {
    private let fd: Int32
    private init(fd: Int32) { self.fd = fd }

    static func acquire(_ url: URL) -> DaemonLock? {
        let fd = open(url.path, O_RDWR | O_CREAT, 0o600)
        guard fd >= 0 else { return nil }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            return nil
        }
        return DaemonLock(fd: fd)
    }

    func release() {
        flock(fd, LOCK_UN)
        close(fd)
    }
}

public enum Daemon {
    public static let idleSeconds = 15.0 * 60
    public static let versionMismatchExit: Int32 = 75

    @MainActor static var session: Session?
    @MainActor static var udid = ""
    @MainActor static var lastActivity = Date()
    @MainActor static var sources: [any DispatchSourceProtocol] = []
    @MainActor static var lock: DaemonLock?
    @MainActor static var listener: Int32 = -1
    @MainActor static var boundInode: UInt64?

    /// What to answer, and whether to exit afterwards (spec §6.9 version handshake).
    public static func respond(
        to request: Request, current: String = Chauffeur.buildID, serving: String? = nil,
        run: ([String]) -> Output
    ) -> (Output, exitAfter: Bool) {
        if let wanted = request.udid, let serving, wanted.caseInsensitiveCompare(serving) != .orderedSame {
            return (
                Output(
                    "this daemon serves \(serving), not \(wanted): both simulators share the socket "
                        + "\(StatePaths.socket(serving).lastPathComponent). Shut one of them down", exit: 1), false
            )
        }
        guard request.version == current else {
            return (
                Output(
                    "daemon is \(current), client is \(request.version); restarting the daemon",
                    exit: versionMismatchExit), true
            )
        }
        return (run(request.args), false)
    }

    /// Serves one simulator until idle, SIGINT/SIGTERM or a version mismatch.
    @MainActor public static func serve(udid: String) -> Never {
        signal(SIGHUP, SIG_IGN)
        signal(SIGPIPE, SIG_IGN)
        do { try StatePaths.ensureDir() } catch {
            FileHandle.standardError.write(Data("chauffeur daemon: \(error)\n".utf8))
            exit(1)
        }
        // One daemon per simulator (C1). If another one is serving, leave; if it is still shutting down, wait.
        let socketPath = StatePaths.socket(udid).path
        let deadline = Date().addingTimeInterval(25)
        while lock == nil {
            lock = DaemonLock.acquire(StatePaths.lock(udid))
            if lock != nil { break }
            if let fd = try? UnixSocket.connect(path: socketPath, timeout: 1) {
                close(fd)
                exit(0)
            }
            guard Date() < deadline else {
                FileHandle.standardError.write(
                    Data("chauffeur daemon: another daemon holds \(StatePaths.lock(udid).path)\n".utf8))
                exit(1)
            }
            usleep(100_000)
        }
        let listener: Int32
        do { listener = try UnixSocket.listen(path: socketPath) } catch {
            FileHandle.standardError.write(Data("chauffeur daemon: \(error)\n".utf8))
            exit(1)
        }
        Daemon.listener = listener
        boundInode = UnixSocket.inode(socketPath)
        try? "\(getpid())".write(to: StatePaths.pidfile(udid), atomically: true, encoding: .utf8)
        Daemon.udid = udid
        session = Session(udid: udid)
        session?.traceFile = StatePaths.trace(udid)
        lastActivity = Date()

        for sig in [SIGINT, SIGTERM] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { MainActor.assumeIsolated { finish() } }
            source.resume()
            sources.append(source)
        }
        let idle = DispatchSource.makeTimerSource(queue: .main)
        idle.schedule(deadline: .now() + 30, repeating: 30)
        idle.setEventHandler {
            MainActor.assumeIsolated { if Date().timeIntervalSince(lastActivity) > idleSeconds { finish() } }
        }
        idle.resume()
        sources.append(idle)

        Thread {
            while true {
                let client = accept(listener, nil, nil)
                if client < 0 {
                    // A closed listener means shutdown; anything else (EMFILE…) backs off instead of spinning.
                    if errno == EBADF || errno == EINVAL { return }
                    usleep(100_000)
                    continue
                }
                UnixSocket.setTimeout(client, 10)
                handle(client)
                close(client)
            }
        }.start()
        // Not dispatchMain(): that parks the main thread, and main-queue blocks then run on a worker thread,
        // where the mouse transport (AppKit thread state) traps. The main run loop keeps them on the main thread.
        RunLoop.main.add(NSMachPort(), forMode: .default)
        while true { RunLoop.main.run() }
    }

    /// Runs on the accept thread; commands execute on the main thread (HID mouse needs it).
    nonisolated static func handle(_ client: Int32) {
        guard let line = UnixSocket.readLine(client),
            let request = try? JSONDecoder().decode(Request.self, from: line)
        else { return }
        let (output, exitAfter) = DispatchQueue.main.sync {
            MainActor.assumeIsolated { () -> (Output, Bool) in
                lastActivity = Date()
                defer { lastActivity = Date() }
                let answer = respond(to: request, serving: udid) { args in
                    session?.run(args, cwd: request.cwd) ?? Output("daemon not ready", exit: 1)
                }
                return (answer.0, answer.exitAfter)
            }
        }
        var data = (try? JSONEncoder().encode(output)) ?? Data()
        data.append(0x0A)
        _ = UnixSocket.writeAll(client, data)
        if exitAfter { DispatchQueue.main.async { MainActor.assumeIsolated { finish() } } }
    }

    /// Stop taking requests first (a successor may start right away), then clean up only what is ours.
    @MainActor static func finish() {
        close(listener)
        UnixSocket.unlink(StatePaths.socket(udid).path, ifInode: boundInode)
        if (try? String(contentsOf: StatePaths.pidfile(udid), encoding: .utf8)) == "\(getpid())" {
            try? FileManager.default.removeItem(at: StatePaths.pidfile(udid))
        }
        session?.shutdown()
        exit(0)
    }
}

public enum DaemonClient {
    /// Longest a command may take; `wait` is capped below it (Session.maxWaitSeconds).
    public static let replyTimeout = 600.0

    /// Start a daemon only when nobody is listening. A slow or dropped reply means a daemon exists (C1).
    static func shouldStart(after error: any Error) -> Bool {
        guard let failure = error as? UnixSocket.Failure else { return false }
        return failure.code == ENOENT || failure.code == ECONNREFUSED
    }

    /// Sends `args` to the daemon for `udid`, starting it, or restarting it after an upgrade, when needed.
    public static func send(udid: String, args: [String], cwd: String? = nil, executable: String) throws -> Output {
        let request = Request(version: Chauffeur.buildID, args: args, udid: udid, cwd: cwd)
        for attempt in 0..<2 {
            do {
                let output = try exchange(udid: udid, request: request)
                guard output.exit == Daemon.versionMismatchExit, attempt == 0 else { return output }
                waitForSocketToGo(udid)
                try start(udid: udid, executable: executable)
            } catch {
                guard attempt == 0, shouldStart(after: error) else {
                    throw ChauffeurError.daemon(
                        "no answer from the daemon (it may still be busy; retry shortly); "
                            + "see \(StatePaths.log(udid).path)")
                }
                try start(udid: udid, executable: executable)
            }
        }
        throw ChauffeurError.daemon("no answer from the daemon; see \(StatePaths.log(udid).path)")
    }

    static func exchange(udid: String, request: Request) throws -> Output {
        let fd = try UnixSocket.connect(path: StatePaths.socket(udid).path, timeout: replyTimeout)
        defer { close(fd) }
        var data = try JSONEncoder().encode(request)
        data.append(0x0A)
        guard UnixSocket.writeAll(fd, data), let line = UnixSocket.readLine(fd) else {
            throw ChauffeurError.daemon("connection dropped")
        }
        return try JSONDecoder().decode(Output.self, from: line)
    }

    /// `chauffeur daemon --udid <udid>` in its own session, logging to $TMPDIR/chauffeur/<udid>.log.
    static func start(udid: String, executable: String) throws {
        try StatePaths.ensureDir()
        let logPath = StatePaths.log(udid).path
        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        // CLOEXEC_DEFAULT: the daemon inherits only fds 0–2 below, not the caller's pipes (an MCP client's stdio).
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT))
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 1, logPath, O_WRONLY | O_CREAT | O_APPEND, 0o600)
        posix_spawn_file_actions_adddup2(&actions, 1, 2)
        let argv: [UnsafeMutablePointer<CChar>?] =
            ([executable, "daemon", "--udid", udid] as [String]).map { strdup($0) } + [nil]
        defer { for p in argv { free(p) } }
        var pid: pid_t = 0
        guard posix_spawn(&pid, executable, &actions, &attr, argv, environ) == 0 else {
            throw ChauffeurError.daemon("cannot start \(executable) daemon")
        }
        let deadline = Date().addingTimeInterval(30)  // a predecessor may take up to ~15 s to shut down
        var exited = false
        while Date() < deadline {
            if let fd = try? UnixSocket.connect(path: StatePaths.socket(udid).path, timeout: 1) {
                close(fd)
                return
            }
            if exited { break }
            // waitpid, not kill(pid, 0): an exited child stays a zombie until reaped, and kill() succeeds on zombies.
            // Try one more connect after it exits: it leaves early when another daemon already serves this simulator.
            if waitpid(pid, nil, WNOHANG) == pid {
                exited = true
                continue
            }
            usleep(50_000)
        }
        throw ChauffeurError.daemon("daemon did not start; see \(logPath)")
    }

    static func waitForSocketToGo(_ udid: String) {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, FileManager.default.fileExists(atPath: StatePaths.socket(udid).path) { usleep(50_000) }
    }
}
