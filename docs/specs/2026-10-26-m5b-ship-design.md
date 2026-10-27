# M5b: `chauffeur ship`: a release the agent can't misreport

**Status:** draft for review · **Date:** 2026-10-26 · **Needs:** M5a (the key); M5c (the review check) for
`--to review`

## Why

The place where tools lie most is the upload. In the last year: `xcrun altool` on Xcode 26 returned exit 0 having
uploaded nothing, and sometimes attached the build to the wrong app on teams with several bundle IDs (confirmed by
Apple DTS); fastlane printed "Successfully uploaded the new binary" right after altool printed `UPLOAD FAILED with 3
errors`, because Xcode 26 changed an error prefix and fastlane's regex missed it; and the opposite, fastlane calling an
upload failed on a duplicate error while the build was already in TestFlight. Further down, Apple rejected 23% of 2025
submissions, with crashes, placeholder content and missing demo accounts (guideline 2.1) the largest bucket.

Apple now exposes every stage as a typed record: `buildUploads` has a state, `builds` has a `processingState`,
`buildBetaDetails` has internal and external states, `appStoreVersions` has an `appVersionState`. No tool reads them
back and tells the agent, in the agent's own result, which record says so. Xcode 27's MCP bridge has no archive,
upload or signing tool at all.

`chauffeur ship` applies chauffeur's one rule to the release: **a stage is reported done only when App Store Connect's
record says it is.** "Uploaded" without the record is `UNVERIFIED`, like a tap without a diff.

## Goals

1. Every stage line names the App Store Connect record it was read from. There is no stage that is inferred from an
   exit code or a tool's stdout.
2. What Apple would refuse after the upload is caught before it (§2), with the ITMS code it would have produced.
3. The archive, like a build or a test run, gets its verdict from the `.xcresult`, never from `xcodebuild`'s exit code.
4. A crash or re-run in the middle of a release resumes from the record. Never a second upload, never a build number
   bumped behind the developer's back.
5. `ship` stops at "testable" unless told `--to review` or `--to store`, and refuses `--to review` without a fresh
   review check (M5c) for the same commit.
6. A full `ship` transcript is under forty lines; `ship status` is one line per stage.

## Non-goals (staged, not ruled out)

Metadata beyond the version string and "What's New"; screenshots and the App Asset Library; in-app purchases;
pricing; phased release; localization management; watchOS, macOS, tvOS and visionOS (the design is per platform; iOS
first); Xcode Cloud; webhooks (polling first; webhooks need a public URL, stage 2); replacing `xcodebuild` (chauffeur
runs it and reads its result bundle).

## 1. Step 0: what to verify before the plan

With the owner's team, a test app record for the fixture app, and the owner's key:

1. **The Build Upload API's shapes.** Apple's pages render the attribute schemas empty. From Apple's OpenAPI
   specification: the exact attributes of `BuildUploadCreateRequest`, `BuildUploadFileCreateRequest` (file name, size,
   type), `BuildUploadFileUpdateRequest` (the commit: which checksum, which algorithm, which field), the
   `uploadOperations` entries (url, method, headers, offset, length), `BuildUploadState` values and the `StateDetail`
   shape. Then one real upload of the fixture app: timings per chunk, how long until `COMPLETE`, how long until the
   `builds` record exists, and whether `preReleaseVersions` appears first.
2. **A bad build's `StateDetail`.** Upload a build with a nested bundle-identifier collision and one with a reused
   build number: what the `buildUploads` record says, when, and whether a `builds` record is created at all.
3. **`.xcresult` on Xcode 26 and 27.** The JSON of `xcrun xcresulttool get build-results` and `get test-results
   summary` for: a clean build, a build with errors, a test run with failures, a test run with zero tests, and an
   archive. Record the fields that give the verdict.
4. **A Developer key's 403s.** The status and error JSON of `POST /v1/appStoreVersions` and
   `POST /v1/betaGroups/{id}/relationships/builds` with a Developer key, so the role messages are right.
5. **Processing time** for five fixture uploads, for the "typical is N minutes" line.

Outcomes: if the Build Upload API can't be driven end to end, M5b does not fall back to `altool`; it comes back for
review, because the failure classes above live in `altool`.

## 2. Build evidence: `build`, `test`, `archive`

Three new commands, run in the CLI process (not the daemon), each a thin wrapper that runs `xcodebuild` with
`-resultBundlePath` and judges from the result bundle:

```
chauffeur build   [--scheme S] [--configuration Debug|Release] [--workspace W | --project P]
chauffeur test    [--scheme S] [--only <Target/Class/test>]
chauffeur archive [--scheme S] [--configuration Release]
```

Scheme, workspace and project are found as the skill already describes (one of each in the folder, else the flag is
required). Derived data goes under `build/` as today's skill says. The simulator destination for `build` and `test`
is the pinned target.

| Result bundle says | `xcodebuild` exit | Verdict |
|---|---|---|
| no errors, product exists | 0 | `built · 0 warnings · 12 s · build/…/Fixture.app` |
| errors | any | `BUILD FAILED · Sources/Login.swift:41: cannot find 'user' in scope` (first error; `--json` has all) |
| no errors, product missing | 0 | `UNVERIFIED · xcodebuild exited 0 but no product at …` |
| tests ran, all passed | any | `passed 42/42 · 8 s` |
| tests ran, some failed | any | `FAILED 2 of 42 · LoginTests.testEmpty · XCTAssertEqual failed: …` |
| zero tests ran | 0 | `UNVERIFIED · 0 tests ran (wrong scheme or filter?)` |
| archive exported, `.xcarchive` exists with `Info.plist` and the app | 0 | `archived · Fixture 1.4 (87) · iOS 26 SDK · build/Fixture.xcarchive` |

Exit codes: `built`/`passed`/`archived` 0; `BUILD FAILED`/`FAILED` 1; `UNVERIFIED` 3. The verdict never comes from the
exit code alone: Xcode 26 is documented returning 0 on failed UI tests, and "SUCCEEDED with 0 tests" is a known trap.
The last 20 lines of `xcodebuild`'s output are written to `build/chauffeur-<cmd>.log` and the path is printed on
failure.

`archive` also prints the facts pre-flight will use, read from the archive's `Info.plist` and the app's: bundle id,
version, build, SDK, minimum OS, signing identity and profile name. It writes a sidecar, `chauffeur.json`, inside
the `.xcarchive` folder: the commit, whether the tree was dirty, the scheme and configuration, and the time. `ship`
runs `archive` itself unless given `--archive <path.xcarchive>`; a foreign archive without the sidecar can still ship
to TestFlight, but `--to review` needs `--commit <sha>` for the review gate (§3), and the transcript says the commit
was supplied by hand.

## 3. Pre-flight: what Apple would refuse

Apple receives the exported IPA, not the archive, and `-exportArchive` is where the App Store profile, the final
entitlements (no `get-task-allow`, production `aps-environment`) and thinning are applied. So `ship` exports first
(§4 step 2; it writes nothing to App Store Connect) and **pre-flight runs on the exported IPA's `Payload/<App>.app`**,
the bytes that will be uploaded. Checks that need the archive's own plist (SDK, Xcode build) read it too. **Blocking**
checks stop the run (`REFUSED before upload`, exit 7). **Advisory** checks print a `warning:` and continue, because
they are heuristics.

| Check | Reads | Prevents | Kind |
|---|---|---|---|
| SDK is iOS 26 or later | `DTSDKName`, `DTPlatformVersion` | ITMS-90725 (hard since 2026-04-28) | blocking |
| `MinimumOSVersion` ≥ 13 | app `Info.plist` | the 2026-09-09 requirement | blocking |
| `CFBundleShortVersionString` is `a.b.c` of integers | `Info.plist` | ITMS-90060 | blocking |
| version ≥ the last version on App Store Connect | `appStoreVersions` | ITMS-90062 | blocking |
| build string unused for this version | `builds` filtered by version and build | ITMS-90189 | blocking |
| bundle id has an app record the key can see | `apps` by bundle id | the wrong-app failure, by construction | blocking |
| `embedded.mobileprovision` present, distribution type, not expired, matches the bundle id | the profile | ITMS-90161, 90174 | blocking |
| entitlements ⊆ the profile's | `codesign -d --entitlements`, the profile | ITMS-90046, "doesn't include the … entitlement" | blocking |
| no two nested bundles share a `CFBundleIdentifier`; no `Frameworks` folder inside a framework | the app tree | ITMS-90685, the March 2026 altool case | blocking |
| 1024 pt marketing icon present, no alpha | the asset catalog's compiled icon | ITMS-90717 | blocking |
| `ITSAppUsesNonExemptEncryption` present | `Info.plist` | `MISSING_EXPORT_COMPLIANCE` (testers can't install) | blocking unless `--encryption exempt\|non-exempt`, which sets it on the build after processing |
| `PrivacyInfo.xcprivacy` at the app root and in each embedded SDK on Apple's list | the app tree | ITMS-91053, 91061 | advisory |
| a purpose string for each sensitive framework linked | `otool -L` against a table of framework → `NS…UsageDescription` | ITMS-90683 | advisory |
| `aps-environment` when APNs symbols are linked | `nm`, entitlements | ITMS-90078 | advisory |
| `UIUserInterfaceStyle`, if set, is Light, Dark or Automatic | `Info.plist` | ITMS-90785 | blocking |
| no `x86_64` slice | `lipo -info` | ITMS-90087 | blocking |
| `--to review`: a review check report (M5c) exists for this commit and passed | `.chauffeur/review/<commit>.json` | guideline 2.1 | blocking unless `--skip-review-check`, which is printed in the transcript |
| `--to review`: a Developer key | the sheet (M5a) | a 403 after the upload | blocking |

Output on refusal:

```
ship Fixture 1.4 (87) → REFUSED before upload · 2 problems
  build 87 already exists for 1.4 on App Store Connect (uploaded 2026-10-25, PROCESSING) — ITMS-90189
  ITSAppUsesNonExemptEncryption missing from Info.plist: testers can't install until export compliance is set
hint: bump the build number, add the key (or pass --encryption exempt), then run ship again
```

A refused run uploads nothing and writes nothing to App Store Connect. The checks live under
`Sources/ChauffeurCore/Release/Preflight/`, one file per input they read (`Plist.swift`, `Profile.swift`,
`Signing.swift`, `Bundles.swift`, `Icon.swift`, `Connect.swift`), one check per function, each returning a `Finding`
with its ITMS code, and a `Preflight.swift` that lists them in order, so a PR can add one and no file nears the
400-line limit.

## 4. Upload, read back

The upload uses Apple's Build Upload API (API 4.1), never `altool` or Transporter:

1. Export: `xcodebuild -exportArchive` with an app-store-connect export options plist chauffeur writes itself
   (`method: app-store-connect`, `destination: export`, `uploadSymbols: true`, automatic signing unless the project's
   settings say manual). Then pre-flight (§3) on the exported payload.
2. `POST /v1/buildUploads` for the app **by id** (resolved in pre-flight from the payload's bundle id). The wrong-app
   failure can't happen: the request names the app.
3. `POST /v1/buildUploadFiles` reserving the IPA; Apple returns `uploadOperations`.
4. `PUT` each chunk to the URL, with the headers, offset and length Apple gave, retrying a failed chunk three times
   with backoff. Only these URLs, only for these PUTs (M5a §4).
5. `PATCH /v1/buildUploadFiles/{id}` committing with the checksum Apple asks for.
6. Poll `GET /v1/buildUploads/{id}` with a scoped token until the state leaves `AWAITING_UPLOAD` and `PROCESSING`.
7. Find the `builds` record: `GET /v1/builds?filter[app]=…&filter[version]=87&filter[preReleaseVersion.version]=1.4`.

What the stages mean:

| Line | True only when |
|---|---|
| `sent 48.2 MB in 31 s` | every chunk's PUT returned 2xx and the commit was accepted |
| `delivered · buildUploads/8F3A… COMPLETE` | the upload record's state is `COMPLETE` |
| `REFUSED by Apple · buildUploads/8F3A… FAILED` | the state is `FAILED`; `StateDetail`'s messages follow verbatim, with ITMS codes |
| `processing · builds/2B91… PROCESSING for 3 min (typical: N min)` | the build record exists and says so |
| `processed · builds/2B91… VALID` | `processingState == VALID` |
| `REFUSED by Apple · builds/2B91… INVALID` | `INVALID` or `FAILED`; what Apple says follows |

There is no line for "uploaded". Between "sent" and "delivered" the state is `delivered?` and the result, if the
command has to stop there, is `UNVERIFIED · sent, but App Store Connect hasn't confirmed buildUploads/8F3A… yet`
with the id, so `ship status` can finish the job.

## 5. TestFlight

After `processed`:

- **Export compliance.** If the build's `usesNonExemptEncryption` is unset and `--encryption` was given, `PATCH
  /v1/builds/{id}` sets it. The read-back is the `buildBetaDetails` state leaving `MISSING_EXPORT_COMPLIANCE`.
- **Internal testers.** Internal groups with access to all builds get the build with no action; the line reads
  `testable (internal) · buildBetaDetails/… IN_BETA_TESTING · 3 internal groups`. `--group <name>` adds the build to
  a named group (`POST /v1/betaGroups/{id}/relationships/builds`).
- **External testers.** `--group <name>` naming an external group also needs test notes (`--notes <file>` or
  `--notes "text"`), posted as `betaBuildLocalizations`, then a beta review submission. The stages that follow are
  Apple's: `WAITING_FOR_BETA_REVIEW` → `IN_BETA_REVIEW` → `BETA_APPROVED` → `IN_BETA_TESTING`, each line quoting
  the state. `BETA_REJECTED` is `REFUSED by Apple` with the reason from the record if present and a link to App Store
  Connect. A 422 `BETA_CONTRACT_MISSING` is printed verbatim with the hint that an Admin must accept the agreement in
  App Store Connect.

"Testers can install" is printed only for `IN_BETA_TESTING` or `READY_FOR_BETA_TESTING` (internal) and `BETA_APPROVED`
or `IN_BETA_TESTING` (external), with `expired == false`. Any other state is reported as that state.

## 6. Review and release

`--to review` adds, after `processed`:

1. `appStoreVersions`: find the version for the platform and version string, or create it (`POST
   /v1/appStoreVersions`, `releaseType: MANUAL` unless `--release-after-approval`). `MANUAL` is the default so that
   approval never ships by itself (author's call).
2. Attach the build (`PATCH /v1/appStoreVersions/{id}/relationships/build`).
3. "What's New": `--notes` is required for a version that already has a released predecessor; written to each
   `appStoreVersionLocalizations` the version has (`PATCH`). A per-locale 409 ("Attribute 'whatsNew' cannot be edited
   at this time") is printed verbatim for that locale and the run stops before submitting.
4. `POST /v1/reviewSubmissions`, `POST /v1/reviewSubmissionItems` with the version, then `PATCH` with
   `submitted: true`. The read-back is the submission's state and the version's `appVersionState`
   (`WAITING_FOR_REVIEW`, `IN_REVIEW`, `PENDING_DEVELOPER_RELEASE`, `READY_FOR_DISTRIBUTION`, `REJECTED`,
   `METADATA_REJECTED`, `DEVELOPER_REJECTED`).
5. Apple's `STATE_ERROR.ENTITY_STATE_INVALID` on submit (a newly required field, an unanswered questionnaire) is
   printed with Apple's `detail` verbatim and a link to the version in App Store Connect. chauffeur doesn't try to
   fill fields it doesn't know about.

`--to store` (or a later `chauffeur release`) runs once the version is `PENDING_DEVELOPER_RELEASE`: `POST
/v1/appStoreVersionReleaseRequests`, read back as `READY_FOR_DISTRIBUTION`. `ship` with `--to store` on a version
still in review stops at `in review` with exit 6; `ship status --to store` finishes it later.

What `ship` never does, whatever the flags: cancel or remove a submission, expire a build, reject its own binary,
change pricing or availability, delete anything. When a run is wrong after submission, the hint says what to do by
hand and gives the App Store Connect URL.

## 7. Output, exit codes, JSON

A complete run to TestFlight:

```
ship Fixture 1.4 (87) → to testflight · key 7X2K9ABC1D (App Manager) · app apps/6451… (com.example.fixture)
archived    Fixture 1.4 (87) · iOS 26.1 SDK · min iOS 17 · build/Fixture.xcarchive · 48 s
preflight   14 checks passed · warning: no PrivacyInfo.xcprivacy in Frameworks/Analytics.framework
sent        48.2 MB in 31 s
delivered   buildUploads/8F3A… COMPLETE · 0:42 after send
processing  builds/2B91… PROCESSING · 4 min (typical: 3–6 min)
processed   builds/2B91… VALID · 1.4 (87) · uploadedDate 2026-10-26T14:02:11Z
testable    buildBetaDetails/2B91… IN_BETA_TESTING · internal: 2 groups · external: not requested
→ testable · 1.4 (87) · 6 min 12 s
```

A refusal after the upload:

```
delivered   buildUploads/8F3A… COMPLETE
→ REFUSED by Apple · builds/2B91… INVALID
  "ITMS-90685: CFBundleIdentifier Collision. There is more than one bundle with the CFBundleIdentifier value
  'com.example.fixture' under the iOS application 'Fixture.app'."
hint: Frameworks/Analytics.framework carries the app's bundle id; fix its Info.plist, bump the build to 88, ship again
```

| First line | Exit |
|---|---|
| `→ testable`, `→ submitted`, `→ in review` reached as requested, `→ released` | 0 |
| an error running a tool (`xcodebuild` missing, keychain read refused) | 1 |
| `UNVERIFIED` (sent but not confirmed; rate limited; Apple unreachable) | 3 |
| `PENDING` (still `PROCESSING`, `IN_REVIEW`, or waiting for beta review after the wait limit) | 6 |
| `REFUSED before upload` or `REFUSED by Apple` | 7 |

`--wait <s>` caps the run (default 20 min; 0 returns after `delivered`). `--json` emits one object: `stages` as an
array of `{name, record, state, at, ms}`, `findings`, `outcome`, `hint`. Apple's strings are escaped as untrusted
text. `chauffeur ship status` prints the stages again from the state file (§8) and the live records, one line each.

## 8. Resume: the state file

`ship` writes `.chauffeur/ship/<bundle>-<version>-<build>.json` in the project before the first request to App Store
Connect: the archive path and its commit, the app id, then each record id as it is created (`buildUpload`,
`buildUploadFile`, `build`, `appStoreVersion`, `reviewSubmission`), and the stages reached.

- A second `ship` for the same archive reads it and **re-attaches**: an upload record in `AWAITING_UPLOAD` is
  resumed from the next chunk; a `COMPLETE` one skips to finding the build; a build that exists skips the upload.
  Nothing is uploaded twice, and the build number is never changed by chauffeur.
- `.chauffeur/` must be ignored by git; `ship` warns once if it isn't, since the file holds record ids and paths.
- The file holds no key, token or Apple error body.

## 9. Agent surface

- **MCP:** one new tool, `ship`, with `to` (`testflight` | `review` | `store`), `group`, `notes`, `encryption`,
  `wait`, `status` (boolean: report, don't act), and `archive`; and `build` with `action` (`build` | `test` |
  `archive`), `scheme`, `configuration`, `only`. Keys have no tool (M5a). Over MCP, `wait` defaults to 0: the call
  returns at `delivered` (or `UNVERIFIED`/`REFUSED`) and the tool description tells the agent to call `ship` with
  `status: true` later, because the MCP server handles one call at a time and a twenty-minute call would block it.
  The CLI default stays 20 minutes. The tool definitions move from `MCPTools.swift` (already near the limit) into one
  file per tool group under `Agent/Tools/`.
- **Skill and `AGENTS.md`:** a "Ship" section: the loop (`build`/`test` for a verdict; `review-check` before `ship
  --to review`; read the first line; `PENDING` means `ship status` later; `REFUSED` means fix and ship again), and
  the rule that a stage is real only with its record. One sentence that keys are the human's, never the agent's.
- `chauffeur help` lists the commands; `doctor` adds the key line (M5a) and the pinned app.

## 10. Release

New commands, two new tools and an exit code change what agents see: M5a, M5b and M5c ship together as **0.3.0**,
after M4b's 0.2.0. The README gains a ship section and, when M5d is done, the release honesty table.

## Testing

**Unit (no network):**
- `.xcresult` judging on the recorded JSON from step 0: each row of §2's table on Xcode 26 and 27 shapes.
- Pre-flight: a synthetic exported payload tree per check under `Tests/ChauffeurCoreTests/Fixtures/Payloads/` (plus
  the archive plist the SDK check reads), each failing exactly its check with its ITMS code; the clean payload passes
  all; advisory checks never block.
- The upload: a fake transport records every request; the order of §4's steps, chunk retry, the commit body, the
  app addressed by id, and that only Apple's returned URLs are PUT to.
- The state machine on recorded responses: every `buildUploads`, `processingState`, internal and external beta state
  and `appVersionState` value maps to the stage word in §4–§6, and no other input produces "testers can install",
  "submitted" or "released".
- Resume: each stage of the state file re-attaches at the right step; the same archive twice never uploads twice.
- Output: the transcript examples in §7 render byte for byte from fixtures; exit codes; the JSON shape; Apple strings
  escaped.
- The deny guarantees (M5a's table test) still pass with M5b's operations added: no DELETE, no `expired`, no
  `canceled`.

**The fixture app must become archivable first.** Today `Tests/FixtureApp` is built by `build.sh` with `swiftc`
for the simulator, ad-hoc signed, with no project or scheme. M5b adds `Tests/FixtureApp/Fixture.xcodeproj` with one
scheme, bundle id `dev.chauffeur.fixture`, automatic signing, and `DEVELOPMENT_TEAM` read from an ignored
`Tests/FixtureApp/Local.xcconfig` (a committed `Local.xcconfig.example` shows the one line), so no team id reaches
the public repo. `build.sh` keeps building the simulator app the existing live tests use. The owner registers the
bundle id on their team and creates the app record, TestFlight only (an owner to-do, not a design question).

**Live (owner's team, the fixture app's test record):** a clean ship to internal TestFlight reaches `testable`; a
reused build number is `REFUSED before upload`; a build without the encryption key is refused, then ships with
`--encryption exempt` and the beta state leaves `MISSING_EXPORT_COMPLIANCE`; a nested-bundle-id build is `REFUSED by
Apple` with the ITMS text; `ship status` after killing `ship` mid-upload resumes without a second upload. The review
path (§6) is run for real on the owner's own App Store app, its next release (owner decision, 2026-10-26): the fixture app
isn't store-worthy. That run is the demo: its transcript, with the record ids, is the README's ship section.

## Done when

- Step 0's findings are in this spec and the design matches them.
- Unit tests pass in CI; the live tests pass locally against the owner's test record.
- `build`, `test`, `archive`, `ship` and `ship status` exist in the CLI and the MCP tools; the skill has the Ship
  section.
- `docs/design.md` records the release scope, the stage words and the "no stage without its record" rule;
  `CLAUDE.md`'s "Where code goes" gains rows for `Connect` and `Release`.
- 0.3.0 is released per §10.

## Staging

| Gap | Closed by | Stage |
|---|---|---|
| "uploaded" with nothing on App Store Connect | Build Upload API and record read-back | M5b |
| the build attached to the wrong app | app addressed by id | M5b |
| ITMS refusals after a slow upload | pre-flight | M5b |
| `MISSING_EXPORT_COMPLIANCE` after processing | pre-flight and `--encryption` | M5b |
| a re-run uploading twice | the state file | M5b |
| exit 0 on a failed build or test | `.xcresult` verdicts | M5b |
| submit with a crash or placeholder in the build | M5c's report as a pre-flight check | M5b + M5c |
| waiting by polling | webhooks through a small public endpoint | stage 2 |
| metadata, screenshots, Asset Library | its own spec | stage 2 |
| watchOS, macOS, visionOS | per-platform pre-flight and destinations | stage 2 |

## Findings

To be filled in from step 0 before the plan is written.
