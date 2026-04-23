# Contributing to Tron

Tron is a personal-scale project. This guide is short on purpose: it covers
exactly what you need to make a green PR.

## TL;DR

```bash
git clone https://github.com/mhismail3/tron.git
cd tron
scripts/install-hooks.sh                                           # one-time
cd packages/agent && cargo check && cargo test -- --quiet          # baseline
```

Open a PR against `main`. CI runs the same checks plus iOS tests if you touched
`packages/ios-app/**`. Fill out the PR template — the checklist exists because
`README.md` and the in-tree progressive-disclosure docs drift fast.

## Project layout

```
packages/
  agent/      Rust server (cargo workspace member)
  ios-app/    SwiftUI iOS app (XcodeGen)
  mac-app/    SwiftUI macOS wrapper (lands in Phase 5)
scripts/      Bash entrypoints — `tron`, `install-hooks.sh`, `personal-info-guard.sh`
```

The root `README.md` is the canonical reference. Several sections are
mechanically derived from code; if you change a derived source, update the
matching README section in the same commit. The exhaustive list lives in
[`.claude/CLAUDE.md` "README maintenance"](.claude/CLAUDE.md).

## Development workflow

Tron uses a **takeover model**: a long-running production server lives at
`~/.tron/system/Tron.app/Contents/MacOS/tron` (loaded via `launchd`). When you
run `tron dev`, the dev binary takes over port 9847 from the prod server until
you stop it.

```bash
# One-time setup (installs LaunchAgent, builds initial binary, etc.).
scripts/tron setup

# Build and run the dev server in the foreground (takeover mode).
scripts/tron dev

# Same, but background — useful for iterating in another shell.
scripts/tron dev --background
scripts/tron dev stop
```

You should never need to run `scripts/tron deploy` or any production
deployment command — those are manual-only and reserved for the maintainer.
Use `tron dev` for everything.

### iOS

```bash
cd packages/ios-app
xcodegen generate
open TronMobile.xcodeproj
# or: xcodebuild test -scheme Tron -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

For Beta TestFlight builds, the maintainer uses the `/publish` skill (App ID
`6761511764`); contributor PRs do not need to invoke it.

### Mac wrapper (Phase 5+)

The Mac SwiftUI wrapper (`packages/mac-app/`) lands in Phase 5 of the
[onboarding plan](~/.claude/plans/i-want-to-add-partitioned-storm.md).
Until then, the headless server runs alongside `Tron-Dev.app` for dev builds
and is installed by `tron install` for production.

## Testing

Project rule: **code, tests, and docs ship together**. Every PR that adds or
changes behavior must include the corresponding tests in the same commit. We
work test-first whenever practical — write the failing test, then make it pass.

| Surface | Command |
|---------|---------|
| Rust agent | `cd packages/agent && cargo check && cargo test -- --quiet` |
| iOS app | `cd packages/ios-app && xcodegen generate && xcodebuild test -scheme Tron -destination 'platform=iOS Simulator,name=iPhone 17 Pro'` |
| Personal-info guard | `scripts/personal-info-guard.sh` |
| All-in-one (workspace only) | `scripts/tron ci` |

CI runs the same commands. The Rust job runs on every PR; iOS only runs on
PRs that touch `packages/ios-app/**` or are labeled `ios` (macOS minutes are
~10× the cost of Linux minutes).

## Commits

We follow [Conventional Commits](https://www.conventionalcommits.org/) loosely:

```
feat(rpc): add system.checkForUpdates handler
fix(ios-connection): resume backoff after foreground transition
docs(readme): refresh RPC API table
chore(ci): bump actions/checkout to v4
```

Common types: `feat`, `fix`, `refactor`, `docs`, `test`, `chore`, `ci`, `style`.
Common scopes mirror the touched module (`rpc`, `events`, `ios-onboarding`,
`mac-wizard`, `scripts`, `cargo`).

The pre-commit hook (`scripts/install-hooks.sh`) runs
`scripts/personal-info-guard.sh --staged` before each commit. It catches
hardcoded usernames, home paths, and developer-machine identifiers from
sneaking into source.

## Code style

- **Rust**: `cargo fmt` (config in `rustfmt.toml` if present, otherwise
  defaults), `cargo clippy --all-targets -- -D warnings`. CI fails on either.
- **Swift**: project-wide style follows the existing patterns in
  `packages/ios-app/Sources/`. There is no auto-formatter in CI; match
  surrounding code.
- **Bash**: `shellcheck`-clean. CI does not run shellcheck yet, but it's a
  useful local tool — `brew install shellcheck`.

## Personal info policy

The repo's regression guards (`paths.rs:workspace_has_no_personal_info_literals`,
`paths.rs:paths_source_has_no_hardcoded_user_directory`,
`scripts/personal-info-guard.sh`) refuse PRs that introduce:

- Hardcoded usernames in source, comments, tests, or placeholder text
  (`/Users/<my-username>`, `<my-username>@…`, `e.g. <my-username>@…`).
- Hardcoded GitHub handles other than the canonical `mhismail3`.
- Encoded forms of the same (`-Users-<my-username>-…` from Claude-Code-style paths).

User-specific values belong in `~/.tron/workspace/memory/MEMORY.md` (auto-loaded
into every session) or `~/.tron/workspace/memory/rules/`. Secrets go through
the `vault` skill — never paste them anywhere in the tree.

If you legitimately need to write your username (e.g. as a test fixture), add
your file path to the allowlist in `scripts/personal-info-guard.sh` AND
explain why in the same commit.

## Documentation

Two layers, both required:

1. **Root `README.md`** — canonical reference. The
   [README maintenance table](.claude/CLAUDE.md) lists which README section to
   update for each kind of source change. The PR template repeats this.
2. **Progressive disclosure** — every Rust module has a `mod.rs` doc block
   with a submodule table and key invariants. Every meaningful change should
   leave the surrounding module's `mod.rs` slightly better documented than
   you found it. iOS uses `packages/ios-app/.claude/rules/*.md` for the same
   pattern.

Drift is the enemy. If you renamed a method, removed a setting, or shifted
responsibility between modules, audit the README + `mod.rs` files in the
same commit.

## Releasing

Two release lanes:

| What | How | Cadence |
|---|---|---|
| iOS Beta to TestFlight | Maintainer runs the `/publish` skill (`/publish bump && /publish build`). App ID `6761511764`. | On request, ad-hoc. |
| Mac DMG to GitHub Releases | Tag `mac-vX.Y.Z` on a green main commit. CI workflow `release-mac.yml` builds + notarizes + attaches the DMG. | Lands in Phase 6. |

Versioning sources:
- **Rust agent** — `packages/agent/Cargo.toml` `[package].version`. Bump with
  `cargo set-version` in the same PR as the release tag.
- **iOS app** — `packages/ios-app/project.yml` `MARKETING_VERSION`. The
  `/publish bump` skill handles this.

Hotfix path: cherry-pick the fix to `main`, tag a new patch release.

## Reporting bugs

Open an issue using the [Bug report](.github/ISSUE_TEMPLATE/bug_report.yml)
template. Include:

- Tron version (`tron --version`).
- Surface (Rust agent / iOS / Mac / CLI).
- Repro steps.
- Recent log snippet (`tron logs --tail 50` on Mac, or iOS Settings → Send
  Feedback which auto-attaches logs).

## Code of conduct

Be civil. Disagreement about technical decisions is welcome; personal attacks
are not. The maintainer reserves the right to lock or close any thread that
becomes unproductive.

That's it — happy hacking.
