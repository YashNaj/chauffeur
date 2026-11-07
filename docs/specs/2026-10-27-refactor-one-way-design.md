# Refactor: one way to do each thing

**Status:** draft for review · **Date:** 2026-10-27

## Why

chauffeur's code is written and extended by agents and read by its owner in pull requests. That sets the bar for the
code: an agent adding a feature must find exactly one way to do each thing and exactly one place to add it, and a
reviewer must be able to tell from a diff that a change is right without reading the whole engine. Today neither
holds. Two audits of the tree on 2026-10-27 (76cfdf3) found:

- **A new command touches eight places kept in sync by hand**: the dispatch switch, the CLI forward list, the
  logged and watched sets, its own `usage:` string, the `Usage.text` copy, the MCP tool schema, the MCP argv mapping,
  and the skill's command table. Nothing derives one from another, and they have drifted: `logs --last` allows 500
  in the CLI and 200 in the MCP schema; the skill's exit-code line lacks exit 6; the outcome list is written four
  times as four different subsets; the untrusted-text rule is written five times.
- **A tap's verdict can be upgraded from NO EFFECT in four hand-written ways** (the switch retry, the screen
  re-judge, the pending finish, the clipboard), each rewriting a different subset of the report's fields, and
  network judgment exists four times. The evidence screenshot is taken inside `act` and discarded when a later pass
  upgrades the verdict. `Session+Act.swift` is at 389 of the 400-line cap; the next evidence source breaks the lint.
- **The engine has no offline tests.** `Session` builds its own clock, accessibility provider and HID client, so
  `act`, `observe`, `baseline`, `wait` and every gesture are covered only by the live suites. Unit tests that touch
  the network path sleep for real seconds.
- **The HID client is used from five places** where the accessibility, simulator and network bridges each have one
  Swift wrapper. The bridge's dictionary keys are string literals written in Objective-C and read in Swift with no
  shared constant, and `CHSimulator.m` makes nine `valueForKey:` calls with no exception guard: an Xcode rename
  there takes the daemon down, the risk the "no `try!`" rule exists to prevent.
- **The web-views spec needs changes perception can't take cleanly**: the settle loop hashes only the raw tree, the
  sweep cache is keyed only by that hash, the tree builder is a private struct, and the sweep step and targets are
  hard-coded.

This document is the design for fixing that, in stages, with no change to any verdict and no change to any
user-visible text except the ones listed in §9. It comes before the web-views work because the web-views plan would
otherwise add a fifth verdict upgrade, a second sweep, and a ninth place to register a command.

## Goals

1. **One registry.** A command is declared once (name, usage, options with their ranges, traits, handler); the CLI
   dispatch, the usage text, the batch and logging traits, the MCP tool schema and the skill's table are derived
   from it.
2. **One pipeline.** An action is: baseline, gesture, observe, classify, then an ordered list of evidence passes
   that share one way to credit a change; every gesture declares its passes; the evidence screenshot is taken once,
   last, only when the verdict is still NO EFFECT.
3. **One wrapper per private capability, one way to write the bridge.** Each private framework has exactly one
   Swift type in front of it; inside the bridge there is one way to load a library, resolve a symbol, read a key
   safely, wait on a reply and build an error.
4. **One seam style.** Dependencies enter `Session` through its initialiser, the way `Connect` already does, so the
   whole engine runs offline against recorded trees, a fake transport and a fake clock. Unit tests never sleep.
5. **One glossary.** Outcomes, exit codes and the untrusted-text rule are defined once and rendered into the usage
   text, the skill and the MCP instructions from that definition.
6. **Perception ready for web views**: an observe knows whether it serves a snapshot or a verdict; the sweep is a
   component with a step and a filter; the builder is a type of its own; a request line can name its source process.
7. **Every stage is a pull request that passes `scripts/check.sh` and the live suites, with golden tests pinning the
   text it must not change.** No stage changes a verdict. Measured at the end by the "Done when" list.

## Non-goals

- A rewrite in another language. See §10: the private frameworks are reached through the Objective-C runtime, and
  Swift's native interop with an Objective-C target is the right tool; Rust would reach the same frameworks through
  untyped runtime calls with no checking at all.
- New SwiftPM targets for their own sake. Three targets (bridge, core, CLI) are the right count for one binary; the
  boundaries this design draws are folders and types inside `ChauffeurCore`, enforced by the lint, not by the
  package manifest.
- Merging the three NDJSON framings (socket, daemon, MCP stdio) or the daemon protocol. Not worth the risk.
- New behaviour. The web-views work, the request-source fix beyond what §9 lists, and anything on the roadmap come
  after, through their own specs.

## Anti-goals

- A big-bang branch. Six stages, six pull requests, each shippable on its own and each leaving `main` green.
- "While I'm here" cleanups inside a stage. A stage does what its section says and nothing else.
- Any output change that isn't in §9, however small. A golden test that fails is a bug in the stage, not a reason to
  update the golden.

## Constraints

- The project's rules stand: private API only in `ChauffeurBridge`; no `try!` or `print` in `Sources`; files under
  400 lines in `Sources` and 600 in `Tests`; fakes behind seams, never flags in production code; live tests after any
  change under `Engine`, `Device`, `Perception`, `Screen` or the bridge.
- One owner, one 8 GB Mac, one subscription. Stages are sized so each is a day of agent work with one live run at
  the end, not a week.
- Outputs are the product. Agents read every line chauffeur prints, and the benchmark numbers depend on them.

## 1. Golden tests first

Before any stage, pin what must not change, as unit tests over recorded inputs:

- `Usage.text` byte for byte; the skill markdown and the AGENTS section; the MCP instructions; the MCP tool list
  with its schema as JSON.
- Rendered reports: for each outcome and each evidence shape (change with diff, NO EFFECT with a failed request,
  PENDING, copy, crash, type with submit), one `ActionReport`/`TypeReport` built from fixtures, rendered as text and
  as JSON.
- Every `Expected:` line the live tests assert, collected into one place the plan can diff against.

These tests are the contract for the whole refactor. A stage may change a golden only for a change listed in §9,
in the same pull request, with the changelog line.

## 2. One seam style: dependencies in, no sleeping tests

`Session` gains an initialiser that takes its environment, modelled on `Connect`'s `Environment`:

```swift
struct SessionEnvironment {
    var clock: any SettleClock               // SystemClock in production
    var device: (String) throws -> any SimDevice   // Device (booted, size, the CHSimulator) in production
    var ax: (any SimDevice) throws -> any AXSource  // AXProvider in production
    var inputs: (any SimDevice) throws -> any InputDevice // HID (new, §4) in production
    var touchEvidence: any TouchEvidenceSource // TouchLog in production: evidence(since:waitMs:), cursor, isAttached
    var logs: any LogSource                  // LogTap in production: since(cursor), cursor, append for tests
    var shell: any ShellRunner               // SimCtl / Shell in production
    var flows: () -> (any FlowSource)?        // NetStatsSource in production
    var processes: any ProcessTable          // sysctl in production
}
```

Touch evidence, logs and the device are in the environment (my call, from the reviewer's check): without a touch
evidence seam an offline `act` could never see `.app` evidence, so `classify` could never reach `changed` or `retry`,
and the offline tests in "Done when" would be impossible. `heal`'s direct `SimCtl` calls go through `shell`. This
makes stage 1 larger than first estimated, so the staging table splits it in two.

- The existing closure seams (`isAlive`, `findCrashReport`, `simulatorBooted`, `simulatorBootDate`, `relaunch`,
  `commandHook`, `telemetryOverride`, `crashReportWaitMs`) move into the environment one at a time; the plan
  retires each closure when its last test is ported. No second style survives.
- `AXSource` is the protocol `AXProvider` already satisfies in shape: `read()`, `read(pid:)`, `frontmostPID()`,
  `element(at:)`. `AXProvider`'s sweep and cache sit on top of any `AXSource`.
- A recorded tree (`Tests/ChauffeurCoreTests/Fixtures/ax`) replays as a fake `AXSource` whose `read()` returns the
  next frame of a scripted sequence; a fake `InputDevice` records the gestures it was asked to send. With those two
  and `FakeClock`, `act` runs offline: transport fallback, the retry, the Verifier's inputs, settle and rev bumps,
  `baseline`, `wait`, and every evidence pass.
- Every `usleep`, `Date()` and `sleep` in the engine goes through the clock. The three unit tests that sleep today
  (`aRawSocketWaitingIsPending` 2 s; two more 300 ms each) run in milliseconds.
- The live suites stay. They prove the bridge; the new unit tests prove the engine.

## 3. One pipeline: evidence passes

`act` becomes a fixed sequence with one extension point:

1. baseline (unless given), gesture through the transport order, observe, touch evidence, `Verifier.classify`;
2. the gesture's **evidence passes**, in order;
3. if the outcome is still NO EFFECT, the evidence screenshot.

An evidence pass is one type:

```swift
protocol EvidencePass {
    /// Looks again, with whatever the pass watches, and may upgrade the report. Never downgrades.
    func apply(to report: inout ActionReport, context: ActionContext) throws
}
```

with `ActionContext` carrying the baseline snapshot, the target node, the touch time, the clock and the observe
function. The four upgrades become four passes that all call one method:

```swift
extension ActionReport {
    /// The one way a NO EFFECT becomes a change: the diff, the revisions, the settle, the hints, the screenshot.
    mutating func credit(change after: Snapshot, from before: Snapshot, settle: Settle, hints: [String] = [])
}
```

- `NetworkPass` (judge after the touch, set PENDING), `ScreenAgainPass` (judge the screen again after a reply),
  `SwitchRetryPass` (the late switch, or one more tap), `ClipboardPass`, and `TypingNetworkPass` (one look after
  the grace, no window: typing is verified by the field, so a late request must not make it a false NO EFFECT, as
  the code says today). Each is a file under `Engine/Passes/`.
- Each gesture declares its passes, and the declaration reproduces today's behaviour exactly: tap runs network,
  screen-again, switch retry, clipboard; type runs `TypingNetworkPass` only; scroll, swipe, button and open run
  none. (My call, from the reviewer's check: type does not get the 2 s window or the screen re-judge, because that
  would change its timing and verdicts.)
- **The classify step is pluggable, so `button` and `open` fit without a touch.** Step 1's "observe, touch evidence,
  classify" is a `Classifier`: `TouchClassifier` wraps `Verifier.classify`; `NoTouchClassifier` is today's
  `actWithoutTouch` rule (observe until the tree differs or the cap runs out; UNVERIFIED or UNATTRIBUTED from whether
  the baseline settled). Same pipeline, two classifiers, no verdict changes.
- **Passes operate on one report shape.** `ActionReport` and `TypeReport` adopt an `EvidenceCarrier` protocol
  (outcome, requests, hints, the lead) so a pass can serve typing without merging the two report types.
- **Network judgment is one component.** `NetworkWatch` owns the flow source, the telemetry list, the watched pids
  and the pending tap, and exposes `judge(afterTouch:)`, `sampleOnce()` and `finish(deadline:)`. `NetJudge` gains the
  finish mode `finishPending` needs: poll until the verdict isn't PENDING or the deadline passes, no grace, no
  confirm look, so a bare `wait` behaves exactly as today. `stillWaiting` reads from `NetworkWatch`.
- `settledMs` is kept per site exactly as today (the three sites compute it differently); `credit` takes it as an
  argument rather than deciding. Changing that is a later ruling, not this refactor.
- The log and crash annotation (`annotate`) stops rewriting the first line by searching for `" → "`: the report
  carries a `lead` the renderer places, and annotation sets it. Output stays byte-identical.

Result: `Session+Act.swift` drops well under the cap, the sequencing is explicit, and the fifth evidence source
(web views) is one file and one line in a gesture's pass list.

## 4. One wrapper per capability, one way to write the bridge

**Swift side.** `Device/HID.swift` is the single owner of `CHHIDClient`: it vends the transports, the keyboard and
the hardware buttons. `Session`, `Doctor`, `Input` and `Session+Gestures` go through it. After this, each private
capability has one Swift type: `AXProvider`, `HID`, `NetStatsSource`, `Device`.

**Doctor** keeps running in the CLI process (it must work when no daemon can start), but it stops re-implementing
`Session`'s probes: it uses the same `AXSource`, `HID` and `AXSettings` wrappers and renders its accessibility
findings with `AXHealth.message`, the text `Session` already prints. Its wording changes to match; that is a ruling
in §9 (my call: the two texts describe one condition and should read the same).

**`frontmostPid` keeps its own round trip.** Taking the pid from the last tree read could be stale after an app
switch, and `watchedPids` relies on it when no app was launched. Only the translation setup is deduplicated.

**A guarded read that fails throws.** When a `CHValue` read on `CHSimulator` fails, the Swift side gets
`ChauffeurError.bridge`, never a default such as "not booted": that path tears the session down and drops the
tracked app, which a failed read must not cause.

**Bridge side**, all in `CHInternal.h` and used by every `.m` file:

- `CHError(code, message)` on `CHBridgeErrorDomain` with distinct codes; the Swift side maps it to
  `ChauffeurError.bridge` in one place.
- `CHValue`, `CHString`, `CHNumber`: exception-guarded KVC reads. `CHSimulator.m`'s nine bare `valueForKey:` calls
  use them.
- `CHLoad(path)` and `CHSym(handle, name)`: one loading style (`RTLD_NOW`, cached handle); the nine
  `lib ? dlsym : NULL` lines in `CHNetStats.m` become nine `CHSym` lines.
- `CHWaitSync(timeout, block)` for the three semaphore copies.
- `CHAXReader` gets a private `-rootForTranslation:token:` so the translation setup is written once, and
  `frontmostPid` stops making a second round trip.
- `keyUsage:` goes; `usagePage:` is the one HID send.

**Shared keys.** `ChauffeurBridge.h` exports the dictionary keys (`CHAXRole`, `CHAXFrame`, `CHFlowPid`, …) and both
the Objective-C writers and the Swift initialisers use them. A renamed key then fails to compile instead of
returning nil.

## 5. One registry: commands declared once

```swift
struct CommandSpec {
    let name: String
    let usage: String                  // the literal usage line, padding and all: "tap <ref|x,y> [--long <s>] [--edge]"
    let positionals: [PositionalSpec]  // name, kind, required
    let options: [OptionSpec]          // name, kind (flag, number with range and clamp, enum with cases, text), help
    let traits: Traits                 // forwarded, logged, watched, batchable, agent (exposed to MCP and the skill)
    let run: Handler                   // .daemon((Session, [String]) throws -> Output) or .local(([String]) throws -> Output)
}
```

- `Commands.all` is the one list. From it: `Session.dispatch` (the `.daemon` handlers), the CLI's local dispatch
  (the `.local` ones: `use`, `doctor`, `mcp`, `skill`, `help`, `version`, `keys`), `CLI.forwarded`, the `logged`,
  `watched` and `batchable` sets, `Usage.text`, and the `Args` parser each handler uses (the handler no longer
  carries its own usage string; `Args` is built from the spec, so a range lives in one place).
- **`keys` stays out of the daemon and the MCP schema by construction**: its spec is `.local` with `agent: false`,
  the MCP derivation includes only `agent: true` specs, and a test asserts `keys` is absent from the tool list and
  from the daemon dispatch. M5a's property ("for humans, never an agent") becomes a trait a test checks, not a
  convention a reviewer remembers.
- **One range per option, with `clamp`.** `wait --timeout` is declared `0...300, clamp: true`: a larger value
  clamps to 300 as today instead of becoming a usage error, and the published schema says 300. No option carries two
  ranges.
- **The usage line is a literal in the spec**, not derived from the options: `Usage.text`'s column padding is
  irregular and must stay byte-identical. The literal is still written once.
- **The MCP tools are derived** by a declarative table: tool property → (command, option or positional), with the
  type, range and enum taken from the spec, plus per-tool hooks for the few special cases (the `find`/`wait_for`
  exclusion, the push payload written to a file, the `args` array). A property that serves two commands with
  different cases (`mode` for `permission` and `appearance`) stays untyped, as today; a property that serves one
  command gets that command's enum. The seven grouped tools and their hand-written descriptions stay.
  `MCPTools.swift`'s second switch over commands goes, and the MCP error texts join the golden tests. Agent stops
  reaching into Engine for `privacyServices`; it reads the enum from the spec.
- **The skill's command table** and the AGENTS section are rendered from the specs: a `skillRow` on the spec (the
  "Need" phrasing and the example invocation) keeps the table's shape; commands without a row today get none.
- The drift found by the audit is resolved by deliberate rulings in §9, not by whichever copy the refactor happens
  to keep.

Adding a command after this is: one `CommandSpec` and one handler. Changing a range is one number.

## 6. One glossary

`Outcome` already exists for verdicts. It gains, next to it, `ExitCode` (an enum with the six codes; the 50 bare
`exit:` literals in `Sources` become cases) and one `Glossary` that renders the outcome list, the exit-code line and
the untrusted-text rule. The usage text, the skill, the AGENTS section and the MCP instructions all render from it,
so the skill can no longer lack exit 6 and the MCP instructions can no longer lack TEXT MISMATCH.

Errors become text and exit codes in one function, used by `Session.guarded`, `CLI.handleText` and
`MCPServer.call`; `ConnectError` maps through the same function.

## 7. Rendering with the models, helpers in one place

- `Shot.line`/`Shot.json` move to `Screen`; `describe(ScreenKind)` becomes `ScreenKind.description`; launch,
  terminate, install, logs and the type submit line get report types next to `TypeReport`, rendered by the
  model, so Engine builds data and never strings.
- `ScreenText` (escape, quote, length caps) is its own file; `Perception.quote` forwards to it until its callers
  move. Text safety is cross-cutting and lives with no module.
- Small shared helpers, each replacing copies: `Endpoint` (parse and format host and port; four copies today),
  `Proc` (one `kinfo` read; two copies), `SimProcesses.helpers(ofApp:)` (the WebKit networking and WebContent
  lookups, used by the network layer and by perception), `LogStream(level:predicate:)` with a `LogFollower` base
  (`TouchLog` and `LogTap` shrink), `Blocking<T>` (four semaphore boxes), `Plist.dict`, one date formatter, the
  found line, point parsing and ref recognition.
- `Connect` keeps its style; it is the template. `ConnectKeys.handle`'s parsing becomes a `CommandSpec` like every
  other command, so there is one place commands live.

## 8. Perception ready for web views

Done last, because it's the only part the web-views plan depends on directly:

- `Builder` moves to `Perception/Builder.swift` as an internal type. Its identity, ordinal and ref logic are what
  web children will reuse under a `webview` ancestor.
- `Sweep(step:filter:)` replaces the hard-coded 32 pt step and `isSweepTarget`; the bar sweep is one instance of it.
- `observe` takes a purpose, `.snapshot` or `.verdict`, threaded from `baseline`, `act`, `finishPending` and `wait`.
  In this refactor the purpose is carried but changes nothing: both purposes serve the cached sweep keyed by the raw
  hash, exactly as today, so a verdict still compares like with like. The web-views plan is what adds the
  fingerprint to the key and the fresh sweep for verdicts, with its own golden tests; doing it here without a
  fingerprint would compare a fresh sweep after the gesture with a cached one before it, which can differ on its
  own and give a false `changed`. (My call, from the reviewer's check.)
- `AXSource.read()` returns a `Frame` (the root, and room for a fingerprint) so the settle loop can hash more than
  the tree later without changing its shape again.
- `RequestItem` gains `process` (and the JSON a `process` field), set from the flow's process name (activity layer)
  or the app's executable (log records). The rule for the line: "the app" is the launched app's executable, or the
  frontmost pid's process when nothing was launched; a request whose process is the app prints as today; the WebKit
  networking process prints as `web view`; any other helper prints its process name. So:
  `request: web view · 127.0.0.1:8765 · sent 451 B, got 341 B`. The log-record-to-flow match requires the pid as
  well as the port, so an app record can no longer claim a WebKit flow. **This changes output** (§9).

## 9. Output changes, each a ruling

Everything else in this document is byte-identical. These are the only changes, each with its changelog line:

| Change | Ruling | Why |
|---|---|---|
| MCP `logs.last` maximum 200 → 500 | the CLI's range wins; the schema follows the spec | one range, one place |
| MCP `wait.timeout` maximum 300 | kept; the CLI's 86 400 is clamped to 300 anyway, so the spec declares 300 | the published schema is already right |
| `location` and `do` usage lines | the handler's text wins over `Usage.text` | the handler is what an error prints |
| Skill exit-code line gains `6` | fixed by the glossary | an omission |
| MCP instructions gain TEXT MISMATCH and APP EXITED | fixed by the glossary | an omission |
| Request lines name a non-app source process (`request: web view · 127.0.0.1:8765 · …`) | new text, from §8 | the benchmark's one chauffeur miss (2026-10-27) |
| Log-record-to-flow matching requires the pid | an app record can't claim another process's connection | a latent misattribution |
| Doctor's accessibility findings use `AXHealth.message` | one text for one condition (§4) | two wordings today |
| Agent-facing instruction text is rendered from the glossary in one wording (the untrusted-text rule, the outcome list, the exit-code line, the skill's command table) | owner's decision, 2026-10-27: one wording, with a changelog line | five wordings of one rule today; keeping each surface byte-identical would mean storing per-surface variants, which defeats the goal; the text explains results and is not itself a result |

**Default ruling for drift the plan finds beyond this table:** the handler (what the CLI actually does and prints
on an error) wins; agent-facing instruction text follows it; verdict text and result lines never change. Any drift
the plan resolves this way is listed in its ledger and in the changelog. The web-views spec's "Expected:" lines and
the benchmark doc are updated in the same pull request as the request-line rulings.

## 10. Why not Rust

The whole value of chauffeur sits behind Apple's private frameworks (AccessibilityPlatformTranslation,
CoreSimulator, SimulatorKit, NetworkStatistics), reached through the Objective-C runtime. Swift calls them through a
small Objective-C target with real types, exceptions caught in one place, and a compiler that checks the Swift side.
Rust would reach the same classes through `dlopen`, runtime class lookup and untyped message sends, because its
Objective-C bindings are generated from public SDKs only; every private call would be hand-written and unchecked,
the daemon would be an FFI boundary away from every crash, and nothing about the problems in this document (eight
registries, four upgrades, five HID owners) is a language problem. The language stays. The shape changes.

## Staging

Each stage is one pull request, in this order, each leaving `main` green with the golden tests and the live suites
passing:

| Stage | Contents | Size | Risk |
|---|---|---|---|
| 0 | Golden tests (§1); `ExitCode` and the one error mapping (§6, codes only); clock injection (§2, clock only) | ~250 lines | low |
| 1a | `SessionEnvironment` with clock, device, `AXSource`, touch evidence, shell; `heal` through `shell`; first offline tests of `observe`, `baseline`, `wait` and `act`'s classify step (§2) | ~350 lines | medium |
| 1b | `InputDevice` and the `HID` wrapper, `LogSource`, Doctor through the wrappers (§2, §4 Swift side); offline tests of the gestures and the retry | ~300 lines | medium |
| 2 | Evidence passes, the two classifiers, `EvidenceCarrier`, `credit`, `NetworkWatch` with the finish mode, `annotate` by field (§3) | ~500 lines | medium: the verdict path, full live run |
| 3 | `CommandSpec`, derived usage, dispatch, traits, MCP schema, skill table, glossary text (§5, §6) | ~600 lines | medium: schema rulings in §9 |
| 4 | Bridge internals and shared keys (§4 bridge side); rendering moves and shared helpers (§7) | ~400 lines | low to medium: live run for the bridge |
| 5 | Perception for web views and request source (§8), with the two output rulings | ~250 lines | medium |

A stage that grows past its size stops and splits. Stages 0 to 2 are the ones the web-views plan needs; 3 to 5 can
interleave with it if the owner prefers, but 5 must land before the web-views sweep.

## Done when

Measured, not asserted:

- Adding a command touches two places: a `CommandSpec` and a handler. Proved by adding a throwaway command in a
  test and asserting it appears in usage, dispatch, the MCP schema and the skill table.
- Adding an evidence pass is one file and one entry in a gesture's list. Proved by a test pass that credits a change
  from a scripted frame.
- `act`, `baseline`, `wait`, `finishPending` and every gesture have offline tests against recorded trees, a fake
  transport and a fake clock; no unit test sleeps (the suite's wall time drops by at least the 2.6 s it sleeps today).
- `grep` finds: one `dlopen`, one `dlsym` helper, one semaphore helper and one error constructor in the bridge; zero
  bare `valueForKey:`; one owner of `CHHIDClient`; zero bare `exit:` literals in `Sources`; one `usage:` literal per
  command (in its spec); the outcome list and the exit-code line in one file.
- No `Sources` file over 300 lines (the lint stays at 400; the margin is the point).
- The golden tests pass unchanged except for the seven rulings in §9, each with its changelog line.
- Every live suite passes on iOS 27 after stages 1, 2, 4 and 5.

## Findings

Filled in by the plan: the exact list of `exit:` literals and their intended codes; the full drift table between the
CLI and the MCP schema (the audit found four; the plan's step 0 greps for all); the `settledMs` conventions at the
three sites, written down before `credit` is introduced.

### Decision

Approved by the owner on 2026-10-27 with §9 as written, including one wording for agent-facing instruction text.
The eleven other calls the builder check raised are marked "my call" in §2, §3, §4, §5 and §8 and stand unless the
owner objects. Next: the plan, staged as in the table above, written with the plan skill.

### Amendments accepted

2026-10-29, Plan 2 Stage 2b: amendment 6 (`relaunch` and `commandHook` deleted, not moved into the environment),
amendment 9 (`EvidenceCarrier` and `TypingNetworkPass` deleted; both reports keep `requests` and `requestElapsedMs`),
and Task 24's reversal (`ActionContext` is plain data; the classifier reads the session) — see
docs/plans/2026-10-29-refactor-2-registry-bridge-perception.md, "Spec amendments proposed".
