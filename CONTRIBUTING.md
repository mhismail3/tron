# Contributing to Tron

Tron is a personal-scale project. This guide is short on purpose: it covers
exactly what you need to make a green PR.

## TL;DR

```bash
git clone <repository-url>
cd tron
scripts/install-hooks.sh                                           # one-time
scripts/tron ci test                                               # Rust baseline
```

Open a PR against `main`. CI always runs the personal-info/version guards and
the Rust quality path, then runs the full iOS or Mac jobs when their source
paths or labels apply. Fill out
the PR template — the checklist exists because `README.md` and the in-tree
progressive-disclosure docs drift fast.

## Project layout

```
packages/
  agent/      Rust server (cargo workspace member)
  ios-app/    SwiftUI iOS app (XcodeGen)
  mac-app/    SwiftUI macOS wrapper and server installer
scripts/      Bash entrypoints — `tron`, `install-hooks.sh`, `personal-info-guard.sh`
```

The root `README.md` is the concise project front door. Detailed cross-cutting
behavior lives in `packages/agent/docs/project-reference.md`, while module and
client architecture lives beside its source. The maintenance map in `AGENTS.md`
identifies the right owner for each kind of change.

## Development workflow

Tron uses a **takeover model**: a long-running production server lives inside
`/Applications/Tron.app` and is registered through ServiceManagement. When you
run `tron dev`, the dev binary takes over port 9847 from the prod server until
you stop it. The command completes exactly one dev-profile build before it
stops the installed helper; `-b` places that build before optional `-t` tests,
while without `-b` the tests run first.

```bash
# One-time setup (checks prerequisites, builds, and links the workspace CLI).
scripts/tron setup

# Build and run the dev server in the foreground (takeover mode).
scripts/tron dev

# Same, but background — useful for iterating in another shell.
scripts/tron dev --background
scripts/tron dev --stop
```

You should never need to run `scripts/tron deploy` or any production
deployment command — those are manual-only and reserved for the maintainer.
Use `tron dev` for everything.

Before a storage migration or risky local-state experiment, create and verify
an owner-only profile archive with `scripts/tron state snapshot`. List or
verify archives with `scripts/tron state snapshots` and
`scripts/tron state verify <archive>`. `scripts/tron state restore <archive>`
requires the server to be stopped and preserves replaced state in a dated
recovery directory.

### iOS

```bash
cd packages/ios-app
xcodegen generate
open TronMobile.xcodeproj
# or: xcodebuild test -scheme 'Tron Beta' -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

Every successful main-branch CI push is published to the private automatic
internal TestFlight group for App ID `6761511764`. Release tags independently
advance selected builds through the public TestFlight path; contributor PRs do
not deploy and do not need App Store Connect access.

### Mac wrapper

The Mac SwiftUI wrapper lives at `packages/mac-app/`. It's a SwiftUI app that
bundles the headless Rust agent inside helper apps under
`Contents/Library/LoginItems/Tron Server*.app/Contents/MacOS/tron` and presents
a first-run wizard + menu bar icon. Debug builds `TronMac.app` with bundle ID
`com.tron.mac.dev` in DerivedData. Release overrides the product name to build
`Tron.app` with bundle ID `com.tron.mac` and ships it in a notarized DMG. This
is wholly separate from `tron dev`'s headless agent at
`~/.tron/internal/run/Tron-Dev.app` (`com.tron.agent`) — see
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

CI exercises the same flow on every PR that touches `packages/mac-app/**`,
`packages/agent/**`, or `release-mac.yml` (the agent binary is embedded, so a
Rust change affects the Mac app bundle). The iOS and Mac `project.yml` files are
authoritative; CI generates their ignored Xcode projects before building. It
also runs focused non-flaky wrapper tests for paths/status/Tailscale coverage
before packaging. PR CI and `release-mac.yml` both delegate DMG assembly and
mounted-image verification to `packages/mac-app/scripts/package-dmg.sh`.
Missing apps, failed packaging, empty images, or images without the wrapper,
helper, and `Applications` link fail the job.

## Testing

Project rule: **code, tests, and docs ship together**. Reuse existing tests for
the changed owner; add or update tests when behavior changes or a genuine
coverage gap exists.

| Surface | Command |
|---------|---------|
| Rust agent | `scripts/tron ci test` |
| iOS app | `cd packages/ios-app && xcodegen generate && xcodebuild test -scheme 'Tron Beta' -destination 'platform=iOS Simulator,name=iPhone 17 Pro'` |
| Mac wrapper | `cd packages/mac-app && xcodegen generate && xcodebuild test -project TronMac.xcodeproj -scheme TronMac -destination 'platform=macOS' -configuration Debug` |
| Personal-info guard | `scripts/personal-info-guard.sh` |
| Rust commit milestone | `scripts/tron ci fmt check clippy test` |

CI runs `scripts/tron ci fmt`, `check`, `clippy`, and `test` as its one Rust
quality path for every repository change. Cargo's default auto-discovery of
top-level `packages/agent/tests/*.rs` files owns the integration-target fact
set. The test command derives that set from the same source layout, runs each
target once in deterministic order, and reserves `integration` for the final
serial invocation. The
[repository workflow invariant](packages/agent/tests/repository_workflow_invariants.rs)
compares that schedule with Cargo and verifies GitHub delegates to this local
owner. The same invariant owns generated-project hygiene by requiring iOS and
Mac XcodeGen output to stay ignored and untracked; client workflows own project
generation and the consuming builds, tests, and archives. On pull requests,
iOS and Mac jobs run for their package paths, their release workflows, or
relevant labels. Both run on `main` and manual dispatch. `CI summary` requires
successful change detection and all unconditional jobs; it accepts a skipped
client job only on a successfully path-filtered pull request.

The path classifier is repository-owned `scripts/ci-change-flags.sh`; its
offline self-test prevents workflow behavior from depending on a mutable
third-party filtering action. Apple/release versions live only in
`config/ci-toolchain.env`. CI downloads exact XcodeGen, create-dmg, and ASC
artifacts, verifies their SHA-256 values, and checks Xcode, the iOS runtime, and
simulator identity before building. Update the manifest and its invariant tests
in the same PR when a toolchain moves.

`performance.yml` runs a daily advisory 100-sample server benchmark and uploads
raw samples plus git/Python/runner provenance. It does not block deployment
until a stable runner and calibrated baseline are deliberately promoted. The
offline whole-agent acceptance catalog is checked with
`python3 scripts/evaluation/whole-agent.py --self-test`; external runners may
evaluate normalized evidence without adding evaluation behavior to the engine.

Every external GitHub Action is pinned to a full commit SHA, and container
actions are pinned to an OCI digest. Keep the readable release line in the
trailing comment (for example, `# v4`). Dependabot remains the update owner;
its PR must move the immutable revision and pass the same aggregate gate. A
repository invariant scans every workflow so mutable action tags cannot enter
through CI or either release lane.

## Commits

We follow [Conventional Commits](https://www.conventionalcommits.org/) loosely:

```
feat(worker): add bounded recent-research runner
fix(events): preserve session ownership during reconstruction
docs(storage): clarify resource cleanup ownership
ci: fail closed when path detection fails
```

Common types: `feat`, `fix`, `refactor`, `docs`, `test`, `chore`, `ci`, `style`.
Common scopes mirror the touched module (`tool`, `events`, `ios-session`,
`mac-wizard`, `scripts`, `cargo`).

The pre-commit hook (`scripts/install-hooks.sh`) runs Rust formatting check
(`cargo fmt --all -- --check`) when staged Rust files change, then runs
`scripts/personal-info-guard.sh --staged` before each commit. It catches both
Rust formatting drift and hardcoded usernames, home paths, and
developer-machine identifiers from sneaking into source.

`main` is protected by the repository ruleset: changes enter through a pull
request whose branch is current with `main`, and the single required `CI
summary` check must pass. Local hooks are an early feedback layer, not a
substitute for that remote merge boundary.

## Code style

- **Rust**: `cargo fmt` (config in `rustfmt.toml` if present, otherwise
  defaults), `cargo clippy --all-targets`. `scripts/tron ci` and GitHub both
  deny emitted warnings; the Cargo lint policy keeps broad style/pedantic
  suggestions disabled while enforcing correctness and configured Rust lints.
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
- Hardcoded GitHub handles, personal domains, or maintainer-specific release
  URLs. Use generic placeholders, local config, CI secrets, or runtime
  configuration.
- Encoded forms of the same (`-Users-<my-username>-…` from Claude-Code-style paths).

User-specific values belong in runtime state outside the repository. Worker-owned
secrets go through `~/.tron/workspace/vault/`; Tron-owned provider and transport
credentials live in `~/.tron/auth.json`. Never paste secrets anywhere in the tree.

Notification transport selection and relay HMAC credentials use the typed
`notification-push` auth entry. Use
`scripts/tron auth notifications configure-relay`, `status`, `use`, and
`clear-relay`; the CLI must report only mode/readiness, never the URL or secret.
Direct APNs provider credentials remain in the typed `apple-push` entry and are
managed with `scripts/tron auth apns`. Device tokens are runtime transport data
and must never appear in source, tests, logs, diagnostics, or CLI output.

The Cloudflare relay in `packages/relay` is prepared and validated locally with
`npm run check` and `npm test`. Its deployment and secret configuration are
manual operations. Never deploy it, or run any production deployment command,
as part of automated contributor validation.

Tests that need identity-shaped data must use synthetic, nonpersonal fixtures;
personal literals are not allowlisted into the repository.

## Documentation

Three layers, each with a distinct job:

1. **Root `README.md`** — concise product and developer entry point. It should
   not contain generated catalogs, source trees, audit histories, or release
   runbooks.
2. **Technical reference and client docs** —
   `packages/agent/docs/project-reference.md` owns cross-cutting server details;
   package architecture guides own iOS and Mac details.
3. **Progressive disclosure** — every Rust module has a `mod.rs` doc block
   with a submodule table and key invariants. Every meaningful change should
   leave the surrounding module's `mod.rs` slightly better documented than
   you found it. iOS uses the architecture and development docs under
   `packages/ios-app/docs/` for the same pattern.

Drift is the enemy. Update the narrowest owning document; only change the root
README when the product-level story, supported setup, or primary workflow
changes.

## Releasing

Three distribution lanes:

| What | How | Cadence |
|---|---|---|
| iOS internal TestFlight | A successful `CI` workflow for a `main` push triggers `release-ios.yml` for the exact tested SHA. It archives the `Tron` / `Prod` app, uploads it with the workflow's monotonic Apple build number, and waits until the configured all-build internal group can install it. | Every green main push. |
| iOS public TestFlight | Tag `server-v0.1.0-beta.1`-style versions on a green main commit. The same workflow submits Beta App Review when required and assigns externally-ready builds to the public group. | Same tag as server release. |
| Server DMG to GitHub Releases | The same tag triggers `release-mac.yml`, which builds and notarizes the macOS DMG, creates a draft release when absent, or refreshes assets on an existing release without changing its publish state. | Same tag as iOS release. |

Versioning sources:
- **Source of truth** — root `VERSION.env`. `TRON_VERSION` is canonical
  SemVer, `TRON_APPLE_BUILD` is the checked-in local/Mac Apple build, and
  `TRON_DISPLAY_VERSION` is the human-facing label. Hosted iOS TestFlight
  delivery overrides `CFBundleVersion` with the existing workflow's monotonic
  `GITHUB_RUN_NUMBER`; internal, public, and rerun uploads share that owner.
- **Generated mirrors** — `packages/agent/Cargo.toml`, `packages/agent/Cargo.lock`,
  Mac/iOS `project.yml`, and custom `TRONCanonicalVersion` bundle keys.
  Run `scripts/tron version sync` after editing `VERSION.env`; CI runs
  `scripts/tron version check` to prevent drift.

### Cutting a beta release

```bash
# 1. Confirm main is green.
git checkout main && git pull && git log -1 --oneline

# 2. Set VERSION.env, then sync generated mirrors.
# Use `scripts/tron version bump beta` first when advancing to the next beta.
scripts/tron version sync

# 3. Commit the bump and tag.
git commit -am "chore(release): bump Tron version"
git tag "$(scripts/tron version print | awk -F= '$1 == "TRON_RELEASE_TAG" { print $2 }')"
git push && git push --tags

# 4. Tag push starts both release workflows:
#    - release-mac.yml: build → codesign → app notarize/staple → DMG
#      build/sign/notarize/staple → create a draft or refresh existing assets
#      without changing the release's publish state.
#    - release-ios.yml: archive Prod iOS app → export/sign App Store IPA →
#      upload to App Store Connect → wait for processing → resolve export
#      compliance / beta review → either stop as pending Apple review or assign
#      to the public TestFlight group. The green main commit already triggered
#      its independent internal TestFlight build.
#    Verify the generated GitHub release notes, DMG artifact, SHA256 manifest,
#    and TestFlight build before announcing the release.

# 5. To test the pipeline without cutting a real release, use
#    Actions → Release (Mac DMG) with dry_run=true and Actions → Release (iOS
#    TestFlight) with channel=dry-run. The iOS workflow also exposes internal
#    and external manual recovery channels, both restricted to main. Live runs
#    fail before the build when a required release secret is missing.
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

**GitHub Actions variables** for iOS TestFlight group assignment:

| Variable | What |
|---|---|
| `ASC_TESTFLIGHT_INTERNAL_GROUP_ID` | Required all-build internal TestFlight group id for automatic main delivery |
| `ASC_TESTFLIGHT_PUBLIC_GROUP_ID` | Existing public TestFlight group id behind the onboarding QR link; CI can auto-discover a single public-link group |

Rotate by regenerating the relevant `.p12` or profile, re-encoding
(`base64 -i Tron.p12 | pbcopy`), or by creating a new App Store Connect API key
and updating the corresponding secret in GitHub -> Settings -> Secrets and
variables -> Actions. If the iOS signing secrets are absent, CI falls back to
automatic Xcode cloud signing, which requires the ASC key/account to have
permission to manage App Store signing assets. The local signing lane accepts
matching manually managed profiles or matching Xcode-managed App Store profiles.
It rejects expired profiles and warns during their final 30 days. Because a
profile cannot outlive its selected distribution certificate, rotate the Apple
Distribution certificate, `.p12`, and both profile secrets together before the
earliest expiration; the TestFlight group setup does not need to be repeated.
The iOS app and share extension declare `ITSAppUsesNonExemptEncryption=false`;
revisit that release assertion before adding non-exempt cryptography.

**Rollback a bad server release**: `gh release delete <release-tag>` removes
the release assets. Existing installs are unaffected because they do not
auto-pull deletions. Cut a fixed release at the next beta or patch version.

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
