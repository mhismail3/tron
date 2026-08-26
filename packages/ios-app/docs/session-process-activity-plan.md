# Session Process Activity Redesign Plan

Status: Implemented; focused Gateway/iOS validation and physical-device deployment passed.
End-to-end live process lifecycle acceptance requires the updated Gateway payload to be
installed through the maintainer-owned Mac update runbook.

## Objective

Replace the per-extension activity pills and Extension Activity hub with one
session-level process affordance that truthfully presents process activity the
Gateway already observes:

- assistant `bash` tool invocations;
- synchronous and asynchronous subagents; and
- any existing process-producing extension lifecycle that provides the same
  typed ownership and lifecycle evidence.

The redesign must not add another command executor, detached-command tool,
process supervisor, event journal, history database, or iOS history mirror. It
is an observation and presentation redesign, not a new execution system.

The result should provide:

- one process button that emerges from the input bar's leading edge;
- an animated solving orb while any admitted process is active;
- an animated thinking/breathing orb while only terminal work from the last
  five minutes remains;
- a current/recent process sheet from the composer;
- canonical paginated Process History from Manage Session;
- command rows with bounded live output;
- tappable subagent rows that open a full read-only canonical-live session
  sheet; and
- no ambient extension status, widget, or service dashboard.

This plan supersedes the product direction in
`extension-activity-hub-plan.md` once implemented. The existing plan remains a
description of the currently shipped architecture until the cutover is
complete; it should then be removed rather than retained as a legacy ledger.

## Settled product contract

### Included process sources

| Source | Included | Authority |
| --- | --- | --- |
| Assistant `bash` tool call | Yes | Pi tool declaration, Gateway tool execution lifecycle, canonical tool result |
| Synchronous subagent | Yes | Exact owning tool call plus admitted structured subagent lifecycle |
| Asynchronous subagent | Yes | Exact owning tool call plus admitted async lifecycle artifact |
| Existing extension-owned process with typed lifecycle | Yes, when it satisfies the same ownership contract | Exact tool/run ownership and admitted structured lifecycle |
| Shell-launched detached grandchild such as `nohup x &` | No independent row unless an existing producer reports it | The encompassing `bash` call only |
| User `!` bash command | No | Separate direct-bash transcript/runtime path |
| Terminal-sheet PTY | No | `TerminalService` |
| Read, edit, web, and other ordinary tools | No | Ordinary tool/transcript presentation |
| Gateway administrative work | No | Administrative runtime services |

“Existing process” means a process invocation with authoritative lifecycle
facts already emitted by the owning tool or extension. Tron must not infer a
background process from command text, shell syntax, PIDs, output strings,
filesystem artifacts without exact ownership, or OS process enumeration.

If an assistant runs `nohup server &` in the current `bash` tool, the process
sheet may show that `bash` invocation until its tool lifecycle ends. It must not
claim that the detached child remains running afterward. A future producer may
join the process projection by implementing the typed producer contract; that
future integration does not require a new iOS model or composer design.

### Visibility

A process is **active** when its admitted lifecycle is queued, running, paused,
or otherwise nonterminal and attention-requiring.

A process is **recent** when it is terminal and:

```text
terminalAt + 300_000 ms > authoritative Gateway time
```

At exactly `terminalAt + 300_000 ms`, it becomes historical and no longer keeps
the composer button visible. Failed, stopped, rejected, and interrupted work
uses the same five-minute window. Active always outranks recent for aggregate
orb state.

The five-minute partition controls ambient visibility only. It never deletes
canonical history.

### Entry points

The composer button sheet contains only:

1. Active
2. Recently finished, at most five minutes old

Manage Session owns one **Process History** row. Its sheet contains:

1. Current and recent activity from the mounted live authority
2. Earlier canonical activity loaded through bounded Gateway pagination

Both entry points reuse the same process row, process detail, and subagent
viewer implementations.

### Observation-only milestone

The iOS surfaces expose no Stop, Kill, Retry, Resume, or process-input actions.
Existing tools and extension producers retain their existing control semantics.
The process redesign neither removes nor expands those controls.

### Subagent session liveness

The first implementation is canonical-live:

- completed canonical messages and tool entries appear after their JSONL append;
- current structured tool/output activity remains live between appends;
- the viewer updates while it is open; and
- token-by-token assistant text is out of scope because it is not canonical in
  the child session file and has no existing typed producer stream.

The viewer is fully read-only. It must not acquire a second writable runtime for
the child session.

### Extension content retirement

Remove ambient extension statuses, read-only widgets, service activity, the
per-extension composer pills, the integrated extension hub, and Extension
Activity history from user-facing process presentation.

Retain:

- native interactive extension prompts and editors;
- extension transport required by those prompts;
- process-producing extension instrumentation; and
- technical package/source names where appropriate in source and dependency
  documentation.

User-facing UI must say **Subagent**, an agent label, **Processes**, or
**Process History**, never “Pi Subagents.”

## Current architecture audit

### Reusable foundations

- `RuntimeSlot` already owns live tool execution state and exact per-session
  mutation serialization.
- Assistant tool calls have stable `toolCallId` identity, bounded rolling
  output, progress sequencing, and canonical tool results.
- Structured subagent runs already project sync/async lifecycle, bounded child
  rows, output, ownership bindings, terminal latches, and canonical terminal
  receipts.
- The Gateway already validates extension artifact paths and constrains artifact
  reads.
- Extension recency already has a Gateway-owned coalesced expiry mechanism,
  though it currently uses 15 minutes and extension-specific models.
- Extension history already demonstrates canonical JSONL-backed pagination
  without a second database.
- `SessionPresentationStore` already admits revisioned session deltas and
  performs exact-generation replacement/resynchronization.
- The current history sheet already demonstrates the correct composition of a
  mounted current/recent section with paginated earlier activity.
- Composer geometry, transcript viewport ownership, and morph infrastructure
  are centralized and should be reused.
- Historical pre-Gateway `AuditSessionSheet` demonstrates the desired full
  read-only transcript presentation concept, but its old runtime ownership
  model must not be restored.

### Gaps to close

1. There is no package-agnostic process contract.
2. Current pills group per extension rather than per session.
3. Assistant shell tool executions disappear from the live overlay when their
   canonical result arrives; there is no five-minute shell recency projection.
4. Current extension/subagent recency is 15 minutes.
5. Process history does not merge canonical assistant shell calls and subagent
   receipts into one ordered source.
6. Existing subagent child models do not carry a validated opaque child-session
   identity.
7. Historical subagent rows therefore cannot open their canonical session.
8. The current child transcript view is a simplified recursive activity viewer,
   not a full paged canonical transcript.
9. The composer observes high-frequency extension group content instead of a
   shallow aggregate state.
10. The current hub mixes statuses, widgets, services, and delegated runs even
    though only the latter belong in process history.
11. User-facing “Pi Subagents” naming conflicts with Tron product ownership.
12. The current source policy includes a pre-existing contradictory periodic
    timeline assertion; it should be corrected by its owning test change if it
    blocks focused validation, not worked around in production code.

## Architecture principles

### Canonical truth remains canonical

| Layer | Owner | Contents | Lifetime |
| --- | --- | --- | --- |
| Pi session JSONL | Pi `SessionManager` | Assistant tool calls/results and normalized terminal subagent receipts | Canonical session lifetime |
| Subagent lifecycle artifacts | Existing producer | Current structured run state and progress | Producer-defined |
| Runtime process overlay | `RuntimeSlot` process projection | Active/recent command and subagent summaries | Disposable and bounded |
| Historical process query | Gateway | Page derived from canonical JSONL plus separately tagged mounted live state | Request-only |
| iOS process state | Mounted session presentation | Current/recent projection and loaded page generation | Disposable |
| Child transcript observer | Gateway read-only lease | Canonical child pages plus invalidation state | While viewer is open |

Do not add SQLite, a sidecar session index, a second JSONL journal, or durable iOS
process history.

### Projection, not execution

The Gateway gains adapters that observe existing producers. It does not gain a
new command tool, executor, PTY, supervisor, process group, or restart-survival
contract.

### Exact ownership before admission

A process row is admitted only when the Gateway can bind it to the exact current
session and canonical tool/run identity. Labels, command text, titles,
timestamps, output, async directory names, and package names are not ownership
keys.

### Shallow ambient state

The composer observes a small `ProcessOverview`, not command output, child
trees, or history pages. Output updates may refresh an open process sheet without
causing composer-wide state churn or animation retargeting.

## Process protocol contract

Introduce package-agnostic versioned DTOs. Names below are illustrative but the
separation is required.

### `SessionProcessActivity`

```text
version
processId                 stable namespaced presentation identity
kind                      command | subagent
executionMode             foreground | background | synchronous | asynchronous | unknown
parentProcessId?          grouping only; never identity
source                    mainAssistant | delegatedAgent | admittedExtension
lifecycle                 versioned state/attention/sequence facts
startedAt?
terminalAt?
recentUntil?
title                     bounded display label
command?                   bounded command preview
currentTool?               bounded tool label
currentPathBasename?       basename only
outputTail?                bounded live/recent output
outputTruncated
counts?                    bounded tool/turn/child facts
toolCallId?                exact canonical correlation
runId?                     producer correlation, not route identity
childSessionRef?           opaque validated reference
visibility                 active | recent | historical
```

Use one deterministic `processId` derived from canonical session identity,
process kind, and exact owning tool call/child run identity. Synthetic artifact
IDs remain internal until exact ownership is known. Artifact enrichment must not
re-key an installed native row.

`executionMode` is producer-authored. The Gateway must not convert shell syntax
into foreground/background classification. Main assistant `bash` calls are
foreground for this contract. Existing structured subagent runs retain their
sync/async truth.

### Lifecycle

```text
state:
  queued | running | paused |
  completed | failed | stopped | rejected | interrupted | unknown

attention:
  none | activeLongRunning | needsAttention

sequence                    Gateway monotonic process sequence
observedAt                  Gateway admission time
producerUpdatedAt?          display evidence only
terminalAt?                 authoritative terminal-admission time
recentUntil?                terminalAt + 300_000 ms
```

Terminal state is latched. Advisory producer updates cannot resurrect a terminal
row. Equal or older sequences cannot replace newer accepted state. Producer wall
clock is display evidence; Gateway sequence and admission clocks own ordering.

### `SessionProcessOverview`

```text
version
revision
asOf
activeCount
recentCount
problemCount
nearestExpiry?
visibility                  hidden | active | recent
omissions?
```

The overview is server-authored from the same admitted process set. The composer
must not derive its button state by repeatedly traversing process rows.

### Bounds

Initial limits should reuse existing tool and extension bounds where practical:

- maximum 32 current/recent process rows in a snapshot;
- current work admitted before recent terminal work when bounded;
- explicit omitted-count and encoded-byte metadata;
- UTF-8-safe command/title/output truncation;
- existing extension child depth/count limits;
- history default 25 rows, hard maximum 50, plus encoded response cap; and
- no unbounded JSON or recursively admitted producer payload.

## Gateway live projection

### Assistant command adapter

Observe only assistant-owned Pi tool execution events for the canonical `bash`
tool.

On tool start:

- establish `processId` from session ID plus exact `toolCallId`;
- capture the bounded canonical command declaration;
- assign the Gateway process sequence and start monotonic anchor; and
- publish a command process delta and overview delta.

On tool progress:

- admit cumulative output using existing progress sequence rules;
- retain a bounded suffix with explicit truncation;
- update an open process sheet; and
- avoid republishing the full transcript or structurally changing the composer.

On tool end/canonical result:

- latch the terminal result;
- use the canonical result entry timestamp as historical terminal evidence;
- retain a disposable recent row until the five-minute deadline;
- reconcile the output with the canonical tool result projection; and
- remove the high-frequency live execution overlay without removing process
  recency.

Direct user bash and Terminal PTY paths must not call this adapter. Filtering by
rendered tool title or transcript `kind == bash` is insufficient; admission must
come from the assistant tool execution owner.

### Subagent adapter

Refactor extension-specific run projection behind a process-producer adapter:

- preserve exact tool call, run, async artifact, and terminal receipt ownership;
- map sync/async mode without collapsing it to foreground command semantics;
- project each executable child as a subagent process row;
- retain workflow/container relationships as `parentProcessId` or grouping
  metadata rather than inventing sessions for non-executable containers;
- preserve current tool, basename-only path, bounded output, counts, state, and
  attention;
- keep terminal precedence and duplicate-run suppression; and
- publish the same `SessionProcessActivity` contract as command rows.

Do not delete the semantic extension host. Only remove ambient extension content
from the process UI.

### Existing generic process producers

Define a private Gateway adapter interface for any existing tool/extension that
already supplies:

- exact session/tool ownership;
- stable producer run identity;
- typed lifecycle and monotonic replacement evidence;
- bounded display/output data; and
- authoritative terminal evidence.

No current producer should be broadened by parsing logs or spawning processes.
Adding another adapter is a separate production-backed change.

### Five-minute recency

Generalize or replace the extension-specific recency scheduler with one process
recency owner using `300_000` ms.

- Record wall and monotonic anchors at terminal admission.
- Schedule one coalesced timer for the nearest expiry.
- At expiry, increment process revision and publish the new process overview and
  current/recent projection even if no other session event occurs.
- Reconstruct recent assistant commands from the canonical transcript when a
  runtime is acquired or the Gateway restarts.
- Reconstruct recent subagents from terminal receipts.
- Derive five-minute visibility from `terminalAt`; ignore historical 15-minute
  `recentUntil` values in old extension receipts.
- Clamp malformed or implausible timestamps and classify unavailable truth as
  historical/unknown rather than active.

An iOS timer may make a stale mounted button disappear at the supplied deadline,
but it must never extend visibility beyond the Gateway deadline or fabricate a
new process state. Reconnect always installs authoritative Gateway state.

### Event and snapshot behavior

Add process activity as a revisioned session projection:

- snapshots include `processOverview` and bounded current/recent
  `processActivities`;
- `session.processActivity` upserts one exact process by ID and sequence;
- `session.processOverview` replaces the shallow aggregate revision;
- overview/activity revision mismatch triggers bounded resynchronization;
- output-only updates do not replace transcript pages;
- runtime generation and subscription cursor rules remain unchanged; and
- malformed known process frames fail closed to authoritative catch-up.

Do not route process updates through extension widget presentation or infer them
from SwiftUI-visible tool rows.

## Canonical Process History

### Command history

Assistant command history is derived from canonical Pi JSONL:

- identify assistant `bash` tool declarations on the selected canonical branch;
- join each declaration to its canonical result by `toolCallId`;
- use canonical entry order and result timestamp;
- reuse existing bounded command/output projection and blob/truncation policy;
- include incomplete/interrupted truth only when canonical evidence supports it;
- deduplicate against the mounted active/recent overlay by `processId`; and
- do not write a duplicate custom receipt for ordinary synchronous `bash`.

### Subagent history

Continue using normalized terminal custom receipts because asynchronous subagent
completion may occur after the launching tool has returned and artifacts are
disposable.

Evolve the receipt schema to include:

- stable process/activity ID;
- exact parent session and owning tool-call identity;
- run identity and sync/async mode;
- terminal lifecycle and bounded counts;
- bounded agent/child display label; and
- validated opaque child session ID when available.

Receipts continue omitting raw task text, recent output, absolute paths, async
directories, environment, PIDs, credentials, and other live-only payload.
Historical transcript content belongs to the validated child session itself.

Old `tron.extension-activity.v1` receipts are normalized at read time. Do not
rewrite canonical sessions merely to migrate presentation. Old rows without a
validated child session reference remain visible but non-openable with truthful
copy.

### History API

Advertise a process-history capability and provide bounded read-only methods,
for example:

```text
session.processHistory.list(sessionId, cursor?, limit?, filter?)
session.processHistory.get(sessionId, processId)
```

Responses must:

- merge command and subagent canonical sources in reverse chronological order;
- use a history revision derived only from canonical branch/receipt changes;
- keep mutable live output and recency on a separate live revision;
- return stable opaque cursors and explicit next cursor;
- reject mixed-generation pagination with retryable conflict;
- obey count and encoded-byte caps;
- include explicit omission/truncation facts; and
- never expose child file paths.

The first UI page may compose mounted current/recent state above canonical pages,
but current/recent rows are not part of the canonical history cursor.

## Child subagent session identity

### Admission

`sessionFile` may be accepted only from exact admitted subagent producer
evidence. The Gateway must:

1. canonicalize and realpath the file;
2. enforce an allowlisted session root;
3. reject symlinks, non-regular files, replacement races, and oversized headers;
4. parse the canonical session header;
5. verify the child session ID and structural subagent classification;
6. verify the exact owning parent/tool/run relationship using producer ownership
   and header/catalog evidence;
7. retain only an opaque child-session reference in protocol and receipts; and
8. fail closed on ambiguity.

A run ID or `subagent:<runId>` identity is not a child session identity.

Before identity is validated, the process row remains visible and its viewer
action is disabled with **Session preparing**. A terminal row whose session was
never persisted remains visible with **Session unavailable**.

### Read-only observer

Add a parent-authorized child transcript lease rather than calling
`RuntimeRegistry.acquire`:

```text
session.processTranscript.open(parentSessionId, processId)
session.processTranscript.page(leaseId, before?, expectedNextEntryId?)
session.processTranscript.close(leaseId)
session.processTranscript.changed(leaseId, revision)   // event/invalidation
```

The observer must:

- authorize through the parent process-to-child relationship on every lease;
- expose no mutation methods;
- never create a child `RuntimeSlot`;
- open the public session parser as `ReadonlySessionManager` or an equivalently
  narrowed immutable adapter;
- reuse canonical `projectTranscriptPage` and its byte/item/anchor bounds;
- watch only the exact admitted file while the lease is mounted;
- debounce appends and wait for complete newline-terminated JSONL records;
- invalidate and re-read rather than maintaining another canonical mirror;
- preserve branch, leaf, generation, and expected-next-entry safeguards;
- close on route dismissal, profile replacement, disconnect, or lease timeout;
  and
- cap leases per client/session.

Canonical transcript pages show completed messages and tool entries. The parent
process activity projection supplies the transient current tool/output panel
until corresponding canonical entries append. That transient panel must not be
inserted as a fake canonical transcript item.

## iOS state ownership

Introduce focused owners rather than placing clocks, paging, or file liveness in
SwiftUI views:

- `SessionProcessAdmissionPolicy` — strict DTO and semantic bounds;
- `SessionProcessProjection` — exact-ID merge, lifecycle priority, sections,
  deduplication, and stable ordering;
- `SessionProcessStore` — mounted overview/current/recent authority;
- `SessionProcessHistoryStore` — cancellation-owned canonical pagination;
- `ReadOnlySubagentSessionStore` — lease, page generation, invalidation, and
  transient live panel;
- `ProcessOrbPresentation` — shallow hidden/active/recent visual state; and
- one process route enum installed by the existing session presentation host.

`SessionPresentationStore` installs process activity only for the exact session,
runtime generation, connection epoch, revision, and activity sequence. Full
snapshots replace the overlay; stale deltas are ignored. Snapshot cache must not
become a five-minute or historical truth source.

The composer observes only `SessionProcessOverview`. An open process sheet may
observe bounded activity rows. History and child transcript stores exist only
while their route is mounted.

No old Extension Activity UI fallback should survive in the new app. If the
Gateway capability is unavailable, hide the composer process affordance and show
Process History as unavailable rather than reviving the retired hub.

## Native UI design

### Composer process button

Place one 44-point circular process control before `inputBar` in the existing
composer control `HStack`. Keep the trailing catch-up/scroll-to-bottom control
independent.

```text
[ process button? ] [ input bar ] [ catch-up button? ]
```

Use one typed state:

```text
hidden   no active or recent processes
active   at least one active process; solving orb
recent   no active process and at least one <=5-minute terminal process;
         breathing/thinking orb
```

Requirements:

- reuse the existing `GlassEffectContainer`, morph registry, and single composer
  geometry owner;
- visually emerge from and return to the input bar's leading edge;
- do not install a free-floating overlay or independent viewport geometry;
- appearance/disappearance issues no transcript scroll command;
- if pinned-tail composer geometry requires settlement, use only the existing
  nonanimated composer-owned path;
- latest target wins during rapid active/recent/hidden changes;
- stale expiry animation cannot hide a newly active process;
- simultaneous leading and trailing controls retain a usable input width at
  narrow sizes and large Dynamic Type; and
- button output/activity updates do not continuously retarget its structure.

Accessibility example:

```text
Label: “Processes”
Value: “2 active, 1 recently finished”
Hint: “Shows current and recent processes”
```

### Current/recent process sheet

Tapping the button opens one session-level sheet, not an extension hub.

Sections:

1. Active
2. Recently finished

Command row:

- command icon and bounded command preview;
- foreground state and duration;
- bounded monospaced live/recent output tail;
- explicit truncation/freshness where applicable; and
- no control buttons.

Subagent row:

- agent label and bounded task/title available from live projection;
- sync/async state;
- current tool/output summary;
- lifecycle and duration;
- disclosure only when an opaque child session route is available; and
- truthful preparing/unavailable state otherwise.

Use static scroll-optimized surfaces for potentially long output/list content.
Do not recreate extension overview cards, status sections, widgets, services, or
filters in this sheet.

### Manage Session

Rename the existing **Extension Activity** destination to **Process History**.
Use one row alongside other session-level destinations. Its value may report:

- `2 active · 3 recent`;
- `18 recorded processes`; or
- `History unavailable` when capability truth is absent.

The history sheet composes mounted current/recent sections with paginated Earlier
activity. It owns loading, empty, unavailable, reconnecting, conflict, Load More,
and exact-generation detail states.

### Full read-only subagent session

Build a dedicated read-only session presentation that reuses:

- transcript row renderers;
- tool/result views;
- paging controls and canonical anchors;
- generation-gated page preparation;
- compaction/custom-message presentation where legal; and
- the recent chat scroll architecture's single scroll owner.

Do not embed writable `ChatView`, install a composer, subscribe the child as the
main mounted session, or restore retired Engine/worker-audit runtime ownership.

The sheet includes:

- read-only navigation title using the agent label or **Subagent**;
- full canonical paged transcript;
- transient live activity panel for current tool/output;
- reconnecting/unavailable/completed states; and
- no prompt, queue, attachment, branch, compact, or mutation controls.

## Native orb implementation

Use the MIT-licensed geometry from
`https://github.com/Jakubantalik/thinking-orbs`.

- Source `solving`/Rubik mode represents active work.
- Source `breathing`/ring mode represents the requested Thinking state.
- Port deterministic point geometry and z-sorted circle projection.
- Render with one SwiftUI `Canvas` inside `TimelineView(.animation)`.
- Use a shared monotonic epoch so view reconstruction does not jump phase.
- Tint every dot with Tron emerald; preserve source depth through
  opacity/intensity rather than monochrome paint.
- Pause animation when offscreen or while the scene is inactive.
- Under Reduce Motion, render a deterministic static representative frame, such
  as source time `t = 0.6`.
- Keep display-cadence invalidation localized to the orb.
- Avoid WebView, JavaScript runtime, Metal, and one-layer-per-dot Core Animation.
- Package the upstream copyright and MIT license in third-party notices.
- Add numeric golden vectors for representative solving, breathing, and morph
  frames plus deterministic reduced-motion coverage.

The orb's animated image has no independent accessibility semantics; the button
owns the stable label/value/hint.

## Privacy and safety

Never project or instrument:

- absolute session/artifact/async paths;
- PIDs or process-group identifiers;
- environment values;
- credentials or command-derived secrets;
- raw owner source paths;
- unbounded task, command, or output text; or
- child session files not exactly authorized by the parent process relation.

Use basename-only path display. Instrumentation may record opaque IDs/hashes,
kind/state buckets, counts, revision tags, truncation flags, and routing outcomes.
It must not record task, command, output, prompt, or path text.

Interactive extension prompts remain governed by their existing input leases and
modal priority. Process sheets are read-only and cannot consume those leases.

## Migration and cleanup

### Wire and canonical compatibility

- Add process DTOs and capabilities additively.
- Continue decoding old extension terminal receipts for historical sessions.
- Derive the new five-minute deadline from terminal time rather than old stored
  15-minute `recentUntil`.
- Do not rewrite old sessions.
- Do not create a second iOS UI path for old Gateway extension hubs.
- Retain old protocol fields only for the supported rolling wire window; remove
  them when the minimum supported client contract permits.

### iOS removal targets

After process UI is operational:

- remove `ExtensionActivityPill`;
- remove the integrated extension hub and single-run bypass routing;
- replace `ExtensionActivityHistorySheet` with Process History;
- remove ambient status/widget/service presentation from composer and Manage
  Session;
- remove obsolete extension grouping/pill policies and tests;
- replace simplified recursive subagent chat with the canonical read-only
  viewer; and
- preserve interactive extension prompt/editor routes.

### Documentation

Update with implementation:

- `packages/gateway/README.md` — process authority, recency, canonical history,
  receipt evolution, transcript lease, privacy, and bounds;
- `packages/ios-app/docs/architecture.md` — mounted process state, composer
  ownership, read-only child transcript, and no-cache rules;
- `packages/ios-app/docs/events.md` — process deltas, overview expiry, history,
  transcript lease invalidation, and modal priority;
- `packages/ios-app/docs/development.md` — focused tests, orb license/fixtures,
  and physical-device scenarios; and
- delete `extension-activity-hub-plan.md` after its current behavior is fully
  replaced and canonical documentation owns the new truth.

## Implementation sequence

### Phase 1 — Contracts and fixtures

Gateway:

- define process activity, lifecycle, overview, history page/detail, child
  reference, and transcript lease contracts;
- add strict count/string/byte admission;
- add capabilities and shared protocol fixtures;
- specify deterministic process identity and old receipt normalization; and
- test exact five-minute boundaries with injected clocks.

No UI cutover occurs in this phase.

### Phase 2 — Existing command projection

- adapt assistant-owned `bash` tool start/progress/end to process activity;
- separate process recency from transient `toolExecutions` removal;
- reconstruct recent terminal commands from canonical JSONL;
- derive paginated command history from canonical declarations/results;
- publish shallow overview and activity deltas; and
- verify user bash, Terminal PTYs, and ordinary tools remain excluded.

### Phase 3 — Subagent process projection

- adapt structured extension runs and children into package-agnostic process
  rows;
- change recency from 15 to five minutes in the new projection;
- preserve terminal latches, exact async ownership, and eviction/drain behavior
  already required by existing async subagents;
- evolve terminal receipts with validated opaque child-session IDs;
- normalize old receipts for history; and
- keep interactive semantic extension transport intact.

### Phase 4 — Process history and child observer

- implement merged command/subagent pagination and detail;
- add stable history revisions/cursors and retryable conflicts;
- validate child session identity and parent authorization;
- implement bounded read-only transcript leases and invalidation;
- reuse `ReadonlySessionManager`/canonical page projection without creating a
  runtime; and
- test concurrent append, partial line, replacement, symlink, and cleanup cases.

### Phase 5 — iOS stores and sheets

- add strict process model admission;
- implement mounted process store and shallow overview state;
- implement cancellation-owned history store;
- implement current/recent and Process History sheets;
- implement read-only child session store/sheet with canonical paging; and
- install exact-generation process routes without changing the composer yet.

### Phase 6 — Orb and composer cutover

- port and license the orb geometry;
- add golden-vector, Reduce Motion, lifecycle, and performance tests;
- insert the leading process control through existing composer morph ownership;
- verify coexistence with the trailing catch-up button;
- remove per-extension pills and hub routing; and
- rename Manage Session to Process History.

### Phase 7 — Retirement, documentation, and validation

- remove dead ambient extension status/widget/service UI and policies;
- remove “Pi Subagents” user-facing text;
- update owning Gateway/iOS documentation and source guards;
- run focused unit/contract/hosted tests;
- run Gateway build and generic iOS build-for-testing;
- run personal-info guard, source policy, and diff check; and
- deploy to the connected physical device for acceptance scenarios.

## Focused validation matrix

### Gateway

- assistant `bash` start, cumulative progress, end, and canonical settlement;
- exact exclusion of direct user bash, Terminal PTYs, and ordinary tools;
- command process identity stable across live-to-canonical handoff;
- command recency at `4:59.999`, exactly `5:00.000`, and later;
- active process remains visible regardless of age;
- main-agent settlement does not prematurely settle a still-running tool;
- several simultaneous commands/subagents with deterministic ordering;
- subagent sync/async modes and parent/child grouping;
- terminal state cannot be resurrected by late artifact updates;
- Gateway restart reconstructs recent commands and receipt-backed subagents;
- old 15-minute receipts use the new derived five-minute classification;
- canonical history merge, deduplication, cursor conflict, and byte bounds;
- no duplicate receipts for ordinary command tool results;
- child session path/root/header/parent/run validation;
- symlink, replacement race, foreign session, and ambiguous run rejection;
- child JSONL partial writes and canonical append invalidation;
- transcript lease disconnect/timeout cleanup; and
- snapshots/events remain inside production wire limits.

### iOS model and store

- strict DTO bounds and malformed optional-row omission;
- malformed overview/revision authority triggers resynchronization;
- exact process sequence replacement and terminal latch;
- active/recent/hidden overview priority;
- local deadline cannot extend server visibility;
- reconnect and runtime-generation replacement;
- snapshot cache cannot create recent/history truth;
- history request cancellation and exact-generation page admission;
- transcript lease cancellation and stale invalidation rejection; and
- unavailable child session route states.

### iOS presentation

- one process button for one or many process producers;
- solving orb whenever any process is active;
- breathing orb only when all visible processes are recent;
- exact expiry morphs away without a transcript scroll command;
- process and catch-up buttons coexist at narrow widths and large Dynamic Type;
- high-frequency output does not structurally animate the composer;
- current/recent sheet contains no ambient extension sections;
- Process History paging/loading/conflict/reconnect states;
- command output typography and truncation;
- subagent route opens full canonical transcript;
- child viewer has no composer or mutation controls;
- VoiceOver labels, values, headings, and unavailable states;
- Reduce Motion static orb and opacity-only structural transitions; and
- no user-facing “Pi Subagents” text.

## Physical-device acceptance scenarios

1. Start one assistant shell tool: one leading solving-orb button appears without
   moving a detached transcript reader.
2. Stream shell output: the open process row updates while composer geometry and
   transcript anchoring remain stable.
3. Complete the shell tool: the button transitions to breathing and remains for
   five minutes.
4. Cross the exact five-minute boundary with no other event: the button morphs
   away; Process History retains the command.
5. Start synchronous and asynchronous subagents together: one session-level
   button remains mounted and both rows preserve their modes and identities.
6. Let the launching async subagent tool settle while the child remains active:
   the solving state remains until authoritative child termination.
7. Fail one child while another remains active: aggregate remains solving, with
   truthful per-row failure.
8. Finish all children: aggregate changes to breathing, then disappears at the
   common nearest expiry progression.
9. Open an active subagent: canonical messages append live and current
   tool/output remains visible between appends.
10. Open a completed historical subagent after Gateway restart: the validated
    opaque child reference opens the read-only canonical transcript.
11. Open an old receipt without child identity: history remains truthful and the
    viewer action reports unavailable rather than guessing.
12. Run `nohup x &` inside ordinary assistant bash: Tron shows the bash invocation
    only and does not fabricate a continuing detached process after tool end.
13. Background/foreground the app and reconnect across completion/expiry: no
    duplicate process, stale running resurrection, or extended recency.
14. Show process and catch-up controls simultaneously under large Dynamic Type,
    VoiceOver, and Reduce Motion.

## Acceptance checklist

- [ ] No new command/process execution tool or supervisor is introduced.
- [ ] Only authoritative existing producers create process rows.
- [ ] Assistant `bash` calls and sync/async subagents share one typed process
      projection.
- [ ] User bash, Terminal PTYs, ordinary tools, and administrative work remain
      excluded.
- [ ] Shell syntax and OS processes are never used to infer detached lifecycle.
- [ ] One session-level composer button replaces every extension-specific pill.
- [ ] Active uses the solving orb; recent-only uses the breathing/thinking orb.
- [ ] Gateway owns the exact five-minute boundary and publishes expiry without
      another session event.
- [ ] Composer observation is shallow and output updates do not cause structural
      animation.
- [ ] The current/recent sheet contains process rows only.
- [ ] Manage Session owns one Process History destination with bounded canonical
      pagination.
- [ ] Command history derives from canonical tool call/result data without
      duplicate receipts.
- [ ] Subagent terminal truth remains receipt-backed where required.
- [ ] Child session paths never reach iOS or canonical receipts.
- [ ] Full subagent sessions open through a parent-authorized read-only observer,
      never another runtime.
- [ ] Canonical-live behavior is explicit; token streaming remains out of scope.
- [ ] Ambient extension statuses, widgets, and service sections are retired
      without breaking interactive extension prompts.
- [ ] User-facing “Pi Subagents” naming is removed.
- [ ] Orb source geometry is licensed, tested, Reduce Motion compliant, and
      emerald-tinted.
- [ ] No Gateway/iOS history mirror, second journal, or sidecar is added.
- [ ] Focused Gateway and iOS tests pass.
- [ ] Gateway build and generic iOS build-for-testing pass.
- [ ] Physical-device scenarios pass.
- [ ] `git diff --check`, source policy, and personal-info guard pass.

## Known limitation intentionally retained

Tron cannot reliably track an arbitrary operating-system process that an
existing shell tool detaches after the tool itself completes unless that process
has an existing typed lifecycle producer. The correct behavior is to show the
canonical assistant `bash` invocation and stop tracking it at terminal tool
settlement. Inventing a process executor or inferring continued liveness would
violate this plan's authority and root-cause constraints.

This limitation does not prevent future process producers from joining the
unified projection. They must first provide exact ownership, bounded lifecycle,
and authoritative terminal evidence; no composer or iOS history redesign should
be necessary.
