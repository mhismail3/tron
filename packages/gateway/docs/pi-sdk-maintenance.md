# Pi SDK maintenance

Owner: `gateway/pi-sdk` (`packages/gateway/pi-sdk.module.json`). How the pinned Pi SDK
family and the Tron-owned `pi-subagents` provider change, and what proves a change.
The charter rule applies: both change only atomically through their updaters, and a Pi
behavior delta stops for a maintainer decision. No deployment, Gateway lifecycle command,
Stable install or restart is part of dependency maintenance.

## Update rules

- **Pi SDK** updates are one atomic family change. From a clean
  `package.json`/`package-lock.json` run
  `cd packages/gateway && npm run update:pi-sdk -- <exact-version>`, then
  `npm run check:pi-sdk` and `npm run test:pi-sdk-rollback`. Never merge
  independent Pi package updates or hand-edit the lockfile. While
  `pi-coding-agent-patch.json` exists the updater refuses any version the patch was
  not rebuilt for ([Tron-patched `pi-coding-agent`](#tron-patched-pi-coding-agent)).
- **`pi-subagents`** updates are one atomic Tron-owned provider change, never a user
  npm dependency: `npm run update:pi-subagents -- --fork-repo <path-or-url>
  <full-fork-commit>`, then `npm run check:pi-subagents` and
  `npm run test:pi-subagents-scripts`
  ([Tron-owned `pi-subagents` build](#tron-owned-pi-subagents-build)).
- **Stop on any meaningful Pi behavior delta.** Event ordering, canonical JSONL,
  compaction/retries, extension UI, projections, settings/auth/models, packaging or
  user-visible UI/UX changes are compared with the approved baseline and explicitly
  decided; compiling is never acceptance. Changing the executable payload contract
  (npm's `app/node_modules/.bin/pi` and the runtime alias
  `../../app/node_modules/.bin/pi`) needs the one-time manual Mac Release reinstall.
- Provider IDs and credentials follow the Pi catalog. Tron never migrates or aliases
  a retired provider ID (for example `azure-openai-responses` to `azure`).

## Version authority and checks

`packages/gateway/package.json` is the sole SDK version authority. `pi-agent-core`,
`pi-ai`, `pi-coding-agent` and `pi-tui` are exact and equal. `npm run check:pi-sdk`
(offline) validates every recognized Pi package in the lockfile and installed tree
against that cohort and the canonical registry, and requires `node_modules/.bin/pi` to
be a symlink to `pi-coding-agent`'s declared `bin.pi`. Staged payloads omit the
development-only `pi-sdk-baseline.json`; check them with
`node scripts/check-pi-sdk.mjs --runtime-tree <app>`.

The updater preflights every family package (version, source revision, integrity,
Node engine), resolves the four pins in one
`npm install --package-lock-only --save-exact --engine-strict`, installs with `npm ci`
(an argument-bearing `npm install` would skip the postinstall that keeps node-pty's
`spawn-helper` executable), runs `npm audit signatures`, and restores its owned
manifests and the installed tree with `npm ci` on any failure. On success it writes
the upstream `CHANGELOG.md` sections between the versions to
`<git-dir>/work/issue-<N>/pi-sdk-changelog-<from>-to-<to>.md` (or `work/pi-sdk-update/`);
an update with no changelog delta fails. It uses the npm paired with the pinned Node.

`pi-sdk-baseline.json` records the prior runtime for the rollback matrix and any
one-way delta the maintainer accepted for that range under `knownOneWayDeltas`
(an exact `{store, from, to, reason, rollbackState, credentialKey}` entry; an
unobserved entry fails as stale). `npm run test:pi-sdk-rollback` seeds and rereads,
in both directions, session JSONL, settings, auth, `mcp.json` (via `pi mcp add`, with a
hyphenated server name) and the MCP OAuth credential store, naming the on-disk keys a
runtime cannot resolve. Only the rollback runtime may lack the built-in MCP surface.
`node scripts/compare-pi-sdk-graph.mjs BASE HEAD` compares the dependency closure
reachable from the Pi family; when it changes, run the rollback matrix and
`scripts/ios-gateway-e2e-test` directly (no hosted CI runs either).

## Tron-patched `pi-coding-agent`

No published release yet carries what the Gateway needs from `pi-coding-agent`: the
`projectDir` option ([Project root](../src/machine/README.md#project-root)), dequeuing a
delivered image-only steer or follow-up, normalizing a queued steer's or follow-up's
images for the active model as `prompt()` does, an idle `session.systemPrompt` that
keeps the extension sections the transcript still gives the model, and a run start
that a prompt's `preflightResult("started")` callback can revoke. Until one does,
`pi-coding-agent` is a Tron-built tarball at the family's version.

`pi-coding-agent-patch.json` is its only owner: upstream tag and commit, the published
tarball's integrity, the backported upstream proposal commit, the patch SHA-256, the
bundled `pi-ai` model data, the Node/npm toolchain and the built tarball's SHA-512,
under `third_party/pi-coding-agent/` with the upstream MIT `LICENSE`. `package.json`
names `file:third_party/pi-coding-agent/<file>.tgz`, so the lock binds its bytes and
`npm ci` needs nothing else. `check:pi-sdk` accepts exactly that declaration (direct
dependency, lock root and entry, tarball and patch digests, license); any other `file:`
dependency fails. Packaging stages the declaration and tarball before `npm ci`. The
package version stays the release version, so Pi's own version checks are unchanged.

`npm run reproduce:pi-coding-agent` rebuilds from a fresh fetch of the tag with the
declared toolchain: the unpatched pack must equal the registry tarball byte for byte,
then `git apply`, rebuild and pack must equal the committed SHA-512 (`--upstream
<path>` uses a local clone). After a deliberate patch change, `--write` replaces the
tarball and records both digests; then refresh the lock with `npm install`. Moving the
patch to another release updates the declaration's `version`, `upstream`, `modelData`
and artifact path, rebases the patch onto that tag and runs `--write`.

`update:pi-sdk` installs a patched cohort only for the declared version and requires
the registry's `pi-coding-agent` and `pi-ai` integrities to be the declared ones (Pi
stopped publishing `gitHead` with 1.1.0, so provenance is the declaration's tag commit).
When a release ships the APIs (the declaration's `removeWhen`), remove the patch in one
change: set `pi-coding-agent` back to the exact release version; delete
`pi-coding-agent-patch.json`, `third_party/pi-coding-agent/`,
`packages/gateway/scripts/build-pi-coding-agent-patch.mjs` and its `reproduce:pi-coding-agent` script;
drop the declaration from `packages/mac-app/scripts/stage-gateway-app.sh` and the
`BUILD_INPUT_FILES` of `scripts/gateway-install-inputs.mjs`; run `npm install`, then
`npm run update:pi-sdk -- <release>`.

## Tron-owned `pi-subagents` build

**Pin.** `pi-subagents-pin.json` is the single version authority: fork commit, source
archive SHA-256, fork lockfile SHA-256, Node/npm build versions and the SHA-512 of the
self-contained closure. `fork.repository` stays null until a public fork URL exists;
once recorded it is the updater default and a different override is refused. A
retained predecessor pin binds its exact archive, lockfile and closure (a registry
predecessor also its registry integrity); a partial rollback record is rejected.
Archives and lockfiles live under `artifacts/`.

**Check.** `npm run check:pi-subagents` (offline) validates both selections' inputs and
package identity and walks the whole lock-resolved runtime graph: every non-peer
dependency resolves inside the closure at its locked path and version with matching
`resolved`/`integrity`. Pi host-provided peers are excluded. Integrity chains from
`npm ci` (lockfile SRI) to the closure SHA-512 to this graph check.

**Build.** `npm run build:pi-subagents-closure` with the toolchain the pin records
(select it with `TRON_NODE_BIN`) reads the top-level selection; rebuild a predecessor
in a disposable copy, never a live install. Development dependencies are removed only
from the temporary install manifest; the packaged manifest keeps source metadata and
adds sorted `bundledDependencies`.

**Update.** The updater checks the pinned upstream tag and fork ancestry online
(reporting latest upstream without selecting it), exports git objects into a
disposable tree, and packs/builds with the repository-pinned Node/npm. The candidate
needs a new `-tron.N` version and must pass, before anything is published, the offline
real-Gateway activation/discovery/child-execution gate and the previous → candidate →
previous execution/resume probe, both in disposable payloads and homes. Any failure
removes staging and leaves the pin and artifacts unchanged. Publication creates new
immutable artifacts and renames the pin atomically, keeping the current pin as
previous; a final check failure restores it. `.pi-subagents-update-staging` is the
exclusive invocation lease: an interrupted update leaves it for the operator to
inspect, never to sweep. The updater never edits the fork, installed homes or user
package manifests, and never deploys or starts a service.

**Install and activation.** `npm run install:pi-subagents -- <gateway-home>` extracts
the closure offline into `<gateway-home>/internal/pi-subagents/<version>`, staging
files and a receipt (version, fork commit, closure SHA-512), verifying, then
publishing by directory rename. A valid root is reused, a damaged one refused; old
roots are never pruned. Every Gateway startup activates its selected payload's closure
the same way, after delegated-root cutover admission and before Pi extension
discovery; damaged bytes or receipts fail startup closed. `scripts/tron dev start`
therefore installs into `~/.tron-dev/internal/pi-subagents/`. **Stable installation
is maintainer-only**, by promoting the reviewed payload (or the Mac Release reinstall
runbook); its startup performs the same activation.

**Admission.** One `ManagedSubagents` selection belongs to the payload and configured
home. Runtime loads, session-free admin loads, subagent discovery, `session.resources`
and the managed `packages.list` row use it. Admission revalidates the receipt and every
installed file against the pinned archive, and checks SDK peer ranges against the
payload; Pi's loader aliases peer imports to the host SDK, so one immutable root serves
several payloads. Before any managed load, `PI_SUBAGENTS_TEMP_ROOT` must resolve to
`delegatedArtifactRoot(tronHome)` for the supplied home (bound through
`delegatedProviderEnvironment`), rechecked after loading; otherwise `conflict`. The
same owner sets `PI_SUBAGENTS_PI_CODING_AGENT_PACKAGE_ROOT` to the running payload's
`pi-coding-agent`, so the provider's detached children use the selected host; shell
commands still filter `PI_*`. The manifest's `pi.extensions`, `pi.skills` and
`pi.prompts` must stay inside the verified root (empty, escaping or non-regular
entries fail closed) and feed Pi's additional skill and prompt paths with managed
provenance. The loaded extension gets a build-bound `tron:pi-subagents@…#…` owner, the
only one allowed to register `subagent`, at load and later.

**User declarations.** User or project `npm:pi-subagents` declarations are ignored,
never executed. `managedProviderSettingsView` filters the package reads Pi's resolver
uses (pre-trust, final and reload passes) and refuses package writes through it;
`DefaultResourceLoader.extensionsOverride` runs after module loading, so it is not the
exclusion seam. `packages.list` keeps the declaration with a typed `conflict`
(`code: managed-provider`) and empty `provides`; Settings labels it Ignored with
"Remove it with `pi remove npm:pi-subagents`". One
`pi-subagents.user-package-ignored` warning per load reports it.

**Proof.** `managed-subagents.install.integration.test.ts` (real closure and loader in
an isolated home, destructive byte/receipt cases) and
`managed-subagents.integration.test.ts` (startup activation with npm offline and TCP
denied, then a real foreground child through `RuntimeRegistry`/`RuntimeSlot`; report
`test-results/managed-subagents.integration.json`). `npm run test:pi-subagents-rollback`
runs previous → candidate → previous in one isolated home, resuming the candidate child
through the previous provider's `action: resume`; original JSONL prefixes must stay
unchanged (report `test-results/managed-subagents.rollback.json`; keep the home with
`TRON_SUBAGENTS_ROLLBACK_ROOT=<nonexistent dir>`). Its fixture process owner stops and
joins every spawned tree before removing roots and writes join failures to
`TRON_TEST_PROCESS_OWNER_FAILURE`, which fails the update and keeps staging. After
`npm run build`, `src/sessions/managed-subagents.payload.integration.test.ts` activates
the bundler's real staged app inputs with TCP denied
(`test-results/managed-subagents.payload.json`).

## Persisted-state corpus

`test-fixtures/pi-sdk/corpus/` holds an agent directory and canonical sessions the
**outgoing** SDK wrote through the real Gateway, plus Tron's observation of reopening
them. Regenerate it with `npm run record:pi-corpus` (owned by
`vitest.corpus.config.ts`) **before** bumping the family, so
`src/sessions/pi-persisted-state-corpus.integration.test.ts` fails when an existing
session, per-chat tool selection, model, saved provider key or MCP credential stops
resolving. [`test-fixtures/pi-sdk/README.md`](../test-fixtures/pi-sdk/README.md)
describes its contents.

## Candidate review

Inventory every release-note, API and documentation delta against its owning seam and
record it as inherited, adapted with evidence, deferred with acceptance criteria, or
not applicable; keep that matrix in the candidate's issue, not here. Seams: `StreamFn`
wrappers and request context (`src/runtime/`), canonical entries and projections
(`src/sessions/`), provider catalogs and source-preserving media, and extension
registration (`src/extensions/compatibility-manifest.ts`). Standing decisions:
`context_edit` entries stay canonical but are not chat rows; session import uses
`SessionManager.forkFrom` with a new identity, keeping entry IDs; the SDK resizes images
for the active model, so the Gateway keeps the source upload and never resizes twice.

Every Pi union Tron switches over is classified at compile time:
`compatibility-manifest.ts` (extension seam), `src/sessions/projection.ts` (entry
types, roles, content blocks), `src/sessions/history.ts` (entry set and node kind) and
`src/sessions/runtime-slot.ts` (`AgentSessionEvent`) end in a `never` default, and the
node-kind map is `satisfies Record<…>`, so a new member fails `npm run build` naming its
owner. Prove the gate by adding a synthetic member to the installed SDK typings.

## Pi SDK behavior trace

`src/sessions/sdk-behavior-trace.integration.test.ts` locks what the pinned SDK makes
Tron emit, persist and send. One faux-provider scenario through the real
`RuntimeRegistry`/`RuntimeSlot` and Pi's codemode, tool-search and MCP built-ins covers
streamed text and thinking, a direct tool, codemode with a nested call,
`models.classify()` and `image()`, direct and codemode-exposed MCP tools, tool search,
steer and follow-up, abort, manual compaction and a Chat model change. Its normalized
trace (per-request tool names, prompt section headings and prompt hash, the classifier
request, every broadcast topic's payload shape, every canonical JSONL entry and the
transcript projection) must equal
`test-fixtures/pi-sdk/sdk-behavior-trace.golden.json`. IDs, times, temp paths and
host-derived numbers are normalized; a single searchable MCP server and pruned
live-progress subtrees keep host timing out. A second case replays the scenario on a
busy event loop with delayed responses and must match; only the idle case may write.

Run `npm run test:sdk-behavior-trace`; a mismatch keeps
`test-results/sdk-behavior-trace.diff` and `.actual.json`. Update deliberately with
`npm run update:sdk-behavior-trace` ([scenario locks](scenario-locks.md)). The golden
is darwin-specific (the `computer` module registers only there) and includes
Tron-owned prompt text, so a change to Tron's tool snippets or rules updates it in the
same change. For an SDK candidate, review the diff hunk by hunk as inherited, adapted
with evidence or not applicable before updating; a hunk nobody can explain is the stop.
