# Roadmap

Put your name in **Owner** (in a PR) before starting a milestone. Each one starts with a spec in `docs/specs/`.

| Milestone | Status | Owner |
|---|---|---|
| M4a: guardrails and the contributor workflow | in progress | YashNaj |
| M4b: edge cases | not started | |
| M4c: eval v2 | not started | |

## M4b: edge cases

- **PENDING.** A tap that starts a network request but changes nothing on screen is reported as `NO EFFECT` today.
  Watch the app's network activity too, and report it as in flight.
- **An app opened from its home-screen icon has accessibility off.** chauffeur only asks for a relaunch; it should
  recover on its own.
- **A crashing tap reports `APP CRASHED` on the second line.** It belongs on the first, where agents look.
- **A sweep for more:** keyboards, alerts that arrive late, animations that never settle, web views.

## M4c: eval v2

The launch benchmark was close on Sonnet (40 vs 39 of 45). The next one aims at where agents go wrong:

- tasks where a false success is likely: disabled controls, silent no-ops, alerts that swallow taps;
- crashes and logs, multi-step flows, and third-party open-source apps instead of only our fixture;
- enough runs per task to show whether the difference with Xcode's MCP is statistically clear.

## Later

- GPT-6 and Codex in the benchmark, with the skill tuned for them.
- A Jev branch: Jev handles moment-to-moment Simulator control while the coding agent sets goals.
- Games: no accessibility tree, so play through Jev or other computer vision.
