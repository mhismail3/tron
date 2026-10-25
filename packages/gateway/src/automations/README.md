# gateway/automations

## Purpose

The Gateway is the sole scheduler and canonical owner of durable automations:
definitions, triggers, the run ledger, dispatch into sessions and settlement. Pi
extensions and subagents may run inside a scheduled turn but own no timer,
definition, retry or ledger. iOS and the first-party `schedule` tool are clients.

## Owns

`automation-service.ts`, `automation-scheduler.ts`, `automation-executor.ts`,
`automation-store.ts`, `automation-timeline.ts`, `schedule.ts`,
`schedule-module.ts` (optional-owner descriptor) and `tron-schedule-extension.ts`. Store: `gateway/automations/`, strict schema-version-2
owner-only documents, each with one definition, at most one nonterminal run and 64
retained terminal runs. Older shapes are not admitted, migrated or projected. Writes
sync the file and its directory before acknowledgement.

## Contract

- **Triggers** (`automations.v2`): one-time, anchored interval, and IANA-timezone
  daily/weekly. Calendar gaps advance to the first valid minute; repeated minutes take
  the earlier instant. Misfire `latest`|`skip`; overlap `skip`|one `queueLatest`.
  Recurrence advances from schedule time, not completion; clock movement never
  recreates a recorded occurrence. Catch-up, history, batches, timers, prompts,
  storage and concurrency are bounded.
- **Targets**: one existing persisted user session (prompts and notifications), or one
  Gateway-canonical workspace with `newPerRun` sessions (prompts only, intervals of at
  least 24 hours, since generated sessions are never auto-deleted). Workspaces must
  exist and have a resolved trust decision; Automations create no directories,
  worktrees or branches.
- **Dispatch.** Every run snapshots its target and concrete session ID before dispatch
  (workspace runs get a predetermined UUID created through
  `RuntimeRegistry`/`RuntimeSlot` via `OwnedSessionDispatch`). Scheduled prompts never
  steer or enqueue into an active turn; a busy target waits durably. Resource actions
  revalidate the typed skill or prompt inside the slot and carry automation
  provenance. Extension commands, attachments, shell, webhooks, deployment and Gateway
  lifecycle are not automation capabilities; RuntimeSlot rejects scheduled text that
  resolves to an extension command before any effect.
- **Settlement.** Occurrences and runs are durable before dispatch. Pre-admission
  transient failures retry with bounded backoff; accepted agent failures do not.
  Accepted work without exact terminal evidence becomes `outcomeUnknown`, blocks
  future occurrences and needs an explicit receipt-backed resolution (refused until
  its process-local owner retires). Successful completion stays marked until the
  terminal record is durable, so recovery finishes settlement without replaying.
  Three consecutive definitive failures open a circuit breaker. Running work has an
  exact operation-fenced cancellation and deadline, not a pause.
- **RPCs.** Reads: `automation.status`, `.list` (no action bodies; paged under an
  opaque catalog lease), `.get`, `.schedule.preview {trigger, after?, limit 1–20}`
  (never writes), `.timeline.list`, `.run.list`, `.run.get`. Receipt-backed:
  `automation.create`, `.update`, `.enable`, `.pause`, `.delete`, `.runNow`,
  `.run.cancel`, `.run.resolve`. Definitions use revision fences; scheduler state has
  its own revision. `automation.changed` is only an invalidation hint.
- **Timeline** (`automations.timeline.v1`, advertised once recovery is ready):
  `{from, through, displayTimezone, cursor?, limit 1–200}` over at most seven days,
  grouped by local day; a cursor is bound to the client, window and revision and
  expires after a minute. More than twelve occurrences of one automation in a day
  become one `series` item, counted analytically across DST. Overflow is an explicit
  retryable error, never dropped occurrences.
- **`schedule` tool** targets its own persisted session or a new session in its
  workspace, dedupes by tool-call identity, and refuses mutations from an
  automation-originated turn. Paired credentials are machine-administrator
  credentials, so any paired client may manage any automation.
  Composition supplies the canonical receipt owner's existing mutation operation;
  this tool owns no receipt lane or completion policy. Diagnostics use the shared
  module log port, not a transport logger dependency.

## Invariants

- A crash before canonical invocation or marker evidence may requeue the same run; a
  run never creates a second session or writes Pi's JSONL.
- Startup reconciles targets and runs before dispatch opens; a malformed record stays
  untouched and disables dispatch for that evidence.
- Shutdown and drain close the scheduler synchronously, cancel pending admissions
  and join dispatch through terminal acknowledgement; an expired wait reports a
  blocker, never successful retirement.
- Timer arming derives from one catalog snapshot, never shared across writes.

## Entry points

`AutomationService` (RPCs), `AutomationScheduler` (timers, catch-up),
`GatewayAutomationExecutor` (dispatch), `tron-schedule-extension.ts` (the tool).

## Signals

| Signal | Level | Meaning |
|---|---|---|
| `automation.dispatch-failed` | warning | Dispatch, recovery or settlement failed (`automation-diagnostic.ts`): `referenceHash` (automation ID, or `scheduler` for a scan) and optional `operationHash` (run ID), 16 hex characters of SHA-256 |
| `automation.recovery-step` | info | One part of recovery finished: `step` (`store`, `reconcile-targets`, `scheduler-recover`), `durationMs`; target count and slowest target kind in the message |
| `automation.recovery-deferred` | warning | Initialization ran before the catalog's first cut, so targets are re-checked next start: `reason=catalog_not_ready` |

## Verify

```bash
scripts/tron verify --module gateway/automations
scripts/tron test gateway src/automations/automation-scheduler.integration.test.ts
```

`automation-scheduler.integration.test.ts` uses the real executor, SDK and canonical
JSONL: fresh success, reserved-run cancellation, unreserved drain-time cancellation,
durable reopen and explicit successor. Behavior locks:
`automations.store.lock.integration.test.ts` and `automations.owned-run.lock.integration.test.ts`
(a session and a workspace prompt run now through the owned-session boundary on the real
Gateway: provider requests, JSONL, frames, records and command receipts).
`tests/automation-rpc.lock.integration.test.ts` adds real-socket schedule preview,
list and timeline admission: connection/window/revision-scoped cursors, stale-write
refusal, actual wall-clock lease expiry and restart invalidation with persisted
records. It waits the real 60-second lease, using unrelated status reads to keep
the socket live without renewing that lease; no clock or timer is mocked.
Its disposable trace is `test-results/automation-rpc/trace.json`.

## Not here

Session lanes and owned dispatch: [gateway/run](../sessions/README.md). The iOS
Automations UI: `packages/ios-app`.
