# M4b: network requests and other evidence the screen doesn't show

**Status:** draft for review · **Date:** 2026-10-08

## Why

A reader of the launch post asked how long chauffeur waits before calling `NO EFFECT` on a tap that starts a slow
network request. Today it watches only the screen: when nothing changes, it reports `NO EFFECT` once the screen is
quiet, usually within a quarter of a second. A tap that starts a request and shows no spinner looks exactly like a
dead button, so the agent retries or gives up when it should wait. We answered publicly that chauffeur would add a
`PENDING` result and watch the app's network activity.

The principle behind it is wider than requests: **a tap is judged on all the evidence the app produces, not only the
screen.** M4b applies it to network activity first, then to the clipboard, and finishes the two other roadmap items
that follow from it (a crash reported on the first line; recovering an app opened from its icon).

## Goals

1. A tap that starts network activity and changes nothing on screen is reported `PENDING` while the app waits for a
   reply, never `NO EFFECT`, whatever networking stack the app uses.
2. A tap that truly does nothing is still `NO EFFECT`, with no added delay beyond what checking costs (measured in
   step 0).
3. A request that fails explains a `NO EFFECT`: the failure leads the result (`POST /login → 500`).
4. Telemetry (analytics, crash reporting, attribution) never turns a dead button into `PENDING`.
5. `wait` finishes a `PENDING` tap and tells a slow backend from a screen that will never change.
6. A double submit, a copy to the clipboard and a crash are each reported where an agent looks first.
7. The agent sees host, method, path shape, status, timing and byte counts; never bodies, headers, cookies, query
   strings, values an app marked private, or clipboard contents.

## Non-goals for M4b (staged, not ruled out)

M4b is the first stage of seeing what an app does on the network. What it doesn't cover is scheduled, not excluded
(see "Staging" at the end): request and response bodies, a `network` command listing all traffic, and method, path
and status for apps that don't use Apple's networking stack. Also out of M4b: a proxy or trusted certificate in the
simulator; haptics, sounds, and file or settings writes as evidence; an agent-supplied "I expect a request" hint.
chauffeur itself still makes no network connections: everything here is read on the Mac.

## 1. Step 0: what the Mac and the logs show

Before any feature code, a throwaway app on iOS 26 and iOS 27 simulators answers:

**Activity layer (the most important question):**
1. Can chauffeur read per-process connection data for a simulator app process (remote address and port, bytes sent
   and received, start time, state), through the NetworkStatistics framework, `nettop`, or `proc_pidinfo`? For TCP,
   UDP and QUIC? How fresh is it (polling cost and delay)?
2. Does it see traffic from URLSession, `Network.framework`, a raw BSD socket (standing in for Flutter and other
   non-Apple stacks), a WebSocket, and a `WKWebView` (whose traffic runs in a WebKit networking process: can that
   process be tied to the app)?
3. Can the remote host name be recovered (the connection's host name, or DNS seen for that process), or only the IP?

**Detail layer:**
4. Which lines in the app's log stream mark a URLSession request starting and ending, at which log level, and do
   they carry a status code and an error kind? If the start lines are `debug`, what does following only
   `com.apple.CFNetwork` at debug level cost in CPU?
5. Does `log config --subsystem com.apple.CFNetwork --mode "private_data:on"` (run with `simctl spawn`) unhide host and
   path? Does Apple's lower-level networking subsystem need it too? Only the global switch? Can chauffeur read the
   current setting back (`log config --status`)?
6. How late do the lines arrive after the event? Does a marker line chauffeur writes into the simulator's log
   (`simctl spawn <udid> log …` or equivalent) arrive in order, so it can tell when the stream has caught up?

**Clipboard:**
7. How long does `simctl pbpaste` take, and does reading it show a paste banner or fire the app's
   `UIPasteboard` change handling?

The answers go into "Findings" at the end before the plan is written. Outcomes:

- Activity layer works → §2 as written.
- Activity layer doesn't work → the in-app library (Staging, stage 2) moves into M4b, and the design comes back for
  review.
- Per-subsystem unhiding works → §5 as written; only the global switch → §5's opt-in path.
- No usable log lines → the detail layer comes from the in-app library instead, and the design comes back for review.

## 2. Two layers of evidence

A new `Network` folder in `ChauffeurCore` (private API calls, if needed, go in `ChauffeurBridge`):

- **Activity (`ConnectionWatch`), universal.** Per-process connection data for the app and, for web views, its WebKit
  networking process. Each connection: remote endpoint, host if known, bytes sent and received over time, opened and
  closed times. From these it derives, after a given moment: *did the app send anything*, and *is it waiting for a
  reply* (bytes went out and the reply has not finished arriving). It sees every stack because it doesn't depend on
  how the app makes requests. It doesn't lag behind the way logs can.
- **Detail (`RequestLog`), where available.** Apple's networking log lines from the existing `LogTap`, parsed into
  `started(id, method, host, path, time)` and `ended(id, status | error, time)`. Matched to activity by host and time,
  it adds method, path, status and error kind. Parsing is pure and unit-tested on recorded lines from step 0.
- **`Telemetry`** (§4) and **`PathShape`** (§6).

**What belongs to the tap:** activity and requests that started after the touch reached the app (touch log time).
Connections already open before the tap count only for bytes sent after the touch (an HTTP/2 connection is reused
for new requests). Activity that was already flowing before the touch and continues (a feed loading, polling) is
excluded by comparing the rate before and after; if it changes the screen, the existing `the screen was already
changing` (`UNVERIFIED`) rule applies.

**Before judging no change**, chauffeur makes sure the evidence is current: it reads activity fresh, and, when the
detail layer is in use, waits until its marker line has come through the log stream (§1 question 6). Step 0's
measurement of this is the true minimum cost of goal 2.

**Delayed requests.** A request sent after a short delay (search-as-you-type usually waits about 300 ms) starts after
the screen has settled. When the tapped or typed-into element is a text or search field, chauffeur watches for
activity for a short extra window (default 500 ms, set from step 0) before judging. Other taps are not delayed.

**When the app isn't watched** (no process to attach to), the result says `network not watched` and the tap behaves as
today. The detail layer additionally needs the app's log stream, which §8's recovery makes available for apps opened
from their icon.

## 3. Result rules

After the screen settles or reaches its time limit, with telemetry excluded:

| Screen | The tap's network activity | Result |
|---|---|---|
| changed | any | `changed`; one `request:` evidence line per request or connection |
| no change | none | `NO EFFECT`, as today |
| no change | waiting for a reply | wait up to the request window (default 2 s) for the reply, then judge again; still waiting → `PENDING` |
| no change | reply arrived, a request failed | `NO EFFECT`; the failure leads the headline |
| no change | reply arrived, all succeeded | `NO EFFECT · POST /x → 200 in 340 ms but nothing changed on screen` |
| no change | a connection keeps streaming (WebSocket after its `101`, a server stream) | `NO EFFECT` with `request: … connected, data flowing`, not `PENDING` |
| no change | clipboard changed | `changed · copied to clipboard (N characters)` (§7) |

The request window only runs while the app is waiting for a non-telemetry reply, so a true no-op is never delayed by
it. A chain (the reply to one request triggers another) is still the tap's: every request started after the touch
counts.

Output, with the detail layer:

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

With activity only (another stack, or no detail):

```
tap Login → PENDING · api.example.com:443 · 1.2 KB sent, awaiting reply after 2.1 s
```

- **Duplicates:** the same method and path shape twice from one tap adds `request: … sent twice` (detail layer).
- **Telemetry:** one line, `telemetry: 2 requests (app-measurement.com, sentry.io)`, never in the headline.
- **Exit codes:** `PENDING` is a new code, `6` ("effect still in flight"); the rest are unchanged.
- **Batches:** a step that comes back `PENDING` does what a bare `chauffeur wait` does (§9), up to the wait limit, and
  the batch judges the final result. A batch never stops on `PENDING` itself, so "tap Login, then tap Profile" works.
- **JSON and MCP:** outcome `pending`; a `requests` array of `{method, host, port, path, status, error, ms, sent,
  received, telemetry, duplicate, streaming}`, with fields absent when the layer that provides them isn't available.
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
- Matching needs a host. When only an IP is known (§1 question 3) and no log line names the host, the connection
  counts, and the evidence line says `telemetry filter unavailable for <ip>`.

## 5. Seeing hosts and paths in logs: private log data

URLs in the logs read `<private>` by default.

- **Per-subsystem (the default if step 0 confirms it):** when chauffeur launches an app, it reads the simulator's
  current log setting; if Apple's networking subsystem is still redacted, it runs `simctl spawn <udid> log config
  --subsystem com.apple.CFNetwork --mode "private_data:on"` (plus the networking subsystem if step 0 needs it) and
  prints once: `note: unhid network log data in this simulator so requests show their host; chauffeur doctor
  --undo-logging turns it off`. It checks the real setting every time rather than remembering it, so an erased or
  reset simulator is handled. The app's own log lines stay redacted.
- **Global only:** never automatic. `chauffeur doctor --fix network` turns it on after a warning that every private
  value in the simulator's logs, including the app's own, becomes visible to `chauffeur logs` and so to the agent.
  Without it, the activity layer still gives `PENDING` and hosts where §1 question 3 allows.
- `chauffeur doctor` reports the setting's state; `--undo-logging` restores it.

## 6. What the agent may see

- Host, port, method, path shape, status or error kind, timing, and byte counts.
- **Path shape:** the query string and fragment are dropped. Path segments that are numbers, UUIDs, hex or base64
  runs of 16 or more characters, or contain `@`, become `{id}`, `{token}` or `{email}`:
  `/reset/sam@example.com/7f3a…` → `/reset/{email}/{token}`. A segment that is a person's name (`/users/john-smith`)
  is not caught by these rules; stage 2 adds a check against identifiers seen elsewhere (screen text, the app's
  data) to close that.
- Hosts and paths are quoted and escaped like screen text: they can come from server responses (redirects, links), so
  they are untrusted data.
- Never: bodies, headers, cookies, query strings, the app's private log values, clipboard contents.

## 7. Clipboard

chauffeur hashes `simctl pbpaste` output before and after a tap, inside the daemon. A change is a verified effect:
`changed · copied to clipboard (24 characters)`. Only the length leaves the daemon. If step 0 shows `pbpaste` over
30 ms, the clipboard is read only after a no-change result, the one case where it can change the verdict. If step 0
shows that reading it is visible to the app (a paste banner, a change notification), the clipboard check is dropped
from M4b and redesigned rather than shipped with a side effect.

## 8. Crash first, and recovering an app opened from its icon

- **Crash first:** a tap that kills the app leads with `tap Pay → APP CRASHED · Fixture died 120 ms after the touch
  (SIGABRT)`; the screen diff and the crash block follow. Exit 5 is unchanged.
- **Icon-opened app:** when the frontmost app has no accessibility tree because it was opened from its icon,
  chauffeur relaunches it through its own launch path (which also attaches the log stream, so the detail layer works),
  retries the command once, and says so: `note: relaunched com.example.app — it was opened from its icon without
  accessibility; its in-app state was reset`. Only the frontmost app, once per app per session, and never inside a
  batch, where it stops with today's message because a state reset would corrupt the flow.

## 9. `wait`

- **`chauffeur wait`** (no query) finishes the last `PENDING` tap: it waits for that tap's replies to arrive and the
  screen to settle, then judges the tap again with §3's rules and output. No pending tap → a message and exit 1.
- **`wait "<query>"`** that times out names what is still waiting: `wait "Welcome" → timed out after 10 s · still
  waiting: GET api.example.com/feed (9.8 s)`.
- Both keep the 300 s limit.

## 10. Release

New output and a new exit code change what agents see, so M4b ships as **0.2.0**. The README's benchmark figures were
measured before M4b: the release either re-runs the benchmark tasks that touch the network, or states that the figures
come from 0.1.x. The MCP bundle and registry entry move to 0.2.0 with it.

## Testing

**Unit (no simulator):**
- `RequestLog` on recorded lines from step 0, including failures, timeouts and `101` upgrades.
- `ConnectionWatch` derivations on recorded connection samples: sent-after-touch, waiting for a reply, streaming,
  traffic already flowing before the touch.
- Every row of §3's table, through the existing fake clock and touch transport; a true no-op is not delayed; batches
  wait through `PENDING`.
- `Telemetry`: built-in suffixes, project entries, path prefixes, IP-only.
- `PathShape`: `{id}`, `{token}`, `{email}`, query and fragment stripping, escaping.
- Duplicates; exit code 6; the JSON `requests` array with absent fields; `chauffeur use` keeps `telemetryHosts`.
- The marker-line catch-up; the text-field extra window.
- Clipboard hash compare; the crash headline order; relaunch-once and never-in-a-batch; the private-data setting read
  back rather than remembered.

**Live (fixture app, Xcode 27 locally):** a "Network" screen talks to a small HTTP and WebSocket server the tests start
on 127.0.0.1, so no internet is needed:

| Button or field | Expected |
|---|---|
| slow API (2.5 s) | `PENDING`, then `chauffeur wait` → `changed` with the request line |
| fast API (100 ms) | `changed` with a request line |
| failing API (500) | `NO EFFECT · … → 500` |
| analytics only | `NO EFFECT` with a telemetry line |
| double submit | a `sent twice` line |
| slow raw-socket request (a non-Apple stack) | `PENDING` from the activity layer |
| open WebSocket | `NO EFFECT` with `connected, data flowing` |
| web view link to a slow page | `PENDING` |
| search field (300 ms debounce) | typing → `PENDING` or `changed`, never a false `NO EFFECT` |
| dead | plain `NO EFFECT`, no slower than step 0's measured minimum |
| Copy | `changed · copied to clipboard` |

Plus a batch through the slow API, and an icon-launch test for §8's recovery.

## Done when

- Step 0's findings are in this spec, and the design matches them.
- Unit tests pass in CI on Xcode 26; the live tests pass locally on Xcode 27.
- The skill, MCP instructions and tool descriptions explain `PENDING`, exit 6 and `chauffeur wait`.
- `docs/design.md` replaces the "network inspection" non-goal with this scope and the staging below.
- `docs/roadmap.md` marks M4b in progress and lists stage 2.
- 0.2.0 is released per §10.

## Staging

| Today's gap | Closed by | Stage |
|---|---|---|
| a slow request reported `NO EFFECT` | activity + detail layers, `PENDING` | M4b |
| Flutter, raw sockets, gRPC, other stacks | activity layer | M4b |
| WebSockets and server streams | activity layer (`data flowing`) | M4b |
| web views | activity layer via the WebKit networking process | M4b |
| log delay | activity layer; marker-line catch-up | M4b |
| delayed (debounced) requests | text-field extra window | M4b |
| method, path and status on non-Apple stacks | in-app library loaded at launch | stage 2 (network visibility) |
| bodies, headers (opt-in), a `network` command | in-app library | stage 2 |
| names in paths | identifier check against screen and app data | stage 2 |

Stage 2 gets its own spec and security review: it runs code inside the app, and bodies can carry secrets and untrusted
text.

## Findings

Measured 2026-10-08 on macOS 27 with Xcode 27: an iOS 27.0 simulator (iPhone 18 Pro) first, then iOS 26.2 (iPhone 17
Pro). A throwaway probe app with one button per kind of traffic talked to a stdlib Python server on 127.0.0.1; neither
is in the repo. iOS 26 matched iOS 27 except where noted.

### 1. Per-process connection data

**Yes, through the NetworkStatistics framework; not through `nettop`.** A simulator app is an ordinary Mac process, and
`nettop -p <pid>` lists its sockets:

```
16:45:48.222539,tcp4 127.0.0.1:52695<->127.0.0.1:8765,Established,0,206,
```

`nettop` is unusable as a source, though: it samples in whole seconds (`-s 0.2` is rejected), a running `nettop -L 0`
costs about 140% of a core whatever the filter, and a one-shot `nettop -L 1` (10 ms) lists only the connections still
open, so a request that opens and closes between polls is lost.

Calling the framework directly (`NStatManagerCreate`, `NStatManagerAddAllTCP`/`AddAllUDP`, polling
`NStatManagerQueryAllSources`) works on both iOS versions. Each source carries `processID`, `processName`, `provider`
(`TCP`/`UDP`), `TCPState`, local and remote address, `startAbsoluteTime`, `txBytes`/`rxBytes`, `txUnacked` and
`sendBufferUsed`. A new connection is reported when it is created; counts are as fresh as the poll; a closed
connection reports its final counts as it is removed, so short requests are never missed. Cost of the throwaway
probe, which watches every source on the Mac (about 65): 3% of a core polling every 100 ms, 1% every 250 ms.

| Probe button (iOS 27) | What the framework showed for the app's pid |
|---|---|
| URLSession slow (2.5 s) | `tx 206` at once, `rx 94` 2.45 s later, then removed |
| URLSession fast / 500 | seen even though open under 100 ms: `rx 94 tx 206` / `rx 113 tx 206` on removal |
| raw BSD socket, slow | `tx 58`, `rx 94` 2.47 s later |
| `NWConnection`, slow | a refused IPv6 `::1` attempt, then IPv4: `tx 58`, `rx 94` 2.5 s later |
| UDP datagram, reply after 2.5 s | `tx 300`, `rx 100` 2.48 s later |
| WebSocket after its `101`, server stream | `rx` grows every 0.5 s while `tx` stays flat |
| real host (`https://example.com`) | TCP source 240 ms after the task started, `rx 2896 tx 1534` |

QUIC was not tested: it needs an HTTP/3 server, and the probe stays offline. The framework reports QUIC as UDP
sources, so the UDP row stands in for it; this is unverified.

### 2. Which stacks and processes are seen

URLSession, `Network.framework`, raw BSD sockets, UDP, WebSockets and server streams all appear under the app's own
pid (table above). Web views do not: a `WKWebView`'s traffic is in the simulator's `com.apple.WebKit.Networking`
process (iOS 27: `/System/Library/ExtensionKit/Extensions/NetworkingExtension.appex`), started when the first web view
opened. Its parent is the device's `launchd_sim`, not the app; its launch arguments name only the service
(`{"type":8,"enhancedSecurity":false,"serviceName":"com.apple.WebKit.Networking"}`); its sources have `epid 0` and the
same `euuid` as every other process. It can be found (parent `launchd_sim` of this device), but its traffic can be tied
to the app only by time: traffic from it that starts after the touch, while the app is frontmost.

### 3. Host names

**Only IP addresses.** No source field carries a host name, for the probe or for a Mac `curl https://example.com`.
`lsof` without `-n` gives reverse DNS, which for real hosts names the CDN rather than the API. Host names come from the
detail layer (question 4).

### 4. Log lines for a request

At **Default** level, which the info-level stream `LogTap` already runs (`--level info`, `process == "<app>"`)
receives, so nothing changes for the detail layer to start. From `com.apple.CFNetwork` (category `Default`, the summary
in `Summary`):

```
Task <E78C6C1C-…>.<1> resuming, timeouts(60.0, 604800.0) qos(0x21) …
Task <E78C6C1C-…>.<1> setting up Connection 1
Task <E78C6C1C-…>.<1> sent request, body N 0
Task <E78C6C1C-…>.<1> received response, status 500 content U
Task <E78C6C1C-…>.<1> summary for task success {transaction_duration_ms=11, response_status=500, …, request_bytes=206, response_bytes=94, …}
Task <E78C6C1C-…>.<1> finished successfully
Task <6DF84C44-…>.<5> HTTP load failed, 0/0 bytes (error code: -1004 [1:61])
Task <6DF84C44-…>.<5> finished with error [-1004] Error Domain=NSURLErrorDomain Code=-1004 …
```

and from `com.apple.network` (category `connection`), once per connection:

```
[C1 B47F6DB7-… Hostname#a88a3e8b:8765 tcp, url: http://localhost:8765/slow, definite, attribution: developer, context: com.apple.CFNetwork.NSURLSession.{…}]
[C1 0CEDFA44-… Hostname#265e009a:443 tcp, tls, url: https://example.com/a/123, definite, attribution: developer, …]
```

So: start, end, status, error code and timing per task, always. The URL comes from the connection, and the query is
already gone (`https://example.com/a/123?q=secret` logged as `…/a/123`). Two limits:

- **No method**, at any level, in any line (checked at debug level too).
- **The path is only known for a connection's first request.** With keep-alive, a later task logs only
  `Task <…>.<7> now using Connection 7`, and Connection 7's `url:` line still names the first request's path. The host is
  right for every task on the connection; the path is not.

Cost of following more than today's stream, over eight taps: info level 0.29 s of CPU, debug level limited to
`com.apple.CFNetwork` 0.22 s, debug level for the whole app 0.42 s. Debug level isn't needed.

### 5. Private data

Both simulators already report `System mode = INFO STREAM_LIVE PRIVATE_DATA` before anything is changed, and the
`url:` line is shown in full. Other values in the same stream are still `<private>` (`ATS violation … for server:
<private>`), so the URL is logged as public data, not unhidden. The switches can't be used anyway:
`log config --mode "private_data:off"` answers `Simulator unable to set system mode`, and the per-subsystem form answers
`Ignoring some flags 0x9 because they are system only`. It also resets that subsystem's level (`INFO` became `DEFAULT`;
restored with `--mode level:info`). `log config --status` reads the setting back.

### 6. Delay and catching up

Lines arrive 0–10 ms after their own timestamp (five taps on each version, measured on arrival at the Mac). A marker
works on iOS 27 only: `simctl spawn <udid> log emit -p "chauffeur-marker-1"` reaches a stream whose predicate adds
`OR eventMessage CONTAINS "chauffeur-marker"`, after the tap's lines, but each `simctl spawn` costs 350–400 ms. iOS
26's `log` has no `emit`, and the simulator has no `logger`.

### 7. Clipboard

`simctl pbpaste` takes 100–110 ms (median of 10 on each version; first call up to 0.56 s) and returns the copied text.
Reading it shows no paste banner, and the app's `UIPasteboard.changedNotification` doesn't fire. `simctl pbinfo` costs
the same and has no change count.

### Baseline

`tap` on a button that does nothing: 0.98–1.02 s wall time on iOS 27, 1.0–1.85 s on iOS 26. Today the probe's slow
URLSession, raw socket, `NWConnection`, UDP, stream and real-host buttons all come back `NO EFFECT`. One extra case to
look at in Plan 2: on iOS 26 a fast request whose reply changed the label still came back `NO EFFECT`, because the
touch reached the app 2 s after the command started.

### Decision

- **Activity layer works → §2 as written.** Source: the NetworkStatistics framework, called from `ChauffeurBridge`
  (private API), polled every 100 ms while a tap is being judged and idle otherwise; TCP and UDP. Web views:
  `com.apple.WebKit.Networking` under the device's `launchd_sim`, counted by time. Hosts from the activity layer are
  IPs.
- **Detail layer works, narrower than §2 assumed.** Info level and today's predicate. Parse the `Task <…>` lines for
  start, status, error and timing, and the connection's `url:` line for the host. A path is shown only when the task
  set up the connection (it logs `setting up Connection N`, and `CN`'s `url:` line comes from that request);
  otherwise the path is absent, never guessed. There is no method: §3's examples lose the method (`api.example.com/login → 500`), and duplicates
  ("sent twice") compare host and path shape. Telemetry entries with a path prefix only match when the path is known.
- **Private data: no step.** The URL is visible without changing anything, the switches can't be set in the
  simulator, and the app's own private values stay hidden. §5's `log config` steps and `doctor --undo-logging` are
  dropped; `doctor` can report the `log config --status` line.
- **Catching up: a fixed 20 ms grace, no marker.** Lines lag at most 10 ms; a marker costs 350 ms and doesn't exist on
  iOS 26.
- **Request window 2 s and text-field window 500 ms**, as proposed: a task's connection appeared 11–240 ms after the task
  started (loopback and a real host), well inside both.
- **Clipboard stays, read only after a no-change result** (§7's rule for a read over 30 ms): reading is invisible to
  the app.
- **Goal 2's minimum cost:** one fresh poll (under 10 ms) plus the 20 ms grace on a dead tap, against today's ~1.0 s.
