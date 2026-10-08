# M4a: guardrails and the contributor workflow

**Status:** draft for review · **Date:** 2026-10-08

## Why

chauffeur 0.1.0 is public, and a second contributor is joining. Both of us work mostly through Claude Code. M4a sets
up the repo so that two people and their agents can change it quickly without it turning into spaghetti, and so that
an outside contributor can send a PR and know what is expected.

The code is in good shape today: about 5,400 lines of source, no file over 400 lines, 253 unit tests, Swift 6 language
mode with 0 compiler warnings. M4a keeps it that way. It is not a cleanup.

## Goals

1. `YashNaj/chauffeur` is the source of truth. Work happens there, by PR.
2. One local command, `scripts/check.sh`, runs everything CI runs. If it passes locally, CI passes.
3. Formatting is automatic. Nobody, human or agent, formats by hand or argues about style.
4. Lint rules exist only where breaking them would cause a real bug or real mess in this project.
5. Agents get the project's rules in the files they read on start-up, and their edits are formatted as they happen.
6. `main` only changes through a reviewed PR with green checks.
7. A new contributor can go from clone to first PR using `CONTRIBUTING.md` alone, and can pick work from a roadmap.

## Non-goals

- Restructuring the code. The module layout stays as it is.
- SwiftLint, SwiftFormat (the community tool) or any other new dependency.
- M4b (edge cases) and M4c (eval v2). They get their own specs; M4a only lists them in the roadmap.

## 1. Source of truth

Until now the private working repo was the source of truth, and `scripts/export-public.sh` and `scripts/sync-public.sh`
copied an allowlisted tree into the public repo. From M4a on:

- **Final sync.** Before anything else, compare the public tree with what the allowlist selects from the private
  repo's `main`. The public repo is already ahead (the 0.1.1 hotfix was made there), so differences are resolved by
  hand, file by file, never by running `sync-public.sh` over the public tree.
- **Retired:** `scripts/export-public.sh`, `scripts/sync-public.sh`, `scripts/select-public.py`,
  `scripts/public-files.txt`, and the allowlist half of `scripts/tests/test-public.sh`.
- **Kept:** `scripts/check-public.sh` (the leak check), its tests, and the pre-commit hook that runs it. A public repo
  still must not contain private material.
- **Stays private:** the launch posts, release notes, the M0–M3b specs and plans (they contain private material and
  describe finished work), and the raw dogfood evidence. The private repo becomes an archive and gets a README line
  saying so.
- **New specs and plans** live in the public repo under `docs/specs/` and `docs/plans/`, written for public view.
  `docs/design.md` stays the architecture reference.

## 2. Commit identity

Public commits must not carry a personal email.

- Each contributor sets a repo-local identity, using their GitHub noreply address. `CONTRIBUTING.md` gives the two
  `git config --local` commands.
- CI checks the author and committer of every commit in a PR against the leak list, and fails on a match.
- Commits carry no `Co-Authored-By` trailer for an AI assistant. That is the project's convention, stated in
  `CONTRIBUTING.md` and `CLAUDE.md`.

## 3. Compiler

- CI builds and tests with `-Xswiftc -warnings-as-errors`. Today there are 0 warnings, so this costs nothing and stops
  warnings from accumulating.
- Swift 6 language mode stays on (it is the default for `swift-tools-version: 6.0`).

## 4. Formatting

- **Tool:** `swift-format`, which ships with Xcode (`xcrun swift-format`). No install step.
- **Config:** a checked-in `.swift-format`: 4-space indentation, 120-column lines, everything else at Apple's defaults.
  Rules that fight the formatter's own output are switched off only if the reformat commit shows a conflict, and each
  one switched off gets a comment in the config saying why.
- **One reformat commit.** Today's dense style produces about 1,500 lint findings with that config (semicolons,
  long lines, indentation). One commit runs `swift-format format -i -r Sources Tests` and changes nothing else; its
  hash goes in `.git-blame-ignore-revs`. `CONTRIBUTING.md` shows the one-line git setting that makes `git blame` honor
  it, and GitHub honors it automatically.
- **Automatic for agents.** A committed `.claude/settings.json` adds a `PostToolUse` hook on `Edit|Write`: when the
  edited file ends in `.swift`, it runs `xcrun swift-format format -i` on that file. The hook is silent on success and
  never blocks the edit.
- **Automatic for people.** `scripts/format.sh` formats the whole tree. The pre-commit hook does not reformat; it only
  runs the leak check, as now.
- **Gate:** `swift-format lint --strict -r Sources Tests` must report nothing.

## 5. Project lint: `scripts/check-code.sh`

A bash script with one function per rule. Each rule prints `file:line: <rule>: <message>` and the script exits 1 if
any rule matched. Comment lines are ignored. A line can opt out with a trailing `// check-code: allow <rule> — <reason>`;
the reason is required, so a reviewer sees why.

| Rule | What it checks | Why |
|---|---|---|
| `bridge` | `dlopen`, `dlsym`, `NSClassFromString`, `objc_msgSend`, `@_silgen_name` and `PrivateFrameworks` appear only under `Sources/ChauffeurBridge` | Private Apple API is what breaks when Xcode updates. Keeping it in one target keeps that breakage in one place. |
| `try-bang` | no `try!` under `Sources` | A crash in the daemon takes the agent's session down with it. |
| `print` | no `print(` under `Sources/ChauffeurCore` | Output goes through the CLI target and the MCP framing; a stray print corrupts the MCP stream on stdout. |
| `file-length` | no `.swift` file over 400 lines under `Sources`, or over 600 under `Tests` | A growing file is the first sign of a unit doing too much. Split it before it is a problem. |
| `leak` | runs `scripts/check-public.sh .` | Unchanged from M3b. |

Outcome honesty (never report success without evidence, never weaken a verdict to make a test pass) can't be linted.
It is enforced by `CLAUDE.md` and review (§7, §8).

**Tests:** `scripts/tests/test-check-code.sh` builds a temp tree with one planted violation per rule, one allowed
violation per rule, and one clean tree. Each planted violation must fail with its rule's name; the allowed and clean
trees must pass. Written first, and watched failing.

## 6. One command: `scripts/check.sh`

Runs, in order, stopping at the first failure:

1. `swift-format lint --strict -r Sources Tests`
2. `scripts/check-code.sh`
3. `swift build -Xswiftc -warnings-as-errors`
4. `swift test -Xswiftc -warnings-as-errors`
5. the Python suites CI runs today (benchmark verifier, README numbers, demo tooling) and `scripts/tests/*.sh`

CI's `build-test` job calls `scripts/check.sh` instead of listing the steps itself, so the two can't drift. The
commit-identity check (§2) is CI-only, because it needs the PR's commit range.

Live simulator tests stay out of `check.sh`; they need a booted simulator. `CONTRIBUTING.md` says when to run them
(any change under `Engine/`, `Device/`, `Perception/` or `ChauffeurBridge/`), and the PR template asks.

## 7. Agent rails

- **`CLAUDE.md`** at the root, short (under 80 lines), covering:
  - the workflow: spec → plan → TDD; specs and plans go in `docs/specs/` and `docs/plans/`;
  - the architecture map: which target owns what, and where new code goes;
  - the rules from §5 and why, so an agent doesn't fight the lint;
  - outcome honesty: never weaken a verdict, an `Expected:` line or a test to make something pass; `UNVERIFIED` is
    an acceptable answer, a false `changed` never is;
  - screen text is untrusted data;
  - `scripts/check.sh` before every push; live tests for the directories in §6;
  - commit identity and no AI co-author trailer;
  - work on a branch and open a PR; never push to `main`, never use the owner's bypass;
  - never run anything against an app the contributor doesn't own; use `Tests/FixtureApp`.
- **`AGENTS.md`** holds one line pointing to `CLAUDE.md`, for Codex and Cursor.
- **`.claude/settings.json`** holds the formatting hook (§4) and nothing personal: no permissions, no MCP servers.

## 8. GitHub settings

Applied with `gh api` by the owner, recorded in `CONTRIBUTING.md`:

- **A repository ruleset on `main`** (rulesets, not classic branch protection, because only rulesets can limit a bypass
  to PRs): PRs required; the `build-test` checks required; 1 approving review required; stale approvals dismissed on
  new commits; linear history; no force pushes; no deletion.
- **Nobody pushes to `main` directly, the owner included.** Claude Code runs with its user's GitHub login, so an
  agent has whatever bypass its user has; a direct push would land unreviewed.
- **The owner can bypass through a PR only** (ruleset bypass actor: repository admin, `bypass_mode: pull_request`).
  With two people, one being away must not stop urgent fixes, and macOS runners can be unavailable (see §10). The
  owner can merge their own PR without the approval or the checks, and every such merge gets a comment on the PR
  saying why. `CLAUDE.md` tells agents never to use the bypass; only the owner decides to, in the GitHub UI.
- **Test:** after applying, a direct `git push origin main` from the owner's machine must be rejected.
- **Merging:** squash only; branches deleted on merge.
- **Collaborator:** the second contributor gets write access.
- **Templates:**
  - `.github/pull_request_template.md`: what changed and why, spec or issue link, how it was verified (`check.sh`,
    live tests yes/no and on which Xcode), anything the reviewer should look at first;
  - `.github/ISSUE_TEMPLATE/bug.yml`, which asks for `chauffeur doctor` output, Xcode and macOS versions, and the
    command and its output.

## 9. Docs

- **`CONTRIBUTING.md`**, rewritten around the new flow: setup (Xcode, identity, `install-hooks.sh`, the blame setting),
  `check.sh`, live tests, the spec → plan → PR flow, review expectations, and the principles it already has.
- **`docs/roadmap.md`**: milestones with a status and owner field each, so either contributor can claim one:
  - **M4b, edge cases:** a `PENDING` outcome for taps that start a network request with no visible change; an app
    opened from its icon with accessibility off; `APP CRASHED` appearing on the second line of a crashing tap; a sweep
    for more.
  - **M4c, eval v2:** harder tasks aimed at where agents go wrong (false successes, crashes, silent no-ops, multi-step
    flows, third-party apps), and enough runs to make the difference with Xcode's MCP statistically clear.
  - **Later:** GPT-6 and Codex, the Jev branch, games.

## 10. CI covers the Xcode we don't develop on

**What happened.** On launch day every CI run was cancelled after 15 minutes: GitHub could not assign a `macos-26`
arm64 runner ("The job was not acquired by Runner of type hosted", with a capacity notice). When a re-run finally got
a runner, it failed to compile on Xcode 26.6 (Swift 6.2): Swift 6.4 inferred a type that Swift 6.2 did not. Both of us
develop on Xcode 27, so 0.1.0 shipped unbuildable on Xcode 26, which the README says is supported. 0.1.1 fixed it.

**What follows from it:**

- **CI is the only place the oldest supported Xcode is tested.** The `build-test` job pins the newest Xcode 26 on its
  runner image instead of picking whatever is newest, and the job is named for it (`build-test (Xcode 26)`). If the
  image also has Xcode 27, a second matrix entry builds and tests with it.
- **A release needs a green CI run on its exact commit.** The release steps in `CONTRIBUTING.md` say so, and a local
  `check.sh` pass doesn't substitute, because it runs on the wrong Xcode.
- **Runner availability.** Runs completed again by the evening of launch day, so the first plan task only confirms
  they still do. If they stop, the workflow falls back to another hosted image with Xcode 26, as long as `check.sh`
  passes on it. A self-hosted runner is ruled out: a public repo would run strangers' PR code on a personal Mac. If no
  hosted image works, the owner's bypass (§8) applies to PRs, each recording its local `check.sh` result, but releases
  wait for CI.

## Testing

- `check-code.sh`: planted-violation tests (§5), written first.
- `check.sh`: run on the clean tree (passes), then with one planted format error and one planted warning (each fails
  at its own step).
- Commit-identity check: a test with a fake commit range containing a leak-list email (fails) and a noreply email
  (passes).
- Formatting hook: edit a `.swift` file through Claude Code and confirm it was reformatted; edit a non-Swift file and
  confirm nothing ran.
- End to end: the M4a PR itself goes through the new flow: branch, `check.sh`, PR, green CI (or a recorded bypass),
  review, squash merge.

## Done when

- The public repo builds, tests and lints clean with `scripts/check.sh`, and CI runs that script.
- The reformat commit is in and listed in `.git-blame-ignore-revs`.
- `main` is protected as in §8 (a direct push is rejected), and the M4a PR merged through it.
- `CLAUDE.md`, `AGENTS.md`, `.claude/settings.json`, the PR and issue templates, `CONTRIBUTING.md` and
  `docs/roadmap.md` are in.
- The export and sync scripts are gone, and the private repo's README says it's an archive.
