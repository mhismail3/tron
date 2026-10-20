# Delegated activity and extension history

How delegated subagent work and extension runs are attributed, projected and read back.
Owners: `gateway/delegation` (`delegated-provider.ts`, `child-session-admission.ts`,
`managed-subagents.ts`), `gateway/extension-activity` and `gateway/projection`
(`process-activity.ts`); RuntimeSlot keeps the exact process-to-child bindings.

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
  root ID while it owns live work, else each live child's run ID.
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
the branch revision. One registry owns discovery and watchers; slots watch only proven-owned
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

Callbacks are wrapped through `DefaultResourceLoaderOptions.extensionsOverride` on every load,
and admission reads the extension's own registration maps, so late `registerTool` and friends
pass the same policy (the markdown transformer is the one unattributed surface, and nothing
authorizes from it). An AsyncLocalStorage owner (opaque SHA-256 of source provenance, a generic
title, exact `sourceInfo.source`) follows handlers, tools, commands, renderers, promises and
timers; owner and reserved-name admission resolve at invocation because Pi finalizes
`SourceInfo` after loading. Ownerless callbacks stay ownerless. Owner records are bounded.
