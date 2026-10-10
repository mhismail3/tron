# Contributing to Tron

Tron is a native iPhone interface and minimal Mac gateway for a private coding
agent. User-facing language calls the product and agent **Tron**. The embedded Pi
SDK may be named in technical implementation documentation, dependency work, and
source contracts, but not as a second user-facing product.

## Repository map

- `packages/gateway` — strict TypeScript gateway, protocol, supervision, tests
- `packages/ios-app` — SwiftUI iPhone app and share extension
- `packages/mac-app` — macOS installer/menu bar and gateway packaging
- `packages/push-relay` — closed product-operated App Attest/APNs transport
- `scripts/tron` — contributor command entry point
- `tools/work` — repository-agnostic GitHub work tracking for parallel agents,
  configured by `.github/work.json`

The custom Rust backend, Engine/Activity protocol, agent workers, event
journals and the SQLite session mirror, browser operator, and legacy notification delivery subsystem were
retired. Do not reintroduce their terminology or architecture through
compatibility wrappers. The current Cloudflare push relay is only a closed
installation registry, idempotency boundary, and APNs transport; it owns no
agent execution, session state, inbox, badge, or reminder policy.

## Change requirements

1. Ship implementation, owning documentation, and the tests required by the
   [testing policy](AGENTS.md#testing-policy) together.
2. Fix root causes and preserve canonical runtime ownership; do not create a
   second model/session/settings schema unless the mobile protocol requires a
   bounded projection.
3. Never include personal paths, handles, domains, credentials, or fixture
   secrets. Run `scripts/personal-info-guard.sh`.
4. Use exact production dependency versions and commit lockfile changes. The
   repository-wide Node toolchain pin is `.node-version` (currently 22.22.0);
   package `engines` remain compatibility minimums.
5. Never add or invoke an automated production deployment command.
6. Trust is not sandboxing. Copy and docs must say that executable resources run
   with the Mac user's authority.
7. Agents may start, restart and stop the Debug Gateway (`scripts/tron dev`,
   port 9848). `scripts/tron dev handoff` and every Stable or production
   transition (update, rollback, promotion and restart RPCs, the installed app,
   the `com.tron.server` LaunchAgent, Mac reinstall) remain maintainer actions
   ([AGENTS.md rule 8](AGENTS.md#rules)).
8. Pi SDK updates are one atomic family change. `packages/gateway/package.json`
   is the version authority; do not merge independent Pi package updates. Use
   `cd packages/gateway && npm run update:pi-sdk -- <exact-version>` from a
   clean manifest/lockfile, then run `npm run check:pi-sdk` and
   `npm run test:pi-sdk-scripts` and `npm run test:pi-sdk-rollback`. The
   `pi-sdk-baseline.json` file records the prior runtime used by the sequential
   rollback probe, and any one-way rollback delta the maintainer has accepted for
   that version range under `knownOneWayDeltas`; `package.json` remains the
   current-version authority. The updater performs online metadata preflight, uses the npm
   paired with the repository-pinned Node runtime, runs normal repository
   lifecycle scripts with `--engine-strict` and disables Python bytecode writes
   during npm installs. Tests that require the pinned runtime use its verified
   `.ci-tools` cache, not a mutable developer Node installation. The updater
   restores only its owned manifests plus
   the disposable installed tree with `npm ci` if anything fails. No deployment or
   Gateway lifecycle command is part of dependency maintenance.
9. `pi-subagents` updates are one atomic Tron-owned provider change, not a
   user-managed npm dependency. `packages/gateway/pi-subagents-pin.json` binds
   the exact fork/upstream commits, source archive, lockfile, and bundled closure.
   From a clean pin/artifact/package state use `cd packages/gateway && npm run
   update:pi-subagents -- --fork-repo <path-or-url> <full-fork-commit>`, then run
   `npm run check:pi-subagents` and `npm run test:pi-subagents-scripts`.
   `fork.repository` is null until the public fork URL exists; only the updater
   needs the explicit source. Once recorded, that URL is the default and an
   override must match it. Checks and installs remain self-contained/offline.
   The updater reads git objects, never the fork working tree; it preflights
   the pinned upstream release/tag and fork ancestry, reports latest upstream
   without selecting it, and packs/builds using the pinned Node/npm. Publication
   retains current as previous, and failure restores only invocation-owned
   files. Prior artifacts and install roots stay untouched for rollback. Do not
   install through the user package updater, edit a user's package manifest, or
   deploy/restart a Gateway as dependency maintenance. Conflicting user-installed
   providers are refused rather than replaced or run alongside Tron. Every
   Gateway startup installs/verifies its selected payload's closure offline before
   discovery, reusing a valid immutable root and refusing damage. Debug activation
   uses `scripts/tron dev start`; inspect status first and coordinate any other
   worktree's running candidate. Stable installation happens only when the
   maintainer updates/promotes the reviewed Stable payload (or follows the Mac
   Release reinstall runbook); agents never install into Stable. This is payload
   activation, not part of the dependency updater.
10. Stop on any meaningful Pi behavior delta. Event ordering, canonical JSONL,
   compaction/retries, extension UI, projections, settings/auth/models,
   packaging, or user-visible UI/UX changes must be compared with the approved
   baseline and explicitly decided; never accept a changed behavior merely
   because TypeScript or tests compile. The executable payload contract is npm's
   `app/node_modules/.bin/pi` projection and the exact runtime alias
   `../../app/node_modules/.bin/pi`; changing it requires the documented one-time
   manual Mac Release reinstall, not source-only promotion through an old launcher.

## Fast validation

Start with the smallest owner and expand only after it passes.

The privacy guard uses Git's inventory: full scans include every tracked file
and nonignored untracked file, so new packages, configuration and agent guidance
need no parallel scan-root list. Ignored generated output is skipped only when
untracked; tracked files remain in scope. Only the guard's own needle definitions
are exempt. Pre-commit `--staged` checks changed index blobs, not later working-tree
edits. `--stdin` applies the same needles to text about to be published, such as
the evidence `scripts/tron work verify --post` writes to GitHub, and exits 1 on
a finding. Install that hook once per clone with `scripts/install-hooks.sh`, run from
the main checkout or any linked worktree; Git's hooks directory is shared, so one
install guards every worktree. The hook runs `personal-info-guard.sh --staged`
and the Gateway build for staged gateway TypeScript. Run
`python3 scripts/test-personal-info-guard.py` for disposable-repository
regressions covering those boundaries, literal filenames, fail-closed Git errors
and hook installation from linked worktrees. Fixtures isolate Git's
environment/configuration so an inherited alternate index cannot redirect their
writes. CI runs them on Linux and macOS; pattern syntax must work with both Git
regex implementations.

### Toolchain

Node is pinned exactly by `.node-version`; CI and Mac packaging read that file.
`scripts/tron` sets `PYTHONDONTWRITEBYTECODE=1` so native npm builds never write
`__pycache__` into the pinned npm tree, which the digest in
`config/ci-toolchain.env` rejects (#638).
Use `scripts/verify-ci-toolchain.sh node` to verify the current executable and
reject duplicated version mirrors. Install native project generation with
`scripts/install-ci-tools.sh xcodegen`; both `scripts/tron ios generate` and
`scripts/tron mac generate` reject a mismatched XcodeGen. `TRON_CI_TOOLS_DIR`
relocates that cache (default `.ci-tools`) for the installer, project
generation, the Mac bundle script, `scripts/tron-ios-test`,
`scripts/ios-gateway-e2e-test` and `scripts/tron-profile-ios`; the iOS runner fixtures use it to serve a
synthetic XcodeGen on every host. Xcode version literals
remain intentional Apple-toolchain pins. Run
`python3 scripts/check-documentation-policy.py` after changing documentation
navigation, commands, repository paths, or backticked paths in source
comments. Run `scripts/check-agent-policy.sh` after changing agent guidance. The [agent guidance index](.agents/README.md)
owns skill routing and the policy-fixture validation commands.

### Gateway

```bash
cd packages/gateway
npm run build
npx vitest run src/sessions/runtime-registry.integration.test.ts
npm test
npm audit --omit=dev
```

Gateway mutations require `commandId`. Distinct sessions may run concurrently;
all mutations for one session stay serialized. A disconnect must not abort an
accepted run. Use `scripts/tron chat --session <id>` when testing terminal/mobile
handoff: it attaches to the Gateway-owned runtime. Never open the same canonical
JSONL simultaneously in a separate Pi process.

### Isolated development lifecycle

`~/.tron-dev/gateway` on port `9848` is the only routine agent-development
surface. `scripts/tron dev status` (or `preflight`) is read-only and never
builds; it reports the expected endpoint/home, PID start identities, lifecycle
epoch, source revision, payload fingerprint, health readiness, and the source
worktree, branch and dirtiness (`sourceWorktree`, `sourceBranch`,
`sourceDirty`) of the running candidate. `start`/`restart` build from a dirty
tree too: the candidate's `sourceRevision` is always the full 40-hex `HEAD` the
payload manifest requires, and uncommitted work (tracked edits or untracked,
non-ignored files) is recorded only as `sourceDirty` and a `-dirty` marker in
the free-form version label, never in the revision. The tree is measured before
the build (the label reflects only this) and again when the record is written
after it; `sourceDirty` is true if either measurement is dirty or `HEAD` moved
while the candidate built. Both measurements read the tree, not the payload, so
an edit the build compiled in and then reverted before the record is written
(with `HEAD` unchanged) still records clean; do not edit a worktree while it
builds a candidate meant for handoff.
`start`/`restart` record the worktree, branch and dirtiness they built from against the
staged candidate's runtime epoch (eight records, always keeping the running
one); status resolves them from the epoch that reached readiness, so a failed
restart from another worktree never relabels the running Gateway, even when
both checkouts build the same payload fingerprint. Unknown values report
`null`: all three for an unrecorded epoch, dirtiness for a record written
before it was recorded, and the branch of a detached checkout.
`scripts/tron dev stop` is also build-free and refuses to trust a stale or
reused PID based on `kill -0` alone. The supervisor atomically publishes bounded lifecycle state:
`starting`, `ready`, `stopping`, `restarting`, `failed`, or `stopped`. Lifecycle writes use the explicit transition table in `scripts/tron-dev-state.mjs`; illegal regressions fail closed. Exit 75
is the intentional authenticated restart drain; other exits consume a bounded
restart budget and eventually become `failed`.

After source changes, an agent or the maintainer restarts the Debug Gateway
with `scripts/tron dev restart` for loopback, or adds `--tailscale` when iOS
must reach it. `scripts/tron dev` runs every mode under a minimal, allow-listed
environment, so an agent shell's inherited Stable Gateway values (subagent root,
channel, payload identity, session) never reach the Debug build, deploy helper,
supervisor or Gateway. The Debug Gateway is one shared resource: check
`scripts/tron dev status` first, and do not replace another worktree's running
candidate while its work may still be validating. A command without a host flag
inherits a live supervisor's recorded host; an explicit conflicting flag fails
closed and requires `scripts/tron dev stop` before changing exposure. A fresh
start without a flag defaults to loopback. `start`, `restart` and this sole Debug
supervisor require the signed launcher from
`/Applications/Tron.app`; `stop`, `status` and `handoff` never execute it.
`start`/`restart` build and stage an immutable candidate and refuse an unknown
owner already listening on 9848; the supervisor preserves accepted-run shutdown
draining and waits for truthful exact health identity. After testing, only the
maintainer may run `scripts/tron dev handoff --tailscale`; it performs authenticated
pre/post identity checks and copies the exact payload into Stable as an inactive
candidate only after pre/post authenticated identity proof. Stable is always a
known commit: handoff refuses the selected candidate unless its runtime epoch's
source record says it was built from a clean tree. It also refuses a changed
Node version or runtime contents. When the installed app's validated runtime has
the candidate's Node version, Debug staging uses that exact signed runtime and
its native npm artifacts. Every Mach-O file in the candidate's `app/node_modules`
(including spawned executables) is replaced with the installed copy only when
its owning package's lockfile version and integrity match exactly. Changed or
missing identities, missing installed native files, and native aliases outside
the npm tree refuse staging with `rebuild and install a signed app`; staging
never re-signs addons or relaxes library validation. A different Node version
keeps the official candidate runtime and handoff refuses with the manual
signed-app instruction. A dirty candidate and one whose dirtiness is
unknown (no record, or a record written before dirtiness was recorded) both fail
closed; commit any changes, run `scripts/tron dev restart`,
and hand off the resulting clean candidate. The copy pins the admitted version
and fingerprint under the Debug payload lock, so a Debug apply or rollback that
changes the selection after admission is refused rather than copied. Promotion still
requires explicit user confirmation in iOS pinned to version plus fingerprint. Debug and Stable RPCs are
channel-bound; neither runtime can mutate the other channel. Do not
replace `/Applications/Tron.app`, invoke production
deployment, or install an iOS release as part of routine agent work. The
installed supervised app remains a frozen release image while isolated
iteration proceeds on `9848`.

### iOS

```bash
scripts/tron-ios-test build
scripts/tron-ios-test run --only-testing TronMobileTests/<OwningSuite>
python3 scripts/test-ios-test-infrastructure.py
```

The canonical runner reuses products for nearby owners and preserves bounded
logs/results on its exact repository-owned test simulator. A successful run must
also contain an extracted XCTest summary proving at least one executed,
non-skipped passing test; process failures and timeouts retain their original
status. Run `scripts/tron-ios-test checkpoint` only after focused owners pass. See
`packages/ios-app/docs/development.md` for status, cleanup, diagnostics, and the
[iOS build matrix](packages/ios-app/docs/development.md#build-matrix).
Keep generated schemes and DerivedData out of the diff.

### Mac

Stage generated gateway payloads only when a build/archive needs them:

```bash
packages/mac-app/scripts/bundle-gateway.sh
scripts/tron mac generate
```

The TronMac build and test commands are in the
[Mac development guide](packages/mac-app/docs/development.md#efficient-focused-tests).
CI only compiles the Mac app and test sources, unsigned. Run the app-hosted
`TronMacIntegrationTests` locally, because they need the team's signing certificate.

The Release app packages only `Tron Agent.app` under the stable
`com.tron.server` label. Developer tooling reuses that installed signed launcher
with the isolated Debug payload and never registers a second Login Item.

## Diagnosing a failure

Run `scripts/tron diagnose` (after a Gateway build) to write one read-only,
redacted bundle of an incident's logs and state. What it collects and its
guarantees are in the Gateway README's Diagnostic bundle section.

## Documentation ownership

Owning docs by area are listed in
[AGENTS.md](AGENTS.md#documentation-ownership).

Update the nearest owner when behavior changes. Keep root README concise and link
to implementation-level detail.

## Commits and releases

Every change reaches `main` as one squash-merged pull request for one issue,
through `scripts/tron work land` ([AGENTS.md work tracking](AGENTS.md#work-tracking)).
Keep commits reviewable and avoid generated build output. Xcode projects may be
regenerated from `project.yml`; staged Mac gateway payloads and Node runtimes are
ignored. CI does not publish production artifacts. TestFlight/App Store delivery,
Mac signing and notarization, and production deployment are deliberate manual
maintainer actions. Release tags use `tron-v<version>`.

`VERSION.env` is the only hand-edited product identity file; `scripts/tron version`
owns its mirrors. `sync` rewrites every generated platform mirror from it, `bump
beta|patch|minor` updates `VERSION.env`, syncs the mirrors, and prints the result,
and CI runs `check` to reject drift read-only.
