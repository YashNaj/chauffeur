# Changelog

## Unreleased (0.2.0)

- A crash now leads the action's result: `tap Pay → APP CRASHED: …` on the first line.
- An app opened from its home-screen icon without accessibility is relaunched once, with a note; never inside `do`.
- `chauffeur use` keeps the other keys in `.chauffeur.json`, including the new `telemetryHosts`.

## 0.1.1

- Builds with Xcode 26 again. 0.1.0 compiled only with Xcode 27, so `brew install` failed on Xcode 26.

## 0.1.0 — first public release

- Drive the iOS Simulator from a coding agent: `snapshot`, `tap`, `type`, `scroll`, `wait`, `find`, `do`, `screenshot`,
  app and device commands, `logs`, `doctor`.
- Every action is verified: changed, NO EFFECT, INTERCEPTED, NOT DELIVERED, UNVERIFIED, APP CRASHED or APP EXITED.
- MCP server (`chauffeur mcp`) and an agent skill (`chauffeur skill install`).
- Heals the simulator's accessibility when an Xcode session or an early query breaks it.
- Xcode 26 and 27, iOS 26 and 27 simulators, Apple silicon.
