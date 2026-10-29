# Refactor Plan 1: foundations and the pipeline (stages 0, 1a, 1b, 2)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Pin every output with golden tests, inject `Session`'s dependencies so the engine runs offline, and turn the
tap path into one pipeline of evidence passes, with no verdict and no user-visible text changing except the Doctor
wording ruling in the spec's §9.

**Architecture:** Four pull requests, one per stage, each leaving `main` green. Stage 0 records the goldens, adds
`ExitCode` and injects the clock. Stage 1a adds `SessionEnvironment` (device, accessibility, touch evidence, shell,
flows, processes) and the first offline tests of `observe`, `baseline` and `wait`. Stage 1b adds the one HID wrapper,
the log seam and offline tests of `act` and every gesture, and routes Doctor through the wrappers. Stage 2 makes the
classify step pluggable, turns the four hand-written verdict upgrades into evidence passes sharing one `credit`, and
puts network judgment in one `NetworkWatch`. Plan 2 (stages 3 to 5: the command registry, the bridge internals,
perception for web views) is written after this plan lands.

**Tech Stack:** Swift 6 (SwiftPM, Swift Testing), the Objective-C bridge untouched in this plan, `scripts/check.sh`,
live tests on a booted iOS 27 simulator.

**Spec:** `docs/specs/2026-10-27-refactor-one-way-design.md`

## Global Constraints

- Private API only in `Sources/ChauffeurBridge`; no `try!` or `print` in `Sources`; files under 400 lines in `Sources`
  and 600 in `Tests` (this plan aims for under 300 in `Sources`).
- Fakes go behind seams (protocols, `SessionEnvironment`, recorded trees under `Tests/ChauffeurCoreTests/Fixtures`),
  never as flags in production code.
- No verdict changes. No user-visible text changes except §9's Doctor ruling (Task 13). A golden test that fails is a
  bug in the task, never a reason to re-record the golden.
- After every stage that touches `Engine`, `Device`, `Perception`, `Screen` or the bridge (all four here), run
  `CHAUFFEUR_LIVE_UDID=<udid> swift test --no-parallel` on a booted iOS 27 simulator with load under 10 and nothing
  else building.
- Every stage ends with `scripts/check.sh` passing, a branch, a PR, and a merge before the next stage starts.
- Commit with the noreply identity; no AI co-author trailer.

## Review Focus

1. `wait --timeout 600` must still wait 300 s, not fail usage (Task 9 pins it offline: the clamp is `Session.waitTimeout`).
2. A session whose accessibility source returns no tree for longer than `AXHealth.patienceMs` must still heal
   (flags, bridge restart) through the shell seam, not silently stop (Task 8 pins `heal` offline).
3. A transport whose send fails must drop the HID client and rebuild it on the next action, as today (Task 12).
4. A tap on a screen with an unattached touch log must come back UNVERIFIED, never `changed` (Task 12).
5. After Stage 2, the evidence screenshot must exist exactly when the final verdict is NO EFFECT and never when a
   pass upgraded it (Task 16).

---

## Stage 0: goldens, exit codes, the clock

Branch `refactor-0-goldens`. PR title: "Refactor 0: golden tests, ExitCode, an injectable clock".

### Task 1: Golden tests for agent-facing text

**Files:**
- Create: `Tests/ChauffeurCoreTests/Golden/Golden.swift`, `Tests/ChauffeurCoreTests/Golden/GoldenTextTests.swift`
- Create (recorded): `Tests/ChauffeurCoreTests/Fixtures/golden/usage.txt`, `skill.md`, `agents.md`,
  `mcp-instructions.txt`, `mcp-tools.json`
- Modify: `Package.swift` (the `Fixtures` resource copy already covers the new folder; verify)

**Interfaces:**
- Produces: `enum Golden { static func check(_ name: String, _ actual: String, sourceLocation: SourceLocation = #_sourceLocation) }`
  which compares `actual` byte for byte with `Fixtures/golden/<name>` and fails with a unified diff of the first
  differing 20 lines. With `CHAUFFEUR_GOLDEN_RECORD=1` in the environment it writes the file (into the source tree,
  via `#filePath`) instead of comparing. Every later task uses it.

- [ ] **Step 1: Write `Golden.check` and the five tests**

```swift
@Suite struct GoldenTextTests {
    @Test func usage() { Golden.check("usage.txt", Usage.text) }
    @Test func skill() { Golden.check("skill.md", Skill.skillMarkdown) }
    @Test func agentsSection() { Golden.check("agents.md", Skill.agentsSection) }
    @Test func mcpInstructions() { Golden.check("mcp-instructions.txt", MCPServer.instructions) }
    @Test func mcpTools() { Golden.check("mcp-tools.json", MCPTools.definitions.jsonLine()) }  // sorted keys
}
```

If `MCPTools.definitions` isn't the name of the tool list, use the existing accessor; the JSON must be rendered with
sorted keys so the golden is stable (add `JSON.canonical` if `jsonLine()` isn't deterministic).

- [ ] **Step 2: Run to verify they fail** (no golden files yet)

Run: `swift test --filter GoldenTextTests`
Expected: 5 failures, each "no golden Fixtures/golden/<name>; record with CHAUFFEUR_GOLDEN_RECORD=1"

- [ ] **Step 3: Record**

Run: `CHAUFFEUR_GOLDEN_RECORD=1 swift test --filter GoldenTextTests && git status --short Tests/ChauffeurCoreTests/Fixtures/golden`
Expected: five new files

- [ ] **Step 4: Run to verify they pass without recording**

Run: `swift test --filter GoldenTextTests`
Expected: 5 passes

- [ ] **Step 5: Commit**

```bash
git add Tests/ChauffeurCoreTests/Golden Tests/ChauffeurCoreTests/Fixtures/golden
git commit -m "Golden tests for the usage text, the skill, the AGENTS section and the MCP surface"
```

### Task 2: Golden tests for rendered reports, and the live expectations ledger

**Files:**
- Create: `Tests/ChauffeurCoreTests/Golden/GoldenReportTests.swift`
- Create (recorded): `Tests/ChauffeurCoreTests/Fixtures/golden/reports/<case>.txt` and `<case>.json`
- Create: `scripts/live-expectations.sh`, `docs/plans/2026-10-27-refactor-live-expectations.md`

**Interfaces:**
- Produces: `enum ReportCases { static let all: [(name: String, report: any ReportRendering)] }` where the cases are
  built from fixtures, one per shape: `changed-diff`, `changed-copy`, `changed-via-retry`, `noeffect-plain`,
  `noeffect-failed-request`, `noeffect-success-no-change`, `noeffect-telemetry`, `pending`, `intercepted`,
  `not-delivered`, `unverified`, `unattributed`, `type-ok`, `type-mismatch`, `type-ok-with-request`.
  `ReportRendering` is a test-only protocol with `render() -> String` and `json: JSON`, adopted by `ActionReport` and
  `TypeReport` in the test target.

- [ ] **Step 1: Write the cases and the test**

Build each `ActionReport` with the 12-parameter initialiser (`Verifier.swift:108`), fixed values (`settledMs: 420`,
`revBefore: 7`, `capMs: 1500`, `transport: "digitizer"`), the request items from `ReportNetworkTests` (`fail`,
`ping`, `open`), and `hints: Verifier.hints(outcome:target:)` with `target: nil`. For `changed-via-retry` set
`retriedFrom: "digitizer"`, `transport: "mouse"`. For `noeffect-plain` set `evidenceShot: "$TMPDIR/shot.jpg"`.

```swift
@Suite struct GoldenReportTests {
    @Test(arguments: ReportCases.all.map(\.name)) func renders(_ name: String) throws {
        let report = try #require(ReportCases.all.first { $0.name == name }).report
        Golden.check("reports/\(name).txt", report.render())
        Golden.check("reports/\(name).json", report.json.jsonLine())
    }
}
```

- [ ] **Step 2: Run to verify they fail, record, run to verify they pass**

Run: `swift test --filter GoldenReportTests` (fail), then with `CHAUFFEUR_GOLDEN_RECORD=1`, then again (pass).
Expected: 15 × 2 goldens recorded; 15 passes.

- [ ] **Step 3: Write `scripts/live-expectations.sh`**

It greps every `contains("…")`, `hasPrefix("…")` and `== "…"` literal in `Tests/ChauffeurCoreTests/Live/*.swift`,
prefixed by file name, sorted, into `docs/plans/2026-10-27-refactor-live-expectations.md` under a one-line header
saying what it is and the commit it was made from. Run it and commit the output. Each later stage re-runs it and
the diff must be empty except for Task 14's Doctor lines.

- [ ] **Step 4: Commit**

```bash
git add Tests/ChauffeurCoreTests/Golden Tests/ChauffeurCoreTests/Fixtures/golden scripts/live-expectations.sh docs/plans/2026-10-27-refactor-live-expectations.md
git commit -m "Golden tests for rendered reports; the live expectations ledger"
```

### Task 3: `ExitCode` and one error mapping

**Files:**
- Create: `Sources/ChauffeurCore/ExitCode.swift`
- Modify: `Sources/ChauffeurCore/Engine/Args.swift:109` (`Output.init`), `Sources/ChauffeurCore/Engine/Session.swift:309-321`
  (`guarded`), `Sources/ChauffeurCore/CLI.swift:126-134`, `Sources/ChauffeurCore/Agent/MCPServer.swift:140-144`,
  every `exit: <literal>` in `Sources` (33 × 1, 4 × 3, 4 × 4, 6 × 64; `exitCode` in `Verifier.swift:126-130` and
  `:282`), `scripts/check-code.sh`
- Test: `Tests/ChauffeurCoreTests/ExitCodeTests.swift`

**Interfaces:**
- Produces: `public enum ExitCode: Int32, CaseIterable { case ok = 0, error = 1, noEffect = 3, notFound = 4, crashed = 5, pending = 6, usage = 64 }`
  with `public var line: String` (the fragment used in the usage text: "3 action had no verified effect");
  `Output.init(_ text: String, exit: ExitCode, data: JSON? = nil)`;
  `public static func Output.failure(_ error: any Error) -> Output` which is the one mapping: `ChauffeurError.usage`
  → `.usage`, `ChauffeurError`, `RefError`, `ConnectError`, `MCPToolError` → `.error` with their `description`,
  anything else → `.error` with `"\(error)"`.

- [ ] **Step 1: Write the failing tests**

```swift
@Suite struct ExitCodeTests {
    @Test func usageLineIsBuiltFromTheCodes() {
        #expect(Usage.text.contains(ExitCode.allCases.map(\.line).joined(separator: " · ")))
    }
    @Test func oneMappingForEveryErrorKind() {
        #expect(Output.failure(ChauffeurError.usage("usage: x")).exit == ExitCode.usage.rawValue)
        #expect(Output.failure(ChauffeurError.notBooted("U")).exit == 1)
        #expect(Output.failure(RefError.stale("e4", "x")).exit == 1)
        #expect(Output.failure(ConnectError.noKey).exit == 1)
        #expect(Output.failure(MCPToolError(message: "act tap needs target")).text == "act tap needs target")
    }
}
```

Adjust the error constructors to real cases (`grep -n "case " Sources/ChauffeurCore/Model.swift Connect/ConnectError.swift Agent/MCPTools.swift`).

- [ ] **Step 2: Run to verify they fail**

Run: `swift test --filter ExitCodeTests`
Expected: FAIL, `ExitCode` undefined

- [ ] **Step 3: Implement `ExitCode`, `Output.failure`, the usage line from the codes, and replace every literal**

`Usage.text` keeps its exact bytes: build the "exit codes:" line from `ExitCode.allCases` and assert the golden
still passes. `guarded`, `CLI.handleText` and `MCPServer.call` each become one call to `Output.failure`. Add to
`scripts/check-code.sh` the rule `no bare exit-code literals in Sources` (pattern `exit: [0-9]`), with the same
`// check-code: allow` escape as the other rules.

- [ ] **Step 4: Run everything**

Run: `scripts/check.sh 2>&1 | tail -1`
Expected: `check: all passed` (the goldens from Tasks 1 and 2 unchanged)

- [ ] **Step 5: Commit**

```bash
git add Sources scripts/check-code.sh Tests/ChauffeurCoreTests/ExitCodeTests.swift
git commit -m "ExitCode: the six codes in one enum, one error mapping, no bare literals"
```

### Task 4: Inject the clock

**Files:**
- Modify: `Sources/ChauffeurCore/Engine/Session.swift:74` (`let clock = SystemClock()`) and its `init(udid:)`,
  `Session+Act.swift:206` (`usleep` in selftest), `Session+Gestures.swift:62` (`usleep` in `press`),
  `Session+Apps.swift` and `Session+Logs.swift` (`Date()` in launch and `detectCrash`)
- Modify: `Tests/ChauffeurCoreTests/SettleTests.swift:5` (move `FakeClock` to `Support.swift`),
  `Tests/ChauffeurCoreTests/SessionNetworkTests.swift:16` (`session()` builds with `FakeClock`)
- Test: `Tests/ChauffeurCoreTests/SessionNetworkTests.swift`

**Interfaces:**
- Produces: `public init(udid: String, clock: any SettleClock = SystemClock())` on `Session`; `let clock: any SettleClock`.
  `FakeClock` (test target, `Support.swift`): `var now = 0`, `nowMs()`, `sleep(ms:)` advances `now`.

- [ ] **Step 1: Write the failing test**

In `SessionNetworkTests`, change `session()` to `Session(udid: …, clock: FakeClock())` and add:

```swift
@Test func theWindowIsPaidOnTheFakeClockNotTheWall() {
    let clock = FakeClock()
    let s = session(clock: clock)
    var r = report(.noEffect)
    let started = Date()
    s.applyNetwork(&r, net: TapNet(pids: [4321], earlier: [], atTouch: [], logCursor: s.logTap.cursor, touchMs: clock.now), target: nil)
    #expect(Date().timeIntervalSince(started) < 0.2)
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter SessionNetworkTests`
Expected: compile error, `Session` has no `clock:` parameter

- [ ] **Step 3: Implement the injectable clock and route every sleep and `Date()` through it**

`Session.init(udid:clock:)`; `let clock: any SettleClock`. In `press`: `clock.sleep(ms: button.holdMs)`. In selftest:
`clock.sleep(ms: 300)`. For the two `Date()` uses, keep `Date()` where a wall-clock timestamp is written to a file or
compared with a crash report's wall time (`launchedAt`), and use `clock.nowMs()` where a duration is measured; note
each decision in a comment.

- [ ] **Step 4: Run the unit suite and time it**

Run: `time swift test 2>&1 | tail -3`
Expected: all pass; `SessionNetworkTests` total under 0.5 s (was ~2.6 s)

- [ ] **Step 5: Live tests, check, commit, PR**

Run: `CHAUFFEUR_LIVE_UDID=<udid> swift test --no-parallel 2>&1 | grep -E "Suite .* (passed|failed)|Test run"`, then `scripts/check.sh`.
Expected: every suite passes.

```bash
git add -A Sources Tests scripts
git commit -m "Session takes its clock; no unit test sleeps for the network window"
git push -u origin refactor-0-goldens && gh pr create --base main --title "Refactor 0: golden tests, ExitCode, an injectable clock"
```

---

## Stage 1a: the environment and the first offline engine tests

Branch `refactor-1a-environment`. PR title: "Refactor 1a: SessionEnvironment; observe, baseline and wait run offline".

### Task 5: `AXSource`

**Files:**
- Create: `Sources/ChauffeurCore/Device/AXSource.swift`
- Modify: `Sources/ChauffeurCore/Device/AXProvider.swift` (conform), `Sources/ChauffeurCore/Engine/Session.swift:9` (`var ax: (any AXSource)?`)
- Test: `Tests/ChauffeurCoreTests/AXSourceTests.swift`

**Interfaces:**
- Produces:
  ```swift
  @MainActor public protocol AXSource: AnyObject {
      func read() -> AXElement?
      func read(pid: Int32) -> AXElement?
      func frontmostPID() -> Int32?
      func element(at point: Point) -> AXElement?
      func probe(center: Point) -> (frontmostIsEmptyApp: Bool, screenAnswers: Bool)
      func complete(_ root: AXElement) -> AXElement
  }
  ```
  `AXProvider: AXSource` (it already has every method except `element(at:)`, which wraps `reader.element(at:)`).
  Test fake `ScriptedAX: AXSource` (in `Support.swift`): `init(frames: [AXElement?])`, `read()` returns the next frame
  and repeats the last; `read(pid:)` returns nil; `frontmostPID()` returns `scriptedPID` (default 4321);
  `element(at:)` returns nil; `probe` returns `(false, true)`; `complete` returns its argument.

- [ ] **Step 1: Write the failing test**

```swift
@Suite @MainActor struct AXSourceTests {
    @Test func aScriptedSourceReplaysItsFramesAndHolds() throws {
        let home = try Fixtures.ax("fixture-home"), form = try Fixtures.ax("fixture-form")
        let ax = ScriptedAX(frames: [home, form])
        #expect(ax.read() == home); #expect(ax.read() == form); #expect(ax.read() == form)
    }
}
```

- [ ] **Step 2: Run to verify it fails** — Run: `swift test --filter AXSourceTests`. Expected: `AXSource` undefined.
- [ ] **Step 3: Implement the protocol, conform `AXProvider`, change `Session.ax`'s type, add `ScriptedAX`**
- [ ] **Step 4: Run** — `swift test` passes; `scripts/check-code.sh` passes.
- [ ] **Step 5: Commit** — `git commit -m "AXSource: the accessibility seam; AXProvider conforms"`

### Task 6: `SimDevice`, `TouchEvidenceSource`, `ShellRunner`, `ProcessTable`

**Files:**
- Create: `Sources/ChauffeurCore/Device/Seams.swift` (the four protocols; under 120 lines)
- Modify: `Sources/ChauffeurCore/Device/Device.swift` (conform), `Sources/ChauffeurCore/Device/TouchLog.swift` (conform),
  `Sources/ChauffeurCore/Shell.swift` (`SimCtlRunner: ShellRunner`), `Sources/ChauffeurCore/Logs/Crash.swift:5-15` (`Proc` conforms via `LiveProcessTable`)
- Test: `Tests/ChauffeurCoreTests/SeamsTests.swift`

**Interfaces:**
- Produces:
  ```swift
  public protocol SimDevice: AnyObject { var udid: String { get }; var booted: Bool { get }; var size: Size { get } }
  public protocol TouchEvidenceSource: AnyObject {
      var isAttached: Bool { get }; var cursor: Int { get }
      func start() throws; func stop()
      func evidence(since cursor: Int, waitMs: Int) -> Evidence
  }
  public protocol ShellRunner: Sendable {
      /// `xcrun simctl <args>`; throws `ChauffeurError.simulatorServiceUnresponsive` on timeout, as `SimCtl.run` does.
      func simctl(_ args: [String], stdin: String?, timeout: Double) throws -> ProcessResult
  }
  public protocol ProcessTable: Sendable { func isAlive(_ pid: Int32) -> Bool; func parent(of pid: Int32) -> Int32?; func children(of parent: Int32, named: String) -> [Int32] }
  ```
  `Device: SimDevice` (add `udid`), `TouchLog: TouchEvidenceSource`, `struct SimCtlRunner: ShellRunner` (calls
  `SimCtl.run`), `struct LiveProcessTable: ProcessTable` (calls `Proc`). Test fakes in `Support.swift`:
  `FakeDevice(udid:booted:size:)`, `ScriptedTouches(evidence: [Evidence], attached: Bool)` (returns the next scripted
  evidence per `evidence(since:waitMs:)`, `.unavailable` when `attached == false`), `RecordingShell(replies: [[String]: ProcessResult])`
  (records every call in `calls`, replies from the table or `ProcessResult(status: 0, out: "", timedOut: false)`),
  `FakeProcesses(alive: Set<Int32>)`.

- [ ] **Step 1: Write the failing test** (one per fake, asserting the scripted behaviour; and `SimCtlRunner` is `ShellRunner`)
- [ ] **Step 2: Run to verify it fails** — `swift test --filter SeamsTests`
- [ ] **Step 3: Implement the protocols, conformances and fakes**
- [ ] **Step 4: Run** — `swift test`; `scripts/check-code.sh`
- [ ] **Step 5: Commit** — `git commit -m "Seams: SimDevice, TouchEvidenceSource, ShellRunner, ProcessTable"`

### Task 7: `SessionEnvironment`

**Files:**
- Create: `Sources/ChauffeurCore/Engine/SessionEnvironment.swift`
- Modify: `Sources/ChauffeurCore/Engine/Session.swift` (init, stored properties, `connect`, `drop`, `heal`,
  `restartBridge`, `ensureAccessibility`), `Session+Act.swift:19-35` (`transportsReady` keeps building HID until Task 11),
  `Session+Clipboard.swift:46` (`readClipboard` through the shell), `Session+Act.swift:252,262` (`pbcopy` through the shell),
  `Session+Logs.swift` (`isAlive` through `processes`), `Session+Network.swift:28-33` (`watchedPids` through `processes`),
  `Daemon.swift` and `MCPServer.swift` (construct with `.live`)
- Test: `Tests/ChauffeurCoreTests/SessionEnvironmentTests.swift`

**Interfaces:**
- Produces:
  ```swift
  public struct SessionEnvironment {
      public var clock: any SettleClock
      public var device: @MainActor (String) throws -> any SimDevice
      public var ax: @MainActor (any SimDevice) throws -> any AXSource
      public var touchEvidence: any TouchEvidenceSource
      public var shell: any ShellRunner
      public var flows: @MainActor () -> (any FlowSource)?
      public var processes: any ProcessTable
      public static func live(udid: String) -> SessionEnvironment
      /// Tests: scripted everything, an unattached touch log unless given, no flows.
      public static func scripted(ax: ScriptedAX, touches: ScriptedTouches = …, shell: RecordingShell = …, clock: FakeClock = …) -> SessionEnvironment  // test target
  }
  public init(udid: String, environment: SessionEnvironment)
  public convenience init(udid: String)  // = environment: .live(udid:)
  ```
  `Session.clock`, `touchLog` and the `flowSource` lookup read from the environment. `Session.ax` becomes
  `(any AXSource)?`, `Session.device` becomes `(any SimDevice)?`. The `.live` factories downcast `SimDevice` to
  `Device` to reach `sim` for `AXProvider(sim:)`; that cast lives only in `SessionEnvironment.live`.
  The closure seams `simulatorBooted`, `simulatorBootDate`, `findCrashReport`, `relaunch`, `commandHook`,
  `telemetryOverride`, `crashReportWaitMs` stay as they are in this plan (Plan 2 retires them).

- [ ] **Step 1: Write the failing test**

```swift
@Suite @MainActor struct SessionEnvironmentTests {
    @Test func connectUsesTheEnvironmentsDeviceAndSource() throws {
        let env = SessionEnvironment.scripted(ax: ScriptedAX(frames: [try Fixtures.ax("fixture-home")]))
        let s = Session(udid: "ZZ000000-TEST", environment: env)
        let out = s.run(["snapshot"])
        #expect(out.exit == 0 && out.text.contains("button \"Show alert\" [e"), out.text)
    }
    @Test func aDeviceThatIsNotBootedIsReported() {
        var env = SessionEnvironment.scripted(ax: ScriptedAX(frames: []))
        env.device = { FakeDevice(udid: $0, booted: false, size: Size(w: 402, h: 874)) }
        let s = Session(udid: "ZZ000000-TEST", environment: env)
        #expect(s.run(["snapshot"]).text.contains("not booted"))
    }
}
```

- [ ] **Step 2: Run to verify it fails** — compile error, no `environment:` initialiser
- [ ] **Step 3: Implement the environment and route `connect`, `heal`, `restartBridge`, `ensureAccessibility`, the clipboard reads and `pbcopy` through it**
- [ ] **Step 4: Run** — `swift test`; `scripts/check-code.sh`; `Session.swift` must stay under 400 lines: if it doesn't, move `heal`/`restartBridge`/`ensureAccessibility` to `Engine/Session+Heal.swift` in this step.
- [ ] **Step 5: Commit** — `git commit -m "SessionEnvironment: Session takes its device, accessibility, touch evidence, shell, flows and processes"`

### Task 8: `heal` offline

**Files:**
- Test: `Tests/ChauffeurCoreTests/SessionHealTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
@Test func noTreeForLongEnoughTurnsTheFlagsBackOnThroughTheShell() throws {
    let shell = RecordingShell(replies: [["spawn", "ZZ000000-TEST", "defaults", "read", AXSettings.domain]: ProcessResult(status: 0, out: "{ ApplicationAccessibilityEnabled = 0; }", timedOut: false)])
    let clock = FakeClock()
    let env = SessionEnvironment.scripted(ax: ScriptedAX(frames: [nil]), shell: shell, clock: clock)
    let s = Session(udid: "ZZ000000-TEST", environment: env)
    let out = s.run(["snapshot"])
    #expect(shell.calls.contains { $0.starts(with: ["spawn", "ZZ000000-TEST", "defaults", "write", "com.apple.Accessibility", "ApplicationAccessibilityEnabled"]) }, "\(shell.calls)")
    #expect(out.exit != 0)
}
```

The exact `defaults write` arguments are in `ensureAccessibility` (`grep -n "defaults" Sources/ChauffeurCore/Engine/Session.swift`); copy them.

- [ ] **Step 2: Run to verify it fails** (if it passes at once, the shell seam isn't on the heal path: fix Task 7)
- [ ] **Step 3: Make it pass** (no production change expected beyond Task 7)
- [ ] **Step 4: Commit** — `git commit -m "heal runs offline through the shell seam"`

### Task 9: `observe`, `baseline` and `wait` offline

**Files:**
- Test: `Tests/ChauffeurCoreTests/SessionObserveTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
@Suite @MainActor struct SessionObserveTests {
    @Test func revBumpsOnlyWhenTheSnapshotChanges() throws {
        let home = try Fixtures.ax("fixture-home"), form = try Fixtures.ax("fixture-form")
        let s = Session(udid: "ZZ000000-TEST", environment: .scripted(ax: ScriptedAX(frames: [home, home, home, form, form])))
        #expect(s.run(["snapshot"]).text.contains("rev 1"))
        #expect(s.run(["snapshot"]).text.contains("rev 1"))
        #expect(s.run(["snapshot"]).text.contains("rev 2"))
    }
    @Test func waitFindsTextOnALaterFrame() throws {
        let home = try Fixtures.ax("fixture-home"), form = try Fixtures.ax("fixture-form")
        let clock = FakeClock()
        let s = Session(udid: "ZZ000000-TEST", environment: .scripted(ax: ScriptedAX(frames: [home, home, home, home, form, form]), clock: clock))
        let out = s.run(["wait", "Email", "--timeout", "5"])
        #expect(out.exit == 0 && out.text.hasPrefix("found after "), out.text)
    }
    @Test func waitTimeoutAbove300IsClampedNotRefused() throws {
        let home = try Fixtures.ax("fixture-home")
        let clock = FakeClock()
        let s = Session(udid: "ZZ000000-TEST", environment: .scripted(ax: ScriptedAX(frames: [home]), clock: clock))
        let out = s.run(["wait", "Nowhere", "--timeout", "600"])
        #expect(out.exit == 4 && out.text.contains("after 300s"), out.text)
        #expect(clock.now >= 300_000)
    }
    @Test func baselineWaitsForTheScreenToBeQuiet() throws { /* lastChangeMs just set → baseline sleeps ≥ 500 ms on the fake clock */ }
}
```

Frame counts: `observe` polls until two consecutive reads hash the same, so give each distinct screen at least two
frames. Adjust the "Email" query to a label that exists in `fixture-form.json` (`grep -o '"label":"[^"]*"' Tests/ChauffeurCoreTests/Fixtures/ax/fixture-form.json | head`).

- [ ] **Step 2: Run to verify they fail** — the first fails only if rev logic is wrong; it must pass; the clamp test must pass; `waitFindsTextOnALaterFrame` must pass. These are regression pins: if any fails, the environment wiring from Task 7 is wrong. Fix the wiring, not the test.
- [ ] **Step 3: Run the stage** — `scripts/check.sh`, then the live suites.
- [ ] **Step 4: Re-run the ledger** — `scripts/live-expectations.sh && git diff --stat docs/plans/2026-10-27-refactor-live-expectations.md` → no change.
- [ ] **Step 5: Commit and PR** — `git commit -m "observe, baseline and wait have offline tests"`, push `refactor-1a-environment`, open the PR.

---

## Stage 1b: one HID wrapper, the log seam, `act` offline, Doctor through the wrappers

Branch `refactor-1b-inputs`. PR title: "Refactor 1b: HID, the log seam, act runs offline, Doctor shares the wrappers".

**Amended 2026-10-28, before execution** (the Fable review of Stage 1a, ledger "## Fable review"): Task 10 is split
into 10a (the closure seams move into `SessionEnvironment`, `typeCommand` gets its own file) and 10b (HID); Task 12
pins the four verdict-upgrade paths and `finishPending` line by line before Stage 2 rewrites them as passes. Line
numbers below are from `main` at 0b50039 (after Stage 1a); the ones in the Stage 1a amendment text were older.

### Task 10a: `typeCommand` in its own file; boot state and the crash report into the environment; `isAlive` retires

**Files:**
- Create: `Sources/ChauffeurCore/Engine/Session+Type.swift` (`typeCommand`, `redactedType`, `provisionalType`, `shown`,
  moved unchanged from `Session+Act.swift:211-334`; `Session+Act.swift` drops from 391 to about 270 lines, so 10b's
  HID diff is readable)
- Modify: `Sources/ChauffeurCore/Engine/SessionEnvironment.swift` (three new members; `.live` provides today's
  implementations), `Sources/ChauffeurCore/Engine/Session.swift:35-40` (the `simulatorBooted`, `simulatorBootDate`,
  `isAlive`, `findCrashReport` properties go), `:86-91` (their defaults go), `Session+Logs.swift:15,17,29,105`,
  `Session+Device.swift:49-50`, `Session+Apps.swift:106` (read `processes.isAlive(_:)` and the environment's members)
- Modify tests: `Tests/ChauffeurCoreTests/Support.swift` (`FakeProcesses` becomes a class; `.scripted` gains
  `processes:`, `flows:` and the three members; `RecordingShell` records stdin and timeout and answers a repeated call
  from an ordered list; the comment at `:136-140` stops naming the closures),
  `Tests/ChauffeurCoreTests/AnnotateTests.swift:13-23` (`session(alive:report:)` builds the environment first),
  `:100,102,113` (liveness flips on the fake), `:119,129,136,139,192` (members set before the session is built),
  `Tests/ChauffeurCoreTests/DeviceTests.swift:8,24,35` (the same), `Tests/ChauffeurCoreTests/SeamsTests.swift:72`
  (still compiles; one more assertion)

**Interfaces:**
- Produces, in `SessionEnvironment` (today's closure types, copied from `Session.swift:36-40`):
  ```swift
  /// Is the simulator booted (nil: could not tell), when did its current boot start, and the report for a gone app.
  public var simulatorBooted: () -> Bool?
  public var simulatorBootDate: () -> Date?
  public var findCrashReport: (TrackedApp) -> CrashReport?
  ```
  `.live(udid:)` fills them with `{ SimBoot.booted(udid: udid) }`, `{ SimBoot.date(udid: udid) }` and
  `{ app in CrashFinder.find(bundle: app.bundle, pid: app.pid, udid: udid, since: app.launchedAt) }`, moved from
  `Session.init` (`Session.swift:86-90`). `Session` reads `environment.simulatorBooted()`,
  `environment.simulatorBootDate()`, `environment.findCrashReport(app)` and `processes.isAlive(pid)`; the four
  properties are deleted. `processes` is then the only liveness seam. `relaunch`, `commandHook`, `telemetryOverride`
  and `crashReportWaitMs` stay as they are (Plan 2).
- Test support (`Support.swift`):
  ```swift
  /// A `ProcessTable` whose live pids a test changes between commands (a reference, so the session sees the change).
  final class FakeProcesses: ProcessTable, @unchecked Sendable { var alive: Set<Int32>; init(alive: Set<Int32>) }
  static func scripted(
      ax: ScriptedAX, touches: ScriptedTouches = ScriptedTouches(evidence: [], attached: false),
      shell: RecordingShell = RecordingShell(), clock: FakeClock = FakeClock(),
      flows: (any FlowSource)? = nil, processes: FakeProcesses = FakeProcesses(alive: []),
      simulatorBooted: @escaping () -> Bool? = { true }, simulatorBootDate: @escaping () -> Date? = { nil },
      findCrashReport: @escaping (TrackedApp) -> CrashReport? = { _ in nil }
  ) -> SessionEnvironment
  /// Replies in order for a repeated call (`pbpaste` before and after a tap); the last one holds.
  RecordingShell(replies: [[String]: [ProcessResult]] = [:])
  var calls: [[String]]                                           // as today
  var recorded: [(args: [String], stdin: String?, timeout: Double)] // new: Task 12 asserts pbcopy's stdin
  ```
  A test that flips liveness keeps the `FakeProcesses` it passed and sets `procs.alive`; one that needs a boot date or
  a report passes it to `.scripted` (or sets `env.<member>` before `Session(udid:environment:)`).

- [ ] **Step 1: Move `typeCommand`** — a pure move into `Session+Type.swift` (`import ChauffeurBridge` moves with it for
  now; 10b removes it); `swift test`; `git commit -m "Session+Type: typeCommand in its own file"`.
- [ ] **Step 2: Write the failing tests** — `SeamsTests`: `let procs = FakeProcesses(alive: [1]); let table: any ProcessTable = procs; procs.alive = []; #expect(!table.isAlive(1))`.
  `SessionEnvironmentTests`: a `.scripted(ax: ScriptedAX(frames: []), processes: procs)` session with
  `procs.alive = [4321]` and `s.app = TrackedApp(bundle: "dev.chauffeur.fixture", executable: "Fixture", displayName: "Fixture", pid: 4321, launchedAt: Date())`;
  `procs.alive = []` then `s.annotate(Output("snapshot"), since: 0, logs: false).exit == 5`; the same session built with
  `simulatorBooted: { false }` exits 0 and ends with `s.app == nil` (today's `aShutDownSimulatorIsNotACrash` through the
  environment). `defer { TrackedApp.clear(StatePaths.app(s.udid)) }` as `AnnotateTests` does.
- [ ] **Step 3: Run to verify they fail** — compile errors: `.scripted` has no `processes:`; `procs.alive` on a struct copy changes nothing.
- [ ] **Step 4: Implement** — the three members, `.live`, `.scripted`, the six `Session` call sites; port `AnnotateTests`
  and `DeviceTests`: every `s.isAlive = { _ in x }` becomes `procs.alive = x ? [4321] : []`; every
  `s.simulatorBooted`, `s.simulatorBootDate`, `s.findCrashReport` assignment moves into the environment built before
  the session (`session(alive:report:booted:bootDate:)`). Assertions stay byte for byte. Where a ported test relies on
  `connect()` failing on the fake udid today (`aCrashBetweenCommandsIsReportedByTheNextCommandThatEndsTheApp` runs
  `terminate`, `launch`, `install`, `permission` through `s.run`), give the scripted environment a device that is not
  booted (`env.device = { FakeDevice(udid: $0, booted: false, size: Size(w: 402, h: 874)) }`) rather than falling back
  to `.live`; if any assertion must change, say why in the PR.
- [ ] **Step 5: Run** — `swift test`; `grep -n "isAlive\|simulatorBooted\|simulatorBootDate\|findCrashReport" Sources/ChauffeurCore/Engine/*.swift`
  shows only `processes.isAlive(` and `environment.<member>(` reads; `scripts/check-code.sh`.
- [ ] **Step 6: Commit** — `git commit -m "SessionEnvironment: boot state and the crash report are members; processes is the one liveness seam"`

### Task 10b: `InputDevice` and `HID`

**Files:**
- Create: `Sources/ChauffeurCore/Device/HID.swift`
- Modify: `Sources/ChauffeurCore/Device/Input.swift` (`DigitizerTransport`, `MouseTransport` and `Keyboard` are built
  by `HID` only; `Gestures.tap`/`drag` and `Keyboard.press` sleep through a `SettleClock` parameter; `import
  ChauffeurBridge` leaves the file if the transports' `CHHIDClient` can be hidden behind `HID`, else the client type
  stays referenced here and the lint rule below allows it), `Sources/ChauffeurCore/Engine/Session.swift:1,10-11`
  (`import ChauffeurBridge`, `hid`, `transports` go; `preferred` stays; `drop()` at `:144-150` forgets the input
  device), `Session+Act.swift:18-36` (`transportsReady` asks `environment.inputs`; its `(device as? Device)?.sim` cast
  and the "until Task 10" comment are deleted, so a fake device gets fake transports instead of silently none),
  `:71-74` (`hid = nil; transports = []` becomes `inputs?.reset()`), `:141,160,191,370` and `Session+Gestures.swift:32`, `Session+Type.swift` (`Gestures.tap`/`drag`
  take `clock`), `Session+Type.swift` (`guard let hid` and `Keyboard(hid:)` become `try inputDevice().keyboard(clock: clock)`),
  `Session+Gestures.swift:46-47,52,56-64` (`press` moves into `HID`; the `guard let hid` goes), `Session+Gestures.swift:1`,
  `Session+Act.swift:1`, `Session+Type.swift:1` (`import ChauffeurBridge` goes), `SessionEnvironment.swift` (add
  `inputs`), `scripts/check-code.sh` (new rule), `scripts/tests/test-check-code.sh` (one case)
- Test: `Tests/ChauffeurCoreTests/HIDTests.swift`, `Tests/ChauffeurCoreTests/Support.swift` (`FakeInputs`,
  `FakeTransport`, `FakeTextInput`)

**Interfaces:**
- Produces:
  ```swift
  @MainActor public protocol InputDevice: AnyObject {
      /// Digitizer first, then mouse. The same objects until `reset()`: `act` compares transports by identity.
      func transports() throws -> [any TouchTransport]
      func keyboard(clock: any SettleClock) throws -> any TextInput
      func press(_ button: HardwareButton, clock: any SettleClock) throws -> Bool   // holds for button.holdMs
      /// After a failed send: drop the client; the next call rebuilds it.
      func reset()
  }
  @MainActor public protocol TextInput {
      func type(_ text: String) -> Bool
      func press(_ usage: UInt32, modifiers: [UInt32]) -> Bool
  }
  extension TextInput { public func press(_ usage: UInt32) -> Bool }   // typeCommand's bare `press(Keys.returnKey)`
  @MainActor public final class HID: InputDevice { public init(device: Device) }   // the ONE owner of CHHIDClient
  public enum Gestures {
      static func tap(_ t: any TouchTransport, at: Point, screen: Size, holdMs: Int = 50, clock: any SettleClock) -> Bool
      static func drag(_ t: any TouchTransport, from: Point, to: Point, screen: Size, steps: Int = 12, stepMs: Int = 16, clock: any SettleClock) -> Bool
  }
  public struct Keyboard: TextInput { init(hid: CHHIDClient, clock: any SettleClock) }   // the two 15 ms waits through `clock`
  ```
  `SessionEnvironment.inputs: @MainActor (any SimDevice) throws -> any InputDevice`; `.live` downcasts to `Device`
  beside `ax`'s cast (the two casts in the one place the plan allows) and returns `HID(device:)`. `Session` keeps
  `var inputDevice: (any InputDevice)?`, built on first use from `environment.inputs(device)`, set to nil in `drop()`;
  a failed send calls `inputDevice?.reset()` (the device rebuilds its client; the session keeps the same device, so a
  fake can count resets). Test fakes (`Support.swift`):
  ```swift
  @MainActor final class FakeTransport: TouchTransport {
      init(name: String, supportsMove: Bool, sends: Bool = true); private(set) var touches: [(Point, TouchPhase)]
  }
  final class FakeTextInput: TextInput {
      init(types: Bool = true, presses: [Bool] = [true])   // `press` pops the next result and holds the last
      private(set) var typed: [String]; private(set) var pressed: [(usage: UInt32, modifiers: [UInt32])]
  }
  @MainActor final class FakeInputs: InputDevice {
      init(transports: [FakeTransport] = [FakeTransport(name: "digitizer", supportsMove: true), FakeTransport(name: "mouse", supportsMove: false)],
           keyboard: FakeTextInput = FakeTextInput(), press: Bool = true)
      private(set) var resetCount = 0; private(set) var pressed: [HardwareButton]
  }
  ```
  `SessionEnvironment.scripted` gains `inputs: FakeInputs = FakeInputs()` here and `logs:` in Task 11.

- [ ] **Step 1: Write the failing tests** — `HIDTests`: `FakeInputs().transports().map(\.name) == ["digitizer", "mouse"]`;
  a `Gestures.tap` on a `FakeTransport` with a `FakeClock` records `[.down, .up]` and advances the clock by exactly
  `holdMs`; `Gestures.drag` records 1 + 12 + 1 touches and advances by 12 × 16 ms; `FakeTextInput(presses: [true, false])`
  answers true then false then false; `let _: any InputDevice = HID(device:)` is compile-only (no simulator in unit
  tests). Lint: `scripts/check-code.sh` gains `hid-owner`: `CHHIDClient` outside `Sources/ChauffeurBridge` may appear
  only in `Sources/ChauffeurCore/Device/HID.swift` (and `Device/Input.swift` if the transports keep the type);
  `scripts/tests/test-check-code.sh` gets one case for it.
- [ ] **Step 2: Run to verify it fails** — `swift test --filter HIDTests` (undefined types); the lint case fails on `Session.swift`.
- [ ] **Step 3: Implement** `HID`, `InputDevice`, `TextInput`; move `press`; route `transportsReady`, `typeCommand`,
  `buttonCommand` and `selftestCommand` through `inputDevice()`; `usleep` leaves `Input.swift`
  (`grep -c usleep Sources/ChauffeurCore/Device/Input.swift` → 0). Delete `transportsReady`'s `device as? Device` cast.
- [ ] **Step 4: Run** — `swift test`; `scripts/check-code.sh` (new rule passes); `grep -rn CHHIDClient Sources/ChauffeurCore/Engine` → nothing.
- [ ] **Step 5: Commit** — `git commit -m "HID: one owner of the HID client; InputDevice is the seam"`

### Task 11: `LogSource`

**Files:**
- Create: add `LogSource` to `Sources/ChauffeurCore/Device/Seams.swift`
- Modify: `Sources/ChauffeurCore/Logs/LogTap.swift:112` (conform), `:168-173` (`append` becomes `public`, its comment
  updated: tests feed lines through the seam), `SessionEnvironment` (add `logs`; `.live` builds `LogTap(udid:)`),
  `Session.swift:14,85` (`let logTap: LogTap` and its construction go; `var logs: any LogSource { environment.logs }`),
  every `logTap.` use in `Engine` (`grep -n "logTap" Sources/ChauffeurCore/Engine/*.swift`: `Session.swift:105,134,230`,
  `Session+Apps.swift:87-88`, `Session+Logs.swift:6,9,34,70,114,124,147`, `Session+Network.swift:53,65`,
  `Session+Wait.swift:107`; `logTapAttemptMs` keeps its name)
- Test: `Tests/ChauffeurCoreTests/Support.swift` (`ScriptedLogs`), `Tests/ChauffeurCoreTests/SessionNetworkTests.swift`
  (rename, and the `.live` build at `:15-24` becomes `.scripted(ax: ScriptedAX(frames: []), flows: ScriptedFlows(flows), clock: clock)`:
  it set `s.flowSource` and `s.flowSourceTried` directly, bypassing `environment.flows`; `telemetryOverride = []`
  stays, it is a closure seam until Plan 2), `Tests/ChauffeurCoreTests/AnnotateTests.swift` (rename),
  `Tests/ChauffeurCoreTests/Live/AppsLiveTests.swift:22` (`s.logs.executable`). `LogTapTests` and `LogRedactTests`
  use `LogTap` directly and are untouched.

**Interfaces:**
- Produces (every member `Session` reads today; `LogTap` already has each one):
  ```swift
  public protocol LogSource: AnyObject {
      var isAttached: Bool { get }
      /// The executable whose log is followed while the stream is attached.
      var executable: String? { get }
      var cursor: Int { get }
      var all: [LogLine] { get }
      func since(_ cursor: Int) -> [LogLine]
      /// False when `log stream` did not attach; following the same executable again keeps the lines.
      @discardableResult func start(executable: String) -> Bool
      func stop()
      /// Tests feed lines; `LogTap` shapes URLs as it stores them.
      func append(_ line: LogLine)
  }
  ```
  `SessionEnvironment.logs: any LogSource`. Test fake `ScriptedLogs: LogSource` (`Support.swift`): a `LogRing` behind
  the protocol; `init(attaches: Bool = true)`; `start` records the executable, sets `executable` and `isAttached =
  attaches`, returns `attaches`; `stop` clears `isAttached`. `.scripted` gains `logs: ScriptedLogs = ScriptedLogs()`.

- [ ] **Step 1: Rename in tests first** (`s.logTap` → `s.logs` in `SessionNetworkTests`, `AnnotateTests`,
  `Live/AppsLiveTests.swift:22`; move `SessionNetworkTests.session(flows:clock:)` to `.scripted(... flows:)`) and run:
  compile error.
- [ ] **Step 2: Implement; run `swift test`** (`SessionNetworkTests` still 0.06 s) **; commit** — `git commit -m "LogSource: the launched app's log is a seam"`

### Task 12: `act` offline, and the upgrade paths pinned line by line

**Files:**
- Test: `Tests/ChauffeurCoreTests/SessionActTests.swift` (classify paths, delivery, the intercepted tap),
  `Tests/ChauffeurCoreTests/SessionGestureTests.swift` (scroll, swipe), `Tests/ChauffeurCoreTests/SessionUpgradeTests.swift`
  (the five pins below), `Tests/ChauffeurCoreTests/SessionTypeTests.swift` (`type` and `type --submit`); each under
  600 lines, sharing one `Tests/ChauffeurCoreTests/ActSupport.swift` for the session builder, the ref lookup and the
  mutated fixture frames. Goldens: `Tests/ChauffeurCoreTests/Fixtures/golden/sessions/*.txt` (new folder; `Golden.check`
  creates it on record).

**Test data every test shares** (`ActSupport.swift`):
- The session: `.scripted(ax:touches:shell:clock:flows:processes:inputs:logs:)` with `inputs: FakeInputs()`,
  `touches: ScriptedTouches(evidence: [.app("dev.chauffeur.fixture")], attached: true)` unless the test says otherwise,
  a random `ZZxxxxxx-TEST` udid, and `defer { TrackedApp.clear(StatePaths.app(s.udid)) }` where an app is tracked.
- Refs: look them up, never hard-code: `Perception.build(root: home, size: Size(w: 402, h: 874), previous: nil, refs: &refs, rev: 1).find("Show alert").first?.ref`
  (`fixture-home`), `.find("Agree to terms")` (`fixture-form`; its `AXCheckBox` has subrole `AXSwitch`, so its role is
  `switch`, value `0` → `off`), `.find("email")` / `.find("password")` (`fixture-form`'s `AXTextField`s, identifiers
  `email`/`password`; the second has subrole `AXSecureTextField` → `securefield`).
- Mutated frames, since `AXElement`'s fields are `var`s: `formOn` = `fixture-form` with the switch's `value = "1"`;
  `formTyped` = the email field's `value = "alice@example.com"`; `formSecure` = the password field's `value` = 21 bullets
  (`•`) for a 21-character password (`TypeCheck.verify` counts added bullets).
- Reads per observe on the fake clock (Stage 1a Findings): a stable screen costs 2 reads at `minMs: 0` and 3 at
  `minMs: 150`; `baseline()` is 4 reads when the screen just changed (observe, 500 ms sleep, observe) and 2 when it
  has been quiet ≥ 500 ms; `act` then reads 3. `ScriptedAX` holds its last frame, so only the earlier frames need exact
  counts. Frame counts are test data the implementer may adjust with a comment; the assertions below may not change.
- Flows: `ScriptedFlows` (move it from `SessionNetworkTests.swift` to `ActSupport.swift`) pops one sample per
  `flows(pids:)` call and holds the last. A tap samples at `netStart` (before the baseline), at `tapNet` (the touch),
  once after `NetJudge.graceMs`, then every 100 ms while pending and once more after `confirmMs`. `waiting` =
  `Flow(id: 1, pid: 4321, process: "Fixture", proto: "tcp", remote: "127.0.0.1:8765", tx: 58, rx: 0, openedMs: 1, closedMs: nil)`;
  `done` = the same with `rx: 512, closedMs: 2`. `watchedPids()` is `[4321]` from `ScriptedAX.scriptedPID`.
- No evidence screenshot is ever written: `capture` runs `io … screenshot` through `RecordingShell`, finds no file and
  `act`'s `try?` drops it, so a NO EFFECT renders without its `screen:` line offline.

- [ ] **Step 1: Write the failing tests.** `SessionActTests` and `SessionGestureTests`, as before:

```swift
@Test func aChangeOnTheNextFrameIsCredited() throws {
    // frames: [home ×4 (baseline), form] ; touches: .app("dev.chauffeur.fixture")
    let out = s.run(["tap", showAlert])
    #expect(out.exit == 0 && out.text.hasPrefix("tap \(showAlert) \"Show alert\" → changed · settled"), out.text)
}
@Test func noTouchEvidenceRetriesOnTheNextTransportThenNotDelivered() throws {
    // touches: [.none, .none]; transports: [digitizer, mouse], both send
    #expect(out.text.contains("NOT DELIVERED · retried via mouse")); #expect(inputs.transports.map(\.touches.count) == [2, 2])
}
@Test func anUnattachedTouchLogIsUnverified() throws { /* ScriptedTouches(evidence: [], attached: false) → "UNVERIFIED" */ }
@Test func aFailedSendDropsTheClientAndRebuildsIt() throws { /* both FakeTransport(sends: false) → NOT DELIVERED and inputs.resetCount == 1 */ }
@Test func aTouchThatLandedInAnotherAppIsIntercepted() throws {
    // launch offline first: shell replies ["appinfo", udid, bundle] → an Info.plist XML with CFBundleExecutable and
    // CFBundleDisplayName "Fixture"; ["launch", udid, bundle] → "dev.chauffeur.fixture: 4321"; processes alive [4321];
    // frames [home …]; then touches .app("com.apple.springboard") → "INTERCEPTED by com.apple.springboard"
}
@Test func theSwitchIsTappedAgainWhenTheFirstTouchWasIgnored() throws { /* see SessionUpgradeTests; here assert only the two touches */ }
@Test func scrollReportsTheFoundLine() throws {
    // fixture-longlist has Row 1–14 only (the plan's "Row 48" does not exist): frames [longlist ×4, longScrollview],
    // query "Label 69" (`long-scrollview.json`) → hasPrefix("found text \"Label 69\" [e") and hasSuffix("after 1 scroll down")
}
@Test func swipeIsVerifiedByTheScreen() throws { /* frames [home ×4, form] → changed */ }
```

`SessionUpgradeTests`: five pins, each `Golden.check("sessions/<name>.txt", out.text)` on the whole output (every line,
so Stage 2's passes must reproduce `settledMs`, the hints and the request lines exactly). The upgrade sites today:

| Pin | Site | Frames, touches, flows, shell | What the recorded golden must show |
|---|---|---|---|
| `tap-screen-again` | `Session+Network.swift:105-115` (`judgeScreenAgain`) | tap `showAlert`; frames `[home ×7, form]` (baseline 4, the NO EFFECT act 3, then the second look); flows `[[], [], [waiting], [done]]` | `changed · settled <N>ms · rev 1→2` where N is the time since the touch (the act's 150 ms settle + grace + one 100 ms poll + the 300 ms confirm + the second observe), the diff, then the request line for `127.0.0.1:8765`; no `hint:` line (`:114` clears them); exit 0 |
| `tap-late-switch` | `Session+Act.swift:146-155` | tap `agree` (`holdMs` 50); frames `[form ×7, formOn]`; no flows | `changed · settled 150ms · rev 1→2` (the FIRST act's settle, `:149-151` keep `settledMs`), the `~ … off → on` diff line, `hint: the switch changed only after 1.5s`; exit 0 |
| `tap-second-tap` | `Session+Act.swift:156-167` | tap `agree`; frames `[form ×9, formOn]` (baseline 4, act 3, second baseline 2, then the second act sees `formOn`); touches `[.app(fixture), .app(fixture)]` | the second act's line `changed · settled 150ms · rev 1→2`, the diff, `hint: the first touch reached the app but the switch ignored it; chauffeur tapped once more`; also `touches.requests.count == 2` and the digitizer's `touches.count == 4` |
| `tap-clipboard-with-requests` | `Session+Act.swift:169-176` | tap `showAlert`; frames `[home]`; flows `[[], [], [done]]`; shell replies `["pbpaste", udid]: [out "", out "hello, clipboard"]` | `changed · copied to clipboard (16 characters)` then the `127.0.0.1:8765` request line (`:170-176` keep `requests`); no `hint:`; exit 0 |
| `wait-finishes-pending` | `Session+Wait.swift:61-97` (`finishPending`, `settledMs` at `:83`) | tap `showAlert` with flows `[[], [], [waiting]]` → `s.run(["tap", …])` is `PENDING`, exit 6, headline `→ PENDING · 127.0.0.1:8765 · sent 58 B, no reply after 2.`; then `flows.samples = [[done]]` and `s.run(["wait"])`; frames `[home ×7, form]` | the wait's output: `changed · settled 150ms · rev 1→2` (`:83` uses the wait's own observe, not the time since the touch), the diff, the request line; no `hint:`; exit 0; `s.pendingTap == nil` |

Also pin, with `==` on the first line, that the four NO EFFECT paths do not fire when they should not: a `button` target
is not tapped twice (`touches.requests.count == 1`), an unchanged pasteboard stays NO EFFECT.

`SessionTypeTests` (the Stage 0 Findings' missing §1 shape): `type` into `email` with `"alice@example.com"` (17
characters → the paste path: `shell.recorded` has `["pbcopy", udid]` with that stdin, then `FakeTextInput.pressed`
has `(Keys.v, [Keys.command])`); frames `[form ×7, formTyped]`; then three goldens with `--submit`:
`type-submit-changed` (frames `[form ×7, formTyped ×3, home]` → `submit → changed · rev 2→3` and the diff),
`type-submit-noeffect` (frames `[form ×7, formTyped]` → `submit → NO EFFECT · nothing changed after Return`),
`type-submit-notdelivered` (`FakeTextInput(presses: [true, false])`: the paste's ⌘V succeeds, Return fails →
`submit → NOT DELIVERED: Return failed to send`, exit 3). And the secure paste: `type password "correct horse battery"`
(21 characters), frames `[form ×7, formSecure]` → the label is `type eN (21 characters)`, the pasteboard is cleared:
`shell.recorded.filter { $0.args == ["pbcopy", udid] }.map(\.stdin) == ["correct horse battery", ""]`, and the trace
args are `Session.redactedType(...)`. `focusing the field failed` is pinned with touches `[.none, .none]`.

- [ ] **Step 2: Run** — every test must compile and pass on the first run: these are regression pins, and a failure is a
  wiring bug in Tasks 10a-11, not a reason to change an assertion. Record the goldens with
  `CHAUFFEUR_GOLDEN_RECORD=1 swift test --filter SessionUpgradeTests` and `--filter SessionTypeTests`, then READ each
  recorded file and check the table's facts (which `settledMs`, which hint, the request line present or absent) before
  committing; a golden that pins the wrong behaviour is worse than none. Teeth: temporarily delete one line at each
  upgrade site (`report.hints = []` at `Session+Network.swift:114`; `report.settledMs = settle.elapsedMs` at
  `Session+Wait.swift:83`) and watch the matching golden fail; revert, don't commit. Record every live `Expected:`
  these tests duplicate in the ledger's "unit twin" column (`scripts/live-expectations.sh` gains that column: a test
  name per line where one exists).
- [ ] **Step 3: Commit** — `git commit -m "act, tap, scroll, swipe, type and wait have offline tests; the four upgrade paths are pinned"`

### Task 13: Doctor through the wrappers (the §9 wording ruling)

**Files:**
- Modify: `Sources/ChauffeurCore/Doctor.swift:85-189` (use `Device`, `AXProvider`, `HID`, `AXSettings`, `AXHealth.message`; delete its own probe and messages; `import ChauffeurBridge` goes)
- Modify: `Tests/ChauffeurCoreTests/DoctorTests.swift`, `Tests/ChauffeurCoreTests/Fixtures/golden/` (a new `doctor-*.txt` golden per Doctor message, recorded in this task since the text changes by ruling)
- Modify: `CHANGELOG.md` ("Unreleased: `doctor` describes accessibility problems in the same words as a result's note")
- Modify: `CONTRIBUTING.md:31-32` — only the Xcode 27 job (`build-test`) is required since 2026-10-28 (the macos-26
  runners are starved); reword to: CI also runs Xcode 26 when runners are available; it is not required, so check it
  when it runs.

- [ ] **Step 1: Write the failing test** — `DoctorTests` asserts each accessibility finding equals `AXHealth.message(plan, recovered: false)` for the matching plan.
- [ ] **Step 2: Run to verify it fails**
- [ ] **Step 3: Implement**; the lint rule from Task 10b now also forbids `import ChauffeurBridge` in `Doctor.swift`
- [ ] **Step 4: Run the stage** — `scripts/check.sh`; live suites; `scripts/live-expectations.sh` (only Doctor lines differ; note them in the PR)
- [ ] **Step 5: Commit and PR** — `git commit -m "Doctor uses the engine's wrappers and wording"`, push `refactor-1b-inputs`, open the PR.

---

## Stage 2: one pipeline

Branch `refactor-2-pipeline`. PR title: "Refactor 2: evidence passes, one credit, one network watch".

### Task 14: `EvidenceCarrier` and `credit`

**Files:**
- Create: `Sources/ChauffeurCore/Engine/EvidenceCarrier.swift`
- Modify: `Sources/ChauffeurCore/Verifier.swift` (`ActionReport: EvidenceCarrier`, `TypeReport: EvidenceCarrier`; `credit`)
- Test: `Tests/ChauffeurCoreTests/CreditTests.swift`

**Interfaces:**
- Produces:
  ```swift
  public protocol EvidenceCarrier {
      var outcome: Outcome { get set }
      var requests: [RequestItem] { get set }
      var requestElapsedMs: Int { get set }
      var hints: [String] { get set }
  }
  extension ActionReport {
      /// The one way a NO EFFECT becomes a change. `settledMs` is passed, not computed: the three sites keep their conventions.
      public mutating func credit(change after: Snapshot, from before: Snapshot, settledMs: Int, settled: Bool, hints: [String] = [])
      // sets outcome = .changed, revAfter = after.rev, diff = Diff.lines(from: before, to: after), settledMs, settled, hints, evidenceShot = nil
  }
  ```
- [ ] **Step 1: Write the failing test** — a NO EFFECT report credited with two fixture snapshots has `outcome == .changed`, `diff` non-empty, `revAfter == after.rev`, `evidenceShot == nil`, and renders exactly like `GoldenReportTests`'s `changed-diff` case when given the same values.
- [ ] **Step 2: Run to verify it fails** — `credit` undefined
- [ ] **Step 3: Implement**
- [ ] **Step 4: Run** — `swift test`; goldens unchanged
- [ ] **Step 5: Commit** — `git commit -m "credit: the one way a NO EFFECT becomes a change"`

### Task 15: `Classifier`, `ActionContext`, and `act` as the pipeline's first half

**Files:**
- Create: `Sources/ChauffeurCore/Engine/Pipeline.swift` (`ActionContext`, `Classifier`, `TouchClassifier`, `NoTouchClassifier`, `EvidencePass`; under 200 lines)
- Modify: `Sources/ChauffeurCore/Engine/Session+Act.swift:39-98` (`act` uses a classifier and runs passes), `Session+Apps.swift:201-225` (`actWithoutTouch` becomes `act(… classifier: NoTouchClassifier(capMs:note:hints:))`)
- Test: `Tests/ChauffeurCoreTests/ClassifierTests.swift`

**Interfaces:**
- Produces:
  ```swift
  public struct ActionContext {
      public var before: Snapshot; public var baselineSettled: Bool; public var target: Node?
      public var touchMs: Int; public var capMs: Int
      public var net: TapNet?
      public var observe: (_ minMs: Int, _ capMs: Int) throws -> (snapshot: Snapshot, settle: Settled<AXElement>)
      public var clock: any SettleClock
  }
  public protocol Classifier { func classify(context: ActionContext, sent: Bool, touchCursor: Int) throws -> (report: ActionReport, after: Snapshot) }
  public struct TouchClassifier: Classifier { … }     // today's observe(150, capMs) + touch evidence + Verifier.classify
  public struct NoTouchClassifier: Classifier { public init(capMs: Int, note: String, hints: [String]) }  // today's actWithoutTouch loop and rule
  public protocol EvidencePass { func apply(to report: inout ActionReport, context: ActionContext, session: Session) throws }
  ```
  `act(_ label:, target:, before:, baselineSettled:, capMs:, needsMove:, network:, classifier: any Classifier = TouchClassifier(), passes: [any EvidencePass], gesture:)`.
  In this task `passes` is `[]` for every caller and the existing inline code stays where it is; Task 16 moves it.

- [ ] **Step 1: Write the failing tests** — `NoTouchClassifier` on frames [home, home, form, form] returns `.changed`; on frames [home ×4] after the cap returns `.unverified` with the note; `TouchClassifier` with `.app` evidence and no change returns `.noEffect`.
- [ ] **Step 2: Run to verify they fail**
- [ ] **Step 3: Implement; `button` and `open` go through `act` with `NoTouchClassifier`**
- [ ] **Step 4: Run** — `swift test` (goldens, `SessionActTests`, `OpenTests`, `GestureTests` unchanged)
- [ ] **Step 5: Commit** — `git commit -m "act: a pluggable classify step; button and open are the same pipeline"`

### Task 16: The passes

**Files:**
- Create: `Sources/ChauffeurCore/Engine/Passes/NetworkPass.swift`, `ScreenAgainPass.swift`, `SwitchRetryPass.swift`, `ClipboardPass.swift`, `TypingNetworkPass.swift`, `EvidenceShot.swift` (the final screenshot step)
- Modify: `Session+Act.swift` (`tapCommand` declares `passes: [NetworkPass(), ScreenAgainPass(), SwitchRetryPass(), ClipboardPass()]`; the inline switch retry, clipboard check and evidence shot code are deleted), `Session+Network.swift` (`applyNetwork` and `judgeScreenAgain` become the two passes' bodies), `Session+Act.swift:276-281` (`typeCommand` runs `[TypingNetworkPass()]` on its `TypeReport` through `EvidenceCarrier`)
- Test: `Tests/ChauffeurCoreTests/PassTests.swift`

**Interfaces:**
- Consumes: Task 14's `credit`, Task 15's `EvidencePass` and `ActionContext`.
- Produces: each pass `public struct … : EvidencePass { public init() }`. `ClipboardPass` reads the clipboard mark
  taken before the action from `context` (add `clipboardBefore: ClipboardMark?` to `ActionContext`, filled by
  `tapCommand` as today). `EvidenceShot.capture(report:context:session:)` runs after all passes, only when
  `report.outcome == .noEffect`.

- [ ] **Step 1: Write the failing tests**, offline, one per pass:
  - `NetworkPass`: `ScriptedFlows([[waiting]])` → `.pending`, exit 6, headline `"→ PENDING · 127.0.0.1:8765 · sent 58 B, no reply after 2."` (port of `aRawSocketWaitingIsPending`).
  - `ScreenAgainPass`: settled requests and a changed later frame → `.changed` with the diff.
  - `SwitchRetryPass`: a switch target, unchanged after the first tap, changed after the second; two touches recorded.
  - `ClipboardPass`: `clipboardBefore` differs from the shell's `pbpaste` reply → `changed · copied to clipboard (17 characters)`.
  - `TypingNetworkPass`: one sample at `graceMs`; `clock.now` advanced by exactly `NetJudge.graceMs`.
  - Order: with a NO EFFECT and a clipboard change, the evidence shot is not taken (`RecordingShell` saw no `io … screenshot` call); with a plain NO EFFECT it is taken once.
- [ ] **Step 2: Run to verify they fail**
- [ ] **Step 3: Implement the passes and delete the inline code**; `Session+Act.swift` must end under 300 lines
- [ ] **Step 4: Run** — `swift test`; goldens unchanged; `SessionActTests` unchanged
- [ ] **Step 5: Commit** — `git commit -m "Evidence passes: network, screen again, switch retry, clipboard, typing; the shot last"`

### Task 17: `NetworkWatch` and `NetJudge.finish`

**Files:**
- Create: `Sources/ChauffeurCore/Engine/NetworkWatch.swift`
- Modify: `Sources/ChauffeurCore/Network/NetJudge.swift` (add `finish`), `Sources/ChauffeurCore/Engine/Session.swift` (replace `flowSource`, `flowSourceTried`, `pendingTap`, `telemetryOverride` with `let network: NetworkWatch`; keep `telemetryOverride` as a forwarding property until Plan 2), `Session+Network.swift`, `Session+Wait.swift:60-110` (`finishPending` and `stillWaiting` call the watch)
- Test: `Tests/ChauffeurCoreTests/NetJudgeTests.swift`, `Tests/ChauffeurCoreTests/NetworkWatchTests.swift`

**Interfaces:**
- Produces:
  ```swift
  extension NetJudge {
      /// A bare `wait`: poll every `pollMs` until the verdict isn't PENDING or `deadlineMs` passes. No grace, no confirm look.
      public static func finish(clock: some SettleClock, deadlineMs: Int, pollMs: Int = 200, sample: () -> [RequestItem]) -> NetVerdict
  }
  @MainActor public final class NetworkWatch {
      public init(flows: @escaping () -> (any FlowSource)?, processes: any ProcessTable, logs: any LogSource, clock: any SettleClock, telemetry: @escaping () -> [String])
      public var pending: PendingTap?
      public func start(appPid: Int32?, frontmost: Int32?) -> NetStart
      public func atTouch(_ start: NetStart) -> TapNet
      public func judge(afterTouch net: TapNet, textField: Bool) -> NetVerdict          // today's applyNetwork verdict
      public func sampleOnce(_ net: TapNet) -> [RequestItem]                             // typing's one look
      public func finish(_ net: TapNet, deadlineMs: Int) -> NetVerdict                   // finishPending's loop
      public func verdictNow(_ net: TapNet) -> NetVerdict                                // the changed-outcome sample after graceMs
      public func stillWaiting(sinceLogCursor: Int) -> String?
  }
  ```
- [ ] **Step 1: Write the failing tests** — `NetJudgeTests.finishReturnsWhenTheReplyArrivesAndNeverConfirms` (FakeClock: `[open]` until 1000 ms then `[done]` → `.settled` at ≤ 1200 ms with no extra 300 ms); `finishStopsAtTheDeadline` (`[open]` forever, deadline 30 000 → `.pending` at 30 000 ± pollMs). `NetworkWatchTests`: port `SessionNetworkTests` to call the watch directly for `judge`, and a `wait` test through `Session` on `FakeClock` where the pending tap finishes at 2 500 ms (`WaitTests` style).
- [ ] **Step 2: Run to verify they fail**
- [ ] **Step 3: Implement; `Session+Network.swift` shrinks to the two passes' helpers**
- [ ] **Step 4: Run** — `swift test`; goldens unchanged; `scripts/live-expectations.sh` unchanged
- [ ] **Step 5: Commit** — `git commit -m "NetworkWatch: one owner of flows, pids and the pending tap; NetJudge.finish for a bare wait"`

### Task 18: The crash lead by contract, not by string search

**Files:**
- Modify: `Sources/ChauffeurCore/Engine/Args.swift:109` (`Output.withLead(_:)`), `Sources/ChauffeurCore/Engine/Session+Logs.swift:52-58`
- Test: `Tests/ChauffeurCoreTests/AnnotateTests.swift`

**Interfaces:**
- Produces: `extension Output { /// Replaces what follows the first " → " on the first line; the lead contract every report renderer follows. public func withLead(_ lead: String) -> Output }` (my call: `Output` is text by the time `annotate` runs, so the contract is kept in one named function with its own test rather than moved into the renderers; Plan 2 may make it structural).
- [ ] **Step 1: Write the failing test** — `Output("tap e4 \"Pay\" → NO EFFECT · x\nhint: y").withLead("APP CRASHED: z").text == "tap e4 \"Pay\" → APP CRASHED: z\nhint: y"`; a first line without " → " is replaced whole.
- [ ] **Step 2: Run to verify it fails**; **Step 3: Implement and use it in `annotate`**; **Step 4: `swift test`**; **Step 5: Commit** — `git commit -m "The crash lead is placed by one function"`

### Task 19: Stage 2 verification and PR

- [ ] **Step 1: Line counts** — `wc -l Sources/ChauffeurCore/Engine/*.swift | sort -rn | head -5`: every file under 300.
- [ ] **Step 2: `scripts/check.sh`** → `check: all passed`
- [ ] **Step 3: Live suites** on a booted iOS 27 simulator, load under 10: `CHAUFFEUR_LIVE_UDID=<udid> swift test --no-parallel 2>&1 | grep -E "Suite .* (passed|failed)|Test run"` → every suite passes, including `NetworkLiveTests` (14 tests) and `TapLiveTests`.
- [ ] **Step 4: Ledger** — `scripts/live-expectations.sh` → no diff.
- [ ] **Step 5: Timing** — `time swift test` (unit only): no test sleeps; note the wall time in the PR.
- [ ] **Step 6: Changelog** — under Unreleased: "Internal: one evidence pipeline for taps; no result changes." and the Doctor line from Task 13 if it isn't there yet.
- [ ] **Step 7: Push and PR** — `git push -u origin refactor-2-pipeline && gh pr create --base main --title "Refactor 2: evidence passes, one credit, one network watch"`. Merge after CI; then write Plan 2.
  The PR must say that "the shot once, last" changes the artefacts folder: today a NO EFFECT later upgraded by the
  switch retry or the clipboard check has already written its screenshot there; after Task 16 no file is written.

---

## Findings (filled in as the stages run)

- Task 3: the full list of `exit:` literals and the code each became.
- Task 4: which `Date()` uses stayed wall-clock and why.
- Task 14: the three `settledMs` conventions, written down before `credit` is introduced.
- Task 16: any pass whose offline test needed a seam this plan didn't foresee.
- The drift the ledger shows at each stage, resolved by §9's default ruling (the handler wins) and listed here.

### Stage 0 (branch `refactor-0-goldens`)

**Task 3: the exit-code literals.** 47 `exit: <digit>` literals in `Sources`, each now an `ExitCode` case:
33 × `1` → `.error`, 4 × `3` → `.noEffect`, 4 × `4` → `.notFound`, 6 × `64` → `.usage`. Eight of them were the arms of
two catch sites, four in `Session.guarded` and four in `CLI.handleText`; both are now one `Output.failure(error)` call,
and so is `MCPServer.call`'s catch, which had no literal. The `exit: [0-9]` pattern missed 13 more, found in review and
converted in a second commit: the ternaries `exit: anyDelivered ? 0 : 3` (selftest) and `exit: changed ? 0 : 3`
(type's submit); `out.exit = 5` (crash annotation → `.crashed`); in batch, `var exit: Int32 = 0`, `exit = 1`,
`!= 0` and `out.exit == 6`; in `launchCommand`, `var exit: Int32 = 0` and `exit = alive ? 3 : 1`; and the `== 0` /
`!= 0` checks in recover, the MCP server (two) and Doctor (→ `ExitCode.ok.rawValue`). The `exit-literal` lint now also
catches ternary branches and `exit`/`.exit` followed by `=`, `==` or `!=` and a digit.

Left as they are, by ruling: process exit statuses (`exit(64)` and `exit(output.exit)` in
`Sources/chauffeur/main.swift`, `exit(0)`/`exit(1)` in the daemon), and the daemon's version-mismatch code
`versionMismatchExit = 75`. That one *is* carried by an `Output`: `Daemon.respond` returns it, the client retries once,
and on a second mismatch `Daemon.send` returns it, so the CLI can exit 75. It stays out of `ExitCode` because a seventh
case would change `Usage.text`'s exit-code line, which §9 doesn't list. **Plan 2's glossary must decide on 75.**
`Output.exit` stays `Int32` (it is the daemon's wire format); `Output.init(_:exit: ExitCode, data:)` is an overload,
and `ActionReport.exitCode`, `TypeReport.exitCode` and `Doctor.exitCode` return `ExitCode`.

**Task 4: `Date()` and sleeps.** Both engine sleeps now go through the session's clock: selftest's 300 ms pause and
`press`'s hold. Every `Date()` left in `Engine` is a wall-clock time, not a duration, and stays, with a comment:
`launchedAt` (saved with the tracked app, compared with the simulator's boot date and crash report times);
`CrashInfo.detectedAt` (a `Date` field, stored only); the trace line's timestamp; the screenshot file name. Durations
were already measured with `clock.nowMs()`. `Settle.wait` and `NetJudge.judge` take `any SettleClock` instead of
`some` so the session's existential clock can be passed. `SessionNetworkTests` went from 2.65 s to 0.06 s. Raw
`usleep`/`Date()` outside `Engine` (TouchLog, Input, Daemon, LogStream, Doctor) are not Stage 1a work after all: Input's sleeps
move with the HID wrapper in Stage 1b, and TouchLog, LogStream, the daemon and Doctor stay on wall time unless a later seam
needs them (corrected in Stage 1a).

**Where each §1 report shape is pinned.** Task 2's 15 goldens cover every shape §1 lists except two. *Crash* is pinned
byte for byte by `AnnotateTests.aVanishedAppIsACrashReportedOnce`. *Type with submit* is pinned nowhere yet: the
"submit → …" lines and "→ not typed: focusing the field failed" in `Session+Act.swift`'s `typeCommand` need an offline
`type`, which needs Stage 1b's seams. **Task 12 therefore adds an offline `type --submit` test whose rendered output
ends in `Golden.check` (submit changed, submit NO EFFECT, submit NOT DELIVERED), recorded before Stage 2 touches
`typeCommand`.**

**The live expectations ledger.** The header line names the commit it was generated at and changes on every run;
"no diff" means no change from line 3 on. The final review found the script missed `hasSuffix("…")`; it now collects
contains, hasPrefix, hasSuffix and `== "…"`, and the regeneration added only the three `hasSuffix` lines (Batch, Bridge,
Screenshot).

**Live run at the end of Stage 0** (c2e9bfb, iPhone 17 on iOS 27, load 3 at start, 877 s): 455 tests, every live suite
passed, `NetworkLiveTests` included, except `AXLiveTests.anAppStartedWithTheFlagsOffIsToldToRelaunch` (2 issues).
With the accessibility flags turned off, the fixture's tree is still readable, so chauffeur never says "relaunch it";
after the relaunch a system alert covers the app. The same test fails identically on `main` (76cfdf3), so it predates
this refactor: the simulator now exposes the tree with the flags off. It needs its own investigation, outside this
plan. During the run an orphaned `Tests/FixtureApp/netserver.py` from an earlier session held port 8765, so the
network suites ran against it (same script); they passed.

### Stage 1a (branch `refactor-1a-environment`)

**Every `simctl` call in the engine goes through `SessionEnvironment.shell`**, not only the five the plan listed: heal's
`defaults read`, the bridge restart, the clipboard (`pbcopy`, `pbpaste`), install, appinfo, launch, terminate, openurl,
privacy, location, push, appearance, the screenshot and recover's `launchctl list`, 19 calls in all, each with identical
arguments, stdin and timeout. `AXSettings.ensure` takes the shell too, with no default, so no caller can bypass the seam; Doctor never called it
and still runs its own `defaults read` through `SimCtl` until Task 13.
`heal`, `restartBridge` and `ensureAccessibility` moved, unchanged, to `Engine/Session+Heal.swift`.

**Two seams for one fact, until Plan 2.** The `isAlive` closure stays (the plan retires closures in Plan 2) but defaults
to `environment.processes.isAlive`; the saved-app check and `watchedPids` use `processes` directly. A test that overrides
only one of them gets mixed answers. Likewise `simulatorBooted` beside `device.booted`.

**One cast outside `.live`, until Task 10.** `transportsReady` builds the HID client from `(device as? Device)?.sim`;
with a fake device it builds none, and every gesture fails as a bridge error, never a success (`doctor --live`'s selftest
prints nothing and exits 3).

**Task 8's test as planned proved nothing.** `connect()` already runs `ensureAccessibility(force: false)` through the
shell, so "a `defaults write` happened" passes without `heal`. The test asserts heal-only evidence instead: a second,
forced `defaults write` and a `defaults read` after the first write (flags off), and `launchctl stop
com.apple.CoreSimulator.bridge` (flags on, screen answers). Each no-tree `snapshot` spends 3000 fake ms, so heal's
4000 ms patience is reached on the third.

**Task 9's frame lists were off by one.** A stable screen settles in two reads (75 fake ms) per `snapshot`, so
"rev 1, rev 1, rev 2" needs `[home ×4, form ×2]`. The form label is "Agree to terms" ("Email" isn't in the fixture).

**Live run at the end of Stage 1a** (5c9589f, iPhone 17 on iOS 27, 1154 s): 473 tests. Two failed: the pre-existing
`anAppStartedWithTheFlagsOffIsToldToRelaunch` (fails on `main` too), and `aDeadButtonIsPlainAndNotSlower`, while host
load from outside the session rose to about 51: a request from the Network tab's web view to 127.0.0.1:8765 landed in
the dead tap's window (the attribution Stage 5 fixes) and the taps took 1.1 to 2.0 s. `NetworkLiveTests` re-run alone
at load 3: 12 of 12 passed, the dead button included. The ledger body is unchanged.

**For Plan 2:** a task must retire the closure seams still on `Session` after Task 10a: `relaunch`, `commandHook`,
`telemetryOverride` and `crashReportWaitMs` (`isAlive`, `simulatorBooted`, `simulatorBootDate` and `findCrashReport`
move into `SessionEnvironment` in Task 10a, after the Fable review of this stage found that neutral closures set on the
session would have been a second seam style; `processes` is then the only answer to "is this process alive" and the
environment's `simulatorBooted` the only one to "is the simulator booted", beside `device.booted` for the connected
device). Stage 5's `Sweep` should also lift `complete` off `AXSource`, so the bar sweep runs on top of any source
(spec §2) and can be tested offline.

### Stage 1b (branch `refactor-1b-inputs`)

**The plan was amended before execution** (commit 0106398), from the Fable review of Stage 1a: Task 10 split into 10a and
10b, the closures moved into the environment, and Task 12 gained the upgrade-path pins. That supersedes two Stage 1a
lines above: Task 7's "the closure seams stay as they are in this plan" and the "Two seams for one fact, until Plan 2"
paragraph. After 10a, `processes` is the only liveness seam, and `.live`'s `inputs` holds the `Device` cast that
`transportsReady` used to make.

**HID owns the client.** `CHHIDClient` appears only in `Device/HID.swift` (lint `hid-owner`); `HID.open()` returns
nothing, so no other file can get hold of the client without naming it. `Input.swift` has no `usleep`: taps, drags and
the keyboard wait on the session's clock. A failed send now does explicitly what the rebuild used to do implicitly:
`inputDevice.reset()`, `preferred = 0`, and `inputDeviceLost`, which keeps `type`'s "HID client lost after focusing"
error. The plan's `try inputDevice().keyboard(...)` would have removed that error on two reachable paths (a focus tap
whose send failed with the touch log unattached, and a reconnect inside `observe`), so it was kept by ruling. The method
is `inputDeviceReady()`, since Swift won't allow a method and a property both named `inputDevice`.

**Task 11's protocol was wrong in the plan** (a `start(bundle:pid:)` that doesn't exist); `LogSource` lists what
`Session` reads from `LogTap`, and `LogTap.append` is public. `SessionNetworkTests` runs on `.scripted` (0.05 s) with
its flow source built up front, as `netStart()` builds it in production.

**Task 12: what the recorded goldens showed against the table.** Diff lines are `-`/`+` only (the table's `~ … off → on`
was notation). A text node gets no ref, so a scroll's found line is `found text "Label 69" after …`, as the live
`ScrollLiveTests` expects; "Row 48" isn't in `fixture-longlist`, so the scroll uses `long-scrollview`. The screen-again
`settledMs` (770 ms) counts from the touch and so includes the 50 ms hold. The `wait` pin needs a tap that settles later
than the wait (225 ms against 150 ms), or deleting `Session+Wait.swift:83` changes nothing. Offline, a NO EFFECT has no
`screen:` line, because `capture` finds no file. The live ledger's unit-twin column comes from `scripts/live-twins.tsv`;
only the twinned lines changed.

**Not pinned yet, and needed before Stage 2 Task 16:** `judgeScreenAgain` skips replies that are telemetry only
(`Session+Network.swift`, the `!$0.telemetry` guard). Nothing pins that it doesn't fire for them, and it guards against
a false `changed`. A pin needs `ScriptedLogs` to release log lines after the touch, because flow-only items are never
telemetry. **Task 16 writes that pin first.** Also unpinned: the drop-inside-`observe` path of `inputDeviceLost`.

**Task 13: Doctor's wording, by ruling.** The relaunch and no-tree findings are `AXHealth.message(plan, recovered:
false)`. The relaunch line has no flags clause, because Doctor only reads the flags. The poisoned-bridge line keeps
Doctor's own text, because every `AXHealth` bridge message says chauffeur restarted the bridge, and Doctor never does.
The flags-off warning keeps its text, because no plan covers flags off with a tree. One finding changed, not only
its wording: with no tree and the flags off, Doctor says to relaunch, as `Session` decides, where it used to point at
the bridge or say "no tree". The old bridge text's "chauffeur does this itself after 4 s" was false in that case.
This is in the CHANGELOG. For Plan 2's glossary: the two `AXHealth` lines drop Doctor's `accessibility:` prefix, and
the no-tree line says "run: chauffeur doctor" inside doctor's own output.

**For Plan 2:** `AXProvider` has two public inits (`init(sim:)` for `.live` and the live tests, `init(device:)` for
Doctor); `button` and `selftest` have no offline test (`FakeInputs.pressed` is ready for one); `Session.swift` is 323
lines, over the 300 aim.

**Live run at the end of Stage 1b** (ab24da8, iPhone 17 on iOS 27, load 5 at start and about 57 by the end from
activity outside the session, 881 s): 515 tests; only the pre-existing `anAppStartedWithTheFlagsOffIsToldToRelaunch`
failed (2 issues, fails on `main` too). `NetworkLiveTests` passed, the dead button included. The live ledger's body is
unchanged from line 3 on; against `main`, only the nine twinned lines gained their twin column.
