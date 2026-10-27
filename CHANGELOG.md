# Changelog

## Unreleased (0.2.0)

- A crash now leads the action's result: `tap Pay → APP CRASHED: …` on the first line.
- An app opened from its home-screen icon without accessibility is relaunched once, with a note; never inside `do`.
- `chauffeur use` keeps the other keys in `.chauffeur.json`, including the new `telemetryHosts`.
- A tap that starts a network request and changes nothing on screen is `PENDING` (exit 6) while the app waits for
  the reply; `chauffeur wait` finishes it, and `do` waits through it.
- A request that fails or changes nothing explains a `NO EFFECT`: `api.example.com/login → 500 Internal Server
  Error in 180 ms (server 160 ms)`, with bytes, protocol and a hint. Telemetry gets its own line.
- A copy to the clipboard counts as a change: `changed · copied to clipboard (24 characters)`.
- URLs in Apple's networking log lines are shown as host and path shape everywhere: no query strings, tokens or
  emails in `chauffeur logs` or action results.

## 0.1.1

- Builds with Xcode 26 again. 0.1.0 compiled only with Xcode 27, so `brew install` failed on Xcode 26.

## 0.1.0 — first public release

- Drive the iOS Simulator from a coding agent: `snapshot`, `tap`, `type`, `scroll`, `wait`, `find`, `do`, `screenshot`,
  app and device commands, `logs`, `doctor`.
- Every action is verified: changed, NO EFFECT, INTERCEPTED, NOT DELIVERED, UNVERIFIED, APP CRASHED or APP EXITED.
- MCP server (`chauffeur mcp`) and an agent skill (`chauffeur skill install`).
- Heals the simulator's accessibility when an Xcode session or an early query breaks it.
- Xcode 26 and 27, iOS 26 and 27 simulators, Apple silicon.
