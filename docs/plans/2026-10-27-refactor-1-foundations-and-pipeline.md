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
- No verdict changes. No user-visible text changes except §9's Doctor ruling (Task 14). A golden test that fails is a
  bug in the task, never a reason to re-record the golden.
- After every stage that touches `Engine`, `Device`, `Perception`, `Screen` or the bridge (all four here), run
  `CHAUFFEUR_LIVE_UDID=<udid> swift test --no-parallel` on a booted iOS 27 simulator with load under 10 and nothing
  else building.
- Every stage ends with `scripts/check.sh` passing, a branch, a PR, and a merge before the next stage starts.
- Commit with the noreply identity; no AI co-author trailer.

## Review Focus

1. `wait --timeout 600` must still wait 300 s, not fail usage (Task 10 pins it offline: the clamp is `Session.waitTimeout`).
2. A session whose accessibility source returns no tree for longer than `AXHealth.patienceMs` must still heal
   (flags, bridge restart) through the shell seam, not silently stop (Task 10 pins `heal` offline).
3. A transport whose send fails must drop the HID client and rebuild it on the next action, as today (Task 13).
4. A tap on a screen with an unattached touch log must come back UNVERIFIED, never `changed` (Task 13).
5. After Stage 2, the evidence screenshot must exist exactly when the final verdict is NO EFFECT and never when a
   pass upgraded it (Task 17).

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

### Task 10: `InputDevice` and `HID`

**Files:**
- Create: `Sources/ChauffeurCore/Device/HID.swift`
- Modify: `Sources/ChauffeurCore/Device/Input.swift` (transports and `Keyboard` take `HID`, not `CHHIDClient`; the
  `import ChauffeurBridge` moves to `HID.swift`), `Sources/ChauffeurCore/Engine/Session.swift:10-12` (remove `hid`,
  `transports`, `preferred` stays), `Session+Act.swift:19-35` (`transportsReady` uses `environment.inputs`),
  `Session+Act.swift:238-239` (`Keyboard` from inputs), `Session+Gestures.swift:56-66` (`press` moves into `HID`),
  `Sources/ChauffeurCore/Engine/SessionEnvironment.swift` (add `inputs`)
- Test: `Tests/ChauffeurCoreTests/HIDTests.swift`

**Interfaces:**
- Produces:
  ```swift
  @MainActor public protocol InputDevice: AnyObject {
      func transports() throws -> [TouchTransport]   // digitizer first, then mouse
      func keyboard() throws -> any TextInput
      func press(_ button: HardwareButton, holdMs: Int, clock: any SettleClock) throws -> Bool
      func reset()                                      // after a failed send: rebuild the client next time
  }
  public protocol TextInput { func type(_ text: String) -> Bool; func press(_ usage: UInt32, modifiers: [UInt32]) -> Bool }
  @MainActor public final class HID: InputDevice { public init(device: Device) }   // the ONE owner of CHHIDClient
  ```
  `SessionEnvironment.inputs: @MainActor (any SimDevice) throws -> any InputDevice`. Test fake `FakeInputs`
  (`Support.swift`): `init(transports: [FakeTransport], keyboard: FakeTextInput = …, press: Bool = true)`;
  `FakeTransport(name: String, supportsMove: Bool, sends: Bool)` records every `touch` call in `touches`;
  `FakeInputs.resetCount` counts `reset()` calls (Task 12 asserts it). `SessionEnvironment.scripted` gains an
  `inputs:` parameter here and a `logs:` parameter in Task 11.

- [ ] **Step 1: Write the failing tests** (`FakeInputs` behaviour; `HID` is an `InputDevice`; `grep -c CHHIDClient Sources/ChauffeurCore/Engine` is 0 — assert via a test that reads the files? No: add the rule to `scripts/check-code.sh`: `CHHIDClient` may appear only in `Device/HID.swift`.)
- [ ] **Step 2: Run to verify it fails**
- [ ] **Step 3: Implement `HID`, `InputDevice`, `TextInput`; move `press`; route `transportsReady`, `typeCommand` and `buttonCommand` through `environment.inputs`; `drop()` calls `inputs.reset()` semantics (the session forgets its `InputDevice` and asks the environment again)**
- [ ] **Step 4: Run** — `swift test`; `scripts/check-code.sh` (new rule passes)
- [ ] **Step 5: Commit** — `git commit -m "HID: one owner of the HID client; InputDevice is the seam"`

### Task 11: `LogSource`

**Files:**
- Create: add `LogSource` to `Sources/ChauffeurCore/Device/Seams.swift`
- Modify: `Sources/ChauffeurCore/Logs/LogTap.swift:112` (conform), `SessionEnvironment` (add `logs`), every `logTap.` use in `Engine` (`grep -n "logTap" Sources/ChauffeurCore/Engine/*.swift`)
- Test: existing tests that call `s.logTap.append` keep working through `s.logs.append`

**Interfaces:**
- Produces: `public protocol LogSource: AnyObject { var isAttached: Bool { get }; var cursor: Int { get }; func since(_ cursor: Int) -> [LogLine]; func append(_ line: LogLine); func start(bundle: String, pid: Int32) throws; func stop() }`
  (copy `LogTap`'s real `start` signature). `Session.logs: any LogSource`.

- [ ] **Step 1: Rename in tests first** (`logTap` → `logs` in `SessionNetworkTests`, `AnnotateTests`, `LogTapTests` where they go through Session) and run: compile error.
- [ ] **Step 2: Implement; run `swift test`; commit** — `git commit -m "LogSource: the launched app's log is a seam"`

### Task 12: `act` offline

**Files:**
- Test: `Tests/ChauffeurCoreTests/SessionActTests.swift` (under 600 lines; split into `SessionActTests` and `SessionGestureTests` if needed)

- [ ] **Step 1: Write the failing tests**, each building a session with `.scripted(...)` plus `inputs: FakeInputs(...)` and `touches: ScriptedTouches(...)`:

```swift
@Test func aChangeOnTheNextFrameIsCredited() throws {
    // frames: home ×2 (baseline), form ×2 (after); touches: .app("dev.chauffeur.fixture")
    let out = s.run(["tap", "e3"])   // the ref for "Show alert" in fixture-home
    #expect(out.exit == 0 && out.text.hasPrefix("tap e3 \"Show alert\" → changed · settled"), out.text)
}
@Test func noTouchEvidenceRetriesOnTheNextTransportThenNotDelivered() throws {
    // touches: [.none, .none]; transports: [digitizer, mouse], both send
    #expect(out.text.contains("NOT DELIVERED")); #expect(inputs.transports.map(\.touches.count) == [2, 2])
}
@Test func anUnattachedTouchLogIsUnverified() throws { /* ScriptedTouches(attached: false) → "UNVERIFIED" */ }
@Test func aFailedSendDropsTheClientAndRebuildsIt() throws { /* FakeTransport(sends: false) → after the action, inputs.resetCount == 1 */ }
@Test func aTouchThatLandedInAnotherAppIsIntercepted() throws { /* .app("com.apple.springboard") with expectedApp set via launch bookkeeping → "INTERCEPTED" */ }
@Test func theSwitchIsTappedAgainWhenTheFirstTouchWasIgnored() throws { /* frames: a switch row, unchanged, then changed; two touches recorded */ }
@Test func scrollReportsTheFoundLine() throws { /* fixture-longlist, --until "Row 48" */ }
@Test func swipeIsVerifiedByTheScreen() throws { /* frames differ after → changed */ }
```

Use `fixture-home.json` refs by running `Perception.build` in the test to look up `"Show alert"`'s ref rather than
hard-coding `e3`.

- [ ] **Step 2: Run to verify they fail/compile** — the first run must compile and the assertions must pass; a failure is a wiring bug in Tasks 10 and 11. Record every live `Expected:` these tests duplicate in the ledger's "unit twin" column (`scripts/live-expectations.sh` gains that column: a test name per line where one exists).
- [ ] **Step 3: Commit** — `git commit -m "act, tap, scroll and swipe have offline tests"`

### Task 13: Doctor through the wrappers (the §9 wording ruling)

**Files:**
- Modify: `Sources/ChauffeurCore/Doctor.swift:85-189` (use `Device`, `AXProvider`, `HID`, `AXSettings`, `AXHealth.message`; delete its own probe and messages; `import ChauffeurBridge` goes)
- Modify: `Tests/ChauffeurCoreTests/DoctorTests.swift`, `Tests/ChauffeurCoreTests/Fixtures/golden/` (a new `doctor-*.txt` golden per Doctor message, recorded in this task since the text changes by ruling)
- Modify: `CHANGELOG.md` ("Unreleased: `doctor` describes accessibility problems in the same words as a result's note")

- [ ] **Step 1: Write the failing test** — `DoctorTests` asserts each accessibility finding equals `AXHealth.message(plan, recovered: false)` for the matching plan.
- [ ] **Step 2: Run to verify it fails**
- [ ] **Step 3: Implement**; the lint rule from Task 10 now also forbids `import ChauffeurBridge` in `Doctor.swift`
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
`usleep`/`Date()` outside `Engine` (TouchLog, Input, Daemon, LogStream, Doctor) are Stage 1a's.

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
