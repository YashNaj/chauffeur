# Benchmark: chauffeur vs Xcode 27's MCP server

The same 15 iOS Simulator tasks were given to Claude Code, 3 times each, with Opus and with Sonnet. The agent had
either chauffeur's tools or the device tools from Xcode 27's own MCP server (`xcrun mcpbridge`), and nothing else.
That makes 180 runs.

## Headline

**Opus**

| | chauffeur | Xcode 27 MCP |
|---|---|---|
| Tasks verified | 45/45 | 39/45 |
| Median cost per task | $0.054 | $0.338 |
| Median turns | 5.0 | 12.0 |
| Median wall time | 20 s | 38 s |
| False successes | 0 | 0 |

**Sonnet**

| | chauffeur | Xcode 27 MCP |
|---|---|---|
| Tasks verified | 40/45 | 39/45 |
| Median cost per task | $0.031 | $0.222 |
| Median turns | 5.0 | 12.0 |
| Median wall time | 18 s | 40 s |
| False successes | 0 | 0 |

A **false success** is a run that claims it finished an action task when its final screen shows it didn't. Neither tool
produced one. Every failure below was reported honestly by the agent.

## Setup

- **Host:** an 8 GB Apple-silicon Mac running Xcode 27.0, with an iPhone 18 Pro simulator on iOS 27.0.
- **Agent:** Claude Code (`claude -p`), with Opus and with Sonnet. Each task ran 3 times per tool and model.
- **Tools:** each arm gets one MCP server and the `Read` tool, and nothing else: no shell, no file edits, no web.
  - **chauffeur arm:** every chauffeur tool.
  - **Xcode arm:** the device-interaction tools (`DeviceInteractionStartSession`,
    `DeviceInteractionStartWorkspaceSession`, `XcodeListWorkspaces`, `DeviceInteractionSynthesize`,
    `DeviceInteractionEndSession`) and `GetConsoleOutput`. Apple documents the syntax of
    `DeviceInteractionSynthesize` only in Xcode's device-interaction skill, so the Xcode arm starts with that skill
    loaded into its system prompt, as it would be inside Xcode. The skill is Apple's text, so it isn't in this repo:
    `dogfood/xcode-skill.sh` exports it from the installed Xcode at run time.
  - Tools that read the project's source, such as `XcodeGrep`, are not allowed, because the chauffeur arm can't see
    source either.
- **Starting state:** before each run, the app under test is terminated, and either relaunched or left on the home
  screen. F6 also resets Fixture's location permission, and the Settings tasks set the appearance back to light.
  - The harness doesn't restore accessibility settings between runs (`NO_AX_RESTORE=1`).
  - The first-run screens of Calendar and Reminders were dismissed once, by hand, before the benchmark began.
- **The test app:** the F tasks use `Tests/FixtureApp`, a small SwiftUI app in this repo. The S, C, K and R tasks use
  the simulator's built-in Settings, Calendar, Contacts and Reminders apps.

| Task | Prompt |
|---|---|
| F1 | In the Fixture app, fill the form with email dogfood@example.com, agree to the terms and submit it. |
| F2 | In the Fixture app's form, enter the password s3cret-dogfood and the email a@b.co, then submit. |
| F3 | Open the long list in the Fixture app and tell me which row comes right after Row 47. |
| F4 | In the Fixture app, show the alert, dismiss it with Cancel, and tell me what the app says the last action was. |
| F5 | Go to the Form tab, then back to Home, then tap Show alert and press OK. |
| F6 | Make the Fixture app request location access, allow it while using the app, and confirm it worked. |
| F7 | Tap the Crash button in the Fixture app and tell me exactly what happened and why. |
| F8 | Tap Log errors in the Fixture app and summarise any errors the app logged. |
| F9 | Open the Fixture app and switch the segmented control on its home screen to Mine. |
| S1 | Using the Settings app, find out which iOS version this simulator runs. |
| S2 | Turn on Dark Mode using the Settings app (not a shortcut). |
| S3 | In Settings, find the Accessibility setting that makes text bigger and tell me its current value. Don't change it. |
| C1 | In the Calendar app, find which calendars are listed and tell me their names. Don't create or change anything. |
| K1 | In Contacts, open Kate Bell and tell me which company she works for. Don't change anything. |
| R1 | Open the Reminders app and tell me which lists are under My Lists and how many reminders each one has. Don't create or change anything. |

F1 and F2 are traps. F1 gives no password, and F2 never agrees to the terms, so the form can't be submitted. A run
passes if it says why.

## Per-task results

Each cell shows successes out of 3, the median cost and the median number of turns.

| Task | Opus · chauffeur | Opus · Xcode | Sonnet · chauffeur | Sonnet · Xcode |
|---|---|---|---|---|
| F1 | 3/3 · $0.055 · 5 | 3/3 · $0.338 · 13 | 3/3 · $0.035 · 7 | 3/3 · $0.222 · 12 |
| F2 | 3/3 · $0.054 · 5 | 3/3 · $0.312 · 10 | **1/3** · $0.040 · 9 | 3/3 · $0.243 · 14 |
| F3 | 3/3 · $0.048 · 5 | 3/3 · $0.403 · 11 | 3/3 · $0.026 · 5 | 3/3 · $0.193 · 13 |
| F4 | 3/3 · $0.043 · 5 | 3/3 · $0.270 · 9 | 3/3 · $0.023 · 5 | 3/3 · $0.195 · 11 |
| F5 | 3/3 · $0.060 · 7 | 3/3 · $0.445 · 19 | 3/3 · $0.034 · 8 | 3/3 · $0.248 · 15 |
| F6 | 3/3 · $0.095 · 8 | 3/3 · $0.369 · 17 | 3/3 · $0.025 · 5 | 3/3 · $0.254 · 17 |
| F7 | 3/3 · $0.076 · 5 | **0/3** · $0.290 · 14 | 3/3 · $0.033 · 4 | **0/3** · $0.179 · 13 |
| F8 | 3/3 · $0.051 · 4 | **0/3** · $0.295 · 14 | 3/3 · $0.023 · 4 | **0/3** · $0.152 · 9 |
| F9 | 3/3 · $0.056 · 7 | 3/3 · $0.536 · 19 | **0/3** · $0.058 · 12 | 3/3 · $0.304 · 17 |
| S1 | 3/3 · $0.048 · 5 | 3/3 · $0.378 · 12 | 3/3 · $0.028 · 5 | 3/3 · $0.259 · 13 |
| S2 | 3/3 · $0.083 · 9 | 3/3 · $0.423 · 12 | 3/3 · $0.061 · 13 | 3/3 · $0.247 · 10 |
| S3 | 3/3 · $0.058 · 6 | 3/3 · $0.389 · 9 | 3/3 · $0.037 · 7 | 3/3 · $0.279 · 12 |
| C1 | 3/3 · $0.050 · 5 | 3/3 · $0.255 · 9 | 3/3 · $0.029 · 5 | 3/3 · $0.158 · 9 |
| K1 | 3/3 · $0.038 · 4 | 3/3 · $0.178 · 5 | 3/3 · $0.026 · 5 | 3/3 · $0.109 · 5 |
| R1 | 3/3 · $0.036 · 3 | 3/3 · $0.165 · 6 | 3/3 · $0.021 · 3 | 3/3 · $0.102 · 6 |

## Where each tool failed

- **F7 and F8, Xcode, both models (12 runs):** the taps worked, but the agent couldn't say why the app crashed or what
  it logged. `GetConsoleOutput` returned nothing useful for the app, and the arm has no crash-report tool. Every run
  said so. chauffeur passed both tasks in all 12 of its runs. It reports `APP CRASHED` with the app's own fatal line,
  `FixtureApp.swift:57`, and `logs` returns the app's error lines.
- **F9, chauffeur, Sonnet (3 runs):** F9 starts on the home screen. Sonnet opened Fixture by tapping its icon, as a
  person would, so the app started with its accessibility server off. chauffeur saw this and said a relaunch would
  fix it, but Sonnet didn't relaunch, and it reported that it couldn't do the task. Opus relaunched and passed all 3.
  A future chauffeur should relaunch by itself instead of asking the agent to.
- **F2, chauffeur, Sonnet (2 runs):** F2 is a trap: the user never agrees to the terms, so the form shouldn't be
  submitted. In 2 runs Sonnet switched on "Agree to terms" by itself to get the form through. It said so plainly, and
  the text check (`terms`) passed, but agreeing to terms for the user is the wrong outcome, so both count as
  failures. No Xcode run did this.

## Method

- **Automatic checks:** `dogfood/verify.py` checks each run against the `check` column of `dogfood/tasks.tsv`.
  - Most checks are a pattern the final answer must contain, such as `password` for F1 or `27.0` for S1.
  - S2 checks the simulator's real appearance after the run.
  - F6 and F9 are marked for a person to check.
- **Hand review:** a person reviewed:
  - every run marked for checking, against its final screenshot;
  - every failed run;
  - a sample of passing runs: all of F1, F2 and F4, which is 9 per tool and model.

  The hand review overruled the automatic check in two places:
  - **F5:** this task asks for no answer, so the pattern `alert ok` was too strict. Two Sonnet · chauffeur runs ended
    on "Last action: alert ok" and count as passes.
  - **F2:** the two runs above passed the pattern, but they agreed to the terms, so they count as failures.
- **The Xcode arm's tool list was fixed during the benchmark.**
  - The first full Xcode round allowed only `DeviceInteractionStartSession`. Apple's skill tells the agent to use
    `DeviceInteractionStartWorkspaceSession`, so 17 of its 90 runs were refused a tool the skill had just recommended.
  - That round was thrown away, and all 90 Xcode runs were run again with the workspace-session tools allowed. The
    tables above are from the second round only.
- **What's published:** [`dogfood/results-launch/summary.csv`](../dogfood/results-launch/summary.csv) has one row per
  run, with turns, cost, time and tool calls. [`verdicts.tsv`](../dogfood/results-launch/verdicts.tsv) has the
  automatic verdict, the final verdict and the reason for every run. Full transcripts and screenshots aren't
  published, because they contain local paths. To produce your own, run `dogfood/run-all.sh`.

## Cost

The published runs cost $30.10 at API prices: chauffeur $4.09 and Xcode $26.01. Including the discarded first Xcode
round ($25.27), the benchmark cost about $55.50 in all.

## Network round: chauffeur 0.2.0 against Xcode 27.1's MCP (2026-10-27)

The launch benchmark never started a network request, so it could not show what M4b added. This round adds five
tasks on the fixture's Network tab, each 3 times with Opus and with Sonnet on both arms: 60 runs, the same machine,
an iPhone 17 simulator on iOS 27.0, chauffeur 0.2.0 (the release binary) against Xcode 27.1 (27A9275).

**Opus**

| | chauffeur 0.2.0 | Xcode 27.1 MCP |
|---|---|---|
| Tasks verified | 14/15 | 12/15 |
| Median cost per task | $0.046 | $0.405 |
| Median turns | 5.0 | 14.0 |
| Median wall time | 15 s | 51 s |

**Sonnet**

| | chauffeur 0.2.0 | Xcode 27.1 MCP |
|---|---|---|
| Tasks verified | 15/15 | 12/15 |
| Median cost per task | $0.022 | $0.193 |
| Median turns | 4.0 | 16.0 |
| Median wall time | 13 s | 37 s |

### The tasks

The Network tab talks to a local server (`Tests/FixtureApp/netserver.py`, started by the reset). A pass is a final
answer that matches the `check` column of `dogfood/tasks.tsv`, then a hand review.

| Task | Prompt | What decides it |
|---|---|---|
| N1 | In the Fixture app's Network tab, tap Slow API and tell me what the Result row says once the request has finished. | the reply takes 2.5 s; the row then reads `slow 200` |
| N2 | …tap Failing API and tell me whether its request succeeded; if it did not, tell me the HTTP status it got. | the server answers 500 and the app shows nothing |
| N3 | …tap Dead network button and tell me whether tapping it did anything. | a control: nothing happens |
| N4 | …tap Copy code and tell me how many characters it put on the clipboard. | 17; the app shows nothing |
| N5 | …tap Medium API and tell me what the Result row says. | the reply takes 1.2 s; the row then reads `medium 200` |

### Per-task results

Pass count over 3 runs · median cost · median turns.

| Task | Opus · chauffeur | Opus · Xcode | Sonnet · chauffeur | Sonnet · Xcode |
|---|---|---|---|---|
| N1 slow request | 3/3 · $0.046 · 5 | 3/3 · $0.381 · 11 | 3/3 · $0.023 · 5 | 3/3 · $0.192 · 14 |
| N2 failing request | 3/3 · $0.048 · 5 | **0/3** · $0.423 · 17 | 3/3 · $0.022 · 4 | **0/3** · $0.206 · 17 |
| N3 dead button | **2/3** · $0.095 · 7 | 3/3 · $0.387 · 14 | 3/3 · $0.029 · 6 | 3/3 · $0.190 · 14 |
| N4 clipboard copy | 3/3 · $0.043 · 4 | 3/3 · $0.510 · 19 | 3/3 · $0.020 · 4 | 3/3 · $0.237 · 20 |
| N5 medium request | 3/3 · $0.042 · 4 | 3/3 · $0.363 · 11 | 3/3 · $0.020 · 4 | 3/3 · $0.189 · 14 |

### Where each tool failed

- **Xcode, N2, all six runs.** The HTTP status never reaches the screen, and the simulator's console shows nothing
  for a URLSession reply, so the agent has nothing to read. Every answer said so honestly ("I couldn't tell whether
  the request succeeded, and I have no HTTP status for it"); every run also tapped the button twice, which is a
  double submit. chauffeur's agent answered from the tap's result line, `NO EFFECT · 127.0.0.1:8765/fail → 500
  Internal Server Error`, in 4 or 5 turns.
- **Xcode, N4, all six passes by improvisation.** The clipboard count isn't on screen either. Every Xcode run that
  passed long-pressed the Search field, pasted, and counted the characters. chauffeur's agent read `copied to
  clipboard (17 characters)` on the tap's result line.
- **chauffeur, N3, one Opus run (hand review).** The agent tapped the Network tab and the dead button within a
  second, while the tab's web view was still loading its page. The activity layer saw the WebKit networking process
  fetch the page after the touch and attributed it to the tap: `NO EFFECT · 127.0.0.1:8765 · sent 451 B, got
  341 B, but nothing changed on screen`. The verdict was right; the evidence line was wrong, and the agent concluded
  "the button works, but it gives no feedback". The automatic check passed the answer (it says "nothing you can
  see"); the hand review overruled it to a failure. The fix is to name the web view as the source of such a line, so
  an agent can discount it; it's tracked on the roadmap.
- **N1 and N5, both tools.** The screen eventually shows the result, so both arms pass; the difference is the path.
  chauffeur's agent went snapshot, tap, tap, `wait`, answer. Xcode's agent took 11 to 17 turns of tap, capture, read
  and re-capture, and once admitted it "read this from the screenshot only".

### Method

- `dogfood/run.sh` gained a `network` reset: start the fixture's server if it isn't listening, clear the simulator's
  pasteboard, terminate and relaunch the fixture.
- **The pasteboard reset was added during the run.** The first two Sonnet reps of N4 ran with the previous run's
  code already on the pasteboard, so the copy changed nothing and both arms improvised a paste; those four runs were
  set aside and N4 was run again for those reps under the reset. The published N4 rows all start from a clean
  pasteboard.
- **Xcode's skill export hung once for 76 minutes** (`mcpbridge run-agent skills export`, Xcode 27.1) before the first
  Xcode run; `dogfood/xcode-skill.sh` now caches the export per Xcode build and gives each attempt 60 s. Xcode 27.1's
  server still exposes the same device-interaction tools the harness allows; no run was refused a tool.
- **Hand review:** every chauffeur answer (30) and every automatic failure (6) was read; one chauffeur pass was
  overruled, above. `dogfood/results-network/verdicts.tsv` has the automatic verdict, the final verdict and the
  reason for every run; `summary.csv` has turns, cost, time and tool calls.
- **Cost:** the 60 runs cost $10.76 at API prices: chauffeur $1.26, Xcode $9.50.

## Earlier rounds

Both earlier rounds ran 14 tasks, once each, with Opus only. They used the narrower Xcode tool list.

- **M2:** chauffeur verified 14/14 tasks, Xcode 12/14. Median cost was $0.058 against $0.479.
- **M3a:** chauffeur verified 14/14 tasks, Xcode 12/14. Median cost was $0.058 against $0.401, and median turns were
  5.5 against 15.5.
