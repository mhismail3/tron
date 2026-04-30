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

Beta TestFlight builds are published by the tag-triggered iOS release workflow
for App ID `6761511764`; contributor PRs do not need App Store Connect access.

### Mac wrapper

The Mac SwiftUI wrapper lives at `packages/mac-app/`. It's a SwiftUI app that
bundles the headless Rust agent as `Contents/Resources/tron-agent` and presents
a first-run wizard + menu bar icon. Both Debug and Release configurations
build `TronMac.app` (the bundle name follows the XcodeGen target); Debug uses
bundle ID `com.tron.mac.dev` (lives in DerivedData), Release uses
`com.tron.mac` and ships as a notarized DMG (`Tron.app` to the end user). This
is wholly separate from `tron dev`'s headless agent at
`~/.tron/system/deployment/Tron-Dev.app` (`com.tron.agent`) — see
[`packages/mac-app/docs/architecture.md` → Workflows & Variants](packages/mac-app/docs/architecture.md#workflows--variants).

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

The pre-commit hook (`scripts/install-hooks.sh`) runs Rust formatting check
(`cargo fmt --all -- --check`) when staged Rust files change, then runs
`scripts/personal-info-guard.sh --staged` before each commit. It catches both
Rust formatting drift and hardcoded usernames, home paths, and
developer-machine identifiers from sneaking into source.

## Code style

- **Rust**: `cargo fmt` (config in `rustfmt.toml` if present, otherwise
  defaults), `cargo clippy --all-targets`. CI fails on high-signal lint classes
  configured in `packages/agent/Cargo.toml`; broad style/pedantic suggestions
  remain advisory.
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
| iOS Beta to TestFlight | Tag `server-v0.1.0-beta.1`-style versions on a green main commit. CI workflow `release-ios.yml` archives the `Tron` / `Prod` iOS app, exports an App Store Connect IPA with automatic cloud signing or configured local signing secrets, uploads to App ID `6761511764`, waits for processing, verifies the internal group has all-build access, and assigns the build to the public TestFlight group. | Same tag as server release. |
| Server DMG to GitHub Releases | The same tag triggers `release-mac.yml`, which builds + notarizes + attaches the macOS DMG as a draft `Tron Server ...` pre-release with generated changelog notes. | Same tag as iOS release. |

Versioning sources:
- **Source of truth** — root `VERSION.env`. `TRON_VERSION` is canonical
  SemVer (`0.1.0-beta.1`), and `TRON_APPLE_BUILD` is the numeric Apple
  build. Human-facing surfaces format that first beta as `v0.1 (Beta 1)`.
- **Generated mirrors** — `packages/agent/Cargo.toml`, `packages/agent/Cargo.lock`,
  Mac/iOS `project.yml`, and custom `TRONCanonicalVersion` bundle keys.
  Run `scripts/tron version sync` after editing `VERSION.env`; CI runs
  `scripts/tron version check` to prevent drift.

### Cutting a beta release

```bash
# 1. Confirm main is green.
git checkout main && git pull && git log -1 --oneline

# 2. Set VERSION.env, then sync generated mirrors.
# For the first beta this is already 0.1.0-beta.1; subsequent betas can use
# `scripts/tron version bump beta`.
scripts/tron version sync

# 3. Commit the bump and tag.
git commit -am "chore(release): Tron v0.1 (Beta 1)"
git tag "$(scripts/tron version print | awk -F= '$1 == "TRON_RELEASE_TAG" { print $2 }')"
git push && git push --tags

# 4. Tag push starts both release workflows:
#    - release-mac.yml: build → codesign → app notarize/staple → DMG
#      build/sign/notarize/staple → GitHub Release draft.
#    - release-ios.yml: archive Prod iOS app → export/sign App Store IPA →
#      upload to App Store Connect → wait for processing → assign to
#      internal + public TestFlight groups.
#    Verify the generated GitHub release notes, DMG artifact, SHA256 manifest,
#    and TestFlight build before announcing the release.

# 5. To test the pipeline without cutting a real release, use
#    Actions → Release (Mac DMG) and Actions → Release (iOS TestFlight)
#    with `dry_run=true`. Missing release secrets auto-force dry-run, so
#    forks can exercise the build without the Apple credentials.
```

**Required GitHub Actions secrets** for notarized releases:

| Secret | What |
|---|---|
| `MACOS_CERT_P12_BASE64` | base64-encoded Developer ID Application `.p12` |
| `MACOS_CERT_PASSWORD` | password protecting the `.p12` |
| `NOTARIZE_APPLE_ID` | Apple ID email for `notarytool` |
| `NOTARIZE_TEAM_ID` | Apple Developer team ID |
| `NOTARIZE_APP_PASSWORD` | app-specific password for the Apple ID |
| `ASC_KEY_ID` | App Store Connect API key id for iOS upload/distribution |
| `ASC_ISSUER_ID` | App Store Connect API issuer id from Users and Access -> Integrations -> App Store Connect API -> Team Keys |
| `ASC_KEY_P8_BASE64` | base64-encoded App Store Connect API private key; locally, `asc auth doctor` shows the active `.p8` path when `asc` is already configured |
| `IOS_DISTRIBUTION_CERT_P12_BASE64` | Optional but recommended for iOS CI signing: base64-encoded Apple Distribution `.p12` |
| `IOS_DISTRIBUTION_CERT_PASSWORD` | Password for `IOS_DISTRIBUTION_CERT_P12_BASE64` |
| `IOS_APPSTORE_PROFILE_BASE64` | App Store Connect distribution profile for `com.tron.mobile` |
| `IOS_SHARE_EXTENSION_APPSTORE_PROFILE_BASE64` | App Store Connect distribution profile for `com.tron.mobile.ShareExtension` |

**Required GitHub Actions variables** for iOS TestFlight distribution:

| Variable | What |
|---|---|
| `ASC_TESTFLIGHT_INTERNAL_GROUP_ID` | Existing internal TestFlight group id |
| `ASC_TESTFLIGHT_PUBLIC_GROUP_ID` | Existing public TestFlight group id behind the onboarding QR link |

Rotate by regenerating the relevant `.p12` or profile, re-encoding
(`base64 -i Tron.p12 | pbcopy`), or by creating a new App Store Connect API key
and updating the corresponding secret in GitHub -> Settings -> Secrets and
variables -> Actions. If the iOS signing secrets are absent, CI falls back to
automatic Xcode cloud signing, which requires the ASC key/account to have
permission to manage App Store signing assets. The local signing lane accepts
matching manually managed profiles or matching Xcode-managed App Store profiles.

**Rollback a bad server release**: `gh release delete server-v0.1.0-beta.1` pulls the DMG.
Existing installs are unaffected (they don't auto-pull deletions). Cut a fixed
release at the next beta or patch version.

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
