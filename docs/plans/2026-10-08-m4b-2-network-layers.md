# M4b Plan 2: the network layers, PENDING and `wait`

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A tap that starts network activity and changes nothing on screen comes back `PENDING` (exit 6) instead of
`NO EFFECT`; a failed or pointless request explains a `NO EFFECT` in words; `chauffeur wait` finishes a pending tap;
the clipboard counts as an effect; and no URL in any log line shows a query, token or email.

**Architecture:** Two evidence layers, merged per tap. The activity layer reads per-connection byte counts for the
app's processes from Apple's NetworkStatistics framework (a new `CHNetStats` bridge class, loaded with `dlopen`) and
derives what the tap sent and whether a reply is missing (`ConnectionWatch`). The detail layer parses CFNetwork's
lines from the app's existing log stream (`RequestLog`) for host, path shape, status, error, timing and bytes. Pure
types merge them (`RequestEvidence`), word them (`RequestText`) and judge the verdict with a request window
(`NetJudge`); a thin `Session+Network` glue calls them from `tap`.

**Tech Stack:** Swift 6 / SwiftPM, swift-testing, Objective-C (ChauffeurBridge), `xcrun simctl`, Python 3 (`-I`) for
the live tests' local server.

**Spec:** `docs/specs/2026-10-08-m4b-network-and-evidence-design.md` (read its Findings and Decision first; the
owner's decisions of 2026-10-08 are marked "owner decision" in §3, §6 and the Decision).

## Global Constraints

- Work in `~/Developer/repos/chauffeur` on branch `m4b-network`, cut from `m4b-plan2` (this plan's branch). Every
  change reaches `main` through a PR; never push to `main`.
- Commits: author and committer `YashNaj <68571013+YashNaj@users.noreply.github.com>`; no AI `Co-Authored-By`
  trailer; no session links. `scripts/check-commits.sh origin/main..HEAD` must pass.
- `scripts/check.sh` passes before every push. Run `scripts/format.sh` after editing Swift (swift-format, 4 spaces,
  120 columns).
- Lint (`scripts/check-code.sh`): `dlopen`, `dlsym` and private frameworks only in `Sources/ChauffeurBridge`; no
  `try!` in `Sources`; no `print` in `ChauffeurCore`; files under 400 lines in `Sources`, 600 in `Tests`.
  `Session.swift` is at 389 lines: Task 8 moves `waitCommand` out before anything is added to it.
- chauffeur makes no network connections of its own; nothing leaves the machine.
- The agent may see host, port, path shape, status, timing and byte counts; never bodies, headers, cookies, query
  strings, values an app marked private, or clipboard contents (spec §6). There is no HTTP method (Findings §4).
- Hosts and paths are untrusted text: rendered through `Perception.escape`.
- A true no-op is never delayed by more than the 20 ms grace plus one sample (spec goal 2, Decision).
- `PENDING` is exit 6; every other exit code is unchanged.
- Pushing, opening or merging PRs, tagging, releasing and publishing are outward actions: ask the owner before each.
  The owner's PRs merge with `gh pr merge <n> --squash --admin` once CI is green.
- Live tests: check `uptime` first (8 GB host, one simulator at a time; boot, then wait for load under 10 before the
  first chauffeur command). `CHAUFFEUR_LIVE_UDID=<udid> swift test --no-parallel --filter <Suite>`.

## Review Focus

1. **A screen that polls on its own.** A feed refreshing every second must not turn a dead tap into `PENDING`.
   Pinned in Task 4 (`alreadyFlowingIsNotTheTaps`).
2. **A dead tap's speed.** No activity → a verdict after the 20 ms grace, no window, no second look. Pinned in Task 7
   (`aTrueNoOpIsNotDelayed`).
3. **Telemetry only.** An analytics ping after a dead tap stays `NO EFFECT`, with a telemetry line. Pinned in Task 7
   (`telemetryOnlyIsNoEffect`) and Task 8 (`telemetryOnlyStaysNoEffect`).
4. **A token in a logged URL.** CFNetwork's error lines carry the full failing URL; it must reach neither `logs` nor
   an action result unshaped. Pinned in Task 1 (`failingURLsInErrorLinesAreShaped`, `logTapStoresShapedLines`).
5. **A stream that never ends.** A WebSocket that keeps receiving is "data flowing", not `PENDING` forever. Pinned
   in Task 4 (`aConnectionThatKeepsReceivingIsStreaming`) and Task 5 (`streamingIsNotPending`).

## File structure

| File | Responsibility |
|---|---|
| `Sources/ChauffeurCore/Network/LogRedact.swift` | shape every URL in CFNetwork/Network log lines (Task 1) |
| `Sources/ChauffeurCore/Network/RequestLog.swift` | CFNetwork lines → `RequestRecord`s (Task 2) |
| `Sources/ChauffeurBridge/CHNetStats.m` | NetworkStatistics via `dlopen`: per-connection counts for given pids (Task 3) |
| `Sources/ChauffeurCore/Network/Flow.swift` | `Flow`, `FlowSource`, `NetStatsSource` (Task 3) |
| `Sources/ChauffeurCore/Device/Proc+Tree.swift` | parent pid, process name, children by name (Task 3) |
| `Sources/ChauffeurCore/Network/ConnectionWatch.swift` | flows → what the tap sent, waiting, streaming (Task 4) |
| `Sources/ChauffeurCore/Network/RequestEvidence.swift` | `RequestItem`, merge of both layers, telemetry, `NetVerdict` (Task 5) |
| `Sources/ChauffeurCore/Network/RequestText.swift` | words: names, hints, lines, JSON (Task 6) |
| `Sources/ChauffeurCore/Network/NetJudge.swift` | grace, request window, text-field window (Task 7) |
| `Sources/ChauffeurCore/Verifier.swift` | `Outcome.pending`, report fields, rendering, exit 6 (Task 7) |
| `Sources/ChauffeurCore/Engine/Session+Wait.swift` | `wait`, moved out of `Session.swift`; bare `wait` (Tasks 8, 9) |
| `Sources/ChauffeurCore/Engine/Session+Network.swift` | glue: pids, samples, judging a tap (Task 8) |
| `Sources/ChauffeurCore/Engine/Session+Clipboard.swift` | pasteboard hash before/after a tap (Task 10) |
| `Tests/FixtureApp/NetworkView.swift`, `Tests/FixtureApp/netserver.py` | the fixture's Network tab and its server (Task 12) |

The recorded log fixtures are already committed with this plan: `Tests/ChauffeurCoreTests/Fixtures/network/
ios27-requests.jsonl` (step 0 and the POST check on iOS 27: a 500, an HTTPS 404 over h2, a -1004 connection refusal,
a POST with a 14-byte body, a 2.5 s slow GET) and `ios26-keepalive.jsonl` (two requests on one kept-alive
connection; recorded on iOS 26 and completed in the recorded format where the capture was truncated). One JSON object
per line: `level`, `sender`, `message`, as `LogParser` produces them.

---

### Task 1: Shape URLs in Apple's networking log lines

Spec §6, "Logs follow the same rule".

**Files:**
- Create: `Sources/ChauffeurCore/Network/LogRedact.swift`, `Tests/ChauffeurCoreTests/LogRedactTests.swift`
- Modify: `Sources/ChauffeurCore/Logs/LogTap.swift` (`append`)

**Interfaces:**
- Consumes: `PathShape.shape(_:)` (Plan 1).
- Produces: `LogRedact.line(_ line: LogLine) -> LogLine`, `LogRedact.urls(in text: String) -> String`. Every line
  `LogTap` stores is shaped, so `logs`, action results, crash blocks, the log file and Task 2's parser all see
  shaped URLs.

- [ ] **Step 1: Branch**

```bash
cd ~/Developer/repos/chauffeur && git checkout m4b-plan2 && git checkout -b m4b-network
```

- [ ] **Step 2: Write the failing test**

`Tests/ChauffeurCoreTests/LogRedactTests.swift`:

```swift
import Testing

@testable import ChauffeurCore

/// M4b spec §6 ("logs follow the same rule"): Apple's networking lines never show a query, token or email.
@Suite struct LogRedactTests {
    func framework(_ message: String, sender: String = "Network") -> LogLine {
        LogLine(time: "t", level: "default", message: message, sender: sender)
    }

    @Test func connectionURLsAreShaped() {
        let line = framework(
            "[C1 B47F Hostname#a88a3e8b:8765 tcp, url: http://localhost:8765/reset/sam@example.com/7f3a9c1e5b2d4f60a8b1?t=1, definite]"
        )
        #expect(
            LogRedact.line(line).message
                == "[C1 B47F Hostname#a88a3e8b:8765 tcp, url: http://localhost:8765/reset/{email}/{token}, definite]")
    }

    @Test func failingURLsInErrorLinesAreShaped() {
        let line = framework(
            "Task <E8F6>.<3> finished with error [-1004] UserInfo={NSErrorFailingURLStringKey=https://api.example.com/u/8812?token=abc, NSErrorFailingURLKey=https://api.example.com/u/8812?token=abc, _kCFStreamErrorDomainKey=1}",
            sender: "CFNetwork")
        #expect(
            LogRedact.line(line).message
                == "Task <E8F6>.<3> finished with error [-1004] UserInfo={NSErrorFailingURLStringKey=https://api.example.com/u/{id}, NSErrorFailingURLKey=https://api.example.com/u/{id}, _kCFStreamErrorDomainKey=1}"
        )
    }

    @Test func credentialsInAURLAreDropped() {
        #expect(LogRedact.urls(in: "url: https://bob:hunter2@api.example.com/x,") == "url: https://api.example.com/x,")
    }

    @Test func aURLWithoutAPathKeepsItsHost() {
        #expect(LogRedact.urls(in: "url: https://api.example.com?q=1, x") == "url: https://api.example.com/, x")
        #expect(LogRedact.urls(in: "url: https://api.example.com, x") == "url: https://api.example.com, x")
    }

    @Test func theAppsOwnLinesAreLeftAlone() {
        let own = LogLine(time: "t", level: "info", message: "fetching https://api.example.com/u/8812?token=abc")
        #expect(LogRedact.line(own) == own)
    }

    @Test func logTapStoresShapedLines() {
        let tap = LogTap(udid: "TEST")
        tap.append(framework("[C2 url: https://api.example.com/a/123?q=secret, definite]"))
        #expect(tap.all.map(\.message) == ["[C2 url: https://api.example.com/a/{id}, definite]"])
    }
}
```

- [ ] **Step 3: Run it to verify it fails**

Run: `swift test --filter LogRedactTests 2>&1 | grep -E "error:" | head -3`
Expected: `cannot find 'LogRedact' in scope`.

- [ ] **Step 4: Write `LogRedact`**

`Sources/ChauffeurCore/Network/LogRedact.swift`:

```swift
import Foundation

/// Apple's networking log lines with every URL shaped like an evidence line (M4b spec §6, "logs follow the same
/// rule"): CFNetwork's error lines carry the full failing URL, query and all, and the agent reads logs too.
public enum LogRedact {
    /// The frameworks whose lines carry request URLs. The app's own lines stay as the developer logged them.
    static let senders: Set<String> = ["CFNetwork", "Network"]

    public static func line(_ line: LogLine) -> LogLine {
        guard let sender = line.sender, senders.contains(sender), line.message.contains("://") else { return line }
        var shaped = line
        shaped.message = urls(in: line.message)
        return shaped
    }

    /// Each `scheme://[user@]host[:port][/path][?query][#fragment]` in `text`, as `scheme://host[:port]` and the
    /// path's shape.
    public static func urls(in text: String) -> String {
        text.replacing(#/([A-Za-z][A-Za-z0-9+.\-]*):\/\/([^\/?#\s,;}\]"'<>()]*)([^\s,;}\]"'<>()]*)/#) { match in
            let (_, scheme, authority, rest) = match.output
            let host = authority.split(separator: "@", omittingEmptySubsequences: false).last ?? ""
            return "\(scheme)://\(host)" + (rest.isEmpty ? "" : PathShape.shape(String(rest)))
        }
    }
}
```

In `Sources/ChauffeurCore/Logs/LogTap.swift`, replace

```swift
    /// Internal so unit tests can feed lines without a simulator.
    func append(_ line: LogLine) { lock.withLock { ring.append(line) } }
```

with

```swift
    /// Every line is stored with its URLs shaped (M4b spec §6), so no reader ever sees a raw one. Internal so unit
    /// tests can feed lines without a simulator.
    func append(_ line: LogLine) {
        let shaped = LogRedact.line(line)
        lock.withLock { ring.append(shaped) }
    }
```

- [ ] **Step 5: Run the tests**

Run: `scripts/format.sh && swift test --filter "LogRedactTests|LogTapTests|AnnotateTests" 2>&1 | tail -2`
Expected: all pass.

- [ ] **Step 6: Commit**

```bash
git add Sources/ChauffeurCore/Network/LogRedact.swift Sources/ChauffeurCore/Logs/LogTap.swift \
  Tests/ChauffeurCoreTests/LogRedactTests.swift
git commit -m "Logs: shape every URL in Apple's networking lines"
```

---

### Task 2: Parse CFNetwork's lines into requests

Spec §2 (detail layer), Findings §4.

**Files:**
- Create: `Sources/ChauffeurCore/Network/RequestLog.swift`, `Tests/ChauffeurCoreTests/RequestLogTests.swift`
- Modify: `Tests/ChauffeurCoreTests/Support.swift` (a `Fixtures.network` loader)

**Interfaces:**
- Consumes: `LogLine`, `LogRedact.line` (Task 1).
- Produces: `RequestRecord` (fields below) and `RequestLog.parse(_ lines: [LogLine]) -> [RequestRecord]`;
  `Fixtures.network(_ name: String) throws -> [LogLine]` for later tests.

- [ ] **Step 1: The fixture loader**

In `Tests/ChauffeurCoreTests/Support.swift`, inside `enum Fixtures`, after `crash(_:)`:

```swift
    /// Apple networking log lines recorded in M4b step 0 (`Fixtures/network`), as `LogTap` stores them.
    static func network(_ name: String) throws -> [LogLine] {
        let url = try #require(
            Bundle.module.url(forResource: name, withExtension: "jsonl", subdirectory: "Fixtures/network"))
        return try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map { row in
            let o = try #require(try JSONSerialization.jsonObject(with: Data(row.utf8)) as? [String: String])
            return LogRedact.line(
                LogLine(time: "00:00:00.000", level: o["level"] ?? "default", message: o["message"] ?? "",
                    sender: o["sender"]))
        }
    }
```

- [ ] **Step 2: Write the failing test**

`Tests/ChauffeurCoreTests/RequestLogTests.swift`:

```swift
import Testing

@testable import ChauffeurCore

/// M4b spec §2 (detail layer) on lines recorded in step 0 (Findings §4).
@Suite struct RequestLogTests {
    @Test func recordedRequestsOnIOS27() throws {
        let r = RequestLog.parse(try Fixtures.network("ios27-requests"))
        #expect(r.count == 5)
        #expect(
            r[0]
                == RequestRecord(
                    task: "A450514C-ADE9-4A5B-8EB7-AEC43FD10CDB.1", scheme: "http", host: "localhost", port: 8765,
                    path: "/fail", status: 500, finished: true, ms: 481, serverMs: 1, sent: 206, received: 113,
                    proto: "http/1.1", bodyBytes: 0))
        #expect(
            r[1]
                == RequestRecord(
                    task: "846CF447-8C22-4037-91D1-264405128DE8.2", scheme: "https", host: "example.com", port: 443,
                    path: "/a/{id}", status: 404, finished: true, ms: 239, serverMs: 31, sent: 115, received: 487,
                    proto: "h2", bodyBytes: 0))
        #expect(
            r[2]
                == RequestRecord(
                    task: "E8F6340D-1EB2-4D9F-8010-8B310302409F.3", scheme: "http", host: "localhost", port: 8765,
                    path: "/fast", errorCode: -1004, finished: true, ms: 107, sent: 0, received: 0))
        #expect(
            r[3]
                == RequestRecord(
                    task: "F8F70ACA-50C3-48C8-BD85-08965D45B2E2.1", scheme: "http", host: "localhost", port: 8765,
                    path: "/fast", status: 201, finished: true, ms: 175, serverMs: 1, sent: 300, received: 104,
                    proto: "http/1.1", bodyBytes: 14))
        #expect(r[4].path == "/slow" && r[4].status == 200 && r[4].serverMs == 2511 && r[4].ms == 2525)
    }

    @Test func aReusedConnectionGivesTheHostButNoPath() throws {
        let r = RequestLog.parse(try Fixtures.network("ios26-keepalive"))
        #expect(r.map(\.path) == ["/fast", nil])
        #expect(r.map(\.host) == ["localhost", "localhost"])
        #expect(r.map(\.status) == [200, 500])
        #expect(r[1].port == 8765)
    }

    @Test func tasksThatStartedEarlierAreIgnored() throws {
        let lines = try Fixtures.network("ios26-keepalive")
        // Task 6's `resuming` line came before this action's cursor: its later lines are not this action's.
        let r = RequestLog.parse(Array(lines.dropFirst()))
        #expect(r.map(\.task) == ["F230B378-BAE0-497B-9678-B5343E934411.7"])
    }

    @Test func aTaskWithoutItsEndIsStillRunning() throws {
        let slow = try Fixtures.network("ios27-requests").filter {
            $0.message.contains("FE43492F") || $0.message.hasPrefix("[C2 9838CC02")
        }
        // resuming, the connection's url line, setting up, now using, sent request: no reply yet.
        let r = RequestLog.parse(Array(slow.prefix(5)))
        #expect(r.count == 1 && !r[0].finished && r[0].path == "/slow" && r[0].status == nil)
    }

    @Test func otherLinesAreIgnored() {
        let lines = [
            LogLine(time: "t", level: "error", message: "Task <AB>.<1> resuming", sender: nil),  // the app's own
            LogLine(time: "t", level: "default", message: "[C1.1.1 IPv6#5dac:8765 failed]", sender: "Network"),
        ]
        #expect(RequestLog.parse(lines).isEmpty)
    }
}
```

- [ ] **Step 3: Run it to verify it fails**

Run: `swift test --filter RequestLogTests 2>&1 | grep -E "error:" | head -3`
Expected: `cannot find 'RequestLog' in scope` (and `RequestRecord`).

- [ ] **Step 4: Write `RequestLog`**

`Sources/ChauffeurCore/Network/RequestLog.swift`:

```swift
import Foundation

/// One URLSession task, as Apple's networking log lines tell it (M4b spec §2, Findings §4).
public struct RequestRecord: Equatable, Sendable {
    /// `<task UUID>.<n>`, as CFNetwork names it.
    public var task: String
    public var scheme: String? = nil
    public var host: String? = nil
    public var port: Int? = nil
    /// The path's shape; nil when the task reused a connection another request set up (never guessed).
    public var path: String? = nil
    public var status: Int? = nil
    /// An `NSURLError` code such as -1004.
    public var errorCode: Int? = nil
    public var finished = false
    public var ms: Int? = nil
    /// How long the server took to start answering once the request was sent.
    public var serverMs: Int? = nil
    public var sent: Int? = nil
    public var received: Int? = nil
    public var proto: String? = nil
    /// From `sent request, body <kind> <bytes>` (`body N 0` without one, `body S 14` for 14 bytes).
    public var bodyBytes: Int? = nil
}

public enum RequestLog {
    /// The tasks that start in `lines` (a `resuming` line), in order. Lines of a task that started before them belong
    /// to an earlier action and are ignored.
    public static func parse(_ lines: [LogLine]) -> [RequestRecord] {
        var connections: [Int: Endpoint] = [:]
        var order: [String] = []
        var records: [String: RequestRecord] = [:]
        for line in lines {
            if line.sender == "Network", let (n, endpoint) = connectionURL(line.message) {
                connections[n] = endpoint
                continue
            }
            guard line.sender == "CFNetwork", let (task, event) = taskEvent(line.message) else { continue }
            if event.hasPrefix("resuming") {
                if records[task] == nil {
                    order.append(task)
                    records[task] = RequestRecord(task: task)
                }
                continue
            }
            guard var record = records[task] else { continue }
            apply(event, to: &record, connections: connections)
            records[task] = record
        }
        return order.compactMap { records[$0] }
    }

    struct Endpoint {
        var scheme: String
        var host: String
        var port: Int?
        var path: String
    }

    /// `[C7 <uuid> Hostname#…:8765 tcp, url: http://localhost:8765/fast, definite, …]` → (7, its endpoint). Lines of
    /// sub-connections (`[C7.1.1 …`) don't match.
    static func connectionURL(_ m: String) -> (Int, Endpoint)? {
        guard
            let match = m.prefixMatch(
                of: #/\[C(\d+) [^\]]*?url: ([A-Za-z][A-Za-z0-9+.\-]*):\/\/([^\/,\s]+)([^,\s]*)/#),
            let n = Int(match.output.1)
        else { return nil }
        let scheme = match.output.2.lowercased()
        let (host, port) = hostPort(String(match.output.3))
        let path = match.output.4.isEmpty ? "/" : String(match.output.4)
        return (n, Endpoint(scheme: scheme, host: host, port: port ?? defaultPort(scheme), path: path))
    }

    /// `Task <UUID>.<n> <event>` → ("UUID.n", event). The event may span lines (an error's user info).
    static func taskEvent(_ m: String) -> (String, String)? {
        guard let match = m.prefixMatch(of: #/Task <([0-9A-Fa-f\-]+)>\.<(\d+)> /#) else { return nil }
        return ("\(match.output.1).\(match.output.2)", String(m[match.range.upperBound...]))
    }

    static func apply(_ event: String, to r: inout RequestRecord, connections: [Int: Endpoint]) {
        if let m = event.prefixMatch(of: #/setting up Connection (\d+)/#),
            let e = Int(m.output.1).flatMap({ connections[$0] })
        {
            (r.scheme, r.host, r.port, r.path) = (e.scheme, e.host, e.port, e.path)
        } else if let m = event.prefixMatch(of: #/now using Connection (\d+)/#), r.host == nil,
            let e = Int(m.output.1).flatMap({ connections[$0] })
        {
            (r.scheme, r.host, r.port) = (e.scheme, e.host, e.port)  // a reused connection: its path is someone else's
        } else if let m = event.prefixMatch(of: #/sent request, body \S+ (\d+)/#) {
            r.bodyBytes = Int(m.output.1)
        } else if let m = event.prefixMatch(of: #/received response, status (\d+)/#) {
            r.status = Int(m.output.1)
        } else if let m = event.prefixMatch(of: #/HTTP load failed, .*?error code: (-?\d+)/#) {
            r.errorCode = Int(m.output.1)
        } else if let m = event.prefixMatch(of: #/finished with error \[(-?\d+)\]/#) {
            r.errorCode = Int(m.output.1)
            r.finished = true
        } else if event.hasPrefix("finished successfully") {
            r.finished = true
        } else if let m = event.prefixMatch(of: #/summary for task \w+ \{([^}]*)\}/#) {
            summary(String(m.output.1), into: &r)
        }
    }

    /// `transaction_duration_ms=481, response_status=500, …` from the task's summary line.
    static func summary(_ body: String, into r: inout RequestRecord) {
        var fields: [String: String] = [:]
        for pair in body.split(separator: ",") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            guard kv.count == 2 else { continue }
            fields[kv[0].trimmingCharacters(in: .whitespaces)] = kv[1].trimmingCharacters(
                in: CharacterSet(charactersIn: " \""))
        }
        func int(_ key: String) -> Int? { fields[key].flatMap { Int($0) } }
        r.ms = int("transaction_duration_ms") ?? r.ms
        if r.status == nil, let status = int("response_status"), status > 0 { r.status = status }
        r.sent = int("request_bytes") ?? r.sent
        r.received = int("response_bytes") ?? r.received
        r.proto = fields["protocol"] ?? r.proto
        if let answered = int("response_start_ms"), answered > 0, let asked = int("request_start_ms") {
            r.serverMs = max(0, answered - asked - (int("request_duration_ms") ?? 0))
        }
    }

    /// `localhost:8765` → ("localhost", 8765); `[::1]:8765` → ("::1", 8765); no port → nil.
    static func hostPort(_ authority: String) -> (String, Int?) {
        if authority.hasPrefix("["), let close = authority.firstIndex(of: "]") {
            let host = String(authority[authority.index(after: authority.startIndex)..<close])
            let rest = authority[authority.index(after: close)...]
            return (host, rest.hasPrefix(":") ? Int(rest.dropFirst()) : nil)
        }
        let parts = authority.split(separator: ":")
        if parts.count == 2, let port = Int(parts[1]) { return (String(parts[0]), port) }
        return (authority, nil)
    }

    static func defaultPort(_ scheme: String) -> Int? {
        switch scheme {
        case "http", "ws": return 80
        case "https", "wss": return 443
        default: return nil
        }
    }
}
```

- [ ] **Step 5: Run the tests**

Run: `scripts/format.sh && swift test --filter RequestLogTests 2>&1 | tail -2`
Expected: `Test run with 5 tests in 1 suite passed`.

- [ ] **Step 6: Commit**

```bash
git add Sources/ChauffeurCore/Network/RequestLog.swift Tests/ChauffeurCoreTests/RequestLogTests.swift \
  Tests/ChauffeurCoreTests/Support.swift
git commit -m "Requests from CFNetwork's log lines: host, path shape, status, error, timing, bytes"
```

---

### Task 3: The activity layer's source

Spec §2 (activity layer), Findings §1–§2.

**Files:**
- Create: `Sources/ChauffeurBridge/CHNetStats.m`, `Sources/ChauffeurCore/Network/Flow.swift`,
  `Sources/ChauffeurCore/Device/Proc+Tree.swift`, `Tests/ChauffeurCoreTests/FlowTests.swift`,
  `Tests/ChauffeurCoreTests/Live/NetStatsLiveTests.swift`
- Modify: `Sources/ChauffeurBridge/include/ChauffeurBridge.h`

**Interfaces:**
- Consumes: `CHError` (`CHInternal.h`).
- Produces: `Flow` (`id`, `pid`, `process`, `proto`, `remote`, `tx`, `rx`, `openedMs`, `closedMs`, `isOpen`,
  `remoteHost`, `remotePort`); `@MainActor protocol FlowSource { func flows(pids: [Int32]) -> [Flow] }`;
  `NetStatsSource: FlowSource` (`init() throws`); `Proc.parent(_:) -> Int32?`, `Proc.name(_:) -> String?`,
  `Proc.children(of:named:) -> [Int32]`.

- [ ] **Step 1: Write the failing unit tests**

`Tests/ChauffeurCoreTests/FlowTests.swift`:

```swift
import Darwin
import Foundation
import Testing

@testable import ChauffeurCore

@Suite struct FlowTests {
    @Test func aFlowFromTheBridge() throws {
        let d: [String: Any] = [
            "id": NSNumber(value: 7), "pid": NSNumber(value: 4321), "process": "Fixture", "provider": "TCP",
            "remote": "127.0.0.1:8765", "tx": NSNumber(value: 206), "rx": NSNumber(value: 0),
            "openedMs": NSNumber(value: 1000),
        ]
        let f = try #require(Flow(dictionary: d))
        #expect(f == Flow(id: 7, pid: 4321, process: "Fixture", proto: "tcp", remote: "127.0.0.1:8765", tx: 206, rx: 0,
                openedMs: 1000, closedMs: nil))
        #expect(f.isOpen && f.remoteHost == "127.0.0.1" && f.remotePort == 8765)
    }

    @Test func ipv6AndUnknownRemotes() {
        let v6 = Flow(id: 1, pid: 1, process: "", proto: "tcp", remote: "[::1]:8765", tx: 0, rx: 0, openedMs: 0,
            closedMs: 5)
        #expect(v6.remoteHost == "::1" && v6.remotePort == 8765 && !v6.isOpen)
        let none = Flow(id: 2, pid: 1, process: "", proto: "udp", remote: "", tx: 0, rx: 0, openedMs: 0,
            closedMs: nil)
        #expect(none.remoteHost == "" && none.remotePort == nil)
        #expect(Flow(dictionary: ["id": NSNumber(value: 1)]) == nil)  // no pid
    }

    @Test func processTree() throws {
        #expect(Proc.parent(getpid()) == getppid())
        let me = try #require(Proc.name(getpid()))
        #expect(Proc.children(of: getppid(), named: me).contains(getpid()))
        #expect(Proc.children(of: getppid(), named: "no-such-process-name").isEmpty)
    }
}
```

`Tests/ChauffeurCoreTests/Live/NetStatsLiveTests.swift` (gated with the live suites: it needs no simulator, but it
reads private statistics, which CI runners may not allow):

```swift
import Darwin
import Foundation
import Testing

@testable import ChauffeurCore

@Suite(.enabled(if: Live.enabled))
@MainActor struct NetStatsLiveTests {
    @Test func seesThisProcesssConnection() throws {
        let source = try NetStatsSource()
        let server = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(server) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(server, $0, len) } }
        listen(server, 1)
        _ = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(server, $0, &len) }
        }
        let port = Int(UInt16(bigEndian: addr.sin_port))
        let client = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(client) }
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(client, $0, len) }
        }
        #expect(connected == 0)
        let bytes = [UInt8](repeating: 65, count: 100)
        #expect(send(client, bytes, bytes.count, 0) == 100)
        usleep(300_000)
        let flows = source.flows(pids: [getpid()])
        #expect(flows.contains { $0.remotePort == port && $0.tx >= 100 && $0.isOpen }, "\(flows)")
    }
}
```

- [ ] **Step 2: Run them to verify they fail**

Run: `swift test --filter FlowTests 2>&1 | grep -E "error:" | head -3`
Expected: `cannot find 'Flow' in scope` (and `Proc.parent`).

- [ ] **Step 3: The bridge class**

In `Sources/ChauffeurBridge/include/ChauffeurBridge.h`, before the final `NS_ASSUME_NONNULL_END`:

```objc
/// Per-connection network statistics for processes on this Mac (simulator apps are Mac processes), from Apple's
/// private NetworkStatistics framework, loaded at run time (M4b spec §2, Findings §1).
@interface CHNetStats : NSObject
- (nullable instancetype)initWithError:(NSError **)error;
/// Fresh: queries every source, then returns the open flows of `pids` and the ones that closed in the last two
/// minutes. Each flow: id, pid, process, provider (TCP or UDP), remote ("ip:port", empty until known), tx, rx
/// (bytes), openedMs, closedMs (uptime milliseconds, the clock `DispatchTime` uses).
- (NSArray<NSDictionary<NSString *, id> *> *)flowsForPids:(NSArray<NSNumber *> *)pids NS_SWIFT_NAME(flows(pids:));
@end
```

`Sources/ChauffeurBridge/CHNetStats.m`:

```objc
// Per-connection statistics via the private NetworkStatistics framework (what nettop uses), loaded with dlopen so
// the build doesn't link a private framework. Signatures from step 0's probe (M4b Findings §1).
#import "ChauffeurBridge.h"
#import "CHInternal.h"
#import <dlfcn.h>
#import <netdb.h>
#import <sys/socket.h>

typedef void *CHNStatManager;
typedef void *CHNStatSource;
typedef CHNStatManager (*CHCreateFn)(CFAllocatorRef, dispatch_queue_t, void (^)(CHNStatSource, void *));
typedef void (*CHManagerFn)(CHNStatManager);
typedef void (*CHQueryAllFn)(CHNStatManager, void (^)(void));
typedef void (*CHSourceDictFn)(CHNStatSource, void (^)(CFDictionaryRef));
typedef void (*CHSourceVoidFn)(CHNStatSource, void (^)(void));
typedef void (*CHSourceFn)(CHNStatSource);

static uint64_t CHNowMs(void) { return clock_gettime_nsec_np(CLOCK_UPTIME_RAW) / 1000000; }

/// "ip:port" for a sockaddr; empty for an unset address.
static NSString *CHEndpoint(id value) {
    NSData *data = [value isKindOfClass:NSData.class] ? value : nil;
    if (data.length < sizeof(struct sockaddr)) return @"";
    const struct sockaddr *sa = data.bytes;
    char host[NI_MAXHOST] = {0}, port[NI_MAXSERV] = {0};
    if (getnameinfo(sa, (socklen_t)data.length, host, sizeof host, port, sizeof port, NI_NUMERICHOST | NI_NUMERICSERV))
        return @"";
    if (strcmp(port, "0") == 0) return @"";
    return sa->sa_family == AF_INET6 ? [NSString stringWithFormat:@"[%s]:%s", host, port]
                                     : [NSString stringWithFormat:@"%s:%s", host, port];
}

@implementation CHNetStats {
    dispatch_queue_t _queue;
    CHNStatManager _manager;
    CHQueryAllFn _queryAll;
    CHManagerFn _destroy;
    NSMutableDictionary<NSNumber *, NSMutableDictionary *> *_flows;  // only touched on _queue
    uint64_t _nextId;
}

- (nullable instancetype)initWithError:(NSError **)error {
    if (!(self = [super init])) return nil;
    void *lib = dlopen("/System/Library/PrivateFrameworks/NetworkStatistics.framework/NetworkStatistics", RTLD_LAZY);
    CHCreateFn create = lib ? (CHCreateFn)dlsym(lib, "NStatManagerCreate") : NULL;
    CHManagerFn addTCP = lib ? (CHManagerFn)dlsym(lib, "NStatManagerAddAllTCP") : NULL;
    CHManagerFn addUDP = lib ? (CHManagerFn)dlsym(lib, "NStatManagerAddAllUDP") : NULL;
    CHSourceDictFn setDescription = lib ? (CHSourceDictFn)dlsym(lib, "NStatSourceSetDescriptionBlock") : NULL;
    CHSourceDictFn setCounts = lib ? (CHSourceDictFn)dlsym(lib, "NStatSourceSetCountsBlock") : NULL;
    CHSourceVoidFn setRemoved = lib ? (CHSourceVoidFn)dlsym(lib, "NStatSourceSetRemovedBlock") : NULL;
    CHSourceFn queryDescription = lib ? (CHSourceFn)dlsym(lib, "NStatSourceQueryDescription") : NULL;
    _queryAll = lib ? (CHQueryAllFn)dlsym(lib, "NStatManagerQueryAllSources") : NULL;
    _destroy = lib ? (CHManagerFn)dlsym(lib, "NStatManagerDestroy") : NULL;
    if (!create || !addTCP || !addUDP || !setDescription || !setCounts || !setRemoved || !queryDescription ||
        !_queryAll || !_destroy) {
        if (error) *error = CHError(@"NetworkStatistics is unavailable on this Mac");
        return nil;
    }
    _queue = dispatch_queue_create("chauffeur.netstats", DISPATCH_QUEUE_SERIAL);
    _flows = [NSMutableDictionary dictionary];
    __weak CHNetStats *weakSelf = self;
    _manager = create(kCFAllocatorDefault, _queue, ^(CHNStatSource source, void *unused) {
        CHNetStats *strongSelf = weakSelf;
        if (!strongSelf) return;
        NSNumber *key = @(++strongSelf->_nextId);
        NSMutableDictionary *flow = [@{@"id": key, @"openedMs": @(CHNowMs()), @"tx": @0, @"rx": @0} mutableCopy];
        strongSelf->_flows[key] = flow;
        setDescription(source, ^(CFDictionaryRef d) { [CHNetStats update:flow from:(__bridge NSDictionary *)d]; });
        setCounts(source, ^(CFDictionaryRef c) { [CHNetStats update:flow from:(__bridge NSDictionary *)c]; });
        setRemoved(source, ^{ flow[@"closedMs"] = @(CHNowMs()); });
        queryDescription(source);
    });
    if (!_manager) {
        if (error) *error = CHError(@"NetworkStatistics refused a manager");
        return nil;
    }
    addTCP(_manager);
    addUDP(_manager);
    return self;
}

/// A description or counts dictionary: whichever keys it has.
+ (void)update:(NSMutableDictionary *)flow from:(NSDictionary *)d {
    if ([d[@"processID"] isKindOfClass:NSNumber.class]) flow[@"pid"] = d[@"processID"];
    if ([d[@"processName"] isKindOfClass:NSString.class]) flow[@"process"] = d[@"processName"];
    if ([d[@"provider"] isKindOfClass:NSString.class]) flow[@"provider"] = d[@"provider"];
    if (d[@"remoteAddress"]) {
        NSString *remote = CHEndpoint(d[@"remoteAddress"]);
        if (remote.length) flow[@"remote"] = remote;
    }
    if ([d[@"txBytes"] isKindOfClass:NSNumber.class]) flow[@"tx"] = d[@"txBytes"];
    if ([d[@"rxBytes"] isKindOfClass:NSNumber.class]) flow[@"rx"] = d[@"rxBytes"];
}

- (NSArray<NSDictionary<NSString *, id> *> *)flowsForPids:(NSArray<NSNumber *> *)pids {
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    _queryAll(_manager, ^{ dispatch_semaphore_signal(done); });
    dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 250 * NSEC_PER_MSEC));
    NSSet<NSNumber *> *wanted = [NSSet setWithArray:pids];
    NSMutableArray *out = [NSMutableArray array];
    dispatch_sync(_queue, ^{
        uint64_t now = CHNowMs();
        NSMutableArray *expired = [NSMutableArray array];
        [self->_flows enumerateKeysAndObjectsUsingBlock:^(NSNumber *key, NSMutableDictionary *flow, BOOL *stop) {
            NSNumber *closed = flow[@"closedMs"];
            if (closed && now - closed.unsignedLongLongValue > 120000) {
                [expired addObject:key];
                return;
            }
            if (flow[@"pid"] && [wanted containsObject:flow[@"pid"]]) [out addObject:[flow copy]];
        }];
        [self->_flows removeObjectsForKeys:expired];
    });
    return out;
}

- (void)dealloc {
    if (_manager && _destroy) _destroy(_manager);
}
@end
```

- [ ] **Step 4: The Swift side**

`Sources/ChauffeurCore/Network/Flow.swift`:

```swift
import ChauffeurBridge
import Foundation

/// One connection of a watched process: what the activity layer sees (M4b spec §2).
public struct Flow: Equatable, Sendable {
    public var id: Int
    public var pid: Int32
    public var process: String
    /// `tcp` or `udp`.
    public var proto: String
    /// `ip:port` (`[ip]:port` for IPv6); empty until the connection has a remote address.
    public var remote: String
    public var tx: Int
    public var rx: Int
    /// Uptime milliseconds, the clock `SystemClock` reads.
    public var openedMs: Int
    public var closedMs: Int?

    public init(
        id: Int, pid: Int32, process: String, proto: String, remote: String, tx: Int, rx: Int, openedMs: Int,
        closedMs: Int?
    ) {
        (self.id, self.pid, self.process, self.proto, self.remote) = (id, pid, process, proto, remote)
        (self.tx, self.rx, self.openedMs, self.closedMs) = (tx, rx, openedMs, closedMs)
    }

    /// A flow as `CHNetStats` reports it; nil without an id and a pid.
    init?(dictionary d: [String: Any]) {
        guard let id = (d["id"] as? NSNumber)?.intValue, let pid = (d["pid"] as? NSNumber)?.int32Value else {
            return nil
        }
        self.init(
            id: id, pid: pid, process: d["process"] as? String ?? "",
            proto: (d["provider"] as? String ?? "").lowercased(), remote: d["remote"] as? String ?? "",
            tx: (d["tx"] as? NSNumber)?.intValue ?? 0, rx: (d["rx"] as? NSNumber)?.intValue ?? 0,
            openedMs: (d["openedMs"] as? NSNumber)?.intValue ?? 0, closedMs: (d["closedMs"] as? NSNumber)?.intValue)
    }

    public var isOpen: Bool { closedMs == nil }

    public var remoteHost: String {
        if remote.hasPrefix("["), let close = remote.firstIndex(of: "]") {
            return String(remote[remote.index(after: remote.startIndex)..<close])
        }
        return remote.lastIndex(of: ":").map { String(remote[..<$0]) } ?? remote
    }

    public var remotePort: Int? { remote.lastIndex(of: ":").flatMap { Int(remote[remote.index(after: $0)...]) } }
}

/// Where flows come from: the NetworkStatistics bridge in the daemon, a scripted list in tests.
@MainActor
public protocol FlowSource: AnyObject {
    func flows(pids: [Int32]) -> [Flow]
}

@MainActor
public final class NetStatsSource: FlowSource {
    private let stats: CHNetStats

    public init() throws {
        do { stats = try CHNetStats() } catch { throw ChauffeurError.bridge(error.localizedDescription) }
    }

    public func flows(pids: [Int32]) -> [Flow] {
        stats.flows(pids: pids.map { NSNumber(value: $0) }).compactMap(Flow.init(dictionary:))
    }
}
```

`Sources/ChauffeurCore/Device/Proc+Tree.swift`:

```swift
import Darwin
import Foundation

extension Proc {
    /// The parent of `pid`; nil when it is gone.
    public static func parent(_ pid: Int32) -> Int32? {
        guard pid > 0 else { return nil }
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return info.kp_eproc.e_ppid
    }

    /// The process's name (up to 32 characters, enough for `com.apple.WebKit.Networking`); nil when it is gone.
    public static func name(_ pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 256)
        guard proc_name(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }

    /// Running processes called `name` whose parent is `parent`: how a simulator's WebKit networking process is
    /// found, as the app's sibling under the device's launchd_sim (M4b Findings §2).
    public static func children(of parent: Int32, named name: String) -> [Int32] {
        let capacity = Int(proc_listallpids(nil, 0)) + 64
        var pids = [Int32](repeating: 0, count: capacity)
        let count = Int(proc_listallpids(&pids, Int32(capacity * MemoryLayout<Int32>.size)))
        return pids.prefix(max(count, 0)).filter { $0 > 0 && Self.parent($0) == parent && Self.name($0) == name }
    }
}
```

- [ ] **Step 5: Run the unit tests and the live check**

Run: `scripts/format.sh && swift test --filter FlowTests 2>&1 | tail -2`
Expected: `Test run with 3 tests in 1 suite passed`.

Run: `CHAUFFEUR_LIVE_UDID=x swift test --filter NetStatsLiveTests 2>&1 | tail -2`
Expected: pass (the suite needs no simulator; the variable only enables it). If it fails, read the `flows` it prints
before changing anything: Findings §1 records the dictionary keys this code reads.

- [ ] **Step 6: Commit**

```bash
git add Sources/ChauffeurBridge/CHNetStats.m Sources/ChauffeurBridge/include/ChauffeurBridge.h \
  Sources/ChauffeurCore/Network/Flow.swift Sources/ChauffeurCore/Device/Proc+Tree.swift \
  Tests/ChauffeurCoreTests/FlowTests.swift Tests/ChauffeurCoreTests/Live/NetStatsLiveTests.swift
git commit -m "Activity layer: per-connection counts from NetworkStatistics, and the process tree"
```

---

### Task 4: What a tap did on the network

Spec §2 ("What belongs to the tap").

**Files:**
- Create: `Sources/ChauffeurCore/Network/ConnectionWatch.swift`, `Tests/ChauffeurCoreTests/ConnectionWatchTests.swift`

**Interfaces:**
- Consumes: `Flow` (Task 3).
- Produces: `FlowActivity` (`flow`, `sent`, `received`, `isNew`, `waiting`);
  `ConnectionWatch.activity(earlier:atTouch:now:) -> [FlowActivity]`;
  `ConnectionWatch.streaming(previous:now:) -> [FlowActivity]`.

- [ ] **Step 1: Write the failing test**

`Tests/ChauffeurCoreTests/ConnectionWatchTests.swift`:

```swift
import Testing

@testable import ChauffeurCore

/// M4b spec §2: activity belongs to the tap when it started after the touch.
@Suite struct ConnectionWatchTests {
    func flow(_ id: Int, tx: Int, rx: Int, open: Bool = true, remote: String = "127.0.0.1:8765") -> Flow {
        Flow(id: id, pid: 1, process: "Fixture", proto: "tcp", remote: remote, tx: tx, rx: rx, openedMs: id,
            closedMs: open ? nil : 99)
    }

    @Test func aNewConnectionWaitingForItsReply() {
        let a = ConnectionWatch.activity(earlier: [], atTouch: [], now: [flow(1, tx: 206, rx: 0)])
        #expect(a.count == 1 && a[0].isNew && a[0].sent == 206 && a[0].waiting)
    }

    @Test func aReplyEndsTheWait() {
        let a = ConnectionWatch.activity(earlier: [], atTouch: [], now: [flow(1, tx: 206, rx: 94, open: false)])
        #expect(a.count == 1 && !a[0].waiting)
    }

    @Test func socketsThatMovedNoBytesAreDropped() {
        #expect(ConnectionWatch.activity(earlier: [], atTouch: [], now: [flow(1, tx: 0, rx: 0)]).isEmpty)
    }

    @Test func aReusedConnectionCountsWhatItSentAfterTheTouch() {
        let a = ConnectionWatch.activity(
            earlier: [flow(1, tx: 100, rx: 500)], atTouch: [flow(1, tx: 100, rx: 500)],
            now: [flow(1, tx: 300, rx: 500)])
        #expect(a.count == 1 && !a[0].isNew && a[0].sent == 200 && a[0].received == 0 && a[0].waiting)
    }

    @Test func alreadyFlowingIsNotTheTaps() {
        // A feed that was loading between the first sample and the touch keeps loading: someone else's traffic.
        let a = ConnectionWatch.activity(
            earlier: [flow(1, tx: 100, rx: 100)], atTouch: [flow(1, tx: 100, rx: 400)],
            now: [flow(1, tx: 200, rx: 600)])
        #expect(a.isEmpty)
    }

    @Test func aReplyToAnEarlierRequestIsNotTheTaps() {
        let a = ConnectionWatch.activity(
            earlier: [flow(1, tx: 100, rx: 0)], atTouch: [flow(1, tx: 100, rx: 0)], now: [flow(1, tx: 100, rx: 94)])
        #expect(a.isEmpty)
    }

    @Test func aConnectionThatKeepsReceivingIsStreaming() {
        let first = ConnectionWatch.activity(earlier: [], atTouch: [], now: [flow(1, tx: 200, rx: 20)])
        let later = ConnectionWatch.activity(earlier: [], atTouch: [], now: [flow(1, tx: 200, rx: 60)])
        #expect(ConnectionWatch.streaming(previous: first, now: later).map(\.flow.id) == [1])
        // Still sending, or closed: not a stream.
        let sending = ConnectionWatch.activity(earlier: [], atTouch: [], now: [flow(1, tx: 300, rx: 60)])
        #expect(ConnectionWatch.streaming(previous: first, now: sending).isEmpty)
        let closed = ConnectionWatch.activity(earlier: [], atTouch: [], now: [flow(1, tx: 200, rx: 60, open: false)])
        #expect(ConnectionWatch.streaming(previous: first, now: closed).isEmpty)
    }
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `swift test --filter ConnectionWatchTests 2>&1 | grep -E "error:" | head -2`
Expected: `cannot find 'ConnectionWatch' in scope`.

- [ ] **Step 3: Write `ConnectionWatch`**

`Sources/ChauffeurCore/Network/ConnectionWatch.swift`:

```swift
import Foundation

/// One connection's part in a tap: the bytes it moved since the touch (M4b spec §2).
public struct FlowActivity: Equatable, Sendable {
    public var flow: Flow
    public var sent: Int
    public var received: Int
    /// Opened after the touch.
    public var isNew: Bool

    /// Bytes went out and nothing has come back on a connection that is still open.
    public var waiting: Bool { flow.isOpen && sent > 0 && received == 0 }
}

public enum ConnectionWatch {
    /// The tap's activity: connections opened after the touch, and connections open before it that sent bytes after
    /// it (HTTP/2 reuses one connection for new requests). A connection already moving bytes between `earlier` (a
    /// sample before the baseline) and `atTouch` is someone else's (a feed loading, polling). Connections that moved no
    /// bytes (address lookups, unused sockets) are dropped.
    public static func activity(earlier: [Flow], atTouch: [Flow], now: [Flow]) -> [FlowActivity] {
        let before = Dictionary(atTouch.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let first = Dictionary(earlier.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return now.compactMap { f in
            if let b = before[f.id] {
                if let e = first[f.id], e.tx != b.tx || e.rx != b.rx { return nil }
                let sent = f.tx - b.tx
                guard sent > 0 else { return nil }  // a reply to an earlier request, or a stream opened earlier
                return FlowActivity(flow: f, sent: sent, received: f.rx - b.rx, isNew: false)
            }
            guard f.tx > 0 || f.rx > 0 else { return nil }
            return FlowActivity(flow: f, sent: f.tx, received: f.rx, isNew: true)
        }
    }

    /// Connections that kept receiving between two samples of the same tap without sending: a WebSocket after its
    /// upgrade or a server stream, which wait for nothing (spec §3).
    public static func streaming(previous: [FlowActivity], now: [FlowActivity]) -> [FlowActivity] {
        let earlier = Dictionary(previous.map { ($0.flow.id, $0) }, uniquingKeysWith: { first, _ in first })
        return now.filter { a in
            guard a.flow.isOpen, a.received > 0, let b = earlier[a.flow.id] else { return false }
            return a.received > b.received && a.sent == b.sent
        }
    }
}
```

- [ ] **Step 4: Run the tests**

Run: `scripts/format.sh && swift test --filter ConnectionWatchTests 2>&1 | tail -2`
Expected: `Test run with 7 tests in 1 suite passed`.

- [ ] **Step 5: Commit**

```bash
git add Sources/ChauffeurCore/Network/ConnectionWatch.swift Tests/ChauffeurCoreTests/ConnectionWatchTests.swift
git commit -m "What a tap did on the network: sent after the touch, waiting, streaming"
```

---

### Task 5: Requests, merged from both layers

Spec §2 ("matched to activity by host and time"), §3, §4.

**Files:**
- Create: `Sources/ChauffeurCore/Network/RequestEvidence.swift`, `Tests/ChauffeurCoreTests/RequestEvidenceTests.swift`

**Interfaces:**
- Consumes: `RequestRecord` (Task 2), `FlowActivity` (Task 4), `Telemetry.isTelemetry(host:path:extra:)` (Plan 1).
- Produces: `RequestItem` (fields below, all but `host` defaulted); `NetVerdict` (`.none([RequestItem])` for
  nothing or telemetry only, `.pending([RequestItem])`, `.settled([RequestItem])`, and `items`);
  `RequestEvidence.merge(records:activity:streaming:telemetryExtra:) -> [RequestItem]`;
  `RequestEvidence.verdict(_:) -> NetVerdict`.

- [ ] **Step 1: Write the failing test**

`Tests/ChauffeurCoreTests/RequestEvidenceTests.swift`:

```swift
import Testing

@testable import ChauffeurCore

@Suite struct RequestEvidenceTests {
    func activity(_ id: Int, remote: String, tx: Int, rx: Int, open: Bool = true) -> FlowActivity {
        FlowActivity(
            flow: Flow(id: id, pid: 1, process: "Fixture", proto: "tcp", remote: remote, tx: tx, rx: rx, openedMs: id,
                closedMs: open ? nil : 99), sent: tx, received: rx, isNew: true)
    }
    let api = RequestRecord(task: "A.1", scheme: "https", host: "api.example.com", port: 443, path: "/login")

    @Test func aRecordExplainsItsConnection() {
        let items = RequestEvidence.merge(
            records: [api], activity: [activity(1, remote: "93.184.215.14:443", tx: 900, rx: 0)], streaming: [],
            telemetryExtra: [])
        #expect(items == [RequestItem(host: "api.example.com", port: 443, path: "/login", waiting: true)])
    }

    @Test func aConnectionNoRecordExplainsIsItsOwnItem() {
        let items = RequestEvidence.merge(
            records: [], activity: [activity(1, remote: "127.0.0.1:8765", tx: 58, rx: 0)], streaming: [],
            telemetryExtra: [])
        #expect(
            items == [
                RequestItem(host: "127.0.0.1", port: 8765, sent: 58, received: 0, proto: "tcp", waiting: true,
                    hostKnown: false)
            ])
    }

    @Test func oneConnectionPerRecord() {
        let items = RequestEvidence.merge(
            records: [api],
            activity: [
                activity(1, remote: "93.184.215.14:443", tx: 900, rx: 0),
                activity(2, remote: "10.0.0.9:443", tx: 300, rx: 0),
            ], streaming: [], telemetryExtra: [])
        #expect(items.map(\.host) == ["api.example.com", "10.0.0.9"])
    }

    @Test func telemetryIsMarkedAndDoesNotCount() {
        var ping = api
        ping.host = "app-measurement.com"
        let items = RequestEvidence.merge(records: [ping], activity: [], streaming: [], telemetryExtra: [])
        #expect(items.map(\.telemetry) == [true])
        #expect(RequestEvidence.verdict(items) == .none(items))
    }

    @Test func projectEntriesAreTelemetryToo() {
        var metrics = api
        metrics.path = "/metrics/event"
        let items = RequestEvidence.merge(
            records: [metrics], activity: [], streaming: [], telemetryExtra: ["api.example.com/metrics"])
        #expect(items.map(\.telemetry) == [true])
    }

    @Test func streamingIsNotPending() {
        let socket = activity(1, remote: "127.0.0.1:8766", tx: 200, rx: 60)
        let items = RequestEvidence.merge(records: [], activity: [socket], streaming: [socket], telemetryExtra: [])
        #expect(items.map(\.streaming) == [true] && items.map(\.waiting) == [false])
        #expect(RequestEvidence.verdict(items) == .settled(items))
    }

    @Test func anyMissingReplyIsPending() {
        var done = api
        done.finished = true
        done.status = 200
        var open = api
        open.task = "A.2"
        let items = RequestEvidence.merge(records: [done, open], activity: [], streaming: [], telemetryExtra: [])
        #expect(RequestEvidence.verdict(items) == .pending(items))
        #expect(RequestEvidence.verdict([]) == .none([]))
    }
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `swift test --filter RequestEvidenceTests 2>&1 | grep -E "error:" | head -2`
Expected: `cannot find 'RequestEvidence' in scope`.

- [ ] **Step 3: Write `RequestEvidence`**

`Sources/ChauffeurCore/Network/RequestEvidence.swift`:

```swift
import Foundation

/// One request or connection a tap caused, as the agent sees it (M4b spec §3, §6).
public struct RequestItem: Equatable, Sendable {
    /// A host name from the logs, or the remote IP when only the activity layer saw it; empty while a task has no
    /// connection yet.
    public var host: String
    public var port: Int? = nil
    /// The path's shape; nil when unknown (activity only, or a reused connection).
    public var path: String? = nil
    public var status: Int? = nil
    public var errorCode: Int? = nil
    public var ms: Int? = nil
    public var serverMs: Int? = nil
    public var sent: Int? = nil
    public var received: Int? = nil
    public var proto: String? = nil
    public var bodyBytes: Int? = nil
    public var waiting = false
    public var streaming = false
    public var telemetry = false
    /// False when only the activity layer saw it: its host is an IP, so the telemetry filter couldn't run.
    public var hostKnown = true

    public var failed: Bool { errorCode != nil || (status ?? 0) >= 400 }
}

/// The network half of a tap's verdict (spec §3).
public enum NetVerdict: Equatable, Sendable {
    /// Nothing the tap caused, or telemetry only (the items, for the telemetry line).
    case none([RequestItem])
    /// A reply the app is still waiting for.
    case pending([RequestItem])
    /// Every reply arrived or failed; a stream that keeps flowing counts as arrived.
    case settled([RequestItem])

    public var items: [RequestItem] {
        switch self {
        case .none(let items), .pending(let items), .settled(let items): return items
        }
    }
}

public enum RequestEvidence {
    /// Joins the two layers. Every log record is an item; it explains one connection to its port (the earliest
    /// unexplained one), whose streaming it takes on. Every connection no record explains is an item of its own (a
    /// non-Apple stack). Telemetry is marked here, never dropped: it gets its own line.
    public static func merge(
        records: [RequestRecord], activity: [FlowActivity], streaming: [FlowActivity], telemetryExtra: [String]
    ) -> [RequestItem] {
        let streams = Set(streaming.map(\.flow.id))
        var unexplained = activity.sorted { $0.flow.openedMs < $1.flow.openedMs }
        var items: [RequestItem] = []
        for r in records {
            var item = RequestItem(
                host: r.host ?? "", port: r.port, path: r.path, status: r.status, errorCode: r.errorCode, ms: r.ms,
                serverMs: r.serverMs, sent: r.sent, received: r.received, proto: r.proto, bodyBytes: r.bodyBytes,
                waiting: !r.finished)
            if let port = r.port, let i = unexplained.firstIndex(where: { $0.flow.remotePort == port }) {
                if streams.contains(unexplained.remove(at: i).flow.id) {
                    item.streaming = true
                    item.waiting = false
                }
            }
            item.telemetry =
                !item.host.isEmpty && Telemetry.isTelemetry(host: item.host, path: item.path, extra: telemetryExtra)
            items.append(item)
        }
        for a in unexplained {
            let streaming = streams.contains(a.flow.id)
            items.append(
                RequestItem(
                    host: a.flow.remoteHost, port: a.flow.remotePort, sent: a.sent, received: a.received,
                    proto: a.flow.proto, waiting: a.waiting && !streaming, streaming: streaming, hostKnown: false))
        }
        return items
    }

    public static func verdict(_ items: [RequestItem]) -> NetVerdict {
        let real = items.filter { !$0.telemetry }
        if real.isEmpty { return .none(items) }
        return real.contains(where: \.waiting) ? .pending(items) : .settled(items)
    }
}
```

- [ ] **Step 4: Run the tests**

Run: `scripts/format.sh && swift test --filter RequestEvidenceTests 2>&1 | tail -2`
Expected: `Test run with 7 tests in 1 suite passed`.

- [ ] **Step 5: Commit**

```bash
git add Sources/ChauffeurCore/Network/RequestEvidence.swift Tests/ChauffeurCoreTests/RequestEvidenceTests.swift
git commit -m "Requests merged from both layers, with telemetry marked"
```

---

### Task 6: How a request reads

Spec §3 ("What a request line carries", owner decision), §4 (telemetry line), §6 (escaping).

**Files:**
- Create: `Sources/ChauffeurCore/Network/RequestText.swift`, `Tests/ChauffeurCoreTests/RequestTextTests.swift`

**Interfaces:**
- Consumes: `RequestItem` (Task 5), `Perception.escape(_:limit:)`, `JSON`.
- Produces: `RequestText.target(_:)`, `outcome(_:elapsedMs:)`, `details(_:)`, `line(_:elapsedMs:)`,
  `lines(_:elapsedMs:except:) -> [String]` (request lines for every non-telemetry item but `except`, then the
  telemetry line), `telemetry(_:) -> String?`, `hint(_:) -> String?`, `json(_:) -> JSON`.

**Ruling recorded in the plan:** spec §6 says hosts and paths are "quoted and escaped like screen text", but every
example in §3 shows them unquoted. They go through `Perception.escape` (quotes, backslashes and controls escaped,
length capped) without surrounding quotes. Cost if wrong: add `"` around `target`, one line.

- [ ] **Step 1: Write the failing test**

`Tests/ChauffeurCoreTests/RequestTextTests.swift`:

```swift
import Testing

@testable import ChauffeurCore

@Suite struct RequestTextTests {
    let fail = RequestItem(
        host: "localhost", port: 8765, path: "/fail", status: 500, ms: 481, serverMs: 1, sent: 206, received: 113,
        proto: "http/1.1", bodyBytes: 0)
    let post = RequestItem(
        host: "localhost", port: 8765, path: "/fast", status: 201, ms: 175, serverMs: 1, sent: 300, received: 104,
        proto: "http/1.1", bodyBytes: 14)
    let refused = RequestItem(host: "localhost", port: 8765, path: "/fast", errorCode: -1004, ms: 107, sent: 0,
        received: 0)

    @Test func aStatusInWords() {
        #expect(RequestText.outcome(fail, elapsedMs: 600) == "localhost:8765/fail → 500 Internal Server Error in 481 ms (server 1 ms)")
        #expect(RequestText.details(fail) == "sent 206 B, got 113 B · http/1.1")
        #expect(RequestText.details(post) == "sent 300 B (body 14 B), got 104 B · http/1.1")
    }

    @Test func anErrorInWords() {
        #expect(
            RequestText.outcome(refused, elapsedMs: 200)
                == "localhost:8765/fast failed: could not connect to the server (-1004) after 107 ms")
        #expect(RequestText.details(refused) == "")
        #expect(RequestText.hint(refused) == "nothing accepted the connection at localhost:8765; is the server running?")
    }

    @Test func stillRunning() {
        let open = RequestItem(host: "api.example.com", port: 443, path: "/login", waiting: true)
        #expect(RequestText.outcome(open, elapsedMs: 2200) == "api.example.com/login still running after 2.2 s")
        let raw = RequestItem(host: "127.0.0.1", port: 8765, sent: 58, received: 0, proto: "tcp", waiting: true,
            hostKnown: false)
        #expect(RequestText.outcome(raw, elapsedMs: 2100) == "127.0.0.1:8765 · sent 58 B, no reply after 2.1 s")
        #expect(RequestText.details(raw) == "telemetry filter unavailable for 127.0.0.1")
    }

    @Test func aStream() {
        let socket = RequestItem(host: "127.0.0.1", port: 8766, sent: 200, received: 1200, proto: "tcp",
            streaming: true, hostKnown: false)
        #expect(RequestText.line(socket, elapsedMs: 900)
            == "request: 127.0.0.1:8766 · connected, data flowing · got 1.2 KB · telemetry filter unavailable for 127.0.0.1")
    }

    @Test func hints() {
        #expect(RequestText.hint(fail) == "the server failed (500) and the app shows nothing for it; check the server or the app's error handling")
        var unauthorized = fail
        unauthorized.status = 401
        #expect(RequestText.hint(unauthorized) == "the server refused the request (401); the app may be signed out")
        #expect(RequestText.hint(post) == "the request succeeded but the screen didn't change; the app may not update the screen for this response")
    }

    @Test func telemetryAndLines() {
        let ping = RequestItem(host: "app-measurement.com", port: 443, path: "/a", status: 204, telemetry: true)
        let sentry = RequestItem(host: "o1.ingest.sentry.io", port: 443, status: 200, telemetry: true)
        #expect(RequestText.telemetry([fail, ping, sentry]) == "telemetry: 2 requests (app-measurement.com, o1.ingest.sentry.io)")
        #expect(RequestText.lines([fail, post, ping], elapsedMs: 600, except: fail) == [
            "request: localhost:8765/fast → 201 Created in 175 ms (server 1 ms) · sent 300 B (body 14 B), got 104 B · http/1.1",
            "telemetry: 1 request (app-measurement.com)",
        ])
    }

    @Test func hostsAndPathsAreEscaped() {
        let hostile = RequestItem(host: "evil\"\ncom", port: 443, path: "/x", status: 200)
        #expect(RequestText.target(hostile) == "evil\\\"\\ncom/x")
    }

    @Test func jsonLeavesOutWhatIsUnknown() {
        let raw = RequestItem(host: "127.0.0.1", port: 8765, sent: 58, received: 0, proto: "tcp", waiting: true,
            hostKnown: false)
        let json = RequestText.json(raw)
        #expect(json["host"]?.string == "127.0.0.1" && json["port"]?.int == 8765 && json["waiting"]?.bool == true)
        #expect(json["status"] == nil && json["path"] == nil)
        #expect(RequestText.json(fail)["status"]?.int == 500)
    }

    @Test func sizesAndTimes() {
        #expect(RequestText.bytes(94) == "94 B" && RequestText.bytes(1234) == "1.2 KB" && RequestText.bytes(3_400_000) == "3.4 MB")
        #expect(RequestText.duration(180) == "180 ms" && RequestText.duration(2500) == "2.5 s")
    }
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `swift test --filter RequestTextTests 2>&1 | grep -E "error:" | head -2`
Expected: `cannot find 'RequestText' in scope`.

- [ ] **Step 3: Write `RequestText`**

`Sources/ChauffeurCore/Network/RequestText.swift`:

```swift
import Foundation

/// How a request reads in a result (M4b spec §3, owner decision 2026-10-08): what happened in words, the numbers
/// behind it, and what to try. Hosts and paths come from the network: escaped like log text.
public enum RequestText {
    /// `localhost:8765/fail`, `api.example.com/login`: the port only when it isn't the scheme's usual one, and always
    /// for a bare IP.
    public static func target(_ i: RequestItem) -> String {
        hostPort(i) + Perception.escape(i.path ?? "", limit: 120)
    }

    static func hostPort(_ i: RequestItem) -> String {
        guard !i.host.isEmpty else { return "a request" }
        let host = Perception.escape(i.host.contains(":") ? "[\(i.host)]" : i.host, limit: 80)
        guard let port = i.port, !(i.hostKnown && (port == 80 || port == 443)) else { return host }
        return "\(host):\(port)"
    }

    /// What happened, for a headline.
    public static func outcome(_ i: RequestItem, elapsedMs: Int) -> String {
        let t = target(i)
        if i.streaming { return t + " · connected, data flowing" }
        if i.waiting {
            return i.hostKnown
                ? t + " still running after " + duration(elapsedMs)
                : t + " · sent " + bytes(i.sent ?? 0) + ", no reply after " + duration(elapsedMs)
        }
        if let code = i.errorCode {
            return t + " failed: \(errorName(code)) (\(code))" + (i.ms.map { " after " + duration($0) } ?? "")
        }
        if let status = i.status {
            return t + " → \(status)" + (statusName(status).map { " " + $0 } ?? "")
                + (i.ms.map { " in " + duration($0) } ?? "") + (i.serverMs.map { " (server \(duration($0)))" } ?? "")
        }
        return t + " · sent \(bytes(i.sent ?? 0)), got \(bytes(i.received ?? 0))"
    }

    /// The numbers behind it: `sent 300 B (body 14 B), got 104 B · http/1.1`; empty when there are none.
    public static func details(_ i: RequestItem) -> String {
        var parts: [String] = []
        if i.hostKnown, i.status != nil || i.errorCode != nil, let sent = i.sent, let received = i.received,
            sent + received > 0
        {
            let body = i.bodyBytes.flatMap { $0 > 0 ? " (body \(bytes($0)))" : nil } ?? ""
            parts.append("sent \(bytes(sent))\(body), got \(bytes(received))")
        }
        if i.streaming, let received = i.received { parts.append("got \(bytes(received))") }
        if i.hostKnown, let proto = i.proto { parts.append(Perception.escape(proto, limit: 20)) }
        if !i.hostKnown, !i.host.isEmpty {
            parts.append("telemetry filter unavailable for " + Perception.escape(i.host, limit: 80))
        }
        return parts.joined(separator: " · ")
    }

    public static func line(_ i: RequestItem, elapsedMs: Int) -> String {
        let more = details(i)
        return "request: " + outcome(i, elapsedMs: elapsedMs) + (more.isEmpty ? "" : " · " + more)
    }

    /// A line per request but `except` (the one a headline already names), then the telemetry line.
    public static func lines(_ items: [RequestItem], elapsedMs: Int, except lead: RequestItem? = nil) -> [String] {
        var rest = items.filter { !$0.telemetry }
        if let lead, let i = rest.firstIndex(of: lead) { rest.remove(at: i) }
        return rest.map { line($0, elapsedMs: elapsedMs) } + (telemetry(items).map { [$0] } ?? [])
    }

    /// `telemetry: 2 requests (app-measurement.com, sentry.io)`; never in a headline (spec §3).
    public static func telemetry(_ items: [RequestItem]) -> String? {
        let pings = items.filter(\.telemetry)
        guard !pings.isEmpty else { return nil }
        var hosts: [String] = []
        for p in pings where !hosts.contains(p.host) { hosts.append(p.host) }
        return "telemetry: \(pings.count) request\(pings.count == 1 ? "" : "s") ("
            + hosts.map { Perception.escape($0, limit: 80) }.joined(separator: ", ") + ")"
    }

    /// What to try, for a failure or a success that changed nothing.
    public static func hint(_ i: RequestItem) -> String? {
        if let code = i.errorCode {
            switch code {
            case -1004: return "nothing accepted the connection at \(hostPort(i)); is the server running?"
            case -1001: return "the server didn't answer in time"
            case -1003: return "\(hostPort(i)) doesn't resolve; check the URL and the simulator's network"
            case -1009: return "the simulator is offline"
            case -1005: return "the connection dropped mid-request; retry, or check the server"
            case -1206 ... -1200: return "the secure connection failed: a certificate or App Transport Security problem"
            default: return nil
            }
        }
        guard let status = i.status else { return nil }
        switch status {
        case 401, 403: return "the server refused the request (\(status)); the app may be signed out"
        case 404: return "the server has nothing at that path (404); the app may call the wrong URL"
        case 429: return "the server is rate-limiting the app (429)"
        case 500...599:
            return "the server failed (\(status)) and the app shows nothing for it; check the server or the app's "
                + "error handling"
        case 200...299:
            return "the request succeeded but the screen didn't change; the app may not update the screen for this "
                + "response"
        default: return nil
        }
    }

    /// The JSON `requests` entry (spec §3): fields absent when the layer that provides them saw nothing.
    public static func json(_ i: RequestItem) -> JSON {
        var o: [String: JSON] = [
            "host": .string(i.host), "waiting": .bool(i.waiting), "streaming": .bool(i.streaming),
            "telemetry": .bool(i.telemetry),
        ]
        if let v = i.port { o["port"] = JSON(v) }
        if let v = i.path { o["path"] = .string(v) }
        if let v = i.status { o["status"] = JSON(v) }
        if let v = i.errorCode { o["error"] = JSON(v) }
        if let v = i.ms { o["ms"] = JSON(v) }
        if let v = i.serverMs { o["serverMs"] = JSON(v) }
        if let v = i.sent { o["sent"] = JSON(v) }
        if let v = i.received { o["received"] = JSON(v) }
        if let v = i.proto { o["protocol"] = .string(v) }
        if let v = i.bodyBytes { o["body"] = JSON(v) }
        return .object(o)
    }

    static func statusName(_ code: Int) -> String? {
        [
            200: "OK", 201: "Created", 202: "Accepted", 204: "No Content", 301: "Moved Permanently", 302: "Found",
            304: "Not Modified", 400: "Bad Request", 401: "Unauthorized", 403: "Forbidden", 404: "Not Found",
            409: "Conflict", 422: "Unprocessable Content", 429: "Too Many Requests", 500: "Internal Server Error",
            502: "Bad Gateway", 503: "Service Unavailable", 504: "Gateway Timeout",
        ][code]
    }

    static func errorName(_ code: Int) -> String {
        [
            -999: "cancelled", -1001: "timed out", -1003: "host not found", -1004: "could not connect to the server",
            -1005: "connection lost", -1009: "offline", -1011: "bad server response",
            -1200: "secure connection failed", -1202: "untrusted certificate",
        ][code] ?? "network error"
    }

    static func bytes(_ n: Int) -> String {
        if n < 1000 { return "\(n) B" }
        if n < 1_000_000 { return String(format: "%.1f KB", Double(n) / 1000) }
        return String(format: "%.1f MB", Double(n) / 1_000_000)
    }

    static func duration(_ ms: Int) -> String {
        ms < 1000 ? "\(ms) ms" : String(format: "%.1f s", Double(ms) / 1000)
    }
}
```

- [ ] **Step 4: Run the tests**

Run: `scripts/format.sh && swift test --filter RequestTextTests 2>&1 | tail -2`
Expected: `Test run with 9 tests in 1 suite passed`.

- [ ] **Step 5: Commit**

```bash
git add Sources/ChauffeurCore/Network/RequestText.swift Tests/ChauffeurCoreTests/RequestTextTests.swift
git commit -m "Requests in words: status and error names, server time, bytes, body, hints"
```

---

### Task 7: PENDING in the report, and the request window

Spec §3 (result rules, exit 6), §2 ("Delayed requests"), Decision (20 ms grace).

**Files:**
- Create: `Sources/ChauffeurCore/Network/NetJudge.swift`, `Tests/ChauffeurCoreTests/NetJudgeTests.swift`,
  `Tests/ChauffeurCoreTests/ReportNetworkTests.swift`
- Modify: `Sources/ChauffeurCore/Verifier.swift` (`Outcome`, `Verifier.hints`, `ActionReport`, `TypeReport`)

**Interfaces:**
- Consumes: `RequestItem`, `NetVerdict`, `RequestEvidence.verdict` (Task 5), `RequestText` (Task 6), `SettleClock`.
- Produces: `Outcome.pending`; `ActionReport.requests: [RequestItem]`, `.requestElapsedMs: Int`,
  `.copiedCharacters: Int?`, `.networkNote: String?`, `ActionReport.lead(_:pending:) -> RequestItem?`, exit 6 for
  `.pending`, JSON outcome `pending` and a `requests` array; `TypeReport.requests`, `.requestElapsedMs`;
  `NetJudge.graceMs` (20), `.requestWindowMs` (2000), `.textFieldWindowMs` (500), `.confirmMs` (300),
  `NetJudge.judge(clock:extraWindowMs:sample:) -> NetVerdict`.

- [ ] **Step 1: Write the failing tests**

`Tests/ChauffeurCoreTests/NetJudgeTests.swift` (uses `FakeClock` from `SettleTests.swift`):

```swift
import Testing

@testable import ChauffeurCore

/// M4b spec §3: the request window only runs while the app waits for a reply.
@Suite struct NetJudgeTests {
    let open = RequestItem(host: "api.example.com", port: 443, path: "/login", waiting: true)
    let done = RequestItem(host: "api.example.com", port: 443, path: "/login", status: 200)

    @Test func aTrueNoOpIsNotDelayed() {
        let clock = FakeClock()
        #expect(NetJudge.judge(clock: clock) { [] } == .none([]))
        #expect(clock.now == NetJudge.graceMs)
    }

    @Test func telemetryOnlyIsNoEffect() {
        let clock = FakeClock()
        let ping = RequestItem(host: "app-measurement.com", waiting: true, telemetry: true)
        #expect(NetJudge.judge(clock: clock) { [ping] } == .none([ping]))
        #expect(clock.now == NetJudge.graceMs)
    }

    @Test func aReplyWithinTheWindowSettles() {
        let clock = FakeClock()
        let verdict = NetJudge.judge(clock: clock) { clock.now < 300 ? [open] : [done] }
        #expect(verdict == .settled([done]))
        #expect(clock.now < 300 + NetJudge.confirmMs + 200)
    }

    @Test func noReplyWithinTheWindowIsPending() {
        let clock = FakeClock()
        #expect(NetJudge.judge(clock: clock) { [open] } == .pending([open]))
        #expect(clock.now == NetJudge.graceMs + NetJudge.requestWindowMs)
    }

    @Test func aRequestChainedOnTheReplyIsWaitedFor() {
        let clock = FakeClock()
        let next = RequestItem(host: "api.example.com", port: 443, path: "/profile", waiting: true)
        // /login answers at once; its reply starts /profile, which never answers.
        let verdict = NetJudge.judge(clock: clock) { clock.now < 100 ? [done] : [done, next] }
        #expect(verdict == .pending([done, next]))
    }

    @Test func aDebouncedRequestIsCaughtOnlyWithTheTextFieldWindow() {
        let late = FakeClock()
        #expect(NetJudge.judge(clock: late, extraWindowMs: NetJudge.textFieldWindowMs) {
            late.now < 320 ? [] : [open]
        } == .pending([open]))
        let plain = FakeClock()
        #expect(NetJudge.judge(clock: plain) { plain.now < 320 ? [] : [open] } == .none([]))
    }
}
```

`Tests/ChauffeurCoreTests/ReportNetworkTests.swift`:

```swift
import Testing

@testable import ChauffeurCore

/// M4b spec §3: the result rules as text, JSON and exit codes.
@Suite struct ReportNetworkTests {
    func report(_ outcome: Outcome, requests: [RequestItem], diff: [String] = [], hints: [String] = []) -> ActionReport {
        var r = ActionReport(
            action: "tap e4 \"Login\"", outcome: outcome, evidence: .app("dev.chauffeur.fixture"), settledMs: 420,
            settled: true, revBefore: 7, revAfter: outcome == .changed ? 8 : 7, diff: diff, transport: "digitizer",
            retriedFrom: nil, hints: hints, capMs: 1500)
        r.requests = requests
        r.requestElapsedMs = 2200
        return r
    }
    let fail = RequestItem(
        host: "localhost", port: 8765, path: "/fail", status: 500, ms: 481, serverMs: 1, sent: 206, received: 113,
        proto: "http/1.1", bodyBytes: 0)
    let ping = RequestItem(host: "app-measurement.com", port: 443, path: "/a", status: 204, telemetry: true)
    let open = RequestItem(host: "api.example.com", port: 443, path: "/login", waiting: true)

    @Test func pending() {
        let r = report(.pending, requests: [open], hints: Verifier.hints(outcome: .pending, target: nil))
        #expect(
            r.render() == """
                tap e4 "Login" → PENDING · api.example.com/login still running after 2.2 s
                hint: run `chauffeur wait` for the result
                """)
        #expect(r.exitCode == 6)
        #expect(r.json["outcome"]?.string == "pending")
        #expect(r.json["requests"]?.array?.first?["waiting"]?.bool == true)
    }

    @Test func aFailureLeadsTheNoEffect() {
        let r = report(.noEffect, requests: [ping, fail], hints: [RequestText.hint(fail) ?? ""])
        #expect(
            r.render() == """
                tap e4 "Login" → NO EFFECT · localhost:8765/fail → 500 Internal Server Error in 481 ms (server 1 ms)
                request: sent 206 B, got 113 B · http/1.1
                telemetry: 1 request (app-measurement.com)
                hint: the server failed (500) and the app shows nothing for it; check the server or the app's error handling
                """)
        #expect(r.exitCode == 3)
    }

    @Test func aSuccessThatChangedNothing() {
        var ok = fail
        ok.status = 200
        #expect(
            report(.noEffect, requests: [ok]).render().hasPrefix(
                "tap e4 \"Login\" → NO EFFECT · localhost:8765/fail → 200 OK in 481 ms (server 1 ms), but nothing changed on screen"
            ))
    }

    @Test func aChangeListsItsRequests() {
        var created = fail
        created.status = 201
        let r = report(.changed, requests: [created], diff: ["+ text \"Welcome\""])
        #expect(
            r.render() == """
                tap e4 "Login" → changed · settled 420ms · rev 7→8
                + text "Welcome"
                request: localhost:8765/fail → 201 Created in 481 ms (server 1 ms) · sent 206 B, got 113 B · http/1.1
                """)
    }

    @Test func aCopyIsAChange() {
        var r = report(.changed, requests: [])
        r.copiedCharacters = 24
        #expect(r.render() == "tap e4 \"Login\" → changed · copied to clipboard (24 characters)")
        #expect(r.json["copied"]?.int == 24 && r.exitCode == 0)
    }

    @Test func anUnwatchedNetworkIsSaid() {
        var r = report(.noEffect, requests: [])
        r.networkNote = "no app process to watch"
        #expect(r.render().hasSuffix("\nnote: network not watched (no app process to watch)"))
    }

    @Test func plainNoEffectIsUnchanged() {
        #expect(
            report(.noEffect, requests: []).render()
                == "tap e4 \"Login\" → NO EFFECT · the accessibility tree did not change in 1.5s (touch reached dev.chauffeur.fixture)"
        )
    }
}
```

- [ ] **Step 2: Run them to verify they fail**

Run: `swift test --filter "NetJudgeTests|ReportNetworkTests" 2>&1 | grep -E "error:" | head -4`
Expected: `cannot find 'NetJudge' in scope`, `type 'Outcome' has no member 'pending'`, `value of type 'ActionReport'
has no member 'requests'`.

- [ ] **Step 3: Write `NetJudge`**

`Sources/ChauffeurCore/Network/NetJudge.swift`:

```swift
import Foundation

/// The network half of a tap's verdict, once the screen has settled (M4b spec §3, Findings §6).
public enum NetJudge {
    /// Log lines arrive 0–10 ms after the event (Findings §6): the most a dead tap pays.
    public static let graceMs = 20
    /// How long a missing reply is waited for before the tap is PENDING.
    public static let requestWindowMs = 2000
    /// A debounced request (search as you type) starts after the screen settled (spec §2, "Delayed requests").
    public static let textFieldWindowMs = 500
    /// After every reply arrived, one more look: a stream shows itself by still receiving, and a reply may start the
    /// next request of a chain.
    public static let confirmMs = 300
    static let pollMs = 100

    /// `sample` reads both layers afresh and merges them. Nothing the tap caused → `.none` after the grace, with no
    /// window and no second look.
    public static func judge(
        clock: some SettleClock, extraWindowMs: Int = 0, sample: () -> [RequestItem]
    ) -> NetVerdict {
        clock.sleep(ms: graceMs)
        var verdict = RequestEvidence.verdict(sample())
        let lateUntil = clock.nowMs() + extraWindowMs
        while case .none = verdict, clock.nowMs() < lateUntil {
            clock.sleep(ms: pollMs)
            verdict = RequestEvidence.verdict(sample())
        }
        var deadline = clock.nowMs() + requestWindowMs
        var confirmed = false
        while true {
            switch verdict {
            case .pending where clock.nowMs() < deadline:
                clock.sleep(ms: pollMs)
                verdict = RequestEvidence.verdict(sample())
            case .settled where !confirmed:
                confirmed = true
                clock.sleep(ms: confirmMs)
                verdict = RequestEvidence.verdict(sample())
                if case .pending = verdict { deadline = clock.nowMs() + requestWindowMs }
            default:
                return verdict
            }
        }
    }
}
```

- [ ] **Step 4: Teach the report about PENDING, requests and copies**

In `Sources/ChauffeurCore/Verifier.swift`:

1. In `enum Outcome`, after `case unattributed`'s comment and case, add:

```swift
    /// The screen didn't change and the app is still waiting for a network reply (M4b spec §3): exit 6.
    case pending
```

2. In `Verifier.hints(outcome:target:)`, before `case .changed, .retry:` add:

```swift
        case .pending:
            return ["run `chauffeur wait` for the result"]
```

3. In `struct ActionReport`, after `public var evidenceShot: String?`, add:

```swift
    /// The requests and connections the action caused, telemetry included and marked (M4b spec §3).
    public var requests: [RequestItem] = []
    /// From the touch to the verdict: how long a missing reply has been waited for.
    public var requestElapsedMs = 0
    /// Characters the action copied to the clipboard (M4b spec §7).
    public var copiedCharacters: Int?
    /// Why the network couldn't be watched; shown with a NO EFFECT.
    public var networkNote: String?
```

4. Replace `public var exitCode: Int32 { outcome == .changed ? 0 : 3 }` with:

```swift
    public var exitCode: Int32 {
        switch outcome {
        case .changed: return 0
        case .pending: return 6
        default: return 3
        }
    }

    /// The request a NO EFFECT or PENDING headline names: the first missing reply, else the first failure, else the
    /// first request that isn't a stream, else the stream. Never telemetry.
    static func lead(_ requests: [RequestItem], pending: Bool) -> RequestItem? {
        let real = requests.filter { !$0.telemetry }
        if pending { return real.first(where: \.waiting) }
        return real.first(where: \.failed) ?? real.first(where: { !$0.streaming }) ?? real.first
    }
```

5. Replace the whole `public func render() -> String` with:

```swift
    public func render() -> String {
        let cap = String(format: "%gs", Double(capMs) / 1000)
        let lead = outcome == .changed ? nil : Self.lead(requests, pending: outcome == .pending)
        var head: String
        switch outcome {
        case .changed:
            if let copiedCharacters, diff.isEmpty {
                head = "\(action) → changed · copied to clipboard (\(copiedCharacters) characters)"
            } else {
                head =
                    "\(action) → changed · " + (settled ? "settled \(settledMs)ms" : "still changing at \(cap)")
                    + " · rev \(revBefore)→\(revAfter)"
                if let from = retriedFrom { head += " · via \(transport) after \(from) showed no touch" }
            }
        case .pending:
            head =
                "\(action) → PENDING · "
                + (lead.map { RequestText.outcome($0, elapsedMs: requestElapsedMs) } ?? "waiting for a reply")
        case .noEffect:
            if let lead {
                head =
                    "\(action) → NO EFFECT · " + RequestText.outcome(lead, elapsedMs: requestElapsedMs)
                    + (lead.failed || lead.streaming ? "" : ", but nothing changed on screen")
            } else {
                head =
                    "\(action) → NO EFFECT · the accessibility tree did not change in \(cap) (touch reached \(owner))"
            }
        case .intercepted(let by):
            head = "\(action) → INTERCEPTED by \(by) · nothing changed"
        case .notDelivered, .retry:
            head =
                "\(action) → NOT DELIVERED · " + (retriedFrom != nil ? "retried via \(transport) · " : "")
                + "still no touch"
        case .unverified:
            head = "\(action) → UNVERIFIED: no visible change (\(note ?? "touch log unavailable"))"
        case .unattributed:
            head =
                "\(action) → UNVERIFIED: the screen was already changing before the action, so the change can't be credited to it"
        }
        var requestLines: [String] = []
        if let lead {
            let more = RequestText.details(lead)
            if !more.isEmpty { requestLines.append("request: " + more) }
        }
        requestLines += RequestText.lines(requests, elapsedMs: requestElapsedMs, except: lead)
        var tail = hints.map { "hint: " + $0 }
        if outcome == .noEffect, let shot = evidenceShot {
            tail.insert(
                "screen: \(shot) (look before retrying: some changes, like checkmarks, never reach the tree)", at: 0)
        }
        if outcome == .noEffect, let networkNote { tail.append("note: network not watched (\(networkNote))") }
        return ([head] + diff + requestLines + tail).joined(separator: "\n")
    }
```

6. In `public var json: JSON`, before `return .object(o)`, add:

```swift
        if !requests.isEmpty { o["requests"] = .array(requests.map(RequestText.json)) }
        if let copiedCharacters { o["copied"] = JSON(copiedCharacters) }
```

7. In `var outcomeName`, add `case .pending: "pending"`.

8. In `struct TypeReport`, after `public var settledMs: Int`, add:

```swift
    /// Requests the typing started by the time it was verified (M4b spec §2).
    public var requests: [RequestItem] = []
    public var requestElapsedMs = 0
```

and in `TypeReport.render()`, change the `.ok` case to:

```swift
        case .ok:
            return ([
                "\(action) → typed via \(method) · value=\(Perception.quote(value ?? "")) · settled \(settledMs)ms"
            ] + RequestText.lines(requests, elapsedMs: requestElapsedMs)).joined(separator: "\n")
```

and in `TypeReport.json`, before `return .object(o)`:

```swift
        if !requests.isEmpty { o["requests"] = .array(requests.map(RequestText.json)) }
```

- [ ] **Step 5: Run the tests**

Run: `scripts/format.sh && swift test --filter "NetJudgeTests|ReportNetworkTests|VerifierTests" 2>&1 | tail -2`
Expected: all pass (`VerifierTests` unchanged: a report without requests renders as before).

- [ ] **Step 6: Commit**

```bash
git add Sources/ChauffeurCore/Network/NetJudge.swift Sources/ChauffeurCore/Verifier.swift \
  Tests/ChauffeurCoreTests/NetJudgeTests.swift Tests/ChauffeurCoreTests/ReportNetworkTests.swift
git commit -m "PENDING (exit 6), request lines in results, and the request window"
```

---

### Task 8: Judge every tap on the network

Spec §2 ("What belongs to the tap", "Before judging no change", "When the app isn't watched"), §3.

**Files:**
- Create: `Sources/ChauffeurCore/Engine/Session+Wait.swift`, `Sources/ChauffeurCore/Engine/Session+Network.swift`,
  `Tests/ChauffeurCoreTests/SessionNetworkTests.swift`
- Modify: `Sources/ChauffeurCore/Engine/Session.swift` (move `wait` out; stored properties; clear the pending tap),
  `Sources/ChauffeurCore/Engine/Session+Act.swift` (`act`, `tapCommand`, `typeCommand`),
  `Sources/ChauffeurCore/Engine/Session+Logs.swift` (`annotate`)

**Interfaces:**
- Consumes: Tasks 2–7; `logTap`, `app`, `ax`, `clock`, `resolvePath`, `Target.telemetryHosts(from:)`.
- Produces: `NetStart` (`pids`, `earlier`), `TapNet` (`pids`, `earlier`, `atTouch`, `logCursor`, `touchMs`),
  `PendingTap` (`report`, `before`, `net`, `target`); `Session.flowSource: FlowSource?`, `.flowSourceTried`,
  `.pendingTap`, `.telemetryOverride`; `Session.watchedPids()`, `.flows(_:)`, `.netStart()`, `.tapNet(_:)`,
  `.netItems(_:previous:)`, `.telemetryHosts()`, `.applyNetwork(_:net:target:)`; `act(…, network: NetStart?)`.

- [ ] **Step 1: Move `wait` out of `Session.swift`**

Create `Sources/ChauffeurCore/Engine/Session+Wait.swift` containing `import Foundation`, then `extension Session {`,
then — moved verbatim from `Session.swift` — the `maxWaitSeconds` comment and constant, `waitTimeout(_:)` and
`waitCommand(_:)`, then `}`. Delete them from `Session.swift`.

Run: `scripts/format.sh && swift build 2>&1 | tail -1 && wc -l Sources/ChauffeurCore/Engine/Session.swift`
Expected: `Build complete!`; `Session.swift` about 340 lines.

Commit: `git add -A Sources/ChauffeurCore/Engine && git commit -m "Move wait into its own file (no behavior change)"`

- [ ] **Step 2: Write the failing tests**

`Tests/ChauffeurCoreTests/SessionNetworkTests.swift`:

```swift
import Foundation
import Testing

@testable import ChauffeurCore

@MainActor
final class ScriptedFlows: FlowSource {
    var samples: [[Flow]]
    init(_ samples: [[Flow]]) { self.samples = samples }
    func flows(pids: [Int32]) -> [Flow] { samples.count > 1 ? samples.removeFirst() : samples.first ?? [] }
}

/// M4b spec §3 through the session's glue, with recorded log lines and scripted connections.
@Suite @MainActor struct SessionNetworkTests {
    func session(flows: [[Flow]] = [[]]) -> Session {
        let s = Session(udid: "ZZ" + String(format: "%06X", UInt32.random(in: 0...0xFFFFFF)) + "-TEST")
        s.flowSource = ScriptedFlows(flows)
        s.flowSourceTried = true
        s.telemetryOverride = []
        return s
    }

    func report(_ outcome: Outcome) -> ActionReport {
        ActionReport(
            action: "tap e4 \"Login\"", outcome: outcome, evidence: .app("dev.chauffeur.fixture"), settledMs: 400,
            settled: true, revBefore: 3, revAfter: outcome == .changed ? 4 : 3, diff: [], transport: "digitizer",
            retriedFrom: nil, hints: Verifier.hints(outcome: outcome, target: nil), capMs: 1500)
    }

    /// The touch, then `task`'s recorded lines arriving in the log.
    func tap(_ s: Session, task: String) throws -> TapNet {
        let net = TapNet(pids: [4321], earlier: [], atTouch: [], logCursor: s.logTap.cursor, touchMs: s.clock.nowMs())
        let lines = try Fixtures.network("ios27-requests")
        let url = lines.first { $0.message.contains(task) && $0.message.contains("setting up Connection") }
        let connection = url.map { line in line.message.split(separator: " ").last.map { "[C\($0) " } ?? "" } ?? ""
        for line in lines where line.message.contains(task) || (!connection.isEmpty && line.message.hasPrefix(connection)) {
            s.logTap.append(line)
        }
        return net
    }

    @Test func aFailedRequestLeadsTheNoEffect() throws {
        let s = session()
        var r = report(.noEffect)
        s.applyNetwork(&r, net: try tap(s, task: "A450514C"), target: nil)
        #expect(r.outcome == .noEffect)
        #expect(r.render().hasPrefix("tap e4 \"Login\" → NO EFFECT · localhost:8765/fail → 500 Internal Server Error"))
        #expect(r.hints == [RequestText.hint(r.requests[0]) ?? ""])
    }

    @Test func aChangeGetsItsRequestLines() throws {
        let s = session()
        var r = report(.changed)
        s.applyNetwork(&r, net: try tap(s, task: "F8F70ACA"), target: nil)
        #expect(r.outcome == .changed && r.requests.map(\.status) == [201])
    }

    @Test func telemetryOnlyStaysNoEffect() throws {
        let s = session()
        s.telemetryOverride = ["localhost"]
        var r = report(.noEffect)
        s.applyNetwork(&r, net: try tap(s, task: "A450514C"), target: nil)
        #expect(r.outcome == .noEffect && r.requests.allSatisfy(\.telemetry))
        #expect(r.render().contains("\ntelemetry: 1 request (localhost)"))
        #expect(r.hints == Verifier.hints(outcome: .noEffect, target: nil))
    }

    @Test func aDeadTapStaysPlain() {
        let s = session()
        var r = report(.noEffect)
        let net = TapNet(pids: [4321], earlier: [], atTouch: [], logCursor: s.logTap.cursor, touchMs: s.clock.nowMs())
        let started = s.clock.nowMs()
        s.applyNetwork(&r, net: net, target: nil)
        #expect(r.outcome == .noEffect && r.requests.isEmpty)
        #expect(s.clock.nowMs() - started < 200)
    }

    @Test func noProcessMeansNotWatched() {
        let s = session()
        var r = report(.noEffect)
        s.applyNetwork(&r, net: TapNet(pids: [], earlier: [], atTouch: [], logCursor: 0, touchMs: 0), target: nil)
        #expect(r.networkNote == "no app process to watch")
    }

    @Test func aRawSocketWaitingIsPending() {
        let waiting = Flow(id: 1, pid: 4321, process: "Fixture", proto: "tcp", remote: "127.0.0.1:8765", tx: 58,
            rx: 0, openedMs: 1, closedMs: nil)
        let s = session(flows: [[waiting]])
        var r = report(.noEffect)
        let net = TapNet(pids: [4321], earlier: [], atTouch: [], logCursor: s.logTap.cursor, touchMs: s.clock.nowMs())
        s.applyNetwork(&r, net: net, target: nil)
        #expect(r.outcome == .pending && r.exitCode == 6)
        #expect(r.render().hasPrefix("tap e4 \"Login\" → PENDING · 127.0.0.1:8765 · sent 58 B, no reply after 2."))
    }

    @Test func requestLinesReplaceCFNetworkErrorLinesInLogs() throws {
        let s = session()
        let cursor = s.logTap.cursor
        s.logTap.append(LogLine(time: "t", level: "error", message: "login failed: invalid token"))
        s.logTap.append(
            LogLine(time: "t", level: "error", message: "Task <AB>.<1> HTTP load failed, 0/0 bytes (error code: -1004 [1:61])",
                sender: "CFNetwork"))
        let withRequests = s.annotate(Output("tap e4", data: ["requests": []]), since: cursor, logs: true)
        #expect(withRequests.text == "tap e4\nlogs: [error] \"login failed: invalid token\"")
        let without = s.annotate(Output("tap e4"), since: cursor, logs: true)
        #expect(without.text.contains("(CFNetwork)"))
    }
}
```

The `aRawSocketWaitingIsPending` test runs the real 2 s window on the system clock; it is the only slow unit test.

- [ ] **Step 3: Run them to verify they fail**

Run: `swift test --filter SessionNetworkTests 2>&1 | grep -E "error:" | head -4`
Expected: `cannot find 'TapNet' in scope`, `value of type 'Session' has no member 'flowSource'`.

- [ ] **Step 4: Session state**

In `Sources/ChauffeurCore/Engine/Session.swift`, after `var relaunch: ((String) -> Output)?`, add:

```swift
    /// The activity layer (M4b spec §2), built on the first tap; nil when NetworkStatistics is unavailable.
    var flowSource: FlowSource?
    var flowSourceTried = false
    /// The last tap that came back PENDING, for a bare `wait` (M4b spec §9). Any other action forgets it.
    var pendingTap: PendingTap?
    /// Test seam: the project's telemetry entries (default: `.chauffeur.json` from the client's directory).
    var telemetryOverride: [String]?
```

In `runOne`, after `if Self.logged.contains(command) { lastActionLogCursor = cursor }`, add:

```swift
        if Self.logged.contains(command) { pendingTap = nil }
```

- [ ] **Step 5: The glue**

`Sources/ChauffeurCore/Engine/Session+Network.swift`:

```swift
import Foundation

/// A tap's first network sample, taken before the baseline: a connection already moving bytes then isn't the tap's.
struct NetStart {
    var pids: [Int32]
    var earlier: [Flow]
}

/// A tap's network state at the touch: enough to judge it now and again from a bare `wait`.
struct TapNet {
    var pids: [Int32]
    var earlier: [Flow]
    var atTouch: [Flow]
    var logCursor: Int
    var touchMs: Int
}

/// A tap that came back PENDING (M4b spec §9).
struct PendingTap {
    var report: ActionReport
    var before: Snapshot
    var net: TapNet
    var target: Node?
}

extension Session {
    /// The processes whose traffic is the app's: the launched app (else the app in front) and the simulator's WebKit
    /// networking process, its sibling under the device's launchd_sim, for web views (Findings §2).
    func watchedPids() -> [Int32] {
        guard let pid = app?.pid ?? ax?.frontmostPID() else { return [] }
        let webKit = Proc.parent(pid).map { Proc.children(of: $0, named: "com.apple.WebKit.Networking") } ?? []
        return [pid] + webKit
    }

    func flows(_ pids: [Int32]) -> [Flow] {
        if flowSource == nil, !flowSourceTried {
            flowSourceTried = true
            flowSource = try? NetStatsSource()
        }
        guard let flowSource, !pids.isEmpty else { return [] }
        return flowSource.flows(pids: pids)
    }

    func netStart() -> NetStart {
        let pids = watchedPids()
        return NetStart(pids: pids, earlier: flows(pids))
    }

    /// Right before the touch.
    func tapNet(_ start: NetStart) -> TapNet {
        TapNet(
            pids: start.pids, earlier: start.earlier, atTouch: flows(start.pids), logCursor: logTap.cursor,
            touchMs: clock.nowMs())
    }

    func telemetryHosts() -> [String] { telemetryOverride ?? Target.telemetryHosts(from: resolvePath(".")) }

    /// Both layers now, merged. `previous` is the last sample's activity, to tell a stream from a reply.
    func netItems(_ net: TapNet, previous: inout [FlowActivity]) -> [RequestItem] {
        let activity = ConnectionWatch.activity(earlier: net.earlier, atTouch: net.atTouch, now: flows(net.pids))
        let streaming = ConnectionWatch.streaming(previous: previous, now: activity)
        previous = activity
        return RequestEvidence.merge(
            records: RequestLog.parse(logTap.since(net.logCursor)), activity: activity, streaming: streaming,
            telemetryExtra: telemetryHosts())
    }

    /// Spec §3: a NO EFFECT may become PENDING or carry the reply that explains it; a change gets its request lines.
    /// Other outcomes (delivery problems) are left alone.
    func applyNetwork(_ report: inout ActionReport, net: TapNet, target: Node?) {
        guard report.outcome == .noEffect || report.outcome == .changed else { return }
        if report.outcome == .noEffect, net.pids.isEmpty || flowSource == nil {
            report.networkNote = net.pids.isEmpty ? "no app process to watch" : "network statistics unavailable"
        }
        var previous: [FlowActivity] = []
        let verdict: NetVerdict
        if report.outcome == .changed {
            clock.sleep(ms: NetJudge.graceMs)
            verdict = RequestEvidence.verdict(netItems(net, previous: &previous))
        } else {
            let textField = target.map { Perception.textEntry.contains($0.role) } ?? false
            verdict = NetJudge.judge(clock: clock, extraWindowMs: textField ? NetJudge.textFieldWindowMs : 0) {
                netItems(net, previous: &previous)
            }
        }
        report.requests = verdict.items
        report.requestElapsedMs = clock.nowMs() - net.touchMs
        guard report.outcome == .noEffect else { return }
        switch verdict {
        case .none:
            break
        case .pending:
            report.outcome = .pending
            report.hints = Verifier.hints(outcome: .pending, target: target)
        case .settled(let items):
            if let hint = ActionReport.lead(items, pending: false).flatMap(RequestText.hint) { report.hints = [hint] }
        }
    }
}
```

- [ ] **Step 6: Wire it into `act`, `tap` and `type`**

In `Sources/ChauffeurCore/Engine/Session+Act.swift`:

1. `act`'s signature gains a last parameter before `gesture`: `network: NetStart? = nil,`.
2. In its loop, replace `let sent = gesture(transport)` with:

```swift
            let net = network.map { tapNet($0) }
            let sent = gesture(transport)
```

3. Replace the block from `if outcome == .noEffect, let frame = target?.frame,` to the end of that `if` with:

```swift
            if let net {
                applyNetwork(&report, net: net, target: target)
                if report.outcome == .pending {
                    pendingTap = PendingTap(report: report, before: before, net: net, target: target)
                }
            }
            if report.outcome == .noEffect, let frame = target?.frame,
                let shot = try? capture(
                    screen: before.size, zoom: Verifier.evidenceRegion(target: frame, screen: before.size))
            {
                report.evidenceShot = shot.path
            }
```

4. In `tapCommand`, replace `let (device, _) = try connect()` / `let (before, settled) = try baseline()` with:

```swift
        let (device, _) = try connect()
        let network = netStart()
        let (before, settled) = try baseline()
```

and pass `network: network` to both `act(...)` calls in `tapCommand` (the first tap and the switch's second tap;
for the second, pass `network: netStart()`).

5. In `typeCommand`, after `let (device, _) = try connect()`, add `let network = netStart()`. Before the line
`if Keys.typeable(text) && text.count <= 15 {`, add `let typingNet = tapNet(network)`. Replace
`let report = TypeReport(` … `settledMs: settle.elapsedMs)` with:

```swift
        var report = TypeReport(
            action: label, method: method, verdict: verdict, value: now?.value, settledMs: settle.elapsedMs)
        if verdict == .ok {
            // One look, no window: typing is verified by the field, so a late request can't make it a false NO EFFECT.
            clock.sleep(ms: NetJudge.graceMs)
            var previous: [FlowActivity] = []
            report.requests = netItems(typingNet, previous: &previous)
            report.requestElapsedMs = clock.nowMs() - typingNet.touchMs
        }
```

**Ruling recorded in the plan:** spec §2 gives "the tapped or typed-into" text field a 500 ms extra window. A `type`
result is verified by the field's value, never NO EFFECT from the network, so it takes one sample and no window (500
ms on every `type` would buy nothing); a tap on a text field gets the window. Cost if wrong: a debounced request is
missing from `type`'s lines; `wait` still names it.

6. In `Sources/ChauffeurCore/Engine/Session+Logs.swift` `annotate`, replace
`let errors = logTap.since(from).filter(\.isError)` with:

```swift
            // CFNetwork's lines about a request the result already shows add nothing but noise (spec §3).
            let shown = out.data?["requests"] != nil
            let errors = logTap.since(from).filter {
                $0.isError && !(shown && $0.sender == "CFNetwork" && $0.message.hasPrefix("Task <"))
            }
```

- [ ] **Step 7: Run the tests and the line counts**

Run: `scripts/format.sh && swift test --filter "SessionNetworkTests|AnnotateTests|RecoverTests" 2>&1 | tail -2 && wc -l Sources/ChauffeurCore/Engine/Session*.swift`
Expected: all pass; every file under 400 lines.

- [ ] **Step 8: Commit**

```bash
git add Sources/ChauffeurCore/Engine Sources/ChauffeurCore/Verifier.swift \
  Tests/ChauffeurCoreTests/SessionNetworkTests.swift
git commit -m "Taps are judged on the network too: PENDING, the reply that explains a NO EFFECT, request lines"
```

---

### Task 9: `wait`, batches and the MCP `wait` action

Spec §9, §3 ("Batches").

**Files:**
- Modify: `Sources/ChauffeurCore/Engine/Session+Wait.swift`, `Sources/ChauffeurCore/Engine/Session+Batch.swift`,
  `Sources/ChauffeurCore/Agent/MCPTools.swift`
- Test: `Tests/ChauffeurCoreTests/WaitTests.swift`, `Tests/ChauffeurCoreTests/MCPTests.swift`

**Interfaces:**
- Consumes: `pendingTap`, `netItems`, `RequestEvidence.verdict`, `ActionReport.lead`, `RequestText` (Tasks 5–8).
- Produces: bare `chauffeur wait [--timeout <s>]` (default 30 s, max 300); `Session.finishPending(timeoutMs:)`;
  `Session.stillWaiting() -> String?`; `Session.throughPending(_:wait:) -> Output`; MCP `act` action `wait`.

- [ ] **Step 1: Write the failing tests**

`Tests/ChauffeurCoreTests/WaitTests.swift`:

```swift
import Testing

@testable import ChauffeurCore

/// M4b spec §9 and §3 ("Batches").
@Suite @MainActor struct WaitTests {
    func session() -> Session { Session(udid: "ZZ" + String(format: "%06X", UInt32.random(in: 0...0xFFFFFF)) + "-TEST") }

    @Test func aBareWaitWithNothingPendingSaysSo() {
        let out = session().run(["wait"])
        #expect(out.exit == 1)
        #expect(out.text.hasPrefix("nothing to wait for: no tap came back PENDING"))
    }

    @Test func goneNeedsAQuery() {
        #expect(session().run(["wait", "--gone"]).exit == 64)
    }

    @Test func aPendingStepIsFinishedBeforeTheBatchJudgesIt() {
        let pending = Output("tap e4 → PENDING · a still running after 2.1 s", exit: 6)
        let out = Session.throughPending(pending) { Output("tap e4 → changed · settled 300ms · rev 3→4") }
        #expect(out.exit == 0)
        #expect(out.text == "tap e4 → PENDING · a still running after 2.1 s\ntap e4 → changed · settled 300ms · rev 3→4")
        let plain = Output("tap e5 → changed")
        #expect(Session.throughPending(plain) { Output("never", exit: 1) } == plain)
    }

    @Test func aBareWaitHasALongerDefault() {
        #expect(Session.pendingWaitSeconds == 30)
    }
}
```

In `Tests/ChauffeurCoreTests/MCPTests.swift`, add inside the suite (next to the test containing
`"wait", "--gone", "--timeout", "2.5", "--", "Done"`; copy its way of calling `MCPTools.argv`):

```swift
    @Test func actWaitFinishesAPendingTap() throws {
        #expect(
            try MCPTools.argv(tool: "act", arguments: ["action": "wait"], payloadFile: { _ in "" }) == ["wait"])
        #expect(
            try MCPTools.argv(tool: "act", arguments: ["action": "wait", "timeout": 45], payloadFile: { _ in "" })
                == ["wait", "--timeout", "45"])
    }
```

- [ ] **Step 2: Run them to verify they fail**

Run: `swift test --filter "WaitTests|MCPTests" 2>&1 | grep -E "error:|failed" | head -5`
Expected: `type 'Session' has no member 'throughPending'` / `pendingWaitSeconds`.

- [ ] **Step 3: Bare `wait` and what is still waiting**

In `Sources/ChauffeurCore/Engine/Session+Wait.swift`:

1. After `waitTimeout(_:)`, add:

```swift
    /// A bare `wait` finishes the last PENDING tap; slow backends take longer than a screen does (M4b spec §9).
    nonisolated static let pendingWaitSeconds = 30.0
```

2. In `waitCommand`, change the usage string to
`"usage: chauffeur wait [\"<query>\"] [--gone] [--timeout <s>]"`, replace
`let timeout = Self.waitTimeout(try a.number("--timeout", in: 0...86_400))` and
`guard let query = a.text() else { throw ChauffeurError.usage(a.usage) }` with:

```swift
        let seconds = try a.number("--timeout", in: 0...86_400)
        guard let query = a.text() else {
            if gone { throw ChauffeurError.usage(a.usage) }
            return try finishPending(timeoutMs: Int(min(seconds ?? Self.pendingWaitSeconds, Self.maxWaitSeconds) * 1000))
        }
        let timeout = Self.waitTimeout(seconds)
```

and in its timeout `return Output(`, change the text expression to append `+ (stillWaiting().map { "\nstill waiting: " + $0 } ?? "")`
after `+ "\nscreen: " + lastHeader`.

3. Add to the extension:

```swift
    /// Waits for the PENDING tap's replies, then judges the tap again with the screen as it is now (spec §9).
    func finishPending(timeoutMs: Int) throws -> Output {
        guard let pending = pendingTap else {
            return Output(
                "nothing to wait for: no tap came back PENDING since the last action. To wait for something on the "
                    + "screen: chauffeur wait \"<text>\"", exit: 1)
        }
        let start = clock.nowMs()
        var previous: [FlowActivity] = []
        var verdict = RequestEvidence.verdict(netItems(pending.net, previous: &previous))
        while case .pending = verdict, clock.nowMs() - start < timeoutMs {
            clock.sleep(ms: 200)
            verdict = RequestEvidence.verdict(netItems(pending.net, previous: &previous))
        }
        let (after, settle) = try observe(minMs: 150, capMs: 1500)
        var report = pending.report
        report.requests = verdict.items
        report.requestElapsedMs = clock.nowMs() - pending.net.touchMs
        report.evidenceShot = nil
        if after.hash != pending.before.hash {
            report.outcome = .changed
            report.revAfter = after.rev
            report.diff = Diff.lines(from: pending.before, to: after)
            report.settledMs = settle.elapsedMs
            report.settled = settle.settled
            report.hints = []
        } else if case .pending = verdict {
            report.outcome = .pending
            report.hints = Verifier.hints(outcome: .pending, target: pending.target)
        } else {
            report.outcome = .noEffect
            report.hints =
                ActionReport.lead(verdict.items, pending: false).flatMap(RequestText.hint).map { [$0] }
                ?? Verifier.hints(outcome: .noEffect, target: pending.target)
        }
        if report.outcome == .pending { pendingTap?.report = report } else { pendingTap = nil }
        return Output(report.render(), exit: report.exitCode, data: report.json)
    }

    /// `api.example.com/feed (9.8 s)` for each reply the last action is still waiting for; nil when none is.
    func stillWaiting() -> String? {
        if let pending = pendingTap {
            var previous: [FlowActivity] = []
            let elapsed = RequestText.duration(clock.nowMs() - pending.net.touchMs)
            let open = netItems(pending.net, previous: &previous).filter { $0.waiting && !$0.telemetry }
            return open.isEmpty ? nil : open.map { RequestText.target($0) + " (\(elapsed))" }.joined(separator: ", ")
        }
        let open = RequestLog.parse(logTap.since(lastActionLogCursor)).filter { !$0.finished && $0.host != nil }
        let items = RequestEvidence.merge(records: open, activity: [], streaming: [], telemetryExtra: telemetryHosts())
            .filter { !$0.telemetry }
        return items.isEmpty ? nil : items.map(RequestText.target).joined(separator: ", ")
    }
```

- [ ] **Step 4: Batches go through PENDING**

In `Sources/ChauffeurCore/Engine/Session+Batch.swift`, replace `let out = runOne(command)` with
`let out = Self.throughPending(runOne(command)) { runOne(["wait"]) }`, and add to the extension:

```swift
    /// A step that came back PENDING is finished by a bare `wait` before the batch judges it, so "tap Login, then tap
    /// Profile" works (M4b spec §3, "Batches").
    nonisolated static func throughPending(_ out: Output, wait: () -> Output) -> Output {
        guard out.exit == 6 else { return out }
        let waited = wait()
        return Output(out.text + "\n" + waited.text, exit: waited.exit, data: waited.data)
    }
```

- [ ] **Step 5: The MCP `wait` action**

In `Sources/ChauffeurCore/Agent/MCPTools.swift`:

1. In the `act` tool's `action` enum list, add `"wait"` after `"button"`.
2. Add a property next to `"long"`:
   `"timeout": prop("number", "wait: seconds to wait for a PENDING tap (default 30)", ["minimum": 0, "maximum": 300]),`
3. In `argv(tool:arguments:payloadFile:)`, inside `case "act":`'s `switch action`, add:

```swift
            case "wait":
                argv = ["wait"] + (try a.number("timeout").map { ["--timeout", $0] } ?? [])
```

(`a.number` returns the value formatted by `Geometry.fmt`, so `45` comes back as `"45"`.)

- [ ] **Step 6: Run the tests**

Run: `scripts/format.sh && swift test --filter "WaitTests|MCPTests|BatchTests|ArgsTests|SkillTests" 2>&1 | tail -2`
Expected: all pass.

- [ ] **Step 7: Commit**

```bash
git add Sources/ChauffeurCore/Engine/Session+Wait.swift Sources/ChauffeurCore/Engine/Session+Batch.swift \
  Sources/ChauffeurCore/Agent/MCPTools.swift Tests/ChauffeurCoreTests/WaitTests.swift \
  Tests/ChauffeurCoreTests/MCPTests.swift
git commit -m "wait finishes a PENDING tap; batches go through PENDING; MCP act gains wait"
```

---

### Task 10: A copy to the clipboard is an effect

Spec §7, Findings §7.

**Files:**
- Create: `Sources/ChauffeurCore/Engine/Session+Clipboard.swift`, `Tests/ChauffeurCoreTests/ClipboardTests.swift`
- Modify: `Sources/ChauffeurCore/Engine/Session+Act.swift` (`tapCommand`)

**Interfaces:**
- Consumes: `ActionReport.copiedCharacters` (Task 7), `SimCtl.run`.
- Produces: `ClipboardMark` (`init(_ text:)`, `copied(before:after:) -> Int?`), `Background<T>`
  (`init(_:)`, `result(waitingAtMost:)`), `Session.readClipboard(udid:) -> ClipboardMark?`.

- [ ] **Step 1: Write the failing test**

`Tests/ChauffeurCoreTests/ClipboardTests.swift`:

```swift
import Foundation
import Testing

@testable import ChauffeurCore

/// M4b spec §7: only a length leaves the daemon.
@Suite struct ClipboardTests {
    @Test func aNewNonEmptyValueIsACopy() {
        let before = ClipboardMark("old")
        #expect(ClipboardMark.copied(before: before, after: ClipboardMark("FIXTURE-CODE-2026")) == 17)
        #expect(ClipboardMark.copied(before: before, after: ClipboardMark("old")) == nil)
        #expect(ClipboardMark.copied(before: before, after: ClipboardMark("")) == nil)
        #expect(ClipboardMark.copied(before: nil, after: ClipboardMark("x")) == nil)  // no before: can't tell
    }

    @Test func aMarkKeepsNoText() {
        let mark = String(describing: ClipboardMark("hunter2"))
        #expect(!mark.contains("hunter2"))
    }

    @Test func backgroundWorkIsCollected() {
        let quick = Background { 42 }
        #expect(quick.result(waitingAtMost: 1000) == 42)
        #expect(quick.result(waitingAtMost: 0) == 42)  // a second read gets the same value
        let slow = Background { () -> Int in
            usleep(300_000)
            return 1
        }
        #expect(slow.result(waitingAtMost: 10) == nil)
    }
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `swift test --filter ClipboardTests 2>&1 | grep -E "error:" | head -2`
Expected: `cannot find 'ClipboardMark' in scope`.

- [ ] **Step 3: Write the clipboard check**

`Sources/ChauffeurCore/Engine/Session+Clipboard.swift`:

```swift
import Foundation

/// The simulator pasteboard reduced to what may leave the daemon (M4b spec §7): a hash to compare, and a length.
struct ClipboardMark: Equatable, Sendable, CustomStringConvertible {
    let hash: Int
    let characters: Int

    init(_ text: String) {
        hash = text.hashValue
        characters = text.count
    }

    var description: String { "clipboard (\(characters) characters)" }

    /// What a tap copied: the new length, when the pasteboard changed to something non-empty.
    static func copied(before: ClipboardMark?, after: ClipboardMark?) -> Int? {
        guard let before, let after, after != before, after.characters > 0 else { return nil }
        return after.characters
    }
}

/// Work started on a background queue and collected later, so a slow read (`pbpaste`, ~100 ms) overlaps the baseline.
final class Background<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T?
    private let done = DispatchSemaphore(value: 0)

    init(_ work: @escaping @Sendable () -> T) {
        DispatchQueue.global(qos: .userInitiated).async {
            let v = work()
            self.lock.withLock { self.value = v }
            self.done.signal()
        }
    }

    /// The result, waiting at most `ms`; nil if it isn't ready by then.
    func result(waitingAtMost ms: Int) -> T? {
        if done.wait(timeout: .now() + .milliseconds(ms)) == .success { done.signal() }
        return lock.withLock { value }
    }
}

extension Session {
    nonisolated static func readClipboard(udid: String) -> ClipboardMark? {
        guard let r = try? SimCtl.run(["pbpaste", udid], timeout: 5), r.status == 0 else { return nil }
        return ClipboardMark(r.out)
    }
}
```

In `tapCommand` (`Session+Act.swift`):

1. After `let network = netStart()`, add:

```swift
        let udid = self.udid
        let clipboard = Background { Session.readClipboard(udid: udid) }
```

2. Before the first `var report = try act(`, add
`let clipboardBefore = clipboard.result(waitingAtMost: 2000) ?? nil` (the touch waits only if the read isn't done).

3. Before the final `return Output(report.render(), exit: report.exitCode, data: report.json)` of `tapCommand`,
   add:

```swift
        // A copy changes nothing on screen; read the pasteboard again only then (spec §7: a read costs ~100 ms).
        if report.outcome == .noEffect,
            let copied = ClipboardMark.copied(before: clipboardBefore, after: Session.readClipboard(udid: udid))
        {
            report.outcome = .changed
            report.copiedCharacters = copied
            report.hints = []
            report.evidenceShot = nil
        }
```

- [ ] **Step 4: Run the tests**

Run: `scripts/format.sh && swift test --filter "ClipboardTests|ReportNetworkTests" 2>&1 | tail -2`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/ChauffeurCore/Engine/Session+Clipboard.swift Sources/ChauffeurCore/Engine/Session+Act.swift \
  Tests/ChauffeurCoreTests/ClipboardTests.swift
git commit -m "A copy to the clipboard is a verified effect; only its length is shown"
```

---

### Task 11: Tell agents, and update the docs

Spec §3 (skill, MCP instructions, act description), "Done when".

**Files:**
- Modify: `Sources/ChauffeurCore/Engine/Args.swift` (`Usage.text`), `Sources/ChauffeurCore/Agent/Skill.swift`,
  `Sources/ChauffeurCore/Agent/MCPServer.swift` (`instructions`), `Sources/ChauffeurCore/Agent/MCPTools.swift` (`act`
  description), `docs/design.md`, `docs/roadmap.md`, `CHANGELOG.md`
- Test: `Tests/ChauffeurCoreTests/SkillTests.swift`, `Tests/ChauffeurCoreTests/MCPTests.swift`

**Interfaces:**
- Consumes: exit 6, bare `wait`, MCP `act` `wait` (Tasks 7, 9).
- Produces: agent-facing text that explains `PENDING`.

- [ ] **Step 1: Write the failing tests**

In `Tests/ChauffeurCoreTests/SkillTests.swift`, add inside the suite:

```swift
    @Test func everySurfaceExplainsPending() {
        for text in [Skill.skillMarkdown, Skill.agentsSection, MCPServer.instructions, Usage.text] {
            #expect(text.contains("PENDING") || text.contains("6 effect still in flight"), "\(text.prefix(60))")
        }
        #expect(Usage.text.contains("6 effect still in flight (chauffeur wait)"))
        #expect(Skill.skillMarkdown.contains("`chauffeur wait`"))
    }
```

In `Tests/ChauffeurCoreTests/MCPTests.swift`, add:

```swift
    @Test func actDescribesPending() throws {
        let act = try #require(MCPTools.definitions.first { $0["name"]?.string == "act" })
        #expect(act["description"]?.string?.contains("PENDING") == true)
    }
```

- [ ] **Step 2: Run them to verify they fail**

Run: `swift test --filter "SkillTests|MCPTests" 2>&1 | grep -E "failed|error:" | head -4`
Expected: `everySurfaceExplainsPending` and `actDescribesPending` fail.

- [ ] **Step 3: The text**

1. `Usage.text` (`Args.swift`): the `wait` line becomes
   `          wait ["<query>"] [--gone] [--timeout <s>]   an element to appear (or go); bare: finish a PENDING tap`
   and the exit-codes line becomes
   `        exit codes: 0 ok · 1 error · 3 action had no verified effect · 4 not found · 5 app crashed · 6 effect still in flight (chauffeur wait) · 64 usage`.
2. `Skill.swift`, the loop's result list: after the `APP CRASHED` bullet add

```
           - `PENDING` (exit 6): the app is still waiting for a network reply. Run `chauffeur wait` for the verdict;
             don't tap again.
```

   and in the AGENTS.md section's step 3, after `` `APP CRASHED` means run `chauffeur logs`. `` add
   `` `PENDING` means run `chauffeur wait`. `` (re-wrap to 120 columns).
3. `MCPServer.instructions`: after the sentence ending `…so read the hint. `, add
   `"PENDING means the app is still waiting for a network reply: call act with action wait. "`.
4. `MCPTools` `act` description: after `"…never a false success. "` insert
   `"PENDING (the app is waiting for a network reply): act with action wait finishes it. "`.
5. `docs/design.md` §13: replace `network inspection;` with
   `network inspection beyond M4b's request evidence (bodies, headers and a traffic log are stage 2, see
   docs/specs/2026-10-08-m4b-network-and-evidence-design.md);`.
6. `docs/roadmap.md`: check `- [ ] Network activity and detail layers, …` (`[x]`).
7. `CHANGELOG.md`, under `## Unreleased (0.2.0)`, add:

```markdown
- A tap that starts a network request and changes nothing on screen is `PENDING` (exit 6) while the app waits for
  the reply; `chauffeur wait` finishes it, and `do` waits through it.
- A request that fails or changes nothing explains a `NO EFFECT`: `api.example.com/login → 500 Internal Server
  Error in 180 ms (server 160 ms)`, with bytes, protocol and a hint. Telemetry gets its own line.
- A copy to the clipboard counts as a change: `changed · copied to clipboard (24 characters)`.
- URLs in Apple's networking log lines are shown as host and path shape everywhere: no query strings, tokens or
  emails in `chauffeur logs` or action results.
```

- [ ] **Step 4: Run the tests**

Run: `scripts/format.sh && swift test 2>&1 | tail -1`
Expected: the whole unit suite passes.

- [ ] **Step 5: Commit**

```bash
git add Sources/ChauffeurCore/Engine/Args.swift Sources/ChauffeurCore/Agent docs/design.md docs/roadmap.md \
  CHANGELOG.md Tests/ChauffeurCoreTests/SkillTests.swift Tests/ChauffeurCoreTests/MCPTests.swift
git commit -m "Agents learn PENDING and wait; docs and changelog"
```

---

### Task 12: The fixture's Network tab and the live tests

Spec "Testing → Live".

**Files:**
- Create: `Tests/FixtureApp/NetworkView.swift`, `Tests/FixtureApp/netserver.py`,
  `Tests/ChauffeurCoreTests/Live/NetworkLiveTests.swift`, `Tests/ChauffeurCoreTests/Live/RecoverLiveTests.swift`
- Modify: `Tests/FixtureApp/FixtureApp.swift` (a third tab), `Tests/FixtureApp/build.sh` (compile both files),
  `Tests/FixtureApp/Info.plist` (local networking)

**Interfaces:**
- Consumes: everything above; `Live`, `ref(_:_:)`, `Session.telemetryOverride`.
- Produces: live evidence for every row of the spec's live table except "double submit" (stage 2).

- [ ] **Step 1: The local server**

`Tests/FixtureApp/netserver.py`:

```python
"""The fixture's network peer for live tests: HTTP on 127.0.0.1:8765, WebSocket on 8766. Stdlib only."""
import base64, hashlib, socket, threading, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PAGE = b'<html><body style="font-size:40px"><a href="/slow">Slow link</a></body></html>'


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path.startswith("/slow"):
            time.sleep(2.5)
        if self.path.startswith("/fail"):
            return self.reply(500, b"failed")
        if self.path.startswith("/metrics"):
            return self.reply(204, b"")
        if self.path.startswith("/page"):
            return self.reply(200, PAGE, "text/html")
        self.reply(200, b"ok")

    def reply(self, code, body, kind="text/plain"):
        self.send_response(code)
        self.send_header("Content-Type", kind)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


def websocket():
    s = socket.socket()
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind(("127.0.0.1", 8766))
    s.listen()
    while True:
        c, _ = s.accept()
        request = c.recv(4096).decode(errors="replace")
        key = [l.split(": ", 1)[1] for l in request.split("\r\n") if l.lower().startswith("sec-websocket-key")]
        if not key:
            c.close()
            continue
        accept = base64.b64encode(hashlib.sha1((key[0] + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()).digest())
        c.send(b"HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
               b"Sec-WebSocket-Accept: " + accept + b"\r\n\r\n")

        def tick(c=c):
            try:
                while True:
                    c.send(b"\x81\x04tick")
                    time.sleep(0.05)  # faster than chauffeur's 100 ms samples, so every sample sees it stream
            except OSError:
                pass

        threading.Thread(target=tick, daemon=True).start()


threading.Thread(target=websocket, daemon=True).start()
ThreadingHTTPServer.allow_reuse_address = True
ThreadingHTTPServer(("127.0.0.1", 8765), Handler).serve_forever()
```

- [ ] **Step 2: The Network tab**

`Tests/FixtureApp/NetworkView.swift`:

```swift
// The fixture's Network tab (M4b live tests): one kind of traffic per button, to the live tests' server on
// 127.0.0.1:8765 (HTTP) and 8766 (WebSocket).
import SwiftUI
import WebKit

struct NetworkView: View {
    @State private var result = "none"
    @State private var query = ""
    @State private var search: Task<Void, Never>?
    private let base = "http://127.0.0.1:8765"

    var body: some View {
        List {
            Text("Result: \(result)").accessibilityIdentifier("netResult")
            Button("Slow API") { get("/slow") { result = "slow \($0)" } }
            Button("Fast API") { get("/fast") { result = "fast \($0)" } }
            Button("Failing API") { get("/fail") { _ in } }
            Button("Analytics only") { get("/metrics/event") { _ in } }
            Button("Raw socket") { rawSocket() }
            Button("Open WebSocket") { webSocket() }
            Button("Copy code") { UIPasteboard.general.string = "FIXTURE-CODE-2026" }
            Button("Dead network button") {}
            TextField("Search", text: $query)
                .textInputAutocapitalization(.never)
                .accessibilityIdentifier("search")
                .onChange(of: query) { _, q in
                    search?.cancel()
                    search = Task {
                        try? await Task.sleep(for: .milliseconds(300))
                        let encoded = q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
                        if !Task.isCancelled { get("/fast?q=" + encoded) { _ in } }
                    }
                }
            FixtureWeb(url: URL(string: base + "/page")!).frame(height: 120)
        }
        .navigationTitle("Network")
    }

    func get(_ path: String, done: @escaping @MainActor (Int) -> Void) {
        URLSession.shared.dataTask(with: URL(string: base + path)!) { _, response, _ in
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            Task { @MainActor in done(status) }
        }.resume()
    }

    /// A slow request over a BSD socket: a stack URLSession's logs never see (spec: the activity layer's case).
    func rawSocket() {
        DispatchQueue.global().async {
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = in_port_t(8765).bigEndian
            addr.sin_addr.s_addr = inet_addr("127.0.0.1")
            _ = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            let request = "GET /slow HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n"
            _ = request.withCString { send(fd, $0, strlen($0), 0) }
            var buffer = [UInt8](repeating: 0, count: 4096)
            _ = recv(fd, &buffer, buffer.count, 0)
            close(fd)
        }
    }

    func webSocket() {
        let task = URLSession.shared.webSocketTask(with: URL(string: "ws://127.0.0.1:8766/")!)
        task.resume()
        func next() { task.receive { if case .success = $0 { next() } } }
        next()
    }
}

struct FixtureWeb: UIViewRepresentable {
    let url: URL
    func makeUIView(context: Context) -> WKWebView {
        let view = WKWebView()
        view.load(URLRequest(url: url))
        return view
    }
    func updateUIView(_ view: WKWebView, context: Context) {}
}
```

In `Tests/FixtureApp/FixtureApp.swift`, inside the `TabView`, after the Form tab add:

```swift
                NavigationStack { NetworkView() }.tabItem { Label("Network", systemImage: "network") }.tag("network")
```

In `Tests/FixtureApp/build.sh`, change `-target "$(uname -m)-apple-ios17.0-simulator" FixtureApp.swift -o "$APP/Fixture"`
to `-target "$(uname -m)-apple-ios17.0-simulator" FixtureApp.swift NetworkView.swift -o "$APP/Fixture"`.

In `Tests/FixtureApp/Info.plist`, before `</dict>` at the end:

```xml
    <key>NSAppTransportSecurity</key><dict><key>NSAllowsLocalNetworking</key><true/></dict>
```

Run: `Tests/FixtureApp/build.sh` → prints the `.app` path.

- [ ] **Step 3: The live tests**

`Tests/ChauffeurCoreTests/Live/NetworkLiveTests.swift`:

```swift
import Foundation
import Testing

@testable import ChauffeurCore

/// M4b spec "Testing → Live": every row of the network table on the fixture's Network tab.
@Suite(.enabled(if: Live.enabled), .serialized)
@MainActor struct NetworkLiveTests {
    static func server() throws -> Process {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["python3", "-I", Live.repo.path + "/Tests/FixtureApp/netserver.py"]
        try p.run()
        usleep(500_000)
        return p
    }

    func onNetworkTab() throws -> (Session, Process) {
        let server = try Self.server()
        let s = Session(udid: Live.udid!)
        #expect(s.run(["install", try Live.buildFixture()]).exit == 0)
        #expect(s.run(["launch", Live.fixture]).exit == 0)
        #expect(s.run(["tap", try ref(s, "Network")]).exit == 0)
        return (s, server)
    }

    func done(_ s: Session, _ server: Process) {
        s.shutdown()
        server.terminate()
    }

    @Test func aSlowAPIIsPendingThenWaitFinishesIt() throws {
        let (s, server) = try onNetworkTab()
        defer { done(s, server) }
        let out = s.run(["tap", try ref(s, "Slow API")])
        #expect(out.exit == 6, "\(out.text)")
        #expect(out.text.contains("→ PENDING · 127.0.0.1:8765/slow still running after"), "\(out.text)")
        let waited = s.run(["wait"])
        #expect(waited.exit == 0, "\(waited.text)")
        #expect(waited.text.contains("→ changed") && waited.text.contains("request: 127.0.0.1:8765/slow → 200 OK"),
            "\(waited.text)")
    }

    @Test func aFastAPIChangesWithARequestLine() throws {
        let (s, server) = try onNetworkTab()
        defer { done(s, server) }
        let out = s.run(["tap", try ref(s, "Fast API")])
        #expect(out.exit == 0 && out.text.contains("request: 127.0.0.1:8765/fast → 200 OK"), "\(out.text)")
    }

    @Test func aFailingAPIExplainsTheNoEffect() throws {
        let (s, server) = try onNetworkTab()
        defer { done(s, server) }
        let out = s.run(["tap", try ref(s, "Failing API")])
        #expect(out.exit == 3, "\(out.text)")
        #expect(out.text.contains("→ NO EFFECT · 127.0.0.1:8765/fail → 500 Internal Server Error"), "\(out.text)")
        #expect(out.text.contains("hint: the server failed (500)"), "\(out.text)")
    }

    @Test func analyticsAloneStaysNoEffect() throws {
        let (s, server) = try onNetworkTab()
        defer { done(s, server) }
        s.telemetryOverride = ["127.0.0.1/metrics"]
        let out = s.run(["tap", try ref(s, "Analytics only")])
        #expect(out.exit == 3 && out.text.contains("telemetry: 1 request (127.0.0.1)"), "\(out.text)")
    }

    @Test func aRawSocketIsPendingFromTheActivityLayer() throws {
        let (s, server) = try onNetworkTab()
        defer { done(s, server) }
        let out = s.run(["tap", try ref(s, "Raw socket")])
        #expect(out.exit == 6 && out.text.contains("→ PENDING · 127.0.0.1:8765 · sent"), "\(out.text)")
    }

    @Test func anOpenWebSocketIsDataFlowing() throws {
        let (s, server) = try onNetworkTab()
        defer { done(s, server) }
        let out = s.run(["tap", try ref(s, "Open WebSocket")])
        #expect(out.exit == 3 && out.text.contains("connected, data flowing"), "\(out.text)")
    }

    @Test func aWebViewLinkToASlowPageIsPending() throws {
        let (s, server) = try onNetworkTab()
        defer { done(s, server) }
        let out = s.run(["tap", try ref(s, "Slow link")])
        #expect(out.exit == 6, "\(out.text)")
    }

    @Test func aCopyIsAChange() throws {
        let (s, server) = try onNetworkTab()
        defer { done(s, server) }
        let out = s.run(["tap", try ref(s, "Copy code")])
        #expect(out.exit == 0 && out.text.contains("copied to clipboard (17 characters)"), "\(out.text)")
    }

    @Test func aDeadButtonIsPlainAndNotSlower() throws {
        let (s, server) = try onNetworkTab()
        defer { done(s, server) }
        let dead = try ref(s, "Dead network button")
        var times: [Int] = []
        for _ in 0..<3 {
            let start = Date()
            let out = s.run(["tap", dead])
            times.append(Int(Date().timeIntervalSince(start) * 1000))
            #expect(out.exit == 3 && !out.text.contains("request:") && !out.text.contains("PENDING"), "\(out.text)")
        }
        // Step 0 measured 0.98–1.02 s for a dead tap before M4b; the grace adds 20 ms plus one sample.
        #expect(times.sorted()[1] < 1500, "\(times)")
    }

    @Test func typingIntoSearchIsNeverAFalseNoEffect() throws {
        let (s, server) = try onNetworkTab()
        defer { done(s, server) }
        let out = s.run(["type", try ref(s, "search"), "abc"])
        #expect(out.exit == 0, "\(out.text)")
    }

    @Test func aBatchGoesThroughPending() throws {
        let (s, server) = try onNetworkTab()
        defer { done(s, server) }
        let out = s.run(["do", "tap \(try ref(s, "Slow API")); snapshot"])
        #expect(out.exit == 0 && out.text.contains("→ PENDING") && out.text.contains("→ changed"), "\(out.text)")
    }
}
```

`Tests/ChauffeurCoreTests/Live/RecoverLiveTests.swift`:

```swift
import Foundation
import Testing

@testable import ChauffeurCore

/// M4b spec §8: an app opened without accessibility is relaunched once, with a note (Plan 1, Task 5; checked by hand
/// then, pinned here).
@Suite(.enabled(if: Live.enabled), .serialized)
@MainActor struct RecoverLiveTests {
    @Test func anIconLaunchedAppIsRelaunched() throws {
        let udid = Live.udid!
        _ = try Live.buildFixture()
        let flag = ["spawn", udid, "defaults", "write", "com.apple.Accessibility", "ApplicationAccessibilityEnabled",
            "-bool"]
        try SimCtl.run(flag + ["false"])
        try SimCtl.run(["terminate", udid, Live.fixture])
        try SimCtl.run(["launch", udid, Live.fixture], timeout: 60)
        sleep(4)
        try SimCtl.run(flag + ["true"])
        let s = Session(udid: udid)
        defer { s.shutdown() }
        var out = s.run(["snapshot"])
        for _ in 0..<3 where out.exit != 0 { out = s.run(["snapshot"]) }
        #expect(out.exit == 0, "\(out.text)")
        #expect(out.text.contains("note: relaunched dev.chauffeur.fixture"), "\(out.text)")
    }
}
```

- [ ] **Step 4: Run them live**

```bash
uptime   # load under 10; boot one iOS 27 simulator if none is booted, then wait for load under 10 again
UDID=$(xcrun simctl list devices booted | grep -o -E '[0-9A-F-]{36}' | head -1)
CHAUFFEUR_LIVE_UDID=$UDID swift test --no-parallel --filter "NetworkLiveTests|RecoverLiveTests|NetStatsLiveTests" 2>&1 | tail -15
```

Expected: every test passes. A failure is a finding: read the result text the test prints, then fix the code under
superpowers:systematic-debugging, never the expectation, unless the expectation contradicts the spec (then ledger a
ruling). Then run the existing live suites once, since `tap` changed:
`CHAUFFEUR_LIVE_UDID=$UDID swift test --no-parallel --filter "TapLiveTests|LogsLiveTests|BatchLiveTests|TypeLiveTests" 2>&1 | tail -5`.

- [ ] **Step 5: Commit**

```bash
git add Tests/FixtureApp Tests/ChauffeurCoreTests/Live/NetworkLiveTests.swift \
  Tests/ChauffeurCoreTests/Live/RecoverLiveTests.swift
git commit -m "Fixture Network tab and live tests for every network row"
```

---

### Task 13: Release 0.2.0

Spec §10, CONTRIBUTING "Releasing". Every step after Step 3 is an outward action: ask the owner before each.

**Files:**
- Modify: `Sources/ChauffeurCore/Model.swift` (`Chauffeur.version`), `Tests/ChauffeurCoreTests/ModelTests.swift`,
  `CHANGELOG.md`, `README.md`, `server.json`, `scripts/mcpb/manifest.json`

- [ ] **Step 1: Version and notes**

`grep -rn '0\.1\.1' Sources Tests scripts/mcpb server.json` and change each version string to `0.2.0`
(`Chauffeur.version`, its test, the MCPB manifest, `server.json`'s version). In `CHANGELOG.md`, rename
`## Unreleased (0.2.0)` to `## 0.2.0`. In `README.md`'s benchmark section, add after its first paragraph:
`The figures were measured with chauffeur 0.1.x, before M4b's network evidence.`

- [ ] **Step 2: Full check**

Run: `scripts/check.sh 2>&1 | tail -1 && scripts/check-commits.sh origin/main..HEAD`
Expected: `check: all passed`; commits clean.

- [ ] **Step 3: Commit**

```bash
git add -A Sources Tests CHANGELOG.md README.md server.json scripts/mcpb
git commit -m "0.2.0"
```

- [ ] **Step 4: PR (owner approval first)**

```bash
git push -u origin m4b-network
gh pr create --title "M4b part 2: network evidence, PENDING and wait (0.2.0)" --body "A tap that starts a network request and changes nothing on screen is PENDING (exit 6) until the reply arrives; chauffeur wait finishes it and do waits through it. Failed or pointless requests explain a NO EFFECT in words (status or error, server time, bytes, hint); telemetry gets its own line; a clipboard copy counts as a change; URLs in Apple's networking log lines are shaped everywhere. Live: NetworkLiveTests, RecoverLiveTests and NetStatsLiveTests pass on iOS 27. Releases 0.2.0."
gh pr checks --watch
```

Merge only with the owner's go-ahead: `gh pr merge --squash --admin`.

- [ ] **Step 5: Tag, release, Homebrew, MCP (owner approval for each)**

Follow CONTRIBUTING.md "Releasing" steps 3–5 on the merged `main` commit: tag `v0.2.0` and `gh release create`;
point `YashNaj/homebrew-chauffeur`'s formula at the tag and revision, then `brew upgrade chauffeur && brew test
chauffeur`; the MCP server changed (new outcome, new action), so build `chauffeur.mcpb` with `scripts/build-mcpb.sh`,
attach it to the release, update `server.json` (URL, `fileSha256`) and run `mcp-publisher publish`.
