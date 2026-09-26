# Session archive

- **Started:** 2026-09-26
- **Status:** Active
- **Last updated:** 2026-09-26, G-2
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
| G-3 | Claimed | Search results carry `archived`; `session-search.md` updated | G-1 | tron-coordinator, 2026-09-26 |
| I-1 | Claimed | iOS model, mutation service, AppModel and capability gating; catalog membership follows authoritative responses | G-1 | tron-coordinator, 2026-09-26 |
| I-2 | Ready | Dashboard full-swipe Archive, one collapsed "Archived (N)" container at the bottom, and archived-row actions | I-1 | |
| I-3 | Ready | Search "Archived" label, automation picker exclusion, and display of an existing automation whose target is archived | I-1, G-3 | |
| F-1 | Needs scoping | The `session.fork` RPC rejects with retryable `busy` because its own admitted work entry satisfies the slot's idle check; decide the fix and cover the real path | none | |
| F-2 | Needs scoping | The same self-work-entry rejection now also measured on `session.bash`, `session.navigate` and `session.setTools`; audit every mutation RPC whose slot method consults session work ownership and decide the fix (thread the request's work token, as `session.setModel` already does) | none | |
| V-1 | Ready | Cross-module checkpoint, user-performed Gateway rollout, and eyes-on device review; close the plan | G-2, I-2, I-3 | |

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
