# Roadmap

Put your name in **Owner** (in a PR) before starting a milestone. Each one starts with a spec in `docs/specs/`.

| Milestone | Status | Owner |
|---|---|---|
| M4a: guardrails and the contributor workflow | done | YashNaj |
| M4b: network requests and other evidence | in progress | YashNaj |
| M4c: eval v2 | not started | |

## M4b: network requests and other evidence

Spec: `docs/specs/2026-10-08-m4b-network-and-evidence-design.md`.

- [x] Step 0: what the Mac and the logs show (Findings in the spec)
- [x] Path shapes, telemetry hosts, crash first, relaunching an app opened from its icon
- [ ] Network activity and detail layers, `PENDING`, `wait`, batches, clipboard (Plan 2)
- [ ] A sweep for more: keyboards, alerts that arrive late, animations that never settle.
- [ ] 0.2.0

## Network visibility (stage 2, after M4b)

Every request's method (no log line carries it), the path of requests on a reused connection, path and status for
apps that don't use Apple's networking stack, opt-in bodies, a `network` command, and names in paths, through a small
library chauffeur loads into apps it launches. Its own spec and security review.

## M4c: eval v2

The launch benchmark was close on Sonnet (40 vs 39 of 45). The next one aims at where agents go wrong:

- tasks where a false success is likely: disabled controls, silent no-ops, alerts that swallow taps;
- crashes and logs, multi-step flows, and third-party open-source apps instead of only our fixture;
- enough runs per task to show whether the difference with Xcode's MCP is statistically clear.

## Later

- GPT-6 and Codex in the benchmark, with the skill tuned for them.
- A Jev branch: Jev handles moment-to-moment Simulator control while the coding agent sets goals.
- Games: no accessibility tree, so play through Jev or other computer vision.
