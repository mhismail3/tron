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

Open a draft PR against `main` for lightweight feedback, then mark it ready to
run the authoritative Rust, iOS, and Mac merge-validation matrix. Fill out the
PR template — the checklist exists because `README.md` and the in-tree
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
# fast local loop: scripts/tron-ios-simulator iterate origin/main
```

A successful main-branch CI push is published to the private automatic internal
TestFlight group for App ID `6761511764` only while it remains the current main
head. Release tags independently advance selected builds through the public
TestFlight path; contributor PRs do not deploy and do not need App Store Connect
access. Hosted stable Xcode 26 CI proves the iOS 26 floor; an ephemeral
GitHub-hosted macOS 26 job archives the same source with the exact
App-Store-supported stable/RC Xcode pin and publishes sanitized provenance.
Beta Xcode builds are limited to direct physical-device development until Apple
accepts that toolchain for App Store Connect. Toolchain rotation is documented
in the iOS development guide.

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

Fast feedback runs repository guards plus Rust formatting on every pull
request, including drafts. Marking a PR ready runs `scripts/tron ci fmt`,
`check`, `clippy`, and `test` as its one Rust quality path and always validates
both Apple clients. Cargo's default auto-discovery of
top-level `packages/agent/tests/*.rs` files owns the integration-target fact
set. The test command derives that set from the same source layout, runs each
target once in deterministic order, and reserves `integration` for the final
serial invocation. Check, clippy, test, and documentation builds all use
`--locked`, so CI refuses a manifest change whose lockfile was not updated. The
[repository workflow invariant](packages/agent/tests/repository_workflow_invariants.rs)
compares that schedule with Cargo and verifies GitHub delegates to this local
owner. The same invariant owns generated-project hygiene by requiring iOS and
Mac XcodeGen output to stay ignored and untracked; client workflows own project
generation and the consuming builds, tests, and archives. `CI summary` is the
single fail-closed merge gate. A successful ready-PR run publishes evidence for
the exact synthetic merge tree. Its aggregate checkout stays at depth one and
reads the tree plus ordered parents directly from the raw commit object;
revision-walk formatting is not a provenance source because Git intentionally
hides parents at shallow boundaries. This keeps evidence generation independent
of a history fetch while still binding the stored merge object to the declared
base and head. The `main` run verifies that evidence and its
GitHub artifact digest before reusing it. Candidates are checked newest-first;
the first fully valid exact proof is selected, while missing, stale, malformed,
or tree-mismatched candidates are rejected and no valid proof automatically
runs the complete matrix again. Successful reuse preserves a self-digested
receipt, normalized evidence, and the byte-exact downloaded validation-artifact
ZIP for 90 days.
Artifact redirects are fetched from signed blob storage without forwarding the
GitHub bearer credential across origins.

The authoritative workflow coalesces and cancels only superseded runs for the
same pull request. Every `main` push and manual dispatch uses its run ID and
attempt in a unique concurrency group; this avoids GitHub's otherwise implicit
replacement of an older pending run and preserves complete main validation
history.

`config/ci-policy.json` is the provider-neutral statement of that validation
contract. GitHub Actions remains its only authoritative provider and `CI
summary` remains the protected check. The repository also contains an opt-in
Buildkite shadow pipeline that runs the same required workloads for ready PRs
and `main`, but it has no release lane, signing credentials, required status,
or permission to satisfy merge policy. `scripts/ci-provider-context.py`
normalizes provider metadata, proves Actions' exact
`refs/pull/<number>/merge` / `GITHUB_SHA` checkout against the event's ordered
base/head parents, pins the corresponding GitHub merge ref once for Buildkite,
and makes every Buildkite workload verify that pinned commit, tree, and parents
from a history-bounded,
prerequisite-excluding thin bundle proportional to the merge delta instead of
trusting a moving branch checkout. The pre-checkout bootstrap bytes must match
the merge's bootstrap and are carried into evidence. A bounded merge-ref fetch
retry tolerates both an unavailable ref and a still-old ref: Buildkite accepts
and detaches only the fetched object whose two parents exactly equal the
immutable webhook base/head. GitHub's webhook `merge_commit_sha` is nullable
and can lag ref regeneration, so both adapters schema-check it when present but
never use it as source authority. Main builds likewise require the webhook's
exact `before`/`after`
pair; neither path invents an absent base from Git history. The raw
provider-cached webhook is read ephemerally and is never uploaded. Normalized context preserves
the exact trigger action; an unsupported or substituted PR action fails before
work begins. `tron.validation.v2`
evidence binds that context to the policy,
pipeline configuration, toolchain, required jobs, iOS metrics, and artifact
SHA-256 manifest. Historical v1 remains parseable for audits only; current
main reuse and cross-provider parity both require v2.

The same policy inventories all six GitHub workflows, not merely the merge
matrix: required merge/main validation, PR fast feedback, server performance,
iOS performance, iOS/TestFlight release, and Mac release. Only merge-validation
has a candidate shadow today. The other five remain explicitly unimplemented,
and the replacement gate stays blocked until every inventory entry has a
feature-equivalent, independently verified owner. The policy also pins the
public iOS release identity—ASC app, app/share-extension bundle IDs, scheme,
and configuration—so delivery evidence for a different product cannot count.
Release channel names (`internal`, `external`, `public`) are distinct from
their latest-green-main or tag triggers; evidence may not conflate the two.

The shadow is deliberately inert until a maintainer connects the pipeline and
creates the hosted Linux and pinned M4 macOS queues documented in the
[Buildkite shadow runbook](.buildkite/README.md). It must remain advisory for
at least 30 days. The evaluator applies four separate minimums rather than one
combined count: 30 representative ready-PR source cohorts, 30 eligible `main`
pushes, 30 authenticated eligible TestFlight deliveries, and 30 successful
cross-provider parity samples. Compare downloaded GitHub and Buildkite evidence
with:

```bash
python3 scripts/ci-parity-report.py \
  --reference github-validation-evidence.json \
  --reference-artifacts github-validation-artifacts/ \
  --candidate buildkite-validation-evidence.json \
  --candidate-artifacts buildkite-validation-artifacts/ \
  --output ci-parity-report.json
```

Any source, tree, policy, job, toolchain, SDK, or test-result difference fails
closed. Parity comparison accepts v2 evidence only, requires the current
provider-specific configuration bindings, provider context, iOS metrics, and
all six Buildkite job manifests, and never compares the two providers'
configuration digests to each other. Both artifact arguments must be directories
containing the extracted provider downloads. The comparator safely resolves
every evidence-manifest path beneath its corresponding directory, rejects
traversal, symlinks, ambiguity, missing files, and reuse of one file for two
entries, and stream-verifies every evidence-level size and SHA-256. It then
binds the actual context and iOS payloads to evidence and semantically validates
the Buildkite job/bootstrap records against that context. Every successful job
manifest must structurally contain its exact job-local command log and provider
context path; the iOS manifest must contain the exact metrics path, and the PR
Mac manifest must contain `packages/mac-app/dist/Tron-dryrun.dmg`. The context
and metrics are content-bound through the aggregate evidence, while the nested
command-log and DMG payloads are not dereferenced because provider custody of
those files remains external to the shadow-evidence artifact.

This report proves only offline payload integrity and semantic parity. It does
not authenticate provider custody, artifact IDs, run conclusions, outages, or
API metadata—including custody of those nested job payloads; complete provider
API exports remain mandatory migration evidence. Runtime duration is measured
separately. Do not change the required check or release owner unless the shadow
meets the documented
latency and reliability budgets, proves the hardened release context in a
separate authorized exercise, and has an atomic rollback path. A provider
status page or a handful of green builds is not migration evidence.

The Buildkite provider must disable status publication, fork builds, tag
builds, the GitHub-specific `build_pull_request_merge_commits`
provider-generated PR merge checkout, and all queue secrets. The
source adapter owns exact merge-ref resolution anchored to the webhook's
immutable base/head pair. Enable both Skip Intermediate Builds and Cancel
Intermediate Builds with branch filter `!main`: superseded PR heads stop
consuming Apple minutes, while `main` retains complete history. The always-run,
soft-failing operational observer records all six post-bootstrap outcomes and
missing manifests even after workload failure. Provider API exports remain the
source of truth for source-bootstrap failures, canceled dependencies, outages,
missing triggers, retries, rebuild ancestry, and intentionally superseded
heads; rebuilds never count as new representative samples. Eligible events are
every non-draft PR-to-`main` source event for `opened`, `synchronize`,
`reopened`, and `ready_for_review`, including titles containing CI-skip tokens.
If Buildkite suppresses one before creating a build, the candidate record is
`missing`; the exporter may not omit it.
The reconciled token set is GitHub's five bracketed forms and two
`skip-checks` trailer spellings plus Buildkite's additional `[ci-skip]` and
`[skip-ci]` forms. Commit-message rules cannot prevent Buildkite from honoring
a skip token in a PR title, so independent webhook-to-build reconciliation and
the `skip-token-trigger-continuity` blocker remain mandatory.
Because the bootstrap itself comes from untrusted PR source and holds a scoped
agent session token, activation must also confine the pipeline to a dedicated
secretless hosted cluster containing only the documented Linux and Mac queues.
No release/self-hosted queue may be addressable from that cluster; YAML secret
rejection is defense in depth, not that external security boundary.

The provider settings attestation also requires PR, ready-for-review, reopened,
and `main` branch builds; disables skipping PRs for existing commits; and binds
the exact branch filters. It records Buildkite's API names directly, including
`trigger_mode: code`, `publish_commit_status`, `build_pull_requests`,
`build_pull_request_ready_for_review`, `build_pull_request_reopened`,
`branch_configuration`, `skip_queued_branch_builds`, and
`cancel_running_branch_builds`; provider-specific aliases are rejected.
Buildkite has no parity path for GitHub's manual
`workflow_dispatch`, so that remains an explicit full-replacement blocker.
Before the Buildkite app is connected, the protected-branch ruleset must bind
required context `CI summary` to GitHub Actions integration ID `15368`; a
context-only rule could be spoofed by another installed app. The normalized
ruleset export and the candidate's status-publication-disabled attestation are
both mandatory inputs. Do not mutate the live ruleset as part of advisory CI.

`scripts/ci-cutover-evaluation.py` strictly joins normalized trigger,
provider-run, independent-product, TestFlight, and provider-settings exports
plus the two controlled proof documents. Invoke `--help` for the complete
required input list. The current ledger and report schemas are
`tron.ci-cutover-observations.v2` and `tron.ci-cutover-evaluation.v2`; TestFlight
inputs use `tron.ci-testflight-export.v2`. V1 release observations are rejected
because they do not carry the complete per-`(run ID, run attempt)` eligibility,
intent, head-check, provenance, admission, reuse, and receipt history needed to
authenticate retries and interrupted delivery. The evaluator preserves every
trigger delivery but groups repeated actions for the same PR+source into one
representative cohort. It independently requires at least 30 such cohorts, 30
eligible main pushes, 30 authenticated eligible TestFlight deliveries, and 30
successful parity samples over a window of at least 30 days. It also enforces
p95 budgets, zero
false greens/source/product mismatches, candidate
provider failures at or below 1%, at least a two-percentage-point paired
reliability advantage, and a one-sided exact McNemar/binomial p-value at or
below 0.05. Superseded heads are recorded but excluded from representative
latency and reliability.

Offline normalized exports cannot authenticate their claimed provider API
responses. A passing report therefore says only
`observation-thresholds-satisfied-provenance-unverified`, sets
`eligible_for_external_review: false`, and requires live provider-API,
independent-product-evidence, and controlled-proof re-verification. It never
changes workflows, rulesets, credentials, required checks, or release
authority. Its blockers are read from the repository policy and include live
API/custody verification, fork and skip-token trigger continuity, manual
dispatch, fast-feedback and performance workflows, both TestFlight paths,
release tags, the candidate-main release handoff, and Mac release parity.
Every green-main/TestFlight row now joins both providers' exact main source,
product outcome, attempts, operational evidence, and end-to-end timing before
binding TestFlight to the authoritative GitHub run. This proves candidate main
validation parity, but not a Buildkite-main-to-GitHub-release handoff; that
remains the separate `candidate-main-release-handoff-parity` blocker.

The path classifier is repository-owned `scripts/ci-change-flags.sh`; fast
feedback reports its result without letting path filtering weaken the merge
gate. `scripts/ios-test-selection.py` conservatively powers local
`check-affected` and `iterate` loops: unmapped, test, project, or shared paths
fall back to the full iOS suite. Apple/release versions live only in
`config/ci-toolchain.env`. The same manifest pins the shadow Rust container
digest plus the actionlint container and checksum-pinned Buildkite parser
exercised by both providers.
`scripts/validate-ci-definitions.sh` runs actionlint and rejects Buildkite
secrets or parse warnings in both checked-in graphs. CI also downloads exact
XcodeGen, create-dmg, and ASC artifacts, verifies their SHA-256 values, and
checks Xcode, the iOS runtime, and simulator identity before building. Shared
tool downloads use bounded transient retries and publish into the cache only
after checksum verification, so a partial response cannot poison later runs. Update
the manifest and its invariant tests in the same PR when a toolchain moves.
These setup and verification scripts emit structured UTC records for downloads,
cache/prefix decisions, manifest hashes, validated definitions, and iOS
build/test phase timings. Keep those records secret-safe: never add `set -x`,
environment dumps, credential-bearing URLs, or signing material to CI logs.

`performance.yml` runs a daily advisory 100-sample server benchmark and uploads
raw samples plus git/Python/runner provenance. It does not block deployment
until a stable runner and calibrated baseline are deliberately promoted. The
weekly/manual `ios-performance.yml` compares serial and two-worker tests from
cold hosted runners. Its enumeration hash, result counts, and timing evidence
must remain identical across repeated pairs before parallelism is promoted;
the experiment is not a required check. Promotion requires ten clean paired
runs, no isolation/flake divergence, and a lower p95. A future DerivedData
cache must key Xcode, SDK, generated-project, configuration, source, and test
contracts; it stays off the required path until restore is under 60 seconds,
the artifact is under 2 GB, and p50 improves by at least 20% without behavioral
divergence. Target budgets are under two minutes for fast feedback, full merge
validation below five-minute p50/eight-minute p95, and green-main-to-internal-
TestFlight below seven-minute p50/ten-minute p95. The
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
| iOS internal TestFlight | A successful `CI` workflow for a `main` push triggers `release-ios.yml` for the exact tested SHA only while it remains the current `main` head. Intent-keyed concurrency serializes reruns of that upstream CI run without collapsing distinct commits. Attempt-unique eligibility, intent, provenance, head-check, ASC-admission, reuse, and completion evidence make delivery replay-safe; a completed intent skips the hosted release job. | Latest green main head. |
| iOS public TestFlight | Tag `server-v0.1.0-beta.1`-style versions on a green main commit. Run-ID-scoped direct intent, source-check, ASC-admission, reuse, and completion evidence make tag/manual retries replay-safe; the same workflow submits Beta App Review when required and assigns externally-ready builds to the public group. | Same tag as server release. |
| Server DMG to GitHub Releases | The same tag triggers `release-mac.yml`, which builds and notarizes the macOS DMG, creates a draft release when absent, or refreshes assets on an existing release without changing its publish state. | Same tag as iOS release. |

The iOS development runbook owns the exact hosted TestFlight image/toolchain,
credential lifecycle, App Store Connect evidence, and rotation procedure. The
release workflow log and retained provenance/diagnostic artifacts are the
canonical failure evidence; no developer Mac or custom launchd service is in
the delivery path.

Versioning sources:
- **Source of truth** — root `VERSION.env`. `TRON_VERSION` is canonical
  SemVer, `TRON_APPLE_BUILD` is the checked-in local/Mac Apple build, and
  `TRON_DISPLAY_VERSION` is the human-facing label. Automated iOS TestFlight
  delivery derives `CFBundleVersion` from the Release workflow's single
  monotonic run-number counter. Owner run `N` becomes
  `(1000 + floor(N / 100)).(N % 100).1` for automatic internal delivery; tag/manual
  delivery uses lane `.2`. The first automatic intent owns its allocation, and
  every retry authenticates and reuses that owner rather than allocating from a
  different workflow counter. A tag/manual run similarly owns its lane-2
  allocation for every rerun; an existing ASC build is reusable only through
  that direct run's durable admission chain.
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
#    and external manual recovery channels, both restricted to the exact current
#    main head at checkout and immediately before ASC. Live runs fail before the
#    build when a required release secret is missing.
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
