# Roadmap

Put your name in **Owner** (in a PR) before starting a milestone. Each one starts with a spec in `docs/specs/`.

| Milestone | Status | Owner |
|---|---|---|
| M4a: guardrails and the contributor workflow | done | YashNaj |
| M4b: network requests and other evidence | in progress | YashNaj |
| M4c: eval v2 | not started | |
| M5a: the App Store Connect key | in progress | YashNaj |
| M5b: `chauffeur ship` | spec drafted | YashNaj |
| M5c: the review check | spec drafted | YashNaj |
| M5d: the release honesty eval | spec drafted | YashNaj |

## M4b: network requests and other evidence

Spec: `docs/specs/2026-10-08-m4b-network-and-evidence-design.md`.

- [x] Step 0: what the Mac and the logs show (Findings in the spec)
- [x] Path shapes, telemetry hosts, crash first, relaunching an app opened from its icon
- [x] Network activity and detail layers, `PENDING`, `wait`, batches, clipboard (Plan 2)
- [ ] A sweep for more: keyboards, alerts that arrive late, animations that never settle.
- [ ] 0.2.0

## Web views in the tree (after M4b)

A `WKWebView` contributes nothing to the app's accessibility tree: its content is the WebContent process's own tree,
placed at the web view's frame (found in M4b Plan 2, Task 12). Reading that tree and merging it into the snapshot
so links and fields in web content get refs. Its own spec.

## Network visibility (stage 2, after M4b)

Every request's method (no log line carries it), the path of requests on a reused connection, path and status for
apps that don't use Apple's networking stack, opt-in bodies, a `network` command, and names in paths, through a small
library chauffeur loads into apps it launches. Its own spec and security review.

## M4c: eval v2

The launch benchmark was close on Sonnet (40 vs 39 of 45). The next one aims at where agents go wrong:

- tasks where a false success is likely: disabled controls, silent no-ops, alerts that swallow taps;
- crashes and logs, multi-step flows, and third-party open-source apps instead of only our fixture;
- enough runs per task to show whether the difference with Xcode's MCP is statistically clear.

## M5: ship it, and never misreport it (0.3.0)

Four specs, dated 2026-10-26, in `docs/specs/`. The order is M4b's 0.2.0 first, then M5a → M5b → M5c together as
0.3.0, then M5d.

- **M5a** `2026-10-26-m5a-connect-key-design.md`: the key lives in the keychain behind Touch ID; setup refuses any key
  that can reach users or certificates; the client has no DELETE, no expire, no cancel.
- **M5b** `2026-10-26-m5b-ship-design.md`: `build`, `test`, `archive` judged from the `.xcresult`; pre-flight for
  what Apple would refuse; upload on the Build Upload API; every stage read back from its App Store Connect record;
  resume from the state file; TestFlight, review and release.
- **M5c** `2026-10-26-m5c-review-check-design.md`: the same commit built for the simulator, launched, crawled and
  read before `ship --to review`: crashes, placeholders, dead URLs, review flows.
- **M5d** `2026-10-26-m5d-release-eval-design.md`: staged upload failures run through fastlane, `asc`, Codemagic,
  `altool` and chauffeur, scored against App Store Connect's records, plus an agent arm.

The review-path demo ships the owner's own App Store app's next release (decided 2026-10-26); the fixture
app stays TestFlight-only. Still to do
before live tests: register `dev.chauffeur.fixture` on the team, create its app record, mint the three test keys
(M5a Testing).

### M5a

- [x] Step 0: keychain findings (in the spec)
- [x] Key, tokens, request table, errors, transport, client
- [x] Probes, capability sheet, keychain store, keys commands, CLI and doctor
- [ ] Step 0: probe and scoped-token recordings with the owner's keys (Findings 2 and 4)
- [ ] Live run: keys add with each role; Touch ID observed
- [ ] 0.3.0 with M5b and M5c

## Later

- Stage 2 of M5: metadata and screenshots through the App Asset Library; webhooks; the accessibility evidence pack
  mapped to Apple's Nutrition Labels; trace-to-test export; Instruments evidence through `xctrace`.

- GPT-6 and Codex in the benchmark, with the skill tuned for them.
- A Jev branch: Jev handles moment-to-moment Simulator control while the coding agent sets goals.
- Games: no accessibility tree, so play through Jev or other computer vision.
