import Foundation

/// Splits `log stream --style ndjson` output into JSON objects. `log` prints a "Filtering the log data…" header once
/// it is attached; that header (or any record) is what proves the stream works.
struct NDJSONReader {
    private var buffer = Data()
    private(set) var attached = false

    mutating func feed(_ chunk: Data) -> [[String: Any]] {
        buffer.append(chunk)
        var objects: [[String: Any]] = []
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer.subdata(in: buffer.startIndex..<nl)
            buffer.removeSubrange(buffer.startIndex...nl)
            if let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] {
                objects.append(object)
                attached = true
            } else if String(decoding: line, as: UTF8.self).hasPrefix("Filtering") {
                attached = true
            }
        }
        if buffer.count > 1 << 20 { buffer.removeAll() }  // a line this long is not a log record
        return objects
    }
}

/// A long-lived `xcrun simctl spawn <udid> log stream …` process (S3, spec §6.8), shared by TouchLog and LogTap.
public final class LogStream: @unchecked Sendable {
    public let udid: String
    public let arguments: [String]
    private let lock = NSLock()
    private var process: Process?
    private var reader = NDJSONReader()
    private let handler: @Sendable ([String: Any]) -> Void

    /// `arguments` follow `log stream`; `handler` gets each record on a background queue.
    public init(udid: String, arguments: [String], handler: @escaping @Sendable ([String: Any]) -> Void) {
        self.udid = udid
        self.arguments = arguments
        self.handler = handler
    }

    /// Running and attached. A process that never printed its header is not a working stream (M1 review minor).
    public var isAttached: Bool { lock.withLock { reader.attached && (process?.isRunning ?? false) } }

    /// Starts the stream and waits up to `timeout` seconds for it to attach. False, with the process stopped, if it
    /// never does.
    public func start(timeout: Double = 5) throws -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        p.arguments = ["simctl", "spawn", udid, "log", "stream"] + arguments
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            if chunk.isEmpty { handle.readabilityHandler = nil; return }
            self?.ingest(chunk)
        }
        lock.withLock { reader = NDJSONReader() }
        try p.run()
        lock.withLock { process = p }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, p.isRunning {
            if isAttached { return true }
            usleep(20_000)
        }
        if isAttached { return true }
        stop()
        return false
    }

    public func stop() {
        let p = lock.withLock { () -> Process? in defer { process = nil }; return process }
        if let p, p.isRunning { p.terminate() }
    }

    private func ingest(_ chunk: Data) {
        let objects = lock.withLock { reader.feed(chunk) }
        for object in objects { handler(object) }
    }
}
