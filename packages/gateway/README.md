# Tron Gateway

## Protocol v7 chat semantics

The Gateway is the sole live owner of invocation, operation, and activity
identity. Canonical Pi JSONL remains authoritative; Gateway-owned bounded
`tron.chat-invocation.v1` records persist causal start/terminal/binding facts in
the same session branch and never enter model context. Plain prompt bodies remain
only in their canonical user entries rather than being duplicated into receipts;
resource arguments are bounded but preserve tabs and multiline text. A missing
terminal record after an accepted start is `outcomeUnknown` and is never
automatically replayed. An admission that fails before any run starts (a Home
memory refusal while delivering a waiting result, for one) also restores the
phase it took, so the session is idle again rather than "running" with nothing
running (#881, `home-wake.e2e.test.ts`). When Pi appends a canonical successful assistant reply,
RuntimeSlot starts the exact completion's durable attention settlement immediately
rather than waiting for `agent_settled` (#522). A response completion is not an
operation terminal outcome: automatic compaction and same-owner continuation may
still run, and Stop during those phases must remain authoritative. Terminal
receipts are decided only at final `agent_settled` or transfer to a distinct
follow-up/extension operation. At transfer, the predecessor's exact completion
is captured before its observation record retires. The SDK's awaited public
admission hooks join pending canonical terminal receipt writes before the next
operation's admitted user input, including bounded retries after a pre-staging
failure. SDK-owned between-turn entries emitted before that input (for example,
a tool-loadout system message) are outside this ordering guarantee and may fall
on either side of the receipt. Consumers must not infer anything from receipt-
versus-SDK-entry order. The hooks do not join attention I/O; already accepted follow-ups remain free
to run while preceding attention commits. No terminal promise is retained on a
completion-ownership item. Automation terminal notification still follows the
owning attention settlement. Completion settlement retires only the prior
completion's marker and work while the follow-up remains active, and admits that
exact completed observation cut once from the same completion owner. The operation
observation record owns both its cursor and terminal-callback
completion deduplication. Ownership transfer retires that per-operation record;
a completion already admitted to the durable ownership queue carries its exact
cursor until its cut is settled. When an owner continues in the same run, its
cursor advances just past the completion, so a later cut includes steering input
and its answer without replaying the earlier cut. A later follow-up failure
cannot swallow the earlier success cut. If a durable commit truly blocks
admission, the `attention-pending` diagnostic names the owning operation and its
age. The faux-provider regression in
`src/sessions/runtime-registry.integration.test.ts` retains its canonical
transcript and invocation receipts at
`test-results/runtime-slot-follow-up-steering.json` for inspection and
regeneration with that focused Vitest case.

A failed user Stop (`Foreground work did not stop`) withdraws its unconfirmed
invocation interruption intent. A later natural completion is `completed`, not
`interrupted/user-abort`; an actual SDK abort still settles as interrupted.
Gateway-owned limit/stop reasons retain their separate invocation authority.
`runtime-registry.integration.test.ts` exercises SDK refusal followed by real
run settlement and canonical receipt persistence, with the repeatable artifact
`test-results/failed-stop-natural-completion.json`, alongside actual fast-abort
and already-completed controls.

Every tool call's life after cancellation is bounded (#961,
`sessions/bounded-tool-cancellation.ts`). Pi's loop awaits a tool's `execute`
and its abort waits for the loop to go idle, so one tool that ignored its abort
signal made Stop hang and left a worker running. Two seconds after cancellation
the call resolves as an error result naming the abandoned tool; the run ends and
Stop settles within its grace. Built-in bash kills its process group on abort
and settles first. The abandoned call's late result is discarded. Each call also
runs under its own abort controller, so a task interrupt (#1189) can cancel only the
in-flight calls while the turn continues; see `docs/home.md` (Interrupt).
`src/home/home-task-tool.e2e.test.ts` stops a Home worker blocked in such a tool
and resumes it in place, and stops one in a SIGTERM-ignoring 10-minute command,
with the repeatable artifact `test-results/home-task-tool.json`.

An invocation's receipts all belong to the session it started in. An extension
command that replaces its own session (`ctx.switchSession`, `ctx.newSession`,
`ctx.fork`) is settled there when Pi commits the replacement: at
`beforeSessionInvalidate`, after `session_before_switch` can no longer refuse it
and while the origin is still bound, the Gateway writes its `completed` terminal
receipt and clears its runtime marker in the origin. Nothing more is written for
it under the replacement identity. A fork copies the command's `start` row, which
the replacement projects with its stored lifecycle; the live-command overlay
applies only to a start receipt the replacement itself wrote, so the inherited row
is never shown as running while the replacement's handler is still live. Every
extension-command row a fork inherits (its `start` receipt names the origin) is
projected as settled in the origin, never as staged: with the origin's terminal
lifecycle when the fork's history carries that receipt, otherwise `completed`,
the only outcome the origin records for the forking command whose terminal is
written after the copy. Such a row carries `settledInOriginSession: true` on its
semantic metadata. Stored receipts are never rewritten, and a staged inherited
row would otherwise block live composer commands. Handler code after the call runs unowned in
the replacement, as Pi's stale-context model implies, so a later failure surfaces
as an extension error there. A replacement that fails after that boundary still
records the command `completed`. Receipt and marker writes target the session
bound when they were requested, and a retry never follows a rebind. The
command-driven replacement cases in
`src/transport/session-archive.integration.test.ts` cover all three calls, and
the fork-inherited settlement case there covers the projected rows across restart.

Transcript order is canonical branch order, never timestamp or activity recency.
The v7 projection separates inbound context, agent output/invocations, ambient
status, and hidden state. `custom_message` is model input; `custom`/`appendEntry`
is extension state. Producer attribution is only exact at a Gateway-owned action or callback
boundary, receipt, trusted adapter, or registered tool ownership; unknown remains
unknown. Every projection is bounded by count and byte limits and malformed
recognized data fails closed for authoritative resynchronization.

Protocol v7 deliberately has no v6 runtime path. The deployed v6 update helper
validates a candidate payload manifest against the protocol version it speaks
and refuses a candidate whose advertised protocol range does not contain it, so
it cannot promote a strictly v7 candidate. That one-time major transition must
use the Mac app's manual local Release reinstall runbook:
install the Mac app containing the v7 Gateway payload while preserving
`~/.tron`, verify the registered Gateway, and only then install a v7-only iOS
client. The repository protocol manifest is projected into Gateway payload,
Mac app, and iOS app metadata; launch/build/install validators require one exact
range. A replacement launcher's bundled payload is the migration bootstrap when
a previously selected external payload advertises an older range. Same-major
promotion and rollback treat that rejected external pointer as bounded history
and use the validated signed bundle as their recovery authority; they never
require the incompatible payload to become admissible again. Do not widen the
advertised minimum or allow a mixed v6/v7 pair merely to bypass that handoff.
Ordinary same-major updates continue through the owned Gateway update flow. A
Gateway built before the typed protocol-mismatch close (F-3) still refuses an
unspeakable hello with `1008 "protocol version mismatch"` and no version range,
and mobile clients treat that as a retryable transport failure: every Mac must
run a Gateway that sends the typed close before the phone can stop retrying it
and name the build to update.

Protocol v8 replaces the per-setting RPCs (`settings.update`,
`session.setModel`/`setThinking`/`setContextWindow`/`setTools`, `trust.set`,
`home.configureMemory`) with the one settings change path
([settings model](docs/settings-model.md)). It has no v7 runtime path, so an
older iPhone app is refused with the typed mismatch close rather than failing on
a removed RPC. The v7 to v8 step is the same one-time transition as v6 to v7:
the deployed v7 update helper cannot promote a strictly v8 candidate, so it uses
the manual local Release reinstall runbook, Mac first, then the iPhone app.

Tron Gateway is the minimal always-running Mac service behind the Tron iPhone
app. It embeds the pinned Pi SDK through supported SDK exports. User-facing copy
calls the product and agent **Tron**; source may use Pi-specific names only where
it identifies the backing SDK contract.

## Pi SDK boundary map

`RuntimeSlot` composes Pi's `codemode`, `tool-search`, and `mcp` built-in
extension factories for session runtimes; session-free hook/package loads use
the same composition. The SDK does not load these built-ins automatically.
Scoped `-builtin:<name>` settings decide whether each is enabled. MCP can
activate codemode or tool-search for its exposure needs even when neither is a
`defaultTools` entry.

Pi owns nested execution and canonical session JSONL. Nested tool calls remain
children of their parent result, not independent transcript rows or receipts.
Pi's codemode `image()` label (`[Image saved to <temp path> …]`, written ahead
of each image) stays in canonical JSONL and the model-facing result, but every
client projection hides it (`visibleToolResultContent` in
`src/sessions/projection.ts`): transcript rows and live tool output, result and
partial result. The raw-entry history inspector shows canonical text unchanged.
New sessions materialize at the first user or assistant message; earlier
setup-only state remains in memory, while accepted receipts appended before
that message are flushed with the first persisted message. The
`runtime-registry.integration.test.ts` materialization/reopen cases own this
boundary.

Pi's built-in MCP extension is the sole MCP client and its `mcp.json` files are
the configuration authority. The Gateway binds global config and credentials
to its agent directory, reads trusted-project config only after TrustService
approval, and relays sign-in through the authenticated session operation. See
[ MCP servers](docs/mcp.md) for accepted transport and credential deltas.

Virtual model registrations are replayed by `GlobalProviderResources`; the
picker marks them virtual while assistant rows and effective context limits use
Pi's routed physical model. Usage and cost remain attached to Pi's physical
responses. The process-global Pi markdown/select/settings helpers explicitly
pin the `dark` theme because the Gateway has no terminal and Pi exposes no
per-instance global theme setter; the host-owned RPC callback palette is
independent. P99-19 tracks an upstream setter request.

Jev uses Pi `ModelRuntime.classify()` with TypeSafe's catalog `jev-latest` for
Knowledge and the `jev` tool. Tron retains input bounds,
qualified pre-dispatch price ceilings, assessment versions, and dispatch
certainty; TypeSafe provider credentials remain Pi-owned. Actual TypeSafe model
behavior and price may change without a Tron release.

## Connection boundaries

`ConnectionOwner` owns the generic account envelope for multi-account
integration instances under `state/integrations/connections.json`; it does not
mirror Knowledge evidence, provider checkpoints, cohorts, usage, or remote
receipts. Setup, policy, and disconnect use exact owner-typed commands and
bounded receipts. Runtime bindings are session/generation-scoped admission
projections, not persisted child authority. See [Connection management](docs/connections.md).

### Knowledge connector authority

A legacy catalog with provider-keyed connector rows is not upgraded by startup.
The resolver obtains the Knowledge workspace from `TronWorkspace` and connection
authority from the one `ConnectionOwner`; it never derives one from the other. Owner schema and preserved catalog state are documented in
[Connection management](docs/connections.md).

## Knowledge boundaries

Knowledge state is owned by the Gateway under `state/knowledge`; iOS consumes
bounded pages. A transactional SQLite catalog indexes dates, record heads,
coverage, and lexical search fields while immutable revisions/objects remain
in their owned files. User-initiated startup of the updated Gateway performs the
one-time, data-preserving catalog upgrade before observation admission; reads
never migrate or reset missing state. See [Knowledge storage](docs/knowledge.md)
for publication, paging bounds, upgrade failure, and recovery contracts.
Observation project scope uses the canonical absolute workspace
path (a project reference, not a record filename ID), and each admitted model
cut is branch-lineage-scoped (not the changing leaf), exact, redacted, and
input-bounded. Distinct terminal envelopes retain their own invocation/outcome
when queued. Cancellation or a
configuration/privacy change leaves the cut retryable and cannot publish late.
Admission, retention, redaction, cancellation and recovery bounds are stated
once in [Knowledge storage](docs/knowledge.md).
Branch scope uses append-order first-child continuation, so adding a sibling
never changes the original branch identity. Registered synthesis accepts exact SOURCE, NOTE, and
OBSERVATION revisions, preserves capture disposition, qualifications, contrary
evidence, and privacy scope, and publishes only an unconfirmed agent-derived
note after cancellation/configuration/source fences. Knowledge read pages
continue through complete canonical record sections (including source text,
fields, retention, origins, representations, and assessments); `details` is
not the only route to evidence. Registered recall text includes bounded dated,
attributed, qualified evidence and points to a pinned record/revision read
continuation when needed. `KnowledgeStore` emits the global `knowledge.changed`
invalidation hint after committed mutations, including agent tools, connectors,
and autonomous observations; receipt replays and rejected writes do not emit it.
The hint carries the maximum committed state revision and, when the entire
coalesced window has an exact bounded ID set, the records to refresh. An unknown
or empty ID set in any commit (or a union above 64 IDs) omits `recordIds` for the
whole 250 ms window, requiring a full relevant-projection refresh rather than a
partial targeted patch. The intent resets with the next window. Clients re-read
authoritative pages rather than treating the event as a data mirror, and the
Sources library reads bounded rows
(`projection: "sourceRow"`, capability `knowledge-library-rows.v1`) with batched
previews (`knowledge.previews.read`) instead of full records.
Curation (`knowledge.source.curate`, capability `knowledge-curation.v1`) writes
summaries, vocabulary tags, verdicts, placement and relations as interpretation
through the same owner, one receipted mutation per item, so a batch reports each
entry's outcome and a replay resumes it; summary generation and Jev re-tagging
are owned background work whose state the agent observes (`knowledge.curation.jobs`)
instead of holding a request open. Their terminal `knowledge.curation.job`
events carry the job identity/status and outcome/error metadata; clients query
canonical job/record state after the event. The event list also includes
`knowledge.changed`, a short-window coalesced state-revision invalidation after
committed Knowledge mutations. See [Knowledge storage](docs/knowledge.md#curation-and-enrichment).
Retained source objects are available only through
`knowledge.object.read` with the exact owning record ID and committed revision;
the store rechecks current privacy/exclusion fences after byte I/O and never
uses a hash-only corpus scan. Excluded/forgotten records cannot authorize
object reads.
Connector X runs require a host-qualified account price, explicit paid
access, and a one-attempt allowance reservation/debit; unknown pricing or a
positive budget alone never permits an API call. The read-only `knowledge.raindrop.read` surface verifies the configured numeric
Raindrop user ID against `/user` on every request, then returns bounded raw
metadata for root/child collections, collection detail, paged bookmark search,
individual items, tags, and highlights. It uses the Mac Keychain credential owner,
never follows redirects, preserves provider fields in `details`, and exposes
explicit page continuation without claiming an atomic snapshot. Oversized
metadata fails closed rather than truncating. The agent-facing `raindrop` skill
covers secure manual Keychain setup, the numeric account-ID prerequisite, and
metadata-versus-article-content limits. Remote Raindrop moves
re-read the exact current source revision and connector account/write policy
after preflight before persisting or applying the effect. Native note/correction
mutations carry an explicit confirmation
bit; agent-tool notes remain agent-authored and unconfirmed. `knowledge.status`
returns typed coverage counts (`observedCount`, `emptyCount`, `excludedCount`,
`pendingCount`, `failedCount`, `unavailableCount`, and `remainingCount`), while
`knowledge.observation.coverage` returns bounded canonical coverage pages with a
`nextCursor`. A page can carry an optional `dispositions` filter (capability
`knowledge-coverage-filter.v1`), so a client that lists cuts needing attention
reads only those rows instead of paging a ledger that is mostly settled; the
cursor stays anchored to the same `recordedAt` index. `remainingCount` means
pending, failed, or unavailable cuts—not empty or
intentionally excluded scope. Recovery preserves the admitted terminal outcome
only when its canonical Gateway invocation receipt is present and unambiguous;
otherwise it marks the cut unavailable with an explicit reason.

## Pi SDK maintenance

Provider IDs and credentials follow the Pi catalog. Tron does not migrate or
alias a retired provider ID (including `azure-openai-responses` to `azure`), so
persisted selections that name a removed ID may no longer resolve.

`packages/gateway/package.json` is the sole Pi SDK version authority. The four
runtime dependencies (`pi-agent-core`, `pi-ai`, `pi-coding-agent`, and `pi-tui`)
must always be exact, equal versions. The checker validates every recognized Pi
SDK package actually present in npm's lockfile and installed tree against that
cohort and the canonical registry; it does not require optional historical
packages that a newer coding-agent no longer depends on. The published package
preflight covers the known family (`pi-client`, `pi-protocol`, `pi-telemetry`,
and `chord` included); 0.87.1 adds `chord` and removes coding-agent's direct
`pi-client`/`pi-protocol` dependencies. The checker also recognizes legacy
coding-agent shrinkwrap entries when they occur in a rollback dependency graph;
those entries may omit integrity while retaining a canonical registry URL. The
executable authority is npm's `node_modules/.bin/pi` projection: it must
be a symlink to the declared `bin.pi` executable inside `pi-coding-agent`, and
payload runtime aliases must target `../../app/node_modules/.bin/pi` exactly.
Check the source state offline with `npm run check:pi-sdk`. Staged production
payloads intentionally omit development-only `pi-sdk-baseline.json`; validate
those trees with `node scripts/check-pi-sdk.mjs --runtime-tree <app>`. Run the real-boundary script tests with
`npm run test:pi-subagents-scripts` and the isolated sequential rollback matrix with
`npm run test:pi-sdk-rollback`. The rollback matrix seeds and rereads the
persisted stores it owns — session JSONL, settings, auth, `mcp.json` (written by
`pi mcp add` and read back with a hyphenated server name) and the MCP OAuth
credential store — in both directions, and names the on-disk credential keys when
a runtime cannot resolve what the other wrote. Only the rollback runtime may
report that it has no built-in MCP surface; a candidate that drops or moves it
fails instead of passing as unsupported. A store whose re-keying the maintainer
has accepted as a one-way rollback delta is listed in `pi-sdk-baseline.json`
under `knownOneWayDeltas`: an exact `{store, from, to, reason, rollbackState,
credentialKey}` entry that names the one observation it accepts, so every other
runtime, step, state, tool list and key still fails, and an entry whose delta is
not observed fails as stale. The committed `pi-sdk-baseline.json` records the
prior runtime used for rollback verification and any accepted one-way delta for
that version range; `package.json` remains current-version authority. Run `node scripts/compare-pi-sdk-graph.mjs BASE HEAD`
to compare the complete resolved dependency closure reachable from the direct Pi
family, without treating unrelated lockfile churn as an SDK change. When that graph
changes, run the networked rollback matrix (`npm run test:pi-sdk-rollback`) and the
iOS/Gateway boundary (`scripts/ios-gateway-e2e-test`) as direct
journeys; hosted CI runs neither.

A maintainer updates the family only with `npm run update:pi-sdk -- <exact-version>`
from a clean `package.json`/`package-lock.json`. The helper preflights every
family package through the current npm and prints bounded preflight evidence for
version, source revision, integrity, and the registry-declared Node engine; it updates all four direct pins
in one native `npm install --save-exact --engine-strict` operation, validates the
resulting lockfile, runs `npm audit signatures`, and restores its owned
manifests plus the disposable installed tree with `npm ci` on failure. On
success it also extracts the released `CHANGELOG.md` sections between the current
and target versions from the coding-agent package it installed and writes them to
the run's evidence under the git directory
(`work/issue-<N>/pi-sdk-changelog-<from>-to-<to>.md`, or `work/pi-sdk-update/`
outside a task branch), so the per-seam inventory starts from upstream release
notes instead of a hand-read changelog; an update whose changelog carries no
delta fails and restores. Do not submit independent
Pi package updates, hand-edit lockfiles, run Gateway deployment/lifecycle
commands, or promote/restart a Gateway as part of this process.

### Tron-patched `pi-coding-agent`

The Gateway needs the SDK's `projectDir` option (the Project layer is the
worktree root's `.pi/`, see [Project root](#project-root)), an `AgentSession`
that dequeues a delivered image-only steer or follow-up (upstream removes a
delivered queue entry only when its text is non-empty, so a photo-only queued
message stayed in Pi's queue and in every snapshot's `queuedItems`, #974), and
normalization of a queued steer's or follow-up's images for the active model as
`prompt()` does (upstream queues them as supplied, so an oversized photo entered
canonical history and failed every later request, #408). No published release has
any of them. Until one does, `pi-coding-agent` comes from a Tron-built tarball
instead of the registry, at the same version as the rest of the family.
`pi-coding-agent-patch.json` is its only owner. It records the upstream tag and
commit, the published tarball's integrity, the upstream proposal commit the patch
backports, the patch's SHA-256, the published `pi-ai` model data that release
bundled, the Node/npm toolchain, and the built tarball's SHA-512, under
`third_party/pi-coding-agent/` with the upstream MIT `LICENSE`. `package.json`
names the tarball as `file:third_party/pi-coding-agent/<file>.tgz`, so
`package-lock.json` binds its bytes with npm's own integrity and a clean `npm ci`
needs no other input. `npm run check:pi-sdk` accepts exactly that declaration:
the direct dependency, the lock root and lock entry must name the declared
tarball and integrity, the tarball and patch must match their digests and the
license must be present; without the declaration a `file:` dependency fails as
before (`npm run test:pi-sdk-scripts` runs the checker against the real files and
single-fault copies). Packaging stages the declaration and tarball before `npm ci` in the app
payload, and a source update refreshes the declaration with the lock it explains.
The tarball's package version stays the release version, so Pi's own version
checks are unchanged; the lockfile `resolved` value and the declaration name the
patch.

`npm run reproduce:pi-coding-agent` rebuilds the tarball from a fresh fetch of
the tag with the declared toolchain and model data: `npm ci` and
`npm run build:offline`, then a pack of the unpatched package that must equal the
published registry tarball byte for byte, then `git apply` of the patch, a
pi-coding-agent rebuild and a pack that must equal the committed SHA-512
(`--upstream <path>` uses a local clone). The tarball therefore differs from the
registry release only in the patched modules, their declarations and maps, the
bundled CLI chunks and two docs pages. After a deliberate patch change, `--write`
replaces the tarball and records its SHA-512 and the patch SHA-256; then refresh
the lock with `npm install`. Moving the patch to another release means updating
the declaration's `version`, `upstream`, `modelData` and artifact path, rebasing
the patch onto that tag, and running `--write`.

`npm run update:pi-sdk` refuses while the declaration exists. When a release
ships both changes (the declaration's `removeWhen`), remove the patch in one
change: set `pi-coding-agent` in `package.json` back to the exact release
version, delete `pi-coding-agent-patch.json`, `third_party/pi-coding-agent/`,
`packages/gateway/scripts/build-pi-coding-agent-patch.mjs` and its `reproduce:pi-coding-agent`
script, drop the declaration from `packages/mac-app/scripts/stage-gateway-app.sh`
and the `BUILD_INPUT_FILES` of `scripts/gateway-install-inputs.mjs`, run
`npm install` so the lock returns to the registry entry, then
`npm run update:pi-sdk -- <release>`.

### Tron-owned `pi-subagents` build

The delegated provider is distributed separately from the Gateway's Pi SDK. Its
single source of version authority is `pi-subagents-pin.json`: the fork commit,
source archive SHA-256, fork lockfile SHA-256, Node/npm build versions, and
SHA-512 of the self-contained closure are bound together. `npm run
check:pi-subagents` validates both selections' immutable inputs and package
identity, compares source/closure runtime declarations, and traverses the complete
lock-resolved runtime graph without registry access. Every direct or transitive
non-peer dependency must resolve within the closure at the exact locked package
path and version, with matching runtime declarations and installed npm lock
`resolved`/`integrity` values. Nested versions, scoped packages, hoisting and cycles
use the same graph check; an unpinned nested package cannot shadow a checked
hoisted dependency. Pi host-provided peers are excluded, not dependencies merely
sharing a peer's name. The integrity trust chain has three links: build-time
`npm ci` verifies dependency tarballs against the lockfile SRI, deterministic
packaging pins the resulting closure bytes with SHA-512, and the offline checker
verifies that digest plus graph completeness and installed lock metadata. It does
not attempt to recompute original registry-tarball SRI from extracted files.
A retained predecessor
pin must bind its exact source archive, lockfile, and self-contained closure;
a fork predecessor carries the complete prior build provenance, while a registry
predecessor also binds registry integrity. A partial rollback record is rejected. The retained
`0.59.0` predecessor uses the public npm registry archive, verified against its
`dist.integrity`. Its vendored runtime lock preserves the coordinator-extracted
dependency records and versions, with a root derived from that archive's manifest;
no development dependency versions are inferred. Source archives and lockfiles
are retained under `artifacts/`; build the deterministic closure with `npm run
build:pi-subagents-closure` using the Node/npm toolchain the pin records
(`nodeVersion`/`npmVersion`, which may predate `.node-version`; select it with
`TRON_NODE_BIN`). The builder
reads the top-level pin selection; rebuild a predecessor in a disposable copy
with its version and artifact inputs selected, never by changing a live install.
`npm ci` validates even omitted development dependencies, so the builder removes
them only from its temporary install manifest. The packaged manifest preserves
the source metadata, including development dependencies, and adds sorted
`bundledDependencies`. `npm run test:pi-subagents-scripts` includes a real npm
runtime-only-lock regression with an unavailable registry.

Prepare a new reviewed commit with `npm run update:pi-subagents -- --fork-repo
<path-or-url> <full-fork-commit>`. The pin's `fork.repository` is null until a
public fork URL is recorded; offline consumers never require that repository.
Once recorded, the URL is the updater default and a different override is refused.
The updater checks the exact pinned upstream release/tag and the fork's ancestry
online, reports latest upstream for information only, and exports immutable git
objects into a disposable tree. It uses the repository-pinned Node/npm
(`.node-version`, `TRON_NODE_NPM_VERSION`), and records them in the candidate, to install build
dependencies, run `npm pack` (including the fork's packaging scripts), and build
the closure. The candidate must have a new exact upstream-based `-tron.N` version.
Before publication, the exact staged candidate must pass the offline real-Gateway
activation/discovery/child-execution gate and the mandatory previous → candidate
→ previous execution/resume probe. Both use disposable payloads and isolated homes;
no repository pin or immutable artifact is published while either gate runs.
Their passing JSON reports accompany the command result. Any gate failure refuses
the update and removes its staging; original pin/artifact bytes remain unchanged.
Only then does it exclusively create new immutable artifacts and atomically
rename the pin, retaining the complete current pin (including fork provenance)
as previous. A final
`npm run check:pi-subagents` failure restores the original pin and removes only
newly created files. The private `.pi-subagents-update-staging` directory is
also the exclusive invocation lease; overlapping updates are refused. An
uncatchable termination leaves it in place: inspect the interrupted owner before
manually removing staging, never sweep another update's files. Dirty owned
inputs, reused artifact paths, and mismatched provenance are refused. The updater never edits fork refs/working-tree files or
installed Gateway homes, deploys, or starts a service. `test:pi-subagents-scripts`
covers real local-git export/pack/build/check, both execution gates, unusable
candidate and return-leg resume refusal, and late-failure restoration; only the
online release metadata boundary is faked in those tests. The successful update
regression compares the complete retained prior pin unchanged (repository,
commit, source/lock/closure paths and hashes), and real previous/return legs
require its exact fork-bound receipt. Work verification selects the offline
checker and script suite for provider pin/artifacts/scripts, package manifests,
and Node pin changes, not unrelated runtime sources.

The closure excludes Pi SDK peer dependencies so those resolve from the selected
Gateway SDK, not from a user npm tree. Gateway payloads carry the pin, input
archives, and closure as fingerprinted app inputs; bundling refuses an invalid
pin. This does not install the package into Stable or mutate a user's package
manifest. The provider install/activation lifecycle is managed by Tron and is
not an ordinary user package update.

After building, `npm run install:pi-subagents -- <gateway-home>` explicitly
extracts the selected closure offline into
`<gateway-home>/internal/pi-subagents/<version>`. It stages files and a receipt
(version, fork commit, closure SHA-512) together, verifies them, then publishes
by directory rename. Failed staging is removed; an existing valid root is reused,
and a damaged root is refused rather than overwritten in place. Previous version
roots are not pruned. This activation entry point never defaults to a home and
never edits `agent/npm/package.json`, runs npm installation, or downloads bytes.
Every Gateway startup activates the exact closure carried by its selected
payload, after delegated-root cutover admission and before Pi extension discovery.
A verified existing root is reused without changing files or its receipt; a
missing root is installed offline and damaged bytes/receipts fail startup closed.
There is no channel-dependent installer, registry fetch, or user package update.
`scripts/tron dev start` therefore builds/stages the Debug payload and its startup
installs or verifies that payload's pin in `~/.tron-dev/internal/pi-subagents/`.
Restart and rollback derive their selection from the newly selected payload.

**Stable installation is maintainer-only:** update/promote the reviewed Gateway
payload using the supported Stable payload workflow (or the Mac Release reinstall
runbook if the installed launcher cannot select it). Startup of that selected
payload performs the same offline activation in Stable's home; no separate agent
install into Stable is authorized. Previous roots and all historical runs remain
untouched. Remove an explicitly reported user-provider conflict yourself; Tron
never edits that user declaration.

One `ManagedSubagents` selection belongs to the Gateway payload and configured
home, including when the agent directory is customized. Runtime extension loads,
session-free admin loads, subagent discovery, `session.resources` and the managed
`packages.list` row use that selection. Admission revalidates the receipt and
every installed closure file against the pinned archive; a receipt alone cannot
bless changed bytes. SDK peer ranges are checked against the selected Gateway payload. Pi's extension
loader aliases their imports to its own host SDK exports; no SDK peer copies or
links are installed, so a new Gateway payload can reuse the same immutable root.
Before any managed extension load (including reload and session-free loads),
`ManagedSubagents` requires `PI_SUBAGENTS_TEMP_ROOT` to resolve exactly to
`delegatedArtifactRoot(tronHome)` for its explicitly supplied home. The registry
also passes its home to this owner before constructing runtime dependencies,
refusing a selection belonging to another home. Admission
rechecks the binding after loading; an absent, blank or foreign binding fails
with `conflict` rather than allowing the provider's system-temp fallback.
In-process hosts and test fixtures must bind through
`delegatedProviderEnvironment` before loading, and fixtures restore the previous
environment only after runtime disposal and remove their own temporary homes.
The real execution integration test asserts that no default
`<os.tmpdir()>/pi-subagents-uid-<uid>` root was created.
Before provider initialization, the delegated-provider environment owner also
sets `PI_SUBAGENTS_PI_CODING_AGENT_PACKAGE_ROOT` to the running payload's own
resolved `@earendil-works/pi-coding-agent` package root, replacing any inherited
override. This process-lifetime binding lets the reserved provider's detached
children use the selected host even when argv is not a Pi CLI and the reserved
install has no SDK ancestor. Restart/rollback selects the new process's host;
no SDK files or links are added to the provider install. They never resolve from
user or global npm. Arbitrary shell commands still filter `PI_*`; this binding
is for the provider's own children, not a shell command environment.
The verified manifest also supplies its declared `pi.skills` and `pi.prompts`
paths to Pi's `additionalSkillPaths` and `additionalPromptTemplatePaths`. Files
and directories must remain inside the same verified root; user-package
resource resolution is not used to recover these declarations. The same manifest
owner uses Pi's local-package resolver to expand exact admitted resource files
and attach managed package provenance. Both session resources and `packages.list`
consume that result; ordinary local resources are not relabelled. Pi finalizes
extension metadata after its override, so load completion also restores exact
managed tool/command provenance before publishing the load. The SDK owns resource
loading and replacement on reload.
The exact loaded extension gets a build-bound `tron:pi-subagents@…#…` owner;
user npm sources and provider-shaped local paths grant no delegated authority.
The existing per-extension registration admission also reserves `subagent` for
that owner at load and for late registrations; it is not a one-shot load check.
User or project `npm:pi-subagents` declarations are ignored, never executed,
and never contribute resources or the reserved tool. The managed pinned provider
still loads; no settings or user npm-tree bytes are changed. `packages.list`
retains the declaration with a typed `conflict` (`code: managed-provider`) and
empty `provides`, alongside the managed provider's row. Settings labels it
“Ignored” and displays: “Tron manages pi-subagents; this user declaration is
ignored. Remove it with `pi remove npm:pi-subagents`.” Cleanup is optional.
One `pi-subagents.user-package-ignored` warning per runtime startup/reload or
session-free load reports the exclusion without exposing user paths/specs.

The pinned Pi SDK's `DefaultResourceLoader.extensionsOverride` executes after
module loading, so it is not an exclusion seam. `managedProviderSettingsView`
supplies the resolver's `getGlobalSettings`/`getProjectSettings` package reads
(and `getSettings`/`getPackages`) with a read-only filtered projection, including
pre-trust, final and reload passes. The SDK's `DefaultPackageManager.resolve`
uses these scoped reads; its package persistence paths use `setPackages` or
`setProjectPackages`, which the view refuses, as it does package-bearing
`applyOverrides`. Other calls bind to the canonical manager; non-package writes
persist canonical unfiltered snapshots. Package admin retains its canonical
manager for inventory/mutations and uses the view only for resource resolution.
Any other extension claiming `subagent` still fails admission, including late
registrations. Missing installation
leaves delegated discovery unavailable in read-only/unactivated fixtures; managed
startup activates it before discovery. Corrupt bytes or receipts fail closed. Catalog and package reads retain their
bounded unavailable diagnostic. `managed-subagents.install.integration.test.ts` installs one real
immutable closure per file and shares it among admission/discovery cases;
destructive byte/receipt cases own separate state. The two cold real-loader
cases have measured, explicit deadlines for parallel verification.
It exercises the real
closure and SDK loader/discovery in an isolated empty home, plus exact host SDK
export identity across two payload paths sharing one install.
`managed-subagents.integration.test.ts` invokes the same startup activation
boundary as `gateway-main` from an empty agent home and npm cache with npm offline
and all TCP denied, verifies a second startup preserves root/receipt inode and
mtime, then runs a
real foreground child through `RuntimeRegistry` / `RuntimeSlot` and the host SDK.
Only model output is scripted. It checks packaged/project discovery, the
build-bound canonical activity owner, successful child completion, canonical
child JSONL, the Gateway's matching child-session reference, and read-only
transcript admission/projection through that declared child binding. Damaged bytes
and receipt restart refusals are covered by `managed-subagents.install.integration.test.ts`.
Regenerate its
sanitized evidence with
`npx vitest run src/sessions/managed-subagents.integration.test.ts --maxWorkers=2` from the
Gateway directory; the report is `test-results/managed-subagents.integration.json`
(or `TRON_SUBAGENTS_REPORT` for an external evidence destination).

`npm run test:pi-subagents-rollback` runs the real previous → candidate → previous
sequence against one isolated home. Each leg loads a fresh Gateway runtime with
the selected exact closure, discovers packaged/project agents, and completes a
real foreground child. The return leg reconstructs the candidate parent, reads
its retained run through the previous provider, refuses terminal live control,
and resumes the candidate child through the producer's documented `action: resume`
management API. Revival is detached even with `async: false`: the probe awaits the
same canonical child identity/output and the producer's observed runner/writer
exit-0 proof, then reads terminal producer status. Fixture retirement is a
separate test-support process owner: each leg records native spawn handles/PIDs
and detached groups, propagates its scoped `--import` preload to runner descendants,
and stops/joins the trees before retiring HTTP state or removing roots. Normal
exit, assertion failure and termination signals all use this owner; TERM is
bounded and escalates once to KILL. Disposal confirms no owned non-zombie
PID/group members remain and direct child exit events have settled, never
retrying directory removal. Zombies cannot write; their reaping belongs to the
parent/OS. macOS EPERM during signaling is ignored only after a fresh process
snapshot proves the target is absent or contains exclusively zombies; live
permission failures or failed inspections still reject disposal.
The updater supplies the exclusive `TRON_TEST_PROCESS_OWNER_FAILURE` JSONL path
inside its staging owner, outside disposable leg roots. Join failures record
unjoined live PIDs, attempted signals and the error there. The owner regression
suite keeps this record outside its disposable writer root and includes it plus
host stderr in exit assertions, so a failure is diagnosable from one test log.
Any record fails the update,
restores owned publications and preserves staging for explicit diagnosis; a
later update refuses that still-owned staging directory. Standalone probes own
the same failure record within their fixture root and likewise refuse removal. Scripted model responses are
turn-addressed, not globally queued, so parent notifications and the revived
child cannot steal each other's responses. The fixture supplies the same reserved
delegated-artifact root and process-owned Pi host binding as Gateway startup,
before extension initialization. Its return-leg detached resume proves the host
binding works from a reserved install, including overriding an unavailable
inherited host selection.
The original parent/child JSONL prefixes and all other retained session-tree run
artifacts must remain unchanged; supported continuation appends canonical history rather
than converting it. Both immutable installs/receipts survive rollback. Only the
loopback model endpoint is scripted, including for the predecessor's CLI child.
The loader and admission use the verified manifest's `pi.extensions`, not a
candidate-specific filename; empty, escaping, missing or non-regular entries
fail closed before loading. The suite also exercises invalid entries in actual
receipt-verified closures.

The sanitized report defaults to `test-results/managed-subagents.rollback.json`;
set `TRON_SUBAGENTS_ROLLBACK_REPORT` to retain it elsewhere. To inspect the whole
disposable home, set `TRON_SUBAGENTS_ROLLBACK_ROOT` to a **nonexistent** evidence
directory; the probe refuses to overwrite an existing fixture. Without that
explicit retention request, it removes the fixture on success and failure.
Payload source copies always retire after the probe. This gate selects provider
versions with the current Gateway/SDK, not historical Gateway executables or a
Stable/Debug service transition. Actual service qualification and the broader
detached/live control matrix remain separate release gates.

After `npm run build`, run `npx vitest run
src/sessions/managed-subagents.payload.integration.test.ts --maxWorkers=2` to execute the
bundler's real app-input staging step and activate that staged compiled runtime
with TCP denied. It verifies both selections through the same trusted checker
used by the payload verifier, proves the shipped installer is usable, and rejects
a damaged retained closure. The report is
`test-results/managed-subagents.payload.json` (or `TRON_SUBAGENTS_PAYLOAD_REPORT`).
It shares the selected SDK dependency tree only; pin/artifact authority comes
exclusively from staged app bytes.

`test-fixtures/pi-sdk/corpus/` is the persisted-state upgrade corpus (epic #468,
layer L1): an agent directory and canonical sessions the **outgoing** SDK wrote
through the real Gateway, plus the Tron-level observation of that corpus reopened
from a staged copy. It is generated, not hand-authored — `npm run
record:pi-corpus` runs the recorder under the installed SDK, and
`vitest.corpus.config.ts` owns that run because recording rewrites committed
fixtures. Regenerate the corpus with `npm run record:pi-corpus` **before** bumping
the family, so `src/sessions/pi-persisted-state-corpus.integration.test.ts`
reopens state the previous SDK actually wrote and fails when an existing session,
per-chat tool selection, model, saved provider key or MCP credential stops
resolving. `test-fixtures/pi-sdk/README.md` describes what the corpus contains and
which values are environment tokens.

After each candidate update, inventory every release-note/API/documentation delta
against its owning Gateway seam and record whether it is inherited, adapted with
evidence, deferred with rationale and acceptance criteria, or not applicable.
Review the concrete seams, not just the package build: custom `StreamFn` wrappers
and request context in `src/runtime/`, canonical session entries and mobile
projections/history in `src/sessions/`, provider catalogs and source-preserving
media paths, and Pi-owned extension registration/lifecycle in
`src/extensions/compatibility-manifest.ts`. Pi 0.87 `context_edit` records remain
canonical JSONL entries but are not chat rows; branch projection, restart/resume,
compaction and export/import must preserve the edited model context. Gateway
session import creates a new canonical identity with `SessionManager.forkFrom`
while retaining imported entry IDs and branch references, rather than replacing
a source session. The SDK-written `parentSession` header is provenance to the import
input path, which can be removed with the upload; it is not a guaranteed
navigable parent. Imported entries remain self-contained for reopen and context. Pi 0.87 also applies the active model's initial image-resize
profile before attachments, `read` results and tool-result images enter history;
Gateway must preserve the source upload and avoid pre-resizing prompt images a
second time. `UploadStore` inlines only png, jpeg, gif and webp uploads; any other
`image/*` is claimed as a path-envelope file attachment. The Tron-patched Pi
normalizes a queued steer's or follow-up's images as `prompt()` does (#408), so
the Gateway does not resize them a second time. Queue replacements prepare and
publish entries in requested order: resizing a photo must not let a later text
entry overtake it. An inline image a provider rejects would be replayed by every
later request in its session (#407). Update
focused owner tests and this boundary map when ownership changes. Keep a
candidate's detailed version matrix in its GitHub epic until closeout; do not
turn this paragraph into a second change tracker.

Every Pi union Tron switches over or maps is classified at compile time, so a
candidate that adds a member cannot ship it silently ignored. The extension seam
is inventoried in `src/extensions/compatibility-manifest.ts`; the session seam is
classified in `src/sessions/projection.ts` (canonical entry types, message roles
and content blocks, including which entries become chat rows and which become
outline nodes), `src/sessions/history.ts` (the published entry set and its node
kind) and `src/sessions/runtime-slot.ts` (`AgentSessionEvent`). Every one of those
switches ends in a `never` default and the node-kind map is a `satisfies
Record<…>` over declared kinds, so a new member fails `npm run build` and names
the owner and the member. To prove the gate, add a synthetic member to the union
declaration in the installed SDK's typings and run the build.

Live and cold transcript reads use the bounded `projectTranscriptPage` and
`projectTranscriptPageAfter` paths. Transcript fixtures use those same readers,
not a separate unbounded projection implementation.

### Pi SDK behavior trace

`src/sessions/sdk-behavior-trace.integration.test.ts` owns the behavior seam of an
SDK upgrade: what the pinned SDK makes Tron *emit, persist and send*. One
deterministic faux-provider scenario runs through the real Gateway
(`RuntimeRegistry`, `RuntimeSlot`, and Pi's own codemode/tool-search/mcp
built-ins) and covers streamed text and thinking, a direct tool, codemode with a
nested call plus `models.classify()` and `image()`, direct and codemode-exposed
MCP tools from hyphenated fixture servers, tool search over the tool the
codemode exposure keeps undeclared, steer and follow-up, abort, and manual
compaction. Its normalized trace is compared byte-for-byte with
`packages/gateway/test-fixtures/pi-sdk/sdk-behavior-trace.golden.json`.
Its explicit Chat model selection also persists `tron.settings.v1` with the fixed
model source/reference and command receipt before the following invocation.
That settings lineage is canonical behavior, not noise to prune from the trace.

The trace records each distinct provider request's declared tool names,
system-prompt section headings, a hash of the normalized prompt text and how
many consecutive requests it covers; the TypeSafe classifier request the
codemode step makes, so a classify delta is shown rather than inferred; every
client broadcast topic with the union of its payload structure; every canonical
JSONL entry; and the slot's transcript projection. Ids, timestamps, durations,
counters, the disposable temp root and package paths are normalized, and
host- or checkout-derived numbers (`usage`, `cost`, `stats`, and the compaction
entry's `tokensBefore`, which Pi estimates from the serialized context) are
compared as structure only. A diff therefore means a behavior change rather than
a new run or a different checkout.

Two things the trace deliberately does not compare. A tool search that loads from
*several* servers orders its tools by server connection order, so the scenario
keeps a single searchable server. And a live-progress subtree (`streaming`, the
live `toolExecutions` list, `partialResult`, `nestedCalls`, and the in-flight
`message` of the progress topics) is pruned from an event's shape, because
whether a run observed it is host timing rather than SDK behavior; its settled
form is recorded by the transcript projection.

Run it with `npm run test:sdk-behavior-trace`. A mismatch prints a unified diff
and retains the full diff at `test-results/sdk-behavior-trace.diff` and the exact
trace at `test-results/sdk-behavior-trace.actual.json`; the same comparison by
hand is `git diff --no-index --no-color --unified=3 <golden> <actual>`. An
intended change updates the golden with `npm run update:sdk-behavior-trace`
(`TRON_UPDATE_SDK_BEHAVIOR_TRACE=1`), which prints the hunks it accepted. A
second case runs the same scenario on one busy event-loop thread with an injected
delay on every provider response, and must produce the same trace — so the golden
cannot encode host timing, and only the idle case may write it. The scenario
asserts that its own steps succeeded before the golden is accepted, so a golden
cannot record a degraded scenario (a tool that was never active, a search that
never ran) as correct behavior.

The golden is darwin-specific: Tron's `computer` module registers only on darwin
and its description and rule lines reach the prompt. The Gateway check that runs
this file is macOS. Tron-owned prompt text (Tron's tool snippets, rule lines and
operating context) is part of what the model is sent, so it is part of the
golden: a Tron change to those surfaces updates this golden in the same pull
request, and the diff names exactly which text moved. Keep the full field: it
contains Tron-owned prompt text alongside the SDK's own tool declarations, so
masking one would hide changes to the other.

After each candidate update, run the focused SDK checks, Gateway build and
owning runtime tests, then the full required Gateway/Mac/iOS validation. Treat
any event, persistence, projection, packaging, UI, or UX difference as a
behavior-delta stop: do not normalize it silently; compare current and candidate
behavior and obtain an explicit product decision before continuing. For this
seam, the comparison is the trace above: review its diff hunk by hunk, classify
each hunk as inherited, adapted with evidence, or not applicable, and only then
update the golden. A hunk the reviewer cannot explain is the stop, not a reason
to normalize the trace further. Keep candidate-specific evidence and accepted
exceptions in the issue and the owning focused documentation rather than
repeating the ledger here.

## Ownership

Gateway owns only mobile infrastructure:

- one-time enrollment, hashed device credentials, revocation, and rate limits;
- authenticated HTTP uploads/blobs and JSON WebSocket requests/events;
- one serialized mutation lane and one live runtime per canonical session;
- detached run supervision, bounded idempotency receipts, and crash markers;
- authoritative transcript snapshots projected from canonical JSONL;
- filesystem/Git browsing, bounded uploads, durable display artifacts, and bounded PTY replay;
- settings, credentials, packages, trust, custom-model administration, generic
  extension UI forwarding, and bounded push-notification admission. Extension activity history revisions are
  derived from the globally sorted canonical receipt sequence; filters and
  duplicate-content collapse select page content but never change revision
  identity, and each list cursor additionally binds a bounded fingerprint of the
  exact filter that produced its offset so a cursor cannot be replayed against a
  different filtered projection at the same revision. Component placement metadata is committed only with registry
  admission, so bounded capacity failures cannot orphan surfaces.

Bounded ambient extension-artifact discovery is owned by `src/sessions/extension-artifact-discovery.ts`; `RuntimeRegistry` keeps its discovery timer, in-flight guard, and shutdown admission.

The embedded runtime remains canonical for sessions, provider/model semantics,
credentials, settings, packages, resources, compaction, and retries. Gateway
does not maintain a session database or event journal. A process lock is held per
agent directory and any configured external session directory because the session
format has no cross-process lock; another Gateway must use separate canonical
storage, not the same JSONL tree. The aggregate runtime-lock release is shared and
idempotent across concurrent shutdown callers. Runtime `sessionDir` changes are rejected until
the Gateway is stopped and restarted; the runtime also snapshots the admitted
session directory at startup so an out-of-band settings edit cannot redirect
new work around the ownership lock.

The settings schema exposes only SDK settings the embedded runtime
or a Tron client consumes. Terminal-only presentation settings (thinking-block
hiding, cache-miss notices, skill-command autocomplete, markdown rendering, the
Anthropic extra-usage warning, analytics, and the branch-summary skip prompt) are
not projected or declared, so no change can write them; values already in `settings.json` are left
untouched. `telemetry.install` remains because the SDK uses it to gate provider
attribution headers.

`settings.resolve { target, keys? }` is the settings model's resolver
([docs/settings-model.md](docs/settings-model.md), advertised as
`settings-model.v1`). `target` is `{ kind: "mac" }`, `{ kind: "project", cwd }`,
`{ kind: "session", sessionId }` (the client must have opened the session) or
`{ kind: "home" }` (Home's profile). Every key declared once in
`src/admin/settings-schema.ts` is returned with `{ value, display, layer,
applied, reason?, origin, badges, layers[] }`, where `layers[]` lists each layer the
target has and what it holds. The resolver (`src/admin/settings-resolver.ts`)
takes the topmost layer that the target has, that holds the key, that the key
allows, and that is applied: ordinary Session > Project (`.pi/` at the canonical cwd pi reads) > Mac (`<tronHome>/agent/settings.json` and `trust.json`) > Built-in. Home instead has its chapter Session/launch inputs > Home profile > Mac > Built-in, never Project. Ordinary sessions never gain Home profile. Model specificity wins only within a scope, not across scopes. An untrusted project's values are returned with
`applied: false, reason: "untrusted"` and never apply; reading them is JSON
parsing only. A value stored at a layer the key does not allow is reported in
`diagnostics` and ignored. A thinking level the resolved model does not support
resolves to pi's closest level with a Clamped badge. Redacted keys (`httpProxy`)
return only "Set" or "Not set". `settings-model.integration.test.ts` compares
real Gateway resolutions with the SDK over filesystem-backed stores, including
fallback to built-ins after stored values are removed. It does not claim that a
documentation-string scan proves every SDK setting or runtime applier is covered;
that inventory and the real-runtime journeys remain separate acceptance work.
With `renderer: { version, controls[] }` (doc 7.5) each key also carries
`presentation` (`label`, `help`, `order`, `importance`, the negotiated `control`
and `note`, `valueKind`, static `options`, `range`, `optionsSource`, `confirm`,
`redacted`), and the response carries `renderer: { version }` and `sections[]`
with `{ id, title, description, order, note?, chatInline? }` (doc 7.2). Section
membership and chat inline/subsheet placement are Gateway declarations shared by
Home, Chat, Project and Mac settings. Compact list/model/tool counts are row
`display` values; typed values and full history formatting remain unchanged.
Fixed-source badges keep value evidence in `detail`, not in their short label. The control is the declared one when
the client names it, else its fallback, else `readOnly` with the note "Update
Tron to edit"; a client that sends no `renderer` gets every editable key
read-only, always with its `display`. Presentation and summaries are
`src/admin/settings-presentation.ts`. `settings.options { target, key,
qualifiers?, query?, cursor?, limit? }` serves a key's choices: its static
options, or its `optionsSource` (`catalog.models`, searchable and paged;
`catalog.thinkingLevels` for the `model` qualifier or the target's chat model,
empty for a model without reasoning; `catalog.contextWindow` as a `range` with
the bounds `settings.change` enforces; and `catalog.tools`, whose options carry
the selected tool's serializable `resource` record for shared list/detail UI).
`settings.change { commandId, target, fence?, changes[], reason?, dryRun? }` is the one path every setting changes through
([docs/settings-model.md](docs/settings-model.md) 5). Each change is `{ key,
qualifiers?, layer, op: "set" | "unset", value?, expected? }`. The Gateway
validates it against the key's schema entry (type, allowed layer, writer, and the
target having that layer), checks `expected` against the store, applies it through
the key's applier under that store's own lock, appends one entry per key to the
change record, and broadcasts `settings.changed { changeIds, keys, layer, target }`
(plus `trust.changed` for a trust change). A request with several changes applies
them in a fixed store order and rolls back the stores it already changed when one
fails. `dryRun` validates and returns each change's tier and error without applying.
Appliers: the Mac `settings.json` (`updateJsonLocked`), the Project
`.pi/settings.json` (written keeping the file's other keys and indentation, then
staged with `git add` when git can take it, never committed; an unparseable file is
a failed change left untouched; an ignored `.pi/`, no repository or a locked index
leaves the write unstaged with the reason), trust (`TrustService.setAndApply` with
the project runtime reload), the Home profile and Gateway stores (the model fallback queues among them),
and a session's Chat layer through its slot lane (`setModel`, `setThinking`,
`setContextWindow`, `setTools`, and `setChatRunSetting`). Live Run keys with a
Chat binding are resolved at prompt/request admission; explicit
Chat values live in branch-local `tron.settings.v1` entries, survive fork/resume,
and unset back to current defaults. The runtime overlays operational fields
without reloading fixed resources or saving defaults. Its own running settings
tool appends in the lane it already owns. Optional provider timeout/count and
WebSocket timeout are replaced after SDK default composition, at the final
provider-stream boundary under the exact agent request's async context. Unset
cannot resurrect initial SDK values, and unrelated memory/extension requests
retain their explicit options. Ordinary/Home and fork/cold-resume provider
journeys cover that distinction. Directional request settings also retain their
effective value in canonical `requestPins`: image blocking narrows before SDK
message conversion, including within a tool turn; default/outside widening stays
fixed across fork/resume. A Chat-layer approval or maintainer tap can release it;
lowering a risk floor alone cannot. New chats also record fixed model, thinking,
context-window, tools and declared fixed Chat settings with their actual value,
source, time and stable reference. Fork/resume preserve that provenance; a fixed
Chat unset snapshots the current lower-layer default through the normal audited
change path. Inherited snapshots are not explicit overrides in summaries. The
generic native row handles the served reset action, but session-surface adoption
and approved Mac/Project widening propagation remain outstanding. Home rollover
inherits Chat policy and provenance only from the adjacent sealed chapter, using
its live canonical branch or an identity-fenced cold read. Existing successor
recovery never recopies it, and no predecessor messages or audit receipts move.
The `home.chapter-recovery` settings-source reason diagnoses this boundary.
A Chat-layer change needs `fence: {
runtimeGeneration, model?, revision? }`, the runtime the client read; the lane's
idle, chapter and fence guards are unchanged, and the receipt's work entry is the
session's. Keys with no writer (`setup.sessionDir`) cannot change while the Gateway
runs. Every non-iPhone actor must give a `reason`.

The change record is `<tronHome>/gateway/settings/changes/`: append-only segments
of at most 500 entries named in `index.json`, kept forever and never consulted to
compute a value. Each entry holds the actor, target, layer, key, qualifiers,
`before` and `after` (only `changed` for a redacted key), the reason, the tier and
how it was reached, the status (`applied` or `failed` with its reason), the git
result of a Project write, and `undoOf` or `applyAgainOf`. `settings.history {
cursor?, limit?, key?, status?, actor?, layer?, section? }` pages it newest first,
scanning at most one bounded segment per request. Filters intersect; `actor` is
an actor kind or `agents` (all non-iPhone actors, including outside changes).
Omitting it is Everything. `layer` is a writable layer and `section` is a declared
section ID. An empty page with `nextCursor` is not the end: continue until the
cursor is absent. Settings summaries traverse this same API up to their fixed
200-entry recent horizon, so a segment rollover does not hide recent changes.
Each returned entry adds schema-owned `presentation` (label, section when declared,
actor, layer, and before/after display strings). This projection never rewrites the
record. Retired keys retain their key ID and recorded JSON display; redacted entries
expose only Hidden → Changed, never raw before/after or fixed values. Outside
changes are labeled Outside Tron, not You. Native clients need no key-formatting map.
`settings.undo { commandId, changeId, fence? }` writes `before` back as an
ordinary change, refused with the current value when the store no longer holds
`after`, and refused for a redacted change, which has no `before`.
A learned-profile entry (`home.profile.item`, written by Home's `profile` tool or
`home.profileChange`) is undone with its whole group back to each note's `before`,
and refused unless every note still holds its `after` (docs/settings-model.md 6.4).
`settings.applyAgain { commandId, changeId }` names an `outside` entry that
replaced or removed a value Tron wrote and writes that value back through the same
path and gate (with `applyAgainOf`), refused when the store moved on since.

Outside changes (docs/settings-model.md 5.6) are owned by
`src/admin/settings-outside.ts`. Every settings read, and a debounced directory
event on the Mac agent directory or a known project's `.pi/`, compares the Mac
`settings.json`, `trust.json` and each known project's `.pi/settings.json` (at
most 64, least recently read out) by content digest with the per-key values Tron
last observed in `<tronHome>/gateway/settings/observed.json`. Each differing key
instance becomes one `outside` entry (redacted keys by digest only) with the
repository `HEAD` and branch for a project file; an entry that replaced a value
Tron wrote refers to that change and offers Apply again. Tron's own writes, the
change path and package installs, bracket the store so they never echo. The tier
is the key's floor for its direction and decides only whether it pushes. A commit
whose `.pi/settings.json` blob is Tron's staged blob appends `committed` to that
change. Rows carry `Changed outside Tron` (with Apply again), and a Project value's
git state as `Staged`, `Uncommitted` or `Local only`. The provider-request
boundary reads values only. `models.json` and `mcp.json` hold no schema key, so
they are not compared.

Every change gets a tier, and the tier is enforced (docs/settings-model.md 5.4,
5.5). It is `max(floor + web, riskModel)` capped at approve: the key's floor for
the change's direction, or the maintainer's override of it in
`<tronHome>/gateway/settings/floors.json` (the key `permissions.floor`, qualified
by `key` and, for a key whose floor differs by direction, `direction`; only the
iPhone writes it, and lowering one is its widen direction, floor approve); one
step more when the requesting run read open-world content, then max-composes the optional bounded risk assessment. The typed classifier can only raise; UI taps and dry runs do not dispatch it, and failure/timeout preserves the computed tier. Its bounded disclosure, pricing ceiling and audit basis are owned by settings-model.md §5.4b.
The iPhone's own change is applied at once whatever its tier. An agent's
(`home`, `worker`, `agent`) quiet change applies; a notify change applies and
queues an `explicit` push naming it; an approve request is held: one entry per
change is recorded `pending`, a `waiting` push asks the maintainer, and the
result is `{ status: "pending", approval: { requestId, digest, expiresAt } }`.
Pending requests live in `<tronHome>/gateway/settings/approvals.json` (at most
100 open). `settings.approvals {}` lists the open ones with their diff and
`digest`, each change with its `label`, raw `before` and `after`, Gateway `display`
strings and any `confirm` text, and the request with `requester`, who asked as the
iPhone names it; `settings.decide { commandId, requestId, digest, approved, fence? }`
approves or declines one, bound to that exact diff. Approval re-plans every change
against the store with the recorded `before` as `expected`, so a store that moved
since, or a newer request for the same key, supersedes it and the approval is
refused. Decisions, supersession and expiry (24 hours, evaluated against the
change path's clock whenever the path is used) are appended to the record as
facts referring to the pending entry; an expired or declined change is never
applied. `settings.approvalsChanged { kind, requestId, status }` is broadcast on
every change to the open set. The requester is told on its next run: the
`tron-settings` module adds one `tron.settings-outcome.v1` custom message naming
each of its declined, expired or superseded changes, once.

The `tron-settings` module registers the `settings` tool in every session,
Home included: a thin client of the resolver and the change path that always
targets its own chat, recorded as Home, the task worker (with its task id) or
the chat's agent, with the tool call id. A chat's own Chat-layer values change
only between runs, so the tool refuses them during its run. The module also sets
the run's web mark from the `tool_call` hook, which runs before each call
(nested codemode calls included): a call to any tool that does not declare
`annotations.openWorldHint: false` marks the run until it ends. Tron's own tools
declare it; `web_search`, `web_fetch`, `computer` and the `knowledge` tool (its
X, capture and Raindrop actions) declare `true`; pi's built-in `read`, `edit`,
`write`, `grep`, `find`, `ls`, `bash`, `codemode` and `tool_search` are declared in
`tron-settings-extension.ts` against their built-in source (`bash` is Tron's
direct bash tool, `<sdk:bash>`; decision 33); any undeclared third-party or MCP
tool marks the run. A task worker writes exactly the keys an ordinary chat's
agent may: a key's `writers` list is the grant, and there is no per-task grant
(decision 34).

`modules.list` reports Tron's built-in extensions for Settings without opening a
session. It returns one row per entry of the single `TRON_MODULES` definition
that `RuntimeSlot` also registers (`tron-modules.ts`: stable name, one-line
purpose, declared tool and command names), so the installed list cannot name a
module a session does not load or omit one it does. The always-loaded
`tron-invocation-settlement` module comes first in definition and registration
order. It has no tools or commands: its awaited hooks join RuntimeSlot-owned
terminal receipt writes before the next admitted input, without waiting for
attention settlement. MCP servers are managed only through the explicit `mcp.*`
methods below; they are not projected as Tron connection instances.

`hooks.list` serves the same hook fields `session.resources` returns
(`extensions`, `extensionLoadErrors`, `hookInventory`) for one scope without a
session, so the Hooks sheet and a live session cannot decode differently. An
absent `cwd` is the global scope: it loads the user's agent-home extensions
against an untrusted home directory, and the Gateway process working directory
never selects a project. A supplied `cwd` is canonicalized by the trust owner and
loads that project's extensions only while the canonical trust decision is true,
re-read during the load as `RuntimeSlot` does, so a decision change cannot leave
project extension code loaded. Loading reuses the `PackageService` settings
pattern (a fail-closed `SettingsManager` created for the resolved trust state) and
the `DefaultResourceLoader` reload used by the global provider runtime; it never
starts a session and never replays an extension's provider registrations into a
runtime. Reads serialize on one mutex and are tracked as drain-aware
administrative work exactly like `packages.list`, and the returned rows are
bounded by the same 256 KiB projection envelope. The pinned SDK cannot cancel an
extension-module load, so no wall-clock deadline is claimed for it. The
`hooks.v1` capability advertises the method.

`packages.list` additionally reports, for each installed package, the names it
`provides` — skills, prompts, themes, subagents, and the tools and commands its
extensions register — attributed from the resolution the read already performs,
the subagent catalog and that same session-free extension load, capped at 256
names per kind: a failed extension load or failed subagent discovery leaves the
kinds that did resolve in place and adds one bounded `providesDiagnostic`
instead of failing the read.

Each row also carries `nodeRequirement { range, runtime, status }` when the
installed package's `package.json` declares `engines.node`. `status` is
`satisfied`, `unsatisfied` or `invalid`, and is judged against
`process.versions.node`, which is the Node every package runs in. npm only
prints `EBADENGINE` during install, so this is where a mismatch stays visible
after install or update. It is a warning, never a refusal (#243, decision D-2 on
#241). A package without the field, or with an unreadable or oversized manifest,
has no `nodeRequirement`. The integration journey is
`src/admin/package-node-requirement.integration.test.ts`.

### MCP administration

`mcp.list` is an explicit request (never a poll) that runs the bundled `pi mcp
list --json` CLI out of process. `scope` is `global` or `project`; project scope
requires a canonical trusted `cwd`. Output is bounded to 1 MiB and the process
timeout is 30 seconds. The CLI exits 1 while any server is unhealthy; its JSON
is still projected. Each row is `{ name, state, scope, enabled, exposure,
transport, tools, error? }` with Pi's `state` values (`connected`, `needs-auth`,
`failed`, `disabled`, …); Pi's `source` path stays on the Mac and `error` is
bounded to 2 KiB. `mcp.add`, `mcp.remove`, `mcp.logout`, `mcp.update` and
`mcp.token.set` require a `commandId` and use the bounded command receipt store.
Add/remove report the affected server and require `/reload` or a new session for
configuration changes; sign-out and new credentials are observed by running
sessions at the next turn. `mcp.update` patches only `enabled` and `exposure` on
an existing entry in the scope's `mcp.json`, under a file lock, retaining all
other JSON keys and failing closed on malformed or oversized files. Project scope
is the Project root (`TrustInspection.projectDir`), not the subdirectory a chat
runs in. Every change to an `mcp.json`, by these writers or outside Tron, broadcasts
`mcp.changed` (`{ scope: "global" }` or `{ scope: "project", projectDir }`) so the
MCP screen reloads; an outside change is also a settings record entry with a push
(settings-model.md 5.6a). Tron's own writes are adopted as observed, never
recorded as outside changes; `models.custom.put` is bracketed the same way.

`mcp.token.set` stores bearer credentials through the host Keychain credential
owner and writes only a `!command` reference in `mcp.json`; token values are
never returned or logged. `mcp.auth.start` takes `{ sessionId, server,
commandId }` and starts Pi's own `/mcp login <server>` extension command through
the attached session's normal prompt admission. It returns `{ operationId,
recovered }`; `mcp.auth.cancel` takes `{ operationId }`. The authenticated device
owns the operation. One operation is active per device/session/server, with the
same 15-minute timeout, cancellation, tombstone and `auth.resume` replay rules
as provider authentication. Events retain the standard `auth.event`,
`auth.prompt` and `auth.completed` shapes and add target
`{ kind: "mcp", sessionId, server }`. The per-session MCP `openUrl` hook routes
only the authorization URL for that active operation into the auth event; an
unowned request fails closed and never opens the Mac browser. Callback capture
is parsed only from Pi's authorization URL and relay is restricted to its
provider-authored loopback listener. Pi's pasted-redirect prompt is delivered
through the same operation. Closing or evicting the session cancels its MCP
auth operation.

### Agent home

Pi's canonical agent home is `<tronHome>/agent`: Stable uses `~/.tron/agent` and
the isolated Debug supervisor uses `~/.tron-dev/agent`. An absolute
`PI_CODING_AGENT_DIR` is the only override for an intentionally custom Gateway
invocation, and the managed Debug supervisor strips it to preserve its profile;
the retired `TRON_AGENT_DIR_NAME` is rejected rather than silently
reinterpreted. Canonical JSONL, settings, credentials, installed
packages/resources, retries, and compaction stay in that home. The retired
`~/.pi/agent` home is never read, migrated, or deleted.

### Provider account usage

`provider.usage` is the additive `provider-usage.v1` read capability. It resolves
credentials through the selected `ModelRuntime`, and queries only exact first-party
configurations for Anthropic OAuth, OpenAI Codex, OpenRouter, Kimi Coding, Z.ai
(including its China endpoint), Moonshot Open Platform (international and China),
and OpenCode Go. Custom or overridden base URLs
are reported unsupported; they are never sent to a first-party quota endpoint.
Anthropic usage requires the active Anthropic OAuth credential and reads the
subscription quota endpoint (`/api/oauth/usage`), not API-key billing. It admits
CortexKit's `cortexkit-anthropic-messages` model API only at Anthropic's exact
first-party API host, in addition to Pi's built-in `anthropic-messages` API. It reports
provider-supplied 5-hour, weekly, model-scoped weekly, and optional extra-usage
monthly limits; amounts/resets omitted by Anthropic remain absent rather than
being inferred. API-key authentication is not advertised as subscription usage.
OpenCode Go reports its account-wide rolling 5-hour, weekly, and monthly percent
windows. Its first-party shapes cover both the bundled catalog's `opencode.ai/zen/go`
paths and the refreshed remote catalog's `opencode.ai/inference/go` paths (including
its `google-generative-ai` model), so a catalog refresh keeps usage supported; a valid key whose account is not on Go reports unsupported rather than a
rejected credential. Moonshot reads `GET /v1/users/me/balance` on the exact regional
host and reports Available/Voucher/Cash balances in that region's currency (USD on
`api.moonshot.ai`, CNY on `api.moonshot.cn`), with no quota windows because Moonshot
exposes none; a reported cash deficit keeps its negative amount. Global reads include
only configured supported providers, while a provider ID requests one bounded status
snapshot.
The provider catalog reports the same first-party predicate as `usageSupported`, so
a client can reserve a loading row only for providers that will actually answer. Its
`localOnly` flag is true only for a provider with at least one model whose every
resolved model base URL host, and provider base URL host when set, is loopback
(`localhost`, `127.0.0.0/8`, `::1`): that provider runs unmetered locally, so clients
show an unlimited indicator instead of requesting account usage.
Responses contain at most 16 providers, 16 windows, and 4 balances. Successful
observations are cached for 60 seconds and failed/rate-limited reads use bounded
negative backoff. Cache and in-flight identity include the effective provider and
authentication fingerprint, so logout, reauthentication, and account changes cannot
reuse another account's usage. Raw credentials and response bodies remain local.

`provider.list` exposes OpenAI's API-key and OAuth login methods, and labels the
separate Codex provider `OpenAI Codex (legacy)`. Sign in with ChatGPT tokens are
audience-bound to `api.openai.com/v1`, carry no ChatGPT account claim, and OpenAI
forbids sending them to ChatGPT backend endpoints, so no first-party endpoint
reports usage for them. OpenAI usage is therefore borrowed: only while `openai`
uses OAuth and both `openai` and `openai-codex` resolve to their exact first-party
shapes, `provider.usage` for `openai` runs the Codex `wham` read with the Codex
credential and returns it under `openai` with `source` `openai-codex.wham`. The
`openai` credential is never resolved for usage. A missing Codex login reports
`unconfigured`, which clients present as a Codex sign-in prompt. While OpenAI
qualifies, `provider.list` sets `usageLentTo: "openai"` on the `openai-codex` row
(otherwise `null`), so clients can hide the legacy row and show the plan once. Tron cannot prove
the two logins belong to the same ChatGPT account (#312). API-key `openai` is not
usage-supported. A change to the `openai` login or composition during the read
answers `unavailable` instead of the lent windows. Sign in with ChatGPT receives a stable device ID from global Pi
settings. AuthBroker serializes OpenAI and Codex legacy OAuth operations because
both SDK flows use callback port 1455; live sign-in remains a manual acceptance
gate.

For first-party OpenAI ChatGPT OAuth, new model choices are gated by one
Gateway-wide owner and the public provider availability filters in each `ModelRuntime`,
using that same OAuth access token's `GET https://api.openai.com/v1/models`
response. The Gateway retains only `visibility: "list"` entries whose `slug`
matches a model registered by the pinned SDK, preserving account order. This
account list is the sole lifecycle and endpoint-eligibility authority for
first-party OpenAI OAuth choices: bundled models it omits (including hidden,
retired, or route-incompatible entries) are not selectable. Unknown account
slugs are ignored because Tron has no registered transport metadata for them.
The Gateway constructs the `OpenAIModelEligibility` owner and attaches its runtimes
directly; Home borrows that owner rather than installing a second policy.
Discovery is paginated and bounded to five seconds. The first account-backed
availability/catalog read may therefore wait up to five seconds; before a
successful result, or after a failure without a same-token success, OAuth OpenAI
fails closed to no choices. Successful discoveries are fresh for 60 seconds
before another bounded refresh; on refresh failure, the last successful list for
the same token may remain available. A token change does not authorize the
previous token's list. The access token is sent
only to `https://api.openai.com/v1/models`; API-key OpenAI and custom endpoints
keep their existing catalog behavior without discovery. Eligibility applies
only when the provider and every registered OpenAI model use the SDK's exact
first-party Responses route. If a mixed/custom model is registered, the whole
provider is left unchanged rather than applying account authority to proxy
models.

A credential-configured provider with only non-chat capabilities can appear in
`provider.list` with `modelCount: 0`; configured credentials do not promise chat
choices. Typed catalog refresh preserves image/classifier entries in
`models-store.json` without exposing them as chat models, including after reload.

Chat and default model changes (`model.ref[role=chat]`), `provider.list` choice counts, and
`model.list.available` use the same policy. On a new session only, an ineligible
saved OpenAI/Codex default is replaced by the first currently available model;
the persisted setting is not rewritten, and creation fails without publishing a
session if no fallback exists. Existing session model identities are
not rewritten, including on reopen. A Codex provider remains registered and its
credential remains available to the usage adapter, but its models are not new
choices while `providerUsageLentTo` identifies `openai`; a sole Codex sign-in is
unchanged. This describes account-list behavior, not the current account's exact
membership; a live account check remains a maintainer post-install validation. An
extension can still call `ctx.setModel` directly; extension-authored selections are
outside this Tron policy because the SDK has no pre-selection admission hook. Likewise, an
extension provider contribution that re-registers `openai` or `openai-codex`
replaces the SDK filter decoration (the SDK keeps native and extension providers
mutually exclusive). Gateway catalog, selection, default and Knowledge admission
still consult the eligibility owner directly, but SDK snapshot consumers (model
cycling and Pi's own no-default initial pick) are unfiltered for that composition.

A native executor adapter must retain its tool promise through actual native
cleanup, not reject it when only its client waiter stops. The existing Pi/slot
operation owner then keeps Stop and drain pending without a second work registry.
The [native-tool settlement qualification](docs/native-tool-settlement.md) proves
that boundary and its waiter-only negative control with a synthetic peer; it
registers no production computer-use capability or native input path.

The first-party `native_capture` tool lists bounded visible-window and display
handles with logical dimensions (`catalog`), selects one exact handle (`view`),
or closes this session's native scopes (`stop`). Display handles support a whole
display or an explicit bounded region in display-local points; window handles
show the whole selected window. Selection returns an opaque `native_live` source for `display`, not a
renderer grant or pixels. Only the canonical display result on the active branch
permits viewing. The existing live-view registry, authenticated HTTP routes and
mobile renderer serve both producers with shared viewer/decode budgets. Each native transport operation
(`request`, local retirement) is bounded by an owner deadline: a signed host that never replies produces an
explicit uncertain failure rather than a fabricated remote join. This bounds the
caller wait; it does not prove host-side retirement or authorize replay.

`machine/native-capture-client.ts` binds one connection to the canonical session
and extension load. Import is inert; explicit catalog opens the API-versioned,
signed `Tron.app/Contents/Library/Native/tron-native-capture.node` (API4). This Mac
capability is optional: missing/incompatible code disables capture, not Gateway
startup or source updates. No endpoint, credentials, process/window ID or input
is accepted. Listing and selection start no stream. First-viewer admission starts
capture; last-viewer retirement suspends and joins it. Reopening uses the same
retained native source/filter and exact crop, never another catalog lookup, and waits for a clean
prior join. Source loss, failed suspension, load replacement or explicit Stop ends
the reference. Stop uses independent capacity and joins local callbacks after the
host response; local disconnect alone never proves remote native retirement.
Viewer idle demand and diagnostic expiry use monotonic time, so wall-clock changes
cannot extend abandoned capture or manufacture expiry.
Frames remain latest-only, bounded and outside JSONL/artifact caches. An asynchronous
native-start/read failure retains only a finite reason for its exact reference,
bounded to64 entries, reported for60 seconds, and cleared at session retirement. This lets the
next frame request report a safe cause without retaining pixels or permitting
source resurrection. Native first-frame waiting ends after10 seconds of visible
polling even when setup/empty reads succeed; expiry requests Stop and retains
actual native retirement, never treating the deadline as a joined resource. Installed
XPC and real-window/mobile qualification remain required; offline tests are not
that evidence. See the
[Mac wire and lifetime contract](../mac-app/docs/computer-control.md#direct-gateway-capture-client).

The optional first-party `computer` tool is a thin `{tool, arguments}` client of
pinned Cua Driver 0.28.0 (revision `1b50c02e2d34734f64d2d22f54eb76cc97b4a663`).
The permission-bearing Native Host owns one direct embedded Cua process and a
private per-generation socket; Gateway receives only a read-only
`{socket, generation}` bootstrap through the authenticated native boundary and
never accepts an endpoint, environment, or session from model input. Invocations
bind the canonical session/load and require fresh observations and element
references. Refused, background-unavailable, malformed, non-zero, or disconnected
results are refusal or `outcomeUnknown`, never success or replay. Marker-free action
objects are also unknown; observation objects need no artificial success flag.
Geometry setters use exact window metadata rather than pixel-input admission.
Cua telemetry is
disabled for daemon and clients. Missing Cua assets disable only this tool;
permissions and capture remain available. Administrative history, browser,
config, update, install, and grant surfaces are not exposed. Each extension load
owns its binding and awaited shutdown; there is no global computer-session mirror.
Before an explicit observation, the adapter confirms Cua's owner-bound session
activation and discards old proofs if idle expiry required revival. It does not
revive a session for an action or replay that action. Accepted calls outlive waiter Stop without replay. Observations return bounded
image blocks from disposable files in an owned directory canonicalized before
invocation (including macOS temporary-directory symlinks). Files are removed before
publication; actions require fresh references from that load. Before foreground input, inspect the full desktop for blocking system
dialogs: window-only capture and ordinary-window ordering can hide macOS's separate
direct-capture consent prompt. The agent never approves OS permissions itself.

## Automations

The Gateway is the sole scheduler and canonical owner for durable automations.
Pi extensions and delegated subagents may execute work inside a scheduled turn,
but they own no timer, definition, retry, or run ledger. Automation records live
under `gateway/automations/` as strict schema-version-2 bounded owner-only
documents containing one definition, at most one nonterminal run, and 64
retained terminal runs. Older target shapes are not admitted, migrated, or
fallback-projected. Writes
sync the replacement file and parent directory before acknowledgement. iOS and
Pi's first-party `schedule` tool are clients of this authority, never mirrors.

`automations.v2` supports one-time, anchored interval, and IANA-timezone
daily/weekly triggers. Calendar gaps advance to the first valid local minute and
repeated local minutes choose the earlier instant. Misfire policy is `latest` or
`skip`; overlap policy is `skip` or one `queueLatest` occurrence. Catch-up,
history, dispatch batches, timers, prompts, storage, and concurrency are all
bounded. Scheduler timer arming derives the earliest retry or enabled occurrence
from one owned catalog snapshot, without sharing that read across durable writes
or dispatch. Recurrence advances from intended schedule time rather than completion
time, and clock movement cannot recreate an already-recorded occurrence.

An Automation target is exactly one existing persisted user session or one
Gateway-canonical workspace with `newPerRun` session policy. Existing-session
targets support prompts and notifications. Workspace targets support prompts
only, create one ordinary user-visible session for every run, and require
intervals of at least 24 hours because generated sessions are canonical data and
are never automatically deleted. Workspaces must already exist and have a
resolved project-trust decision; Automations do not create directories,
worktrees, or branches.

Every run durably snapshots its target and concrete execution-session ID before
dispatch. Existing targets reuse their session ID; workspace runs receive a new
predetermined UUID and create that exact identity through
`RuntimeRegistry`/`RuntimeSlot`. `OwnedSessionDispatch` is the neutral boundary
for shared session leases, exact recovery evidence, and terminal acknowledgement;
Automation retains its own operation identity and result interpretation above
that seam. The seam also owns the fixed 24-hour deadline primitive for callers
that explicitly opt in; it does not impose a deadline on ordinary sessions or
Automation. A live-only generated slot carries an exact operation-owned lease
until Pi persists its first user or assistant message.
Restart recovery always consults the run snapshot and concrete session identity.
A new session with no user or assistant message remains memory-only; after the
first user message, Pi persists the transcript and any earlier canonical
invocation receipts together. Restart recovery after workspace admission without
that evidence becomes `outcomeUnknown`; Tron never creates a second session or
writes Pi's JSONL itself. Ordinary per-session serialization, runtime capacity,
project resources, settings, credentials, and model selection remain authoritative.

Scheduled prompts never steer or enqueue into an active turn, so a busy existing
target waits durably while unrelated sessions may proceed. Resource actions
revalidate the current typed skill or prompt identity inside the selected or
newly created RuntimeSlot and project Gateway automation provenance instead of
pretending the input came from a user. Extension commands, attachments,
arbitrary shell, webhooks, deployment, and Gateway lifecycle actions are not
automation capabilities. RuntimeSlot also rejects scheduled plain text that
resolves to an installed extension command, inside its mutation lane and before
command effects, run markers, or terminal observers are admitted. Omitting a
typed resource cannot bypass that boundary; explicit user commands remain
available.

Each occurrence and run is durable before dispatch. A queued or waiting projection
can already have a dispatch reservation while its durable claim is publishing.
Cancellation signals that exact owner and settles through its dispatch path;
only an unreserved queued run uses immediate terminal settlement. `automation-scheduler.integration.test.ts`
proves this with the real executor/SDK and canonical JSONL, plus a fresh successful
automation, unreserved drain-time cancellation, durable reopen and explicit successor.
Pre-admission transient failures may retry with bounded backoff; accepted agent failures do not. A crash
before any canonical invocation/marker evidence permits the same run to requeue.
Gateway shutdown cancels pending admissions through the executor and exact prompt
preflight as well as already-active executions. Disposal joins dispatch through
its terminal acknowledgement, not merely the provider completion. An expired
wait returns an explicit blocker while the execution, marker, and lease remain
owned; it never reports successful retirement. Resolving an unknown run is refused
until its process-local owner retires. A handle returned after admission was
cancelled is cancelled and acknowledged without publishing a new running state.
Accepted work without exact terminal evidence becomes `outcomeUnknown`, blocks
future occurrences, and requires an explicit receipt-backed user resolution.
Successful canonical completion remains marked until the automation terminal
record is durable, so restart recovery can finish settlement without replaying
the prompt. One-time work completes after its terminal occurrence, three
consecutive definitive failures open a circuit breaker, and running work has an
exact operation-fenced cancellation/deadline rather than a fictional pause.

Startup performs bounded target and run reconciliation before dispatch opens.
Malformed individual records remain untouched and disable automation dispatch
for that evidence instead of being interpreted as absence. Administrative drain
closes the scheduler synchronously; future due work never blocks restart, while
already admitted dispatch and terminal persistence use the shared Gateway work
registry and must settle truthfully. The global `automation.changed` event is
only an invalidation hint; list/get/run RPCs remain authoritative.

## Moonshot Kimi K3

The built-in Moonshot K3 model uses the Open Platform OpenAI-compatible endpoint
and preserves K3 reasoning/tool message fields. Gateway caps the requested
completion reservation at 32,768 tokens and sends the documented
`max_completion_tokens` field; this is separate from K3's 1M-token context
window because Moonshot TPM accounting includes the requested completion budget.
Terminal Moonshot account/org quota responses are normalized as non-retryable;
max-concurrency responses with explicit provider guidance receive one bounded
retry, while transient engine overload responses remain retryable. This prevents
the same over-budget request from consuming the account's RPM through repeated
retries. The provider key still belongs in the runtime credential store and is
never persisted by Gateway.

## Internal workspace

`<tronHome>/workspace` is Tron's durable internal home, separate from every session
cwd and the generic filesystem browser. `files/` holds deliberately retained
documents; `state/<owner>/` is reserved for real capability-owned data. Pi and
Gateway canonical stores stay with their existing owners. Initialization,
fail-local recovery, backup, prompt coverage, internal-file display, and the
future managed-state contract are owned by
[`docs/internal-workspace.md`](docs/internal-workspace.md).
Installed single-file Swift apps (`state/apps/`, `swift-apps.v1` RPCs and the
`swift_app` tool) are owned by [`docs/swift-apps.md`](docs/swift-apps.md).

## Tron Home

Tron Home is one opt-in persistent conversation per Gateway installation. It is created only by an explicit
`home.designate`; until then every session is ordinary. [`docs/home.md`](docs/home.md) owns its designation
record, RPC shapes, chapters, runtime profile, memory, task delegation and terminal client.
[`docs/host-load.md`](docs/host-load.md) owns the host-load design: the host-wide
heavy-run queue and the host-pressure signal, which is observational (#915, #1096).

- **Memory.** There is no memory default: Home refuses activations until its background model
  queue (`model.queue[role=background]`, else the subagent queue, changed through `settings.change`)
  names a model; each summary call falls back along it ([settings model 6.3](docs/settings-model.md#63-model-fallback-queues)). Memory spend is bounded by construction and reported; there is no budget to manage. Each
  activation sends the model only the system messages before it, ONE frozen memory view and its own messages.
  Prior activations are never re-sent, and the view is never persisted.
- **Runtime.** Home runs in the neutral `<tronHome>/gateway/home/workspace` under an explicit untrusted decision,
  with a curated profile: no agent-directory or project discovery (including `SYSTEM.md` and `APPEND_SYSTEM.md`),
  no Pi built-ins, a fixed executable-tool allowlist, per-session compaction disabled, a fixed physical model,
  and zero cache-warming requests. Designation is keyed by session id. A profile change replaces the live runtime
  inside the session's lane. Bound Home chapters refuse fork and identity replacement (`home-identity-replacement`),
  and a separately imported session is ordinary.
- **Chapters.** Home's history is split into physical chapters at quiescent soft and hard size boundaries.
  Sealed chapters stay readable and refuse mutation.
- **Tasks.** Home is delegate-only for project work. `delegate` admits finite work once, in a trusted project,
  through the neutral owned-session boundary. Workers keep normal project capabilities plus the explicit `report`
  tool. Workers may launch subagents; the task stops and joins every async run it started before it settles, so
  the 24-hour deadline covers subagent work. v1 refuses revival, mutating management of runs the task did not
  start, mission launches, scheduled work and durable `bg_wait` wake subscriptions.
  Reports seal exact canonical evidence, never the latest assistant reply; a missing report is `limited` or
  `unknown`. A fixed internal 24-hour deadline cancels and joins operation-owned work. Usage is reported as tokens only,
  and unknown tracked detached work yields `unknown`, never a clean-stop claim.
- **Authority and recovery.** Task authority lives in a separate strict store, initialized on first dispatch.
  Startup retires abandoned tasks from exact canonical reports or terminal `unknown`, without replaying a prompt,
  and co-commits the result outbox. A recovery refusal fences task surfaces until the next start, exposed as
  `home.status.taskRecovery`; ordinary sessions keep working. A restored or copied Tron home needs an explicit
  maintainer `home.reconfirmPermissions` (terminal `/home reconfirm-permissions`), which renews active standing
  scopes only. The maintainer-only `home.taskPermissions`, `home.revokeTaskScope`, `home.revokeTaskGrant` and
  `home.decideTaskGrant` RPCs list and revoke authority, or approve or deny an exact durable request with a one-use,
  expiry-bound grant. `home.taskPermissions` adds the read-only `needsReconfirmation`
  boolean when an active standing scope's restore epoch differs from the current task
  namespace. It never renews a one-use grant or changes authorization; iOS treats
  an absent field as false. Home cannot approve its own requests.
- **Task control.** `home.taskList`, `home.taskStatus`, `home.steerTask`, `home.interruptTask` and `home.stopTask` expose durable spend
  and shared control. A list row reads its worker's name without building a session snapshot or a catalog
  acquisition, so a page stays cheap however large the catalog or the live transcripts are. Terminal `/home task`, `/home steer`, `/home interrupt` and `/home stop` target one task. Interrupt cancels only the worker's in-flight command tree (SIGINT, SIGTERM, then SIGKILL) and keeps the worker running. Steering shares the
  session lane; Stop persists exact intent and cancels outside blocked admission. The maintainer's chat messages to a
  running worker join that same ordered steering lane (a follow-up becomes steering), and Home's steering or the
  maintainer's message also starts the held task's next turn while it waits between turns for its subagent runs.
- **Resume in place (#929).** A settled task (stopped, interrupted, limited or reported) continues as its one
  successor task `<id>.resume-<n>`, bound to the same worker session, so its worktree and work claim (claims name
  the session) stay with it. Home's `task` tool action `resume` (only `taskId`; naming any task of the lineage reaches its current one, #961) and a maintainer message sent in the stopped
  worker's chat both resume it; the message becomes the resume instruction. The stopped record stays immutable and
  each task has at most one started successor. A resume admits like any task: beyond the running-worker budget it
  queues, its worker operation already fixed so the maintainer's message names it (#959). A successor refused or
  settled before it started is not one: the stopped task stays resumable, the refusal's message is kept as
  `terminalEvidence.detail` (and in Home's wake), and its instruction (`resumes.instruction`) is re-delivered,
  oldest first, by the next resume. The rebind refuses while other work runs in the session, but not for Knowledge
  observation, which only reads the settled turn. The worker slot is rebound to the new operation's report owner in place,
  so viewers keep their subscription. Each operation owns the canonical span from its marker to the next marker,
  so reports, spend, subagent counts and settlement proof never mix operations. A question `ask_user` was asking
  when its run stopped (also inside codemode) is recorded as a `tron.ask-user.interrupted.v1` custom entry, and
  the resume brief restates it so the worker asks it again. Journeys: `src/home/home-task-continuity.e2e.test.ts`.
  Canonical usage identities dedupe
  tokens before display. Task results never trigger an automatic Home call: terminal tasks co-commit a durable inbox
  event, delivered on the next maintainer Home message, and make one advisory push decision at most.
- **Protocol.** `home.v1` is advertised in `hello` and `system.info`. `home-memory-view.v1` additionally gates the
  typed memory browser, `home.memory.view` and `home.memory.evidence`: disposable reads of projected summaries and
  canonical history. The RPC table, the `home.status` shape, the memory browser contract and the terminal `/home`
  command table are in [`docs/home.md`](docs/home.md#rpcs).

## Runtime and state

The launcher executes `dist/index.js`, a small entrypoint that imports the
Gateway from `gateway-main.ts`. If loading that module graph or startup fails,
the entrypoint appends one `gateway.fatal-startup` error record to
`gateway.jsonl`, with the error (and one level of cause), runtime epoch and
payload version, then exits non-zero. Payload and home path prefixes are
shortened before redaction so the record names the failing file. The entrypoint
imports only Node built-ins, `tron-home.ts` and the logger's error helper, so
a failure elsewhere in the graph cannot prevent the record.

### Logging

`GatewayLogger` (`src/transport/logger.ts`) is the one writer. What each level
means, every stream and its rotation cap, the retention budgets and the event
catalog are owned by [`docs/observability.md`](docs/observability.md).

- `system.logs` serves the newest 1,000 persisted records (info and above).
  Debug never reaches disk; it lives in a bounded in-memory buffer that
  `system.logs.export` appends to the exported snapshot (see
  [Diagnostic bundle](#diagnostic-bundle)).
- Each record carries `timestamp`, `level`, `event`, `source`, a redacted
  `message`, and the writer-stamped `process`, `runtimeEpoch` and
  `payloadVersion`. Call sites add correlation (`sessionId`, `connectionId`,
  `commandId`, `requestID`, `method`, `outcome`, `code`, `reason`,
  `durationMs`, `step`) as fields rather than message text, and pass a thrown
  value as `error`; the writer stores a bounded, redacted
  `{name, code, message, stack}` with one level of `cause`.
- `gateway.startup-step` records each interval between startup checkpoints,
  adding to process start through listener readiness without double counting.
  `gateway.startup-budget` then judges process start to listening against
  `STARTUP_LISTEN_BUDGET_MS` (5 s) the moment the Gateway serves and names the
  slowest step. That number is this process's own start, not the whole wait a
  restarting client sees — the client counts from its own socket's close, before
  the predecessor is down — so `scripts/tron-profile-gateway` reads the record
  (and its `budgetMs`) for the start while judging the restart case's criterion
  on its own close → listening span.
  `gateway.shutdown-step` names and times every awaited shutdown operation so a
  forced exit can be attributed to its owner.

### Background work

One owner decides when recurring background work may run: `backgroundWork` in
`src/background-work.ts`, started by `gateway-main.ts` after the listener is
serving. Registered jobs take turns **one slice at a time**; between slices the
scheduler yields with `setImmediate`, so the next slice runs in the loop's check
phase after the poll phase's timers and I/O. A due slice waits while a request is
competing for the loop (`requestsCompetingForLoop()` in
`src/transport/request-span.ts`) or while the loop's delay p99 is at or above
`BACKGROUND_PAUSE_P99_MS` (50 ms), re-checking every
`BACKGROUND_PAUSE_RECHECK_MS` (100 ms). A request that hands its wait to work
outside the loop — a receipt-backed mutation (`offLoop`), such as a `session.bash`
shell command, a `session.compact` or a `knowledge.*` model call — does not count
as competing: it holds its receipt for its whole operation while the loop is idle,
and the loop's own delay is what covers the loop work it still does. A slice with
more to do than one bounded batch awaits `backgroundWork.yieldToLoop()` between
batches: that is one loop turn, or a re-check interval while the same pause is in
force, so the slice yields to a request that arrives mid-slice. A rejecting slice
is reported and never stops the scheduler or the jobs registered after it.
`background.slice` (debug, warning on failure) and `background.backlog`
(warning once per starved spell past `BACKGROUND_BACKLOG_WARNING_MS`, 5 minutes)
are the records, and each carries the job in its `step` field;
[`docs/observability.md`](docs/observability.md) owns their fields.

The jobs are the session catalog's periodic reconcile
(`CATALOG_RECONCILE_INTERVAL_MS`, registered by `session-catalog.ts` itself),
command-receipt pruning, and the attachment/display-artifact maintenance pass.
The catalog's startup, watcher-event and watcher-replacement passes are the same
reconcile pass, so they yield to the same pause between bounded batches (the
durable-row batches of `CatalogMetadataIndex.reconcile` and one file per batch in
its rebuild path) even though they are not slices of the registered job. Each
owner keeps its own bounds; the scheduler only decides *when* a slice — or the
next batch of one — may start. Nothing in a request path prunes, walks or
reconciles: an admission may still force one exact pass at its own capacity
boundary (receipts), which is correctness rather than maintenance.
`register({ name, intervalMs, slice })` returns the function that unregisters the
job — exactly that registration, so a later registration under the same name is
not deleted by the replaced owner's dispose — and that call is the seam any other
recurring owner moves its work under.

### Diagnostic bundle

`scripts/tron diagnose [--since <count><s|m|h|d>] [--out <path>]` writes one
read-only bundle for an incident: the `~/.tron/logs` streams in the window
(rotated segments included), the newest device exports, every channel's payload
selection and progress documents, launchd's `com.tron.server` records from
`/usr/bin/log show`, `/health` on the running Gateway's own host and port, Tron
processes with their payload versions, `scripts/tron mac verify`, and Tailscale's
current path to each paired peer plus the network extension's magicsock lines.
Every external command is bounded by a timeout. The command writes only its
output file (`0600`, never overwritten); it never writes to the Tron home,
launchd or the Gateway. The default window is 2h and the default output is a new
file in the system temporary directory. Copied text is redacted with the writers'
rule set (`redact` in `src/transport/logger.ts`), so a token or a user path
cannot reach a shared bundle. It is a compiled tool: `scripts/tron diagnose`
needs a Gateway build (`cd packages/gateway && npm run build`) and refuses with
exit 66 until the compiled collector exists.

A supervised payload validates its architecture-specific immutable `node` and
technical `pi` command aliases before model services or extension packages load.
The aliases must have exact relative target text, remain inside
`TRON_GATEWAY_PAYLOAD_ROOT`, and resolve respectively to the running Node file and
the payload's executable Pi SDK CLI. Stable makes those selected bundled commands
deterministic; Debug preserves a valid developer Node first and adds the payload
commands as fallback. Invalid aliases fail startup rather than silently consulting
Homebrew, NVM, or a mutable user shim. Unsupervised source/test execution retains
its supplied environment. Extension-owned void presentation callbacks are
transactional best-effort projections: malformed or over-budget updates are
rejected with bounded diagnostics and can never become an uncaught process exit.

- Agent state: `PI_CODING_AGENT_DIR`, default `<Tron home>/agent`; Stable uses
  `~/.tron/agent` and the isolated Debug supervisor uses `~/.tron-dev/agent`.
  Stable and Debug never share production JSONL, settings, or credentials
- Physical-machine group identity: a bounded random ID in the one shared path
  `~/.tron/internal/machine-group-id`, used only for connection grouping; Stable
  and Debug resolve this path independently of their selected homes. The retired
  `~/.tron-machine-group-id` path is never a startup fallback or startup read:
  while it exists, startup refuses rather than minting a second identity. It is
  not a session, credential, or runtime-data store
- Gateway state: `<TRON_DATA_DIR|~/$TRON_HOME_NAME|~/.tron>/gateway/`; `gateway.json` is an exact-shape, 16 KiB maximum document with a 256-byte machine ID and 1 KiB machine name; unsafe/malformed/oversized existing files fail startup without rekeying. Secure bounded reads reject symlinks and non-owner-only files; publication uses the existing durable atomic JSON utility. The exact old version-1 shape with a valid `defaultWorkspace` is normalized under the config lock by removing only that unused field, preserving machine identity; unknown shapes/versions are never rewritten. Tron’s durable internal workspace is the sibling `<tronHome>/workspace`; it is separate from the session cwd and canonical Pi session store.
- Local wrapper credential: `gateway/local-auth.json` (`0600`, owner-UID-only regular non-symlink file;
  an existing malformed, wrong-version, or wrong-purpose credential fails closed)
- Hashed mobile devices: `gateway/devices.json` (bounded owner-UID-only regular non-symlink file;
  auth contexts expose only `kind` and `deviceId`)
- Current invitation: `gateway/enrollment.json` (`0600`, owner-UID-only regular non-symlink file;
  ten minutes, one use; pairing consumes it before device persistence and regenerates it if persistence fails)
- Run markers and command receipts: gateway-owned bounded operational state; per-session
  marker mutex lanes are retained only while queued or executing callers use them
- Delegated provider artifacts: the installed `pi-subagents` owner receives the
  resolved `<Tron home>/internal/subagents/` temp root through its existing
  `PI_SUBAGENTS_TEMP_ROOT` contract before extension initialization (its lifecycle
  runs are under the provider-owned `async-subagent-runs/` child). Gateway
  admission accepts only that exact lifecycle subtree and direct files; project-
  local/session artifacts remain provider-owned and are not copied into a second
  authority. Provider layout, retention, cancellation and cleanup remain
  provider-owned. Discovery reads the bounded first-property lifecycle projection
  even when the full report is larger than the legacy document cap; headerless
  artifacts remain subject to that cap, and an oversized legacy read is diagnosed
  separately from an atomic-replacement retry. Restart discovery can therefore
  recover active runs without parsing report bodies or relaxing the artifact I/O
  bound.
- Uploads: transient and bounded; clients may immediately discard their unclaimed staging, remaining unclaimed staging expires, and prompt attachments remain session-owned until canonical deletion
- Store clocks and identifiers: upload expiry, Automation record timestamps and catalog debounce/persistence windows use the host wall clock. Upload and Automation IDs use the platform cryptographic UUID generator; these stores do not accept caller-supplied clock/UUID authorities.
- Tool invocation lineage: Gateway stamps every live and canonical tool declaration with a `toolSegmentId` owned by one visible conversation segment, then publishes each complete contiguous declaration group at finalized assistant `message_end` with runtime-only `groupId`, `groupIndex`, `groupCount`, and `groupFinalized` metadata before any corresponding tool start. Lifecycle operation IDs may rotate while a tool-only agent continuation settles; the display segment remains stable until user input, visible assistant/custom content, or canonical compaction ends it. A fresh provisional generation prevents old calls from matching between such a barrier and the next assistant's stable presentation identity. While Pi has an exact running-phase streaming agent run, `SessionSnapshot.activeToolSegmentId` publishes that run's current segment; it is absent during retry, compaction, settlement, and idle ownership. Equal segment IDs authorize bounded cross-message display aggregation and current unresolved-invocation activity; missing or different IDs do not. This prevents a new operation from reviving an unmatched declaration left by an aborted older tool batch after disposable terminal execution state retires. Group IDs derive from the stable assistant presentation ID plus first projected content ordinal. Cold canonical projection deterministically derives the same segment boundary from authoritative conversation input and visible barriers. All lineage is bounded presentation metadata, survives live/canonical/result reconciliation, is never written to Pi JSONL, and never implies parallel execution.
- Push grants and short-lived intents: `gateway/notifications.json`, an exact 1 MiB owner-only document. It stores endpoint-scoped grants, at most 64 active devices, 256 pending intents, 512 bounded receipts, and 192 revocation tombstones (128 rotation slots plus a 64-device revocation reserve). It never stores raw APNs tokens. Secrets and message content are excluded from RPC projections, logs, and Pi session JSONL.

## Push notifications

Home task operations have one separate terminal owner: their immutable task
record co-commits the wake inbox and durably decides one advisory push before
enqueue. The hint uses a stable task-result event identity and logical `home`
route; a crash after decision may omit it, never replay it. Ordinary terminal
alerts remain unchanged. The wake inbox (not APNs or the notification bell)
delivers the attributed result on the next Home message. See
[Task wake inbox and terminal push](docs/home.md#task-wake-inbox-and-terminal-push).

The first-party inline Pi extension reserves `notify({message})`; RuntimeSlot owns automatic terminal alerts. Pi 0.87 defines `agent_before_settle` as the final actionable boundary (entries plus one `continue: true` request) and `agent_settled` as notification-only after automatic work is finished. `pi.sendMessage(..., { triggerTurn: true })` from an `agent_settled` handler remains available but starts a distinct SDK run/operation with different receipt and notification semantics; it is not equivalent to an in-run `agent_before_settle` continuation. Candidate fixtures exercise `agent_before_settle`. A bounded installed-extension review found no equivalent old-style continuation consumer: `pi-subagents@0.59` uses `agent_settled` to resume widgets (its `triggerTurn` use belongs to `session_compact`), `pi-web-access@0.22` triggers turns from async fetch/command paths, and no `agent_settled` consumer was found in pi-goal, browser, or pi-sub-anthropic. Arbitrary project extensions were not exhaustively inspected, so review them before adoption if present; no compatibility shim is provided. Only Pi's final `agent_settled` at idle is terminal, so automatic retries, compaction retries, queued follow-ups, recoverable tool errors, and extension continuations do not announce an intermediate response. RuntimeSlot matches the exact final run's canonical assistant object and queues fixed, outcome-specific copy for normal completion, output limits, terminal errors (including retry exhaustion), aborts, or a tool/agent stop without a final response. Exact Gateway abort ownership overrides the last assistant reason, including cancellation during retry backoff. It never searches backward for an earlier successful answer or infers an outcome from error prose. The assistant entry ID remains the durable deduplication source and also keys one bounded RuntimeSlot observation disposition shared with successful-response attention state. Without a canonical assistant, the existing invocation terminal receipt ID is the source; a Gateway-derived run without an invocation uses its exact operation identity. An exact mobile subscription or authenticated local connection may publish `session.presentation.set` only after synchronization; monotonically revisioned visible/hidden updates are token-bound, one per connection, removed on close/replacement/disconnect/rekey/delete, and visible leases expire after 45 seconds unless renewed. A local presentation client uses its own `session.open` subscription token and connection identity, so it can quiet only sessions it has opened; it neither claims the mobile role nor revokes a phone's lease. Opening a visible local presentation acknowledges existing unread inbox rows for that session, just like a mobile presentation. If that disposition observes an active chat, RuntimeSlot does not invoke notification enqueue: NotificationService writes only a durable `suppressed` receipt for the completion, creates no relay intent or inbox row, and excludes it from delivery quota. Terminal alerts otherwise carry the bounded session title plus the exact Gateway machine/session route; tapping is therefore profile-qualified rather than inferred from whichever server is selected on iOS. The extension receives only a narrow enqueue closure: the model cannot choose a device, APNs token, environment, topic, relay origin, request ID, priority, badge, payload dictionary, or presentation policy. Admission is persisted before dispatch, expires after fifteen minutes, and returns `queued`, `suppressed`, `rate_limited`, or `unavailable`; APNs acceptance is never described as user delivery. The Gateway does not impose a routine daily notification quota; admission is bounded by the durable pending-intent capacity, and the relay owns the per-device hourly and routine-daily runaway backstop. Capacity refusals are returned synchronously and do not create intents or inbox rows. Preview-disabled grants still replace model-authored `notify` text with fixed generic copy; automatic terminal body copy is fixed by Tron rather than the model. The session title is the product-required terminal-alert title and is therefore shown independently of that model-text preview flag.

Automatic notification admission follows the owning canonical terminal receipt. Pi persists a brand-new session on its first user or assistant message, so canonical invocation and notification receipts appended before the first user message are flushed with it. A failure before any user or assistant message remains memory-only. Tron does not write the SDK's JSONL or create a second receipt journal to bypass that boundary. The same reasoning applies to a failed append on an already-flushed session: because the SDK inserts an entry into its live branch before the physical append, an entry that exists only in memory after a failure is never announced as a durable canonical receipt. Gateway fails closed with an unknown outcome for that exact identity rather than reporting success from memory, and a retry cannot repair it by appending a contradictory duplicate. Admitted prompt preflight/runtime failures and drain-cutoff interruptions use that same notification boundary even if Pi never creates an assistant. A rejected continuation following a successful response retains that response's already-owned terminal receipt rather than overwriting it with a contradictory failure; the stopped alert uses the preceding exact assistant source. Synthetic progress after rejection is not another admitted run. A queued follow-up's failure receives its own terminal receipt and exact marker retirement even when an earlier successful answer is still committing attention; that earlier receipt cannot substitute for the failed owner. In all cases, requests rejected before Gateway admission, handled commands/inputs, maintenance, and pending user interactions are not agent completions. Orderly shutdown of active foreground work preserves its marker, records `outcomeUnknown`, and attempts one interruption alert. Observation is latched before terminal receipt I/O so navigation during persistence cannot change the suppression decision. The persisted/wire kind `agent_finished` is a neutral terminal category, not success evidence; iOS labels it “Agent finished” with a stop icon and displays the reason-specific body. Push admission failure is diagnostic only and cannot fail canonical settlement. This is best-effort notification of observed lifecycle events, not a crash outbox: abrupt process/Mac loss or failed admission can lose an alert, and restart does not replay historical terminal events. Already admitted notification intents retain their existing durable dispatch/retry behavior. Focused coverage is in `runtime-terminal-notifications.integration.test.ts`; run `cd packages/gateway && npx vitest run src/sessions/runtime-terminal-notifications.integration.test.ts` to exercise the local fake-relay journey and write its repeatable JSON report to `packages/gateway/test-results/runtime-terminal-notifications.integration.json`.

Automatic notification kinds are `ask` (Time Sensitive input-needed), `agent_finished` (only when no live session-owned subagent/workflow remains), and `waiting` (one alert per unchanged set of live background process identities). Pending work is selected from the session-owned extension activity identities and the shared live-work rule; disposable process projections and paused/recent history are not pending-work authorities. When that work wakes the session and settles with no remaining live work, the terminal response is `agent_finished`; unchanged waiting identities notify only once per episode. The Gateway policy defaults all three automatic kinds on and iOS exposes Input needed, Finished, and Waiting controls through registration upsert/status. `notifications.json` version 2 adds finished/waiting policy fields and migrates version 1 policy on read, retaining the old ask choice. Relay limits are 120/hour and 1,000 routine/day per device; ask and explicit notify bypass daily but retain the hourly backstop. Relay `rate_limited` is terminal, not retried. Version-1 pending deliveries have no admitted relay envelope and are retired as failed during the version-2 store migration; their inbox entries remain visible and a single `schema_upgrade` delivery signal is emitted. Ask forwards the fixed `time-sensitive` APNs interruption level.

The Gateway also owns a bounded 512-entry user-facing notification inbox in the same owner-only state transaction as delivery admission. A visible `queued` inbox row proves durable admission, not relay or APNs acceptance. New notification content, exact session route, per-target APNs request identities, delivery outcome, and global read state are canonical there; the iOS cache is only a bounded disposable projection. The inbox is part of the versioned document shape; a document without it is rejected as malformed. `notification.inbox.list` takes `filter` (`all`, the default, or `unread`), an opaque keyset `cursor`, and `limit` (1 through 50, default 50), and rejects unknown keys. Rows order by `createdAt` descending then `id` ascending; `nextCursor` encodes the exact `(createdAt, id)` of the last returned row as `<createdAtEpochMs>.<id>`, and the next page returns rows strictly after it, so a page request never fails because the inbox changed and `unread` pages under the same keyset. The response carries the whole-inbox `revision` and the total `unreadCount` across every row, not the filtered page. A malformed cursor is `invalid_request`. `notification.inbox.read` accepts exactly one public inbox ID or APNs request ID and is idempotent: a row already read, or one evicted by the bound, answers `{ changed: false }` instead of failing. `notification.inbox.readAll` requires `through`, the keyset key of the newest row the user has seen, and marks only unread rows at or older than that key, so alerts newer than the cut stay unread. All three are ordinary command-receipt mutations. Reading the inbox is otherwise read-only: no admission, list, read, or read-all path rewrites the credential document unless it actually changed an inbox row. Retention evicts the oldest read rows before any unread row, so an unread alert is never dropped while a read row still occupies the bound. Every committed inbox mutation coalesces into one trailing `notification.inbox.changed` within about 250ms carrying `{ revision, unreadCount }` of that committed state, which lets a client skip a redundant refetch and project the bell immediately. Unknown, unavailable, suppressed, and rate-limited attempts create no inbox row. Preview-disabled explicit model text remains generic in both APNs and inbox storage.

Opening a synchronized mobile chat or local presentation also acknowledges every existing unread inbox row for that chat, across notification kinds and delivery outcomes. Ordinary chats match their exact canonical session. Home matches all physical chapter sessions currently owned by the authoritative Home ledger, so opening a completion's current chapter also reads a generic update from its sealed predecessor; notification kind, preview redaction, and the particular notification used to navigate do not narrow that cut. The trigger is a fresh visible transition of the existing token-bound `session.presentation.set` lease, after transport alias resolution and subscription admission—not `session.open`, a paired technical client, provisional synchronization, or hidden presentation. Ordinary visible renewals and duplicate/stale revisions do not take another read cut; re-entry, lease expiry, or a replacement reconnect token does. Notification selection and mutation linearize with admission and delivery settlement under the notification store mutex. Only the captured inbox IDs survive a failed write (at most 512); the existing two-second notification drain retries those IDs independently of relay availability or the initiating chat/socket. It never broadens a retry to newer alerts. No matching unread rows means no credential-document write or invalidation. Successful persistence broadcasts `notification.inbox.changed`, and later delivery settlement preserves read state. A migrated session identity takes its inbox rows with it, while a reset rebind (a fork or a new session) leaves the alerts it produced on the previous identity. An explicit `notify` admitted from a session the user is currently viewing is still delivered, but its inbox row is created already read so the bell cannot light for an alert the user is watching. Initial failures emit a bounded content-free diagnostic; unread state stays canonical. Pending IDs are process-local: a crash before persistence, or failure before a read cut can be captured, leaves rows unread until a later opening can acknowledge them. Focused regressions live in `runtime-registry-notification-read.integration.test.ts`, `notification-inbox.integration.test.ts`, and the presence/synchronization protocol tests. The Home-title cases in `runtime-terminal-notifications.integration.test.ts` additionally exercise the real model `notify` tool, local HTTP relay, and mobile WebSocket open/sync/visible journey with previews both enabled and disabled; their `test-results/home-title-payloads-{preview,redacted}.json` reports retain payload routes and unread counts before opening the ordinary chat, after opening it, and after opening Home, plus a real canonical-growth rollover followed by opening a successor completion with a predecessor update still unread. The sibling-opening cut leaves an unrelated chat unread. Delivered iOS Notification Center cleanup is separate native work tracked in #1304; a canonical inbox read alone is not proof of OS delivery removal.

Every successfully admitted semantic interaction (`select`, `confirm`, `input`, `editor`, or form) emits one detached input-required callback from the shared `SemanticUIBroker` boundary while that exact interaction remains pending. This includes forms produced by the provenance-checked `@zhushanwen/pi-ask-user@7.0.15` adapter without giving that adapter a second notification path. The generated interaction ID is the durable notification deduplication source. RuntimeSlot samples the same token-bound `session.presentation.set` lease synchronously at interaction admission: an already-visible chat writes only a `suppressed` receipt, with no relay intent, inbox row, or quota charge; a hidden chat queues fixed “Input needed” copy with the exact Gateway machine/session route. Notification failure never delays or fails the interaction. The persisted `notifyWhenAskPresented` field retains its wire name for registration compatibility but governs all semantic input-required alerts. Producer `needsAttention` activity, status text, widgets, retained surfaces, and ordinary runtime phases do not prove a response-capable user interaction and therefore do not trigger this hook.

Authenticated automation reads are `automation.status`, `automation.list`,
`automation.get`, `automation.schedule.preview`, `automation.timeline.list`,
`automation.run.list`, and `automation.run.get`. Receipt-backed mutations are
`automation.create`, `automation.update`, `automation.enable`, `automation.pause`,
`automation.delete`, `automation.runNow`, `automation.run.cancel`, and
`automation.run.resolve`. Definitions use optimistic revision fences; scheduler
state advances a separate state revision so a running occurrence does not
invalidate an unrelated definition edit. List responses omit action bodies and
page under an opaque exact catalog lease. Get returns the full authenticated
definition. `automation.schedule.preview` accepts `{trigger, after?, limit?}`
where the trigger is the strict one-time, anchored-interval, or calendar
contract, `after` is a Gateway timestamp (defaulting to now), and `limit` is
1–20 (default 5); it returns canonical future timestamps only and never writes
state. `automation.timeline.list` accepts `{from, through, displayTimezone,
cursor?, limit?}`. It admits a positive, at-most-seven-day timestamp window,
an IANA display timezone, and a page size from 1–200 (default 100). Its
revision-fenced opaque cursor is bound to the authenticated client and exact
requested window/timezone and expires after one minute; continuations cannot
cross clients, query windows, or catalog revisions. Enabled definitions are
expanded into canonical occurrence IDs in the half-open window and grouped by
display-timezone local day. More than twelve occurrences from one automation on
one day become one `series` item with `dayStart`, `firstAt`, `lastAt`, and
`count`; dense anchored intervals are counted analytically across local-day/DST
boundaries, including fully skipped civil dates, rather than expanded into
unbounded minute entries. Other entries are `occurrence` items. Items sort by
first instant and automation ID. Timeline materialization, iterative occurrence
generation, source bytes, page bytes, global leases, and per-client leases are
all bounded; capacity overflow is an explicit retryable error and never silently
drops occurrences. The timeline capability is advertised as
`automations.timeline.v1` alongside `automations.v2` only after automation
recovery is ready. The first-party schedule tool may target its current persisted
user session or create a new session in that session's canonical workspace. The
tool deduplicates mutations by canonical tool-call identity, retains immutable
assistant provenance for workspace-definition ownership, and rejects mutations
from an automation-originated turn to prevent self-replication. Paired Gateway credentials are machine-administrator
 credentials throughout the existing protocol, so authenticated mobile and local
 clients may manage automations across that Gateway; this is not a new
 per-session authorization boundary.

Authenticated push RPCs are `push.registration.upsert`, `push.registration.remove`, and `push.registration.status`; authenticated notification-resource RPCs are `notification.inbox.list` (keyset `cursor`, `filter`, `limit`), `notification.inbox.read` (one inbox ID or APNs request ID), and `notification.inbox.readAll` (a required `through` cut). Upsert derives `deviceId` from the connection and accepts only an opaque installation ID, endpoint-scoped grant ID/secret, the exact public relay origin that issued it, and preview/policy booleans; preview disclosure defaults off. A registration identical to the stored grant is answered with the same status and writes nothing at all: no command receipt, no credential document, and no delivery-receipt or revocation overlay. Every other upsert keeps its command receipt and is admitted durably as before. `hello` and `system.info` carry `pushRegistrationRevision`, a digest of the grants this Gateway stores and the relay origin they are valid for; it changes whenever a grant is added, rotated, disabled at runtime or retired, so a phone that acknowledged an earlier value re-sends its registration and learns the rotation requirement. Status returns the Gateway-owned relay origin and a bounded rotation requirement. A mobile grant issued by another origin, missing legacy origin identity, or rejected by the relay is never reactivated in place: iOS rotates it through App Attest and transfers the replacement capability. Upsert, removal, and `device.revoke` enter one bounded lane per target device before command-receipt execution, so cross-method invocation order is authoritative while different devices remain concurrent. Revocation disables local push authority before removing the paired bearer; a later admitted upsert revalidates that the device remains paired, and remote revocation retains a bounded tombstone. A grant ID awaiting revocation cannot be admitted as active again: upsert requires rotated endpoint authority, and restart retires any legacy active projection that overlaps a durable tombstone. Thus a delayed revoke can address only the old capability, never a newly active grant. The per-kind policy is Gateway-owned, defaults all three kinds on, and round-trips through registration upsert/status; the ask-notification policy is rechecked inside the same serialized admission transaction that appends the intent, so a concurrent policy disable can no longer admit and deliver an ask notification after the outer read. The public relay origin is read from the canonical maintainer-owned `config/PushService.xcconfig`, embedded into both signed products, and must be an exact public HTTPS origin. It is never accepted from tools, RPC, user settings, or runtime environment. Missing development configuration leaves notification delivery unavailable without affecting Gateway readiness; official packaging fails closed.

Outbound relay requests use one fixed `/v3/notifications` route (plus the unauthenticated `GET /v3/capabilities` read before queuing the settings "Waiting for you" push, whose allowlisted `settings-approval` category is sent only to a relay that lists it; [settings-model.md decision 35](docs/settings-model.md#81-decisions)), no redirects, a twenty-second deadline that exceeds the relay's bounded APNs deadline, a 2 KiB request and 16 KiB response boundary, and a lowercase-hex HMAC over method, path, timestamp, stable request ID, and the exact body's lowercase-hex SHA-256. Restart recovery retries transient outcomes with the same request ID. When the relay specifically reports that this ID still owns an active provider attempt, the Gateway polls it through the same bounded retry schedule; the relay ledger returns the eventual terminal result without creating a second APNs request. Unclassified ambiguous outcomes remain terminal and are never blindly replayed. Exact relay `invalid_signature` and `installation_unavailable` errors invalidate that grant without persisting or logging response bodies; mobile registration then rotates the capability instead of retrying an identity that cannot reach APNs. The Gateway adds no per-installation or per-session delivery quota; the relay applies a device-wide runaway backstop of 120 requests/hour and 1,000 routine requests/day, with ask and explicit notifications exempt from the daily cap.

## Transport

Wire-capability contracts are owned by complete operation families:

- [Connection and request protocol](docs/wire-transport.md): HTTP/LAN/device admission, hello, cancellation, receipts, ordered writes and liveness.
- [Media and live viewing](docs/wire-media.md): display, browser observation, uploads/blobs, immutable exports and prompt image bounds.
- [Session execution and presentation](docs/wire-session-execution.md): live projections, extension forms, queues, Stop/compaction execution and session-bound tools.
- [Session discovery and inspection](docs/wire-session-inspection.md): canonical catalog/acquisition, attention/archive and bounded history/resource reads.
- [Runtime configuration and administration](docs/wire-runtime-configuration.md): models/context, compaction settings, provider auth and packages.
- [Supervised host control](docs/wire-host-control.md): Gateway/Mac/device control, drain/exit proof and payload health.
- [Delegated activity and extension history](docs/delegated-activity.md): canonical producer attribution, lifecycle and read-only child ownership.

### Browser live viewing

[Browser live viewing](docs/wire-media.md#browser-live-viewing) owns the authenticated read-only observer contract.

### Model context windows

[Model context windows](docs/wire-runtime-configuration.md#model-context-windows) owns the model-qualified budget and Chat configuration fences.
`providers/context-window-policy.integration.test.ts` exercises capacity and
preference admission through real SDK sessions; `sessions/runtime-context-window.integration.test.ts`
adds durable overrides, cold resume and fork isolation through the Registry.

### Model recents and release dates

[Model recents and release dates](docs/wire-runtime-configuration.md#model-recents-and-release-dates) owns picker metadata and refresh bounds.

### Prompt attachments and request size

[Prompt attachments and request size](docs/wire-media.md#prompt-attachments-and-request-size) owns model-context image normalization and overflow recovery.

## Session invariants

Live parent runtime admission defaults to 128. Operators may set
`TRON_GATEWAY_MAX_LIVE_RUNTIMES` to an integer from 1 through 1024; this is a
resource ceiling, not a provider-throughput or hardware-capacity guarantee.
Reservations count toward admission. At capacity, the existing eviction owner
reclaims the oldest reloadable idle runtimes before admitting new work, without
waiting for the normal ten-minute expiry. Active work, subscribed sessions,
retained command leases, and unpersisted drafts remain protected. A repeated
acquisition also protects its exact requested session from pressure eviction. Canonical JSONL
is never evicted. Separate sessions run concurrently; child processes retain their
own provider/resource admission limits and are not counted as parent runtimes.
The registry integration suite qualifies 128 simultaneous synthetic parent runs
across eight projects through child-file churn and repeated client reentry.

Admission also holds a byte budget, `LIVE_RUNTIME_BYTE_BUDGET` (1.5 GiB) in
`packages/gateway/src/sessions/runtime-registry.ts`, because the runtime count
alone let loaded sessions push the heap toward its limit. Each live runtime is
charged `LIVE_RUNTIME_HEAP_ESTIMATE_FACTOR` (3) times its canonical JSONL bytes,
measured at admission from the same one-`stat`-per-runtime inventory the
resource sample already reads. The budget is eviction pressure, not an
admission gate: when the live charge plus the opening session's charge exceeds
it, the largest reloadable idle runtime is retired first (the one whose
retirement reclaims the most), under the protections above, and retiring
continues until that projected total fits. Nothing is retired when retiring
could not help — the opening session's own charge is larger than the whole
budget, or the excess is larger than every eligible runtime together — and an
admission the retired set still cannot fit is served anyway, with its
`runtime.loaded` record carrying `overBudget: true`. The runtime count and the
explicit heap limit below stay the backstop; this budget never refuses an open,
and refusal under the real heap limit is not its decision. The projected total
counts the starts already reserved for, except the requested session's own
reservation, which the opening charge already is: two opens of one session at
once therefore retire nothing for it, and a start that adds no bytes (a session
that has not written a transcript yet) retires nothing either. The launcher
passes `--max-old-space-size=4096` to the Gateway's Node process
(`packages/mac-app/scripts/tron-gateway-launcher.c`), and the budget is sized
below that limit. `runtime.loaded` and `runtime.evicted` record each transition
with the session, its reason (`heap` for the heap-pressure pass `G-12` added),
its transcript bytes and the charge, as named `counts`.

A chat's tool loadout (`tools.active` at the Chat layer) lives only in its canonical
transcript, as the system messages' `toolsAdded`/`toolsRemoved`. Every runtime
the Gateway creates for an existing transcript (cold open, reopen after idle or
capacity eviction, restart, fork, previous-runtime restore) applies the loadout
the transcript declares; only a transcript that declares none gets the
configured `defaultTools`. Pi's `createAgentSession` always supplies the
defaults and so skips its own transcript restore, which made an enabled tool
such as `codemode` disappear after a reload and the next prompt persist the
defaults. `runtime-tool-loadout.integration.test.ts` covers a reopen and the
next prompt.

Catalog membership is one owner's index, so nothing coalesces a second
discovery: a live persisted `RuntimeSlot` proves membership for
attention reads and writes, as it does for `acquire`, so acknowledging an open
chat never walks catalog headers. A cold open's fence reads only
the target: exactly one unchanged canonical claimant for its ID, and that file's
own stat and header. Unrelated
catalog churn, such as files created by active subagents, cannot fail the open. Every opened header descriptor closes even if its
initial tail probe fails. Upload and display orphan maintenance resolve canonical
session membership inside their respective serialized ownership lanes, after
previous claims/grants commit; a cut that cannot prove membership preserves
ownership rather than interpreting unavailable membership as an empty catalog.

1. `RuntimeRegistry` owns at most one `RuntimeSlot` per session in this process.
2. `RuntimeSlot` serializes mutations for its session. Different slots execute
   concurrently.
3. Prompt admission returns an operation ID; client disconnect does not abort it.
4. Subscribe/open establishes a two-phase baseline barrier: the connection subscribes
   and captures a snapshot cursor, returns that snapshot plus an ephemeral `syncToken` and
   explicit `subscriptionToken` ownership credential. The connection-local token map is the
   sole installed-subscription representation; replacing a session atomically replaces its slot.
   The client acknowledges the exact
   baseline with `session.sync`, after which only later sequenced events are released.
   While the barrier owns a session's catch-up it is the only delivery path, so every
   in-window event reaches the client exactly once and in sequence, except where the
   connection's outbound queue supersedes unsent state: a dropped sequence is always
   covered by the `session.rebaseline` that replaced it, so the client can
   still accept what follows. Only state that replacement fully re-states may be
   dropped; a frame whose effect installing a snapshot does not perform (a failure
   receipt, a revision bump, an editor directive) is a fence, and it and every frame
   behind it arrive in order. A bounded barrier
   overflow converges the client with a fresh authoritative `session.rebaseline`
   snapshot instead of a resync dead end; only an unavailable session falls back to
   `transport.resyncRequired`.
   A failed open transaction revokes
   its barrier, timer, and subscription ownership immediately, so retrying cannot produce
   a stale “already synchronizing” conflict. Concurrent opens for the same connection and
   session are rejected before they can replace the owner; establishment and synchronization
   commit are request-and-token exact. Distinct sessions and connections remain independent.
   A connection whose `hello` declared `clientRole: "mobile"` instead holds **one mobile
   presentation**: a newer `session.open` retires every other session's synchronization and
   subscription on that connection, synchronized or not, so several answers are never mounted
   on one mobile connection at once and only the newest one can synchronize — an earlier
   answer's `syncToken` is refused with `conflict` (the phone replaces its mounted chat and
   cancels the page it stopped waiting for, it does not keep two). A technical client on its
   own connection keeps independent subscriptions.
   `sync-protocol.integration.test.ts` covers the retiring mobile open and both sides of that
   boundary.
5. Reconnect/open returns complete current runtime state plus a bounded canonical
   transcript tail, not durable missed-event replay; older transcript pages remain
   available through branch-stable anchors.
6. A run marker exists only for an admitted active operation. Startup projects a
   surviving marker as `interrupted`; prompts are never replayed automatically.
7. A foreground snapshot cannot be idle while the embedded runtime is streaming,
   and an idle snapshot cannot retain a running foreground-tool overlay. Detached
   extension work is represented separately by extension UI state.
8. Fork/session replacement rekeys the same owning slot and subscription-token map entry. An open that overlaps rekey uses the slot's post-acquire canonical ID for synchronization, snapshot, and attention. A replacement open rotates the carried token; an old-ID close may resolve through the bounded alias but cannot revoke that newer token. Pre-commit rekey failure restores the source runtime and removes any uniquely created fork JSONL/artifact directory before reporting failure.
9. Idle runtimes may be evicted only while not busy and unsubscribed.
10. Administrative restart waits for admitted agent runs to settle and requires an
    external supervisor; it never claims that in-process runtime memory survives replacement.
11. The gateway is the sole mutable runtime owner. Terminal and mobile chat surfaces
   must attach to this runtime; opening the JSONL in an independent Pi process is
   unsupported because Pi has no cross-process session lock.

## Trust and execution

Each project session has an isolated mutable model/provider runtime. Tron's
administration/onboarding runtime loads the user's global Pi extensions into the
canonical global ModelRuntime without loading untrusted project resources. The
Dashboard provider catalog and global authentication use this runtime before any
session is opened; project-only extension providers remain in their trusted
project RuntimeSlot and never enter the global catalog.

Global package install/update/remove and Mac-layer `settings.change` changes to
`sources.packages` or `sources.extensions` request a serialized global
extension-resource reload. An admitted global package mutation with an uncertain
outcome also requests reconciliation; validation failures and uncertain
project-scoped mutations do not. Pi remains the resource-loader/provider-
registration owner; Gateway reconciles each extension-owned provider ID with its
actual extension runtime in the same ModelRuntime and credential store. Provider
and model catalog reads, provider-usage reads, and global model refresh serialize
with asynchronous reconciliation. The normal provider/catalog invalidation is
published after registrations commit, even
if the SDK's later availability refresh reports an error. A per-extension
load/registration failure is logged without removing that extension's last
working registration or other valid providers. A global authentication operation
remains a provider-runtime user until its underlying login promise settles, even
after timeout or cancellation retires its UI operation. Reconciliation waits for
those promises; while authentication or refresh is pending, new global auth begins
are rejected retryably rather than using a stale provider registration.
The pinned SDK merges duplicate provider registrations in extension order: later
defined fields take precedence and omitted fields remain from earlier
contributors. Gateway retains every registration/runtime contribution and replays
the current ordered set after unregistering old extension layers, so removing or
reordering a contributor does not leave stale fields behind or disturb built-in
providers. Project-scoped package and settings changes do not reload or mutate the
global provider runtime.

### Mac Terminal

Mac Terminal gives the iPhone login shells on this Mac that do not depend on
the Gateway: it connects with SSH to macOS Remote Login (the built-in sshd) over
Tailscale, so it keeps working while Tron.app or the Gateway is quit, crashed or
being replaced. The Gateway's only part is enrollment and revocation
(`src/security/mac-terminal.ts`) and shipping the shell host:

- **`macTerminal.status`** (paired iPhones only, no parameters) returns the login
  `username`, `port` (22), `hosts` (MagicDNS name, then Tailscale addresses, from
  `tailscale status`), `hostKeys` (`/etc/ssh/ssh_host_{ed25519,ecdsa}_key.pub`),
  `remoteLogin` (`on`/`off`/`unknown` from one bounded loopback connect to the
  port; Tron never changes Remote Login), whether this device is `enrolled`, and
  `hostCommand`: the argv (this Gateway's node, its compiled
  `machine/mac-terminal-host.js`, `connect --home <tronHome>`) that reaches the
  shell host. It is omitted when no compiled host sits beside the Gateway.
- **The shell host** (`src/machine/mac-terminal-host.ts`, #1075) keeps Mac
  Terminal's shells across disconnects. It is this Gateway's `TerminalService`
  (PTYs, bounded replay with sequences, the #479 idle and busy rules and closure
  reasons) in its own process, so a Gateway restart, quit or replacement never
  touches it. The iPhone's SSH exec channel runs `connect`, which relays stdio to
  `<tronHome>/gateway/mac-terminal/host-1.sock` (directory 0700), first starting
  the host detached in its own session (`serve`) when none answers. The protocol
  is one JSON object per line: a `{"hello":{"protocol":1}}` greeting, then
  `list`, `open` (columns, rows; a `$SHELL -l` in the home directory), `attach`
  (shell, `after` sequence; returns chunks and `reset`), `detach`, `write`,
  `resize` and `terminate` (the process group), answered by `{"id","result"}` or
  `{"id","error"}`, with `output` and `exit` (`exitCode`, `closedReason`) events
  to the connections attached to that shell. Closing a connection only detaches.
  The socket name carries the protocol version, so a different protocol starts a
  second host and never strands an older host's shells. The idle period is
  `setup.terminalIdleMinutes`, read from the Gateway store at each idle pass, as
  the Gateway reads it. Shells start from the SSH session's environment without
  its `SSH_*` connection variables. With no shell running and no connection for
  24 hours the host exits; until then exited shells (and why they closed) stay
  listed. Its diagnostics go to `gateway/mac-terminal/host.log` (truncated past
  1 MiB at the next start).
- **The key** is the Mac-layer setting `permissions.macTerminalKey`, qualified
  by `device`, stored as one line of `~/.ssh/authorized_keys`:
  `from="100.64.0.0/10,fd7a:115c:a1e0::/48",no-agent-forwarding,no-port-forwarding,no-X11-forwarding,no-user-rc ecdsa-sha2-nistp256 … tron-mac-terminal:<device> …`.
  Only an `ecdsa-sha2-nistp256` key (the iPhone's Secure Enclave key) is
  admitted. Adding one is a widening with an `approve` floor: the maintainer's
  own tap applies it, any agent's request waits for his approval. Removing one
  is `notify`. An iPhone may enroll only its own device id. Every change goes
  through `settings.change` and the record, like any other setting.
- **The file** is the store: Tron rewrites it atomically under its own lock,
  keeps every other line byte for byte, writes mode 0600, and refuses a symlinked,
  non-regular or oversized file. A line deleted by hand on the Mac is simply a
  revoked key, with or without the Gateway.
- **Revocation** is the key unset from the iPhone's Mac Terminal menu or by any
  chat's `settings` tool on the Mac, deleting the line by hand, or revoking the
  paired device: `device.revoke` removes the device's key first and refuses the
  revoke if that fails, so a revoked iPhone never keeps a working key.

The iPhone pins the reported host keys at enrollment and refuses any other key
with its fingerprint; see the iOS architecture's
[Mac Terminal](../ios-app/docs/architecture.md#mac-terminal). The journey
`npm run test:mac-terminal` (it needs this Mac on its tailnet and Swift 6.2)
enrolls through a real Gateway into a real sshd's `authorized_keys` and logs in
with the app's own SSH client: success with PTY resize, login with the Gateway
gone, host-key mismatch, the `from=` restriction, revocation from the iPhone and
by device revoke, and Remote Login off. A second case compiles this package and
drives the real shell host through the same sshd: a shell survives its link
closing, reattaches with its replay and the same `$$`, a second shell is a
different process, `exit` ends only it (listed with its exit code), and Quit ends
the process group while the host stays. Its transcript is
`test-results/mac-terminal.json`.

### Project root

The Project layer is the `.pi/` of a chat's Project root, even for a chat started
in a subdirectory (settings-model decision 31). `projectRoot()` in
`src/machine/workspace-inspection-service.ts` is the only resolver: the realpath
of `git rev-parse --show-toplevel` for the canonical chat cwd, so each linked
worktree is its own Project. When Git reports no work tree (no repository, a cwd
inside `.git`, a refused ownership check) or cannot run, the cwd itself is the
Project; a Git timeout stays a retryable error so one decision never lands on two
directories. `TrustService` resolves it with every inspection
(`TrustInspection.projectDir`) and records, reads and re-reads the decision for
the root, with `hasTrustRequiringProjectResources(cwd, projectDir)`; a decision
saved earlier for a subdirectory no longer applies, so such a chat asks once for
its root. Tron Home's workspace is a standalone directory
(`TrustServiceOptions.standaloneDirectories`): its explicit untrusted decision
never reaches a repository that encloses the Tron home, while a repository inside
the workspace keeps its own root. Each runtime build passes
the root as the SDK's `projectDir` to `SettingsManager.create()` and
`createAgentSessionServices()`, so Pi reads Project settings, packages,
`.pi/{extensions,skills,prompts,themes}`, `SYSTEM.md` and built-in MCP
configuration from the root and starts stdio MCP servers there; extensions read
`ctx.projectDir`. The chat's own cwd still owns tools, context files
(`AGENTS.md` from the cwd and its parents), session grouping and `ctx.cwd`.
Trust changes and Project settings reload every live chat of the root
(`RuntimeSlot.projectDir`); session-free package, hook and settings reads,
compaction policy and project MCP administration use the same root.
`src/sessions/project-root.integration.test.ts` proves a nested chat against a
real repository, linked worktree, stdio MCP server and faux model, writing
`test-results/project-root-864.json`. The SDK option comes from the
[Tron-patched `pi-coding-agent`](#tron-patched-pi-coding-agent).

### Tron context and delegated children

The bundled `tron-core` extension appends Tron identity, the resolved internal
workspace path, and active-tool guidance to the Gateway-owned parent Pi runtime.
It does not change the session `cwd`, load workspace contents, or replace Pi's
base prompt. This inline extension is not automatically loaded in native
`pi-subagents` child processes.

`pi-subagents` exposes bounded `extensionBindings` for native child metadata and
retains the original binding for a resumed run, but the current supported
transport only places JSON in `PI_SUBAGENT_EXTENSION_BINDINGS`; it does not load
an extension or append that value to the child's prompt. Its public request
schema has no per-call `extensions`/`subagentOnlyExtensions` override. The
`subagents.defaultExtensions` setting configures `extensions` only, and
`runtimeSnapshotHost` snapshots runtime MCP servers only. Pi's built-in MCP
configuration is shared through the Gateway agent directory for ordinary CLI
children; explicit child extension lists disable Pi built-ins and MCP server
snapshots are bounded to the child's supported configuration. See
`docs/mcp.md` for the MCP authority and transport boundaries. Tron therefore
does not mutate Pi settings, agent
definitions, or workflow scripts to force-load
`tron-core`, and must not claim automatic identity/workspace propagation to an
arbitrary child. A public mutable `tool_call` hook prefixes direct model-facing
`subagent` task/resume text with a bounded (2 KiB UTF-8) advisory handoff, preserving
the task verbatim and never truncating it. Direct execution selects `agent` and
excludes `workflow`. Tron's model guidance tells the model to write a workflow script
to a git-ignored file under the request cwd and pass its relative path (a string
containing `/`); absolute paths such as `/tmp` fail. Other strings select a named
workflow resource. `workflow: true` (a script
in the same assistant reply) is not recommended because the script prints in chat.
The hook never rewrites workflow source or mixed `agent`/`workflow` requests. Native tasks above 8,000 UTF-16 code
units use the launcher's private task-file delivery; that is not a task rejection
limit. Workflow/structured delegation stage limits remain runner-owned (1 MiB
UTF-8 in the pinned native implementation).

Workflow child launches, slash/RPC/structured delegation, and further children do not
emit this parent tool event: explicitly repeat identity, root, availability and
ownership in every stage/task. The handoff does not grant authorization, change
cwd, load extensions, or give a child parent tools. Explicitly configured child
extensions are an agent configuration guarantee, not Gateway inheritance.

External CLI/job runners do not accept `extensionBindings` and do not provide
native fork/resume, tool-event, or supervisor guarantees. They can receive the
same advisory facts only as runner-specific prompt/task text.

Unresolved trust blocks project resource loading. A trusted project may load
settings, extensions, skills, prompts, packages, and system prompt files with the
Mac user's authority. This is not sandboxing. Package and extension source must
be reviewed before installation. Trust mutations serialize, prepare every open project runtime with
the exact proposed decision, and persist only after all reload attempts settle successfully. A reload
or persistence failure restores the exact prior saved decision and reapplies that runtime state before the mutation can fail; rollback
activation failures remain explicit instead of reporting a failed-but-applied trust change.

The PTY implementation uses node-pty's architecture-specific macOS spawn
helper. The locked package's install hook is followed by Tron's `postinstall`
repair, which enforces executable permissions on that helper; terminal tests
open a real PTY so packaging cannot silently ship a non-executable helper.

## Session search

[Session search](docs/session-search.md) owns `SessionSearchService`, the
in-process index Home's `session_search` research tool reads. It has no client RPC.

## Episodic memory

[Episodic memory](docs/episodic-memory.md) owns the projected-summary tree
(`packages/gateway/src/episodic/`): its projection rules, tree and view algorithms,
invalidation semantics, reported token spend, bounded retries and blocked states,
and its storage under the internal workspace. [Tron Home](docs/home.md#memory-and-readiness)
is its live caller: HomeOwner keys one store by stable `homeId` and supplies the
canonical chapter source in ledger order. RuntimeSlot reports committed entries
and navigation; HomeMemory ingests the source and builds missing summaries in the
background. Each activation waits for and freezes the view preceding its start,
then sends that view instead of earlier activations' transcript. Ordinary sessions
do not use episodic memory.

## Development

```bash
npm ci
npm run build
npm test
npm audit --omit=dev
```

`npm run check` checks production and test-support/corpus scopes separately,
without emitting runtime files. Only these no-emit checks use TypeScript's native
incremental data in `node_modules/.cache/tron/` (separate production/support
files). The compiler revalidates source, dependency types and options; this is
not a remembered pass or a test-selection cache. Removing it only makes the next
check cold. `npm run build` always performs ordinary checked production emission
before the support check, so warmed no-emit data or deleted `dist` outputs cannot
suppress JS, declarations or maps. Each command prints its current compiler phase.
Keep the production `rootDir` and support/corpus scope distinct: both have unique
failure guards, including imports that would escape the production output root.

`npm run test:typescript-build` drives the actual npm scripts and pinned compiler
in a temporary project: cold/warm checks, cached diagnostics and repairs,
source/dependency/config changes, corrupt cache, production-root/declaration
refusals and deleted-output recreation. It is also part of `npm test`, and leaves
`test-results/typescript-build/report.json`, including completed steps on failure.

Vitest admits at most four workers (or the host's available parallelism when
smaller). The suite runs real durable filesystem/SQLite fixtures and SDK child
processes; CPU-count fanout can saturate shared host resources and consume a
test's deadline before its owned work can finish. This is a test-runner resource
bound, not a change to test selection, per-test concurrency assertions, or the
15-second default timeout. Production scheduling is unchanged. Keep focused
owners narrow while iterating and use the full configured suite for checkpoints.

`npm test` runs two Vitest passes, in order. The main pass (`vitest.config.ts`) runs
the parallel suite. The nested pass (`vitest.nested.config.ts`) runs the files that
spawn nested Vitest or real pi children, or that activate the real managed provider
(including a first load from a fresh install root), one file at a time. That config's
list is the single owner of which files are nested. Under parallel workers those
children starve and miss their execFile or detached-process bounds, so they cannot
share the parallel pass; the bounds are hang bounds only, and a passing run never
reaches them. For the same reason the nested pass declares its own hang bounds (240 s
waits under a 300 s test timeout, owned by that config) instead of the main pass's
12 s under 15 s. A fresh root's first managed load transpiles the whole extension
graph because jiti's cache is keyed by absolute path; production reuses one stable
root, so only its first load per install pays that cost.
Run one of them with `npx vitest run --config vitest.nested.config.ts <file>`.

Tests own every remote boundary through injected fetchers, resolvers and HTTP
stubs. `test-support/network-isolation.ts` refuses any non-loopback TCP
connection opened by an in-process socket in the Vitest worker and fails the
current test (or the file, for async work that outlives its test), so an unstubbed in-process fetch cannot pass or
hang depending on the host's network. It does not cover child processes or DNS
lookups.

Waits are hang bounds, not speed budgets. Every condition a test waits for — a
turn settling, a frame arriving, a record landing — is correct at any speed.
`test-support/wait-for.ts` owns that bound: `waitFor(condition, label)` polls a
sync or async condition on real timers and `awaitsWithin(promise, label)` bounds
an event or promise the code already exposes. Both fail with their label at
`WAIT_HANG_BOUND_MS` (12 s, kept below the 15-second `testTimeout` so the failure
names the condition instead of being cut off), and neither moves a fake clock a
test installed: a file that fakes timers advances them itself. A wait that a
hook runs (`beforeEach`/`afterEach` and the cleanup callbacks they await) passes
`HOOK_HANG_BOUND_MS` (5 s), because Vitest's 10-second `hookTimeout` would
truncate the label. A call site with its own measurement budget passes its own
`boundMs` and says why. Every Gateway wait converted by #433 and #460 goes
through this helper: `vi.waitFor`'s per-call speed budgets are gone, and a wait
under fake timers advances that clock itself, because the helper never moves a
clock a test owns.

A bound tuned to host speed turns unrelated CPU contention (parallel agent
builds, hosted runners) into a false failure that lands on a different test each
run (epic #400). Prefer awaiting the event or promise the owning code already
exposes. Where elapsed time, a pass count or an attempt count is itself the
contract — a throughput or latency relationship the test measures, a bounded
number of discovery passes, an event storm whose length is the assertion — keep
that explicit bound or count and say why at the call site.

Two shapes that have failed under load (#650). A Stop, abort or steer that
follows a wait for `slot.isBusy` or a phase is racing SDK admission: `isBusy`
turns true at slot admission, and a Stop before the SDK admits the run revokes
the prompt. Gate on the run's own entry (the faux response function signals when
it is called) instead. And a wait whose condition needs a streamed faux reply
must keep that reply short: the faux provider paces each chunk with a timer of at
least 1 ms, so an 88 KB reply alone costs seconds against a 10 s bound.

Attach a terminal chat surface to the same Gateway-owned runtime as iOS:

```bash
scripts/tron chat --session <session-id>
# or select the newest session for the current working directory
scripts/tron chat
```

This client uses the stable Tron protocol, a 64 KiB-bounded local wrapper credential,
atomic snapshot/event catch-up, command IDs, and reconnect convergence. Automatic
session selection admits at most 126 pages/25,000 unique rows/8 MiB, rejects cursor
cycles and malformed pages, and restarts mixed revisions once rather than recursing.
It does not open
or watch JSONL directly. Running `pi --session <same-file>` concurrently remains
unsupported because that creates a second mutable runtime owner.

Run one test owner while iterating. The HTTP lifecycle owner exercises real
15-second header, 30-second body-idle and 300-second whole-request deadlines;
its five-minute trickling-body journey is intentional, not a stuck-run signal.

```bash
npx vitest run src/transport/sync-protocol.integration.test.ts
npx vitest run src/sessions/runtime-registry.integration.test.ts
```

The integration tests use the SDK's faux provider to verify concurrent real
session runtimes, detached completion, and fork rekeying without network
credentials. A scripted MCP call joins the actual direct-tool registration
boundary first: creating a runtime does not mean its asynchronous HTTP discovery
has completed. Codemode fixture directory setup gives recursive extension-directory
creation sole ownership of its parent, avoiding a competing plain parent mkdir.
The live/cold transcript and MCP execution assertions remain the behavioral oracles. Additional deterministic tests exercise interactive API-key and
OAuth brokering, project trust, and native local-package persistence,
and credential separation. Managed Git rollback journeys separately check the
owned directory is absent (`ENOENT`) and whether its branch must be deleted or
preserved after the branch head moves; an arbitrary filesystem error is not
cleanup proof.

### Lint

`npm run lint` is the Gateway's Oxlint pass. Oxlint 1.88.0 is pinned exactly in
`devDependencies`. `.oxlintrc.json` turns every category off and enables only the rules it
names, so a rule is in force only when it is listed there with zero findings:

- `eslint/no-dupe-keys`: a later key silently replaces an earlier one in an object literal.
- `typescript/no-non-null-asserted-optional-chain`: a `!` after `?.` asserts away a value the
  chain can return as `undefined`.

The pass covers `src`, `test-support`, `test-fixtures` and `scripts`, with the same rules for
source and tests. These rules are syntactic, so the run needs no type information and no
`tsconfig`. Run `npm run lint` directly when useful. `npm run test:lint` runs
`oxlint-rules.integration.test.mjs` against the installed binary and checked-in config:
real bad fixtures must fail at file/line, unused disables fail, and clean code passes.
There is no gate-wiring regression, automatic prerequisite, receipt or hosted CI step.

A disable comment needs a reason after `--` by convention; `--report-unused-disable-directives`
only proves that a disable suppresses something.

Deferred, not enabled: the type-aware async rules (`no-misused-promises`,
`no-floating-promises`, `await-thenable`, `only-throw-error`) and `no-unused-vars`. Each has
open findings across `src` and tests; #1227 owns their triage before they can join the zero
baseline. Until then, lint does not catch a promise that escapes its owner, such as the async
`close` listener in `src/admin/mcp-admin-service.ts`.

### Wire-traffic profile

[Wire-traffic profile](docs/wire-profiling.md) owns the `scripts/tron-profile gateway` scenarios, metrics, bounds and limits.

#### Multi-session qualification

[Multi-session qualification](docs/wire-profiling.md#multi-session-qualification) owns the opt-in scale and impairment workload.

## Session subagent activity

[Delegated activity](docs/delegated-activity.md#session-subagent-activity) owns producer admission, process projection, recency/history and exact child transcript authority.

## Extension activity lifecycle and history

[Extension activity lifecycle and history](docs/delegated-activity.md#extension-activity-lifecycle-and-history) owns lifecycle artifacts, terminal receipts, bounded discovery and expiry contracts.
