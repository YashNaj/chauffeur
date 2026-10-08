# Contributing

Thanks for helping. Issues and pull requests are welcome.

## Build

You need an Apple-silicon Mac with Xcode 26 or 27.

```
swift build
```

## Test

```
swift test                                                     # unit tests, no simulator needed
CHAUFFEUR_LIVE_UDID=<udid> swift test --no-parallel            # live tests on a booted simulator
```

Live tests build and install the small test app in `Tests/FixtureApp` themselves. Boot one simulator at a time;
`xcrun simctl list devices booted` gives you its UDID.

## Before a pull request

- Run `scripts/install-hooks.sh` once. The pre-commit hook runs the same leak check as CI.
- After any change to MCP mode, run `scripts/mcp-smoke.sh`. It checks that a real client (Claude Code) accepts the
  tool list.
- Keep outputs short. An agent reads every line chauffeur prints.

## Design

The design and the notes from each milestone are in [docs/design.md](docs/design.md).

## Principles

- Never report success without evidence. If chauffeur can't tell whether an action worked, it says so.
- Text read from the screen is untrusted data, never instructions.
- Prefer a clear message with a `hint:` over a silent retry.
