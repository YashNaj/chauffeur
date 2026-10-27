# M5a: the App Store Connect key

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `chauffeur keys add|list|check|remove|use` store an App Store Connect team key in the login keychain behind
Touch ID, refuse any key that could lock the team out, print what the key can and can't do, and give M5b a client
that can only send the requests in a static table (reads only, in M5a).

**Architecture:** A new `Sources/ChauffeurCore/Connect/` folder, all public API. Pure types first: the parsed key
(`ConnectKey`), ES256 tokens (`ConnectToken`), the operation enum and its request table (`Operation`,
`RequestTable`), errors (`ConnectError`), the probe decision (`Probe`) and the capability sheet. Two seams for
tests: `ConnectTransport` (HTTP) and `KeyStore` + `Presence` (keychain, LocalAuthentication). `ConnectKeys` is the
command layer, called from `CLI` like `doctor` is: in the CLI process, never in the daemon, never over MCP.

**Tech Stack:** Swift 6 / SwiftPM, swift-testing, CryptoKit (P-256, ES256), Security (login keychain),
LocalAuthentication (Touch ID), URLSession. No private API; nothing in this plan touches `ChauffeurBridge`.

**Spec:** `docs/specs/2026-10-26-m5a-connect-key-design.md`. Read its Findings first: the storage design in §5 was
rewritten from them on 2026-10-26 (login keychain, not the data-protection keychain; presence through
LocalAuthentication plus the keychain's own access list).

## Global Constraints

- Work in `~/Developer/repos/chauffeur` on branch `m5a-connect-key`, cut from `m4b-network` (it needs M4b's
  `.chauffeur.json` merging). The PR targets `main` after M4b's 0.2.0 merges; rebase then. Never push to `main`.
- Commits: author and committer `YashNaj <68571013+YashNaj@users.noreply.github.com>`; no AI `Co-Authored-By`
  trailer; no session links. `scripts/check-commits.sh origin/main..HEAD` must pass.
- `CLAUDE.md` carries an uncommitted local section ("context-mem Integration") that must not reach the repo. Task 12
  stages only its table row, with `git diff CLAUDE.md`, an edited patch and `git apply --cached`.
- `scripts/check.sh` passes before every push. Run `scripts/format.sh` after editing Swift (swift-format, 4 spaces,
  120 columns).
- Lint (`scripts/check-code.sh`): no `try!` in `Sources`; no `print` in `ChauffeurCore`; files under 400 lines in
  `Sources`, 600 in `Tests`.
- Network: the only host is `api.appstoreconnect.apple.com`, over HTTPS, and only from `keys add` and `keys check`.
  `ConnectRequest` has no initialiser that takes a host.
- Never in any output, trace, `--json` line, error or log: the `.p8`, a token, an `Authorization` header, the
  keychain comment. `ConnectKey` and `ConnectRequest` print as their ids and shapes only.
- Apple's error strings and app names are untrusted text: rendered through `Perception.escape` /
  `Perception.quote`.
- Token lifetimes: a one-off call 120 s, a session 1200 s, re-minted when under 60 s remain. Read tokens carry
  `scope: ["GET <path><query>"]`.
- The keychain item: service `chauffeur.appstoreconnect`, account `<key-id>`, data the PEM, comment the
  `StoredKey` JSON. Live tests use service `chauffeur.appstoreconnect.test`.
- Exit codes: refusals and errors 1; usage 64. No new exit code in M5a.
- `keys` commands are never forwarded to the daemon and never appear in `MCPTools`.
- Owner's to-dos this plan depends on (not the implementer's): keys of each role on the team and the issuer id, for
  Task 7's recordings and Task 13's live run.

## Review Focus

1. **A file that isn't a key** (`--help` text saved as `.p8`, a `.cer`, an empty file): `keys add` says the file
   isn't a PEM private key, stores nothing, sends nothing. Pinned in Task 1 (`rejectsFilesThatAreNotKeys`) and
   Task 9 (`addRefusesABadFileBeforeAnyRequest`).
2. **A key id that is already stored:** refused before any request, naming `keys remove`. Pinned in Task 9
   (`addRefusesADuplicateId`).
3. **The human cancels Touch ID:** `keys check` stops with "not confirmed", reads nothing, exits 1. Pinned in
   Task 8 (`presenceDeniedReadsNothing`).
4. **No network, or App Store Connect down (5xx):** `keys add` stores nothing and says which it was. Pinned in Task 7
   (`aServerErrorIsReportedWithAppleTextEscaped`) and Task 9 (`addStoresNothingWhenTheProbeCannotRun`).
5. **A rate-limited probe:** `keys add` reports the remaining budget and stores nothing, rather than storing a key it
   couldn't check. Pinned in Task 7 (`rateLimitedStopsTheProbe`) and Task 9 (`addStoresNothingWhenRateLimited`).

## File structure

| File | Responsibility |
|---|---|
| `Sources/ChauffeurCore/Connect/ConnectKey.swift` | `ConnectRole`, `StoredKey` (the comment JSON), `ConnectKey` (parsed P-256 key; prints as its id) (Task 1) |
| `Sources/ChauffeurCore/Connect/ConnectToken.swift` | ES256 JWT minting, `TokenLifetime`, `TokenSession` (Task 2) |
| `Sources/ChauffeurCore/Connect/Operation.swift` | `Method`, `Operation`, `Operation.Kind`, path parameters and query (Task 3) |
| `Sources/ChauffeurCore/Connect/RequestTable.swift` | `RequestRow`, the table, `forbiddenPatch`, `denied`, `never()` (Task 3) |
| `Sources/ChauffeurCore/Connect/ConnectError.swift` | `AppleError`, `ConnectError` and its messages (Task 4) |
| `Sources/ChauffeurCore/Connect/ConnectTransport.swift` | `ConnectRequest`, `ConnectResponse`, `RateLimit`, `ConnectTransport`, `URLSessionTransport` (Task 5) |
| `Sources/ChauffeurCore/Connect/ConnectClient.swift` | operation → request → response → `JSON` or `ConnectError`; the request log (Task 6) |
| `Sources/ChauffeurCore/Connect/Probe.swift` | the three probes and the decision table (Task 7) |
| `Sources/ChauffeurCore/Connect/CapabilitySheet.swift` | the four-line sheet (Task 7) |
| `Sources/ChauffeurCore/Connect/KeyStore.swift` | `KeyStore`, `Presence` protocols; `ConnectKeys.load` (Task 8) |
| `Sources/ChauffeurCore/Connect/KeychainStore.swift` | the login keychain and LocalAuthentication (Task 8) |
| `Sources/ChauffeurCore/Connect/ConnectKeys.swift` | `keys add/list/check/remove/use`, resolution, `Environment` (Tasks 9, 10) |
| `Sources/ChauffeurCore/Target.swift` | `connectKey(from:)`, `setConfig` (Task 10) |
| `Sources/ChauffeurCore/CLI.swift`, `Engine/Args.swift` | `keys` dispatch, `Environment.connect`, usage lines (Task 11) |
| `Sources/ChauffeurCore/Doctor.swift` | the `connect key:` line (Task 11) |
| `Sources/ChauffeurCore/Agent/Skill.swift`, `docs/design.md`, `CLAUDE.md`, `README.md` | words (Task 12) |
| `Tests/ChauffeurCoreTests/Connect*Tests.swift`, `Fixtures/connect/` | unit tests and recorded responses |
| `Tests/ChauffeurCoreTests/Live/ConnectLiveTests.swift` | keychain round trip; probe recording (Task 13) |

Test helpers (`Tests/ChauffeurCoreTests/ConnectSupport.swift`, Task 1 creates it, later tasks extend it):
`TestKeys.pem()` (a fresh P-256 PKCS#8 PEM from CryptoKit; never a real Apple key), `ScriptedTransport`
(answers by request shape, records every request), `MemoryKeyStore: KeyStore`, `ScriptedPresence: Presence`,
`Fixtures.connect(_ name:) -> ConnectResponse` (reads `Fixtures/connect/<name>.json`:
`{"status": 403, "headers": {...}, "body": {...}, "source": "documented" | "recorded 2026-10-27"}`).

---

### Task 1: The key, its role and its stored record

Spec §2 (`--role`), §5 (the comment JSON), §7 (never printed).

**Files:**
- Create: `Sources/ChauffeurCore/Connect/ConnectKey.swift`, `Tests/ChauffeurCoreTests/ConnectKeyTests.swift`,
  `Tests/ChauffeurCoreTests/ConnectSupport.swift`

**Interfaces:**
- Produces:
  - `public enum ConnectRole: String, Codable, Sendable, CaseIterable { case developer; case appManager = "app-manager" }`
    with `public var title: String` ("Developer", "App Manager") and `public init?(flag: String)` accepting the
    raw values.
  - `public struct StoredKey: Codable, Equatable, Sendable { keyID, issuer: String; role: ConnectRole; apps: [String]; added: String; presence: Bool }`
    with a public memberwise `init(keyID:issuer:role:apps:added:presence:)`, `public func commentJSON() throws -> String` (sorted keys, one line) and
    `public static func from(comment: String) -> StoredKey?`. `apps` entries are `"Name (bundle.id)"`.
  - `public struct ConnectKey: Sendable, CustomStringConvertible { public let keyID: String; public let issuer: String; let signingKey: P256.Signing.PrivateKey }`
    with `public init(pem: String, keyID: String, issuer: String) throws` (throws `ConnectError.badKeyFile(_:)`,
    defined in Task 4; until then a private placeholder is not acceptable: Task 1 adds `ConnectError.swift` with
    only `badKeyFile(String)` and Task 4 fills the rest) and `description == "key \(keyID)"`.
  - Validation in the initialiser: `keyID` is 10 characters of `[A-Z0-9]`; `issuer` parses as a `UUID`; the PEM
    parses with `P256.Signing.PrivateKey(pemRepresentation:)`. Messages: `"<keyID> is not a key id (10 letters and
    digits, as in AuthKey_<id>.p8)"`, `"<issuer> is not an issuer id (a UUID from Users and Access ▸ Integrations)"`,
    `"the file is not a PEM private key (expected -----BEGIN PRIVATE KEY-----; download AuthKey_<id>.p8 from App
    Store Connect)"`. The PEM text never appears in a message.
  - In `ConnectSupport.swift`: `enum TestKeys { static func pem() -> String; static func key() throws -> ConnectKey }`
    (CryptoKit's `pemRepresentation`; `key()` is `ConnectKey(pem: pem(), keyID: keyID, issuer: issuer)`) and
    `static let issuer = "69a6de70-03db-47e3-a96a-7ee2dc5a4c3b"`, `static let keyID = "7X2K9ABC1D"`.

- [ ] **Step 1: Branch**

```bash
cd ~/Developer/repos/chauffeur && git checkout m5a-connect-key
```

- [ ] **Step 2: Write the failing tests**

```swift
@Suite struct ConnectKeyTests {
    @Test func parsesAPKCS8Key() throws {
        let key = try ConnectKey(pem: TestKeys.pem(), keyID: TestKeys.keyID, issuer: TestKeys.issuer)
        #expect(key.keyID == "7X2K9ABC1D" && "\(key)" == "key 7X2K9ABC1D")
        #expect(!"\(key)".contains("PRIVATE KEY"))
    }
    @Test func rejectsFilesThatAreNotKeys() {
        for bad in ["", "usage: chauffeur <command>", "-----BEGIN CERTIFICATE-----\nAAAA\n-----END CERTIFICATE-----"] {
            #expect(throws: ConnectError.self) { try ConnectKey(pem: bad, keyID: TestKeys.keyID, issuer: TestKeys.issuer) }
        }
        #expect(throws: ConnectError.badKeyFile("abc is not a key id (10 letters and digits, as in AuthKey_<id>.p8)")) {
            try ConnectKey(pem: TestKeys.pem(), keyID: "abc", issuer: TestKeys.issuer)
        }
        #expect(throws: ConnectError.self) { try ConnectKey(pem: TestKeys.pem(), keyID: TestKeys.keyID, issuer: "team") }
    }
    @Test func storedKeyRoundTripsAsComment() throws {
        let k = StoredKey(keyID: "7X2K9ABC1D", issuer: TestKeys.issuer, role: .appManager,
                          apps: ["Fixture (dev.chauffeur.fixture)"], added: "2026-10-26T20:00:00Z", presence: true)
        let json = try k.commentJSON()
        #expect(json.hasPrefix(#"{"added":"2026-10-26T20:00:00Z","apps":["#))
        #expect(StoredKey.from(comment: json) == k && StoredKey.from(comment: "not json") == nil)
    }
    @Test func rolesFromFlags() {
        #expect(ConnectRole(flag: "app-manager") == .appManager && ConnectRole(flag: "developer") == .developer)
        #expect(ConnectRole(flag: "admin") == nil && ConnectRole.appManager.title == "App Manager")
    }
}
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `swift test --filter ConnectKeyTests`
Expected: compile error, `ConnectKey` not found.

- [ ] **Step 4: Implement `ConnectKey.swift` and the `ConnectError.badKeyFile` stub, plus `TestKeys`**

`import CryptoKit`; `ConnectError` for now: `public enum ConnectError: Error, Equatable, CustomStringConvertible { case badKeyFile(String) }`
with `description` returning the text. `StoredKey.commentJSON` uses `JSONEncoder` with `.sortedKeys`.

- [ ] **Step 5: Run the tests to verify they pass**

Run: `swift test --filter ConnectKeyTests`
Expected: 4 passed.

- [ ] **Step 6: Commit**

```bash
scripts/format.sh && git add Sources/ChauffeurCore/Connect Tests/ChauffeurCoreTests/ConnectKeyTests.swift Tests/ChauffeurCoreTests/ConnectSupport.swift
git commit -m "Connect: the parsed key, its role and its stored record"
```

---

### Task 2: ES256 tokens

Spec §6.

**Files:**
- Create: `Sources/ChauffeurCore/Connect/ConnectToken.swift`, `Tests/ChauffeurCoreTests/ConnectTokenTests.swift`

**Interfaces:**
- Consumes: `ConnectKey` (Task 1).
- Produces:
  - `public enum TokenLifetime: Sendable { case call, session; public var seconds: TimeInterval }` (120, 1200).
  - `public enum ConnectToken { public static func mint(_ key: ConnectKey, lifetime: TokenLifetime, scope: [String]?, now: Date) throws -> String; static func base64url(_ data: Data) -> String }`.
    Header `{"alg":"ES256","kid":"<keyID>","typ":"JWT"}`; claims `iss`, `iat` (whole seconds), `exp = iat +
    lifetime.seconds`, `aud: "appstoreconnect-v1"`, `scope` only when given. Signature: `signingKey.signature(for:
    Data(signingInput.utf8)).rawRepresentation` (64 bytes), base64url without padding.
  - `public struct TokenSession { public init(key: ConnectKey, lifetime: TokenLifetime, scope: [String]?); public mutating func token(now: Date) throws -> String; public private(set) var expiry: Date }`:
    returns the same token until fewer than 60 s remain, then mints a new one.

- [ ] **Step 1: Write the failing tests**

```swift
@Suite struct ConnectTokenTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    func parts(_ jwt: String) throws -> (header: JSON, claims: JSON, input: String, signature: Data) { /* split on ".", base64url-decode */ }

    @Test func mintsAVerifiableES256Token() throws {
        let pem = TestKeys.pem()
        let key = try ConnectKey(pem: pem, keyID: TestKeys.keyID, issuer: TestKeys.issuer)
        let jwt = try ConnectToken.mint(key, lifetime: .call, scope: ["GET /v1/apps?limit=200"], now: now)
        let p = try parts(jwt)
        #expect(p.header == ["alg": "ES256", "kid": "7X2K9ABC1D", "typ": "JWT"])
        #expect(p.claims["iss"]?.string == TestKeys.issuer && p.claims["aud"]?.string == "appstoreconnect-v1")
        #expect(p.claims["iat"]?.int == 1_800_000_000 && p.claims["exp"]?.int == 1_800_000_120)
        #expect(p.claims["scope"] == ["GET /v1/apps?limit=200"])
        let publicKey = try P256.Signing.PrivateKey(pemRepresentation: pem).publicKey
        #expect(publicKey.isValidSignature(try P256.Signing.ECDSASignature(rawRepresentation: p.signature), for: Data(p.input.utf8)))
        #expect(!jwt.contains("=") && !jwt.contains("+") && !jwt.contains("/"))
    }
    @Test func sessionTokensLastTwentyMinutesAndNoScope() throws { /* exp - iat == 1200; claims["scope"] == nil */ }
    @Test func sessionRemintsBeforeExpiry() throws {
        var s = TokenSession(key: key, lifetime: .session, scope: nil)
        let first = try s.token(now: now)
        #expect(try s.token(now: now + 1000) == first)
        #expect(try s.token(now: now + 1141) != first)   // 59 s left: re-minted
        #expect(s.expiry == now + 1141 + 1200)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter ConnectTokenTests`
Expected: compile error, `ConnectToken` not found.

- [ ] **Step 3: Implement `ConnectToken.swift`**

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter ConnectTokenTests`
Expected: 3 passed.

- [ ] **Step 5: Commit**

```bash
scripts/format.sh && git add Sources/ChauffeurCore/Connect/ConnectToken.swift Tests/ChauffeurCoreTests/ConnectTokenTests.swift
git commit -m "Connect: ES256 tokens, two minutes for a call, twenty for a session, GET scopes"
```

---

### Task 3: Operations and the request table

Spec §4: every request the client can ever send, and the list of what it will never do.

**Files:**
- Create: `Sources/ChauffeurCore/Connect/Operation.swift`, `Sources/ChauffeurCore/Connect/RequestTable.swift`,
  `Tests/ChauffeurCoreTests/RequestTableTests.swift`

**Interfaces:**
- Produces:
  - `public enum Method: String, Sendable, CaseIterable { case get = "GET", post = "POST", patch = "PATCH", put = "PUT" }`.
    There is no `delete` case: a DELETE can't be expressed.
  - `public enum Operation: Equatable, Sendable` with cases `probeUsers`, `probeCertificates`, `probeApps`,
    `apps(bundleID: String?)`, `builds(appID: String, version: String?, buildNumber: String?)`, `build(id: String)`,
    `buildBetaDetail(buildID: String)`, `betaGroups(appID: String)`, `preReleaseVersions(appID: String)`,
    `appStoreVersions(appID: String)`, `appStoreVersion(id: String)`,
    `appStoreVersionLocalizations(versionID: String)`, `reviewSubmissions(appID: String)`,
    `reviewSubmission(id: String)`, `buildUpload(id: String)`, `buildUploadFiles(uploadID: String)`.
  - `public enum Operation.Kind: String, CaseIterable, Sendable` with one case per `Operation` case, same names;
    `public var kind: Kind`; `public var pathParameters: [String: String]` (`["id": …]`);
    `public var query: [(name: String, value: String)]` sorted by name.
  - `public struct RequestRow: Sendable { public let method: Method; public let path: String; public let resource: String; public let role: ConnectRole; public let fields: [String] }`
    with a public memberwise `init(method:path:resource:role:fields:)`. `path` is a template (`/v1/builds/{id}`); `resource` is the first path segment after `/v1/` (`builds`);
    `fields` are the body attributes the encoder may emit, `[]` for GET.
  - `public enum RequestTable { public static let rows: [Operation.Kind: RequestRow]; public static let forbiddenPatch: Set<String>; public struct Denied: Sendable { public let text: String; public let violates: @Sendable (RequestRow) -> Bool }; public static let denied: [Denied]; public static func never() -> [String]; public static func path(for op: Operation) -> String; public static func pathAndQuery(for op: Operation) -> String }`.
  - The rows (all GET, all `role: .developer`, `fields: []`):

    | Kind | path | query |
    |---|---|---|
    | probeUsers | `/v1/users` | `limit=1` |
    | probeCertificates | `/v1/certificates` | `limit=1` |
    | probeApps | `/v1/apps` | `limit=200` |
    | apps | `/v1/apps` | `limit=200`, `filter[bundleId]=` when given |
    | builds | `/v1/builds` | `filter[app]=`, `filter[preReleaseVersion.version]=`, `filter[version]=` when given, `limit=200`, `sort=-uploadedDate` |
    | build | `/v1/builds/{id}` | |
    | buildBetaDetail | `/v1/builds/{id}/buildBetaDetail` | |
    | betaGroups | `/v1/betaGroups` | `filter[app]=`, `limit=200` |
    | preReleaseVersions | `/v1/preReleaseVersions` | `filter[app]=`, `limit=200` |
    | appStoreVersions | `/v1/apps/{id}/appStoreVersions` | `limit=200` |
    | appStoreVersion | `/v1/appStoreVersions/{id}` | |
    | appStoreVersionLocalizations | `/v1/appStoreVersions/{id}/appStoreVersionLocalizations` | `limit=200` |
    | reviewSubmissions | `/v1/reviewSubmissions` | `filter[app]=`, `limit=200` |
    | reviewSubmission | `/v1/reviewSubmissions/{id}` | |
    | buildUpload | `/v1/buildUploads/{id}` | |
    | buildUploadFiles | `/v1/buildUploads/{id}/buildUploadFiles` | `limit=200` |

  - `forbiddenPatch = ["users", "certificates", "bundleIds", "profiles", "webhooks", "betaTesters"]`.
  - `denied` (texts are the sheet's "will never" line, in this order): `"expire a build"` (violated by a `builds`
    row that is not GET and whose `fields` contain `expired`), `"cancel a submission"` (`reviewSubmissions`, not
    GET, `fields` contain `canceled`), `"remove a tester"` (`betaTesters` or `betaTesterUsages` not GET, or any
    row whose path contains `/relationships/betaTesters`), `"delete a webhook"` (`webhooks` not GET),
    `"change pricing"` (resource starting with `appPrice` or `appPricePoints`, not GET).
  - `never()` returns the texts of every `denied` entry that no row violates. `pathAndQuery` percent-encodes
    values (`[` and `]` stay literal, as Apple expects).

- [ ] **Step 1: Write the failing tests**

```swift
@Suite struct RequestTableTests {
    @Test func everyOperationHasARow() {
        for kind in Operation.Kind.allCases { #expect(RequestTable.rows[kind] != nil, "\(kind)") }
        #expect(RequestTable.rows.count == Operation.Kind.allCases.count)
    }
    @Test func thereIsNoDelete() {
        #expect(!Method.allCases.map(\.rawValue).contains("DELETE"))
    }
    @Test func noPatchOnTheForbiddenResources() {
        for (kind, row) in RequestTable.rows where row.method == .patch {
            #expect(!RequestTable.forbiddenPatch.contains(row.resource), "\(kind)")
        }
    }
    @Test func buildsAndSubmissionsCannotExpireOrCancel() {
        for row in RequestTable.rows.values where row.resource == "builds" { #expect(!row.fields.contains("expired")) }
        for row in RequestTable.rows.values where row.resource == "reviewSubmissions" { #expect(!row.fields.contains("canceled")) }
    }
    @Test func m5aIsReadsOnly() {
        for (kind, row) in RequestTable.rows { #expect(row.method == .get && row.fields.isEmpty, "\(kind)") }
    }
    @Test func theNeverLineIsTheWholeDenyList() {
        #expect(RequestTable.never() == ["expire a build", "cancel a submission", "remove a tester", "delete a webhook", "change pricing"])
        let expiring = RequestRow(method: .patch, path: "/v1/builds/{id}", resource: "builds", role: .appManager, fields: ["expired"])
        #expect(RequestTable.denied[0].violates(expiring))
    }
    @Test func pathsAndQueries() {
        #expect(RequestTable.pathAndQuery(for: .probeUsers) == "/v1/users?limit=1")
        #expect(RequestTable.pathAndQuery(for: .build(id: "b1")) == "/v1/builds/b1")
        #expect(RequestTable.pathAndQuery(for: .apps(bundleID: "dev.chauffeur.fixture")) == "/v1/apps?filter[bundleId]=dev.chauffeur.fixture&limit=200")
        #expect(RequestTable.pathAndQuery(for: .builds(appID: "a1", version: "1.3.0", buildNumber: nil))
            == "/v1/builds?filter[app]=a1&filter[preReleaseVersion.version]=1.3.0&limit=200&sort=-uploadedDate")
        #expect(RequestTable.path(for: .buildUploadFiles(uploadID: "u/1")) == "/v1/buildUploads/u%2F1/buildUploadFiles")
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter RequestTableTests`
Expected: compile error, `Operation` not found.

- [ ] **Step 3: Implement `Operation.swift` and `RequestTable.swift`**

Path parameters are percent-encoded with `CharacterSet.urlPathAllowed` minus `/`; query values with
`urlQueryAllowed` minus `&=+`.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter RequestTableTests`
Expected: 7 passed.

- [ ] **Step 5: Commit**

```bash
scripts/format.sh && git add Sources/ChauffeurCore/Connect/Operation.swift Sources/ChauffeurCore/Connect/RequestTable.swift Tests/ChauffeurCoreTests/RequestTableTests.swift
git commit -m "Connect: the request table, reads only, with no DELETE and a tested deny list"
```

---

### Task 4: Errors that say what to do

Spec §3 (401, 429 texts), §4 (errors).

**Files:**
- Modify: `Sources/ChauffeurCore/Connect/ConnectError.swift` (from Task 1's stub)
- Create: `Tests/ChauffeurCoreTests/ConnectErrorTests.swift`

**Interfaces:**
- Produces:
  - `public struct AppleError: Equatable, Sendable { public var status: String; public var code: String; public var title: String; public var detail: String? }`
    with `public static func parse(_ body: Data) -> [AppleError]` (Apple's `{"errors":[…]}`; `[]` when absent).
  - `public enum ConnectError: Error, Equatable, CustomStringConvertible`:
    `badKeyFile(String)`, `unauthorized`, `forbidden(shape: String, needs: ConnectRole, have: ConnectRole)`,
    `rateLimited(remaining: Int)`, `conflict(shape: String, errors: [AppleError])`,
    `apple(status: Int, shape: String, errors: [AppleError])`, `transport(String)`, `unexpectedBody(shape: String)`,
    `noKey(known: [String])`, `unknownKey(String, known: [String])`, `duplicateKey(String)`,
    `presenceDenied(String)`, `keychain(OSStatus, String)`.
  - Messages (exact):
    - `unauthorized`: `App Store Connect rejected the key: check --issuer and --key-id, and that the key is not revoked`
    - `forbidden`: `App Store Connect refused <shape> (403): it needs the <needs.title> role and this key is <have.title>`
    - `rateLimited`: `rate limited by App Store Connect: <n> requests left this hour; try again later` (author's
      call: `X-Rate-Limit` carries no reset time, so no minute count; spec §3's "in N min" becomes this)
    - `conflict`: `App Store Connect refused <shape> (409): <detail or title, escaped>` (one line per error)
    - `apple`: `App Store Connect answered <status> to <shape>: <code> <title, escaped>` (+ `: detail` when present)
    - `transport`: `could not reach App Store Connect: <text>`
    - `unexpectedBody`: `App Store Connect answered <shape> with a body chauffeur can't read`
    - `noKey`: `no App Store Connect key: chauffeur keys add <AuthKey.p8> --issuer <uuid> --key-id <id> --role app-manager`
      (when `known` is non-empty: `several keys stored (<ids>): pin one with chauffeur keys use <id>`)
    - `unknownKey`: `no stored key <id>; stored: <ids>` (or `none`)
    - `duplicateKey`: `key <id> is already stored; run chauffeur keys remove <id> first`
    - `presenceDenied`: `not confirmed: <reason>. Nothing was read`
    - `keychain`: `keychain: <message> (<status>) while <what>`
    Apple text goes through `Perception.escape(_, limit: 200)`.

- [ ] **Step 1: Write the failing tests**

```swift
@Suite struct ConnectErrorTests {
    @Test func parsesAppleErrors() {
        let body = Data(#"{"errors":[{"id":"x","status":"403","code":"FORBIDDEN_ERROR","title":"This request is forbidden for security reasons","detail":"The API key in use does not allow this request"}]}"#.utf8)
        #expect(AppleError.parse(body) == [AppleError(status: "403", code: "FORBIDDEN_ERROR", title: "This request is forbidden for security reasons", detail: "The API key in use does not allow this request")])
        #expect(AppleError.parse(Data("<html>".utf8)) == [])
    }
    @Test func messagesSayWhatToDo() {
        #expect(ConnectError.forbidden(shape: "POST /v1/reviewSubmissions", needs: .appManager, have: .developer).description
            == "App Store Connect refused POST /v1/reviewSubmissions (403): it needs the App Manager role and this key is Developer")
        #expect(ConnectError.rateLimited(remaining: 0).description == "rate limited by App Store Connect: 0 requests left this hour; try again later")
        let e = AppleError(status: "409", code: "STATE_ERROR", title: "t", detail: "Build \"7\" is\nalready attached")
        #expect(ConnectError.conflict(shape: "PATCH /v1/x", errors: [e]).description == #"App Store Connect refused PATCH /v1/x (409): Build \"7\" is\nalready attached"#)
        #expect(ConnectError.noKey(known: []).description.hasPrefix("no App Store Connect key: chauffeur keys add"))
        #expect(ConnectError.noKey(known: ["A", "B"]).description == "several keys stored (A, B): pin one with chauffeur keys use <id>")
        #expect(ConnectError.duplicateKey("A").description == "key A is already stored; run chauffeur keys remove A first")
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter ConnectErrorTests`
Expected: compile error, `AppleError` not found.

- [ ] **Step 3: Implement `ConnectError.swift`**

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter ConnectErrorTests`
Expected: 2 passed.

- [ ] **Step 5: Commit**

```bash
scripts/format.sh && git add Sources/ChauffeurCore/Connect/ConnectError.swift Tests/ChauffeurCoreTests/ConnectErrorTests.swift
git commit -m "Connect: errors that name the role, the detail or the wait"
```

---

### Task 5: Requests, responses, the rate limit header and the transport

Spec §4 (hosts, rate limits), §7 (what the logs see).

**Files:**
- Create: `Sources/ChauffeurCore/Connect/ConnectTransport.swift`, `Tests/ChauffeurCoreTests/ConnectTransportTests.swift`
- Modify: `Tests/ChauffeurCoreTests/ConnectSupport.swift` (`ScriptedTransport`, `Fixtures.connect`)

**Interfaces:**
- Produces:
  - `public struct ConnectRequest: Sendable, CustomStringConvertible { public let method: Method; public let url: URL; public let shape: String; public let body: Data?; let token: String; public var description: String }`.
    The only initialiser is `init(method:, pathAndQuery:, shape:, token:, body:)` (internal), which builds
    `url` from `https://api.appstoreconnect.apple.com` + `pathAndQuery`. `description` is `"<method> <shape>"`.
    `public var headers: [String: String]` returns `Authorization`, `Accept: application/json` and, with a body,
    `Content-Type: application/json`; it is what the transport sends and is never logged.
  - `public struct ConnectResponse: Equatable, Sendable { public var status: Int; public var headers: [String: String]; public var body: Data; public init(status:headers:body:); public func header(_ name: String) -> String? }` (case-insensitive).
  - `public struct RateLimit: Equatable, Sendable { public var limit: Int; public var remaining: Int; public static func parse(_ header: String?) -> RateLimit? }`
    for `user-hour-lim:3600;user-hour-rem:3599` (order-independent, spaces tolerated; nil when either is missing).
  - `public protocol ConnectTransport: Sendable { func perform(_ request: ConnectRequest) throws -> ConnectResponse }`.
  - `public struct URLSessionTransport: ConnectTransport { public init(timeout: TimeInterval = 30) }`: synchronous
    with a semaphore (the CLI process, like `Shell.run`); a `URLError` becomes
    `ConnectError.transport(error.localizedDescription)`; a non-HTTP response becomes
    `ConnectError.transport("no HTTP response")`.
  - In `ConnectSupport.swift`: `final class ScriptedTransport: ConnectTransport, @unchecked Sendable` with
    `init(_ answers: [String: ConnectResponse])` keyed by shape (`"GET /v1/users"`), `var requests: [ConnectRequest]`,
    throwing `ConnectError.transport("unscripted \(shape)")` for an unknown shape; and
    `static func response(_ status: Int, _ json: String, rateLimit: String? = nil) -> ConnectResponse`; and
    `Fixtures.connect(_ name: String) throws -> ConnectResponse`, reading `Fixtures/connect/<name>.json`
    (`status`, `headers`, `body` re-encoded as `Data`; `source` ignored). The folder holds no files until Task 7.

- [ ] **Step 1: Write the failing tests**

```swift
@Suite struct ConnectTransportTests {
    @Test func requestsOnlyGoToAppStoreConnect() {
        let r = ConnectRequest(method: .get, pathAndQuery: "/v1/apps?limit=200", shape: "GET /v1/apps", token: "tok", body: nil)
        #expect(r.url.absoluteString == "https://api.appstoreconnect.apple.com/v1/apps?limit=200")
        #expect(r.headers["Authorization"] == "Bearer tok" && r.headers["Accept"] == "application/json")
    }
    @Test func aRequestPrintsAsItsShapeOnly() {
        let r = ConnectRequest(method: .get, pathAndQuery: "/v1/builds/b1", shape: "GET /v1/builds/{id}", token: "tok-secret", body: nil)
        #expect("\(r)" == "GET /v1/builds/{id}")
        #expect(!String(reflecting: r).contains("tok-secret"))   // reflection is overridden too
    }
    @Test func parsesTheRateLimitHeader() {
        #expect(RateLimit.parse("user-hour-lim:3600;user-hour-rem:3599") == RateLimit(limit: 3600, remaining: 3599))
        #expect(RateLimit.parse(" user-hour-rem:5 ; user-hour-lim:100") == RateLimit(limit: 100, remaining: 5))
        #expect(RateLimit.parse("user-hour-lim:3600") == nil && RateLimit.parse(nil) == nil)
    }
    @Test func headersAreCaseInsensitive() {
        let r = ConnectResponse(status: 200, headers: ["x-rate-limit": "user-hour-lim:1;user-hour-rem:0"], body: Data())
        #expect(r.header("X-Rate-Limit") == "user-hour-lim:1;user-hour-rem:0")
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter ConnectTransportTests`
Expected: compile error, `ConnectRequest` not found.

- [ ] **Step 3: Implement `ConnectTransport.swift` and the test helpers**

`ConnectRequest` conforms to `CustomDebugStringConvertible` and `CustomReflectable` (empty mirror) so no
interpolation path reaches `token`.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter ConnectTransportTests`
Expected: 4 passed.

- [ ] **Step 5: Commit**

```bash
scripts/format.sh && git add Sources/ChauffeurCore/Connect/ConnectTransport.swift Tests/ChauffeurCoreTests/ConnectTransportTests.swift Tests/ChauffeurCoreTests/ConnectSupport.swift
git commit -m "Connect: requests to one host, responses, the rate limit header, a transport seam"
```

---

### Task 6: The client

Spec §4: named operations, scoped two-minute tokens per read, errors, rate limits, the request log.

**Files:**
- Create: `Sources/ChauffeurCore/Connect/ConnectClient.swift`, `Tests/ChauffeurCoreTests/ConnectClientTests.swift`

**Interfaces:**
- Consumes: `ConnectKey`, `ConnectToken.mint`, `Operation`, `RequestTable`, `ConnectRequest`, `ConnectTransport`,
  `RateLimit`, `AppleError`, `ConnectError`, `JSON.parse`.
- Produces: `public final class ConnectClient` (not Sendable; one per command):
  - `public init(key: ConnectKey, role: ConnectRole, transport: ConnectTransport, now: @escaping () -> Date = Date.init)`
  - `public func request(for op: Operation, now: Date) throws -> ConnectRequest`: method and path from the row;
    token `ConnectToken.mint(key, lifetime: .call, scope: ["\(row.method.rawValue) \(pathAndQuery)"], now:)` for
    GET rows (M5b adds session tokens for writes).
  - `public func perform(_ op: Operation) throws -> ConnectResponse`: builds the request, sends it, records
    `"\(method) \(shape) \(status) \(ms)ms"` in `log`, updates `rateLimit` from `X-Rate-Limit`. Throws only
    `ConnectError.transport`.
  - `public func error(for response: ConnectResponse, op: Operation) -> ConnectError?`: nil for 2xx; 401 →
    `unauthorized`; 403 → `forbidden(shape:, needs: row.role, have: role)`; 409 → `conflict`; 429 →
    `rateLimited(remaining: rateLimit?.remaining ?? 0)`; other → `apple(status:, shape:, errors:)`.
  - `public func send(_ op: Operation) throws -> JSON`: `perform`, throw `error(for:op:)` if any, else
    `JSON.parse(body)` (a parse failure is `unexpectedBody`).
  - `public private(set) var rateLimit: RateLimit?`, `public private(set) var log: [String]`,
    `public func ensure(requests n: Int) throws`: throws `rateLimited(remaining:)` when `rateLimit` is known and
    `remaining < n`.

- [ ] **Step 1: Write the failing tests**

```swift
@Suite struct ConnectClientTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    func client(_ answers: [String: ConnectResponse]) throws -> (ConnectClient, ScriptedTransport) { … role: .appManager … }

    @Test func eachReadGetsItsOwnScopedTwoMinuteToken() throws {
        let (c, t) = try client(["GET /v1/apps": ScriptedTransport.response(200, #"{"data":[]}"#)])
        _ = try c.send(.apps(bundleID: nil))
        let claims = /* decode t.requests[0].headers["Authorization"] payload */
        #expect(claims["scope"] == ["GET /v1/apps?limit=200"] && claims["exp"]?.int == 1_800_000_120)
        #expect(t.requests[0].url.host == "api.appstoreconnect.apple.com")
    }
    @Test func statusesBecomeErrors() throws {
        let forbidden = ScriptedTransport.response(403, #"{"errors":[{"status":"403","code":"FORBIDDEN_ERROR","title":"forbidden"}]}"#)
        let (c, _) = try client(["GET /v1/users": forbidden, "GET /v1/builds/{id}": ScriptedTransport.response(401, "{}"),
                                 "GET /v1/apps": ScriptedTransport.response(429, "{}", rateLimit: "user-hour-lim:3600;user-hour-rem:0"),
                                 "GET /v1/betaGroups": ScriptedTransport.response(500, #"{"errors":[{"status":"500","code":"UNEXPECTED_ERROR","title":"An unexpected \"error\""}]}"#)])
        #expect(throws: ConnectError.forbidden(shape: "GET /v1/users", needs: .developer, have: .appManager)) { try c.send(.probeUsers) }
        #expect(throws: ConnectError.unauthorized) { try c.send(.build(id: "b")) }
        #expect(throws: ConnectError.rateLimited(remaining: 0)) { try c.send(.probeApps) }
        #expect(throws: ConnectError.apple(status: 500, shape: "GET /v1/betaGroups", errors: [AppleError(status: "500", code: "UNEXPECTED_ERROR", title: "An unexpected \"error\"", detail: nil)])) { try c.send(.betaGroups(appID: "a")) }
    }
    @Test func rateLimitIsReadOnEveryResponseAndEnsureStops() throws {
        let (c, _) = try client(["GET /v1/apps": ScriptedTransport.response(200, #"{"data":[]}"#, rateLimit: "user-hour-lim:3600;user-hour-rem:2")])
        _ = try c.send(.probeApps)
        #expect(c.rateLimit == RateLimit(limit: 3600, remaining: 2))
        #expect(throws: ConnectError.rateLimited(remaining: 2)) { try c.ensure(requests: 3) }
        try c.ensure(requests: 2)
    }
    @Test func theLogHasShapesAndNoSecrets() throws {
        let (c, _) = try client(["GET /v1/builds/{id}": ScriptedTransport.response(200, #"{"data":{}}"#)])
        _ = try c.send(.build(id: "b1"))
        #expect(c.log.count == 1 && c.log[0].hasPrefix("GET /v1/builds/{id} 200 "))
        #expect(!c.log[0].contains("b1") && !c.log[0].contains("Bearer"))
    }
    @Test func transportErrorsPassThrough() throws {
        let (c, _) = try client([:])
        #expect(throws: ConnectError.transport("unscripted GET /v1/users")) { try c.send(.probeUsers) }
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter ConnectClientTests`
Expected: compile error, `ConnectClient` not found.

- [ ] **Step 3: Implement `ConnectClient.swift`**

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter ConnectClientTests`
Expected: 5 passed.

- [ ] **Step 5: Commit**

```bash
scripts/format.sh && git add Sources/ChauffeurCore/Connect/ConnectClient.swift Tests/ChauffeurCoreTests/ConnectClientTests.swift
git commit -m "Connect: the client sends table operations only, one scoped token per read"
```

---

### Task 7: The probes and the capability sheet

Spec §3. The fixtures are Apple's documented shapes until the owner records real ones (Task 13); each file's
`source` field says which.

**Files:**
- Create: `Sources/ChauffeurCore/Connect/Probe.swift`, `Sources/ChauffeurCore/Connect/CapabilitySheet.swift`,
  `Tests/ChauffeurCoreTests/ProbeTests.swift`, `Tests/ChauffeurCoreTests/Fixtures/connect/users-200.json`,
  `users-403.json`, `certificates-200.json`, `certificates-403.json`, `apps-200.json`, `unauthorized-401.json`,
  `rate-limited-429.json`, `server-500.json`

**Interfaces:**
- Consumes: `ConnectClient.perform/send/ensure`, `RequestTable.never()`, `ConnectRole`, `Perception.escape`.
- Produces:
  - `public enum ProbeVerdict: Equatable, Sendable { case refusedAdmin, refusedCertificates, accepted(apps: [String]), unauthorized, rateLimited(remaining: Int) }`.
  - `public enum Probe`:
    - `public static func decide(users: Int, certificates: Int?, apps: [String]?) -> ProbeVerdict?`: pure, spec §3's
      table top to bottom: `users` 401 → `unauthorized`; 429 → `rateLimited`; 200 → `refusedAdmin`; 403 and
      `certificates` 200 → `refusedCertificates`; 403 and 403 and `apps` given → `accepted(apps:)`; any other
      status → nil (the caller throws the `ConnectError` for it).
    - `public static func run(_ client: ConnectClient) throws -> ProbeVerdict`: `perform(.probeUsers)`; if its
      status is 403, `ensure(requests: 2)` then `perform(.probeCertificates)`; if 403, `send(.probeApps)` and
      `apps(from:)`; a status `decide` returns nil for throws `client.error(for: response, op:)` (Task 6), so
      nothing is sent twice.
    - `public static func apps(from json: JSON) -> [String]`: `data[].attributes.name (bundleId)`, name escaped
      through `Perception.escape(_, limit: 40)`, sorted by name; `limit` 200 means a team with more apps shows
      the first 200 and the sheet says `and more`: author's call, no paging in M5a.
    - `public static func message(_ v: ProbeVerdict) -> String`: the exact spec texts:
      - `refusedAdmin`: `refused: Admin key. This key can remove every other Admin and change roles. chauffeur never holds one. In App Store Connect, create a key with the App Manager role and no access to Certificates, Identifiers & Profiles.`
      - `refusedCertificates`: `refused: this key reaches Certificates, Identifiers & Profiles. It can revoke the team's distribution certificate, which breaks every profile and unsubmitted build. Create one without that access.`
      - `unauthorized`: `ConnectError.unauthorized.description`; `rateLimited`: `ConnectError.rateLimited(remaining:).description`.
  - `public enum CapabilitySheet { public static func render(keyID: String, role: ConnectRole, issuer: String, apps: [String]) -> String }`, four lines:
    ```
    key 7X2K9ABC1D · App Manager · issuer 69a6de70… · apps: Fixture (dev.chauffeur.fixture), Notes (dev.x.notes)
    can:    upload builds · manage TestFlight groups and testers · edit version metadata · submit for review · release
    cannot: touch certificates, identifiers or profiles · add or remove people · change roles · delete apps · create keys
    chauffeur will never: expire a build · cancel a submission · remove a tester · delete a webhook · change pricing
    ```
    `issuer` is its first 8 characters plus `…`. Developer: `can:    upload builds · read builds, TestFlight and
    version state` and `cannot: submit for review · edit version metadata · manage testers · touch certificates,
    identifiers or profiles · add or remove people · change roles · delete apps · create keys`. No apps: `apps: none
    visible`. The last line joins `RequestTable.never()` with ` · `.
  - Fixture files: `users-403.json` and `certificates-403.json` carry Apple's documented `FORBIDDEN_ERROR` body;
    `users-200.json` and `certificates-200.json` a `{"data":[{…}],"links":{}}` with one record; `apps-200.json` two
    apps, `Fixture`/`dev.chauffeur.fixture` and `Notes "quoted"`/`dev.x.notes` (the quote tests escaping);
    `unauthorized-401.json` `NOT_AUTHORIZED`; `rate-limited-429.json` with header
    `X-Rate-Limit: user-hour-lim:3600;user-hour-rem:0` and code `RATE_LIMIT_EXCEEDED`; `server-500.json`
    `UNEXPECTED_ERROR`. All with `"source": "documented"`. Each has `status`, `headers`, `body` (a JSON value).

- [ ] **Step 1: Write the failing tests**

```swift
@Suite struct ProbeTests {
    func client(users: String, certificates: String? = nil, apps: String? = nil) throws -> ConnectClient {
        var answers = ["GET /v1/users": try Fixtures.connect(users)]
        if let certificates { answers["GET /v1/certificates"] = try Fixtures.connect(certificates) }
        if let apps { answers["GET /v1/apps"] = try Fixtures.connect(apps) }
        return ConnectClient(key: try TestKeys.key(), role: .appManager, transport: ScriptedTransport(answers))
    }
    @Test func decisionTable() {
        #expect(Probe.decide(users: 200, certificates: nil, apps: nil) == .refusedAdmin)
        #expect(Probe.decide(users: 403, certificates: 200, apps: nil) == .refusedCertificates)
        #expect(Probe.decide(users: 403, certificates: 403, apps: ["A (a)"]) == .accepted(apps: ["A (a)"]))
        #expect(Probe.decide(users: 401, certificates: nil, apps: nil) == .unauthorized)
        #expect(Probe.decide(users: 429, certificates: nil, apps: nil) == .rateLimited(remaining: 0))
        #expect(Probe.decide(users: 500, certificates: nil, apps: nil) == nil)
    }
    @Test func anAdminKeyIsRefusedAfterOneRequest() throws {
        let c = try client(users: "users-200")
        #expect(try Probe.run(c) == .refusedAdmin && c.log.count == 1)
    }
    @Test func aCertificatesKeyIsRefused() throws {
        #expect(try Probe.run(try client(users: "users-403", certificates: "certificates-200")) == .refusedCertificates)
    }
    @Test func anAppManagerWithoutTheToggleIsAcceptedWithItsApps() throws {
        let c = try client(users: "users-403", certificates: "certificates-403", apps: "apps-200")
        #expect(try Probe.run(c) == .accepted(apps: ["Fixture (dev.chauffeur.fixture)", #"Notes \"quoted\" (dev.x.notes)"#]))
        #expect(c.log.map { $0.split(separator: " ").prefix(3).joined(separator: " ") } == ["GET /v1/users 403", "GET /v1/certificates 403", "GET /v1/apps 200"])
    }
    @Test func unauthorizedAndRateLimitedStopTheProbe() throws {
        #expect(try Probe.run(try client(users: "unauthorized-401")) == .unauthorized)
        #expect(try Probe.run(try client(users: "rate-limited-429")) == .rateLimited(remaining: 0))
    }
    @Test func rateLimitedStopsTheProbe() throws {
        // users answered 403 with one request left: the probe needs two more, so it stops before sending them.
        var users = try Fixtures.connect("users-403"); users.headers["X-Rate-Limit"] = "user-hour-lim:3600;user-hour-rem:1"
        let c = ConnectClient(key: try TestKeys.key(), role: .appManager, transport: ScriptedTransport(["GET /v1/users": users]))
        #expect(throws: ConnectError.rateLimited(remaining: 1)) { try Probe.run(c) }
    }
    @Test func aServerErrorIsReportedWithAppleTextEscaped() throws {
        let c = try client(users: "server-500")
        #expect(throws: ConnectError.self) { try Probe.run(c) }
        do { _ = try Probe.run(c) } catch { #expect("\(error)".hasPrefix("App Store Connect answered 500 to GET /v1/users: UNEXPECTED_ERROR")) }
    }
    @Test func theSheet() {
        let sheet = CapabilitySheet.render(keyID: "7X2K9ABC1D", role: .appManager, issuer: TestKeys.issuer, apps: ["Fixture (dev.chauffeur.fixture)"])
        #expect(sheet == """
            key 7X2K9ABC1D · App Manager · issuer 69a6de70… · apps: Fixture (dev.chauffeur.fixture)
            can:    upload builds · manage TestFlight groups and testers · edit version metadata · submit for review · release
            cannot: touch certificates, identifiers or profiles · add or remove people · change roles · delete apps · create keys
            chauffeur will never: expire a build · cancel a submission · remove a tester · delete a webhook · change pricing
            """)
        #expect(CapabilitySheet.render(keyID: "K", role: .developer, issuer: TestKeys.issuer, apps: []).contains("apps: none visible\ncan:    upload builds · read builds, TestFlight and version state\n"))
        #expect(Probe.message(.refusedAdmin).hasPrefix("refused: Admin key."))
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter ProbeTests`
Expected: compile error, `Probe` not found.

- [ ] **Step 3: Write the fixtures, `Probe.swift` and `CapabilitySheet.swift`**

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter "ProbeTests|ConnectClientTests"`
Expected: all passed.

- [ ] **Step 5: Commit**

```bash
scripts/format.sh && git add Sources/ChauffeurCore/Connect Tests/ChauffeurCoreTests/ProbeTests.swift Tests/ChauffeurCoreTests/Fixtures/connect
git commit -m "Connect: the probes refuse Admin and certificate-reaching keys; the capability sheet"
```

---

### Task 8: The key store, presence, and loading a key

Spec §5 and Findings 1 and 6.

**Files:**
- Create: `Sources/ChauffeurCore/Connect/KeyStore.swift`, `Sources/ChauffeurCore/Connect/KeychainStore.swift`,
  `Tests/ChauffeurCoreTests/KeyStoreTests.swift`
- Modify: `Tests/ChauffeurCoreTests/ConnectSupport.swift` (`MemoryKeyStore`, `ScriptedPresence`)

**Interfaces:**
- Produces:
  - `public protocol KeyStore: Sendable { func add(_ key: StoredKey, pem: String) throws; func list() throws -> [StoredKey]; func pem(for keyID: String) throws -> String; func remove(_ keyID: String) throws }`.
    `add` throws `ConnectError.duplicateKey` when the id exists; `pem`/`remove` throw `unknownKey`; `list` is sorted
    by `keyID` and must not read item data.
  - `public protocol Presence: Sendable { func confirm(reason: String) throws }` throwing `presenceDenied(_:)`.
  - `public enum KeyLoader { public static func load(keyID: String, store: KeyStore, presence: Presence) throws -> (key: ConnectKey, stored: StoredKey) }`:
    `list` → find (else `unknownKey`) → if `stored.presence`, `presence.confirm(reason: "use App Store Connect key
    <id>")` → `pem(for:)` → `ConnectKey`.
  - `public struct KeychainStore: KeyStore { public static let service = "chauffeur.appstoreconnect"; public init(service: String = KeychainStore.service) }`:
    `SecItemAdd` generic password with `kSecAttrService`, `kSecAttrAccount`, `kSecAttrComment`, `kSecAttrLabel`
    `"App Store Connect key <id> (chauffeur)"`, `kSecValueData`; no `kSecUseDataProtectionKeychain`, no access
    control (Findings 1). `list` uses `kSecReturnAttributes` + `kSecMatchLimitAll` and never `kSecReturnData`;
    `errSecItemNotFound` is an empty list. `pem` uses `kSecReturnData` with `kSecMatchLimitOne`. Any other
    `OSStatus` becomes `ConnectError.keychain(status, "<adding|listing|reading|removing> key <id>")` with
    `SecCopyErrorMessageString`.
  - `public struct LocalPresence: Presence`: `LAContext().evaluatePolicy(.deviceOwnerAuthentication,
    localizedReason:)` waited on with a semaphore (60 s); `LAError.userCancel` → `presenceDenied("cancelled")`;
    `notInteractive`/`passcodeNotSet`/timeout → `presenceDenied("<localizedDescription>; run this at the Mac, or
    store the key with --no-presence")`.
  - In `ConnectSupport.swift`: `final class MemoryKeyStore: KeyStore, @unchecked Sendable` (dictionary;
    `var dataReads: Int`, counted in `pem`) and `final class ScriptedPresence: Presence, @unchecked Sendable`
    (`init(allow: Bool)`, `var asked: [String]`).

- [ ] **Step 1: Write the failing tests**

```swift
@Suite struct KeyStoreTests {
    func stored(_ id: String, presence: Bool = true) -> StoredKey { StoredKey(keyID: id, issuer: TestKeys.issuer, role: .appManager, apps: [], added: "2026-10-26T20:00:00Z", presence: presence) }

    @Test func memoryStoreBehavesLikeTheProtocolSays() throws {
        let s = MemoryKeyStore()
        try s.add(stored("B"), pem: TestKeys.pem()); try s.add(stored("A"), pem: TestKeys.pem())
        #expect(try s.list().map(\.keyID) == ["A", "B"] && s.dataReads == 0)
        #expect(throws: ConnectError.duplicateKey("A")) { try s.add(stored("A"), pem: "x") }
        #expect(throws: ConnectError.unknownKey("Z", known: ["A", "B"])) { try s.pem(for: "Z") }
        try s.remove("A")
        #expect(try s.list().map(\.keyID) == ["B"])
    }
    @Test func loadAsksForPresenceThenReads() throws {
        let s = MemoryKeyStore(); try s.add(stored("A"), pem: TestKeys.pem())
        let p = ScriptedPresence(allow: true)
        let loaded = try KeyLoader.load(keyID: "A", store: s, presence: p)
        #expect(loaded.key.keyID == "A" && p.asked == ["use App Store Connect key A"] && s.dataReads == 1)
    }
    @Test func presenceDeniedReadsNothing() throws {
        let s = MemoryKeyStore(); try s.add(stored("A"), pem: TestKeys.pem())
        #expect(throws: ConnectError.presenceDenied("cancelled")) { try KeyLoader.load(keyID: "A", store: s, presence: ScriptedPresence(allow: false)) }
        #expect(s.dataReads == 0)
    }
    @Test func noPresenceKeysSkipTheAsk() throws {
        let s = MemoryKeyStore(); try s.add(stored("A", presence: false), pem: TestKeys.pem())
        let p = ScriptedPresence(allow: false)
        #expect(try KeyLoader.load(keyID: "A", store: s, presence: p).stored.presence == false && p.asked.isEmpty)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter KeyStoreTests`
Expected: compile error, `KeyStore` not found.

- [ ] **Step 3: Implement `KeyStore.swift`, `KeychainStore.swift`, the two fakes**

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter KeyStoreTests`
Expected: 4 passed.

- [ ] **Step 5: Live keychain round trip** (`Tests/ChauffeurCoreTests/Live/ConnectLiveTests.swift`, suite
  `.enabled(if: ProcessInfo.processInfo.environment["CHAUFFEUR_LIVE_KEYCHAIN"] != nil)`):

```swift
@Test func keychainRoundTrip() throws {
    let s = KeychainStore(service: "chauffeur.appstoreconnect.test")
    let id = "TEST" + String(UUID().uuidString.prefix(6)).uppercased()
    try? s.remove(id)
    try s.add(StoredKey(keyID: id, issuer: TestKeys.issuer, role: .developer, apps: ["A (a)"], added: "2026-10-26T20:00:00Z", presence: false), pem: TestKeys.pem())
    #expect(try s.list().contains { $0.keyID == id && $0.apps == ["A (a)"] })
    #expect(try s.pem(for: id).hasPrefix("-----BEGIN PRIVATE KEY-----"))
    try s.remove(id)
    #expect(!(try s.list().contains { $0.keyID == id }))
}
```

Run: `CHAUFFEUR_LIVE_KEYCHAIN=1 swift test --filter ConnectLiveTests`
Expected: 1 passed, no dialog (same binary stores and reads).

- [ ] **Step 6: Commit**

```bash
scripts/format.sh && git add Sources/ChauffeurCore/Connect/KeyStore.swift Sources/ChauffeurCore/Connect/KeychainStore.swift Tests/ChauffeurCoreTests/KeyStoreTests.swift Tests/ChauffeurCoreTests/ConnectSupport.swift Tests/ChauffeurCoreTests/Live/ConnectLiveTests.swift
git commit -m "Connect: the login keychain store, Touch ID before a read, in-memory fakes"
```

---

### Task 9: `keys add`, `keys check`, `keys remove`

Spec §2, §3.

**Files:**
- Create: `Sources/ChauffeurCore/Connect/ConnectKeys.swift`, `Tests/ChauffeurCoreTests/ConnectKeysTests.swift`

**Interfaces:**
- Consumes: everything above; `Target.connectKey(from:)` arrives in Task 10, so `check` takes `config: String?`
  as a parameter here and Task 10 wires it.
- Produces: `public enum ConnectKeys`:
  - `public struct Environment: Sendable { public var store: KeyStore; public var presence: Presence; public var transport: ConnectTransport; public var readFile: @Sendable (URL) throws -> String; public var now: @Sendable () -> Date; public init(store:presence:transport:readFile:now:); public static func live() -> Environment }`
    (`live`: `KeychainStore()`, `LocalPresence()`, `URLSessionTransport()`, `String(contentsOf:encoding: .utf8)`,
    `Date.init`).
  - `public static func add(file: String, issuer: String, keyID: String, role: ConnectRole, presence: Bool, cwd: URL, env: Environment) throws -> Output`:
    1. `ConnectKey(pem: readFile(cwd/file), …)` (a read failure → `badKeyFile("cannot read <file>: <reason>")`);
    2. `duplicateKey` if `store.list()` has the id (before any request);
    3. `Probe.run(ConnectClient(key:, role:, transport:))`; `refusedAdmin`/`refusedCertificates`/`unauthorized`/
       `rateLimited` → `Output(Probe.message(v), exit: 1)`, nothing stored;
    4. `accepted(apps)` → `store.add(StoredKey(…, added: ISO 8601 of now(), presence:), pem:)` → text:
       the sheet, then `stored key <id> (<role.title>, <n> apps) in your login keychain, Touch ID to use` (with
       `--no-presence`: `… in your login keychain (no presence: any process running as you can read it)`), then
       `hint: <file as given> is still on disk; keep a copy somewhere safe, then delete it`, then
       `note: a rebuilt chauffeur asks the keychain once ("Always Allow" remembers that build)`.
       `data`: `{"keyID", "role", "apps", "presence"}`.
  - `public static func check(keyID: String?, config: String?, env: Environment) throws -> Output`: `resolve` →
    `KeyLoader.load` → `Probe.run` → `accepted` prints the sheet and `key <id>: ok (<n> apps)`; a refusal prints
    `Probe.message` plus `\nit is still stored: chauffeur keys remove <id>` with exit 1; `unauthorized`/`rateLimited`
    print their message, exit 1.
  - `public static func remove(keyID: String, env: Environment) throws -> Output`: `store.remove` →
    `removed key <id> from your login keychain. It is not revoked: revoke it in App Store Connect (Users and Access ▸
    Integrations) when it is no longer needed`.
  - `public static func resolve(flag: String?, config: String?, stored: [StoredKey]) throws -> StoredKey`:
    `flag` › `config` › the only stored key › `noKey(known: ids)`; a flag or config id not in `stored` →
    `unknownKey`.

- [ ] **Step 1: Write the failing tests**

```swift
@Suite struct ConnectKeysTests {
    let cwd = FileManager.default.temporaryDirectory
    func env(users: String = "users-403", certificates: String = "certificates-403", apps: String = "apps-200",
             store: MemoryKeyStore = MemoryKeyStore(), presence: Bool = true, file: String? = nil) throws -> (ConnectKeys.Environment, MemoryKeyStore, ScriptedTransport) {
        let t = ScriptedTransport(["GET /v1/users": try Fixtures.connect(users), "GET /v1/certificates": try Fixtures.connect(certificates), "GET /v1/apps": try Fixtures.connect(apps)])
        let e = ConnectKeys.Environment(store: store, presence: ScriptedPresence(allow: presence), transport: t,
                                        readFile: { _ in file ?? TestKeys.pem() }, now: { Date(timeIntervalSince1970: 1_800_000_000) })
        return (e, store, t)
    }
    let add = { (e: ConnectKeys.Environment, cwd: URL) in try ConnectKeys.add(file: "AuthKey_7X2K9ABC1D.p8", issuer: TestKeys.issuer, keyID: TestKeys.keyID, role: .appManager, presence: true, cwd: cwd, env: e) }

    @Test func addProbesPrintsTheSheetAndStores() throws {
        let (e, store, t) = try env()
        let out = try add(e, cwd)
        #expect(out.exit == 0 && out.text.hasPrefix("key 7X2K9ABC1D · App Manager · issuer 69a6de70… · apps: Fixture (dev.chauffeur.fixture), "))
        #expect(out.text.contains("\nstored key 7X2K9ABC1D (App Manager, 2 apps) in your login keychain, Touch ID to use\nhint: AuthKey_7X2K9ABC1D.p8 is still on disk; keep a copy somewhere safe, then delete it\n"))
        #expect(try store.list() == [StoredKey(keyID: "7X2K9ABC1D", issuer: TestKeys.issuer, role: .appManager, apps: ["Fixture (dev.chauffeur.fixture)", #"Notes \"quoted\" (dev.x.notes)"#], added: "2027-01-15T08:00:00Z", presence: true)])
        #expect(t.requests.map(\.shape) == ["GET /v1/users", "GET /v1/certificates", "GET /v1/apps"])
        #expect(!out.text.contains("PRIVATE KEY") && out.data?["keyID"] == "7X2K9ABC1D")
    }
    @Test func addRefusesAnAdminKeyAndStoresNothing() throws {
        let (e, store, t) = try env(users: "users-200")
        let out = try add(e, cwd)
        #expect(out.exit == 1 && out.text.hasPrefix("refused: Admin key. This key can remove every other Admin"))
        #expect(try store.list().isEmpty && t.requests.count == 1)
    }
    @Test func addRefusesACertificatesKey() throws { /* certificates: "certificates-200" → exit 1, text hasPrefix "refused: this key reaches Certificates, Identifiers & Profiles" */ }
    @Test func addRefusesABadFileBeforeAnyRequest() throws {
        let (e, store, t) = try env(file: "usage: chauffeur <command>")
        #expect(throws: ConnectError.self) { try add(e, cwd) }
        #expect(try store.list().isEmpty && t.requests.isEmpty)
    }
    @Test func addRefusesADuplicateId() throws {
        let (e, store, t) = try env(); _ = try add(e, cwd)
        #expect(throws: ConnectError.duplicateKey("7X2K9ABC1D")) { try add(e, cwd) }
        #expect(t.requests.count == 3)
    }
    @Test func addStoresNothingWhenTheProbeCannotRun() throws {
        let (e, store, _) = try env(users: "server-500")
        #expect(throws: ConnectError.self) { try add(e, cwd) }
        #expect(try store.list().isEmpty)
        let (e2, store2, _) = try env(users: "unauthorized-401")
        let out = try add(e2, cwd)
        #expect(out.exit == 1 && out.text == ConnectError.unauthorized.description && (try store2.list().isEmpty))
    }
    @Test func addStoresNothingWhenRateLimited() throws {
        let (e, store, _) = try env(users: "rate-limited-429")
        let out = try add(e, cwd)
        #expect(out.exit == 1 && out.text.hasPrefix("rate limited by App Store Connect") && (try store.list().isEmpty))
    }
    @Test func noPresenceIsSaidOutLoud() throws {
        let (e, store, _) = try env()
        let out = try ConnectKeys.add(file: "k.p8", issuer: TestKeys.issuer, keyID: TestKeys.keyID, role: .developer, presence: false, cwd: cwd, env: e)
        #expect(out.text.contains("in your login keychain (no presence: any process running as you can read it)"))
        #expect(try store.list()[0].presence == false && out.text.contains("can:    upload builds · read builds"))
    }
    @Test func checkAsksForPresenceAndReprobes() throws {
        let (e, _, t) = try env(); _ = try add(e, cwd)
        let presence = ScriptedPresence(allow: true)
        var e2 = e; e2.presence = presence
        let out = try ConnectKeys.check(keyID: nil, config: nil, env: e2)
        #expect(out.exit == 0 && out.text.hasSuffix("\nkey 7X2K9ABC1D: ok (2 apps)") && presence.asked.count == 1 && t.requests.count == 6)
    }
    @Test func checkReportsARevokedKey() throws {
        let (e, store, _) = try env(); _ = try add(e, cwd)
        let (e2, _, _) = try env(users: "unauthorized-401", store: store)
        let out = try ConnectKeys.check(keyID: "7X2K9ABC1D", config: nil, env: e2)
        #expect(out.exit == 1 && out.text == ConnectError.unauthorized.description)
    }
    @Test func removeSaysItDoesNotRevoke() throws {
        let (e, store, _) = try env(); _ = try add(e, cwd)
        let out = try ConnectKeys.remove(keyID: "7X2K9ABC1D", env: e)
        #expect(out.text.hasPrefix("removed key 7X2K9ABC1D from your login keychain. It is not revoked") && (try store.list().isEmpty))
        #expect(throws: ConnectError.unknownKey("7X2K9ABC1D", known: [])) { try ConnectKeys.remove(keyID: "7X2K9ABC1D", env: e) }
    }
    @Test func resolution() throws {
        let a = StoredKey(keyID: "A", issuer: "", role: .developer, apps: [], added: "", presence: true), b = /* "B" */
        #expect(try ConnectKeys.resolve(flag: "B", config: "A", stored: [a, b]).keyID == "B")
        #expect(try ConnectKeys.resolve(flag: nil, config: "A", stored: [a, b]).keyID == "A")
        #expect(try ConnectKeys.resolve(flag: nil, config: nil, stored: [a]).keyID == "A")
        #expect(throws: ConnectError.noKey(known: ["A", "B"])) { try ConnectKeys.resolve(flag: nil, config: nil, stored: [a, b]) }
        #expect(throws: ConnectError.noKey(known: [])) { try ConnectKeys.resolve(flag: nil, config: nil, stored: []) }
        #expect(throws: ConnectError.unknownKey("Z", known: ["A"])) { try ConnectKeys.resolve(flag: nil, config: "Z", stored: [a]) }
    }
}
```

(`added` is the ISO 8601 of the test's fixed `now`: `1_800_000_000` is `2027-01-15T08:00:00Z`.)

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter ConnectKeysTests`
Expected: compile error, `ConnectKeys` not found.

- [ ] **Step 3: Implement `ConnectKeys.swift`**

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter ConnectKeysTests`
Expected: 12 passed.

- [ ] **Step 5: Commit**

```bash
scripts/format.sh && git add Sources/ChauffeurCore/Connect/ConnectKeys.swift Tests/ChauffeurCoreTests/ConnectKeysTests.swift
git commit -m "keys add, check, remove: probe first, store only what passed, say what the key can do"
```

---

### Task 10: The pin: `keys use` and `.chauffeur.json`

Spec §2 (the pin).

**Files:**
- Modify: `Sources/ChauffeurCore/Target.swift`, `Sources/ChauffeurCore/Connect/ConnectKeys.swift`,
  `Tests/ChauffeurCoreTests/TargetTests.swift`, `Tests/ChauffeurCoreTests/ConnectKeysTests.swift`

**Interfaces:**
- Produces:
  - `Target.connectKey(from dir: URL) -> String?` (nearest `.chauffeur.json` that sets `connectKey`).
  - `Target.setConfig(_ key: String, to value: Any, in dir: URL) throws`: the body of today's `writeConfig(udid:)`
    generalised; `writeConfig(udid:)` calls `setConfig("udid", …)` and keeps its signature.
  - `ConnectKeys.use(keyID: String, cwd: URL, env: Environment) throws -> Output`: the id must be in
    `store.list()` (else `unknownKey`), then `Target.setConfig("connectKey", to: keyID, in: cwd)` and
    `using key <id> for <cwd.path>`.
  - `ConnectKeys.list(cwd: URL, env: Environment) throws -> Output`: one line per key,
    `<id> · <role.title> · <n> apps · added <added prefix 10> · presence|no presence` plus ` · pinned` for the
    one `Target.connectKey(from: cwd)` names; none: `no keys stored (chauffeur keys add <AuthKey.p8> --issuer <uuid>
    --key-id <id> --role app-manager)`. `data`: `{"keys": [{"keyID","role","apps","added","presence","pinned"}]}`,
    no issuer. Never calls `store.pem`.
  - `ConnectKeys.check` reads the pin itself from `Target.connectKey(from: cwd)`: its signature becomes
    `check(keyID: String?, cwd: URL, env:)`, and Task 9's two `check` tests pass `cwd:` instead of `config: nil`.

- [ ] **Step 1: Write the failing tests**

In `TargetTests`:
```swift
@Test func connectKeyRoundTripsAndKeepsTheRest() throws {
    let root = /* temp dir */; let file = root.appendingPathComponent(Target.configName)
    try Data(#"{"udid":"AAAA-1","telemetryHosts":["events.example.com"]}"#.utf8).write(to: file)
    try Target.setConfig("connectKey", to: "7X2K9ABC1D", in: root)
    #expect(Target.connectKey(from: root.appendingPathComponent("sub")) == "7X2K9ABC1D")
    #expect(Target.readConfig(from: root) == "AAAA-1" && Target.telemetryHosts(from: root) == ["events.example.com"])
    try Target.writeConfig(udid: "BBBB-2", in: root)
    #expect(Target.connectKey(from: root) == "7X2K9ABC1D" && Target.readConfig(from: root) == "BBBB-2")
}
```
In `ConnectKeysTests`:
```swift
@Test func useWritesThePinAndListShowsIt() throws {
    let root = /* fresh temp dir */; let (e, store, _) = try env(); _ = try add(e, root)
    #expect(throws: ConnectError.unknownKey("Z", known: ["7X2K9ABC1D"])) { try ConnectKeys.use(keyID: "Z", cwd: root, env: e) }
    #expect(try ConnectKeys.use(keyID: "7X2K9ABC1D", cwd: root, env: e).text == "using key 7X2K9ABC1D for \(root.path)")
    let list = try ConnectKeys.list(cwd: root, env: e)
    #expect(list.text == "7X2K9ABC1D · App Manager · 2 apps · added 2027-01-15 · presence · pinned" && store.dataReads == 0)
    #expect(list.data?["keys"]?.array?.first?["pinned"] == true && list.data?["keys"]?.array?.first?["issuer"] == nil)
    #expect(try ConnectKeys.list(cwd: FileManager.default.temporaryDirectory, env: ConnectKeys.Environment(/* empty store */)).text.hasPrefix("no keys stored (chauffeur keys add"))
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter "TargetTests|ConnectKeysTests"`
Expected: compile error, `setConfig` not found.

- [ ] **Step 3: Implement**

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter "TargetTests|ConnectKeysTests"`
Expected: all passed.

- [ ] **Step 5: Commit**

```bash
scripts/format.sh && git add Sources/ChauffeurCore/Target.swift Sources/ChauffeurCore/Connect/ConnectKeys.swift Tests/ChauffeurCoreTests/TargetTests.swift Tests/ChauffeurCoreTests/ConnectKeysTests.swift
git commit -m "keys use and keys list: the pin in .chauffeur.json, kept by chauffeur use"
```

---

### Task 11: The CLI, usage, and `doctor`

Spec §2 (commands), §7 (`doctor`).

**Files:**
- Modify: `Sources/ChauffeurCore/CLI.swift`, `Sources/ChauffeurCore/Engine/Args.swift` (`Usage.text`),
  `Sources/ChauffeurCore/Doctor.swift`, `Tests/ChauffeurCoreTests/CLITests.swift`,
  `Tests/ChauffeurCoreTests/DoctorTests.swift`

**Interfaces:**
- Produces:
  - `CLI.Environment` gains `public var connect: ConnectKeys.Environment`; its `init` gains
    `connect: ConnectKeys.Environment? = nil` (nil → `.live()`); `live(executable:)` passes `.live()`.
  - `CLI.handleText`: `case "keys":` → `try ConnectKeys.handle(tail, cwd: e.cwd, env: e.connect)`, where
    `public static func handle(_ argv: [String], cwd: URL, env: Environment) throws -> Output` parses with `Args`:
    `add <file> --issuer --key-id --role [--no-presence]` (a missing option is
    `ChauffeurError.usage("<option> is required\n" + usage)`; a `--role` that `ConnectRole(flag:)` rejects is
    `ChauffeurError.usage("--role must be developer or app-manager\n" + usage)`), `list`, `check [<id>]`, `remove <id>`, `use <id>`; anything else is
    `ChauffeurError.usage(ConnectKeys.usage)` with
    `usage: chauffeur keys add <AuthKey.p8> --issuer <uuid> --key-id <id> --role developer|app-manager [--no-presence] · keys list · keys check [<key-id>] · keys remove <key-id> · keys use <key-id>`.
    A `ConnectError` thrown out of `handle` is caught in `handleText`'s existing `catch` (it prints
    `"\(error)"`, exit 1): add `catch let error as ConnectError { return Output(error.description, exit: 1) }`
    before the generic one so `--json` wraps it the same way.
  - `Usage.text` gains, after the `mcp` line:
    ```
      keys add <AuthKey.p8> --issuer <uuid> --key-id <id> --role developer|app-manager [--no-presence]
      keys list | check [<key-id>] | remove <key-id> | use <key-id>   App Store Connect keys: for humans, never an agent
    ```
  - `Doctor.connectCheck(keys: [StoredKey], pinned: String?) -> Check`:
    - no keys: `.ok`, `connect key: none (chauffeur keys add)`;
    - `pinned` in `keys`: `.ok`, `connect key: <id> (<role.title>, presence|no presence) · pinned for this project`;
    - `pinned` not in `keys`: `.fail`, `connect key: <id> is pinned in .chauffeur.json but not in your keychain (chauffeur keys add, or keys use another)`;
    - one key, no pin: `.ok`, `connect key: <id> (<role.title>, presence)`;
    - several, no pin: `.warn`, `connect keys: <ids> · none pinned (chauffeur keys use <key-id>)`.
    `Doctor.run` appends it right after the Xcode check, from `try e.connect.store.list()` and
    `Target.connectKey(from: e.cwd)`; a thrown keychain error becomes `.warn`, `connect key: <error>`. It never
    calls `pem`.

- [ ] **Step 1: Write the failing tests**

In `CLITests`:
```swift
@Test func keysCommandsNeverReachTheDaemon() throws {
    let rec = Recorder()
    let store = MemoryKeyStore()
    let connect = ConnectKeys.Environment(store: store, presence: ScriptedPresence(allow: true), transport: ScriptedTransport([:]), readFile: { _ in "" }, now: Date.init)
    var e = env(booted: [a], recorder: rec); e.connect = connect
    #expect(CLI.handle(["keys", "list"], e).text.hasPrefix("no keys stored"))
    let bad = CLI.handle(["keys", "add", "k.p8", "--issuer", TestKeys.issuer, "--key-id", "7X2K9ABC1D", "--role", "admin"], e)
    #expect(bad.exit == 64 && bad.text.hasPrefix("--role must be developer or app-manager"))
    #expect(CLI.handle(["keys"], e).exit == 64 && CLI.handle(["keys", "frob"], e).exit == 64)
    let missing = CLI.handle(["keys", "remove", "Z"], e)
    #expect(missing.exit == 1 && missing.text == "no stored key Z; stored: none")
    #expect(CLI.handle(["--json", "keys", "remove", "Z"], e).text.hasPrefix(#"{"data":null,"exit":1,"text":"no stored key Z"#))
    #expect(rec.calls.isEmpty)
}
@Test func usageListsKeys() { #expect(Usage.text.contains("keys add <AuthKey.p8> --issuer <uuid> --key-id <id> --role developer|app-manager [--no-presence]")) }
```
In `DoctorTests`:
```swift
@Test func connectKeyLine() {
    let k = StoredKey(keyID: "7X2K9ABC1D", issuer: "", role: .appManager, apps: [], added: "", presence: true)
    let n = StoredKey(keyID: "NFC334SLRJ", issuer: "", role: .developer, apps: [], added: "", presence: false)
    #expect(Doctor.connectCheck(keys: [], pinned: nil) == Check(status: .ok, text: "connect key: none (chauffeur keys add)"))
    #expect(Doctor.connectCheck(keys: [k], pinned: "7X2K9ABC1D") == Check(status: .ok, text: "connect key: 7X2K9ABC1D (App Manager, presence) · pinned for this project"))
    #expect(Doctor.connectCheck(keys: [k], pinned: "ZZZZZZZZZZ").status == .fail)
    #expect(Doctor.connectCheck(keys: [k], pinned: nil) == Check(status: .ok, text: "connect key: 7X2K9ABC1D (App Manager, presence)"))
    #expect(Doctor.connectCheck(keys: [k, n], pinned: nil) == Check(status: .warn, text: "connect keys: 7X2K9ABC1D, NFC334SLRJ · none pinned (chauffeur keys use <key-id>)"))
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter "CLITests|DoctorTests"`
Expected: compile errors (`connect`, `connectCheck`).

- [ ] **Step 3: Implement**

`MCPTools` is untouched: there is no `keys` tool. Check `grep -n keys Sources/ChauffeurCore/Agent/MCPTools.swift`
prints nothing.

- [ ] **Step 4: Run the whole suite and the checks**

Run: `scripts/check.sh`
Expected: `check: all passed`.

- [ ] **Step 5: Commit**

```bash
git add Sources/ChauffeurCore/CLI.swift Sources/ChauffeurCore/Engine/Args.swift Sources/ChauffeurCore/Doctor.swift Tests/ChauffeurCoreTests/CLITests.swift Tests/ChauffeurCoreTests/DoctorTests.swift
git commit -m "chauffeur keys in the CLI, and the connect key line in doctor"
```

---

### Task 12: Words: the skill, the design doc, CLAUDE.md, README

Spec "Why" (the design.md line), Done when.

**Files:**
- Modify: `Sources/ChauffeurCore/Agent/Skill.swift`, `Tests/ChauffeurCoreTests/SkillTests.swift`, `docs/design.md`,
  `CLAUDE.md`, `README.md`, `docs/roadmap.md`

- [ ] **Step 1: Write the failing test** (in `SkillTests`):

```swift
@Test func theSkillKeepsKeysWithHumans() {
    #expect(Skill.skillMarkdown.contains("- App Store Connect keys belong to the human: never run `chauffeur keys add`, `remove` or `use`. If a command reports no key, say so and stop."))
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `swift test --filter SkillTests`
Expected: 1 failed.

- [ ] **Step 3: Add the sentence to the skill's Rules list; the AGENTS.md section is unchanged**

- [ ] **Step 4: Edit the docs**

- `docs/design.md`: the decisions table's License row becomes `Apache-2.0 (chosen at release; drafted as MIT), no
  telemetry; network only to App Store Connect during release commands`; §8's first bullet becomes
  `- No telemetry. The only network connections are to App Store Connect, only during release commands (M5a's key
  commands, M5b's ship), and to the project's own metadata URLs in the review check (M5c). Nothing about the
  developer leaves the Mac.`; add a bullet `- The App Store Connect key lives in the login keychain behind Touch
  ID; setup refuses a key that could reach users or certificates; the client has no delete, expire or cancel
  (M5a spec).`
- `CLAUDE.md` "Where code goes": add the row `| \`Sources/ChauffeurCore/Connect\` | App Store Connect: the key, tokens,
  the request table and the probes. Reads only until M5b. |` after the `Agent` row. Stage this hunk only:
  `git diff CLAUDE.md > /tmp/claude.patch`, delete the context-mem hunk from the patch, `git apply --cached
  /tmp/claude.patch`. Verify with `git diff --cached CLAUDE.md` that only the table row is staged.
- `README.md`: a short "App Store Connect key" subsection after the commands: the five commands, one line on the
  probes, one line that an agent never adds or removes keys, link to the spec.
- `docs/roadmap.md`: M5a's status `in progress`, and a checklist like M4b's: step 0 (done), key/tokens/table,
  probes and sheet, keychain, CLI and doctor, live run.

- [ ] **Step 5: Run the checks**

Run: `scripts/check.sh && git diff --cached --stat`
Expected: `check: all passed`; only the table row staged from `CLAUDE.md`.

- [ ] **Step 6: Commit**

```bash
git add Sources/ChauffeurCore/Agent/Skill.swift Tests/ChauffeurCoreTests/SkillTests.swift docs/design.md README.md docs/roadmap.md
git commit -m "docs: keys are the human's; the network line; where Connect code goes"
```

---

### Task 13: The live run and the recorded fixtures (owner at the keyboard)

Spec Testing (live), Findings 2 and 4. Needs: an App Manager key without the Certificates, Identifiers & Profiles
toggle, a Developer key, an Admin key created for this and revoked the same day, and the issuer id.

**Files:**
- Modify: `Tests/ChauffeurCoreTests/Live/ConnectLiveTests.swift`, `Tests/ChauffeurCoreTests/Fixtures/connect/*.json`,
  `docs/specs/2026-10-26-m5a-connect-key-design.md` (Findings 2, 4)

**Interfaces:**
- `ConnectLiveTests.recordProbes`, enabled by `CHAUFFEUR_LIVE_CONNECT_KEY=<id>` (a key already stored with
  `keys add`, or for Admin and certificate keys, which `add` refuses, the three env vars
  `CHAUFFEUR_LIVE_P8=<path> CHAUFFEUR_LIVE_ISSUER=<uuid> CHAUFFEUR_LIVE_KEY_ID=<id>`) and
  `CHAUFFEUR_RECORD=<label>` (`admin`, `app-manager`, `app-manager-cip`, `developer`): wraps `URLSessionTransport`
  in a `RecordingTransport` (tests only) that writes each response as
  `Fixtures/connect/<label>-<resource>-<status>.json` with `"source": "recorded <date>"`, headers trimmed to
  `X-Rate-Limit` and `Content-Type`, and any `id` values left as they are (they are not secrets).
- `ConnectLiveTests.scopedTokenIsGetOnly` (same gating): a `.call` token scoped to `GET /v1/apps?limit=200` sent on
  that path gets 200; the same token on `PATCH /v1/apps/{id}` (through `URLSessionTransport` with a hand-built
  request in the test; no `Operation` exists for it) gets `405`. Records both statuses in Findings 4.

- [ ] **Step 1: Run `keys add` by hand with each key, from the Mac** (the implementer or the owner):

```bash
swift build && .build/debug/chauffeur keys add ~/Downloads/AuthKey_<id>.p8 --issuer <uuid> --key-id <id> --role app-manager
```

Expected, per key: App Manager without the toggle → the sheet and `stored key …`; Admin → `refused: Admin key.`;
App Manager with the toggle → `refused: this key reaches Certificates, Identifiers & Profiles.`; Developer →
the sheet with the Developer `can:` line. Then `keys check`, observe the Touch ID sheet, note the macOS version.
Then revoke the Admin key in App Store Connect and run `keys check` on a key whose Admin twin was revoked → 401.

- [ ] **Step 2: Record the fixtures**

```bash
CHAUFFEUR_LIVE_P8=… CHAUFFEUR_LIVE_ISSUER=… CHAUFFEUR_LIVE_KEY_ID=… CHAUFFEUR_RECORD=admin swift test --filter ConnectLiveTests/recordProbes
```
once per label. Replace the `documented` fixtures with the recorded ones of the same meaning (`users-403` ←
`app-manager-users-403`, and so on); keep the file names the unit tests use.

- [ ] **Step 3: If the App Manager key gets 200 on `/v1/users`**: spec §3's "no Admin-only read" branch applies,
  and the users probe can't tell Admin from App Manager. Implement the branch as the spec states it: the Admin
  verdict comes from the declared role instead. `Probe.decide` gains `declared: ConnectRole` and returns
  `refusedAdmin` never; `keys add` already refuses `--role admin` at parse time (Task 11), so an Admin key can only
  arrive declared as something else, and M5b's first-write check catches that. The sheet's App Manager `cannot:`
  line becomes `add or remove people above App Manager · change roles · …`, the Findings say which branch holds,
  and `ProbeTests.decisionTable` changes with it. Re-run `ProbeTests` on the recorded fixtures either way.

- [ ] **Step 4: Write Findings 2 and 4 in the spec** with the statuses and the `errors[].code` seen, and the macOS
  version where the Touch ID sheet was observed.

- [ ] **Step 5: Run the checks and commit**

```bash
scripts/check.sh && git add Tests/ChauffeurCoreTests Tests/ChauffeurCoreTests/Fixtures/connect docs/specs/2026-10-26-m5a-connect-key-design.md
git commit -m "Connect: recorded probe fixtures and the scoped-token check; findings 2 and 4"
```

---

### Task 14: Finish the branch

- [ ] **Step 1:** `scripts/check.sh`, `scripts/check-commits.sh m4b-network..HEAD`, `CHAUFFEUR_LIVE_KEYCHAIN=1 swift
  test --filter ConnectLiveTests` all pass.
- [ ] **Step 2:** Ask the owner before pushing. Open the PR against `main` once M4b's 0.2.0 has merged (rebase
  first), titled "M5a: the App Store Connect key, and what it can never do", body: the spec link, the Findings
  summary, the live run's transcript with ids, and the note that no release command exists yet so the table is
  reads only.

---

## Addendum (2026-10-27): the spec's Decision

Step 0 and the research pass (spec Findings 2 and 4, Decision) changed §3 and added a binary-hardening requirement.
Tasks 1–12 are complete on the branch; these two tasks bring the code to the revised spec. Task 13's live run then
uses the owner's App Manager key.

### Task 15: The finance alarm replaces the users and certificates probes

Spec §3 (revised), §4 deny list (revised).

**Files:**
- Modify: `Sources/ChauffeurCore/Connect/Operation.swift`, `RequestTable.swift`, `ConnectTransport.swift`,
  `Probe.swift`, `CapabilitySheet.swift`, `ConnectKeys.swift`
- Modify: `Tests/ChauffeurCoreTests/RequestTableTests.swift`, `ConnectClientTests.swift`, `ProbeTests.swift`,
  `ConnectKeysTests.swift`, `CLITests.swift` (if it names the removed kinds), `ConnectSupport.swift`,
  `Live/ConnectLiveTests.swift`
- Fixtures: delete `users-200.json`, `users-403.json`, `certificates-200.json`, `certificates-403.json`; add
  `finance-400.json` (Admin key), `finance-403.json` (App Manager key), `finance-403-agreements.json` (hand-written,
  `code: FORBIDDEN.REQUIRED_AGREEMENTS_MISSING_OR_EXPIRED`, `source: documented`); re-record `apps-200.json` and
  `unauthorized-401.json` from the real keys. Recorded files carry `"source": "recorded 2026-10-27"`.

**Interfaces:**
- `Operation`: remove `probeUsers` and `probeCertificates` (and their `Kind`s, rows, and every test that names them);
  add `probeFinance(month: String)` → row `GET /v1/financeReports`, resource `financeReports`, query
  `filter[regionCode]=US`, `filter[reportDate]=<month>`, `filter[reportType]=FINANCIAL`, `filter[vendorNumber]=0`
  (sorted by name as the others), `accept: "application/a-gzip"`.
- `RequestRow` gains `public let accept: String` (default `"application/json"` in the memberwise init);
  `ConnectRequest` gains `accept` and `headers["Accept"]` uses it; `ConnectClient.request(for:)` passes the row's.
- `RequestTable.forbiddenPost: Set<String> = ["certificates", "bundleIds", "profiles", "userInvitations", "webhooks", "inAppPurchases", "subscriptions", "appPriceSchedules", "appAvailabilities"]`
  and a test `noPostOnTheForbiddenResources` like the PATCH one.
- `RequestTable.denied`, in this order, texts exact: `"expire a build"`, `"cancel a submission"`,
  `"remove a tester"`, `"delete or revoke a certificate, identifier or profile"` (any non-GET on `certificates`,
  `bundleIds` or `profiles`), `"invite or remove a user"` (any non-GET on `users` or `userInvitations`),
  `"change pricing or availability"` (non-GET on a resource starting with `appPrice` or `appAvailabilit`),
  `"touch in-app purchases"` (non-GET on `inAppPurchases`, `subscriptions` or a resource starting with
  `subscription`/`inAppPurchase`), `"manage webhooks"` (non-GET on `webhooks`). `theNeverLineIsTheWholeDenyList`
  and `everyDenyEntryCatchesItsViolation` cover all eight.
- `public enum RoleCheck: Equatable, Sendable { case notFinanceCapable; case unavailable(status: Int, code: String?) }`
  (in `Probe.swift`).
- `ProbeVerdict`: `unauthorized`, `rateLimited(remaining: Int)`, `refusedFinance`, `accepted(apps: [String], roleCheck: RoleCheck)`.
  `refusedAdmin` and `refusedCertificates` are removed.
- `Probe.decide(apps: Int, finance: (status: Int, code: String?)?) -> ProbeVerdict?`: `apps` 401 → `unauthorized`;
  429 → `rateLimited(remaining: 0)`; 200 with `finance == nil` → nil (caller must probe finance); 200 and finance
  `(400, "PARAMETER_ERROR.INVALID")` → `refusedFinance`; `(403, "FORBIDDEN_ERROR")` → `accepted(apps: [],
  roleCheck: .notFinanceCapable)` (the caller fills `apps`); any other finance pair → `accepted(apps: [],
  roleCheck: .unavailable(status:, code:))`; any other `apps` status → nil (caller throws `client.error(for:op:)`).
- `Probe.run(_ client:, now: Date)`: `perform(.probeApps)`; map 401/429 as before; on 200 parse apps, then
  `ensure(requests: 1)`, `perform(.probeFinance(month: Probe.lastMonth(now)))` (never `send`: every status is a
  verdict here; a transport error becomes `.unavailable(status: 0, code: "transport")`), then `decide`.
  `Probe.lastMonth(_ now: Date) -> String` is `yyyy-MM` of the previous month in UTC.
- `Probe.message(.refusedFinance)` is the spec's text verbatim: `refused: finance-capable key. This key can read the
  team's finance reports, which only Admin, Account Holder and Finance keys can. An Admin key can remove every other
  Admin, revoke certificates and delete identifiers; chauffeur never holds one. In App Store Connect, generate a key
  with the App Manager role.`
- `CapabilitySheet.render(keyID:role:issuer:apps:roleCheck:)` produces the six lines of spec §3 (role line reads
  `App Manager (declared)`; the `role check:` line has the two forms; the `cannot (Apple's role chart):` line; the
  `unverified for this role:` line; the `chauffeur will never:` line from `RequestTable.never()`). Developer keeps
  its own `can:`/`cannot` lines as the spec says.
- `ConnectKeys.add`/`check`: verdict handling follows the new enum; the `stored key …` line is unchanged; `data`
  gains `"roleCheck": "not-finance-capable" | "unavailable"`.
- Fixture recording: a test-only `RecordingTransport` in `ConnectSupport.swift` wrapping `URLSessionTransport`, used
  by `ConnectLiveTests.recordProbes`, enabled by `CHAUFFEUR_RECORD_PROBES=<label>` with `CHAUFFEUR_LIVE_P8`,
  `CHAUFFEUR_LIVE_ISSUER`, `CHAUFFEUR_LIVE_KEY_ID`; it runs `Probe.run` and writes each response as
  `Fixtures/connect/<label>-<resource>-<status>.json` (headers trimmed to `X-Rate-Limit` and `Content-Type`; a
  gzip body is stored as an empty object). The implementer runs it for the Admin key, the App Manager key and the
  revoked key (Findings 2 names them; the owner authorised their use for testing on 2026-10-27), then renames the
  files to the names the unit tests use.

Steps: failing tests first (`RequestTableTests`, `ProbeTests`, `ConnectKeysTests`), implement, record fixtures,
`scripts/check.sh`, commit `Connect: the finance alarm replaces the role probes; the deny list grows`.

### Task 16: Only a hardened build may hold a key

Spec §5 (hardened binary).

**Files:**
- Create: `scripts/sign.sh`, `Sources/ChauffeurCore/Connect/BuildIdentity.swift`, `Tests/ChauffeurCoreTests/BuildIdentityTests.swift`
- Modify: `Sources/ChauffeurCore/Connect/ConnectKeys.swift`, `Sources/ChauffeurCore/Connect/ConnectError.swift`,
  `scripts/check.sh`, `scripts/build-mcpb.sh`, `CONTRIBUTING.md`, `README.md`, `Tests/ChauffeurCoreTests/ConnectSupport.swift`,
  `ConnectKeysTests.swift`, `CLITests.swift`

**Interfaces:**
- `public protocol BuildIdentity: Sendable { var hardenedRuntime: Bool { get }; var debuggable: Bool { get } }`.
- `public struct LiveBuildIdentity: BuildIdentity`: `SecCodeCopySelf` → `SecCodeCopySigningInformation(_, [.signingInformation], _)`;
  `hardenedRuntime` = `kSecCodeInfoFlags` contains `kSecCodeSignatureRuntime` (0x10000); `debuggable` =
  `kSecCodeInfoEntitlementsDict["com.apple.security.get-task-allow"] == true`. Any failure reads as
  `hardenedRuntime == false`.
- `ConnectError.unhardenedBuild` with description `this build can't hold an App Store Connect key: it isn't
  hardened. Build and sign a release: swift build -c release && scripts/sign.sh`.
- `ConnectKeys.Environment` gains `identity: BuildIdentity` (`live()` → `LiveBuildIdentity()`); `add` and `check`
  throw `unhardenedBuild` before touching the store or the network when `!identity.hardenedRuntime || identity.debuggable`.
  `list`, `remove` and `use` don't read key data and are not gated. Test fake `FixedBuildIdentity(hardened:debuggable:)`;
  the CLITests helper uses `hardened: true, debuggable: false`.
- `scripts/sign.sh [path]`: `codesign --force --sign - --options runtime "$path"` (default `.build/release/chauffeur`),
  then verifies with `codesign -d -vv` that the flags include `runtime` and the entitlements have no
  `get-task-allow`; non-zero exit otherwise. `scripts/check.sh` runs it after the release build step.
  `scripts/build-mcpb.sh` replaces its plain `codesign --force --sign -` with `scripts/sign.sh`. CONTRIBUTING's
  Releasing section gains the step and the Homebrew formula note (`codesign --force --sign - --options runtime` in
  its install block). README's key subsection says key commands run from the signed release build.
- Verification (implementer, live): after `scripts/sign.sh`, `DYLD_INSERT_LIBRARIES=<a tiny dylib> .build/release/chauffeur --version`
  does not run the dylib's constructor (compare with the unsigned build); `.build/debug/chauffeur keys list` works
  but `keys check` reports `unhardenedBuild`; the signed release build's `keys check` reaches the presence prompt
  (stop there: the owner watches that step in Task 13).

Steps: failing tests first (`BuildIdentityTests` with the fake; `ConnectKeysTests.unhardenedBuildsRefuseKeyCommands`),
implement, `scripts/check.sh`, commit `Connect: only a hardened build may hold a key; scripts/sign.sh`.
