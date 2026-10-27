# M5a: the App Store Connect key, and what it can never do

**Status:** revised 2026-10-27 after Step 0 (see Decision) · **Date:** 2026-10-26

## Why

M5b teaches chauffeur to ship a build. For that it needs an App Store Connect API key, and the key is the dangerous
part. Through documented endpoints, a key with the Admin role can remove every other Admin on the team, revoke the
team's one Apple Distribution certificate (which invalidates every provisioning profile and marks unsubmitted builds
Invalid Binary), delete bundle IDs and profiles, expire every TestFlight build and cancel review submissions. None of
that can be undone by API. An agent holding such a key, one bad tool call or one injected instruction away from any of
it, is a lockout waiting to happen.

Apple gives a tool almost nothing to narrow a key after the fact. A team key has one role, fixed at creation. It
reaches every app on the team. The JWT `scope` claim is documented for GET requests only. And (Findings 2) Apple
exposes no read that tells an Admin key from an App Manager key, except one finance-report quirk that works as a
one-way alarm. So the guards that hold are: the client's own code, which has no request that could lock anyone out;
the binary, which must be the only process that can read the key; and the human, who sees every write named in a
Touch ID sheet before it is sent. (The first draft called a confirmation prompt theatre. That was wrong here: when
an agent runs chauffeur, chauffeur's output goes to the agent, so the Touch ID sheet is the human's only trusted
channel, and a prompt rendered from the exact request is load-bearing. M5b designs it.)

M5a is the first two guards and the setup that explains them. **chauffeur's client has no code path that could lock
the team out, whatever key it holds; setup refuses the one dangerous role it can detect (Admin, through the finance
alarm) and tells the human which role to mint.** The worst an agent can do with chauffeur's key is upload a build
nobody wanted, which is recoverable.

This also changes a line in `docs/design.md`. "No telemetry, no network access" becomes: **no telemetry; the only
network connections are to App Store Connect, only during release commands, and to the project's own metadata URLs in
the review check (M5c).** The promise that mattered was never "no network"; it was "nothing about you leaves your Mac".

## Goals

1. chauffeur can't revoke a certificate, delete an identifier or profile, remove or change a user, invite a user,
   delete a webhook, change pricing or availability, or touch in-app purchases, whatever key it holds: the client
   can't send those requests (§4). Setup refuses the one dangerous role it can detect, Admin or Finance, through the
   finance alarm (§3), and says plainly that it can't verify the rest of the declared role.
2. The `.p8` lives in the login keychain, readable only with the user present (Touch ID or password), never in a
   file chauffeur wrote, an environment variable, a log, the trace, or an MCP response.
3. The agent sees named operations only. There is no "send this request" command, in the CLI or over MCP.
4. Tokens are short: two minutes for a one-off call, twenty for an upload session, GET-only scoped tokens for polling.
5. Setup tells the human, in words, what the key can and can't do before storing it.
6. Nothing leaves the Mac except requests to `api.appstoreconnect.apple.com` and the upload hosts Apple hands back.

## Non-goals (staged, not ruled out)

Individual keys (`sub: "user"` tokens; they inherit a person's role and can't do provisioning): team keys only in
M5a. The Enterprise Program API. CI secret stores and headless runners beyond the `--no-presence` escape in §2.
Key rotation helpers. Webhooks (M5b stage 2: they need a public URL).

## 1. Step 0: what to verify before the plan

With the owner's team, keys of each role created for the purpose and revoked afterwards:

1. **Keychain from a CLI.** Does a generic-password item with `kSecUseDataProtectionKeychain`,
   `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` and a `SecAccessControl` of `.userPresence` work from a plain
   command-line process on macOS 15 and macOS 26? Does the read offer Touch ID, or only the password? Does the prompt
   appear when chauffeur runs from Claude Code's shell, with no TTY? What happens over SSH (expected: the read fails;
   record the error)?
2. **The probes.** For an Admin key, an App Manager key with and without the "Certificates, Identifiers & Profiles"
   toggle, and a Developer key: the status and the error JSON of `GET /v1/users?limit=1` and
   `GET /v1/certificates?limit=1`. Apple's help says only Account Holder and Admin can revoke distribution
   certificates; a third-party transcription of the role matrix says App Manager with the toggle can. Step 0 settles
   it: the probe is the rule, whichever way the answer goes. **If an App Manager key also gets 200 on `/v1/users`**
   (Apple's chart gives App Managers some user management, below Admin), that probe can't tell the two apart, and
   step 0 must find a read that only Admin can make (candidates to try: `GET /v1/users/{id}` for an Admin user,
   the `visibleApps` of users, `userInvitations`). If none exists, §3's branch "no Admin-only read" applies.
3. **Reading the role back.** Is there any endpoint that tells a key its own role? (Expected: no. Then §3's declared
   role stands, checked at first write.)
4. **Scoped tokens.** A token whose `scope` is `GET /v1/builds/{id}` polls that build; the same token on a PATCH gets
   `405`. Record both.
5. **A key file's permissions as downloaded.** What mode does Safari give `AuthKey_XXXX.p8` in `~/Downloads`? (For
   the message in §2 that asks the human to delete it.)
6. **Reading attributes without the prompt.** Does `SecItemCopyMatching` with `kSecReturnAttributes` and no
   `kSecReturnData` return the item's comment without triggering the user-presence prompt? `doctor` and `keys list`
   depend on it (§7); if it prompts, §7's index item is used instead.

The answers go into "Findings" at the end before the plan is written. If the user-presence read doesn't work from a
CLI process (question 1), M5a stores the item without the access control, says so in `keys list`, and the design
comes back for review before M5b.

## 2. Commands

```
chauffeur keys add <AuthKey.p8> --issuer <uuid> --key-id <id> --role developer|app-manager [--no-presence]
chauffeur keys list
chauffeur keys check [<key-id>]
chauffeur keys remove <key-id>
chauffeur keys use <key-id>          pins the key for this project (.chauffeur.json "connectKey")
```

None of these run in the daemon, and none is an MCP tool. Adding a key needs a human with the file; an agent never
adds, lists or removes keys. `ship` (M5b) reads the pinned key.

**`keys add`** reads the file, probes (§3), prints the capability sheet, and only then stores the key (§5). It never
deletes or moves the human's file; it ends with:

```
stored key 7X2K9ABC1D (App Manager, 3 apps) in your login keychain, Touch ID to use
hint: ~/Downloads/AuthKey_7X2K9ABC1D.p8 is still on disk; keep a copy somewhere safe, then delete it
```

**`--no-presence`** stores the item without the user-presence requirement, for a runner with no Touch ID and no one
at the keyboard. It prints a warning that any process running as this user can read the key, and `keys list` marks
the key `(no presence)`. Owner's call to allow it at all (recorded here as the author's call, 2026-10-26): CI is not
M5a's target, but refusing it would push people back to a `.p8` on disk, which is worse.

**`keys check`** re-runs the probes and reprints the sheet. `ship` runs the same probes at the start of every run,
so a key whose role was changed by revoking and re-creating it under the same id can't slip through.

**The pin.** `.chauffeur.json` gains `"connectKey": "<key-id>"` and, once M5b resolves it, `"connectApp": "<asc app
id>"`. `chauffeur use` keeps both (it merges, since M4b). Resolution: `--key <id>` › `.chauffeur.json` › the only
key in the keychain › an error listing the keys.

## 3. The probes: what a key may be (revised 2026-10-27)

Step 0 (Findings 2) showed that an Admin key and an App Manager key answer identically on every ordinary read,
including `/v1/users` and `/v1/certificates`, and that every App Manager team key reads Certificates, Identifiers &
Profiles (the key dialog has no toggle any more). The first draft's probes would have refused every key that can
ship. What survives is one asymmetry: only Account Holder, Admin and Finance may "view payments and financial
reports", and `GET /v1/financeReports` checks the role before it checks its parameters. With an impossible vendor
number the request can never return data, so it is a safe **finance alarm**.

Before storing, and at the start of every release command, in this order:

| Probe | Response | Verdict |
|---|---|---|
| `GET /v1/apps?limit=200` | 401 | **rejected.** "App Store Connect rejected the key: check `--issuer` and `--key-id`, and that the key is not revoked" |
| `GET /v1/apps?limit=200` | 429 | "rate limited by App Store Connect: N requests left this hour; try again later" |
| `GET /v1/apps?limit=200` | 200 | the sheet lists the apps |
| `GET /v1/financeReports?filter[regionCode]=US&filter[reportDate]=<last month, yyyy-MM>&filter[reportType]=FINANCIAL&filter[vendorNumber]=0` with `Accept: application/a-gzip` | 400 `PARAMETER_ERROR.INVALID` | **refused: finance-capable key.** "This key can read the team's finance reports, which only Admin, Account Holder and Finance keys can. An Admin key can remove every other Admin, revoke certificates and delete identifiers; chauffeur never holds one. In App Store Connect, generate a key with the App Manager role." |
| same | 403 `FORBIDDEN_ERROR` | **not finance-capable:** accepted with the declared role |
| same | anything else (another 403 code such as `FORBIDDEN.REQUIRED_AGREEMENTS_MISSING_OR_EXPIRED`, 5xx, a transport error) | **unknown:** accepted with the declared role; the sheet says `role check: unavailable (<status> <code>)` |

The alarm is one-way and best-effort: a 400 is proof of finance access; a `FORBIDDEN_ERROR` is Apple's answer today
and could change if Apple reorders its checks; anything else proves nothing. The verdict is never "proven App
Manager". Refusing finance-capable keys costs no capability: App Manager is the least role that can submit and
release, and Admin adds nothing to the release path (Findings 2, research 2026-10-27).

The role the human declared (`--role`) can't be read back (step 0, question 3). It is stored on the item and checked
at first write (M5b): a Developer key that gets `403 FORBIDDEN_ERROR` on a write the sheet promised is reported as
`key 7X2K… is Developer, not App Manager: it can upload and read, but not submit, edit metadata or manage testers`
and the sheet is corrected. A 403 whose code starts with `FORBIDDEN.REQUIRED_AGREEMENTS` is an agreement problem,
not a role problem, and is reported as such.

**The capability sheet**, printed by `add` and `check`, in words, from the declared role, the alarm and the table:

```
key 7X2K9ABC1D · App Manager (declared) · issuer 69a6de70… · apps: chauffeur-fixture (dev.chauffeur.fixture), Notes (dev.x.notes)
role check: not an Admin or Finance key (finance alarm) · App Store Connect offers no other read-back
can:    upload builds · manage TestFlight groups and testers · edit version metadata · submit for review · release
cannot (Apple's role chart): add or remove Admins · generate keys · remove or transfer apps · sign agreements
unverified for this role: revoking certificates, deleting profiles and identifiers · chauffeur has no such request
chauffeur will never: expire a build · cancel a submission · remove a tester · delete or revoke a certificate, identifier or profile · invite or remove a user · change pricing or availability · touch in-app purchases · manage webhooks
```

With the unknown verdict the second line reads
`role check: unavailable (403 FORBIDDEN.REQUIRED_AGREEMENTS_MISSING_OR_EXPIRED) · taking App Manager as declared`.
The Developer sheet keeps its `can:` line (`upload builds · read builds, TestFlight and version state`) and its
`cannot:` line (`submit for review · edit version metadata · manage testers` plus the chart items). The last line
is §4's deny list, generated from the table, so the human reads what the code refuses, not only what Apple's role
allows.

## 4. The client: named operations, and nothing else

A new `Sources/ChauffeurCore/Connect/` folder. Nothing in it is private API. (`Keys` is already a type in
`Device/Input.swift`, the HID key codes; the command's type is `ConnectKeys`.) `CLAUDE.md`'s "Where code goes" table
gains a row for `Connect` (App Store Connect: the key, tokens, the request table) when the plan lands.

- **`ConnectClient`** sends exactly the requests in a static **request table**: one entry per operation, with its
  method, path template, the role it needs, and whether it writes. A request not in the table can't be built: the
  only way to make one is through an `Operation` value, and every `Operation` case maps to one table row. There is no
  "raw request" initialiser, public or internal.
- **The table has no DELETE at all**, no PATCH on `users`, `certificates`, `bundleIds`, `profiles`, `webhooks`,
  `betaTesters` or `betaGroups` membership removal, and (revised 2026-10-27) no POST on `certificates`,
  `bundleIds`, `profiles`, `userInvitations`, `webhooks`, `inAppPurchases`, `subscriptions`, `appPriceSchedules`
  or `appAvailabilities`. `PATCH /v1/builds/{id}` exists for `usesNonExemptEncryption`
  only; the body encoder for it has no `expired` field. `PATCH /v1/reviewSubmissions/{id}` exists for `submitted`
  only; its encoder has no `canceled` field. A unit test walks the table and asserts each of these, so a later PR
  can't add one without changing the test, and the sheet's "chauffeur will never" line is generated from the same
  table.
- **Operations in M5a** (M5b adds the release ones and lists them in its spec): the three probes; `apps` (list, by
  bundle id); `builds` (list with filters, one by id); `buildBetaDetails`; `betaGroups`; `preReleaseVersions`;
  `appStoreVersions` (list, by id); `appStoreVersionLocalizations`; `reviewSubmissions` (list, by id); `buildUploads`
  (by id); `buildUploadFiles` (by id). Reads only. Each read is a GET-scoped two-minute token (§6).
- **Hosts.** Requests go to `api.appstoreconnect.apple.com`. The one exception is the chunk upload in M5b, whose
  URLs Apple returns in `uploadOperations`; the client accepts those URLs only from that response and only for the
  PUT it describes.
- **Errors** come back as `ConnectError` with Apple's `errors[].code`, `title` and `detail` kept verbatim (escaped and
  quoted like screen text: they are untrusted), the HTTP status, and the request's method and path shape. Messages
  say what to do: a 403 names the role the operation needs; a 409 shows Apple's `detail`; a 429 shows the wait.
- **Rate limits.** The client reads `X-Rate-Limit` on every response. A command that would need more requests than
  remain in the hour stops with `UNVERIFIED · rate limited by App Store Connect, N requests left this hour` rather
  than guessing; polling (M5b) backs off to stay under it.

## 5. Storage

- One generic-password item per key in the **login keychain** (the file-based one, not the data-protection
  keychain: Findings 1): service `chauffeur.appstoreconnect`, account `<key-id>`, data the `.p8` PEM, attribute
  `kSecAttrComment` a JSON document `{issuer, role, apps, added, presence}`.
- **User presence** is two guards, since the login keychain ignores `SecAccessControl` (Findings 1). First, before
  the data read, chauffeur asks LocalAuthentication for `deviceOwnerAuthentication` (Touch ID, or the login
  password), with the reason "use App Store Connect key <id>"; the read happens only after it succeeds. Second, the
  keychain's own access list: the item is readable without a dialog only by the binary that stored it. Any other
  process, including `security find-generic-password` and a rebuilt chauffeur, gets the keychain's "wants to use"
  password dialog, so no process on the Mac can read the key silently. `keys add` says that a rebuilt chauffeur will
  ask once ("Always Allow" adds that build to the list).
- `--no-presence` skips the LocalAuthentication step only; the keychain's access list still applies.
- The `.p8` is a P-256 key. The Secure Enclave can't import one (it only generates its own), so wrapping is not
  offered; the keychain item with the presence check is the strongest storage available for an imported key.
- **One prompt per command.** A release command reads the item once, at its start, and keeps the parsed key in memory
  for the run. The key is never written back anywhere, never handed to the daemon, and never put in the trace.
- `keys remove` deletes the item. It doesn't revoke the key: that is an Admin action in App Store Connect, and the
  message says so.
- A `KeyStore` protocol fronts the keychain and a `Presence` protocol fronts LocalAuthentication, so unit tests use
  an in-memory store and a scripted presence; one live test writes and deletes a real item under a test account.
- **The binary that reads the key is hardened (added 2026-10-27).** Step 0's follow-up showed the release
  `chauffeur` is linker-signed ad hoc without the hardened runtime, so a library injected with
  `DYLD_INSERT_LIBRARIES` runs inside it under its keychain identity and skips the presence check; the debug build
  carries `get-task-allow`, so a debugger can attach. Release artifacts are therefore signed with
  `codesign -o runtime` (ad hoc is enough: `scripts/sign.sh`, run by `build-mcpb.sh`, CI's release job and the
  Homebrew formula), and every command that reads or writes a key first checks its own code signature: hardened
  runtime present and no `get-task-allow`. A build that fails the check refuses with
  `this build can't hold an App Store Connect key: it isn't hardened. Build and sign a release: swift build -c
  release && scripts/sign.sh`. Developers run key commands from the signed release build; the live keychain test
  calls `KeychainStore` directly and is unaffected.

## 6. Tokens

- ES256 with CryptoKit (`P256.Signing.PrivateKey(pemRepresentation:)`); header `kid`, `typ: JWT`; claims `iss`,
  `iat`, `exp`, `aud: appstoreconnect-v1`, and `scope` for GET-only tokens.
- **Lifetimes.** A one-off call: two minutes. Polling tokens carry a `scope` of the GET paths they poll and nothing
  else, so a token that leaks into a log can read one build's state and do nothing else. **Writes (M5b) get their
  own two-minute token each, minted in the process that sends them:** `scope` is documented for GET only
  (Findings 4), so a write token is a bearer credential for every write the role allows, and must not outlive the
  request. The twenty-minute `TokenSession` stays in the code for the one case that may need it, the upload's chunk
  PUTs, and M5b verifies first whether those pre-signed URLs need a JWT at all.
- Tokens are minted per command in the CLI process. The daemon never sees a token, a key, or the keychain.

## 7. What the agent and the logs see

- Never: the key, a token, an `Authorization` header, the keychain comment. The trace records a release command's
  requests as method, path shape, status and milliseconds; the `--json` output and MCP results carry Apple's record
  ids and states, never credentials.
- Apple's error strings and app names are untrusted text, escaped as screen text is.
- `chauffeur doctor` adds one line: `connect key: 7X2K9ABC1D (App Manager, presence) · pinned for this project`, or
  `connect key: none (chauffeur keys add)`. `doctor` and `keys list` never prompt: they read the item's attributes
  only, which the keychain hands out without a dialog (Findings 6).

## Testing

**Unit (no network, no keychain):**
- Token: a fixed test key produces a JWT whose signature verifies with CryptoKit, with the right header, claims,
  lifetimes and scope; a session token is re-minted before it expires.
- The request table: no DELETE; no PATCH on the forbidden resources; the `builds` and `reviewSubmissions` encoders
  can't emit `expired` or `canceled`; every `Operation` case has a row; the sheet's "will never" line matches the
  table.
- The probe decision table, on recorded responses from step 0 (fixtures under `Tests/ChauffeurCoreTests/Fixtures/
  Connect/`): each row of §3, including 401 and 429.
- Redaction: a trace entry, a `--json` line and an MCP result built from a run with a token present contain no
  token, key or header.
- The pin: `.chauffeur.json` round-trips `connectKey` and keeps `udid` and `telemetryHosts`.
- `ConnectError` messages: 403 names the role; 409 carries `detail` escaped; 429 carries the wait.

**Live (owner's team, keys created for the test and revoked after):** `keys add` with the owner's App Manager key
succeeds and prints the sheet with `role check: not an Admin or Finance key`; with the Admin key it is refused with
the finance-alarm text; with the revoked key it reports 401. `keys check` from a debug build reports the
unhardened-build error. `scripts/sign.sh` on the release build blocks a `DYLD_INSERT_LIBRARIES` library. The Touch
ID prompt is observed by hand once per macOS version and noted in Findings.

## Done when

- Step 0's findings are in this spec and the design matches them (Decision, 2026-10-27).
- The finance alarm refuses the owner's Admin key and accepts the App Manager key, live, with recorded fixtures.
- The release binary is signed with the hardened runtime and a debug build refuses to hold a key.
- Unit tests pass in CI; the live tests pass locally.
- `docs/design.md` carries the new network line and a note on where keys live.
- `chauffeur doctor` reports the key; the skill gains one sentence: an agent never adds or removes keys.
- No release command exists yet (M5b), so the table has reads only, and the "never" test already guards it.

## Decision (2026-10-27)

After Step 0 and a research pass (notes and report under `.superpowers/research/`, summarised in Findings 2 and 4):

1. The `/v1/users` and `/v1/certificates` probes and the "refuse a key that reaches Certificates, Identifiers &
   Profiles" rule are dropped: they cannot distinguish roles, and every key that can ship reads CIP.
2. The finance alarm (§3) replaces them as the only detection, one-way and best-effort; the declared role and the
   first-write check stay.
3. The request table remains the structural guard and its deny list grows to the writes an App Manager key could
   make that a release tool never needs (§4).
4. The release binary is hardened and key commands refuse to run from a build that isn't (§5).
5. The "confirmation prompt is theatre" line is reversed. M5b's spec gains plan/apply with one Touch ID approval
   per plan whose reason text is rendered from the exact requests, a separate approval for release and
   phased-release completion that `--no-presence` cannot bypass, and per-write two-minute tokens.
6. An opt-in later tier, an individual key for an App Manager user limited to chosen apps (Apple blocks individual
   keys from the certificate and profile endpoints), waits on one test: that such a user can still upload a build.

What stays unverifiable, and the sheet says so: the key's role beyond "finance-capable or not"; whether an App
Manager key can revoke a certificate (a throwaway development certificate test could answer it, with the owner's
approval); whether anyone else uses the key; whether the human read the prompt.

## Staging

| Gap | Closed by | Stage |
|---|---|---|
| a key that could lock the team out | the request table; the finance alarm for Admin keys; the hardened binary | M5a |
| the `.p8` on disk or in the environment | keychain with user presence | M5a |
| a tool that can expire, cancel or delete | no such operation exists | M5a |
| individual keys | `sub: "user"` tokens, same probes | stage 2 |
| CI runners | `--no-presence` now; secret-store readers later | stage 2 |
| rotation | `keys add` the new one, `keys use`, `keys remove` the old | stage 2 helper |

## Findings

Step 0, run 2026-10-26 on macOS 27.0.1 (Darwin 27.0.0), Swift 6.4, from Claude Code's shell (no TTY). The scratch
programs are not in the repo; the plan's live tests repeat the checks that matter.

1. **Keychain from a CLI.** The data-protection keychain (`kSecUseDataProtectionKeychain`) refuses an unsigned
   SwiftPM binary with `-34018 A required entitlement is not present`; an ad-hoc signature carrying
   `keychain-access-groups` gets the process killed at launch (exit 137). So a from-source tool can't use it, and
   `SecAccessControl(.userPresence)` can't be enforced by the keychain. The login keychain works: `SecItemAdd`
   succeeds (an access-control attribute is accepted and silently dropped: the stored attributes are `acct, cdat,
   class, icmt, labl, mdat, svce`), and the same binary reads the data back in 11 ms with no dialog. A different
   binary reading the data, and `security find-generic-password -w`, both block on the keychain's password dialog
   (killed after 15 s with nobody at the keyboard). LocalAuthentication from the same no-TTY process:
   `canEvaluatePolicy(.deviceOwnerAuthentication)` is true, `biometryType` is Touch ID, and `evaluatePolicy` puts up
   the Touch ID sheet (it waited the full 25 s unanswered rather than failing). SSH not tried yet; expected: the
   keychain is locked and LocalAuthentication fails with `LAError.notInteractive`; the plan's message for that case
   says to run `keys add` at the Mac or pass `--no-presence`. SwiftPM's ad-hoc identifier differs between debug
   (`chauffeur-<hash>`) and release (`chauffeur`) builds, so a rebuilt debug chauffeur is "another binary" to the
   keychain and gets the dialog once per build; a release build keeps its identifier.
2. **The probes.** Partly run, 2026-10-27, with the owner's existing keys. An Admin key: `GET /v1/users?limit=1`
   answered 200, `keys add` refused it after that one request and stored nothing (the refusal text in §3, verbatim).
   A second key on the machine answered 401 on the first probe (revoked, or minted under another issuer): refused
   with the §3 401 text, nothing stored. A third key, minted 2026-10-27 for chauffeur, answered 200 on all of
   `/v1/users`, `/v1/certificates`, `/v1/bundleIds` and `/v1/userInvitations`: it was either Admin or App Manager
   with the Certificates, Identifiers & Profiles box checked, and `keys add` refused it after the first request.
   Observed shapes: a 200 on `/v1/users` carries `data[].attributes.roles` (e.g. `["ADMIN",
   "CLOUD_MANAGED_DEVELOPER_ID"]`); `X-Rate-Limit` is `user-hour-lim:3600;user-hour-rem:N` and counts down by one
   per request. **Settled 2026-10-27**, later the same day: that third key had been generated as App Manager, and
   the current Generate API Key dialog has no Certificates, Identifiers & Profiles checkbox at all (Access is a
   role picker: Admin, App Manager, Developer, Finance, Sales and Reports, Customer Support, Marketing). A
   differential run of 17 reads with the Admin key and the App Manager key answered identically on every one:
   200 on `users`, `userInvitations`, `certificates`, `bundleIds`, `profiles`, `devices`, `merchantIds`,
   `passTypeIds`, `ciProducts`, `apps`, `betaGroups`; 403 on `webhooks` and `appEvents` for both; the full
   `users` list (two users, roles `ADMIN` and `ACCOUNT_HOLDER+ADMIN`) is the same for both; `GET /v1/apiKeys`
   is `404 PATH_ERROR` for both. With the owner's approval, `DELETE` on ids that cannot exist
   (`/v1/certificates/DOESNOTEXIST00`, `/v1/bundleIds/…`, `/v1/profiles/…`, `/v1/users/0000…`) answered
   `404 NOT_FOUND` for both keys, so Apple checks existence before authorisation and a safe write can't tell the
   roles apart either. **No read and no safe write distinguishes an Admin key from an App Manager key.** §3's
   probes as written would refuse every App Manager key; the design has to change (see the Decision below
   Findings). Whether an App Manager key can revoke a certificate was not tested (it would need a real id);
   Apple's role chart says only Admin and the Account Holder can.
   The responses become fixtures under `Tests/ChauffeurCoreTests/Fixtures/connect/` when recorded; until then the
   decision table is tested on Apple's documented error shape.
3. **Reading the role back.** No endpoint returns a team key's own role (Apple's API reference lists none; the key
   list endpoints are for individual keys only). The declared role stands, checked at first write (M5b).
4. **Scoped tokens.** Run 2026-10-27. A token with `scope: ["GET /v1/apps?limit=200"]` gets 200 on that path, and
   **403** (not 405) on `GET /v1/users?limit=1`, with `code: FORBIDDEN.REQUEST_DOES_NOT_MATCH_SCOPE` and a `detail`
   that names the request and the authorised scopes. Apple normalises the query when matching: a scope written with
   literal brackets (`filter[bundleId]=…`) and one written encoded (`filter%5BbundleId%5D=…`) both match a request
   sent as `%5B`/`%5D` (200 each). So the client's literal-bracket scope string is fine, and §4's "a scoped token
   sent with a POST gets 405" stays to be confirmed when M5b adds a write.
5. **A key file's permissions.** No `.p8` in `~/Downloads` to observe; Safari's downloads here are `0644`
   (`-rw-r--r--`), so a key it downloaded is readable by every process as this user until deleted. Keys that
   `altool` stored under `~/.appstoreconnect/private_keys` are `0600`. The hint in §2 stands.
6. **Reading attributes without the prompt.** `SecItemCopyMatching` with `kSecReturnAttributes` and no
   `kSecReturnData` returns the comment with no dialog, from the same binary (7 ms) and from a different binary
   (9 ms). `doctor` and `keys list` read attributes only; the index item in §7 is not needed.
