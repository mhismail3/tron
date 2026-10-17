# Delegated activity and extension history

[Gateway contract](../README.md)

## Session subagent activity

The additive `process-activity.v1` projection observes only structured synchronous and
asynchronous delegated subagents that already have an authoritative producer. It does
not add another shell tool, detached executor, PTY, process supervisor, or event journal.
Assistant `bash`, direct user `!` bash, Terminal-sheet PTYs, ordinary tools,
administrative work, and shell grandchildren inferred from command syntax remain outside
this surface and continue through their existing transcript/tool presentation. The built-in
foreground bash owner gives each shell a filtered snapshot: it withholds all inherited
`PI_*` and `TRON_GATEWAY_*` variables, then supplies only that canonical session's opaque
`PI_SESSION_ID` for `scripts/tron work`. It preserves PATH intact so managed agent tools
under the live home remain available; PATH identifies executable search locations, not a
data root. The delegated-provider keeps its separate in-process `PI_SUBAGENTS_TEMP_ROOT`
for pi-subagents children; arbitrary shell commands and their process trees do not receive
that live-home root, Gateway supervision/payload identity, or the `TRON_DATA_DIR` and
`TRON_HOME_NAME` selectors. Gateway Vitest configurations (regular, scale and corpus), Node
test scripts share one environment policy. Vitest rejects during setup, before
test modules execute. The policy expands SDK-style `~` paths and
normalizes dot segments, including path-list entries, and interprets `TRON_HOME_NAME` using
the same home-relative resolution as `resolveTronHome()`.

`SessionProcessActivity` gives subagent rows a stable namespaced `processId`, typed
source/mode/lifecycle, bounded current-tool/output facts,
an optional bounded `durationMs` derived only from existing producer timing or canonical
start/terminal timestamps, and an optional opaque validated child-session reference. The
installed pi-subagents foreground producer uses one bounded child index consistently
across progress and terminal result arrays. Gateway admits that positional identity only when
the exact `subagent` tool owner matches the installed pi-subagents extension and the bounded
shape has unique safe-integer indexes (or the terminal result array preserves the already
owned child order), an agent, and recognized lifecycle evidence. The normalized
`foreground-index:N` producer is scoped by the canonical parent tool call. Generic extension
tools continue to require explicit structured `runId`/`asyncId` evidence and can never turn
array position into ownership. Installed-provider identity is derived from the finalized
Pi `SourceInfo.source` npm package-name component, corroborated by the installed
`package.json` name, existing provider-path evidence, and finalized `subagent` tool owner.
The full configured source remains the owner provenance, including an exact npm version
or an explicitly configured absolute `.tgz` file source. npm aliases, other
package names, malformed sources, and same-named local/Git extensions fail closed.

For an exact-owned asynchronous pi-subagents artifact, Gateway applies the producer's stable
child contract: explicit `childId`, then workflow key, then child `runId`, with `step:N` as the
canonical bounded top-level default. A fresh workflow child's `runId` is also its separately validated
session-path owner and must be present from launch; pi-subagents 0.59 and newer publish that evidence
for foreground workflow children. Older artifacts that expose only a workflow key and path remain
visible but cannot authorize a live transcript. Thus ordinary single/parallel/chain artifacts have an exact child
row before and after terminal persistence even when a step has no independent run ID. A single async
run may reserve its fresh child path under the parent fan-out root rather than its detached async run
ID. In that shape, Gateway reads the exact-owned private recovery descriptor and accepts its root only
when descriptor version, source run, exact session file, and fan-out contract all match the live status
step; a missing, foreign, replaced, or malformed descriptor leaves the transcript unavailable. The
same producer identity enriches that row with a validated session reference rather than
re-keying it. `ChildSessionAdmission` (`src/sessions/child-session-admission.ts`) owns child-session file admission: exact canonical containment, header and file identity, and the bounded index of admitted paths, while RuntimeSlot keeps the process-to-child bindings and clears that index at its reset and dispose cuts. If status publishes the owned session target just before Pi creates its canonical JSONL,
Gateway retries that exact artifact binding on a bounded backoff and once on an explicit transcript-open
request; no ambient path scan or client inference participates. Bare launcher acknowledgements remain hidden until the lifecycle artifact
contains child execution evidence. This keeps the composer activity overview continuous
without treating labels or generic extension array positions as ownership.

Async lifecycle artifacts use one canonical `status.json`; its first JSON property is the
bounded `lifecycleProjection` header. RuntimeSlot structurally admits a complete header
from a 32 KiB prefix (header value at most 30 KiB). Parent identity follows the provider's
path-first rule: `sessionId` exactly matches the resolved canonical parent session file,
or the session UUID only when the slot has no file. File identities have a 4096-byte bound,
not a UUID-sized bound. The producer preserves this owner through legitimate resumes.
Within the existing 256 KiB document bound, native presentation reads the full status
steps in launch order, keeping agent-role titles, model/thinking, task, path/output,
attention and counters with Gateway's 32-per-node and 64-total child caps. Released
workflows keep detached execution details in child status files rather than copying
them into root steps. The same read owner joins a bounded single-child execution
through its reciprocal workflow run/key, run ID, parent session, session owner and
validated session file. Only display facts cross that edge; identity and order remain
root-owned. Child detail is optional hydration: missing, malformed, foreign or
unavailable status never refuses root admission or lifecycle publication. Each
unavailable child contributes to the existing `lifecycleOmissions.children` partial
count while its authoritative root edge remains present. The root observation owns
bounded child subscriptions, each filtering parent-tree events to its exact edge;
they observe missing directories' creation and later child-only writes without a
root event.
Edges retire only when the root removes them or its observation retires. Child
watcher errors stay local and never stop the independent root watcher.
A workflow can complete while its runner-backed children keep running. The root observation
then stays open, and the live child counts as live work of its run in the one liveness rule
shared by the dashboard, drain, eviction, and Home task settlement. A terminal root's lifecycle
never moves; only its child rows update until every child is terminal or has an
exact-owned paused process-exit proof. That proof crosses the verified reciprocal
child edge privately; it never changes the child's resumable lifecycle or fabricates
success. Child status and process-terminal sidecar writes both refresh this observation.
Home task status, report admission and task-end Stop select the same exact executions
from one admitted artifact frame. While a root owns live work, its ID is the Stop
target; once it completes, status names each still-live detached child's run ID,
not the completed workflow ID that the provider cannot stop. Selection performs no
second artifact read or await. A process-exited paused child cannot block reporting;
an unresolved paused child remains protected and can be stopped by its exact run ID.
Cold task settlement uses the same paused-exit proof validator and the shared 256KiB
full-artifact bound, including every async child's own status. Missing, malformed or
over-bound cold evidence remains unproven, never inferred successful from a workflow
step. `home-task-subagents-reports.e2e.test.ts` covers real paused-child report/Stop
and a completed workflow status larger than 64KiB across restart; the running-child
report refusal and late-runner settlement journeys preserve live-work protection.
An explicitly empty recent-tools list with no total represents zero tools before the
first tool event. The header supplies ownership, not the compact widget's labels,
ordering or eight-child limit.
Run/tool identity must agree between header, full status and canonical launch binding.

`src/sessions/subagent-parity.integration.test.ts` compares the managed selection's
real RuntimeRegistry projections to `test-support/subagent-parity-old.json`. The same
faux-parent/loopback-child script runs an async single and a three-child failure,
question/answer and success workflow with progress and idle completion wakes. The comparator visits mounted process rows in canonical launch and producer-child order
(no value sorting), comparing state/attention/visibility/mode/source, displayed
model/thinking, current tool/path, output/error tail and truncation, counters,
parent/child/control identity shape and timing presence. The transport's recency
ordering is not a launch order: its random-ID/time tie-breaks remain in raw snapshots.
Child task/control and host-step fields are compared alongside those rows. Transcript
content parts and details, semantic classification/delivery, retained content classification/visibility and app-visible widget/status contents
and component frames are compared, not just category labels. Subagent-owned retained
state is excluded by native `ExtensionRetainedContentPolicy.content`; its private
bytes are retained as evidence, not compared as app text. Native active/recent/problem
counts are compared independently of private provider-frame counters.
Settings includes skill/prompt rows and diagnostics plus agent discovery before,
during and after an invalid definition. An idle real wake is gated before binding;
a separate factory-API steering probe compares displayed queued input with ordinary
maintainer input while retaining hidden wake authority in evidence.
Execution-specific identities, temporary roots, timestamps and elapsed intervals are
normalized; pi-subagents' versioned installation root and bundled `[worker eval]`
frame positions change on every fork bump and are normalized on both legs (the
committed OLD baseline is normalized at comparison). Launch/child/widget order and
authored text remain meaningful. Transport
revision counters are not presentation values. Finite label/delivery allowances and
exact OLD/NEW upstream value pairs in `test-support/subagent-parity-approved.json`
cover only the approved dependency changes (including notification guidance,
resource wording/catalog additions and removed-field
warnings). There is no process-field or blanket content exemption. Idle decision/
completion delivery must match OLD's triggeredTurn, and no wake transcript row is
allowed. The report at `test-results/subagent-parity.json` retains raw statuses,
snapshots and canonical entries. Its typed report fields distinguish always-present
comparison checkpoints from raw snapshots captured only after a successful launch.
This verifies Gateway wire/projection parity, not Swift layout or pill labels.
`TronSubagentParityUITests` separately exercises rendered message details, process
metadata/tool/path/output, private-frame exclusion, Settings skills/prompts/definition
diagnostics and pending/queued wake suppression on bounded hosted fixtures. Those
fixtures are not live Gateway-to-phone or physical-device evidence.

To regenerate OLD, use the pinned Node with isolated HOME/TMPDIR and run
`bash scripts/regenerate-subagent-parity.sh <read-only-0.59.0-package> <private-evidence-dir>`
from this Gateway directory under the bounded command runner. It creates and removes
its own detached `1dc07c210` pre-cutover worktree, installs that revision's SDK and the
OLD package's exact dependencies, copies the shared driver unchanged, loads OLD as a
user package (no managed admission), and writes the baseline plus `parity-old.json`.
Then run `TRON_PARITY_REPORT=<private-evidence-dir>/parity-report.json npx vitest run
src/sessions/subagent-parity.integration.test.ts --maxWorkers=2` under the same runner
and isolated environment. A normal focused test run also compares NEW to the committed
baseline without requiring the OLD installation or a second worktree.
Oversized modern documents retain the existing compact lifecycle fallback; detailed
native coverage therefore remains bounded and may be reduced on overflow, explicitly
marked by `lifecycleOmissions.byteLimitExceeded=true`. Header-less
artifacts retain the bounded document reader. A foreign session
header is an ownership mismatch even when run, tool-call, and artifact path match; it
cannot update children or settle/receipt the activity. Headers without `sessionId`
remain subject to the existing exact run/tool/path ownership proof. A malformed,
truncated, mismatched, or schema-invalid modern header fails closed rather than
fabricating a child or terminal state. Producer
`partial` is adapted to the existing native `failed` state with `needsAttention`; no new
native lifecycle value is required. Header root and child activity/timing, bounded omission
counts, allowlisted host-step metadata, paused process-terminal proof, and exact child session
evidence are then attached to the existing Gateway-owned terminal/ownership latches. `SessionProcessOverview.extensionChildOmissions`
distinguishes producer child omissions from Gateway row-cap omissions; it is an additive
bounded diagnostic and does not promise unlimited native rows.

Absolute session and
artifact paths, PIDs, environment values, and unbounded task/output data never cross
the wire. Bounded delegated-output previews conservatively mask environment assignments,
headers/cookies, long and short credential flags, JSON/query keys, URL userinfo, PEM
blocks, recognizable provider tokens, JWTs, and high-entropy bearer-like strings without
modifying canonical JSONL. `SessionProcessOverview` is the shallow composer authority:
active/recent/problem counts, revision, Gateway `asOf`, and nearest expiry. High-frequency
output remains in bounded process deltas and does not require a transcript rebuild. Optional
resolved model and thinking metadata is copied only from bounded fields already present in
the canonical producer status. Automatic steering recovery emits a management receipt,
not a second launcher result. The exact installed provider's recovered receipt binds its
source and replacement IDs to the original canonical launch in the same parent session;
a stable recovery identity owns the replacement's artifact. Its first admitted artifact
supplies the start time when no launcher row exists. A matching recovered artifact claim,
with the original paused runner's observed terminal proof and pre-handoff timestamps,
settles the superseded execution as stopped—not successful work—while leaving the producer's
resumable history unchanged. The replacement remains independently active until its own
terminal evidence arrives. Foreign owners, conflicting claims, missing process proof,
and currently running sources never authorize this settlement. Late original artifacts
cannot resurrect an already retired execution. The upstream producer does not publish durable completed-tool identity, so
Gateway and iOS intentionally show only the authoritative current tool and bounded output;
they do not invent or cache a last-tool record.


The Gateway owns process recency for exactly five minutes from authoritative terminal
admission. It converts that wall deadline to a monotonic in-process timer, emits a
revisioned expiry snapshot even when no other session event occurs, and reconstructs
recent subagents from their canonical receipts after runtime acquisition. Existing 15-minute extension
compatibility fields do not extend the process deadline. Active work always outranks
recent terminal work. Expiry removes only the disposable projection while retaining a
bounded terminal tombstone so late advisory artifacts cannot resurrect the same process.
Process replacement deltas carry exact removed process IDs, including removal-only frames.
A native sheet may follow a temporary aggregate only when exactly one admitted successor has
the same immutable tool-call and root-run correlation; ambiguous replacements fail closed.

A paused subagent row is presented as settled only after the Gateway has observed that
exact-owned `processTerminal` proof. The proof publishes `state: paused` with its
observation instant as `lifecycle.terminalAt`, a `recentUntil` five minutes later, and
`visibility: recent`, so the row is ordered, frozen, and retired exactly like finished work:
`durationMs` stops sampling the producer's still-counting elapsed time, no abort route is
offered, no restart drain is held, and the session carries no dashboard subagent activity.
A paused run without that proof owns live work: it keeps `visibility: active` and no
terminal timestamp, so iOS presents it as still pausing. A resume is a new run ID and
appears as its own active row while the settled paused row keeps the facts it published.

A run the Gateway watched finish takes its own observation instant as `terminalAt`. A run
it first reads already terminal, after a restart or slot reload, takes the producer's
recorded end instead (falling back to the observation when that end is missing, malformed
or in the future). Otherwise every old run in a reopened session would return as recent,
with a duration counted from its start to now.

`session.processHistory.list` and `.get` page only normalized subagent terminal receipts
under one bounded branch-derived revision and opaque cursor. Pagination stops before a row that exhausts the current page's byte
remainder so that row remains reachable at the next cursor; only a row that cannot fit
an empty page is omitted and reported in omission count/bytes. Cursors conflict when the
canonical generation changes. Old `tron.extension-activity.v1` entries remain readable by
extension history;
process history admits individual historical children only when the receipt records their
exact producer ID and a known synchronous or asynchronous execution mode. Supervisor/control
receipts and unknown modes fail closed rather than authoring invalid process DTOs. Canonical
receipts retain the exact child producer, optional fresh-session owner, and validated opaque
child-session ID so historical transcript authorization does not depend on an unbounded runtime
cache; they continue to omit paths, task text, and output.

The companion `process-history.v1` capability advertises canonical history reads.
The `process-transcript.v2` capability authorizes `session.processTranscript.open`,
`.page`, and `.close` through the exact parent process-to-child relationship. The separate
`process-transcript-abort.v1` capability authorizes only
`session.processTranscript.abort`: the Gateway requires the caller's exact live lease,
serializes with that lease's reads, revalidates parent/process/run, path, and file identity,
then routes stop through an idempotent command receipt. Synchronous children use the
parent session's ordinary settled agent abort, matching the composer stop control; asynchronous
children use only the exact installed subagent controller owner with the exact root run and exact
child producer. Authority follows the installed opaque owner identity rather than Pi's mutable
package source label. The open response sets `canAbort` only when that route exists; synchronous leases
also capture the exact foreground operation ID, so a stale lease cannot abort newer parent work.
It exposes no generic child mutation or writable transcript authority. A
connection-owned lease watches only the validated canonical child file, installs that
watch before capturing its initial page, latches any append in the baseline-publication
window, emits bounded invalidation events, and reopens it through a read-only projection
for canonical paging. In-flight opens reserve the same per-client and per-parent capacity
as established leases. Page and invalidation/live-refresh requests serialize per lease and
recheck the client's expected revision inside that lane, so an older observer read or a
canceled mobile prepend cannot race a refresh and advance the same lease generation out of order.
Open, page, and invalidation reads each revalidate the exact live parent process/tool/run
binding, exact reserved child path, header identity, and original file identity. Ownership admission
reads only the immutable bounded header, so an in-progress tail append cannot masquerade as an
identity replacement. Page projection pins one newline-complete prefix from the already-open inode;
a later canonical append advances the lease through its watcher rather than invalidating that prefix.
Fresh children are
admitted only at `<parent-stem>/<session-owner>/run-N/session.jsonl`, with exactly three relative
path components. The session owner is separately proven as either the exact root run (ordinary
single/parallel/chain, including the status-matched private recovery descriptor for a detached single
run) or an exact artifact child `runId` (detached workflow child); it is never inferred from the path
or process producer. Fork-context children are admitted only at
`<parent-stem>/forks/<fork-session>.jsonl` when their header resolves to the mounted parent. In
both layouts the process producer comes only from the trusted lifecycle identity contract, never
a filename, name, title, or generic extension array position. Fresh children may omit the parent
header because exact tool/run ownership plus the separately validated session-owner path remain
authoritative. Session names and `session_info` never participate in admission. Replacement
or ambiguity closes/fails the lease. Transcript projection
parses the already-open, identity-pinned descriptor through a pure read-only branch adapter
under an explicit 64 MiB per-session parse budget. The adapter follows the selected leaf to
its root, rejects missing parents and ancestry cycles, and preserves the header identity and
selected branch order; a replace/read/swap-back race cannot redirect parsing to another inode
and a legitimate but unbounded child file cannot exhaust Gateway memory.
Read-only open/page/refresh never call `RuntimeRegistry.acquire` for the child and the
lease keeps no second transcript mirror. Only the separately advertised exact-lease abort
may reacquire the already-owned parent runtime, and only to invoke its existing settled
foreground abort or trusted subagent stop control. Producer admission requires the exact owning tool/run,
a unique child identity, and a regular session file structurally nested beneath the
canonical parent session's child root; persisted reopening repeats the parent/process/run,
producer-token, and catalog checks. Reads reject missing ownership, symlinks, oversized headers,
identity/path replacement, foreign or ambiguous catalog identities, incomplete trailing
JSONL appends, stale page anchors, and retired leases. Leases are bounded per connection
and per parent session. Closing the parent presentation or client retires every owned
child observer. Pending viewers carry the same retirement signal through shared parent/catalog waits. Canceling an observer abandons its wait without canceling the independently bounded canonical owner; capacity remains held until any viewer-owned physical read settles. Reads check retirement between bounded chunks and before publication. A live child reference is projected only when its producer/session-owner binding is unambiguous; the exact process ID stays stable as binding availability changes.

## Extension activity lifecycle and history

Structured extension runs retain the legacy coarse `status` alongside the additive
versioned lifecycle record (`queued`, `running`, `paused`, `completed`, `failed`,
`stopped`, `rejected`, or `unknown`). Gateway projection sequence and terminal
latches own ordering; producer timestamps are display evidence only. Terminal
activities receive Gateway-owned `terminalAt`/`recentUntil` facts and are recent for
exactly 15 minutes. Active lifecycle rows use `visibility: current` without a terminal
`remainingMs`; only recent/historical terminal rows carry that countdown. A single coalesced expiry deadline republishes
visibility; history is not deleted at expiry. Live artifact heartbeats publish one
`session.extensionActivity` delta with the exact activity and live revision; they do
not rebuild or broadcast the full transcript snapshot. Reconnect/open snapshots remain
authoritative baselines, and terminal/expiry transitions converge through the same
revisioned activity facts.

The `extension-activity-history.v1` capability exposes
`session.extensionActivity.list` and `.get`. Terminal facts are written as
reserved `tron.extension-activity.v1` Pi custom entries through the session
mutation lane. Receipts are bounded, exactly-once by activity identity, and retain
only child identity, label, lifecycle/attention, and aggregate tool/turn counts;
child task, output, path, current-tool, and timing fields never persist. They
remain in raw JSONL/export but are excluded from transcript, tree, and model projection. History cursors
carry an immutable receipt/branch revision and reject generation mixing. Receipt
admission rejects cyclic child ancestry before reconstructing historical trees.
Pages cap the activity array at 256 KiB and scan at most 50 rows: a row that
exhausts the current page remains at the next cursor, while an individually
oversized row advances the cursor with explicit omission metadata. Paging never
drops an otherwise admissible row merely because an earlier row filled the page.

Artifact discovery is bounded, validates the supported versioned lifecycle
artifact shape, and prioritizes queued/running and unsettled paused runs, then newest
observations before routing them. One Gateway registry owns discovery and the watcher
lifecycle; RuntimeSlot remains the authority for exact session/tool ownership.
Per-slot watchers are therefore permitted only after that exact ownership has
already been proven, and never perform global scans. Pure artifact state and timestamp
normalization is shared by discovery and watcher refresh, while their admission,
ownership, receipt, and fail-closed policies remain slot-owned. A producer's logical
`endedAt` may precede the final persistence `lastUpdate`; admission requires the complete
`startedAt <= endedAt <= lastUpdate` timeline (including the legacy `completedAt` alias),
and keeps `updatedAt` bound to persistence while `completedAt` remains logical completion.
Exact-owned rejection is observable through rate-limited, hard-bounded reason codes
(`invalid-timestamp`, `missing-terminal-time`, `ownership-mismatch`,
`malformed-artifact`, or `artifact-replacement-in-progress`) keyed only by opaque hashes.
Unowned ambient junk is silent, and warnings never include artifact paths or content.
Oversized status files
remain outside the projection byte cap; an exact-owned run may recover only its bounded
top-level lifecycle header when a matching terminal record is also present in the bounded
`events.jsonl` tail, without parsing or projecting oversized step data. Administrative
drain also refreshes exact-owned artifacts directly on a bounded interval, so terminal
work does not depend on watcher delivery or ambient scan scheduling. Atomic status replacement receives bounded retries; if an exact-owned nonterminal status or run directory remains absent for 30 seconds, Gateway changes that disposable lifecycle to `unknown`, removes its active process row, and releases drain/activity claims rather than projecting a zombie forever. Reappearance of the same exact-owned artifact may publish newer evidence. Shared recency scheduling
removes only the disposable ambient projection at its wall-clock deadline,
while canonical history remains available. Detached nonterminal work protects
its session lane from idle eviction and administrative drain.
