# M5c: the review check: test the build you ship

**Status:** draft for review · **Date:** 2026-10-26 · **Needs:** M5b for the archive and the `ship` gate

## Why

Apple's 2025 numbers: about 9.1 million submissions reviewed, 2.09 million rejected, and "Performance" (guideline
2.x) the largest section, bigger than all the others combined. Apple says over 40% of unresolved issues are
guideline 2.1: the app crashes, shows placeholder content, has broken links, or the demo account doesn't work. These
are the rejections an agent causes by saying "ready to submit" without having run the build it is submitting.

No release tool can check this, because none of them can run the app. chauffeur can. The review check is the floor
under a submission: **before `ship --to review`, the same commit is built in the Release configuration, installed in
the simulator, launched, walked, and read.** The report it writes is what `ship` requires (M5b §3).

## Goals

1. A report for a commit that answers, with evidence: does it launch without crashing on the oldest and the newest
   iOS the app supports; is every screen reachable by non-destructive taps free of placeholder text and empty
   content; do the version's metadata URLs answer; do the project's review flows (a demo login, say) pass.
2. The report names what it saw: screens visited, the tree line with the placeholder, the URL and status, the step
   that failed. A reviewer could follow it.
3. The crawl is bounded and never destructive by design where chauffeur can tell, and says what it skipped.
4. `ship --to review` refuses without a passing report for the archive's commit; `--skip-review-check` is allowed
   and printed, so the transcript shows the human chose to skip.

## Non-goals

Judging design, business model or guideline sections other than 2.1 and 2.3.3 (screenshots must show the app in
use: M5b stage 2). Replacing the agent's own testing: flows the project cares about are still driven by the agent with
the normal commands; the check is the floor, not the ceiling. Infinite content (feeds, search results) beyond the
screen limit. Real devices.

## 1. Which build

The archive's binary is signed for distribution and built for arm64 devices; it can't run in the simulator. The check
builds the **same commit in the Release configuration for the simulator** (`chauffeur build --configuration Release`,
M5b §2) and says so on its first line: `review-check · commit a1b2c3d (clean) · Release configuration · simulator
build, not the archive's bytes`. The report records the commit and whether the tree was dirty; `ship` compares the
archive's commit (M5b §8) and refuses on a mismatch or a dirty tree.

Two simulators when `--oldest <udid>` is given or `.chauffeur.json` sets `"oldestUDID"`: the pinned target (newest)
and a booted simulator on the oldest iOS the app supports (`MinimumOSVersion`). chauffeur doesn't boot or shut down
simulators (it never has; a fresh boot is blind for most of a minute), so the human boots both. With no second
simulator, or one whose iOS is newer than the minimum, the report says `oldest iOS 17 not checked: boot one and pass
--oldest <udid>`.

## 2. The crawl

A bounded breadth-first walk from the launch screen. The planner runs **in the CLI process** and drives the daemon
with ordinary commands (`snapshot`, `tap`, `scroll`, `button`, `launch`), each its own request well under the
daemon's reply timeout; the daemon and its socket protocol don't change, and a crawl that takes ten minutes is ten
minutes of short commands, not one long one. The planner is a pure type (`Release/Crawl.swift`) that takes the
current tree and its memory of screens and returns the next step; the CLI loop executes it.

- Fresh install: `simctl uninstall` then install, so there is no state from a previous run.
- Launch, wait for the first tree (`launch` already does), snapshot.
- A screen is identified by a signature: the sorted set of (role, name, identifier) of its nodes, ignoring values.
  A tap that produces a known signature is a visited edge.
- For each untried actionable ref on the screen, in tree order: tap it, settle, snapshot, record the edge and the new
  screen, then go back (`Back`, `Close`, `Cancel`, `Done` by role and name; else `swipe` from the left edge; else
  `button home` and relaunch, which resets the crawl to the root). Scroll each screen to the end once, collecting
  refs that come into view.
- **Skipped by label**, with the skip recorded: refs whose name matches a word from a list in
  `Sources/ChauffeurCore/Release/Crawl.swift` (delete, remove, purchase, buy, subscribe, pay, send, post, publish,
  share, call, sign out, log out, reset, clear, report, block). Labels are untrusted text: the list reduces risk, it
  does not make the crawl safe against an app that labels a purchase "Continue". The report's first lines say that.
- Text fields are not typed into; secure fields never. System alerts (permissions) are answered "don't allow" so the
  flow continues; the alert is recorded as a screen.
- Limits: `--max-screens` (default 60), `--max-minutes` (default 10), depth 8. Reaching a limit is reported, not a
  failure.

The crawl is deterministic for a given app: the same tree order, the same choices. Its planner (which ref next, what
counts as a new screen, how to go back) is pure and tested on recorded trees.

## 3. The checks

| Check | How | Verdict line |
|---|---|---|
| launches | `launch` reaches a tree within 30 s, no `APP CRASHED` | `launch · ok in 1.8 s` / `FAIL launch · APP CRASHED 0.4 s after launch (SIGABRT) · crash report …` |
| no crash in the crawl | any `APP CRASHED` during a tap | `FAIL crawl · crashed tapping "Settings" on screen "Home"` with the crash block |
| no placeholder text | every visible text node against `Placeholders.swift`: `lorem ipsum`, `TODO`, `FIXME`, `TBD`, `placeholder`, `coming soon`, `{{`, `}}`, `%@`, `%d`, `%1$`, `<null>`, `Optional(`, `nil`, `undefined`, `NaN`, `xxx`, `asdf`, `test test`, `Label`, `Title`, `Button` as a whole label | `FAIL placeholder · screen "Profile": text "Lorem ipsum dolor"` |
| no empty screen | a reached screen with no text and no image node | `FAIL empty · screen reached from "Help" has no content` |
| metadata URLs answer | the version's support, marketing and privacy policy URLs from App Store Connect (`appInfos`, `appStoreVersions`), or `--urls`, fetched with GET, following redirects, expecting 2xx within 10 s | `FAIL url · privacy policy https://example.com/privacy → 404` |
| review flows pass | each flow in `.chauffeur.json` `reviewFlows` runs as a batch (§4); a step that is not `changed` fails the flow | `FAIL flow "demo login" · step 3 `tap "Sign in"` → NO EFFECT` |
| advisory: unlabeled controls | buttons and images with no name | `warning: 7 unlabeled buttons (chauffeur a11y, stage 2)` |

The URL fetches are the one place chauffeur connects to hosts other than Apple's: the project's own URLs, from the
project's own App Store Connect record or flags. Nothing is sent but the GET.

## 4. Review flows and query targets

A review flow is a chauffeur batch the project keeps in `.chauffeur.json`:

```json
"reviewFlows": [
  { "name": "demo login",
    "steps": "tap \"Sign in\"; type field:Email \"demo@example.com\"; type secure:Password \"$DEMO_PASSWORD\" --submit; wait \"Welcome\"" }
]
```

Two engine changes make that writable without refs:

- **Query targets.** `tap`, `type` and `scroll --in` accept a query as the existing `find` does (`"Sign in"`,
  `button:Save`, `field:Email`, `secure:Password`), resolved against the current tree; it must match exactly one
  element, else the step fails with the matches listed. Refs keep working. This is useful beyond the check and is
  documented in the skill as "when you know the label".
- **Secrets in flows.** A `$NAME` token in a step is replaced from the environment **in the CLI process** when the
  flow runs (the daemon never sees the environment), and the step is sent as `type <target> --secret -- "<value>"`.
  `--secret` is a new `type` flag that makes the daemon treat the value as it already treats text typed into a
  secure field: never traced, never printed, shown as `<secret: N characters>` in the batch's `[i/n]` lines and the
  result. The value crosses the user's own unix socket once and is written nowhere. A missing variable fails the
  flow before it starts: `flow "demo login" needs $DEMO_PASSWORD in the environment`.

`chauffeur review-check --flow "demo login"` runs one flow on its own, for writing it.

## 5. Output and the report

```
review-check Fixture · commit a1b2c3d (clean) · Release configuration · iPhone 18 Pro (iOS 27.0), iPhone 15 (iOS 17.5)
launch      ok · 1.6 s (iOS 27.0) · 2.1 s (iOS 17.5)
crawl       23 screens, 61 taps, 4 skipped by label (Delete account, Sign out, Buy, Share) · 3 min 10 s
placeholder FAIL · screen "About" (via Settings ▸ About): text "Lorem ipsum dolor sit amet"
urls        support https://example.com/help → 200 · privacy https://example.com/privacy → 200 · marketing: none set
flows       demo login → passed (4 steps)
→ REVIEW CHECK FAILED · 1 problem · report .chauffeur/review/a1b2c3d.json
hint: fix "About", then run review-check again; ship --to review needs a passing report for the archive's commit
```

Exit codes: passed 0; failed 7 (the same "refused" code as `ship`'s pre-flight, since that is what it is); an error
running the check 1; a crash during the check is still 7, with the crash block.

The report, `.chauffeur/review/<commit>.json`: the build facts, the simulators, each check with its verdict and
evidence (screen signatures and the path of taps that reached them, the matched text, the URL and status, the flow
step and its result line), the skips, the limits reached, and the time. `--json` prints it. It holds no secrets and
no screenshots; `--screenshots` writes one JPEG per screen under `.chauffeur/review/<commit>/` and lists the paths.

## 6. Agent surface

- **MCP:** `review_check` with `oldest`, `flow`, `max_screens`, `screenshots`, `urls`.
- **Skill:** in the Ship section: run `review-check` before `ship --to review`; the report is the gate; fix what it
  names rather than skipping it. Query targets get a line in the commands table.

## Testing

**Unit (no simulator):**
- The crawl planner on recorded trees under `Fixtures/Review/`: next ref, screen signatures, back strategy, the skip
  list, limits, the system-alert branch; the same trees always give the same plan.
- Placeholder matching: each entry matches as a whole word or token, `Label` and `Button` only as a whole label,
  no false hit on "Testimonials" or "Buttons by Acme".
- The URL check through a fake fetcher: 2xx, redirect to 2xx, 404, timeout, a non-HTTP scheme refused.
- Flows: query resolution (exactly one match, zero, several), `$NAME` substitution in the CLI, `type --secret`
  redaction in the trace, the batch lines and the result, a missing variable.
- The report: JSON shape, the commit and dirty flag, and `ship`'s comparison (match, mismatch, dirty, missing).

**Live (fixture app):** the fixture gains a "Review" tab behind a launch argument (`-review-fixtures`): a label with
"Lorem ipsum", a button labelled "Delete everything" that must be skipped, a link screen, and a `-crash-on-launch`
argument. Expected: the check fails on the placeholder, lists the skip, passes the clean variant, and reports the
crash variant as `FAIL launch` with the crash block. A flow test logs in to the fixture's form with `$DEMO_PASSWORD`.

## Done when

- Unit tests pass in CI; the live tests pass locally.
- `review-check` exists in the CLI and MCP; `ship --to review` requires its report; the skill explains both.
- Query targets work for `tap`, `type` and `scroll --in` and are in the skill.
- Ships with M5a and M5b in 0.3.0.

## Staging

| Gap | Closed by | Stage |
|---|---|---|
| submitting a build nobody launched | the launch check and the `ship` gate | M5c |
| placeholder text, dead links, a demo account that fails | the crawl, URL and flow checks | M5c |
| screenshots that don't show the app in use (2.3.3) | the crawl's screens as candidates, the tree as proof | stage 2 (screenshots spec) |
| accessibility evidence for the Nutrition Labels | the crawl's trees, contrast sampling, traversal order | stage 2 (a11y spec) |
| a trace of the crawl as a UI test | trace-to-test export | stage 2 |
