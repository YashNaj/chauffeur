# Changelog

## 0.1.0 — first public release

- Drive the iOS Simulator from a coding agent: `snapshot`, `tap`, `type`, `scroll`, `wait`, `find`, `do`, `screenshot`,
  app and device commands, `logs`, `doctor`.
- Every action is verified: changed, NO EFFECT, INTERCEPTED, NOT DELIVERED, UNVERIFIED, APP CRASHED or APP EXITED.
- MCP server (`chauffeur mcp`) and an agent skill (`chauffeur skill install`).
- Heals the simulator's accessibility when an Xcode session or an early query breaks it.
- Xcode 26 and 27, iOS 26 and 27 simulators, Apple silicon.
