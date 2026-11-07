# Pi SDK maintenance

Owner: `gateway/pi-sdk` (`packages/gateway/pi-sdk.module.json`). How the pinned Pi SDK family
and the Tron-owned `pi-subagents` provider change and what proves a change. Both change only
atomically through their updaters, and a Pi behavior delta stops for a maintainer decision. No
deployment, Gateway lifecycle command, Stable install or restart is part of this.

## Update rules

- **Pi SDK:** from a clean `package.json`/`package-lock.json`, `cd packages/gateway && npm run update:pi-sdk -- <exact-version>`, then `npm run check:pi-sdk` and `npm run test:pi-sdk-rollback`. Never merge independent Pi package updates or hand-edit the lock.
  While `pi-coding-agent-patch.json` exists the updater refuses versions the patch was not
  rebuilt for.
- **`pi-subagents`** (never a user npm dependency): `npm run update:pi-subagents -- --fork-repo <path-or-url> <full-fork-commit>`, then `npm run check:pi-subagents` and `npm run test:pi-subagents-scripts`.
- **Stop on any meaningful behavior delta** (event order, canonical JSONL, compaction and
  retries, extension UI, projections, settings/auth/models, packaging, visible UI): compare with
  the approved baseline and decide explicitly; compiling is not acceptance. Changing the
  executable contract (`app/node_modules/.bin/pi`, alias `../../app/node_modules/.bin/pi`) needs
  the one-time manual Mac Release reinstall.
- Provider IDs and credentials follow the Pi catalog; retired IDs are never migrated or aliased.

## Forked dependencies

Tron carries a fork only for a fix upstream has not released, or for a product-specific
change the maintainer approved as Tron-only. New fixes go upstream first; the patch only
bridges until a release ships it. A fork is rebuilt on an upstream release
tag as a patch queue, one commit per patch, versioned `<upstream>-tron.<n>`, with a patch
list naming each patch's reason, upstream PR or issue, drop condition and the test that fails
without it. Each bump (#2181) rebases onto the newest tag, runs upstream suites, the patch
tests and Tron's affected checks, and deletes patches the release contains; a rebase
conflict or a persisted-data migration is a maintainer decision, never applied automatically.

| Fork | Pin | Current patch form |
| --- | --- | --- |
| `pi-coding-agent` | `pi-coding-agent-patch.json` (`removeWhen`) | one numbered `third_party/pi-coding-agent/tron.patch`; queue form at its next bump |
| `pi-subagents` | `pi-subagents-pin.json` | fork commits on v0.76.1, each with tests and a drop condition in TRON-PATCHES.md in the fork; queue form at its next bump |
| CortexKit `anthropic-auth` | user package in `~/.tron/agent/settings.json` | a 1.23.1-tron fork build; its replacement is a patch queue on upstream 2.4.12 (PATCHES.md in the fork, patch tests in one file) that the maintainer switches to |

## Version authority and checks

`packages/gateway/package.json` is the sole version authority: `pi-agent-core`, `pi-ai`,
`pi-coding-agent` and `pi-tui` exact and equal. `npm run check:pi-sdk` (offline) validates the
lockfile and installed tree against that cohort and requires `node_modules/.bin/pi` to link to
`pi-coding-agent`'s `bin.pi`; staged payloads use `node scripts/check-pi-sdk.mjs --runtime-tree <app>`. The updater preflights each package (version, revision, integrity, engine), resolves
all four in one `npm install --package-lock-only --save-exact --engine-strict`, installs with
`npm ci`, runs `npm audit signatures`, restores
on failure, and writes the upstream changelog delta to `<git-dir>/work/issue-<N>/` (no delta
fails). `pi-sdk-baseline.json` records the prior runtime and accepted `knownOneWayDeltas`
(exact entries; unobserved ones fail as stale). `test:pi-sdk-rollback` seeds and rereads, both
ways, JSONL, settings, auth, `mcp.json` and MCP OAuth credentials.
`node scripts/compare-pi-sdk-graph.mjs BASE HEAD` compares the family's dependency closure;
when it changes run the rollback matrix and `scripts/ios-gateway-e2e-test` directly.

## Tron-patched `pi-coding-agent`

Until a release ships them, `pi-coding-agent` is a Tron-built tarball at the family's version
carrying: the `projectDir` option ([project root](../src/machine/README.md#project-root)),
dequeuing a delivered image-only steer or follow-up, normalizing queued images for the active
model, an idle `session.systemPrompt` that keeps transcript-provided extension sections, and a
run start that `preflightResult("started")` can revoke, and FIFO `ModelRuntime`
config reads. A newer awaited refresh cannot overtake an older registration-triggered
config read and let that continuation start storage work after readiness. Each call
still loads current config and retains its own provider selection/error; this is not
a general downstream credential/model-store drain API. It also pins the patched `undici`
(8.12.3) and `minimatch` (11.0.3) that upstream ships from 1.5.0: the `pi` bin and
`./rpc-entry` bundle their dependencies, so only a rebuild moves them, never a Gateway
`overrides` entry.

`pi-coding-agent-patch.json` owns it: upstream tag and commit, the published tarball's
integrity, the backported proposal commit, patch SHA-256, bundled `pi-ai` model data,
toolchain and the built tarball's SHA-512, under `third_party/pi-coding-agent/` with the MIT
`LICENSE`. `package.json` names `file:third_party/pi-coding-agent/<file>.tgz`; `check:pi-sdk`
accepts exactly that declaration and no other `file:` dependency. `npm run reproduce:pi-coding-agent` rebuilds from the tag (the unpatched pack must equal the registry
tarball, the patched pack the committed SHA-512; `--upstream <path>`, `--write` after a
deliberate change). A patch that changes the upstream root `package-lock.json` is reinstalled
from it before the patched build. When a release ships the APIs (`removeWhen`), remove in one change: restore
the exact release version, delete the declaration, `third_party/pi-coding-agent/`,
`packages/gateway/scripts/build-pi-coding-agent-patch.mjs` and its script, drop it from
`packages/mac-app/scripts/stage-gateway-app.sh` and `BUILD_INPUT_FILES` in
`scripts/gateway-install-inputs.mjs`, then `npm install` and `update:pi-sdk`.

## Signals

| Signal | One-step diagnosis / surviving oracle |
| --- | --- |
| `ENOTEMPTY` removing a fixture's `agent` directory, or SDK files reappearing after removal | Run `scripts/tron test gateway src/sessions/model-runtime-config-lifetime.integration.test.ts`. Its real filesystem gate distinguishes an older detached config read from the later awaited Gateway readiness, then checks actual registry disposal/root removal. Other downstream lock lifetimes still require their own writer trace. |

## Tron-owned `pi-subagents` build

- **Pin.** `pi-subagents-pin.json`: fork commit, archive and lockfile SHA-256, Node/npm build
  versions, closure SHA-512; `fork.repository` stays null until a public fork exists. A retained
  predecessor pin binds its exact archive, lockfile and closure. Artifacts live in `artifacts/`.
- **Check** (offline): both selections' inputs and identity, and every non-peer dependency of
  the lock-resolved graph inside the closure with matching `resolved`/`integrity`.
- **Build:** `npm run build:pi-subagents-closure` with the pinned toolchain (`TRON_NODE_BIN`);
  predecessors only in disposable copies.
- **Update:** verifies upstream tag and fork ancestry, builds a new `-tron.N` in a disposable
  tree, and must pass the offline real-Gateway activation/child-execution gate and the previous
  → candidate → previous probe before publishing immutable artifacts and renaming the pin
  (current kept as previous). `.pi-subagents-update-staging` is the exclusive lease; an
  interrupted update leaves it for the operator. It never edits the fork, homes or manifests.
- **Home task gate:** every pin change also re-reviews the fork's launch/control contract
  and updates the reviewed version in `src/kernel/delegation/task-worker-extension.ts`.
  An unreviewed version is refused before launch. Validate actual Home-task launch/resume
  and retained refusals, not only an ordinary session's child execution.
- **Install and activation:** `npm run install:pi-subagents -- <gateway-home>` extracts the
  closure offline into `<gateway-home>/internal/pi-subagents/<version>` with a receipt and
  publishes by rename; valid roots are reused, damaged ones refused, none pruned. Every startup
  activates its payload's closure before extension discovery and fails closed on damage.
  Stable installation is maintainer-only.
- **Admission:** one `ManagedSubagents` selection per payload and home serves runtime and admin
  loads, discovery, `session.resources` and `packages.list`. It revalidates receipt and files,
  checks SDK peer ranges, requires `PI_SUBAGENTS_TEMP_ROOT` = `delegatedArtifactRoot(tronHome)`
  (else `conflict`), sets `PI_SUBAGENTS_PI_CODING_AGENT_PACKAGE_ROOT` to the payload's
  `pi-coding-agent`, confines `pi.extensions|skills|prompts` to the verified root, and gives the
  extension a build-bound `tron:pi-subagents@…#…` owner, the only one allowed to register
  `subagent`. Its factory and discovery loads use the closure's jiti with a private
  `<gateway-home>/internal/pi-subagents-transform-cache/<version>`. The first factory load of a
  process waits (asynchronously) for a worker to transform the whole build into that cache, and a
  discovery read (catalog, `packages.list`) only for the modules its entry reaches, so the
  Gateway thread never runs Babel; if the worker cannot fill the cache the load is refused (`busy`, retryable) and the next
  load prepares again. Each factory load still evaluates a fresh module graph per session.
  After it serves and recovers, the Gateway starts that whole-build preparation in the
  background (startup step `subagent-transforms`); it never delays listening, a session load
  joins it, and a failed preparation (`pi-subagents.transform-cache-failed`) leaves the first
  load to prepare again.
- **User declarations** of `npm:pi-subagents` are ignored (filtered by
  `managedProviderSettingsView`, which also refuses package writes; `extensionsOverride` is too
  late to exclude); `packages.list` shows a typed `conflict` (`managed-provider`), Settings says
  "Remove it with `pi remove npm:pi-subagents`"; one `pi-subagents.user-package-ignored` per load.
- **Proof:** `managed-subagents.install.integration.test.ts`,
  `managed-subagents-warm-process.e2e.test.ts` (fresh home, real Gateway process),
  `managed-subagents.transform.integration.test.ts` (fresh build, no Gateway-thread transform),
  `managed-subagents.integration.test.ts` (npm offline, TCP denied, a real child),
  `npm run test:pi-subagents-rollback` (previous → candidate → previous with resume; original
  JSONL prefixes unchanged; `TRON_SUBAGENTS_ROLLBACK_ROOT` keeps the home; join failures go to
  `TRON_TEST_PROCESS_OWNER_FAILURE`) and, after a build,
  `src/kernel/delegation/managed-subagents.payload.integration.test.ts`. Reports in `test-results/`.

## Persisted-state corpus

`test-fixtures/pi-sdk/corpus/` holds an agent directory and sessions the outgoing SDK wrote
through the real Gateway, plus Tron's observation of reopening them. Regenerate with `npm run record:pi-corpus` before bumping, so `src/sessions/pi-persisted-state-corpus.integration.test.ts`
fails when a session, tool selection, model, provider key or MCP credential stops resolving
([corpus README](../test-fixtures/pi-sdk/README.md)).

## Candidate review

Inventory every release-note, API and documentation delta against its seam as inherited,
adapted with evidence, deferred with criteria, or not applicable; keep the matrix in the
candidate's issue. Seams: `StreamFn` wrappers (`src/runtime/`), canonical entries and
projections (`src/sessions/`), provider catalogs and media, extension registration
(`src/extensions/compatibility-manifest.ts`). Standing decisions: `context_edit` entries are
canonical but not chat rows; import uses `SessionManager.forkFrom` with a new identity; the SDK
resizes images, so the Gateway keeps the upload and never resizes twice. Every Pi union Tron
switches over ends in a `never` default (`compatibility-manifest.ts`, `projection.ts`,
`history.ts`, `runtime-slot.ts`; node kinds `satisfies Record<…>`), so a new member fails `npm run build`.

## Pi SDK behavior trace

`src/sessions/sdk-behavior-trace.integration.test.ts` locks what the pinned SDK makes Tron emit,
persist and send: one faux-provider scenario through the real `RuntimeRegistry`/`RuntimeSlot`
with codemode, tool search and MCP (text and thinking, direct and nested tools,
`models.classify()` and `image()`, MCP tools, steer and follow-up, abort, manual compaction, a
Chat model change), normalized and compared with
`test-fixtures/pi-sdk/sdk-behavior-trace.golden.json`; a busy-loop replay must match too. The
scenario-lock projection omits shared tool descriptions and parameter schemas already covered by
the Home activation lock; this changes only the compared projection, not the captured runtime
transcript or provider schemas. Run
`npm run test:sdk-behavior-trace` (a mismatch keeps `test-results/sdk-behavior-trace.diff`);
update deliberately with `npm run update:sdk-behavior-trace` ([scenario locks](scenario-locks.md)).
The golden is darwin-specific and includes Tron prompt text, so tool snippet changes update it in
the same change. For an SDK candidate review each hunk; one nobody can explain is the stop.
