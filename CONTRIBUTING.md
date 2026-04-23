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

### Mac wrapper

The Mac SwiftUI wrapper lives at `packages/mac-app/`. It's a SwiftUI app that
bundles the headless Rust agent as `Contents/Resources/tron-agent` and presents
a first-run wizard + menu bar icon. Dev builds produce `Tron-Dev.app` (bundle
ID `com.tron.mac.dev`); release builds ship as a notarized DMG.

```bash
cd packages/mac-app
# Stage the agent binary from packages/agent/target/{debug,release}.
./scripts/bundle-agent.sh --profile debug

xcodegen generate
# Unit tests:
xcodebuild test \
  -project TronMac.xcodeproj \
  -scheme TronMac \
  -destination 'platform=macOS' \
  -configuration Debug
```

CI exercises the same flow on every PR that touches `packages/mac-app/**` or
`packages/agent/**` (the agent binary is embedded, so a Rust change affects
the Mac app bundle). PRs also run a dry-run DMG assembly to catch breakage
in `release-mac.yml` before tag push.

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
| Mac DMG to GitHub Releases | Tag `mac-vX.Y.Z` on a green main commit. CI workflow `release-mac.yml` builds + notarizes + attaches the DMG. | Ad-hoc. |

Versioning sources:
- **Rust agent** — `packages/agent/Cargo.toml` `[package].version`. Bump with
  `cargo set-version` in the same PR as the release tag.
- **iOS app** — `packages/ios-app/project.yml` `MARKETING_VERSION`. The
  `/publish bump` skill handles this.
- **Mac wrapper** — `packages/mac-app/project.yml` `MARKETING_VERSION`.

### Cutting a Mac DMG release

```bash
# 1. Confirm main is green.
git checkout main && git pull && git log -1 --oneline

# 2. Bump MARKETING_VERSION in packages/mac-app/project.yml.
#    Match Cargo.toml — the wrapper and the agent ship together.

# 3. Commit the bump and tag.
git commit -am "chore(release): Mac wrapper vX.Y.Z"
git tag mac-vX.Y.Z
git push && git push --tags

# 4. The release-mac.yml workflow runs: build → codesign → notarize →
#    staple → DMG → GitHub Release draft. Verify the DMG artifact + SHA256
#    manifest on the draft release, then click Publish in the GitHub UI.

# 5. To test the pipeline without cutting a real release, use
#    Actions → Release (Mac DMG) → Run workflow with `dry_run=true`.
#    Missing notarization secrets auto-force dry-run, so forks can
#    exercise the build without the Apple credentials.
```

**Required GitHub Actions secrets** for notarized releases:

| Secret | What |
|---|---|
| `MACOS_CERT_P12_BASE64` | base64-encoded Developer ID Application `.p12` |
| `MACOS_CERT_PASSWORD` | password protecting the `.p12` |
| `NOTARIZE_APPLE_ID` | Apple ID email for `notarytool` |
| `NOTARIZE_TEAM_ID` | Apple Developer team ID |
| `NOTARIZE_APP_PASSWORD` | app-specific password for the Apple ID |

Rotate by regenerating the `.p12`, re-encoding (`base64 -i Tron.p12 | pbcopy`),
and updating the secret in GitHub → Settings → Secrets and variables → Actions.

**Rollback a bad Mac release**: `gh release delete mac-vX.Y.Z` pulls the DMG.
Existing installs are unaffected (they don't auto-pull deletions). Cut a fixed
release at `mac-vX.Y.Z+1`.

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
