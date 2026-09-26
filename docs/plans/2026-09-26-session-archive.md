# Session archive

- **Started:** 2026-09-26
- **Status:** Active
- **Last updated:** 2026-09-26, F-5
- **Goal:** A user can archive an idle session so it leaves the dashboard without being deleted, find it again in one collapsed Archived container or in search, and have it return automatically when it runs again.

## Goal and constraints

Archiving hides a session from the dashboard. It never deletes or rewrites anything. The canonical session file and its transcript, name, attention state, artifacts and search index stay as they are. Unarchiving restores the session's normal dashboard position. Only the user's explicit **Delete** removes a session.

These rules override an agent's own judgment:

- **No hidden work.** An archived session is always idle. Archiving is rejected
  while anything is active: the phase is running, compacting or retrying, the
  session is waiting for the user, it has active subagents, or it has queued
  prompts. Every new run clears the archive state before the run can do any
  work. That covers a prompt from any device, an automation prompt, Bash,
  manual compaction, and a turn started by an extension or a scheduled wake.
- **Opening is not a run.** Opening, reading, renaming, marking read or unread,
  exporting, or searching an archived session leaves it archived.
- **Archive state is Gateway-owned display state.** It lives in a Gateway store,
  like read/unread attention. It never goes in the Pi JSONL, and archiving never
  appends an entry, changes `updatedAt`, or starts a runtime for an inactive
  session.
- **No compatibility shims.** A new capability `session-archive.v1` gates the
  iOS UI. `session.list` keeps its current default for clients that don't send
  the new parameter. Do not bump the protocol version for this additive
  contract, and add no fallback paths.
- **Where archived sessions appear.** Archived sessions are hidden from the
  dashboard's workspace groups and from the automation session picker. They
  appear in one collapsed **Archived (N)** container at the bottom of the
  dashboard, and in session search results labeled **Archived**.
- **Out of scope for this plan:** bulk archive, auto-archive after a period,
  and archiving subagent sessions.
- **No agent-run lifecycle actions.** Agents never rebuild or restart the
  Gateway and never install over `/Applications/Tron.app`. Rollout of the
  Gateway half is a user action (see V-1).

## Context

Current state, inspected 2026-09-26:

- **Delete is the only removal.** `session.delete` in `packages/gateway/src/transport/gateway-service.ts` calls
  `RuntimeRegistry.delete()` in `packages/gateway/src/sessions/runtime-registry.ts`. That call admits the
  session against hardened structural identity, rejects busy and subagent sessions, disposes the slot,
  deletes the canonical file, then removes attention state on the attention lane.
- **Attention is the model to copy.** `SessionAttentionStore` (`packages/gateway/src/sessions/session-attention-store.ts`)
  is a bounded, atomic, versioned JSON store under `~/.tron/gateway/`.
  - It is pruned at startup only from *complete* structural evidence.
  - It follows session re-keying through `SessionAttentionRebindDisposition`
    (`migrate` / `reset` / `discard`, declared in `runtime-slot.ts`).
  - It is projected into each catalog seed in `buildCatalogPageSeeds`.
  - The archive store copies this ownership pattern. Its data stays separate.
- **Listing.** `session.list` pages a `CatalogPageSource` through
  `SessionListPaginationStore` (`packages/gateway/src/transport/session-list-pagination.ts`).
  The cache generation key is `listRevision:projectionGeneration:scope`. iOS only ever requests
  scope `user`. Membership changes reach clients through `session.listChanged`.
- **Summary updates never add rows.** `session.summary` updates only rows iOS
  already knows about. A row appears only when the catalog admits it.
- **Prompt entry.** Gateway-admitted prompts, including automations
  (`automation-executor.ts`), enter through `RuntimeSlot.prompt()` on the slot
  lane. Bash and compaction have their own RPCs. Extension turns started with
  `triggerTurn` start inside Pi without Gateway admission.
- **iOS.**
  - Dashboard rows are in `packages/ios-app/Sources/UI/Chat/SessionShellView.swift`. The trailing swipe
    has Delete (with confirmation) and Rename. The leading swipe has Mark Read/Unread.
  - Mutations go through `SessionMutationService` and `AppModel` using `performOnOwningGateway`.
  - The dashboard combines several paired Gateways through `DashboardGatewayConnectionPool`.
  - `SnapshotCache` persists dashboard buckets.
  - `AutomationFormView` picks sessions from `model.visibleSessions`.
- **Precedent.** Knowledge already has an `includeArchived` list flag
  (`KnowledgeRPCClient.swift`). Session archive is a separate concept and does
  not share that store.

## Plan rules

- **Testing.** Follow the AGENTS.md testing policy.
  - The primary proof is one Gateway WebSocket integration test that exercises
    the full lifecycle and writes a JSON report at a stable path.
  - Before writing any isolated test (store, iOS state), list its failure modes
    in the task's handoff entry. Each isolated test must target one listed mode
    that the integration test cannot catch.
- **Atomicity.** Each task ships its code, tests and owning docs together.
  Gateway tasks must leave `session.list`'s default behavior correct at every
  commit.

## Tasks

| ID | Status | Scope | Depends on | Owner |
| --- | --- | --- | --- | --- |
| G-1 | Done | Gateway archive store, `session.archive.set` RPC, list filtering and count, delete/rekey/prune ownership, `session-archive.v1` capability | none | archive worker, 2026-09-26 |
| G-2 | Done | Every new run unarchives: an admission-time clear for Gateway-admitted runs, plus a backstop when an active phase is published | G-1 | tron-coordinator, 2026-09-26 |
| G-3 | Done | Search results carry `archived`; `session-search.md` updated | G-1 | tron-coordinator, 2026-09-26 |
| I-1 | Done | iOS model, mutation service, AppModel and capability gating; catalog membership follows authoritative responses | G-1 | tron-coordinator, 2026-09-26 |
| I-2 | Done | Dashboard full-swipe Archive, one collapsed "Archived (N)" container at the bottom, and archived-row actions | I-1 | tron-coordinator, 2026-09-26 |
| I-3 | Done | Search "Archived" label, automation picker exclusion, and display of an existing automation whose target is archived | I-1, G-3 | tron-coordinator, 2026-09-26 |
| F-1 | Done | The `session.fork` RPC rejects with retryable `busy` because its own admitted work entry satisfies the slot's idle check; decide the fix and cover the real path | none | tron-coordinator, 2026-09-26 |
| F-2 | Done | The same self-work-entry rejection now also measured on `session.bash`, `session.navigate` and `session.setTools`; audit every mutation RPC whose slot method consults session work ownership and decide the fix (thread the request's work token, as `session.setModel` already does) | none | tron-coordinator, 2026-09-26 |
| F-3 | Done | Coordinator review of I-3: chat archive state comes from a bounded iOS observation list (parallel state). Make the Gateway `SessionSnapshot` carry `archivedAt` (republished on change) and delete the observation list | I-3 | tron-coordinator, 2026-09-26 |
| F-4 | Done | I-2's hosted UI journey never passed (app never idled; simulator contention). Make it pass on a healthy simulator, fixing the fixture if it is the cause, and keep its screenshots | I-2 | tron-coordinator, 2026-09-26 |
| F-5 | Done | `session-archive.integration.test.ts` "rejects a prompt retryably when archive state cannot be cleared" failed once in four full-suite runs (passes alone and under targeted load); reproduce, find the root cause, fix | G-2 | tron-coordinator, 2026-09-26 |
| F-6 | Needs scoping | Same class as F-5, unproven: `RuntimeRegistry` line 1216 also writes `gateway/model-recents.json` fire-and-forget (`void this.noteModelUsed(...)` → `await this.recentModels.record(...)`), so its durable write can equally outlive `dispose()`. Decide whether `RecentModelStore` gets the same disposal drain | F-5 | |
| V-1 | Ready | Cross-module checkpoint, user-performed Gateway rollout, and eyes-on device review; close the plan | G-2, I-2, I-3, F-3, F-4, F-5, F-6 | |

## Task details

### G-1 — Archive store, RPC and listing

Owning files:

- New `session-archive-store.ts` in `packages/gateway/src/sessions/`
- `runtime-registry.ts`
- `gateway-service.ts`
- `session-list-pagination.ts`
- `packages/gateway/src/protocol/types.ts`

**Store** (`~/.tron/gateway/session-archive.json`):

- **Format.** `{ version: 1, sessions: { [id]: { archivedAt } } }`.
- **Bounds.** Size limits match the attention store: 50,000 sessions, 2 MiB,
  200-byte IDs.
- **Writes.** Write to a temp file, then rename. One mutex serializes writes.
- **Corruption.** A corrupt, oversized or wrong-version file is handled the same
  way the attention store handles one (read and match it; do not invent a new
  policy). The store never silently resets to empty, because that would make
  every archived session reappear.

**RPC** `session.archive.set { sessionId, archived: boolean }`:

- **Receipts.** It is a `mutation` with a command-ID receipt. Register it
  wherever the existing method-admission lists name `session.rename` and
  `session.delete`.
- **Admission.** It reuses delete's hardened structural admission: the session
  must be known and unambiguous. Subagent sessions are rejected with
  `conflict`. A session being deleted gets `busy` (retryable).
- **Archiving must be idle.** Archiving checks the rule in Goal and constraints
  under the registry mutex, and inside the slot lane when a slot exists.
  Otherwise it fails with `busy`, "Stop the session before archiving it", code
  `session_operation_busy`. A pending automation dispatch reservation or lease
  for the session also counts as busy.
- **No runtime for inactive sessions.** A session with no slot is archived
  without starting a runtime.
- **Idempotent.** Archiving an already-archived session keeps its original
  `archivedAt`. Unarchiving a session that isn't archived is a no-op success.
- **Response.** The response returns the authoritative
  `{ archived, archivedAt? }`.

**Listing:**

- **New parameter.** `session.list` takes `archived?: "exclude" | "only"`,
  default `exclude`. `exclude` hides archived IDs from every list and cursor
  page.
- **`only` ordering.** `only` returns archived user sessions newest-archived
  first. Ties break by ID.
- **Count.** The first `exclude` page returns `archivedCount`.
- **Summary field.** `SessionSummary.archivedAt?` is set only on archived rows.
- **Cache key.** An archive-store revision joins the page-source generation key,
  so a pagination lease can never mix archive states across pages.
- **Change signal.** Each committed change bumps the registry revision and calls
  `sessionListChanged`.

**Ownership:**

- **Delete.** Delete removes the archive record on the same lane and with the
  same pending-retry discipline as attention removal.
- **Re-keying.** It follows `SessionAttentionRebindDisposition`:
  - `migrate` moves the record.
  - `reset` (new session, fork) leaves the new ID unarchived. The source session
    keeps its own state.
  - `discard` removes the record.
- **Startup pruning.** Startup prunes records only from complete structural
  evidence. Incomplete evidence and duplicate IDs keep their records.

**Capability.** Advertise `session-archive.v1` in `system.info`.

**Observability.** Add a privacy-safe `sessions.archive.persist-failed` event
(outcome and stage only, no IDs), and add its row to `packages/gateway/docs/observability.md`.

**Tests.** Extend or add a WebSocket integration test beside `server-terminal-delete.integration.test.ts`. It writes its report to the test's retained artifact path and covers:

1. Archive an inactive idle session. It is absent from `exclude`, present in
   `only` with `archivedAt`, and `archivedCount` is 1.
2. The session's JSONL bytes and `updatedAt` are unchanged, and no runtime
   started.
3. Replaying the same command ID returns the receipt.
4. Archiving a running session, or one waiting for input, returns `busy`.
5. After a Gateway restart the session is still archived.
6. `session.open` on an archived session succeeds and it stays archived.
7. Rename while archived keeps it archived.
8. Delete removes the store record. Re-creating any file cannot resurrect it.
9. Forking an archived session produces an unarchived child.
10. Subagent archive returns `conflict`.

**Docs.** Add an archive section to the session contract in `packages/gateway/README.md`.

### G-2 — Every new run unarchives

**Primary: clear at admission.** Gateway-admitted work clears the archive state
durably before the run is admitted. This covers `RuntimeSlot.prompt()` (every
RPC and automation prompt), `session.bash`, `session.compact`, and any other
Gateway RPC that starts agent work. Enumerate those RPCs by reading
`gateway-service.ts` and record the list in the handoff.

- **Hook.** Use a registry-owned `beforeRunAdmission(sessionId)` hook that runs
  inside the slot lane, after `assertUsable()` and before admission. The lane
  ordering makes the result correct whichever of archive and prompt arrives
  first.
- **Fail closed.** If the unarchive write fails, reject the run as retryable
  `busy` so that no work runs hidden. Log
  `sessions.archive.persist-failed`.

**Backstop: publishing an active phase.** An extension `triggerTurn` or
scheduled wake starts inside Pi without Gateway admission. When a slot publishes
an active phase for an archived ID, the registry clears the record and emits
`session.listChanged`. The run is already underway, so this path cannot reject
it. A persistence failure keeps the session visible through the live summary and
retries on the next active summary. Log a privacy-safe
`sessions.archive.auto-unarchived` event with a trigger category of `admission`
or `backstop`, and add it to the observability row. It is the single signal
that explains why an archived session reappeared.

**Tests.** Add cases to the G-1 integration test:

- A prompt to an archived session from a second client unarchives it before its
  first event arrives, and both clients see `session.listChanged`.
- Bash and compaction each unarchive.
- An automation `existingSession` run unarchives.
- A fixture extension that starts a turn on its own unarchives through the
  backstop.
- A negative control: a forced store-write failure rejects the prompt, and no
  run marker is created.

### G-3 — Search

Add `archived: boolean` to `SessionSearchResult` (`session-search-contract.ts`).

- It is read from the archive store when the response is built, never stored
  in the search index, so archive changes need no reindex.
- Archived sessions stay searchable and anchorable.
- Add a search case to the G-1 integration test.
- Update `packages/gateway/docs/session-search.md`.

### I-1 — iOS state

Owning files: `SessionCatalogModels.swift`, `SessionMutationService.swift`, `AppModel.swift`, `DashboardStateOwners.swift`, `SnapshotCache.swift`.

- **Model.** Add optional `archivedAt` to `SessionSummary`.
- **Mutation.** Add `SessionMutationService.setArchived` with a command ID and a
  bounded timeout. It runs through `performOnOwningGateway`.
- **Applying the response.** On success, the authoritative response removes the
  row from the dashboard bucket (archive) or schedules a catalog read (unarchive)
  and checkpoints the cache. It is applied monotonically like `applyAttention`,
  with no optimistic state before the response arrives.
- **Count.** `archivedCount` is stored per Gateway profile and summed across
  the dashboard pool. A profile that is offline or doesn't advertise the
  capability contributes nothing and is not shown as zero.
- **Cache.** Archived rows are never persisted in `SnapshotCache`. Only the
  count is.
- **Gating.** Every archive UI control is hidden for a profile that doesn't
  advertise `session-archive.v1`.

Before writing any isolated test, list its failure modes. Candidates:

- a late `session.summary` for an archived ID re-adding the row;
- a stale archived-list read published after a newer unarchive;
- count double-counting across the pool.

### I-2 — Dashboard

Owning file: `SessionShellView.swift`, plus a new archived-container view if the file would otherwise grow.

**Trailing swipe:**

- **Archive** is the full-swipe action, with a neutral tint.
- **Delete** stays a partial-swipe action with its existing confirmation.
- **Rename** is kept.
- The leading **Mark Read/Unread** swipe is unchanged.

**Archived (N) container:**

- **Placement.** One container row at the bottom of the dashboard, after every
  workspace group. It is hidden when N is 0 on every capable profile, and
  collapsed by default.
- **Loading.** Expansion pages `archived: "only"` from each capable, connected
  profile. The read carries the managed presentation activity and a
  latest-request fence. An unavailable profile shows an inline "unavailable"
  note.
- **Rows.** Rows show their workspace. Tapping opens the session. Swipes are
  **Unarchive** (full swipe) and **Delete** (with confirmation).
- **Refresh.** `session.listChanged` refreshes the count and, if the container
  is expanded, the archived page.
- **No disruption.** Keep chat identity and dashboard scroll position stable
  when a row moves between the dashboard and the container.

**Proof.** Extend `TronSmokeUITests` with a fixture journey: archive, the
container count goes up, expand, unarchive. Keep its screenshots as the
artifact. Accessibility identifiers use the existing
`session-*-action-<dashboardID>` pattern.

### I-3 — Search, automations, chat

- **Search.** Search result rows with `archived == true` show an **Archived**
  label. Opening one does not unarchive it.
- **Automation picker.** `AutomationFormView` already reads
  `model.visibleSessions`. Confirm archived rows are absent.
- **Existing automations.** When the saved target of an existing automation is
  archived, its detail and edit views must still name it rather than showing an
  empty or invalid target. Resolve the name through the owning Gateway, not the
  dashboard bucket. The automation keeps running, and each run unarchives the
  target (G-2).
- **Chat.** An archived session opened from search or the Archived container
  shows its archived state wherever the session's Manage/context actions live,
  with an **Unarchive** action. Sending a message needs no confirmation, because
  G-2 unarchives it.

### V-1 — Checkpoint and close

1. Run the full Gateway suite and the focused iOS suites. Run
   `scripts/ios-gateway-e2e-test run` once as the release checkpoint.
2. Report the exact user action to roll out the Gateway. The user performs any
   Gateway rebuild, update or restart.
3. Eyes-on iPhone review, after the user installs:
   - full swipe;
   - the container across two paired Macs if available;
   - unarchive by prompting from search;
   - an automation firing into an archived session.
4. Close the plan: move the lasting contract into the Gateway README,
   `packages/gateway/docs/session-search.md`, `packages/gateway/docs/observability.md` and
   `packages/ios-app/docs/architecture.md` (dashboard section). Add a
   `docs/plans/HISTORY.md` entry and delete this file.

## Handoff log

### G-1 · Done · 2026-09-26 · archive worker
- Result: the Gateway owns session archive state end to end. A new
  `SessionArchiveStore` persists `{ version: 1, sessions: { id: { archivedAt } } }`
  in `session-archive.json` under the Gateway home, atomically and with the
  attention store's bounds, and `RuntimeRegistry.setArchived` exposes it through
  the `session.archive.set` mutation RPC. `session.list` takes
  `archived: "exclude" | "only"` (default `exclude`), returns `archivedCount` on
  a first `exclude` page, and marks archived rows with `archivedAt`. State
  follows delete, rebind, and startup prune from complete structural evidence,
  and `session-archive.v1` advertises the contract. Nothing else about a session
  changes: no file rewrite, no `updatedAt` change, no runtime for a cold session.
- Evidence (verified):
  - `npm run build` clean.
  - `npx vitest run src/transport/session-archive.integration.test.ts`
    (new): 9/9 in 2.5 s over a real WebSocket, real `GatewayService`, real
    `RuntimeRegistry`, paired device and faux provider. Covers idle archive with
    `archivedAt`/`archivedCount` and byte-identical JSONL with zero runtime
    starts, command replay, cursor/filter binding and newest-first archived
    order, `busy` for running and for the waiting-for-input and active-subagent
    projections, restart persistence plus open-stays-archived, rename-while-
    archived and an unarchived fork child, subagent `conflict`, and delete with
    a re-created file that cannot resurrect the record. Retained, regenerable
    report: `test-results/session-archive.integration.json` in the gateway
    package (gitignored output, not source).
  - `npx vitest run src/sessions/session-archive-store.test.ts` (new): 6/6,
    targeting only the failure modes the lifecycle test cannot reproduce:
    corrupt/oversized/wrong-version documents fail closed and leave the file
    untouched instead of resetting to empty; a failed durable write leaves the
    in-memory projection and the revision unchanged; the capacity bound rejects;
    re-archive keeps the original timestamp; prune removes exactly the
    unretained IDs; rekey never overwrites a target; `assertAbsent` blocks a
    rebind onto existing state.
  - `npx vitest run src/sessions/runtime-registry.integration.test.ts`: 240/240
    in 44.3 s. `src/transport/session-list-pagination.test.ts`,
    `src/sessions/session-attention-store.test.ts`,
    `src/transport/server-terminal-delete.integration.test.ts`,
    `src/transport/server-revocation.integration.test.ts`,
    `src/client/terminal-chat.test.ts`, `src/transport/gateway-service-transcript.test.ts`,
    `src/transport/command-receipts.test.ts`, `src/transport/gateway-restart.test.ts`,
    `src/admin/hook-resources.integration.test.ts`: 70/70 and 39/39 in the two
    focused runs.
  - `python3 scripts/check-documentation-policy.py` and
    `scripts/personal-info-guard.sh` both pass.
- Changes: this commit (`packages/gateway/src/sessions/session-archive-store.ts`,
  `packages/gateway/src/sessions/runtime-registry.ts`,
  `packages/gateway/src/sessions/runtime-slot.ts`, `packages/gateway/src/transport/gateway-service.ts`,
  `packages/gateway/src/transport/session-list-pagination.ts`,
  `packages/gateway/src/protocol/types.ts`, `packages/gateway/src/gateway-main.ts`,
  `packages/gateway/src/automations/automation-scheduler.ts`,
  `packages/gateway/README.md`, `packages/gateway/docs/observability.md`, `.gitignore`,
  and the two new test files).
- Tasks added: F-1.
- Kept on purpose:
  - Archiving a live-only session (created but not yet persisted) writes a
    record for an ID that may never reach disk. Startup prune removes it, and
    `archivedCount` counts only rows the catalog admits, so no phantom row or
    count can appear in-process.
  - The idle check runs under the registry mutex and then on the target slot's
    lane, mirroring delete's idle-check-then-dispose ordering. The synchronous
    projection and work checks make the lane wait bounded; splitting them would
    reopen delete's admission-to-commit window.
  - `RuntimeRegistry.catalog`/`catalogSnapshot` stay unfiltered, because session
    search and `readSearchCut` must keep archived sessions addressable (G-3).
  - The automation reservation query is one read-only method on the scheduler
    plus a late-bound registry option, because the scheduler is constructed
    after the registry and the reservation window exists before the executor
    takes its session lease.
- Deviations: the plan's case 9 calls for forking through `session.fork`; that
  RPC is rejected by its own admitted work entry, so the fork is driven on the
  owning runtime and the RPC defect is recorded as F-1 rather than fixed here.
- For the next agent: G-2 is next. Its clear-at-admission hook belongs inside
  `RuntimeSlot`'s lane immediately after `assertUsable()` in `prompt`,
  `executeBash`, and compaction, and it must fail closed on a store write
  failure; `RuntimeSlot.assertArchivable` is the G-1-side check that already
  runs on that lane. F-1 needs a decision: the cheapest fix is to thread the
  RPC's work token into `RuntimeSlot.fork`'s idle check, which also argues for
  auditing every other lane-level `assertIdle` reached from a mutation RPC.

### G-2 · Done · 2026-09-26 · tron-coordinator

- Result: every new run clears retained archive state before it can do any
  work, so an archived session is never running while hidden. Gateway-admitted
  runs clear it inside the same session-lane critical section that admits them
  (`session.prompt` — RPC, automation, scheduled and extension prompts —
  `session.bash`, `session.compact`, and the model-backed branch summary from
  `session.navigate`; the hook is a no-I/O no-op while the session is not
  archived), and a store failure rejects the run retryably. A turn Pi starts on
  its own is caught at the one summary-publication funnel: the row becomes
  visibly unarchived immediately and the durable record is cleared behind it,
  surviving a failed write through a bounded in-memory override that retries on
  the next publication. Both paths log the new privacy-safe
  `sessions.archive.auto-unarchived` event with the boundary that cleared the
  record.
- Result (review fix): archive admission and its durable commit are now one
  session-lane critical section (`RuntimeSlot.commitArchiveWhileIdle` replaces
  `assertArchivable`), closing the window where a prompt admitted between the
  idle check and the commit would run while the archive committed over it. The
  lock order is registry mutex -> session lane -> attention/archive lane, and no
  path holds a display-projection lane while waiting for a session lane or the
  registry mutex (delete releases the attention lane before taking the mutex;
  setAttention resolves admission before entering; rekey already nests this
  order). A cold session is fenced by the mutex plus the existing slot-identity
  recheck, because every slot publication happens inside that mutex.
- Evidence (verified):
  - `npm run build` clean.
  - `npx vitest run src/transport/session-archive.integration.test.ts`: 18/18 in
    5.7 s over the real WebSocket, `GatewayService`, `RuntimeRegistry` and faux
    provider. Nine new G-2 cases: a prompt from one client unarchives before its
    admission response returns, both clients receive `session.listChanged`, and
    the run publishes no event while hidden; Bash, manual compaction (real
    summarization, `compacted: true`) and an automation-shaped
    `acquireAutomationLease` + owned prompt each clear the record; a queued
    follow-up makes archive admission `busy`; an extension-owned trigger
    (`pi.sendMessage` with `triggerTurn`) with no Gateway admission is restored
    by the backstop while its run is still `running`; a forced store-write
    failure rejects the prompt with retryable `busy`, leaves the record, and
    creates no run marker and no phase change; and ten concurrent
    archive/prompt rounds plus a gated round never end archived-while-working.
  - Negative control for the review fix: reverting
    `commitArchiveWhileIdle` to release the lane before the commit makes the new
    "holds the session lane from archive admission through the durable commit"
    case fail (`expected true to be false`: the prompt was admitted while the
    commit was still open). Restored, it passes.
  - `npx vitest run src/sessions/runtime-registry.integration.test.ts`: 240/240
    in 57.9 s. `runtime-compaction.integration.test.ts`,
    `sync-protocol.integration.test.ts`, `server-terminal-delete.integration.test.ts`,
    `session-attention-store.test.ts` (34/34), and
    `runtime-terminal-notifications.integration.test.ts`,
    `gateway-service-transcript.test.ts`, `tron-workspace.integration.test.ts`,
    `command-receipts.test.ts`, `gateway-restart.test.ts` (69/69) all pass.
  - `python3 scripts/check-documentation-policy.py` and
    `scripts/personal-info-guard.sh` pass.
- Changes: this commit (`packages/gateway/src/sessions/runtime-slot.ts`,
  `packages/gateway/src/sessions/runtime-registry.ts`,
  `packages/gateway/src/gateway-main.ts`, `packages/gateway/README.md`,
  `packages/gateway/docs/observability.md`, and
  `packages/gateway/src/transport/session-archive.integration.test.ts`).
- Tasks added: F-2.
- Kept on purpose:
  - Archiving a session with no runtime still commits on the display lane
    alone: `setArchived` holds the registry mutex across the whole operation and
    every slot publication takes that mutex, so no runtime can appear between
    the structural admission and the commit.
  - The unarchive direction (`archived: false`) still does not require an idle
    session, so a client can always reverse a hidden row, including one whose
    run has already started.
  - The backstop also fires for `waitingForUser` and `hasActiveSubagents`
    projections, not only `running`/`compacting`/`retrying`: archive admission
    treats those as active, so the same rule must clear them or the invariant
    would be asymmetric.
  - A failed backstop write keeps an in-memory visible override and retries on
    the next published summary instead of adding a second durable intent store;
    a restart falls back to the durable record, which the next run admission
    clears.
- Deviations: the required G-2 Bash case is driven on the owning runtime rather
  than through the `session.bash` RPC, which is rejected before that boundary by
  its own admitted work entry (same class as F-1; measured for `session.bash`,
  `session.navigate` and `session.setTools` and recorded as F-2).
- For the next agent: G-3 and I-1 are in flight in other worktrees. G-3 reads
  the archive store directly, so it will not see the registry's in-memory
  visible override during a failed backstop write; prefer routing that read
  through a registry seam if the two land together. F-2 needs a decision: the
  measured fix is to pass the mutation's work token into the slot methods whose
  idle check consults session work ownership, exactly as `session.setModel`
  already does.

### G-3 · Done · 2026-09-26 · tron-coordinator

- Result: `SessionSearchResult` carries `archived`, the Gateway archive
  projection read from the archive store at publication. A new read-only
  `RuntimeRegistry.isArchived` seam is the only search involvement, so archive
  state never enters the index: archiving or unarchiving a session changes no
  indexed text, needs no reindex, and leaves the session searchable and
  anchorable while its dashboard row is hidden.
- Evidence (verified):
  - `npm run build` clean.
  - `npx vitest run src/transport/session-archive.integration.test.ts`: 10/10 in
    2.8 s. The new case "keeps an archived session searchable and marked
    archived" drives a real `SessionSearchIndex` and `SessionSearchService`
    through the real WebSocket `session.search` and `session.search.anchor`: the
    hit is `archived: false`, then `session.archive.set` hides the row from
    `session.list` while the same canonical entry and content revision come back
    as `archived: true`, an anchor still resolves the exact entry, the canonical
    file is byte-identical, and unarchiving returns `archived: false`. Retained,
    regenerable report: `test-results/session-archive.integration.json` in the
    gateway package (gitignored output, not source).
  - `npx vitest run src/sessions/session-search-service.test.ts
    src/sessions/session-search-index.test.ts src/sessions/session-search-text.test.ts
    src/transport/gateway-service-transcript.test.ts`: 36/36 in 1.4 s. No new
    isolated test was written: the contract is fully exercised by the WebSocket
    case above, and these files only needed their `any`-typed registry stubs to
    answer `isArchived` because the published seam is now part of the service's
    read contract.
  - `python3 scripts/check-documentation-policy.py` and
    `scripts/personal-info-guard.sh` both pass.
- Changes: this commit (`packages/gateway/src/sessions/session-search-contract.ts`,
  `packages/gateway/src/sessions/session-search-service.ts`,
  `packages/gateway/src/sessions/runtime-registry.ts`,
  `packages/gateway/src/transport/session-archive.integration.test.ts`,
  `packages/gateway/src/sessions/session-search-service.test.ts`,
  `packages/gateway/docs/session-search.md`).
- Tasks added: none.
- Kept on purpose:
  - The search fixture wires `SessionSearchService` behind an opt-in `search`
    option, so only the case that reads search results pays for a real SQLite
    index; the other nine archive cases are unchanged.
  - `readSearchCut` and `catalog` stay unfiltered by archive state. Search and
    anchors need archived sessions addressable, and filtering here would have
    silently changed the anchor contract.
  - The archive label is read for each result while the response is assembled
    rather than snapshotted once. Archive commits never invalidate a search, so
    the only cost is that a session archived by another device mid-response can
    show both labels in that one response; a later response is correct.
- Findings (fixture traps, not product behavior):
  - The pinned manager appends its own `thinking_level_change` entry the first
    time a runtime opens a session file it created, and the first open can land
    after the request that triggered it. Cross-query revision comparisons in one
    test therefore need one warm query plus one warm anchor before the measured
    reads, which is why the new case warms first.
  - A hand-written canonical fixture message must carry a full assistant
    envelope (`api`, `provider`, `model`, `stopReason`, and
    `usage.cost.total`): opening that session for an anchor makes the runtime
    project `message.usage`, and a message without one fails the request with an
    internal error.
- Deviations: none from the task's scope. The plan allowed either extending the
  G-1 integration test or an owning search test; the WebSocket test won because
  it is the real path, so the fixture now owns real search wiring and the hit's
  exact canonical entry and content revision are compared across the archive
  change on that path instead of against a stub.
- For the next agent: I-3 consumes the new field. `SessionSearchResult` in
  `packages/ios-app/Sources/Models/SessionSearchModels.swift` currently ignores
  unknown response keys, so adding the iOS field is the whole client change; it
  must decide whether `archived` is required (a Gateway without
  `session-archive.v1` omits it) or gated on the capability. Nothing else on the
  Gateway side labels, filters, or orders search results by archive state.

### G-2/G-3 merge · Done · 2026-09-26 · tron-coordinator

- Result: merged G-3 into the G-2 branch. `RuntimeRegistry.isArchived` now
  reads the effective projection (`archivedAt`), so a session whose backstop
  write failed and is pending restoration is already `archived: false` in
  search, as the G-2 handoff asked.
- Evidence: `npm run build` clean; archive integration, archive store, search
  service and list pagination tests 49/49 (5.8 s).
- Changes: merge commit.
- Deviations: none.


### I-1 · Done · 2026-09-26 · archive worker

- Result: iOS carries archive state without owning it. `SessionSummary.archivedAt`
  decodes the Gateway's row state, `session.list` pages admit `archivedCount`, and
  `SessionMutationService.setArchived` sends `session.archive.set` with a command
  ID and a 60 s bound. `AppModel.setSessionArchived` applies only the authoritative
  response: archive removes the row and keeps the ID hidden from live summaries,
  unarchive schedules an authoritative catalog read instead of fabricating a row.
  The dashboard keeps one count per profile and sums it over archive-capable
  profiles (`SessionArchiveCountProjection`), never as a zero, and a new
  `loadArchivedSessions` reads `archived: "only"` pages for the archived container
  under the caller's managed activity and an exact per-profile latest-request
  fence. Archive controls are gated by `supportsSessionArchive(profileID:)`.
- Failure modes written before the isolated tests (the Gateway lifecycle test
  cannot reproduce them):
  - F-A a late `session.summary` for an archived ID re-materializes the row on the
    focused catalog or a background pool catalog;
  - F-B a stale `archived: "only"` page is published after a newer archive toggle
    or a surface exit;
  - F-C the count double-counts, fabricates a zero for an incapable/unknown
    profile, or drops a row's archive state from a copied summary;
  - F-D `SnapshotCache` persists an archived row or loses the count across a
    relaunch;
  - F-E iOS encodes the wrong archive command or flattens the Gateway's
    `session_operation_busy` refusal into a generic failure;
  - F-F the loader admits a leaked archived row into the dashboard projection or a
    foreign row into the archived projection.
- Evidence (verified):
  - `scripts/tron-ios-test build`: TEST BUILD SUCCEEDED.
  - `scripts/tron-ios-test run --only-testing TronMobileTests/SnapshotCacheTests
    --only-testing TronMobileTests/DashboardStateOwnerTests
    --only-testing TronMobileTests/SessionMutationServiceTests
    --only-testing TronMobileTests/AppModelCatalogSyncTests`: 84 tests in 4 suites
    passed, including the ten new archive tests. The pool-level test uses
    `TRON_IOS_TEST_DERIVED_DATA` scoped to this worktree, because the default
    derived-data path is shared by concurrent sessions and another session's
    build overwrote these products mid-verification. The retained result bundle
    is under `~/Library/Developer/Tron/ios/test-runs/`.
  - That test found a real defect in this change before it shipped: the pool's
    new count callback was declared only in the delegate protocol extension, so
    the subscription read it as a default no-op and the count never reached the
    dashboard. It is now a protocol requirement.
  - `python3 scripts/check-documentation-policy.py` and
    `scripts/personal-info-guard.sh` pass.
- Changes: this commit (`SessionCatalogModels.swift`, `SessionMutationService.swift`,
  `AppModel.swift`, `DashboardStateOwners.swift`, `DashboardGatewayConnectionPool.swift`,
  `SnapshotCache.swift`, `GatewayRequestTimeout.swift`, the four owning test files, and
  `packages/ios-app/docs/architecture.md`).
- Kept on purpose:
  - The count is not adjusted locally on an archive response. It converges from
    the Gateway's own list change, so a concurrent change on another device
    cannot make iOS disagree with the store.
  - An archived ID stays marked until an authoritative `exclude` page contains it
    again, and `remove` clears the mark, so delete cannot resurrect a row.
  - `installCached`/`markLoadUnavailable` retain the count, because a failed list
    read must not make the count look unknown.
  - Capability comes only from a live handshake (`system.info`), matching every
    other capability-gated surface; a cached count contributes only once the
    owning profile is actually capable.
- Deviations: the plan's "a profile that is offline ... contributes nothing" is
  implemented as "a profile with no known count contributes nothing". A capable
  profile whose last-known count came from the cache or a failed read still
  contributes it, which is the point of persisting the count; an incapable or
  never-observed profile contributes nothing and is never shown as zero.
- For the next agent: I-2 consumes `model.archivedSessionCount`,
  `model.supportsSessionArchive(profileID:)` and
  `model.loadArchivedSessions(profileID:cursor:presentationActive:)`, and must call
  `model.invalidateArchivedSessionsReads(profileID:)` after deleting from the
  container. `markArchived` invalidates in-flight loads, so a refresh is required
  after archive; the Gateway's `session.listChanged` already triggers it.

### I-3 · Done · 2026-09-26 · tron-coordinator

- Result: search, the automation form, and chat now show Gateway-owned archive
  state without owning it. `SessionSearchResult` carries `archived` and the
  search group renders one **Archived** label for the session; opening a result
  changes nothing. `AutomationFormView` and `AutomationDetailView` name a saved
  target that the dashboard projection cannot hold (archived rows are excluded
  from it by contract) by reading the owning Gateway's archived projection, so
  the target is never empty or invalid; the picker keeps taking its input from
  `model.visibleSessions`, which excludes archived rows. `SessionContextSheet`
  shows an **Archived** row with an explicit Unarchive action for the presented
  session, and sending a message still needs no confirmation because G-2 clears
  the archive before admitting the run.
- Decode decision (the G-3 note): `archived` decodes as
  `decodeIfPresent(Bool.self) ?? false`. The field is additive, and search is
  reachable against a Gateway older than the archive contract; the existing
  rows already use this exact pattern for additive booleans and enums
  (`hasActiveSubagents ?? false`, `kind ?? .user`). A required field would make
  the whole search response undecodable against that Gateway, which is a
  regression rather than a compatibility shim.
- Failure modes written before the isolated tests (the Gateway lifecycle test
  cannot reach them):
  - FM-1 a required `archived` field fails the whole search decode against an
    older Gateway, or the flag never reaches the row/group label;
  - FM-2 the chat's archive label reads a stale fact — a session that has
    unarchived (its row returned to the dashboard) still shows Archived, or a
    session opened from the container/search is not labeled;
  - FM-3 the archived-target name comes from an unbounded page walk, from the
    dashboard bucket, or is invented for a non-archived/incapable Gateway.
- Evidence (verified):
  - `scripts/tron-ios-test build` (scoped `TRON_IOS_TEST_DERIVED_DATA`):
    TEST BUILD SUCCEEDED.
  - `scripts/tron-ios-test run --only-testing TronMobileTests/AppModelCatalogSyncTests
    --only-testing TronMobileTests/SessionSearchTransportTests`: 34 tests plus
    dynamic-parameter runs passed in run `20260926T111256Z-run.GXWRTS`
    (`~/Library/Developer/Tron/ios/test-runs/`). The four new tests: two
    AppModel cases (FM-2/FM-3, including the 5-page bound and the
    incapable-Gateway no-read control) and one transport case (FM-1, decoding a
    response that both includes `archived: true` and omits the field entirely).
  - Negative control for FM-2 is inside the first case: the same session stops
    being labeled once an authoritative `exclude` page returns its row, and a
    deletion clears the observation.
  - `python3 scripts/check-documentation-policy.py` and
    `scripts/personal-info-guard.sh` pass.
- Changes: this commit (`SessionSearchModels.swift`, `AppModel.swift`,
  `DashboardStateOwners.swift`, `SessionSearchCoordinator.swift`,
  `SessionShellView.swift`, `SessionContextSheet.swift`,
  `AutomationFormView.swift`, `AutomationDetailView.swift`, the two owning test
  files, and `packages/ios-app/docs/architecture.md`).
- Kept on purpose:
  - The chat's archive fact is a bounded per-profile observation list (256
    newest IDs) fed by the archive response, an archived page, and search
    evidence. The dashboard projection stays authoritative for a live row, so a
    run that unarchives a session clears the label without any extra read. No
    second archive store, no per-session Gateway read (which the frozen Gateway
    does not have).
  - The search label is one capsule on the session group header rather than one
    per passage row: every passage in a group is the same session, so repeating
    it would add noise without information.
  - The archived-target read reuses the container's `loadArchivedSessions`, so it
    shares that read's latest-request fence. A container read in flight is
    retired and reloaded, and this lookup can itself be retired (then it keeps
    the existing fallback name); a dedicated fence would have been a second
    read owner for the same projection.
  - The automation target keeps its exact `sessionId`; only the display name
    changes, and the form's picker is disabled (not hidden) when an archived
    target is the only session, so an empty picker cannot be opened.
- Deviations: the plan's chat requirement names "the Archived container" as an
  opening surface; I-2 owns the container tap, and this task records the archive
  evidence in the two route builders (`navigationRoute(for:)` and
  `navigationRoute(profileID:sessionID:...)`) plus the archived page read, so a
  container-opened chat is labeled whichever builder I-2 uses, with no I-2
  interface change.
- For the next agent: the I-2 dashboard container is still the only surface with
  archive controls; V-1 should confirm on device that an archived session opened
  from the container shows the Manage Session row. The concurrent I-2 session
  held the shared test-simulator lease for most of this task, and several
  unrelated runs in both worktrees failed with `dyld ... _dyld_sim_prepare`
  (EXC_BAD_ACCESS) before the test host bootstrapped; my focused suites passed
  in the run named above, and the extra regression suites
  (`SessionMutationServiceTests`, `SessionSearchCoordinatorTests`,
  `SnapshotCacheTests`, `DashboardStateOwnerTests`) should be re-run at V-1.

### I-2 · Done (hosted journey unverified) · 2026-09-26 · tron-coordinator

- Result: the dashboard owns archiving and the archived container. The session
  row's trailing swipe is one shared modifier (`sessionRowTrailingSwipe`): Archive
  is the full-swipe action with a neutral tint and appears only for a Gateway that
  advertises `session-archive.v1`, Delete keeps its confirmation, Rename is
  unchanged, and the leading Mark Read/Unread swipe is untouched. One collapsed
  `Archived (N)` section sits after every workspace group in both dashboard sort
  modes and stays hidden until a capable Gateway publishes a non-zero count. Its
  owner (`ArchivedSessionsContainerState`) pages `archived: "only"` from every
  connected capable server under the caller's managed activity and the model's
  per-profile latest-request fence, retires every in-flight page on collapse or a
  profile switch, names an unreachable or failed server inline instead of showing
  stale rows, drops rows/cursors for a server it can no longer read, and offers
  Unarchive (full swipe) and Delete (the dashboard's own confirmation, which
  invalidates that server's archived reads). A Gateway list change refreshes the
  count and, while expanded, the pages.
- Failure modes written before the isolated tests (the hosted journey cannot
  reproduce them):
  - FM-1 a page from a superseded expansion generation is published after a
    collapse;
  - FM-2 a `.retired` read publishes rows or marks the server unavailable;
  - FM-3 a malformed page publishes rows instead of naming the server;
  - FM-4 a server that is no longer capable or connected keeps rows, cursors, or
    reads;
  - FM-5 paging reads a disconnected server or reports more pages than exist;
  - FM-6 removing one server's row drops an equal session ID owned by another
    server.
- Evidence (verified):
  - `scripts/tron-ios-test build` (unit tier): TEST BUILD SUCCEEDED; the
    ui-validation tier build also succeeded.
  - `scripts/tron-ios-test run --only-testing TronMobileTests/DashboardStateOwnerTests`:
    44/44 passed, including the three new archived-container cases.
    Retained bundle: `~/Library/Developer/Tron/ios/test-runs/20260926T120537Z-run.itlxjC`.
  - Not verified: the new hosted journey
    `TronSmokeUITests.testSessionArchiveSwipeAndArchivedContainerJourney` did not
    pass. First run hung at app launch and hit the process deadline (status 75);
    the second run reached the assertions but the app never reported an idle
    event loop ("App event loop idle notification not received"), so every element
    query timed out (`Failed to get matching snapshots`) before the first
    screenshot. The same machine produced `dyld_sim _dyld_sim_prepare` SIGBUS
    crashes and launch hangs for other sessions during the same window. The
    journey, its fixture, and its screenshots still need one run on a healthy
    simulator; treat I-2's UI proof as open.
- Changes: this commit (`ArchivedSessionsSection.swift`, `SessionRowSwipeActions.swift`,
  `HostedSessionArchiveFixture.swift`, `SessionShellView.swift`,
  `DashboardStateOwners.swift`, `TronMobileApp.swift`,
  `DashboardStateOwnerTests.swift`, `TronSmokeUITests.swift`,
  `packages/ios-app/docs/architecture.md`).
- Kept on purpose:
  - Archive applies only the authoritative response. Nothing is staged locally:
    the row leaves the dashboard when the Gateway's own list change lands, and a
    collapsed container never reads archived pages.
  - The archived container is not filtered by the dashboard server filter,
    because the count it presents is the Gateway's unfiltered projection.
  - Archived rows reuse `HistoricalSessionRow` and the dashboard's layout
    constants (both made internal) so the container cannot grow a second row
    design.
- Deviations: the container renders its rows and its Unarchive/Delete swipes
  through a dedicated section view rather than extending `sessionButton`, which
  would have coupled an archived row to the workspace-group and rename flows that
  do not apply to it. The `archive` action is not offered for a row whose
  `gatewayProfileID` is unknown, since capability is per server.
- For the next agent: re-run the hosted journey before V-1's eyes-on review.
  I-3 owns the search annotation, the automation picker, and the chat-surface
  archived state.

### F-3 · Done · 2026-09-26 · archive worker

- Result: the chat's archive state is the Gateway's own projection. A live
  session's snapshot carries `archivedAt` (present while archived, absent while
  visible), read from `RuntimeRegistry.archivedAt` — the effective projection
  that already honours a pending restoration — through a new `archivedAt`
  slot-side dependency, and a committed archive change republishes that slot's
  snapshot through the existing `archiveChanged` path (the same shape as
  `refreshCompactionPolicy`). `AppModel.observedArchivedSessionsByProfile`,
  `maximumObservedArchivedSessions`, `observeArchivedSessions`,
  `isSessionArchivedForPresentation` and their call sites are deleted;
  `SessionContextSheet` reads `SessionContextPresentation.archivedAt`, which is
  derived from the decoded snapshot, so the Manage Session archive row needs no
  second read and no parallel state. The automation target lookup
  (`archivedSessionSummary`) stays: it names a session the dashboard projection
  cannot hold, which a snapshot of an unopened session cannot answer.
- Evidence (verified):
  - `npm run build` clean.
  - `npx vitest run src/transport/session-archive.integration.test.ts`: 20/20 in
    5.9 s. New case "carries archive state on the opened snapshot and republishes
    it on every change": an archived session's `session.open` snapshot already
    carries the exact `archivedAt`; unarchiving republishes the subscribed
    client's snapshot without the field; archiving a live idle session
    republishes it with the field; the prompt that clears the record sees a
    snapshot without it. Retained, regenerable report:
    `test-results/session-archive.integration.json` in the gateway package.
  - Negative controls: removing the `archivedAt` snapshot field fails the case
    (`expected undefined to be '2026-09-26T12:34:07.522Z'`); removing the slot
    republish from `archiveChanged` fails the same case at the republish
    assertion. Both restored.
  - `npx vitest run src/sessions/runtime-registry.integration.test.ts
    src/transport/sync-protocol.integration.test.ts
    src/transport/session-list-pagination.test.ts
    src/transport/server-terminal-delete.integration.test.ts`: 257/257 in 45.2 s.
    `session-archive-store`, `session-attention-store`,
    `gateway-service-transcript`, `command-receipts`,
    `runtime-terminal-notifications`, `session-search-service`: 64/64 in 2.1 s.
  - `scripts/tron-ios-test build` (scoped `TRON_IOS_TEST_DERIVED_DATA`):
    TEST BUILD SUCCEEDED.
  - `scripts/tron-ios-test run --only-testing
    TronMobileTests/AppModelCatalogSyncTests --only-testing
    TronMobileTests/SessionPresentationStoreTests --only-testing
    TronMobileTests/SessionMutationServiceTests --only-testing
    TronMobileTests/DashboardStateOwnerTests`: 143 tests in 4 suites passed
    (`~/Library/Developer/Tron/ios/test-runs/20260926T123344Z-run.l520P7`). The
    removed-API test (`archivedPresentationProjection`) and its now-unused
    `mutationRequest` helper are gone; the archive count, container-read fence
    and automation-target cases remain.
  - `python3 scripts/check-documentation-policy.py` and
    `scripts/personal-info-guard.sh` pass.
- Changes: this commit (`packages/gateway/src/protocol/types.ts`,
  `packages/gateway/src/sessions/runtime-slot.ts`,
  `packages/gateway/src/sessions/runtime-registry.ts`,
  `packages/gateway/src/transport/session-archive.integration.test.ts`,
  `packages/gateway/README.md`, `packages/ios-app/Sources/Models/SessionRuntimeModels.swift`,
  `packages/ios-app/Sources/State/AppModel.swift`,
  `packages/ios-app/Sources/UI/Chat/SessionContextSheet.swift`,
  `packages/ios-app/Tests/Gateway/AppModelCatalogSyncTests.swift`,
  `packages/ios-app/docs/architecture.md`, and this plan).
- Tasks added: none.
- Kept on purpose:
  - `refreshArchiveProjection` does not take the session lane, exactly like
    `refreshCompactionPolicy`; the archive commit already owns whichever lane
    ordered it, and taking the lane again would deadlock a backstop that runs
    inside the slot's own publication. The backstop therefore queues its
    republish with `queueMicrotask` instead of re-entering the publisher.
  - Only the four call sites that can have a live slot pass the session ID to
    `archiveChanged`; startup pruning passes none (no slots exist yet), and the
    durable removal in `clearArchivedRecord` passes none because dropping the
    in-memory override does not change the projection the store already
    reported.
  - The fixture now forwards slot broadcasts to the server, mirroring
    `gateway-main`, so the new case observes real `session.snapshot` frames;
    this is fixture fidelity, not a test hook.
- Deviations: the chat's archive row is no longer covered by an iOS unit test.
  The removed case asserted the parallel-state API that this task deleted, and a
  replacement unit test would only reassert a decoded passthrough; the contract
  is covered by the Gateway integration case and remains listed for V-1's
  eyes-on review.
- For the next agent: F-4 (the hosted UI journey) is next. V-1 should still
  confirm on device that an archived session opened from the container shows the
  Manage Session row, now fed by the snapshot.

### F-4 · Done · 2026-09-26 · archive worker

- Result: the hosted journey passes and keeps its three screenshots. Two causes,
  both in the fixture and the journey rather than the simulator: (1) the fixture
  rendered the production row without declaring a branch presentation activity,
  so it inherited the no-coordinator `.active` fallback and ran the dashboard's
  one-second `TimelineView` row clock, which kept the app busy so XCUI never
  observed quiescence; the fixture now declares `PresentationSurfaceActivity.covered`
  (the surfaces under test read no presentation activity, so only the row's
  relative-time clock changes). (2) The fixture applied the row identifier and
  swipe modifier to `HistoricalSessionRow` instead of to a row `Button`, so
  `session-row-<id>` was an `Other` element while the journey queried `buttons`;
  the fixture now mirrors the dashboard's own row button. The journey's drag was
  also completing the full-swipe Archive instead of revealing the actions, so the
  reveal drag is bounded at 38% of the row width.
- Evidence (verified):
  - Control first: `TronSmokeUITests/testAgentDefaultsThinkingSliderOpensAfterDefaultsConsolidation`
    passed (9.3 s) on the same owned simulator, so the environment was healthy
    before the archive journey was diagnosed.
  - The journey passed in three consecutive runs: 20.7 s, 20.5 s, 20.5 s.
    First passing run: `~/Library/Developer/Tron/ios/test-runs/20260926T124536Z-run.bWDqZI`.
  - Screenshots exported from that xcresult with
    `xcrun xcresulttool export attachments` and copied to the Tron workspace's
    `session-archive/` files area as `session-archive-container-collapsed.png`,
    `session-archive-container-expanded.png` and
    `session-archive-unarchived.png`. Visual inspection confirms the workspace
    with only the `Archived (1)` container, the expanded archived row, and the
    restored workspace row with the container gone.
  - `scripts/tron-ios-test build` for the ui-validation tier: TEST BUILD
    SUCCEEDED (scoped `TRON_IOS_TEST_DERIVED_DATA`).
  - `python3 scripts/check-documentation-policy.py` and
    `scripts/personal-info-guard.sh` pass.
- Changes: this commit (`packages/ios-app/Sources/App/HostedSessionArchiveFixture.swift`,
  `packages/ios-app/UITests/TronSmokeUITests.swift`,
  `packages/ios-app/docs/development.md`, and this plan).
- Tasks added: none.
- Kept on purpose:
  - The fixture still renders the production row, swipe modifier and archived
    section instead of synthetic stand-ins, so the journey exercises the real
    identifiers and the real full-swipe/partial-swipe configuration. Only the
    branch activity and the row's button wrapper changed.
  - The journey keeps its three screenshot names and its assertions on the
    container count, the archived row, and the restored workspace row.
- Deviations: the drag distance is a bounded constant, not a measured gesture
  model. It reveals the trailing actions without crossing UIKit's full-swipe
  threshold on the canonical iPhone 17 Pro simulator; a future geometry change to
  the row or actions could require re-tuning it.
- For the next agent: F-3 and F-4 are done, so V-1 is the only remaining row. It
  still needs the full gateway suite, `scripts/ios-gateway-e2e-test run`, the
  user-performed Gateway rollout, and the eyes-on device review.

### F-1 · F-2 · Done · 2026-09-26 · tron-coordinator

- Result: a receipt-backed mutation no longer rejects itself. `GatewayService.mutation`
  holds one `rpc-mutation` GatewayWorkRegistry entry for the whole operation, and
  the session idle check counted that entry, so every idle-checked mutation
  returned retryable `busy` for its own request. The check now excludes exactly
  the initiating request's token. `RuntimeSlot.assertIdle(allowTrustReload,
  exceptWorkToken)` resolves through a private `drainBusyExcept(token)` helper, so
  `isDrainBusy` keeps its exact previous meaning (work entries plus administrative
  drain blockers) and only the eight idle-checked mutation handlers pass their
  token: `session.bash`, `session.setThinking`, `session.setTools`,
  `session.setContextWindow`, `session.label`, `session.fork`,
  `session.navigate` and `session.reloadResources`. Nothing else is excluded:
  another request's entry, detached extension work, administrative drain blockers,
  a running prompt and a streaming session all still reject them.
- Audit of every `this.mutation(...)` case in `gateway-service.ts`
  (58 call sites) for a handler that reaches a slot/registry method consulting
  session work ownership:
  - Fixed (reached `RuntimeSlot.assertIdle` → `isDrainBusy` → `hasSessionWork`):
    `session.bash`, `session.setThinking`, `session.setTools`,
    `session.setContextWindow`, `session.label`, `session.fork`,
    `session.navigate`, `session.reloadResources`.
  - Already correct: `session.setModel`
    (`assertModelChangeIdle(initiatingWorkToken)`), `session.archive.set`
    (`RuntimeRegistry.setArchived` → `commitArchiveWhileIdle(token)`),
    `session.delete` (`RuntimeRegistry.delete` → `isBusyExceptWorkToken(token)`).
  - Not affected: `session.prompt`, `session.abort`, `session.clearQueue`,
    `session.queue.replace`, `session.compact` (`assertIdleForManualCompaction`
    consults no work entry), `session.rename`, `session.reloadResources`' sibling
    reads, `extension.respond` and the remaining mutation RPCs, none of which call
    `assertIdle`/`isBusyExceptWorkToken`.
  - Not a mutation RPC and deliberately unchanged:
    `RuntimeSlot.beginTrustReload()` (trust-service path, no request token) and
    `reload`'s registry trust-transition call site, which still pass no token.
- Evidence (verified):
  - `npm run build` clean.
  - `npx vitest run src/transport/rpc-idle-admission.integration.test.ts`: 2/2 in
    7.4 s over the real WebSocket, `GatewayService`, `RuntimeRegistry` and faux
    provider. Case 1 drives all eight fixed RPCs on an idle session and asserts
    each is admitted, including a real Bash result and a real fork to a new
    session ID. Case 2 is the negative control: a running prompt rejects four of
    them with `busy`, and a concurrently in-flight Bash RPC still rejects
    `session.setTools` with `busy` after the run settles. Report:
    `test-results/rpc-idle-admission.integration.json`.
  - Negative control for the fix itself: with the two source files reverted
    (`git stash push -- runtime-slot.ts gateway-service.ts`), case 1 fails on its
    first RPC with `busy`/`Session must be idle for this operation` and case 2
    fails waiting for the held Bash run. Restored, both pass.
  - `npx vitest run src/transport/session-archive.integration.test.ts`: 20/20 in
    5.9 s, now driving the real `session.bash` and `session.fork` RPCs.
  - `npx vitest run` over `rpc-idle-admission.integration.test.ts`,
    `session-archive.integration.test.ts`, `runtime-registry.integration.test.ts`,
    `sync-protocol.integration.test.ts`, `gateway-work-registry.test.ts` and
    `restart-drain.test.ts`: 280/280 in 48.0 s.
  - Full `npx vitest run`: 1943 passed, 2 failed. `gateway-context-window.test.ts`
    failed on the new trailing token argument and was updated; the other two are
    unrelated flakes (`logger.test.ts` segment rotation,
    `recent-model-usage.integration.test.ts`, both of which also fail on `main`
    or pass in isolation).
  - `python3 scripts/check-documentation-policy.py` and
    `scripts/personal-info-guard.sh` pass.
- Changes: this commit (`packages/gateway/src/sessions/runtime-slot.ts`,
  `packages/gateway/src/transport/gateway-service.ts`,
  `packages/gateway/src/transport/rpc-idle-admission.integration.test.ts`,
  `packages/gateway/src/transport/session-archive.integration.test.ts`,
  `packages/gateway/src/transport/gateway-context-window.test.ts`,
  `packages/gateway/README.md`, and this plan).
- Tasks added: none.
- Kept on purpose:
  - `isDrainBusy` keeps its original two conditions. Folding
    `hasRuntimeWork`/detached-dashboard work into it looks tidier but changes
    drain semantics: `runtime-registry.integration.test.ts`'s paused-workflow
    drain case then times out because a paused detached activity keeps
    `isDrainBusy` true forever. The token exclusion therefore lives in
    `drainBusyExcept` only, which is stale-free for the idle check as well: it
    matches the pre-existing `assertIdle` conditions exactly.
  - No new flag, mode or optional "allow busy" parameter: the token is the
    existing owner identity, and every call site that has no request token keeps
    the previous behavior.
- Deviations: `session.reloadResources` was not in the F-2 row's measured list
  but reaches `RuntimeSlot.reload` → `assertIdle`, so it is fixed with the others.
  The archive integration test's Bash and fork workarounds were replaced by the
  real RPCs, which is how the G-2 deviation is now closed.
- For the next agent: V-1 remains, and it still needs the full gateway suite,
  `scripts/ios-gateway-e2e-test run`, the user-performed Gateway rollout, and the
  eyes-on device review. Note that the iOS app's own full-swipe Archive action
  and the archived container were validated against the UI fixture, not a device.

### F-5 · Done · 2026-09-26 · tron-coordinator

- Result: the flake was not in the archive behavior oracle. The failing
  assertion was the fixture's `afterEach` cleanup: `rm(root, { recursive: true,
  force: true })` threw `ENOTEMPTY: directory not empty, rmdir
  '<root>/gateway'`, which vitest attributes to whichever test's cleanup ran
  (observed on "rejects a prompt retryably when archive state cannot be
  cleared" and on "clears archive state when Bash is admitted"). Root cause is a
  product ownership gap, not a test-ordering bug: a catalog read persists the
  `gateway/catalog-metadata-v2.json` acceleration index fire-and-forget
  (`materializeCatalogSnapshot` → `void this.persistDurableCatalogIndex(...)`,
  `runtime-registry.ts`), whose temp file is created in that same `gateway`
  directory and renamed onto the final path later. `RuntimeRegistry.dispose()`
  shut down slots and the blob/export/workspace stores but never awaited this
  index, so the write (and its directory entry) could land after disposal had
  returned, racing whoever removes the state directory — exactly what a fixture
  cleanup, a reinstall, or an owner-side directory replace does. Fix at the
  owning boundary: `CatalogMetadataIndex.dispose()` sets a closed flag and
  drains its `writeMutex` (refusing writes that had not started), and
  `RuntimeRegistry.disposeSharedStores()` awaits it.
- Evidence (verified), node `v25.9.0` via `PATH=/opt/homebrew/bin:$PATH`:
  - Reproduction of the reported failure (baseline, before the fix): 4
    concurrent runs of this file, 6 rounds = 24 runs → 5 case failures, every
    one `Error: ENOTEMPTY: directory not empty, rmdir '<tmp root>/gateway'`
    (3 × "clears archive state when Bash is admitted", 2 × the persist-failure
    case). It had also appeared in a full-suite run on this branch
    (`Tests 3 failed | 1942 passed (1945)`, this case next to the two unrelated
    flakes) and once in the coordinator's four full-suite runs. Six sequential
    full-suite runs did not reproduce it (only the known
    `logger.test.ts`/`recent-model-usage.integration.test.ts` flakes failed),
    which is why the load-dependent 4-concurrent stress above is the
    reproduction method, not the suite itself.
  - Mechanism evidence: a temporary probe that snapshotted the
    `gateway` state directory (name, inode, size, mtime) 250 ms after each
    `registry.dispose()` plus an `fs.watch` log of the rm window, run over 32
    concurrent runs (640 cleanups): 45 late-write windows, **every one** the
    catalog index (`catalog-metadata-v2.json` created/renamed, or its
    `catalog-metadata-v2.json.tmp-<pid>-<uuid>` temp file replaced). No other
    store wrote after disposal.
  - After the fix, the same probe and load: 0 late-write windows in 640
    cleanups (32 concurrent runs).
  - After the fix, the original uninstrumented reproduction: 12 rounds × 4
    concurrent runs of this file = 48/48 runs, 960/960 cases passed, 0
    failures (baseline 5 failures / 24 runs).
  - After the fix, full `npx vitest run` twice: `1945 passed | 1 failed` both
    times, the single failure being the unrelated pre-existing
    `logger.test.ts` "rotates across eight 5 MB segments" flake (it also failed
    6/6 full-suite runs on this branch before the change; the other known flake,
    `recent-model-usage.integration.test.ts`, passed in both).
  - Focused regression: `catalog-metadata-index.test.ts` 16/16, including the
    new "settles an in-flight save before disposal and refuses later writes"
    (5/5 repeat runs). Negative controls, each restored afterwards: removing the
    disposal drain fails the case deterministically 3/3 (the document is not yet
    published when disposal resolves; the failure output shows the
    `.tmp-<pid>-<uuid>` → `catalog-metadata-v2.json` rename still pending), and
    removing the closed flag fails it deterministically (`expected true to be
    false` — the post-disposal save wrote anyway).
  - `python3 scripts/check-documentation-policy.py` and
    `scripts/personal-info-guard.sh` pass.
- Changes: this commit (`packages/gateway/src/sessions/catalog-metadata-index.ts`,
  `packages/gateway/src/sessions/catalog-metadata-index.test.ts`,
  `packages/gateway/src/sessions/runtime-registry.ts`,
  `packages/gateway/README.md`, and this plan).
- Tasks added: F-6.
- Kept on purpose:
  - The read path still persists the index without awaiting it: awaiting
    acceleration in every catalog read would put a disk transaction on the list
    path for no authority gain ("persistence is acceleration only"). Only
    disposal gained ownership of the write.
  - The archive integration test and its oracle are unchanged: the fix is
    entirely in the owning product boundary, so no assertion was weakened,
    retried, or removed to make the report green.
  - The fixture cleanup has no `rm` retry. Adding `maxRetries` would mask the
    real cause; the probe found no writer other than the drained index.
- Deviations: none in the archive behavior itself. The task's suggested
  hypotheses (a second admission path, a backstop calling the real `remove`, a
  republish leaving the slot busy, the monkeypatch restored too early) were all
  eliminated: every late write belonged to the catalog index.
- For the next agent: V-1 remains and still needs the full gateway suite,
  `scripts/ios-gateway-e2e-test run`, the user-performed Gateway rollout, and
  the eyes-on device review. F-6 records the same fire-and-forget pattern on
  `model-recents.json`, which this task's probe did not observe (it lands early
  in these cases) but which is unowned at disposal for the same reason.
