# M4b: network requests and other evidence the screen doesn't show

**Status:** draft for review · **Date:** 2026-10-08

## Why

A reader of the launch post asked how long chauffeur waits before calling `NO EFFECT` on a tap that starts a slow
network request. Today it watches only the screen: when nothing changes, it reports `NO EFFECT` once the screen is
quiet, usually within a quarter of a second. A tap that starts a request and shows no spinner looks exactly like a
dead button, so the agent retries or gives up when it should wait. We answered publicly that chauffeur would add a
`PENDING` result and watch the app's network activity.

The principle behind it is wider than requests: **a tap is judged on all the evidence the app produces, not only the
screen.** M4b applies it to network requests first, then to the clipboard, and finishes the two other roadmap items
that follow from it (a crash reported on the first line; recovering an app opened from its icon).

## Goals

1. A tap that starts a request and changes nothing on screen is reported `PENDING` while the request runs, never
   `NO EFFECT`.
2. A tap that truly does nothing is still `NO EFFECT`, with no added delay.
3. A request that fails explains a `NO EFFECT`: the failure leads the result (`POST /login → 500`).
4. Telemetry requests (analytics, crash reporting, attribution) never turn a dead button into `PENDING`.
5. `wait` finishes a `PENDING` tap and tells a slow backend from a screen that will never change.
6. A double submit, a copy to the clipboard and a crash are each reported where an agent looks first.
7. The agent sees method, host, path shape, status and timing; never bodies, headers, cookies, query strings, values
   an app marked private, or clipboard contents.

## Non-goals

- Request and response bodies, headers, a `network` command that lists all traffic, and loading a library into the
  app. They belong to a later "network visibility" milestone with its own security review.
- A proxy or a trusted certificate in the simulator.
- Haptics, sounds, and file or settings writes as evidence.
- An agent-supplied "I expect a request" hint. Easy to add on top of `PENDING` later.
- Network access by chauffeur itself. It still reads only local logs; nothing leaves the machine.

## 1. Step 0: what the logs show

Before any feature code, a throwaway app on iOS 26 and iOS 27 simulators answers:

1. Which lines in the app's log stream (it already follows `process == "<app>"` at info level) mark a URLSession
   request starting and ending, and do they carry a status code and an error kind?
2. Does `log config --subsystem com.apple.CFNetwork --mode "private_data:on"` (run with `simctl spawn`) unhide the
   host and path? If not, does adding Apple's lower-level networking subsystem do it? Only the global switch?
3. How late do the lines arrive after the touch? This sets the request window (§3, default 2 s).
4. How long does `simctl pbpaste` take?
5. Do background-session and `WKWebView` requests appear?

The answers are written into a "Findings" section at the end of this spec before the plan is written. Outcomes:

- Per-subsystem unhiding works → §5 as written.
- Only the global switch works → §5's opt-in path.
- No start/end lines exist → stop; the design moves to an in-app library and comes back for review.
- Background or web-view requests are missing → a documented limit (§9), not a fix.

## 2. Request events

A new `Network` folder in `ChauffeurCore` holds:

- **`RequestLog`**: parses the app's log lines into events: `started(id, method, host, path, time)` and
  `ended(id, status | error, time)`. Lines come from the existing `LogTap`; parsing is pure and unit-tested on
  recorded lines from step 0.
- **`Telemetry`**: decides whether a request is telemetry (§4).
- **`PathShape`**: drops the query string and collapses identifiers in the path (§6).

When the app's log stream isn't attached (the app wasn't launched by chauffeur and §8's recovery didn't apply), no
requests are seen. The tap behaves as today and its result says `network not watched`.

**Which requests belong to the tap:** those that started after the touch reached the app (the touch log time) and
before the observation ended. Requests already running before the tap do not count; if one of them changes the screen,
the existing `the screen was already changing` (`UNVERIFIED`) rule applies.

## 3. Result rules

After the screen settles or reaches its time limit, with telemetry excluded:

| Screen | The tap's requests | Result |
|---|---|---|
| changed | any | `changed`; one `request:` evidence line per request |
| no change | none | `NO EFFECT`, as today |
| no change | one still running | wait up to the request window (default 2 s) for it to end, then judge again; still running → `PENDING` |
| no change | all ended, one failed | `NO EFFECT`; the failure leads the headline |
| no change | all ended, all succeeded | `NO EFFECT · POST /x → 200 in 340 ms but nothing changed on screen` |
| no change | clipboard changed | `changed · copied to clipboard (N characters)` (§7) |

The request window only runs when a non-telemetry request is in flight, so a true no-op is never delayed.

Output:

```
tap Login → PENDING · POST api.example.com/login still running after 2.2 s
hint: run `chauffeur wait` for the result
```
```
tap Login → NO EFFECT · POST api.example.com/login → 500 in 180 ms
```
```
tap Place order → changed · settled 420ms · rev 7→8
request: POST api.example.com/orders → 201 in 310 ms
request: POST api.example.com/orders sent twice
```

- **Duplicates:** the same method and path shape twice from one tap adds `request: … sent twice`.
- **Telemetry:** listed on one line, `telemetry: 2 requests (app-measurement.com, sentry.io)`, never in the headline.
- **Exit codes:** `PENDING` is a new code, `6` ("effect still in flight"); the rest are unchanged.
- **JSON and MCP:** outcome `pending`; a `requests` array of `{method, host, path, status, error, ms, telemetry,
  duplicate}`.
- The skill, the MCP instructions and the `act` tool description each gain one line on `PENDING`, exit 6 and
  `chauffeur wait`.

## 4. Telemetry

- A built-in list of about 30 domain suffixes (Firebase and Google Analytics, Crashlytics, Sentry, Segment,
  Amplitude, Mixpanel, AppsFlyer, Adjust, Branch, Datadog, New Relic, Bugsnag, and similar) lives in
  `Sources/ChauffeurCore/Network/Telemetry.swift`, one per line, so a PR can add one.
- A project adds its own entries in `.chauffeur.json`: `"telemetryHosts": ["events.example.com",
  "example.com/metrics"]`. An entry is a domain suffix with an optional path prefix, matched against the path shape.
- `chauffeur use` merges into `.chauffeur.json` instead of rewriting it, so it keeps `telemetryHosts` (today it
  overwrites the file).
- When hosts are unavailable (§5), telemetry can't be told apart: every request counts, and the evidence line says
  `telemetry filter unavailable (hosts hidden)`.

## 5. Seeing hosts: private log data

URLs in the logs read `<private>` by default.

- **Per-subsystem (the default if step 0 confirms it):** the first time chauffeur launches an app on a simulator, it
  runs `simctl spawn <udid> log config --subsystem com.apple.CFNetwork --mode "private_data:on"` (plus the
  networking subsystem if step 0 needs it), records that in its per-simulator state, and prints once:
  `note: unhid network log data in this simulator so requests show their host; chauffeur doctor --undo-logging
  turns it off`. The app's own log lines stay redacted.
- **Global only:** never automatic. `chauffeur doctor --fix network` turns it on after a warning that every private
  value in the simulator's logs, including the app's own, becomes visible to `chauffeur logs` and so to the agent.
  Without it M4b still works, minus the telemetry filter (§4).
- `chauffeur doctor` reports the setting's state; `--undo-logging` restores it.

## 6. What the agent may see

- Method, host, path shape, status or error kind, and timing.
- **Path shape:** the query string and fragment are dropped. Path segments that are numbers, UUIDs, hex or base64
  runs of 16 or more characters, or contain `@`, become `{id}`, `{token}` or `{email}`:
  `/reset/sam@example.com/7f3a…` → `/reset/{email}/{token}`.
- Paths and hosts are quoted and escaped like screen text: they can come from server responses (redirects, links), so
  they are untrusted data.
- Never: bodies, headers, cookies, query strings, the app's private log values, clipboard contents.

## 7. Clipboard

chauffeur hashes `simctl pbpaste` output before and after a tap, inside the daemon. A change is a verified effect:
`changed · copied to clipboard (24 characters)`. Only the length leaves the daemon. If step 0 shows `pbpaste` over
30 ms, the clipboard is read only after a no-change result, the one case where it can change the verdict.

## 8. Crash first, and recovering an app opened from its icon

- **Crash first:** a tap that kills the app leads with `tap Pay → APP CRASHED · Fixture died 120 ms after the touch
  (SIGABRT)`; the screen diff and the crash block follow. Exit 5 is unchanged.
- **Icon-opened app:** when the frontmost app has no accessibility tree because it was opened from its icon,
  chauffeur relaunches it through its own launch path (which also attaches the log stream, so §2 works), retries the
  command once, and says so: `note: relaunched com.example.app — it was opened from its icon without accessibility;
  its in-app state was reset`. Only the frontmost app, once per app per session, and never inside a batch, where it
  stops with today's message because a state reset would corrupt the flow.

## 9. `wait`

- **`chauffeur wait`** (no query) finishes the last `PENDING` tap: it waits for that tap's requests to end and the
  screen to settle, then judges the tap again with §3's rules and output. No pending tap → a message and exit 1.
- **`wait "<query>"`** that times out names what is still running: `wait "Welcome" → timed out after 10 s · still
  running: GET api.example.com/feed (9.8 s)`.
- Both keep the 300 s limit.

Known limits, stated in the skill and `docs/design.md`: requests the app's process doesn't log (if step 0 finds
background sessions or web views missing) aren't seen; a first-party request that is really telemetry counts until
the project lists it.

## Testing

**Unit (no simulator):**
- `RequestLog` on recorded lines from step 0, including failures and timeouts.
- Every row of §3's table, through the existing fake clock and touch transport; a true no-op is not delayed.
- `Telemetry`: built-in suffixes, project entries, path prefixes, hosts unavailable.
- `PathShape`: `{id}`, `{token}`, `{email}`, query and fragment stripping, escaping.
- Duplicates; exit code 6; the JSON `requests` array; `chauffeur use` keeps `telemetryHosts`.
- Clipboard hash compare; the crash headline order; relaunch-once and never-in-a-batch.

**Live (fixture app, Xcode 27 locally):** a "Network" screen talks to a small HTTP server the tests start on
127.0.0.1, so no internet is needed:

| Button | Expected |
|---|---|
| slow API (2.5 s) | `PENDING`, then `chauffeur wait` → `changed` with the request line |
| fast API (100 ms) | `changed` with a request line |
| failing API (500) | `NO EFFECT · … → 500` |
| analytics only | `NO EFFECT` with a telemetry line |
| double submit | a `sent twice` line |
| dead | plain `NO EFFECT`, no slower than today |
| Copy | `changed · copied to clipboard` |

Plus an icon-launch test for §8's recovery.

## Done when

- Step 0's findings are in this spec, and the design matches them.
- Unit tests pass in CI on Xcode 26; the live tests pass locally on Xcode 27.
- The skill, MCP instructions and tool descriptions explain `PENDING`, exit 6 and `chauffeur wait`.
- `docs/design.md` replaces the "network inspection" non-goal with this scope and its limits.
- `docs/roadmap.md` marks M4b in progress and records the network visibility milestone as later work.

## Findings

To be filled in by step 0.
