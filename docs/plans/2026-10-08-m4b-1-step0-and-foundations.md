# M4b Plan 1: step 0 and the foundations

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Answer the spec's step 0 questions and write them into its Findings, and land the M4b pieces that don't
depend on those answers: path shapes, the telemetry list and config, crash-first results, and relaunching an app
opened from its icon.

**Architecture:** M4b is planned in two parts because the spec requires step 0's findings before the plan for the
network layers (§1: "The answers go into Findings … before the plan is written"). Plan 1 is the spike plus four
self-contained units. Plan 2 (written after Task 1, from the Findings) covers `ConnectionWatch`, `RequestLog`, the
result rules, `PENDING`, `wait`, batches, the clipboard, the live tests and the 0.2.0 release.

**Tech Stack:** Swift 6 / SwiftPM, swift-testing, `xcrun simctl`, bash 3.2, Python 3 (`-I`) for the throwaway server.

**Spec:** `docs/specs/2026-10-08-m4b-network-and-evidence-design.md`

## Global Constraints

- Work in `~/Developer/repos/chauffeur` on branch `m4b-spec` (holds the spec and this plan); Tasks 2–6 go on a branch
  `m4b-foundations` cut from it. Every change reaches `main` through a PR; never push to `main`.
- Commits: author and committer `YashNaj <68571013+YashNaj@users.noreply.github.com>`; no AI `Co-Authored-By`
  trailer; no session links. `scripts/check-commits.sh origin/main..HEAD` must pass.
- `scripts/check.sh` passes before every push. Formatting is `swift-format` (4 spaces, 120 columns): run
  `scripts/format.sh` after editing Swift.
- Lint (`scripts/check-code.sh`): private API only in `Sources/ChauffeurBridge`; no `try!` in `Sources`; no `print`
  in `ChauffeurCore`; files under 400 lines in `Sources`, 600 in `Tests`. `Session.swift` is at 377 lines: new
  `Session` code goes in a new `Session+…` file; only stored properties go in `Session.swift`.
- chauffeur makes no network connections of its own; nothing leaves the machine.
- The agent may see host, port, method, path shape, status, timing and byte counts; never bodies, headers, cookies,
  query strings, values an app marked private, or clipboard contents (spec §6).
- Hosts and paths are untrusted text: quoted and escaped like screen text when rendered (Plan 2 renders them).
- Pushing, opening or merging PRs and changing GitHub settings are outward actions: ask the owner before each one.
  The owner's PRs merge with `gh pr merge <n> --squash --admin` once CI is green.
- The step 0 probe app and server are throwaway: they live in a temp directory, never in the repo.

## Review Focus

1. **A slug that looks like a token.** `/account-settings-overview` and `/v2/users` are ordinary paths; collapsing
   them would make every evidence line useless. Pinned in Task 2 (`ordinarySegmentsStay`).
2. **A percent-encoded email.** `/reset/sam%40example.com` must still become `{email}`. Pinned in Task 2
   (`percentEncodedEmailIsCollapsed`).
3. **A telemetry entry that matches too much.** `sentry.io` must not match `notsentry.io`, and `example.com/metrics`
   must not match `/metricsfoo`. Pinned in Task 3 (`suffixesMatchWholeLabels`, `pathPrefixesMatchWholeSegments`).
4. **`chauffeur use` in a project that already has a config.** It must keep every other key. Pinned in Task 3
   (`useKeepsOtherKeys`).
5. **Two running apps with the same display name, or none matching.** The relaunch must not guess; it falls back to
   today's message. Pinned in Task 5 (`ambiguousOrUnknownAppIsNotRelaunched`).

---

### Task 1: Step 0, what the Mac and the logs show

Spec §1. A spike: its output is the spec's Findings section, not code. Everything built here is throwaway and stays
out of the repo.

**Files:**
- Modify: `docs/specs/2026-10-08-m4b-network-and-evidence-design.md` (the `## Findings` section only)
- Throwaway, in `$P=$(mktemp -d)`: `Probe.swift`, `Info.plist`, `server.py`

**Interfaces:**
- Consumes: nothing.
- Produces: the Findings, one subsection per spec §1 question, each with the commands run and the raw evidence
  (recorded log lines, sample `nettop` rows, timings). Plan 2 is written from them.

- [ ] **Step 1: Check the host and pick the simulators**

```bash
uptime
xcrun simctl list devices available | grep -E "iOS (26|27)" | head
```

Load average must be under 10 before booting (8 GB host). Boot one iOS 27 simulator now; the iOS 26 pass (Step 9)
happens after the iOS 27 one, on its own. `export UDID=<the booted udid>`.

- [ ] **Step 2: Write the throwaway server**

`$P/server.py`, stdlib only, on 127.0.0.1 (HTTP on 8765, WebSocket handshake on 8766):

```python
import base64, hashlib, socket, threading, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

class H(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path.startswith("/slow"):
            time.sleep(2.5)
        if self.path.startswith("/fail"):
            self.send_response(500); self.end_headers(); self.wfile.write(b"no"); return
        if self.path.startswith("/stream"):
            self.send_response(200); self.send_header("Content-Type", "text/event-stream"); self.end_headers()
            while True:
                self.wfile.write(b"data: tick\n\n"); self.wfile.flush(); time.sleep(0.5)
        self.send_response(200); self.end_headers(); self.wfile.write(b"ok")
    def log_message(self, *a): pass

def ws():
    s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1); s.bind(("127.0.0.1", 8766)); s.listen()
    while True:
        c, _ = s.accept(); req = c.recv(4096).decode()
        key = [l.split(": ", 1)[1] for l in req.split("\r\n") if l.lower().startswith("sec-websocket-key")][0]
        acc = base64.b64encode(hashlib.sha1((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()).digest()).decode()
        c.send(("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
                f"Sec-WebSocket-Accept: {acc}\r\n\r\n").encode())
        def tick(c=c):
            while True:
                c.send(b"\x81\x04tick"); time.sleep(0.5)
        threading.Thread(target=tick, daemon=True).start()

threading.Thread(target=ws, daemon=True).start()
ThreadingHTTPServer(("127.0.0.1", 8765), H).serve_forever()
```

Run: `python3 -I "$P/server.py" &` then `curl -s -m 5 localhost:8765/fast` → `ok`.

- [ ] **Step 3: Write and build the throwaway probe app**

`$P/Probe.swift`:

```swift
import Network
import SwiftUI
import UIKit
import WebKit

@main
struct ProbeApp: App {
    var body: some Scene { WindowGroup { ProbeView() } }
}

struct ProbeView: View {
    @State var last = "idle"
    @State var showWeb = false
    let base = "http://localhost:8765"

    var body: some View {
        VStack(spacing: 14) {
            Text(last).accessibilityIdentifier("last")
            Button("URLSession slow") { get("/slow") }
            Button("URLSession fast") { get("/fast") }
            Button("URLSession 500") { get("/fail") }
            Button("Raw socket slow") { rawSocket() }
            Button("NWConnection slow") { nwConnection() }
            Button("WebSocket") { webSocket() }
            Button("Stream") { get("/stream") }
            Button("Web view slow") { showWeb = true }
            Button("Copy") { UIPasteboard.general.string = "chauffeur-probe-copy" }
            Button("Dead") {}
        }
        .sheet(isPresented: $showWeb) { Web(url: URL(string: base + "/slow")!) }
    }

    func get(_ path: String) {
        URLSession.shared.dataTask(with: URL(string: base + path)!) { _, r, e in
            DispatchQueue.main.async { last = "\(path) \((r as? HTTPURLResponse)?.statusCode ?? -1) \(e.map { "\($0)" } ?? "")" }
        }.resume()
    }

    func rawSocket() {
        DispatchQueue.global().async {
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = in_port_t(8765).bigEndian
            addr.sin_addr.s_addr = inet_addr("127.0.0.1")
            _ = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
            let req = "GET /slow HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n"
            _ = req.withCString { send(fd, $0, strlen($0), 0) }
            var buf = [UInt8](repeating: 0, count: 4096)
            let n = recv(fd, &buf, buf.count, 0)
            close(fd)
            DispatchQueue.main.async { last = "raw \(n)" }
        }
    }

    func nwConnection() {
        let c = NWConnection(host: "localhost", port: 8765, using: .tcp)
        c.start(queue: .global())
        c.send(content: Data("GET /slow HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n".utf8),
               completion: .contentProcessed { _ in })
        c.receive(minimumIncompleteLength: 1, maximumLength: 4096) { d, _, _, _ in
            DispatchQueue.main.async { last = "nw \(d?.count ?? -1)" }
            c.cancel()
        }
    }

    func webSocket() {
        let t = URLSession.shared.webSocketTask(with: URL(string: "ws://localhost:8766/")!)
        t.resume()
        t.receive { _ in DispatchQueue.main.async { last = "ws message" } }
    }
}

struct Web: UIViewRepresentable {
    let url: URL
    func makeUIView(context: Context) -> WKWebView {
        let w = WKWebView()
        w.load(URLRequest(url: url))
        return w
    }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
```

`$P/Info.plist`: copy `Tests/FixtureApp/Info.plist`, then set `CFBundleIdentifier` to `dev.chauffeur.probe`,
`CFBundleExecutable` and `CFBundleName` to `Probe`, and add `NSAppTransportSecurity` → `NSAllowsArbitraryLoads` = true.

Build exactly like `Tests/FixtureApp/build.sh`, into `$P/Probe.app`:

```bash
mkdir -p "$P/Probe.app"
xcrun -sdk iphonesimulator swiftc -parse-as-library -O -target "$(uname -m)-apple-ios17.0-simulator" \
  "$P/Probe.swift" -o "$P/Probe.app/Probe"
cp "$P/Info.plist" "$P/Probe.app/Info.plist" && codesign --force --sign - "$P/Probe.app"
swift build -c release && B=.build/release/chauffeur
$B install "$P/Probe.app" && $B launch dev.chauffeur.probe
```

Expected: `launch dev.chauffeur.probe → …` with the probe's buttons in `$B snapshot`. `export PID=<pid from launch>`.

- [ ] **Step 4: Activity layer (spec §1 questions 1–3)**

In one terminal: `nettop -n -x -L 0 -s 1 -m tcp -p $PID -J time,bytes_in,bytes_out,state 2>&1 | tee "$P/nettop.txt"`
(if `-p` with `-L 0` errors, use `-P -L 0 -s 1` and filter by the `Probe.<pid>` row). In another, tap each button
with `$B tap "<label>"`, five seconds apart, noting the wall-clock time of each tap.

Record for each button: does a row appear for the probe's pid, how many seconds after the tap, do `bytes_out` and
`bytes_in` move as expected (out first, in ~2.5 s later for the slow ones), and does the WebSocket and stream row keep
growing. For the web view: `ps -axo pid,ppid,command | grep -i "WebKit.Networking" | grep "$UDID"`; note whether its
traffic shows under that process, and how it can be tied to the probe (its parent, its command line, or only "the one
started after the probe opened the sheet").

Then measure what reading the data directly costs, because Plan 2 polls it: time 20 runs of
`nettop -n -x -L 1 -m tcp -p $PID -J bytes_in,bytes_out` (`/usr/bin/time -p`). Also check whether
`lsof -nP -a -p $PID -i` shows the connections with remote names. Note whether host names (`localhost`) or only IPs
appear, and for UDP/QUIC whether rows appear at all (`-m udp`).

- [ ] **Step 5: Detail layer (spec §1 questions 4–6)**

```bash
xcrun simctl spawn $UDID log config --status --subsystem com.apple.CFNetwork
xcrun simctl spawn $UDID log stream --level debug --style ndjson --predicate 'process == "Probe"' > "$P/logs.ndjson" &
$B tap "URLSession slow"; sleep 4; $B tap "URLSession 500"; sleep 2; kill %%
grep -c . "$P/logs.ndjson"
python3 -I -c 'import json,sys; [print(o.get("messageType"), o.get("subsystem"), o.get("category"), o.get("eventMessage","")[:160]) for o in map(json.loads, open(sys.argv[1])) if "Task <" in o.get("eventMessage","") or "nw_" in o.get("eventMessage","")]' "$P/logs.ndjson" | head -60
```

Record the exact lines that mark a task starting and ending, their level (`messageType`), subsystem and category,
whether a status code or error appears, and whether URLs read `<private>`. Then:

```bash
xcrun simctl spawn $UDID log config --subsystem com.apple.CFNetwork --mode "private_data:on"
xcrun simctl spawn $UDID log config --status --subsystem com.apple.CFNetwork
```

Repeat the capture. Record whether host and path now appear. If not, repeat with `--subsystem com.apple.network`,
then (last) with the global `log config --mode "private_data:on"`; undo each with `--mode "private_data:off"` before
trying the next, and undo everything at the end of the task. Measure CPU of a debug-level stream limited to the
subsystem (`--predicate 'process == "Probe" AND subsystem == "com.apple.CFNetwork"'`) against today's info-level
stream during 30 s of tapping: `ps -o %cpu= -p <log stream pid>` every second.

Delay and marker: record the gap between each tap and its first `Task <…>` line (`timestamp` field against the tap's
wall clock). Then check a marker:
`xcrun simctl spawn $UDID logger "chauffeur-marker-1"` (if `logger` doesn't exist in the simulator, try
`xcrun simctl spawn $UDID log` subcommands, and record what exists). Does the marker line reach a stream whose
predicate is `process == "Probe" OR eventMessage CONTAINS "chauffeur-marker"`, and in order after the earlier lines?

- [ ] **Step 6: Clipboard (spec §1 question 7)**

```bash
for i in 1 2 3 4 5 6 7 8 9 10; do /usr/bin/time -p xcrun simctl pbpaste $UDID >/dev/null; done 2>&1 | grep real
$B tap "Copy"; xcrun simctl pbpaste $UDID; $B screenshot
```

Record the median time, that the copied text is read, and whether the screenshot shows a paste banner. Add
`.onReceive(NotificationCenter.default.publisher(for: UIPasteboard.changedNotification)) { _ in last = "pb changed" }`
to the probe, rebuild, read the clipboard again from the host, and record whether `last` changes.

- [ ] **Step 7: The Dead button's baseline**

`for i in 1 2 3 4 5; do /usr/bin/time -p $B tap "Dead" >/dev/null; done 2>&1 | grep real` — today's no-op time,
the number goal 2 must not regress beyond step 0's measured minimum.

- [ ] **Step 8: Repeat on iOS 26**

Shut the iOS 27 simulator down, boot an iOS 26 one, and repeat Steps 3–7 briefly: the same buttons, noting only what
differs.

- [ ] **Step 9: Write the Findings**

Replace `To be filled in by step 0.` in the spec with one subsection per question (`### 1. Per-process connection
data`, … `### 7. Clipboard`), each giving the answer, the command, and the evidence (a few raw lines or numbers), plus
`### Decision`, which applies the spec §1 outcome list: which layer sources hold, the log level and predicate Plan 2
uses, whether private data is per-subsystem or opt-in, the request window and text-field window defaults, the marker
method, and whether the clipboard check stays. Undo every logging change and run
`xcrun simctl spawn $UDID log config --status`.

- [ ] **Step 10: Commit**

```bash
scripts/check-public.sh docs && git add docs/specs/2026-10-08-m4b-network-and-evidence-design.md
git commit -m "docs: M4b step 0 findings"
```

If the Decision is "the activity layer doesn't work" or "no usable log lines", stop here and bring the findings to the
owner before Task 2 (spec §1 says the design comes back for review).

---

### Task 2: Path shapes

Spec §6.

**Files:**
- Create: `Sources/ChauffeurCore/Network/PathShape.swift`, `Tests/ChauffeurCoreTests/PathShapeTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `PathShape.shape(_ raw: String) -> String` (Plan 2 renders requests with it and Task 3 matches project
  entries against it).

- [ ] **Step 1: Branch**

```bash
cd ~/Developer/repos/chauffeur && git checkout m4b-spec && git checkout -b m4b-foundations
```

- [ ] **Step 2: Write the failing test**

`Tests/ChauffeurCoreTests/PathShapeTests.swift`:

```swift
import Testing

@testable import ChauffeurCore

/// M4b spec §6: the agent sees a path's shape, never its identifiers, query or fragment.
@Suite struct PathShapeTests {
    @Test func queryAndFragmentAreDropped() {
        #expect(PathShape.shape("/search?q=secret&token=abc#top") == "/search")
        #expect(PathShape.shape("/search#top") == "/search")
    }

    @Test func numbersAndUUIDsBecomeIds() {
        #expect(PathShape.shape("/users/8812/orders") == "/users/{id}/orders")
        #expect(PathShape.shape("/items/3F2504E0-4F89-11D3-9A0C-0305E82C3301") == "/items/{id}")
    }

    @Test func emailsAndTokensAreCollapsed() {
        #expect(PathShape.shape("/reset/sam@example.com/7f3a9c1e5b2d4f60a8b1") == "/reset/{email}/{token}")
        #expect(PathShape.shape("/s/aGVsbG8gd29ybGQ9PT0x") == "/s/{token}")
    }

    @Test func percentEncodedEmailIsCollapsed() {
        #expect(PathShape.shape("/reset/sam%40example.com") == "/reset/{email}")
    }

    @Test func ordinarySegmentsStay() {
        #expect(PathShape.shape("/account-settings-overview") == "/account-settings-overview")
        #expect(PathShape.shape("/v2/users") == "/v2/users")
        #expect(PathShape.shape("/api/orders/") == "/api/orders/")
    }

    @Test func emptyIsRoot() {
        #expect(PathShape.shape("") == "/")
        #expect(PathShape.shape("?q=1") == "/")
        #expect(PathShape.shape("/") == "/")
    }
}
```

- [ ] **Step 3: Run it to verify it fails**

Run: `swift test --filter PathShapeTests 2>&1 | tail -5`
Expected: build error, `cannot find 'PathShape' in scope`.

- [ ] **Step 4: Write `PathShape`**

`Sources/ChauffeurCore/Network/PathShape.swift`:

```swift
import Foundation

/// A request path as an agent may see it (M4b spec §6): no query or fragment, and segments that identify a person or
/// a secret collapsed to `{id}`, `{token}` or `{email}`.
public enum PathShape {
    public static func shape(_ raw: String) -> String {
        let path = raw.prefix { $0 != "?" && $0 != "#" }
        guard !path.isEmpty else { return "/" }
        return path.split(separator: "/", omittingEmptySubsequences: false).map { segment(String($0)) }
            .joined(separator: "/")
    }

    static func segment(_ s: String) -> String {
        guard !s.isEmpty else { return s }
        if s.contains("@") || s.lowercased().contains("%40") { return "{email}" }
        if s.allSatisfy({ $0.isASCII && $0.isNumber }) || UUID(uuidString: s) != nil { return "{id}" }
        // Hex and base64 runs: long, made of token characters, and mixing in a digit (a slug has none).
        if s.count >= 16, s.contains(where: { $0.isASCII && $0.isNumber }),
            s.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "-_=+.".contains($0)) })
        {
            return "{token}"
        }
        return s
    }
}
```

**Ruling recorded in the plan:** the spec says "hex or base64 runs of 16 or more characters"; a token must also
contain a digit, or every long slug (`/account-settings-overview`) would collapse. Cost if wrong: a long all-letter
token stays visible; stage 2's identifier check (spec Staging) closes that.

- [ ] **Step 5: Run it to verify it passes**

Run: `scripts/format.sh && swift test --filter PathShapeTests 2>&1 | tail -3`
Expected: `Test run with 6 tests in 1 suite passed`.

- [ ] **Step 6: Commit**

```bash
git add Sources/ChauffeurCore/Network/PathShape.swift Tests/ChauffeurCoreTests/PathShapeTests.swift
git commit -m "Path shapes: drop queries, collapse ids, tokens and emails"
```

---

### Task 3: Telemetry list and the project config

Spec §4.

**Files:**
- Create: `Sources/ChauffeurCore/Network/Telemetry.swift`, `Tests/ChauffeurCoreTests/TelemetryTests.swift`
- Modify: `Sources/ChauffeurCore/Target.swift` (`readConfig`, `writeConfig`, new `telemetryHosts`)
- Test: `Tests/ChauffeurCoreTests/TargetTests.swift`

**Interfaces:**
- Consumes: `PathShape.shape(_:)` (Task 2).
- Produces: `Telemetry.builtIn: [String]`; `Telemetry.isTelemetry(host: String, path: String?, extra: [String]) ->
  Bool` (`path` is a raw path or nil when unknown; matching uses its shape); `Target.telemetryHosts(from dir: URL) ->
  [String]`. `Target.writeConfig(udid:in:)` keeps the file's other keys.

- [ ] **Step 1: Write the failing tests**

`Tests/ChauffeurCoreTests/TelemetryTests.swift`:

```swift
import Testing

@testable import ChauffeurCore

/// M4b spec §4: telemetry never turns a dead button into PENDING.
@Suite struct TelemetryTests {
    @Test func builtInHostsMatchBySuffix() {
        #expect(Telemetry.isTelemetry(host: "app-measurement.com", path: "/a", extra: []))
        #expect(Telemetry.isTelemetry(host: "o123.ingest.sentry.io", path: nil, extra: []))
        #expect(Telemetry.isTelemetry(host: "API.MIXPANEL.COM", path: "/track", extra: []))
        #expect(!Telemetry.isTelemetry(host: "api.example.com", path: "/login", extra: []))
    }

    @Test func suffixesMatchWholeLabels() {
        #expect(!Telemetry.isTelemetry(host: "notsentry.io", path: nil, extra: []))
        #expect(!Telemetry.isTelemetry(host: "sentry.io.example.com", path: nil, extra: []))
    }

    @Test func projectEntriesAddHostsAndPathPrefixes() {
        let extra = ["events.example.com", "example.com/metrics"]
        #expect(Telemetry.isTelemetry(host: "events.example.com", path: "/x", extra: extra))
        #expect(Telemetry.isTelemetry(host: "api.example.com", path: "/metrics/batch?k=1", extra: extra))
        #expect(!Telemetry.isTelemetry(host: "api.example.com", path: "/login", extra: extra))
    }

    @Test func pathPrefixesMatchWholeSegments() {
        #expect(!Telemetry.isTelemetry(host: "example.com", path: "/metricsfoo", extra: ["example.com/metrics"]))
        #expect(Telemetry.isTelemetry(host: "example.com", path: "/metrics", extra: ["example.com/metrics"]))
    }

    @Test func aPathEntryNeedsAKnownPath() {
        #expect(!Telemetry.isTelemetry(host: "example.com", path: nil, extra: ["example.com/metrics"]))
    }

    @Test func pathEntriesMatchTheShape() {
        #expect(Telemetry.isTelemetry(host: "example.com", path: "/u/8812/events", extra: ["example.com/u/{id}/events"]))
    }

    @Test func theBuiltInListIsLowercaseAndUnique() {
        #expect(Telemetry.builtIn.count >= 25)
        #expect(Set(Telemetry.builtIn).count == Telemetry.builtIn.count)
        #expect(Telemetry.builtIn.allSatisfy { $0 == $0.lowercased() && !$0.contains("/") })
    }
}
```

Add to `Tests/ChauffeurCoreTests/TargetTests.swift`, inside the suite (it already has a temp-directory pattern in
`configIsFoundFromSubdirectories`; reuse it):

```swift
    @Test func useKeepsOtherKeys() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cht-keep-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent(Target.configName)
        try Data(#"{"udid":"AAAA-1","telemetryHosts":["events.example.com"]}"#.utf8).write(to: file)
        try Target.writeConfig(udid: "BBBB-2", in: root)
        #expect(Target.readConfig(from: root) == "BBBB-2")
        #expect(Target.telemetryHosts(from: root) == ["events.example.com"])
    }

    @Test func telemetryHostsAreFoundFromSubdirectories() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cht-tel-\(UUID().uuidString)")
        let sub = root.appendingPathComponent("a/b")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(Target.telemetryHosts(from: sub).isEmpty)
        try Data(#"{"telemetryHosts":["x.example.com","example.com/m"]}"#.utf8)
            .write(to: root.appendingPathComponent(Target.configName))
        #expect(Target.telemetryHosts(from: sub) == ["x.example.com", "example.com/m"])
    }
```

Check `TargetTests.swift` imports `Foundation`; add `import Foundation` at the top if it doesn't.

- [ ] **Step 2: Run them to verify they fail**

Run: `swift test --filter "TelemetryTests|TargetTests" 2>&1 | tail -5`
Expected: build errors, `cannot find 'Telemetry' in scope` and `type 'Target' has no member 'telemetryHosts'`.

- [ ] **Step 3: Write `Telemetry`**

`Sources/ChauffeurCore/Network/Telemetry.swift`:

```swift
import Foundation

/// Hosts whose requests are telemetry (analytics, crash reporting, attribution): they never make a tap PENDING
/// (M4b spec §4). One per line, so a PR can add one.
public enum Telemetry {
    public static let builtIn: [String] = [
        "app-measurement.com",
        "google-analytics.com",
        "firebaselogging-pa.googleapis.com",
        "firebaselogging.googleapis.com",
        "crashlytics.com",
        "crashlyticsreports-pa.googleapis.com",
        "sentry.io",
        "segment.io",
        "segment.com",
        "amplitude.com",
        "mixpanel.com",
        "appsflyer.com",
        "appsflyersdk.com",
        "adjust.com",
        "adjust.world",
        "branch.io",
        "datadoghq.com",
        "datadoghq.eu",
        "newrelic.com",
        "nr-data.net",
        "bugsnag.com",
        "instabug.com",
        "heapanalytics.com",
        "posthog.com",
        "fullstory.com",
        "logrocket.io",
        "lr-ingest.io",
        "hotjar.com",
        "rollbar.com",
        "flurry.com",
        "kochava.com",
        "singular.net",
    ]

    /// `extra` holds a project's entries: a domain suffix, optionally followed by a path prefix
    /// (`example.com/metrics`), matched against the path's shape. A path entry never matches an unknown path.
    public static func isTelemetry(host: String, path: String?, extra: [String]) -> Bool {
        let host = host.lowercased()
        let shaped = path.map(PathShape.shape)
        return (builtIn + extra).contains { entry in
            let parts = entry.lowercased().split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
            let domain = String(parts[0])
            guard host == domain || host.hasSuffix("." + domain) else { return false }
            guard parts.count == 2 else { return true }
            guard let shaped else { return false }
            let prefix = "/" + parts[1]
            return shaped == prefix || shaped.hasPrefix(prefix + "/")
        }
    }
}
```

- [ ] **Step 4: Update `Target`**

In `Sources/ChauffeurCore/Target.swift`, replace `readConfig` and `writeConfig` with:

```swift
    /// Looks for `.chauffeur.json` in `dir` and its ancestors: the nearest one that sets `udid`.
    public static func readConfig(from dir: URL) -> String? {
        nearest(from: dir) { $0["udid"] as? String }
    }

    /// The project's own telemetry entries (M4b spec §4): the nearest `.chauffeur.json` that sets `telemetryHosts`.
    public static func telemetryHosts(from dir: URL) -> [String] {
        nearest(from: dir) { $0["telemetryHosts"] as? [String] } ?? []
    }

    static func nearest<T>(from dir: URL, _ pick: ([String: Any]) -> T?) -> T? {
        var current = dir.standardizedFileURL
        while true {
            if let object = config(in: current), let value = pick(object) { return value }
            // Directory URLs walk "/" → "/.." → "/../..", so stop at the root explicitly.
            if current.path == "/" { return nil }
            current = current.deletingLastPathComponent().standardizedFileURL
        }
    }

    static func config(in dir: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent(configName)) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// Sets `udid` in `dir`'s `.chauffeur.json`, keeping every other key (`chauffeur use`).
    public static func writeConfig(udid: String, in dir: URL) throws {
        var object = config(in: dir) ?? [:]
        object["udid"] = udid
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: dir.appendingPathComponent(configName))
    }
```

- [ ] **Step 5: Run them to verify they pass**

Run: `scripts/format.sh && swift test --filter "TelemetryTests|TargetTests" 2>&1 | tail -3`
Expected: all pass (7 telemetry tests plus the target suite, including `configIsFoundFromSubdirectories` and
`noConfigAnywhereEndsAtTheRoot` unchanged).

- [ ] **Step 6: Commit**

```bash
git add Sources/ChauffeurCore/Network/Telemetry.swift Sources/ChauffeurCore/Target.swift \
  Tests/ChauffeurCoreTests/TelemetryTests.swift Tests/ChauffeurCoreTests/TargetTests.swift
git commit -m "Telemetry hosts, built in and per project; chauffeur use keeps the config's other keys"
```

---

### Task 4: Crash first

Spec §8, first bullet.

**Files:**
- Modify: `Sources/ChauffeurCore/Engine/Session+Logs.swift` (`annotate`)
- Test: `Tests/ChauffeurCoreTests/AnnotateTests.swift`, `Tests/ChauffeurCoreTests/Live/LogsLiveTests.swift`

**Interfaces:**
- Consumes: `CrashInfo.render()` (existing; its first line is the `APP CRASHED: …` or `APP EXITED: …` line).
- Produces: an action whose app died now reads `<action> → APP CRASHED: <bundle> (pid N) · <exception or note>` on
  its first line. Exit 5 unchanged.

**Ruling recorded in the plan:** the spec's example headline (`Fixture died 120 ms after the touch (SIGABRT)`) needs a
time of death chauffeur doesn't measure. The headline reuses the crash block's existing first line, which already
carries the bundle, pid and exception. The screen diff stays dropped after a crash, as today: it would only show the
home screen. Cost if wrong: a later task adds the timing.

- [ ] **Step 1: Change the tests first**

In `AnnotateTests.aVanishedAppIsACrashReportedOnce`, the expected text becomes:

```swift
        #expect(
            out.text == """
                tap e5 "Crash" → APP CRASHED: dev.chauffeur.fixture (pid 4321) · crash report not written yet (macOS can take a minute)
                reason: "fixture: crashing"
                logs: [fault] "fixture: crashing"
                hint: after fixing it, rebuild, chauffeur install <path.app>, then chauffeur launch dev.chauffeur.fixture
                """)
```

In `aReadReportIsShownWithItsFrames`, the expectation becomes:

```swift
        #expect(
            out.text.hasPrefix(
                "tap e5 \"Crash\" → APP CRASHED: dev.chauffeur.fixture (pid 4321) · EXC_BREAKPOINT (SIGTRAP)\nreport: /r/Fixture.ips\n  libswiftCore.dylib"
            ))
```

Add a test that an action result without an arrow (defensive) keeps its first line and the block below it:

```swift
    @Test func aResultWithoutAnArrowKeepsItsFirstLine() {
        let out = session(alive: false).annotate(Output("done\nmore"), since: 0, logs: true)
        #expect(out.text.hasPrefix("done\nAPP EXITED: dev.chauffeur.fixture (pid 4321)"))
    }
```

In `Tests/ChauffeurCoreTests/Live/LogsLiveTests.swift:33`, `"\nAPP CRASHED: dev.chauffeur.fixture (pid "` becomes
`"→ APP CRASHED: dev.chauffeur.fixture (pid "`.

- [ ] **Step 2: Run them to verify they fail**

Run: `swift test --filter AnnotateTests 2>&1 | grep -E "✘|failed|passed" | head`
Expected: `aVanishedAppIsACrashReportedOnce` and `aReadReportIsShownWithItsFrames` fail (the crash is still on line 2);
`aResultWithoutAnArrowKeepsItsFirstLine` passes already (that's today's behavior, kept).

- [ ] **Step 3: Implement**

In `annotate` (`Session+Logs.swift`), replace:

```swift
        if let crashed {
            // An action's diff after a crash would only show the home screen; a crash noticed before the command ran
            // leaves the command's own result (launch, terminate…) intact.
            if logs && noticed == nil { out.text = String(out.text.prefix { $0 != "\n" }) }
            extra += crashed.render()
            data["crash"] = crashed.json
        }
```

with:

```swift
        if let crashed {
            var block = crashed.render()
            // An action's diff after a crash would only show the home screen, and its verdict is moot: the crash leads
            // the first line, where agents look (M4b spec §8). A crash noticed before the command ran leaves the
            // command's own result (launch, terminate…) intact.
            if logs && noticed == nil {
                let first = out.text.prefix { $0 != "\n" }
                if let arrow = first.range(of: " → ") {
                    out.text = String(first[..<arrow.lowerBound]) + " → " + block.removeFirst()
                } else {
                    out.text = String(first)
                }
            }
            extra += block
            data["crash"] = crashed.json
        }
```

- [ ] **Step 4: Run them to verify they pass**

Run: `scripts/format.sh && swift test --filter "AnnotateTests|CrashTests" 2>&1 | tail -2`
Expected: all pass.

- [ ] **Step 5: Update the agent-facing text**

`grep -rn "APP CRASHED" Sources/ChauffeurCore/Agent` and check that no line says the crash appears on a later line;
if one does, change it to say the crash leads the result. Then `swift test --filter "SkillTests|MCPTests" 2>&1 | tail -2`
→ pass.

- [ ] **Step 6: Commit**

```bash
git add Sources/ChauffeurCore/Engine/Session+Logs.swift Sources/ChauffeurCore/Agent \
  Tests/ChauffeurCoreTests/AnnotateTests.swift Tests/ChauffeurCoreTests/Live/LogsLiveTests.swift
git commit -m "A crash leads the action's result"
```

---

### Task 5: Relaunch an app opened from its icon

Spec §8, second bullet.

**Files:**
- Create: `Sources/ChauffeurCore/Engine/Session+Recover.swift`, `Tests/ChauffeurCoreTests/RecoverTests.swift`
- Modify: `Sources/ChauffeurCore/Errors.swift` (new case), `Sources/ChauffeurCore/Device/SimApps.swift`
  (`runningApps`), `Sources/ChauffeurCore/Device/AXHealth.swift` (`relaunchTarget`),
  `Sources/ChauffeurCore/Engine/Session.swift` (three stored properties; `observe`; `runOne`),
  `Sources/ChauffeurCore/Engine/Session+Batch.swift` (`inBatch`)

**Interfaces:**
- Consumes: `launchCommand(_:)` (existing), `AXProvider.read()` (existing; the frontmost root, whose `label` is the
  app's display name), `SimApps.appInfo(_:)` (existing).
- Produces: `ChauffeurError.needsRelaunch(bundle: String, why: String)`; `SimApps.runningApps(_ launchctlList:
  String) -> [String]`; `AXHealth.relaunchTarget(frontLabel: String?, running: [(bundle: String, displayName:
  String)]) -> String?`; `Session.withRelaunch(_:)`; `Session.inBatch: Bool`.

- [ ] **Step 1: Write the failing tests**

`Tests/ChauffeurCoreTests/RecoverTests.swift`:

```swift
import Foundation
import Testing

@testable import ChauffeurCore

/// M4b spec §8: an app opened from its icon has no accessibility tree; chauffeur relaunches it once, never in a batch.
@Suite @MainActor struct RecoverTests {
    let list = """
        PID\tStatus\tLabel
        412\t0\tcom.apple.SpringBoard
        9031\t0\tUIKitApplication:dev.chauffeur.fixture[5b1c][rb-legacy]
        -\t0\tUIKitApplication:com.apple.mobilesafari[77aa][rb-legacy]
        9120\t0\tUIKitApplication:com.apple.Preferences[0c3d][rb-legacy]
        """

    @Test func runningAppsAreTheUIKitApplicationsWithAPid() {
        #expect(SimApps.runningApps(list) == ["dev.chauffeur.fixture", "com.apple.Preferences"])
    }

    @Test func theFrontAppIsFoundByItsDisplayName() {
        let running = [(bundle: "dev.chauffeur.fixture", displayName: "Fixture"),
                       (bundle: "com.apple.Preferences", displayName: "Settings")]
        #expect(AXHealth.relaunchTarget(frontLabel: "Fixture", running: running) == "dev.chauffeur.fixture")
    }

    @Test func ambiguousOrUnknownAppIsNotRelaunched() {
        let twins = [(bundle: "a.one", displayName: "Twin"), (bundle: "a.two", displayName: "Twin")]
        #expect(AXHealth.relaunchTarget(frontLabel: "Twin", running: twins) == nil)
        #expect(AXHealth.relaunchTarget(frontLabel: "Other", running: twins) == nil)
        #expect(AXHealth.relaunchTarget(frontLabel: nil, running: twins) == nil)
    }

    func session() -> Session {
        Session(udid: "ZZ" + String(format: "%06X", UInt32.random(in: 0...0xFFFFFF)) + "-TEST")
    }

    @Test func aBlindAppIsRelaunchedOnceAndTheCommandRetried() throws {
        let s = session()
        var launched: [String] = []
        s.relaunch = { launched.append($0); return Output("launch \($0) → ok") }
        var calls = 0
        let out = try s.withRelaunch {
            calls += 1
            if calls == 1 { throw ChauffeurError.needsRelaunch(bundle: "dev.chauffeur.fixture", why: "blind") }
            return Output("app \"Fixture\" · rev 1")
        }
        #expect(launched == ["dev.chauffeur.fixture"] && calls == 2)
        #expect(
            out.text == "app \"Fixture\" · rev 1\nnote: relaunched dev.chauffeur.fixture — it was opened from its "
                + "icon without accessibility; its in-app state was reset")
        // The same app going blind again in this session is not relaunched a second time.
        #expect(throws: ChauffeurError.blind("blind")) {
            try s.withRelaunch { throw ChauffeurError.needsRelaunch(bundle: "dev.chauffeur.fixture", why: "blind") }
        }
        #expect(launched.count == 1)
    }

    @Test func neverInsideABatch() {
        let s = session()
        s.inBatch = true
        var launched = 0
        s.relaunch = { _ in launched += 1; return Output("ok") }
        #expect(throws: ChauffeurError.blind("blind")) {
            try s.withRelaunch { throw ChauffeurError.needsRelaunch(bundle: "x.y", why: "blind") }
        }
        #expect(launched == 0)
    }

    @Test func aFailedRelaunchGivesTodaysMessage() {
        let s = session()
        s.relaunch = { _ in Output("launch x.y → FAILED: nope", exit: 1) }
        #expect(throws: ChauffeurError.blind("blind")) {
            try s.withRelaunch { throw ChauffeurError.needsRelaunch(bundle: "x.y", why: "blind") }
        }
    }

    @Test func needsRelaunchReadsAsItsReason() {
        #expect(ChauffeurError.needsRelaunch(bundle: "x.y", why: "relaunch it").description == "relaunch it")
    }
}
```

- [ ] **Step 2: Run them to verify they fail**

Run: `swift test --filter RecoverTests 2>&1 | tail -5`
Expected: build errors (`runningApps`, `relaunchTarget`, `needsRelaunch`, `relaunch`, `withRelaunch`, `inBatch`
don't exist).

- [ ] **Step 3: The error case**

In `Sources/ChauffeurCore/Errors.swift`, add after `case blind(String)`:

```swift
    /// The app in front has no tree and chauffeur knows which app it is: `withRelaunch` can recover (M4b spec §8).
    case needsRelaunch(bundle: String, why: String)
```

and in `description`, beside `case .blind(let why): return why`:

```swift
        case .needsRelaunch(_, let why):
            return why
```

- [ ] **Step 4: `SimApps.runningApps` and `AXHealth.relaunchTarget`**

In `Sources/ChauffeurCore/Device/SimApps.swift`, after `springBoardPID`:

```swift
    /// The bundle ids of running apps (a pid, and a `UIKitApplication:<bundle>[…]` label) in `launchctl list`.
    public static func runningApps(_ launchctlList: String) -> [String] {
        launchctlList.split(separator: "\n").compactMap { line in
            let cols = line.split(separator: "\t")
            guard cols.count == 3, Int32(cols[0]) != nil, cols[2].hasPrefix("UIKitApplication:") else { return nil }
            return String(cols[2].dropFirst("UIKitApplication:".count).prefix { $0 != "[" })
        }
    }
```

In `Sources/ChauffeurCore/Device/AXHealth.swift`, inside the enum:

```swift
    /// The running app whose display name is the empty front app's label; nil unless exactly one matches.
    public static func relaunchTarget(frontLabel: String?, running: [(bundle: String, displayName: String)]) -> String?
    {
        guard let frontLabel else { return nil }
        let matches = running.filter { $0.displayName == frontLabel }
        return matches.count == 1 ? matches[0].bundle : nil
    }
```

- [ ] **Step 5: Session state, `withRelaunch`, and wiring**

In `Sources/ChauffeurCore/Engine/Session.swift`, after `var healNote: String?`'s declaration, add:

```swift
    /// Inside `do`: a blind app is not relaunched, because resetting its state would corrupt the flow (M4b spec §8).
    var inBatch = false
    /// Apps relaunched for accessibility this session: at most once each.
    var relaunchedForAccessibility: Set<String> = []
    /// Seam for unit tests: how an app is relaunched (default: `launchCommand`).
    var relaunch: ((String) -> Output)?
```

Create `Sources/ChauffeurCore/Engine/Session+Recover.swift`:

```swift
import Foundation

extension Session {
    /// Runs `body`; when the app in front turns out to have been opened from its icon without accessibility, relaunches
    /// it through `launch` (which also follows its log) and runs `body` once more (M4b spec §8). Never inside a batch,
    /// at most once per app per session; otherwise today's message.
    func withRelaunch(_ body: () throws -> Output) throws -> Output {
        do {
            return try body()
        } catch ChauffeurError.needsRelaunch(let bundle, let why) {
            guard !inBatch, !relaunchedForAccessibility.contains(bundle) else { throw ChauffeurError.blind(why) }
            relaunchedForAccessibility.insert(bundle)
            let launched = relaunch?(bundle) ?? guarded { try launchCommand([bundle]) }
            guard launched.exit == 0 else { throw ChauffeurError.blind(why) }
            var out = try body()
            out.text +=
                "\nnote: relaunched \(bundle) — it was opened from its icon without accessibility; its in-app state "
                + "was reset"
            return out
        }
    }

    /// The bundle id of the empty app in front, when exactly one running app has its display name.
    func relaunchCandidate(_ ax: AXProvider) -> String? {
        guard let label = ax.read()?.label,
            let list = try? SimCtl.run(["spawn", udid, "launchctl", "list"]).out
        else { return nil }
        let running = SimApps.runningApps(list).compactMap { bundle -> (bundle: String, displayName: String)? in
            guard let out = try? SimCtl.run(["appinfo", udid, bundle], timeout: 30).out,
                let info = SimApps.appInfo(out)
            else { return nil }
            return (bundle, info.displayName)
        }
        return AXHealth.relaunchTarget(frontLabel: label, running: running)
    }
}
```

In `observe` (`Session.swift`), replace

```swift
            if plan.relaunchApp { throw ChauffeurError.blind(AXHealth.message(plan, recovered: false)) }
```

with

```swift
            if plan.relaunchApp {
                let why = AXHealth.message(plan, recovered: false)
                if let bundle = relaunchCandidate(ax) { throw ChauffeurError.needsRelaunch(bundle: bundle, why: why) }
                throw ChauffeurError.blind(why)
            }
```

In `runOne`, replace

```swift
        var output = guarded {
            commandHook?(command)
            return try dispatch(command, Array(argv.dropFirst()))
        }
```

with

```swift
        var output = guarded {
            try withRelaunch {
                commandHook?(command)
                return try dispatch(command, Array(argv.dropFirst()))
            }
        }
```

In `batchCommand` (`Session+Batch.swift`), as the first line of the body:

```swift
        inBatch = true
        defer { inBatch = false }
```

- [ ] **Step 6: Run the tests and the line counts**

Run: `scripts/format.sh && swift test --filter "RecoverTests|AXHealthTests|BatchTests" 2>&1 | tail -2 && wc -l Sources/ChauffeurCore/Engine/Session.swift`
Expected: all pass; `Session.swift` under 400 lines.

- [ ] **Step 7: Check it live**

```bash
B=.build/debug/chauffeur; swift build
xcrun simctl spawn $UDID defaults write com.apple.Accessibility ApplicationAccessibilityEnabled -bool false
xcrun simctl terminate $UDID dev.chauffeur.fixture; xcrun simctl launch $UDID dev.chauffeur.fixture
xcrun simctl spawn $UDID defaults write com.apple.Accessibility ApplicationAccessibilityEnabled -bool true
$B snapshot | tail -3
```

Expected: the snapshot shows the fixture's home screen and ends with `note: relaunched dev.chauffeur.fixture — it was
opened from its icon without accessibility; its in-app state was reset`. If chauffeur's healing re-enables the flag
before the app is judged empty, the note still appears because the app started with it off. Ledger the output. If it
doesn't reproduce, ledger exactly what happened and keep the unit tests as the gate.

- [ ] **Step 8: Commit**

```bash
git add Sources/ChauffeurCore/Errors.swift Sources/ChauffeurCore/Device/SimApps.swift \
  Sources/ChauffeurCore/Device/AXHealth.swift Sources/ChauffeurCore/Engine/Session.swift \
  Sources/ChauffeurCore/Engine/Session+Recover.swift Sources/ChauffeurCore/Engine/Session+Batch.swift \
  Tests/ChauffeurCoreTests/RecoverTests.swift
git commit -m "Relaunch an app opened from its icon without accessibility, once, never in a batch"
```

---

### Task 6: Roadmap, changelog, and the PR

**Files:**
- Modify: `docs/roadmap.md`, `CHANGELOG.md`

**Interfaces:**
- Consumes: Tasks 2–5.
- Produces: PR "M4b part 1: step 0 findings and foundations".

- [ ] **Step 1: Roadmap**

In `docs/roadmap.md`: the M4a row becomes `done`; the M4b row becomes `| M4b: network requests and other evidence |
in progress | YashNaj |`. Replace the `## M4b: edge cases` section's bullets with:

```markdown
Spec: `docs/specs/2026-10-08-m4b-network-and-evidence-design.md`.

- [x] Step 0: what the Mac and the logs show (Findings in the spec)
- [x] Path shapes, telemetry hosts, crash first, relaunching an app opened from its icon
- [ ] Network activity and detail layers, `PENDING`, `wait`, batches, clipboard (Plan 2)
- [ ] 0.2.0

## Network visibility (stage 2, after M4b)

Method, path and status for apps that don't use Apple's networking stack, opt-in bodies, a `network` command, and
names in paths, through a small library chauffeur loads into apps it launches. Its own spec and security review.
```

- [ ] **Step 2: Changelog**

At the top of `CHANGELOG.md`, under `# Changelog`:

```markdown
## Unreleased (0.2.0)

- A crash now leads the action's result: `tap Pay → APP CRASHED: …` on the first line.
- An app opened from its home-screen icon without accessibility is relaunched once, with a note; never inside `do`.
- `chauffeur use` keeps the other keys in `.chauffeur.json`, including the new `telemetryHosts`.
```

- [ ] **Step 3: Full check and commit**

```bash
scripts/check.sh 2>&1 | tail -1
scripts/check-public.sh . && git add docs/roadmap.md CHANGELOG.md && git commit -m "Roadmap and changelog: M4b part 1"
scripts/check-commits.sh origin/main..HEAD
```

Expected: `check: all passed`; commits clean.

- [ ] **Step 4: Ask the owner, then push and open the PR**

**Owner approval:** push `m4b-foundations` and open the PR (it includes the spec, both plans' commits so far and the
Findings):

```bash
git push -u origin m4b-foundations
gh pr create --title "M4b part 1: step 0 findings and foundations" --body "Spec and step 0 findings for M4b, plus path shapes, telemetry hosts, crash-first results and relaunching icon-opened apps. Plan 2 (network layers, PENDING) follows from the findings."
gh pr checks --watch
```

Merge only with the owner's go-ahead: `gh pr merge --squash --admin`.

---

## Plan 2 (written after Task 1)

From the Findings: `ConnectionWatch` (activity), `RequestLog` (detail), matching the two, the evidence-is-current
check, the text-field window, the result rules and rendering (with `PathShape` and `Telemetry`, quoting hosts and
paths like screen text), exit 6 and the JSON `requests` array, bare `chauffeur wait` and `wait "<query>"` timeouts,
batches through `PENDING`, the private-data setting and `doctor --fix network` / `--undo-logging`, the clipboard
check, the fixture app's Network screen with the local server, the live tests, the skill and MCP text,
`docs/design.md`, and the 0.2.0 release (spec §10).
