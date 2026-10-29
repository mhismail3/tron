# Delegated activity and extension history

How delegated subagent work and extension runs are attributed, projected and read back.
Owners: `gateway/delegation` (`delegated-provider.ts`, `child-session-admission.ts`,
`managed-subagents.ts`, `managed-producer.ts` for message-local provenance and API binding,
`task-subagents.ts` for canonical task settlement receipts
and bounded cold artifact proof; `OwnedTurnOwner` for live run/artifact authority), `gateway/extension-activity` and `gateway/projection`
(`process-activity.ts`); RuntimeSlot keeps the exact process-to-child bindings.

`worker-contract.ts` owns the actual control identity, finite refusal reasons and
shared worker/control diagnostic records. Home's broader business diagnostics compose
these records; native frames do not import the Home dispatcher for their contracts.

`WorkerSettlement` owns the live worker's delivery/detached waiter sets and
operation-deadline/disposal-grace join. Native publications address that owner directly;
they retain no parallel waiters. `subagent-control.ts` executes the exact installed
controller against the actual SDK session, retaining the provider's rejection semantics.

`DelegationOperations` is the one registry-owned service shared by Home and
automations. It acquires the actual worker for steer/stop/interrupt and uses
`worker-control.ts` for the exact operation fences and steering input. Steering submits
that input directly to the acquired native prompt, without a submission adapter.
Native prompt admission stays K2; one native interruption operation is bound in kernel composition,
so target capture precedes steering and abort. Home retains no native control binding.

The service also owns worker creation, resume leases, deadline races, settlement
acknowledgement and the one first-registration-wins session→task attribution index.
That metadata is not a live report-owner binding. Home selects recovery entries;
native catalog/attention batching reads/registers this owner and keeps its original
acknowledgement lane and publication ordering. No parallel index or token map exists.
Worker resume acquires the canonical native lease here, invokes the existing K5
owned-turn owner's lane-protected bind, and releases that same lease on failure.
A failed rebuild restores the previous report binding. Refused admission retires
its report callbacks; an acquired or late lease joins K5's exact-binding release
and native toolset rebuild before releasing its pin. A superseding binding is
never cleared by an older admission. SDK rebuild and physical publication remain native I/O. Registry supplies only
its actual persisted-session acquisition; it has no resume forwarding route.

Native Session/Run owns ordinary leases, prompt admission and canonical recovery/marker
I/O. Home and Automation call those authorities directly rather than forwarding through
K5. The shared service retains actual worker orchestration and clear-before-release
acknowledgement; it has no passthrough admission, lease or recovery methods.
It also owns cold subagent artifact proof and the optional-root refusal policy. The
resource view is the actual native options object, preserving the late root read;
there is no copied root or Registry proof wrapper. Home calls K5's projection reader
on the same native selected-branch evidence cut, without a native projection wrapper.

`worker-turn-boundary.ts` owns actual task report/budget/reminder finish-turn policy
over the existing native frame and created SDK runtime. It awaits the SDK boundary
first and preserves late canonical/queue/diagnostic reads and exact queued-input Stop.
K2 installs that policy; it does not duplicate its algorithm.

`subagent-settlement.ts` owns the actual task-end stop/join/notice/receipt algorithm.
Its structural backend view is the actual native runtime: no copied context or token
index. Canonical append and work handles remain native; the same operation owner is
passed to the append after the live notice join. Settlement reads the actual K5 run
controller/Stop selection and waiter owner; native supplies SDK, canonical and work I/O.

`OwnedTurnOwner` holds the single live worker report-owner binding as well as the
session-local owned-terminal observer map and held-task continuation state. Creation
seeds its binding once; resume validates live work, chapter identity and canonical
markers in the same native lane, replaces the binding, rebuilds the SDK runtime and
publishes in the original order. Slot has no separate worker field or bind route.
K2 passes its actual frame, reads this owner for admission,
registers wake identity at the native admission boundary and reports canonical terminals
directly. K5 keeps wake-before-own selection, own-before-task callback ordering, selected-
branch/live-work hold decisions and exact waiting-task Stop; no native wait mirror exists.
`owned-operation-terminal.ts` defines the canonical terminal contract and waiting-Stop code.
Native completion classification, receipt persistence and abort I/O remain K2.

The same owner holds the actual activity/correlation, watcher/read-generation and receipt
maps. `subagent-artifact-status.ts` owns bounded opened-file/directory/header proofs;
`subagent-artifact-reconcile.ts` owns live/cold admission and replacement reconciliation;
`subagent-activity.ts` folds lifecycle, canonical facts/receipts and publications over those
same maps. No native subagent artifact parser, run-control method, second index or callback adapter
exists. Native branch/disposal boundaries call this owner's reset/retirement operations;
watched refresh checks generation and disposed-frame identity after its read. Admission
retains bounded path/header/inode proofs; ambient discovery uses attribution and receipt-claim
checks and reads Native’s existing retirement fence (`shuttingDown` or `disposed`)
at entry, after its read and on read failure, before shared recency, lifecycle
publication or canonical receipt writes. Idle retirement sets that same Native
fence before awaiting SDK cleanup. Watched reads also check their existing read
generation before missing-file handling or any other post-read effect.
Native alone writes SDK invocation
rows; K5 writes their activity projection
through the actual Native resource operation without borrowing the tool-row map.
The bounded Gateway discovery scheduler offers each frame's actual K5 owner directly.
Native process rows, exact process-to-child projection bindings, canonical append and
physical SDK/work/publication resources retain their original identities and lifetimes.

Managed-provider logging consumes the existing K3 `ModuleLog` contract; K5 does
not depend on the Transport logger implementation. Optional logging and metadata are unchanged.

## Session subagent activity

- `process-activity.v1` projects only structured synchronous and asynchronous subagents with
  an authoritative producer. Bash, `!` commands, terminal PTYs, ordinary tools and inferred
  shell children stay ordinary transcript presentation; no shell tool, executor or journal is
  added. Foreground bash withholds inherited `PI_*` and `TRON_GATEWAY_*` and supplies only the
  session's `PI_SESSION_ID`; PATH is kept; `PI_SUBAGENTS_TEMP_ROOT`, `TRON_DATA_DIR` and
  `TRON_HOME_NAME` never reach shells. Gateway test configurations share one environment policy
  that rejects a live home before test modules run.
- `SessionProcessActivity` rows: stable namespaced `processId`, typed source, mode and
  lifecycle, bounded current tool and output, optional `durationMs` from producer or canonical
  timing, optional validated child-session reference, optional model and thinking from the
  producer status. The installed pi-subagents foreground producer's child index
  (`foreground-index:N`, scoped by the parent tool call) is admitted only when the `subagent`
  owner is the installed extension (finalized `SourceInfo.source` package name, installed
  `package.json`, provider path) and indexes are unique; generic tools need explicit
  `runId`/`asyncId` and never gain ownership from array position.
- Async artifacts: child identity is `childId`, then workflow key, then child `runId`, else
  `step:N`. A workflow's `runId` and its canonical session owner are independent (resumes may
  share a session); contradictory bindings for one process fail closed. A detached single run
  may use the parent fan-out root only through a matching private recovery descriptor. A
  session target published before its JSONL exists is retried on bounded backoff and on an
  explicit open; no path scans. Bare launcher acknowledgements stay hidden until child evidence.
- `status.json`'s first property is the `lifecycleProjection` header, admitted from a 32 KiB
  prefix (≤ 30 KiB). Parent identity is the exact canonical parent file (else the session UUID
  when the slot has no file). Within 256 KiB the full steps give titles, model, task, path,
  attention and counters (32 children per node, 64 total); child detail joins through the
  reciprocal workflow edge and is optional (`lifecycleOmissions.children`); oversized
  documents use the compact fallback (`lifecycleOmissions.byteLimitExceeded`). A foreign
  session header is an ownership mismatch; malformed headers fail closed; producer `partial`
  becomes `failed` with `needsAttention`.
- A completed workflow with running children stays open; those children are live work for the
  dashboard, drain, eviction and Home task settlement until terminal or proven paused-exited.
  Home task status, report admission and Stop select executions from one artifact frame: the
  root ID while it owns live work, else each live child's run ID. Report admission
  asks `OwnedTurnOwner` to refresh live activities' exact-owned artifacts before
  selecting live work, including terminal roots with live children. It uses the
  watcher's existing generation/disposal-fenced reader and preserves the shared
  liveness policy for missing artifacts, recovery and failed receipt claims.
- Recovery: an installed provider's recovered receipt binds source and replacement to the
  original launch; with the original runner's terminal proof the superseded run settles as
  stopped, never successful; the replacement stays active. Only the current tool and bounded
  output are shown; nothing invents a last-tool record.
- Paths, PIDs, environment values and unbounded task text never cross the wire; output
  previews mask credentials, headers, cookies, URL userinfo, PEM, tokens, JWTs and high-entropy
  strings without touching JSONL. `SessionProcessOverview` carries active/recent/problem counts,
  revision, `asOf`, nearest expiry and `extensionChildOmissions`.
- Recency: the Gateway owns exactly five minutes after terminal admission (a monotonic timer,
  a revisioned expiry snapshot, a tombstone against resurrection). A paused row is settled
  (`state: paused`, `terminalAt`, `visibility: recent`, no abort route) only after the exact
  `processTerminal` proof; otherwise it is active. A run first read already terminal after a
  restart uses the producer's end time. Replacement deltas carry exact removed IDs.
- `session.processHistory.list|get` (`process-history.v1`) page normalized subagent terminal
  receipts under one branch revision; a row that cannot fit an empty page is omitted and
  counted. Receipts keep child producer, session owner and validated child-session ID, never
  paths, task text or output.
- `session.processTranscript.open|page|close` (`process-transcript.v2`) read a child through
  the exact parent process-to-child relationship with a connection-owned, per-client and
  per-parent bounded lease: the watcher is installed before the first page; reads serialize
  per lease, recheck revision, parent binding, path, header and inode; a 64 MiB parse budget
  over the pinned newline-complete prefix; symlinks, oversized headers, replacement and stale
  anchors fail. Fresh children live only at `<parent-stem>/<session-owner>/run-N/session.jsonl`
  (owner proven as the root run or an artifact child `runId`), forks at
  `<parent-stem>/forks/<fork>.jsonl`. Reads never acquire the child runtime.
  `session.processTranscript.abort` (`process-transcript-abort.v1`) needs the live lease and
  routes through a receipt to the parent's settled abort (synchronous, bound to the captured
  operation) or the installed controller with exact run and child (async); `canAbort` says
  which. Closing the parent presentation retires every lease.
- Proof: `child-session-admission`, `managed-workflow-children`
  (`test-results/managed-workflow-resume.json`), `home-task-subagents-reports.e2e.test.ts` and
  `subagent-parity.integration.test.ts`, which compares projections with
  `test-support/subagent-parity-old.json` under approved deltas in
  `test-support/subagent-parity-approved.json` (`test-results/subagent-parity.json`;
  regenerate OLD with `packages/gateway/scripts/regenerate-subagent-parity.sh`, isolated).

## Extension activity lifecycle and history

Extension runs keep coarse `status` plus a lifecycle (`queued`, `running`, `paused`,
`completed`, `failed`, `stopped`, `rejected`, `unknown`); Gateway sequence and terminal latches
own ordering. Terminal rows get `terminalAt`/`recentUntil` and stay recent 15 minutes (only they
carry `remainingMs`); heartbeats publish one `session.extensionActivity` delta, not a snapshot.
`extension-activity-history.v1`: `session.extensionActivity.list|get` page reserved
`tron.extension-activity.v1` receipts (exactly once per activity; identity, label, lifecycle,
counts only; out of transcript, tree and model), 256 KiB and 50 rows per page, cursors bound to
the branch revision. The registry owns discovery scheduling; its frames' K5 owners watch only proven-owned
artifacts. Timelines must satisfy `startedAt <= endedAt <= lastUpdate`; rejections log
rate-limited hashed reasons (`invalid-timestamp`, `missing-terminal-time`,
`ownership-mismatch`, `malformed-artifact`, `artifact-replacement-in-progress`). Drain refreshes
owned artifacts on an interval; a nonterminal artifact missing for 30 s becomes `unknown` and
releases its claims.

## Canonical producer attribution and lifecycle artifacts

- Every canonical `custom_message` is context; producer-visible ones project as inbound
  context. The managed provider loads through a Tron-owned factory whose `sendMessage` captures
  its build-bound owner on a fresh content array that travels with the message through every
  queue; the Gateway reads it at `message_start` and never infers it. Generic extensions keep
  callback-bound attribution. Owners carry typed `kind` (`subagent` or `extension`); one
  classifier also admits historical `npm:pi-subagents` owners; consumers use the kind.
- Delivery: managed per-child notes and supervisor progress are stored context; the parent
  wakes only for async completion (`subagent-notify`), control notices and expects-reply
  decisions (quiet scheduled successes do not wake). `sendUserMessage` enters normal admission
  as a `subagentWake` invocation, projected as a hidden internal `prompt` with `subagent`
  origin. `tron.context-delivery.v4` receipts bind the exact canonical tail at Pi's boundary
  and record `delivery=triggeredTurn` with `wakeEntryId` only through the exact wake binding.
- Structured extension tool results (`details.runId`/`asyncId`, `results[].progress`) project
  `ExtensionRunActivity`; the explicit pi-subagents `status.json` contract projects detached
  runs. Everything provider-specific lives in `delegated-provider.ts`; recognition needs the
  receipt-verified reserved closure, so look-alikes never become the provider.
  `<tronHome>/internal/subagents/` is scanned under one work budget; a synthetic
  `subagent:<runId>` identity is rekeyed when the tool call arrives; terminal status is
  authoritative; historical artifacts settle only with an exact tool-call/`asyncDir` binding.
  `subagent_supervisor` receipts reference runs and never claim launches
  (`managed-attribution.integration.test.ts`, `runtime-registry.integration.test.ts`).

## Extension registration ownership

K3 `extension-registration.ts` owns generic callback and registration metadata;
producer kind is supplied by its actual owner. Product reservations and identity
classification stay in `extensions/owner-attribution.ts`, supplied to native loads
through `extensionAdmission`. No Host-to-Delegation classification import is needed.

Callbacks are wrapped through `DefaultResourceLoaderOptions.extensionsOverride` on every load,
and admission reads the extension's own registration maps, so late `registerTool` and friends
pass the same policy (the markdown transformer is the one unattributed surface, and nothing
authorizes from it). An AsyncLocalStorage owner (opaque SHA-256 of source provenance, a generic
title, exact `sourceInfo.source`) follows handlers, tools, commands, renderers, promises and
timers; owner and reserved-name admission resolve at invocation because Pi finalizes
`SourceInfo` after loading. Ownerless callbacks stay ownerless. Owner records are bounded.
