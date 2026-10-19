# Repository development

Repository-wide development runbooks: the privacy guard, the pinned toolchain,
the isolated Debug Gateway lifecycle, and versions and releases. The rules that
bind every change are in the [charter](../AGENTS.md); package runbooks live with
their packages ([Gateway](../packages/gateway/README.md#development),
[iOS](../packages/ios-app/docs/development.md),
[Mac](../packages/mac-app/docs/development.md)).

Start validation with the smallest owner and expand only after it passes
([charter](../AGENTS.md#validation-and-landing),
[independent landing](../tools/work/README.md)).

## Privacy guard

The privacy guard uses Git's inventory: full scans include every tracked file
and nonignored untracked file, so new packages, configuration and agent guidance
need no parallel scan-root list. Ignored generated output is skipped only when
untracked; tracked files remain in scope. Only the guard's own needle definitions
are exempt. Pre-commit `--staged` checks changed index blobs, not later working-tree
edits. `--stdin` applies the same needles to text about to be published, such as
pull request bodies and issue comments, and exits 1 on a finding. Install that hook once per clone with `scripts/install-hooks.sh`, run from
the main checkout or any linked worktree; Git's hooks directory is shared, so one
install guards every worktree. The hook runs `personal-info-guard.sh --staged`
only; it never builds or runs tests. Run
`python3 scripts/test-personal-info-guard.py` for disposable-repository
regressions covering those boundaries, literal filenames, fail-closed Git errors
and hook installation from linked worktrees. Fixtures isolate Git's
environment/configuration so an inherited alternate index cannot redirect their
writes. The guard supports macOS and Linux Git regex implementations.

## Toolchain

Node is pinned exactly by `.node-version`; CI and Mac packaging read that file.
Package `engines` fields remain compatibility minimums. Production dependencies
use exact versions with committed lockfiles.
`scripts/tron-node` is the one resolver for the pinned development Node: it
prints the chosen `node` (`TRON_NODE_BIN`, then the exact nvm directory, then
the checksum-verified cache, then each `node` on `PATH`, then Homebrew), and
`scripts/tron-node exec COMMAND` runs a command with that Node first on `PATH`.
`scripts/tron-node install` fills the cache from the official archive checked
against `config/ci-toolchain.env` (`scripts/install-ci-tools.sh node`). It uses
the primary checkout's `.ci-tools`, so one install serves every linked worktree.
It refuses a signed Gateway payload or app-bundle runtime, which Tron agent shells have first on `PATH` but which cannot load
unsigned native add-ons and has no `npx`. Packaging, `scripts/tron dev`,
`scripts/tron ci|chat|diagnose`, the iOS Gateway E2E harness, the profiler and
`scripts/tron work verify` all use it.
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
comments. Run `scripts/check-agent-policy.sh` after changing agent guidance. The [agent guidance index](../.agents/README.md)
owns skill routing and the policy-fixture validation commands.

**Node update rule.** Tron runs the current Active LTS major of Node.

- **Check:** `scripts/tron-node status --online` reports newer patches of the
  pinned major (and which are security releases), the major's LTS, maintenance
  and end-of-life dates, and a newer Active LTS major. Plain `status` stays
  offline. Neither command edits anything.
- **Patch:** Take patch releases monthly, or at once for a security release. Use
  `scripts/tron-node pin X.Y.Z`. It checks both macOS archives against
  `SHASUMS256.txt` and rewrites `.node-version` with the archive, runtime and
  npm-tree digests in `config/ci-toolchain.env`. Then run
  `scripts/tron-node install` and the directly relevant tests.
- **Major:** Adopt a new LTS major within six months of its LTS date, as its own
  change. The same `pin` also needs `engines.node` and `@types/node` in
  `packages/gateway/package.json`, and evidence that native modules (`node-pty`)
  and `node:sqlite` load under the new runtime. Don't combine it with unrelated
  dependency upgrades.
- **Packages:** A Pi package whose `engines.node` needs a newer major is a
  reason to schedule the major move, not to run that package unsupported.
- **Rollback:** Revert the pin commit, or `pin` the earlier version.
- **Shipping:** The signed Gateway carries its own runtime, so an installed
  Gateway changes Node only through a newly signed Tron build that the
  maintainer installs. Gateway rollback to the previous payload restores the
  previous runtime. Agents never rebuild, restart or promote it.

## Isolated development lifecycle

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

## Commits, versions and releases

Landing follows the [charter](../AGENTS.md#validation-and-landing). Keep commits reviewable and avoid generated build output. Xcode projects may be
regenerated from `project.yml`; staged Mac gateway payloads and Node runtimes are
ignored. TestFlight/App Store delivery,
Mac signing and notarization, and production deployment are deliberate manual
maintainer actions. Release tags use `tron-v<version>`.

`VERSION.env` is the only hand-edited product identity file; `scripts/tron version`
owns its mirrors. `sync` rewrites every generated platform mirror from it, `bump
beta|patch|minor` updates `VERSION.env`, syncs the mirrors, and prints the result,
and `scripts/tron version check` reports drift read-only when requested.

## Restructure metrics

`scripts/tron metrics [<rev>]` measures a commit's Git objects for the
[restructure targets](restructure/plan.md#3-metrics-definitions-and-targets) and
writes `test-results/metrics/<sha>.json`; `--compare <base>` prints the delta
table restructure slices paste into their closing evidence. It reports and never
gates. The [metric definitions](../tools/metrics/README.md) own the
classification rules and the metrics that stay unavailable until their slice lands.

## Module ownership

Every tracked file has exactly one owner, declared by a co-located
`<name>.module.json` manifest. `scripts/tron ownership` reports unowned or doubly
owned paths and malformed manifests; it never gates. A new or moved file needs
its manifest updated in the same change. [Ownership rules](../tools/ownership/README.md).

`scripts/tron layers [gateway|ios]` checks a package's dependency graph against
manifest layers and `dependsOn`. The Gateway graph comes from the pinned TypeScript
compiler; the iOS graph comes from the Xcode index store of a fresh
`scripts/tron-ios-test build` of the current commit (stale evidence is refused).
Existing violations live in the shrink-only `packages/<pkg>/layer-baseline.json`;
new or grown ones fail, and a fixed one must be removed with `--update`.
[Layer rules](../tools/layers/README.md).

`scripts/tron budgets` checks a commit's file sizes (500 lines for code) and doc
budgets with the metrics counts. An oversized file passes only with an exception
in its owning manifest; exceptions are shrink-only against `origin/main`, so a new
one, a grown excepted file or a stale one fails. [Budget rules](../tools/budgets/README.md).

`scripts/tron verify --changed` is a restructure slice's one command: the static
checkers above (ownership, budgets, layers, documentation policy, privacy guard,
diff check, Gateway typecheck and lint), then the tests the changed modules own.
A kernel, toolchain or unowned change runs every lock. It prints live progress,
stops at the first failure, writes `test-results/verify/<sha>.json`, and fails a
run that executes no test. [Verify](../tools/verify/README.md).
