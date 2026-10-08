# chauffeur — design

This is the design document chauffeur was built from, with notes from each milestone.

Date: 2026-10-06 · Status: draft for review

An open-source (Apache-2.0), telemetry-free driver that lets LLM coding agents operate
the iOS Simulator reliably: see the screen as a compact element tree, act on it,
and get told the truth about whether each action worked.

Background: market and technical research, and a touch-injection spike on Xcode 26.3 (neither is published).

## 1. Decisions already made

| Decision | Choice | Why |
|---|---|---|
| Audience | Native SwiftUI/UIKit devs using Claude Code / Cursor / Codex on their own Mac | The gap: leaders are React Native–first or build-first |
| Scope | Post-build only: install, launch, see, act, verify, logs | Builds are commoditised (`xcodebuild`, Xcode MCP, MobileBuildMCP) |
| Shape | One Swift binary; per-simulator background daemon; CLI + agent skill + MCP mode as thin frontends | Warm state = ms-level actions and "what changed" diffs |
| Language | Swift 6 core, small Objective-C target for private-framework declarations | Private APIs are ObjC/Swift; HID message builders need the main thread |
| License | Apache-2.0 (chosen at release; drafted as MIT), no telemetry, no network access | Incumbents drifting to FSL, closed binaries, telemetry |

## 2. Success criteria (v1 is done when)

1. **Production-app flow.** In Claude Code, an agent installs and launches
   `com.example.app`, completes one real multi-screen flow (≥ 8 actions
   including text entry and a scroll), and reads the app's logs. No screenshots
   required.
2. **Repeatable.** The scripted version of that flow passes 10/10 runs.
3. **No silent misses.** Across all acceptance runs, every action's reported
   outcome matches reality (checked by screenshot review). An action that did
   nothing is never reported as success.
4. **Control app.** The same checks pass on a Settings flow
   (`com.apple.Preferences`), so we are not tuned to one app.
5. **Token budget.** Median snapshot ≤ 400 tokens; median action result ≤ 150
   tokens (measured with the Anthropic token-counting API on acceptance logs).
6. **Compatibility.** Xcode 26.x verified locally; Xcode 27 verified in CI.

## 3. The pain points, refined

Ranked by how badly they hurt an agent. "Silent" failures rank highest because
an agent cannot recover from something it is told succeeded.

**P1 — Silent no-op actions (critical).** Taps that report OK and do nothing.
Evidence: AXe #71 (Xcode 27 drops the first gesture from a short-lived process;
0/6 delivered), orca #23997 (Device Hub's `dtuhidd` makes iOS ignore legacy
input), MobileBuildMCP #453, and our own spike — the first 4 taps of the session
reported success, reached the Settings app per backboardd, and changed nothing;
the next 44 all landed. Root causes are plural (input path changes, cold
connections, overlays intercepting), so the fix is not "pick the right API" but
**verify every action and explain misses** (§6.2).

**P2 — Incomplete element trees (critical).** The private accessibility API
misses SwiftUI toolbar items and the NavigationBar back button (AXe #43);
mobile-mcp misses iOS elements (#88); custom-drawn views and Flutter are
invisible. A tree-first tool whose tree lacks the back button strands the agent.
Mitigation: measure completeness first (M0), merge a Vision-OCR fallback for
regions the tree doesn't cover, and always allow ref-less coordinate actions
derived from a point-scaled screenshot (§6.4).

**P3 — Breakage on every Xcode release (high).** Xcode 26 changed the HID
function signature (5 → 9 args); Xcode 27 moved SimulatorKit to
`SharedFrameworks` and added `dtuhidd`. idb, AXe, MobileBuildMCP and the Claude
pane all broke. Mitigation: runtime framework discovery, swappable input
transports chosen by a self-test, `chauffeur doctor`, and a CI matrix including
Xcode betas from June each year (§6.1, §10).

**P4 — Token burn and session-killing images (high).** Screenshot loops cost
~1,500 tokens per look; oversized images crash Claude sessions (mobile-mcp
#140); stale snapshots accumulate in context. Mitigation: tree-first snapshots,
diffs after actions, screenshots only on request at 1 px = 1 pt with a size
ceiling, artifacts written to files with paths returned (§5).

**P5 — Coordinate and gesture traps (medium).** Pixel vs point confusion is
mobile-mcp's top issue (#29); touches within ~4 pt of an edge trigger system
gestures silently (Claude pane); our spike's 9-arg path flagged taps as
`fromEdge`. Mitigation: everything in points, one Geometry module, an edge guard,
and ref-based actions by default (§6.5).

**P6 — System UI the app doesn't own (medium).** Permission prompts and alerts
belong to SpringBoard; AXe can't tap them (#41). Mitigation: pre-empt with
`simctl privacy grant`, include SpringBoard alerts in snapshots if the tree
exposes them (M0 spike), report "intercepted by system UI" when the Verifier sees
a touch go to SpringBoard (§6.2).

**P7 — Install and setup pain (medium).** idb's top issues are all installation
(#604, #649, #646). Mitigation: one signed, notarised binary; `brew install`;
no Python, companion or Node; `chauffeur skill install` writes the agent skill.

**P8 — Prompt injection via screen text (medium, cheap to fix now).** On-screen
text, including hidden accessibility nodes, can carry instructions (15–82%
attack success on Android agents). Mitigation: drop hidden nodes, present screen
text as quoted data, and say so in the skill (§8).

## 4. Architecture

```
 agent ──shell──▶ chauffeur <cmd> ──┐
 agent ──MCP────▶ chauffeur mcp ────┤  unix socket per simulator, version handshake
                                    ▼
                chauffeurd  (same binary: `chauffeur daemon --udid …`)
 ┌────────────────────────────────────────────────────────────────────┐
 │ Commands — the only API the frontends call                         │
 │  ├─ Perception   snapshot · refs · diff · settle · find            │
 │  │    ├─ AXProvider (AXPTranslator)    ├─ OCRProvider (Vision)      │
 │  │    └─ Screen (capture, downscale, zoom)                          │
 │  ├─ Input        tap · type · swipe · scroll-until · press-button   │
 │  │    └─ HIDTransport ◀ IndigoMouse | Digitizer | DTUHID (Xcode 27) │
 │  ├─ Verifier     did the action land? if not, why?                  │
 │  │    └─ TouchLog (backboardd stream)                               │
 │  ├─ Geometry     points, scale, orientation, edge guard            │
 │  ├─ LogTap       app log stream + crash reports since last action   │
 │  ├─ SimControl   simctl: install, launch, openurl, privacy, push…   │
 │  └─ Trace        append-only action log (for later test export)     │
 │ Supervisor   device state, reconnects, idle exit                    │
 │ SimBridge    framework discovery, SimDevice resolution (ObjC target)│
 └────────────────────────────────────────────────────────────────────┘
```

Unit boundaries:

| Unit | Does | Depends on | Tested with |
|---|---|---|---|
| SimBridge | Finds Xcode frameworks (xcode-select dir, `PrivateFrameworks`, `SharedFrameworks`), resolves `SimDevice`, exposes typed wrappers for private calls | CoreSimulator, SimulatorKit (dlopen) | Live sim |
| HIDTransport | `send(touch:)`, `send(key:)`, `send(button:)`; reports `health` | SimBridge | Live sim, spike recipes |
| Geometry | Converts refs/points to normalised transport coords; orientation; edge guard | Screen metrics | Pure unit tests |
| AXProvider | Raw accessibility tree for the frontmost app + SpringBoard overlays | SimBridge, AccessibilityPlatformTranslation | Live sim; recorded fixtures |
| OCRProvider | Text boxes for screen regions the tree doesn't cover | Screen, Vision | Fixture images |
| Perception | Normalise, prune, assign refs, serialise, diff, settle-wait | AXProvider, OCRProvider (data only) | Pure unit tests on fixtures |
| Verifier | Classifies each action's outcome (§6.2) | Perception, TouchLog | Pure unit tests on a decision table |
| TouchLog | Streams backboardd touch-delivery records | `simctl spawn log stream` | Live sim |
| LogTap | Buffers app logs; detects crashes | `log stream`, DiagnosticReports | Live sim |
| SimControl | Thin typed `simctl` wrapper | `xcrun simctl` | Live sim |
| Supervisor | Lifecycle, reconnects, idle shutdown | Everything above | Fault-injection tests |
| Trace | JSONL of every command + outcome | — | Unit |
| Frontends | CLI parsing/printing, MCP adapter, skill installer | Commands | Golden-output tests |

Rule: only SimBridge, HIDTransport, AXProvider and TouchLog touch private or
undocumented surfaces. Perception, Verifier and Geometry operate on plain value
types so they are testable without a simulator.

## 5. Agent-facing interface

### 5.1 Commands (v1)

```
chauffeur use <name|udid>                 pin the target simulator for this directory
chauffeur doctor [--live]                 environment + transport self-test report
chauffeur install <path.app> | launch <bundle> [--args …] | terminate <bundle>
chauffeur open <url>                      deep link / universal link
chauffeur permission <grant|revoke|reset> <service> <bundle>
chauffeur location <lat,lon> | push <bundle> <payload.json> | appearance <light|dark>

chauffeur snapshot [--all] [--screenshot]  pruned element tree; --all adds coordinates
chauffeur find "<text or role:text>"        matching refs only
chauffeur screenshot [--zoom <ref|x,y,w,h>] writes JPEG, prints path + size

chauffeur tap <ref | x,y> [--long <s>]
chauffeur type <ref> "<text>" [--submit]
chauffeur scroll <up|down|left|right> [--in <ref>] [--until "<query>"]
chauffeur swipe <x1,y1> <x2,y2> [--edge]
chauffeur button <home|lock|siri|volume-up|volume-down>
chauffeur wait "<query>" [--gone] [--timeout <s>]
chauffeur do '<cmd>; <cmd>; …'            batch; stops at first failure

chauffeur logs [--since-last] [--last <n>] [--level error]
chauffeur skill install [--agents claude,codex,cursor]
chauffeur mcp                              MCP server over stdio (same commands)
```

Target resolution: `--udid` › `CHAUFFEUR_UDID` › `.chauffeur.json` written by
`chauffeur use` › the only booted simulator › error listing booted simulators.

All output is compact text by default; `--json` returns the same data as JSON.
Large artifacts (screenshots, full logs) are files; only paths are printed.

### 5.2 Snapshot format

Indented outline, one element per line, refs only on actionable or
referenced elements. Screen text is always quoted.

```
app com.example.app · screen "Sign in" · 402×874pt portrait · rev 7
nav "Sign in"
  button "Back" [e1]
textfield "Email" [e2] value=""
securefield "Password" [e3]
button "Sign in" [e4] disabled
link "Forgot password?" [e5]
↓ 3 more below — scroll down
```

- Pruned: invisible, zero-size, offscreen (summarised as the `↓` line), and
  purely decorative containers.
- Coordinates omitted by default (`--all` adds `@x,y,w,h` in points).
- OCR-derived nodes, when present, are marked `ocr "Continue" [e9]`.
- SpringBoard alerts appear at the top under `system alert "…"`.

### 5.3 Refs

A ref is a short handle (`e4`) bound to an element identity:
`(role, accessibilityIdentifier ?? label, nearest labelled ancestor, ordinal)`.
Within a daemon session the same identity keeps the same ref across snapshots,
so `e4` still means "Sign in" after the screen changes, as long as it exists.
A ref whose element is gone returns `stale ref e4 ("Sign in") — not on screen;
run snapshot` instead of tapping where it used to be.

### 5.4 Action results

Every action returns outcome, diff and new log lines:

```
tap e4 "Sign in" → changed · settled 340ms · rev 7→8
+ system alert "Incorrect password"
+   button "OK" [e10]
logs: [error] AuthService: 401 Unauthorized (1 more: chauffeur logs --since-last)
```

```
tap e4 "Sign in" → NO EFFECT · touch reached com.example.app at (201,612)
  but nothing changed in 1.5s
hint: e4 is disabled. Fill e2 and e3 first.
```

```
tap e4 "Sign in" → NOT DELIVERED · retried via digitizer transport · still no touch
hint: input transport unhealthy — run `chauffeur doctor --live`
```

Errors always say what to do next.

## 6. Key mechanisms

### 6.1 Input transports and self-test

- `IndigoMouseTransport`: 9-arg `IndigoHIDMessageForMouseNSEvent`, target `0x32`,
  normalised coords. Spike: 24/24 after warm-up on Xcode 26.3.
- `DigitizerTransport`: IOHIDEvent digitizer parent + finger →
  `IndigoHIDMessageForTrackpadEventFromHIDEventRef` → patch target bytes
  (0x6c/0x10c) and edge bytes. Spike: 20/20. Supports edge flags properly.
- `DTUHIDTransport` (Xcode 27): XPC to the guest's `dtuhidd` digitizer service,
  following iosef PR #15. Built and verified in CI only (local machine stays on
  26.3).
- All HID message construction runs on the main actor.
- Selection: on daemon start, choose by Xcode version and probe
  (`com.apple.coredevice.dtuhidd.active` → DTUHID). The first action of a session
  is treated as the live self-test: if the Verifier says NOT DELIVERED, retry once
  on the next transport and remember the winner. `doctor --live` runs an explicit
  tap on a harmless target (status bar) and reports.
- Default for Xcode 26: `DigitizerTransport` (correct edge semantics).

### 6.2 Verification (the core promise)

For every action:

1. Take the cached pre-action tree hash (the daemon always holds the latest).
2. Note the TouchLog cursor; dispatch the action.
3. Settle-wait (§6.3).
4. Classify:

| Tree changed? | Touch evidence | Outcome reported |
|---|---|---|
| yes | any | `changed` + diff |
| no | delivered to the target app at the expected point | `NO EFFECT` + hints (disabled, not hittable, covered, needs scroll) |
| no | delivered to SpringBoard / another window | `INTERCEPTED by <owner>` + what's on top |
| no | none recorded | retry once on the alternate transport → `changed` or `NOT DELIVERED` |
| no | TouchLog unavailable | `UNVERIFIED: no visible change` (never "ok") |

`type` additionally checks the field's `value` contains the text. `wait` and
`find` are read-only and skip this.

TouchLog: while the daemon runs it raises `com.apple.BackBoard` logging to
debug inside the simulator (needed for per-touch coordinates and destinations,
as the spike showed) and restores the prior level on exit and on idle shutdown.
`doctor` reports if a previous crash left it raised.

### 6.3 Settle detection

Poll the AX tree (target 50–100 ms per poll; confirmed in M0). Settled when two
consecutive hashes match and at least 150 ms have passed since the action;
cap at 1.5 s for taps, 3 s for launches and navigation, configurable. The
reported `settled Nms` tells the agent if it's racing an animation.

### 6.4 Tree completeness fallback

After building the tree, Perception computes screen coverage: regions of the
screenshot with visible content but no tree element. If coverage gaps exceed a
threshold, OCRProvider runs Vision text recognition on those regions only and
merges results as `ocr` nodes with refs (tappable via their boxes). Screenshot
capture for this is only taken when the tree looks sparse (heuristic: fewer than
3 actionable elements, or known-gap patterns such as a nav bar with no back
button; thresholds tuned on S1 fixtures). Whether this is v1 or later depends on the M0 completeness measurement.

### 6.5 Geometry

All public coordinates are points in the current orientation. Geometry owns:
device point size, scale, orientation, and conversion to the transport's
normalised space. Edge guard: a tap or swipe start within 6 pt of an edge is
refused unless `--edge` is passed, with an explanation. Screenshots are
downscaled to 1 px = 1 pt, JPEG, and capped at 1568 px on the long edge, so
image coordinates equal tap coordinates.

### 6.6 Text input

ASCII via HID keyboard events; anything else via `simctl pbcopy` + paste. Focus
the field by tapping its ref first; verify via the field's value; `--submit`
sends Return. Secure fields can't be read back, so verification falls back to
"keyboard events delivered + no error".

### 6.7 Scroll until visible

`scroll --until "<query>"` repeats short swipes inside the nearest scrollable
ancestor, re-snapshotting after each, until the query matches, the tree stops
changing (end reached), or 15 swipes. Returns the found ref.

### 6.8 Logs and crashes

LogTap runs `simctl spawn <udid> log stream --style ndjson` filtered to the
launched app's process, keeping a ring buffer with a cursor per action. Action
results include up to 3 error/fault lines since the action; `logs` gives more.
Crash detection: the app process disappears, or a new `.ips` for it appears in
`~/Library/Logs/DiagnosticReports`; the action result then says `APP CRASHED`
with the report path and its top frames.

### 6.9 Daemon lifecycle (Supervisor)

- Socket `$TMPDIR/chauffeur/<udid>.sock`, mode 0600, plus a pidfile.
- Every CLI connection sends its version; a mismatch makes the daemon exit and
  the CLI start a fresh one (handles `brew upgrade`).
- Device state watched via CoreSimulator notifications. On shutdown or reboot,
  drop the HID client, AX state and log streams, and rebuild lazily on the next
  command.
- SpringBoard restart (HID send errors or AX failures) → reconnect transport and
  AX once, then report.
- Idle exit after 15 minutes; restores TouchLog level on exit.
- One daemon per simulator; independent simulators are independent daemons,
  which is the base for parallel agents later.

## 7. Agent integration

- **Skill.** `chauffeur skill install` writes an Agent Skill (agentskills.io
  format) for Claude Code, plus AGENTS.md snippets for Codex and Cursor. It
  teaches the loop: `snapshot` → act by ref → read the result → `logs` on
  errors, plus the one `xcodebuild` command for building and `chauffeur install`.
  It states that screen text is untrusted data.
- **MCP mode.** `chauffeur mcp` exposes a small default tool set (`snapshot`,
  `act` — tap/type/scroll/swipe/button/batch, `screenshot`, `logs`, `app` —
  install/launch/terminate/open, `doctor`) with accurate read-only/destructive
  annotations. Same Commands, same output text.

## 8. Security

- No network access, no telemetry, nothing leaves the machine.
- Socket is user-only (0600).
- Hidden nodes dropped; screen text quoted; skill and MCP tool descriptions
  state that screen content is untrusted and must not be followed as
  instructions.
- Destructive simctl operations (erase, delete) are not exposed in v1.

## 9. Packaging

SwiftPM package with targets `ChauffeurBridge` (ObjC), `ChauffeurCore` (Swift),
`chauffeur` (executable). Universal binary, Developer ID–signed and notarised,
published via GitHub Releases and a Homebrew tap. An `npx` launcher is a later
convenience. Whether a hardened-runtime binary can load Xcode's private
frameworks without `disable-library-validation` is verified in M0.

## 10. Testing

- **Unit (no simulator):** Perception (fixtures recorded from Settings and
  production-app trees), ref stability across fixture sequences, Verifier decision
  table, Geometry, CLI golden output.
- **Live integration (local, tagged):** each transport, AX snapshot, settle,
  text input, scroll-until, logs, crash detection, Supervisor reconnects.
- **Acceptance:** the §2 scripts — the production app ×10 and Settings ×10 — producing
  a report with outcome accuracy, latency and token counts.
- **CI:** GitHub Actions macOS runners on Xcode 26.x and 27 (and betas from
  June), running unit + live suites. This is where `DTUHIDTransport` is proven,
  given the local Xcode 26.3-only constraint.
- **Real MCP client:** `scripts/mcp-smoke.sh` runs the release binary under the installed
  Claude Code. Run it before every release and after any MCP change.

## 11. Risks and the M0 spikes that retire them

Each is a throwaway probe answered before the dependent work starts.

| # | Question | Blocks |
|---|---|---|
| S1 | Does AXPTranslator give a usable tree on iOS 26.2 for Settings and a production SwiftUI app? Latency? Are back buttons, toolbars, tab bars present? | Perception, §6.4 priority |
| S2 | Do SpringBoard alerts and permission prompts appear in the tree, and do taps on them land? | P6 |
| S3 | Can a long-running `log stream` on backboardd at debug level give per-touch destination + point within ~200 ms? Can the prior level be read and restored? | Verifier |
| S4 | Text input: HID keyboard for ASCII, pbcopy+paste for Unicode, with and without the software keyboard showing | `type` |
| S5 | Does a signed, hardened-runtime binary load SimulatorKit/CoreSimulator? | Packaging |
| S6 | On an Xcode 27 CI runner: does either legacy transport work; does the iosef dtuhidd recipe work? | Xcode 27 support |

If S1 shows significant gaps, OCR fallback (§6.4) moves into M1. If S3 fails,
the Verifier falls back to tree-diff-only with `UNVERIFIED` outcomes, and P1's
guarantee weakens to "never reports success without a visible change".

## 12. Milestones

Each milestone gets its own implementation plan; M0 findings are appended to
this spec before the M1 plan is written.

- **M0 — Spikes S1–S6** (throwaway, findings appended to this spec).
- **M1 — Core loop:** SimBridge, Supervisor, Digitizer + IndigoMouse transports,
  Geometry, AXProvider, Perception (snapshot, refs, diff, settle), Verifier,
  TouchLog, CLI `snapshot/tap/type/scroll/wait/find`, `doctor`.
- **M2 — Agent surface:** LogTap + crash detection, SimControl commands,
  `do` batching, `screenshot --zoom`, skill installer, MCP mode, Trace.
- **M3a — Reliability and honest verification**: self-healing accessibility
  (flags and a poisoned simulator bridge), honest launch, NO EFFECT evidence, APP EXITED vs
  APP CRASHED, a real-client MCP smoke test; accepted by the head-to-head re-run
  (see [the benchmark](benchmark.md)).
- **M3b — Open-source release:** Apache-2.0, a Homebrew tap that builds from source, a README led by the
  launch benchmark, demos from real runs, v0.1.0. (Signing and DTUHID in CI were deferred.)
- **Later (designed for, not built):** export Trace as XCUITest / Maestro YAML,
  XCTest-runner backend for real devices and stubborn system UI, parallel
  simulator orchestration, IOSurface framebuffer capture for faster screenshots.
- **Next spike after launch: games.** Most games draw their own UI, so the accessibility tree is empty. The spike:
  - add a small SpriteKit game to the test app that reports its state (positions, score, screen) as log lines;
  - add a fast input loop without per-tap verification;
  - use a typed decision model (TypeSafe's Jev, a "System One" model that returns schema-checked decisions in one
    fast pass) for moment-to-moment play, with the coding agent setting goals and judging outcomes.

  Measure decisions per second, level completion and cost. Open questions:
  - whether Jev accepts images (state reports are the safer route either way);
  - frame capture speed (today's screenshots take about 0.6 s);
  - an opt-in exception to the no-network rule for a hosted model.

  Targets: automated playtesting, crash and soft-lock hunting, menu and purchase-flow smoke tests, balance runs.
  Turn-based and casual games come before real-time ones.

## 13. Non-goals for v1

Building apps; real devices; Android; cloud simulators; visual regression
baselines; network inspection; recording video.

## 14. M0 findings (2026-10-06, Xcode 26.3 / iOS 26.2)

The spike code and raw results are not published; the findings are summarised here.

**S1 — tree completeness and latency: usable, with known holes.** AXPTranslator's frontmost read works with no
PID fallback; median 20–50 ms on fixture/Settings screens, 137 ms on a 68-node production-app screen, ~500 ms cold.
The tree walk **misses toolbar items and tab-bar items** (fixture Filter/Add; the production app's back button, Camera,
More, all five tabs): their containers appear with frames but no children. A hit-test sweep
(`objectAtPoint:displayId:bridgeDelegateToken:`) finds all of them, including the selected tab, but a full
32 pt grid costs 2.7 s. SwiftUI `List` exposes only visible rows; the production app's ScrollView exposes everything
(y up to 1940 on an 874 pt screen). Empty text fields report their placeholder as value. Right after launch the
root is an empty `Application` with a 0×0 frame (+0.3 s), complete by +0.6 s. SpringBoard's tree comes back
when it's frontmost.

**S2 — system UI: fully reachable.** App alerts and SpringBoard permission prompts both appear in the frontmost
tree (an alert makes the tree contain only the alert). Host-side digitizer taps dismiss SpringBoard prompts.
`simctl privacy grant location` pre-empts the prompt; `grant notifications` is unsupported.

**S3 — touch evidence: works.** A debug-level backboardd stream yields, per touch, the receiving scene
(bundle id) and the exact point, typically 6–30 ms after sending. A tap on a disabled button shows evidence
with an unchanged tree (NO EFFECT); SpringBoard touches carry no sceneID. `log config --reset` restores the
factory level, not the previous one, so the prior mode must be saved and re-applied; SIGINT handling verified.

**S4 — text: HID for ASCII, paste otherwise.** HID page-7 keys typed `Ab@1.test_X` exactly (~35 ms/char).
`é`/emoji are reported unsupported; `simctl pbcopy` + Cmd+V typed `café 🚕` in ~0.5 s with no paste banner.
Secure fields read back as bullets. The software keyboard never appears. A SwiftUI Toggle row ignores a tap at
its centre; tapping the switch near the right edge works.

**S5 — signing: no entitlements needed.** Ad-hoc and team-signed hardened-runtime binaries both load
CoreSimulator, SimulatorKit and AccessibilityPlatformTranslation. Developer ID to be confirmed at M3.

**S6 — Xcode 27: all three transports work.** On Xcode 27.0 (27A266a), digitizer, mouse and dtuhid all land
on both the iOS 26.2 and iOS 27.0 runtimes (53–60 ms; dtuhid 62–71 ms warm, 0.4–1.2 s on first connect).
SimulatorKit's HID client was not removed, and dtuhid is now vended for 26.2 too. Every failure seen was host
load (8 GB Mac, load average 216 during the iOS 27 first boot): `simctl` calls stalled for minutes,
CoreSimulatorService needed a restart, dtuhid's fixed 4 s liveness probe expired once, and the AX tree took >3 s
to settle after launch. `Simulator.app` no longer ships inside Xcode 27; nothing depends on it. The CI workflow stays available for Xcode 26 coverage.

**Also observed earlier** (hid-tap spike): the first 4 taps of a session silently did nothing, later 44/44 landed.
Not reproduced since; the Verifier exists for exactly this.

### Decisions changed by M0

1. **Targeted hit-test sweep moves into M1** (AXProvider): sweep only inside nodes that have a frame and no
   children (nav-bar host, `Tab Bar` group); cache results per screen revision. OCR stays a later extension.
2. **No separate SpringBoard path**: the frontmost read covers home screen and prompts. Perception tags a
   SpringBoard root over an app as `system alert`.
3. **Perception prunes off-screen nodes by frame** and summarises them; a 0×0 root counts as "not settled".
4. **Verifier keeps full touch evidence** (spec §6.2 table stands). TouchLog is a long-lived stream; Supervisor
   saves and restores the exact prior BackBoard level.
5. **`type`**: HID when every character maps to page 7, otherwise paste the whole string; verify via value
   (placeholder-aware), bullet count for secure fields.
6. **Per-role tap points**: `AXSwitch` taps near its right edge, not the centre.
7. **Signing**: Developer ID + hardened runtime, no entitlements; CI signing needs a non-interactive keychain.
8. **Default transport: digitizer on Xcode 26 and 27**, mouse as fallback; dtuhid is a third transport behind
   the same protocol, connected once per session with a backoff liveness budget (~10 s), not a fixed 4 s.
9. **Supervisor bounds every `simctl` call with a timeout** and reports an unresponsive CoreSimulatorService as
   a named condition; "settled" means polling the tree, never a fixed post-launch sleep.

### M1 notes (implementation deviations and measurements)

- Socket files are named by the first 8 characters of the udid (`$TMPDIR/chauffeur/AF7CFC76.sock`): full-udid
  paths came within 4 bytes of the 104-byte unix-socket limit.
- `--json` output moves to M2, with the MCP adapter that needs it.
- Landscape is detected (root wider than tall) and refused with an explanation; conversion is M2+.
- The Verifier's `expectedApp` is nil until M2's `launch` supplies a bundle id, so a touch on another app's
  scene counts as NO EFFECT, not INTERCEPTED.
- Device state is checked lazily on each command (cached device still booted? no tree → reconnect once) instead of
  subscribing to CoreSimulator notifications (§6.9); a mid-session reboot test passes.
- Placeholder attribute: exposed (`accessibilityPlaceholderValue`, e.g. "Email"), so empty fields render `value=""`.
- Tab-bar items and segmented-control segments are `AXRadioButton` (value 1 = selected). They render as `tab`
  inside the tab bar and `radio` elsewhere, both with refs.
- A just-presented alert drops touches until ~200 ms after its tree settles (iOS 26.2). Actions therefore wait
  until 500 ms after the last observed screen change; back-to-back alert taps failed 3/3 without it.
- When a diff is cut at 12 lines, additions are listed first: a full-screen change otherwise showed only removals.
- iOS 27 shows the software keyboard when a field is focused (26.2 never did, S4). On the simulator's first-ever
  keyboard presentation under heavy load, one `type` returned "no accessibility tree yet" (an honest error, not a
  false success); not reproduced in 3 direct tries or a second full acceptance run.
- The daemon drives the main run loop, not `dispatchMain()`: the latter runs main-queue work off the main thread,
  where the mouse transport traps.
- Measured 2026-10-06 (Xcode 27.0, iPhone 17 Pro iOS 26.2 / iPhone 18 Pro iOS 27.0, 8 GB host):
  cold first command (daemon start) 2.3 s; warm `snapshot` via CLI ~375 ms; bar sweep 376 ms; tap → changed settles
  in 220–660 ms; first tap of a session 1.9 s (HID + touch log start); `doctor --live` digitizer 86 ms, mouse
  101 ms. Acceptance 19/19 on iOS 26.2 and 19/19 on iOS 27.0 (first 27 run 16/19, see keyboard note), every step
  checked against its screenshot. Live tests must run serially (`swift test --no-parallel`).

### M2 notes (implementation deviations and measurements)

- MCP is dual-era: protocol 2026-07-28 (stateless, per-request `_meta`, `server/discover`) and the `initialize`
  handshake for 2025-11-25, 2025-06-18 and 2025-03-26. Seven tools: §7's six plus `device` (permission, location,
  push, appearance); `find` and `wait` are options of `snapshot`. Results are the CLI text (`isError` = exit ≠ 0);
  screenshots also come back inline. `tools/list` is about 8 KB (8.4 KB measured).
- Crashes: the launched app's process vanishing is APP CRASHED (exit 5) at once. macOS wrote the `.ips` within the
  3-minute polling window in every acceptance run (17–70 s while planning; the exact delay was not re-measured), so
  results wait at most 3 s and `logs` shows the report later.
- LogTap follows only apps started with `chauffeur launch`, by executable name, at info level and above; `print()`
  output is not captured.
- `button home`: worked with Indigo source 0x0 and target 0x33 on both runtimes (iPhone 17/18 Pro, no home button).
  The accessibility tree lags the screen by over a second after it, so actions without touch evidence (`button`,
  `open`) keep observing until the tree differs or a cap passes (button 4 s, open 3 s) instead of trusting the
  first stable tree. `lock` and `siri` reach the simulator too (checked by hand; not live-tested because they leave
  it locked or in Siri). Volume presses leave no visible change: UNVERIFIED.
- `open` with a custom scheme: iOS 26.2 and 27.0 ask `Open in "Fixture"?` (SpringBoard) first, so the result is
  `changed` with the alert in the diff and the agent taps Open. `simctl openurl` exits 194 with OSStatus -10814 (not
  115) when no app handles the scheme.
- `simctl push` on iOS 27.0 fails with `Source is not authorized` for an app that was never granted notification
  permission (simctl cannot grant it, S2); iOS 26.2 accepted the same payload.
- Tab-bar items get a new ref after a tab switch (Home was e9, then e15), so refs of tab items should be looked up
  again after switching tabs (M1 ref behaviour, not changed).
- Requests carry `cwd` and `udid`. The trace is `$TMPDIR/chauffeur/<udid8>.trace.jsonl`; screenshots and `logs.txt`
  live in `$TMPDIR/chauffeur/<udid8>/`.
- Measured 2026-10-07 (iOS 26.2 / iOS 27.0, medians from the trace): `launch` 2.4 s / 3.9 s (first iOS 27 launches
  after a boot up to 10 s), `screenshot` 594 ms / 597 ms, `open` 1.07 s / 1.09 s, `button home` 2.2 s / 2.8 s; M2
  acceptance 41/41 (production app installed) and 37/37 (first iOS 27 run 36/37: a cold Settings launch took longer than the
  5 s launch window and was honestly reported UNVERIFIED); M1 acceptance 19/19 on both; every step checked against
  its screenshot. One flaky `TypeLiveTests` failure appeared in the first full iOS 27 live run and did not recur in
  three more runs.
- Still deferred from the M1 review: the bar-sweep cache key, and a fast reboot leaving a stale HID client.

### M3a notes (2026-10-07, iOS 27.0 / iOS 26.2)

- Blindness self-heals. `connect()` re-enables the app-accessibility flags (checked at most every 60 s), `doctor` reports
  them. After 4 s of back-to-back failures `observe` probes the bridge: an empty frontmost application element means the
  app started while the flags were off (advice: relaunch it), and a centre hit-test that answers while frontmost returns
  nothing means a poisoned bridge, so chauffeur restarts `com.apple.CoreSimulator.bridge` (at most once a minute). A
  SpringBoard by-pid read is not a valid test: it answers in both cases (final review, seen live). Reboot repro: blind at boot, bridge restarted 16 s after
  `simctl boot` returned, readable at +53 s (M2: blind 7+ minutes). A launching app shows no tree for 3–6.5 s on the 8 GB host; that never
  triggered a restart.
- `launch` waits up to 15 s and only accepts a screen that is neither SpringBoard nor what was in front before (it used
  to verify on any other app). UNVERIFIED names the tree, not the screen: a screenshot showed Settings while its tree
  still said SpringBoard. Post-boot indexing pushed some cold Settings launches to 16–21 s; settled launches take 5–6 s.
- NO EFFECT says the accessibility tree did not change and attaches a zoomed `screen:` (the target's row ±120 pt).
- F1 cause: right after typing (paste or secure field), a switch can ignore a touch that reached the app, with no
  keyboard or overlay on screen (hardware-keyboard mode). A switch tap that comes back NO EFFECT retakes the baseline,
  reports a late change if there is one, otherwise taps once more and says so.
- An app that is gone with no report and no fault or `Fatal error` line is APP EXITED (exit 5), not APP CRASHED.
- `logs --since-last --last <n>` is allowed. `scripts/mcp-smoke.sh` caught the M2 `ttlMs` blocker on the old binary.
- Acceptance re-run (no harness crutches, Opus, 14 tasks): chauffeur 14/14, Xcode 27 MCP 12/14; chauffeur median $0.058,
  5.5 turns, 21 s; no blindness. Live suites: iOS 27.0 243/245 at a load spike, both green on rerun; iOS 26.2 245/245.

