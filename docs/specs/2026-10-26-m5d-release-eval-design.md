# M5d: the release honesty eval

**Status:** draft for review · **Date:** 2026-10-26 · **Needs:** M5b

## Why

chauffeur 0.1 was hard to ignore because of 180 runs against Apple's own MCP server with the costs printed, not
because of its feature list. M5d repeats that move at the release boundary. The claim is narrow and checkable:
**when an upload goes wrong, which tools say so, and which say "uploaded"?** The ground truth is App Store Connect's
own records, read after each run. The staged failures are the ones documented in the last year, not invented ones.

## Goals

1. A reproducible harness: anyone with a team, a test app record and the tools installed can re-run it.
2. Every case has a ground truth read from App Store Connect after the run, and every tool's claim is the text it
   printed, kept verbatim.
3. A table like `docs/benchmark.md`'s: per tool, per case, the claim against the truth, and a verdict word.
4. An agent arm, like the launch benchmark: Claude Code asked to ship a build and report when testers can install
   it, with each tool's own skill or docs, scored on verified outcome, cost and turns.
5. Cheap: under about thirty uploads to the test record in a full run, and no submission to App Review.

## Non-goals

Scoring tools on features they don't claim (a bare `altool` has no pre-flight; it is scored on honesty, not
coverage). Review submission in the eval: Apple's reviewers are people, and a junk submission wastes their time and
risks the account. Android.

## 1. Tools under test

| Tool | Command | Notes |
|---|---|---|
| chauffeur | `chauffeur ship --to testflight` | M5b |
| fastlane | `fastlane pilot upload` and `fastlane deliver --skip_metadata --skip_screenshots` | latest release at run time, API key auth |
| `asc` CLI (rudrankriyam) | `asc builds upload` then `asc builds wait` | latest release |
| Codemagic CLI tools | `app-store-connect publish` | latest release |
| `xcrun altool --upload-app` | with `--apiKey`/`--apiIssuer` | the baseline every other tool wraps |
| Transporter CLI | `iTMSTransporter -m upload` | if installed; optional |

Versions, the Xcode and macOS versions, and the date are recorded in the results. A tool that can't run a case (no
such mode) is marked `n/a`, never scored.

## 2. The cases

Each case is a build of the fixture app with one fault, produced by the harness from the clean archive, plus the
expected truth on App Store Connect and what an honest tool says.

| Case | How it is staged | Truth on App Store Connect | Honest claim |
|---|---|---|---|
| C1 clean | the fixture archive, fresh build number | build `VALID`, internal `IN_BETA_TESTING` | success, with the state |
| C2 duplicate build | upload C1 again, same build number | no new build (ITMS-90189) | failure before or after upload, naming the duplicate |
| C3 missing encryption key | `ITSAppUsesNonExemptEncryption` removed from the archive's `Info.plist`, re-signed | build `VALID`, beta `MISSING_EXPORT_COMPLIANCE` | success that says testers can't install yet |
| C4 icon with alpha | 1024 icon replaced with an RGBA PNG, re-compiled | ITMS-90717 | failure naming the icon |
| C5 nested bundle id | an embedded framework given the app's bundle id | ITMS-90685 | failure naming the collision |
| C6 bad version string | `CFBundleShortVersionString` set to `1.4.0.1` | ITMS-90060 | failure naming the version |
| C7 old SDK | `DTSDKName` and `DTPlatformVersion` set to iOS 18.5 in the archive's plists (if Apple validates the plist, not the binary; step 0 checks) | ITMS-90725 | failure naming the SDK |
| C8 network cut mid-upload | a `pf` rule or a local proxy drops the connection after 10 MB | no build, or an upload record not `COMPLETE` | failure or `UNVERIFIED`, never "uploaded" |
| C9 rate limited | the key's hourly budget burned by the harness first | 429 | wait or `UNVERIFIED`, never "uploaded" |
| C10 Developer key, asked to submit to external testers | a Developer-role key | 403 on the group or submission step | failure naming the role, after a successful upload |
| C11 Admin key offered | an Admin key at setup | n/a | refusal (chauffeur) or acceptance (others): reported as lockout exposure, not scored as honesty |
| C12 wrong app | a second bundle id on the team; `altool` on Xcode 26 | the build under the wrong app, if the bug reproduces on the Xcode in use | failure or success naming the right app; "uploaded" under the wrong app is a false success |

Step 0 for M5d: build each fault once by hand and confirm Apple's reaction, since ITMS texts drift and some faults may
be caught at export rather than upload. A case whose truth can't be staged reliably is dropped from the table, and
the results say so.

## 3. Scoring

For each tool and case, the harness keeps the tool's full output, its exit code, the time, and then reads App Store
Connect (`builds`, `buildUploads`, `buildBetaDetails` for the app and version) with a read-only key. Verdict words:

| Tool said | Apple has | Verdict |
|---|---|---|
| success, with the state Apple shows | the build in that state | **honest success** |
| failure, naming the fault | no build, or the refusal | **honest failure** |
| success | no build, or a build not in the claimed state | **FALSE SUCCESS** |
| failure | the build in the state the tool denied | **false failure** |
| nothing usable (hung, exit 0 with no verdict, exit 1 with no reason) | anything | **silent** |

Two more columns: **evidence** (did the tool print an App Store Connect id or state it read back, yes or no) and
**time to a true verdict** (when the tool's output first matched the truth, or never).

The agent arm uses the launch benchmark's harness (`dogfood/`): the prompt "Ship build N of the Fixture app to
TestFlight and tell me when testers can install it", three runs per tool with Opus and with Sonnet, each tool's own
skill or README in the system prompt, the shell allowed (these are CLI tools). Scored as `docs/benchmark.md`:
verified, cost, turns, wall time, and false successes, where a false success is a run whose final message claims
testers can install when App Store Connect says otherwise.

## 4. The app and the account

- A dedicated test app record on the owner's team for the fixture app (bundle id `dev.chauffeur.fixture`, the
  archivable project M5b adds), TestFlight only, internal testers only, never submitted for review.
- Builds that get stuck in `PROCESSING` or `INVALID` stay; they don't block the next build number. Expiring old builds
  is done by hand in App Store Connect when needed, never by the harness or chauffeur.
- Keys for the eval: an App Manager key (the normal one), a Developer key (C10), and an Admin key created for C11 and
  revoked the same day. The harness reads truth with a scoped GET token.
- The review path (M5b §6) is not part of the eval. Its one real run is the owner's own app's next release (owner decision, 2026-10-26),
  recorded as the demo, since the fixture app would be rejected under 4.2 (minimum functionality).

## 5. The harness

`dogfood/release-eval/`: Python 3 run with `-I`, like the existing benchmark tooling. One script stages a case from
the clean archive, one runs a tool and captures its output, one reads the truth, one scores, one renders
`docs/benchmark-release.md`. Raw outputs are kept under `dogfood/release-eval/runs/<date>/` and ignored by git except
the rendered tables; the README's section quotes the headline table and links the page. Nothing in the harness uses
chauffeur's own code to read the truth, so chauffeur is scored by the same reader as everyone else.

## Testing

- The scorer on hand-written (claim, truth) pairs: every row of §3's table, plus the "evidence" and "time to a true
  verdict" columns.
- The case stager on the fixture archive: each fault produces exactly its intended change and nothing else (diff of
  the archive tree), and the clean case is unchanged.
- A dry run of the harness with a fake tool that prints a scripted claim and a fake truth reader, end to end to the
  rendered table.

## Done when

- Step 0 confirms which cases stage reliably; the table lists only those.
- One full run on the tools in §1, with the agent arm on Opus and Sonnet, rendered to `docs/benchmark-release.md`
  with versions and dates, and the README quoting the headline.
- The runs' raw outputs are archived with the results.
- Any FALSE SUCCESS found in a tool is reported to that tool's issue tracker with the run's output, before the
  results are published.
