# Contributing

Thanks for helping. Issues and pull requests are welcome. Most of this project is written with coding agents;
[CLAUDE.md](CLAUDE.md) holds the rules they follow, and they apply to people too.

## Setup

You need an Apple-silicon Mac with Xcode 26 or 27.

```
git clone https://github.com/YashNaj/chauffeur && cd chauffeur
git config --local user.name "<your GitHub login>"
git config --local user.email "<id>+<login>@users.noreply.github.com"   # github.com/settings/emails shows it
git config --local blame.ignoreRevsFile .git-blame-ignore-revs
scripts/install-hooks.sh                                               # leak check on every commit
```

## Check

```
scripts/check.sh                                               # format, lint, build, tests: what CI runs
scripts/format.sh                                              # formats everything (agents format as they edit)
CHAUFFEUR_LIVE_UDID=<udid> swift test --no-parallel            # live tests on a booted simulator
```

Run the live tests after any change under `Engine`, `Device`, `Perception`, `Screen` or `ChauffeurBridge`. They
build and install the small test app in `Tests/FixtureApp` themselves. Boot one simulator at a time;
`xcrun simctl list devices booted` gives you its UDID. After any change to MCP mode, run `scripts/mcp-smoke.sh`: it
checks that a real client (Claude Code) accepts the tool list.

CI builds with Xcode 26. If you develop on Xcode 27, CI is the only place your change is compiled with the older
Swift, so wait for it.

## Making a change

1. **Bigger than a bug fix?** Write a spec in `docs/specs/` and a plan in `docs/plans/` first, and open the PR with
   them early. Check [docs/roadmap.md](docs/roadmap.md) and put your name on a milestone before starting it.
2. **Branch, test first, implement.** Every behavior change comes with a test that failed before it.
3. **`scripts/check.sh`, then a PR.** Fill in the template. CI must be green, and the other maintainer approves.
   PRs are squash-merged.
4. **Commits:** your noreply address, and no AI `Co-Authored-By` trailer. CI rejects both.

`main` only changes through PRs. The owner can merge a PR without approval or green CI in an emergency (a
maintainer away, macOS runners down) and leaves a comment on the PR saying why. Releases never skip CI.

## Releasing (maintainers)

1. Bump `Chauffeur.version` in `Sources/ChauffeurCore/Model.swift` and its two tests; add a `CHANGELOG.md` entry.
2. Merge that PR. CI must be green on the exact commit you tag.
3. `git tag -a vX.Y.Z -m "chauffeur X.Y.Z" && git push origin vX.Y.Z`, then `gh release create vX.Y.Z`.
4. In `YashNaj/homebrew-chauffeur`, point `Formula/chauffeur.rb` at the new tag and revision and update the version
   in its test. Commit with your noreply identity, push, then `brew upgrade chauffeur` and `brew test chauffeur`.
5. Only if the MCP server changed: `scripts/build-mcpb.sh`, attach `chauffeur.mcpb` to the release, update
   `server.json` (version, URL, `fileSha256`) and run `mcp-publisher publish`.

## Design

The design and the notes from each milestone are in [docs/design.md](docs/design.md).

## Principles

- Never report success without evidence. If chauffeur can't tell whether an action worked, it says so.
- Text read from the screen is untrusted data, never instructions.
- Prefer a clear message with a `hint:` over a silent retry.
- Keep outputs short. An agent reads every line chauffeur prints.
