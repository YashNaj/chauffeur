import Foundation

/// Long-lived backboardd TouchEvents stream inside the simulator (S3). Raises BackBoard logging to
/// debug while running and restores the prior level on stop.
public final class TouchLog: @unchecked Sendable {
    public let udid: String
    private let levelFile: URL
    private let lock = NSLock()
    private var parser = TouchLogParser()
    private var records: [TouchRecord] = []
    private var stream: LogStream?
    private var restoreLevel: String?

    public init(udid: String, levelFile: URL) {
        self.udid = udid
        self.levelFile = levelFile
    }

    public static func currentLevel(udid: String) -> String? {
        let r = try? SimCtl.run(
            ["spawn", udid, "log", "config", "--status", "--subsystem", BackBoardLevel.subsystem], timeout: 15)
        return r.flatMap { BackBoardLevel.parse($0.out) }
    }

    /// Running and attached. Only then does "no touch recorded" count as evidence (M1 review minor).
    public var isAttached: Bool { lock.withLock { stream }?.isAttached ?? false }
    public var cursor: Int { lock.withLock { records.count } }

    public func start() throws {
        if isAttached { return }
        stop()  // a stream that never attached: end it and restore the level before trying again
        guard let current = Self.currentLevel(udid: udid) else {
            throw ChauffeurError.bridge("cannot read the BackBoard log level")
        }
        let prior = PriorLevel.choose(saved: PriorLevel.load(levelFile), current: current)
        PriorLevel.save(prior, to: levelFile)
        restoreLevel = prior
        try SimCtl.run(
            ["spawn", udid, "log", "config", "--mode", "level:debug", "--subsystem", BackBoardLevel.subsystem],
            timeout: 15)
        let s = LogStream(
            udid: udid,
            arguments: [
                "--level", "debug", "--style", "ndjson", "--predicate",
                #"process == "backboardd" AND category == "TouchEvents""#,
            ]
        ) { [weak self] object in
            guard let message = object["eventMessage"] as? String else { return }
            self?.consume(message)
        }
        lock.withLock { stream = s }
        guard try s.start(timeout: 5) else {
            stop()
            throw ChauffeurError.bridge("the backboardd log stream did not attach within 5s")
        }
    }

    public func stop() {
        let s = lock.withLock { () -> LogStream? in
            defer { stream = nil }
            return stream
        }
        s?.stop()
        if let level = restoreLevel {
            let r = try? SimCtl.run(
                ["spawn", udid, "log", "config", "--mode", "level:\(level)", "--subsystem", BackBoardLevel.subsystem],
                timeout: 15)
            // Keep the saved level when the restore failed, so the next daemon can still put it back.
            if PriorLevel.restored(status: r?.status ?? -1, levelAfter: Self.currentLevel(udid: udid), prior: level) {
                PriorLevel.clear(levelFile)
            }
            restoreLevel = nil
        }
    }

    /// Evidence for touches recorded after `cursor`, waiting up to `waitMs` for the first record.
    public func evidence(since cursor: Int, waitMs: Int) -> Evidence {
        guard isAttached else { return .unavailable }
        let deadline = Date().addingTimeInterval(Double(waitMs) / 1000)
        while Date() < deadline, self.cursor <= cursor { usleep(10_000) }
        usleep(30_000)  // the app's record and the touch-stream record arrive together
        return lock.withLock { parser.evidence(Array(records[min(cursor, records.count)...])) }
    }

    private func consume(_ message: String) {
        lock.withLock {
            if let record = parser.consume(message) { records.append(record) }
        }
    }
}
