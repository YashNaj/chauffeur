import Foundation

/// Lines from stdin, read on a background thread so a `notifications/cancelled` for the request being answered is
/// seen in time: its answer is then dropped (stdio cancellation rule of MCP 2026-07-28).
final class MCPInbox: @unchecked Sendable {
    private let condition = NSCondition()
    private var lines: [Data] = []
    private var cancelled: Set<String> = []
    private var closed = false

    func push(_ line: Data) {
        let message = try? JSON.parse(line)
        condition.lock()
        defer { condition.unlock() }
        if message?["method"] == "notifications/cancelled", let id = message?["params"]?["requestId"] {
            cancelled.insert(id.line())
            return
        }
        lines.append(line)
        condition.signal()
    }

    func close() {
        condition.lock()
        closed = true
        condition.broadcast()
        condition.unlock()
    }

    /// The next line; waits for one. Nil once stdin closed and every line was taken.
    func next() -> Data? {
        condition.lock()
        defer { condition.unlock() }
        while lines.isEmpty && !closed { condition.wait() }
        return lines.isEmpty ? nil : lines.removeFirst()
    }

    func isCancelled(_ id: JSON) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        return cancelled.contains(id.line())
    }
}

/// `chauffeur mcp`: MCP over stdio, one JSON-RPC message per line, until stdin closes. Requests are answered one at a
/// time on the main thread (the simulator bridge needs it). Nothing else may write to stdout.
public enum MCPStdio {
    @MainActor public static func serve(env: CLI.Environment) -> Int32 {
        let inbox = MCPInbox()
        Thread {
            while let line = readLine(strippingNewline: true) { inbox.push(Data(line.utf8)) }
            inbox.close()
        }.start()
        let server = MCPServer { argv in CLI.handle(argv, env) }
        while let line = inbox.next() {
            guard let response = server.respond(toLine: line) else { continue }
            if let id = response["id"], id != .null, inbox.isCancelled(id) { continue }
            // FileHandle writes straight to the pipe; print() would sit in stdout's buffer while the client waits.
            FileHandle.standardOutput.write(Data((response.line() + "\n").utf8))
        }
        return 0
    }
}
