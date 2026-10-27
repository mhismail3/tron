# Home tasks

Owner: [gateway/home](README.md). Home delegates finite project work through `delegate` into
ordinary worker sessions; each worker seals an immutable report, and results reach Home through
the wake inbox. The contract spans the Home owner, RuntimeSlot and `DelegationOperations`, the
managed subagent provider and the iOS task surfaces. Signals: [home module](README.md#signals).

## Persistence

`HomeTaskStore` owns `<tronHome>/gateway/home/tasks/` (0700; files 0600, bounded, read without
following symlinks).

- The first dispatch publishes an empty `authorization.json`, then
  `gateway/workspace-state/home-tasks-initialized.json` (`{ "version": 1 }`), then enables the
  initial trusted-project scope; startup never initializes. A partial setup is refused; later a
  missing namespace, marker or authorization file is lost state.
- A task is `tasks/<13-digit-createdAt>-<taskId>.json` (≤ 256 KiB), strict v1: `version`,
  `taskId`, `revision` (create 1, replace at expected + 1), store-owned `createdAt`/`updatedAt`,
  immutable `homeId`, `generation`, `routeGeneration`, `intent` (`{ text }` ≤ 64 KiB) with
  SHA-256 `intentDigest`, absolute `target` (≤ 4 KiB, not authority), `grantRef` or `scopeRef`,
  `lifecycle` (`pending | active | terminal`), `sessionId`, `operationId`, `stopIntent`
  (never replaced), `spend` (fresh input, cache read and write, output tokens; never a cost),
  `budget` (`permissions.budget.task` at admission), `reportRef` (`{ resultId, sessionId, entryId, digest }`), `wake`, and `terminalEvidence` (`outcome` `progress | needs-input | final | limited | interrupted | unknown`, `final` needs a report; ≤ 256 entry IDs; `failureCause`
  only `provider-usage-limit` or `provider-error`).
- `authorization.json` (`HomeTaskAuthorization`): strict v1 `scopes`, `requests`, `decisions`,
  `grants`; ≤ 4 MiB and 10,000 records per array; each decision names one request once; each
  grant one approved decision with matching binding, expiry and epoch.
- Both files replace durably (temp, fsync, rename, directory fsync) before acknowledgement.
  Malformed or contradictory records keep their bytes and refuse (`home.task.store-refused`);
  an uncertain publication fences the instance until reload; startup removes only this user's
  crash-staged temp files. Creation filenames are permanent; lookup refuses duplicate
  suffixes; there is no index, cap, pruning or deletion. Terminal and authority fields are
  immutable; only WakeInboxOwner advances `wake`.
- **Authority epoch** = the task directory's `dev`, `ino` and birthtime: restart keeps it; a
  restore or copy changes it, so old scopes and grants are refused
  (`scope-reconfirmation-required`).

## Authorization

The standing scope covers any currently trusted project (trust re-resolved at admission),
bound to the epoch. Otherwise a task needs a one-use grant binding intent digest, target,
scope, expiry and epoch, consumed at admission; a `grant-required` refusal records the request
first and returns its `requestId`. Approval records the decision and one grant; a decided
request never mints another or replays the task. Revocation shares the consumption mutex and
does not stop admitted work. Only `home.reconfirmPermissions` re-stamps scopes. Only maintainer
RPCs list, revoke and decide.

## Worker progress check-ins

`checkin` (current worker operation only; never seals or pauses): `step` (256 bytes), `done`,
`next`, optional `blocker` (512 each), `refs` (`branch`, `commit`, `issue`), `needsAttention`;
≤ 4 KiB. Twelve entries are kept, three shown, carried to resumed successors. Routine
check-ins never wake or push. `needsAttention` needs a blocker and requests at most one wake per
30 minutes per lineage through a task outbox (`requested`, `rate-limited`, `pending`, `none`),
kept for a paused Home. Progress is never success evidence.

## Dispatch and workers

Home owns task budget resolution, trusted-target admission, launch queue selection and
model/thinking admission.
The dispatcher reads this stateless policy at the existing admission/turn cuts; settings,
the Gateway model runtime and generic queue IO stay with their canonical native owners.
Home memory selects its background queue over that same native queue reader.

Only the enabled Home's active chapter calls `delegate` with a stable `taskId`, bounded
`intent`, trusted `target` and optional `title` (≤ 80 characters, the worker session name). The
dispatcher records pending intent, authorizes the snapshot, creates the worker through
`DelegationOperations` and binds its operation before prompting; a task ID never replays.

- Each admission step has a 60 s deadline and follows the delegating turn's Stop; a refused
  step fails `delegate` and a pending task settles `unknown` (`admission-cancelled`,
  `admission-timeout`); slow steps log `home.task.dispatch-stage`. No worker cap; heavy steps
  wait in the host-wide queue ([host load](../../../docs/host-load.md)).
- Model: the first available `model.queue[role=worker]` (else Home's model) and
  `model.thinking[role=worker]` (else Home's), clamped; an explicit choice needs a `reason`.
  Choices are fixed in the brief and reported (`worker`, `subagentModels`; subagents default to
  `tron/subagent`). A usage limit moves to the next worker model in place.
- A worker has project tools plus `report` and a canonical `tron-home-task` marker checked
  before cold construction. A sealed report ends the task at that turn boundary; Stop is
  terminal (`task-stopped-before-delivery` receipts for unconsumed steers);
  `DelegationOperations` has a 24-hour ceiling. Individual reply completions update
  attention without stamping the task's root run marker. A notice or report reminder
  can continue the same invocation without conflicting with an earlier reply's
  completion. Terminal invocation cleanup or final task acknowledgement retires it.
- Workers (not Home) load the managed subagent provider; the task extension admits launches,
  reads, run controls and supervisor `reply` only for runs the task owns (by `id`/`runId`,
  never `dir`) and refuses missions, scheduling and non-blocking `bg_wait`, also in nested
  codemode. Trusted extensions are not a sandbox.

## Subagent runs

A task owns every run its worker starts (canonical launches, async runs by `asyncDir`, children
its workflows name); nothing extra is persisted.

- Settlement order: operation terminal; report stop joined; live runs stopped and joined;
  completion notices recorded; `tron-home-task-subagents` fact (`{ receiptId, operationId, stoppedAtEnd }`, only if async runs launched); evidence cut; outcome. The join is bounded by
  one minute (or the 24-hour deadline) plus 5 s; a run still live makes the task `unknown`
  (`detached-work-outlived-task`). Undelivered `subagent-notify` messages count as
  `noticesUndelivered`.
- A normal stop turn without a report while owned work is live keeps the operation open; the
  provider's wake starts the next turn. `report` is refused while any owned run is live.
- `home.taskStatus.subagents` is `{ started, stoppedAtEnd }` from canonical evidence;
  `ownerSettlement` proves an `unknown:no-report` cut but never makes it a success.

## Reports and outcomes

- `report`: `resultId`, `outcome` (`progress`, `needs-input`, `final`), `text` (≤ 64 KiB),
  `evidence` (≤ 64 strings of 4,096 bytes; ≤ 128 KiB). It appends one immutable
  `tron-home-task-report` and requests the exact Stop; duplicates reuse it.
- A plain stop with no report, live child or queued input gets one hidden
  `tron.home-task-report-reminder.v1`; a second is `unknown:no-report`.
- No report: `unknown`. Length, deadline or budget: `limited`. A failed stop: `unknown`
  (`deadline-stop-failed`, `task-stop-failed`, `report-stop-failed`). Budget caps spend at the
  lower of admission and current values, checked per turn.

## Cold reconciliation

After the listener serves, `HomeOwner.recoverTasks` (called by gateway-main) settles abandoned records one at
a time without constructing workers or replaying. A live or unreadable async run →
`unknown` (`detached-work-outlived-task`); a durable Stop intent without report →
`interrupted`; a report counts only with one marker and one valid report after it. Until it
settles, `home.status.taskRecovery` refuses task work (dispatch, tools, steer, Stop,
reconfirmation, redelivery) while ordinary chats continue. Results co-commit their wake
(`cold-explicit-report`, `cold-no-report`, `cold-evidence-unavailable`). After the result
is durable, recovery acknowledges its exact root run marker, including already-terminal
records; it never clears another operation's marker in the same session. An
acknowledgement failure keeps recovery unavailable and the marker intact for the
next startup; it is not treated as a successful cleanup.

## Control and spend status

- `home.taskList` pages one current operation per explicit resume lineage by `createdAt`
  desc, ID asc. Separate delegations stay separate even with the same title. Exact
  `counts: { active, finished }` count these current operations, not superseded records.
  `filter` is `all` (API default), `open` (non-terminal or needs attention), or `finished`;
  cursors bind that filter. Rows retain the current task ID, dates, title, project, worker
  session, lifecycle, outcome, spend, attention, pending grant and recent check-ins from
  that operation; an inherited predecessor blocker is never presented as current.
  A successor refused before starting never supersedes its worker's current operation.
- `home.taskHistory` reads any task ID in a lineage, returning newest-first events for
  every admitted operation (including empty resumes) and accepted check-in. Refused
  admissions keep their records but neither emit an operation nor consume a resume number. Pages default to 20,
  max 50, with total and namespace/lineage-bound cursors. Canonical `checkin` tool-result
  details recover history beyond the twelve recent snapshots; snapshots cover an accepted
  check-in whose tool result is not yet appended. IDs deduplicate inherited copies.
  Text and whitespace remain verbatim: this read never guesses missing producer spaces.
  `complete` is false if older nested calls lack exact retained records: codemode records
  arguments/status, not result details, so an aged-out nested check-in's ID/time cannot
  be reconstructed honestly. Retained nested snapshots are matched to the SDK's canonical
  nested-call record; its incomplete flag also exposes argument/count limits. The client
  names an evidence gap instead of inventing records. State is current, not a fabricated
  historical phase at check-in time. A changed task store or authority epoch during the
  canonical read refuses rather than mixing operation versions.
- `home.taskStatus` remains the exact named operation, adding result, worker model,
  subagents and ≤ 20 live runs. Historical task records and worker sessions are not deleted.
- Home's `task` tool (`list`, `status`, `report`, `steer`, `interrupt`, `stop`, `resume`,
  `rename`) acts only on its own identity and generation; refusals name the state and the
  action to use (`home.task.control`). Rename writes the canonical session name.
- Interrupt aborts only in-flight tool calls (bash: SIGINT, SIGTERM, SIGKILL 5 s apart, abandoned
  after 15 s) and queues `text` as steering. Stop persists `stopIntent`, aborts and joins the
  root prompt; an orphan active task is reconciled from its file at once.
- `home.reconfirmPermissions`, `home.decideTaskGrant` and revocations are maintainer-only and
  receipted.

## Task wake inbox and terminal push

The terminal task and its wake event share one fsynced record. Events move `pending → claimed → admitted → terminal → acknowledged`, or `blocked`, `outcome-unknown`.

- A user activation admits pending results as context; a Gateway-started wake admits them as
  its trigger. Each is a `tron.home-task-result.v1` message with a `tron.context-delivery.v4`
  receipt; ordinary chats never drain the inbox. A quiet pass proves the inbox quiet until the
  next write (`home.inbox.admission-slow` names slow ones).
- `HomeOwner`'s single-flight scheduler wakes when a result settles while Home is eligible,
  after recovery, after `home.resumeMemory` and when an activation goes idle; receipts use
  source `homeWake`, no user row. The text opens with title, outcome, subagent counts and
  elapsed time, then report and evidence.
- Results arrive whole in order within context and chapter headroom; the rest stays pending
  (`tron.home-task-pending.v1`); an oversized one arrives as a reference paged with `task { action: "report", offset, limit ≤ 4096 }`.
- Acknowledgement needs the exact canonical message, attribution and receipt; unreadable proof
  makes the event `outcome-unknown`; Stop before append returns it to `pending`. Events bind
  `{ homeId, routeGeneration }`; `home.redeliverTaskResult` re-stamps one unadmitted event.
- Push: at most one per result (the wake reply, one waiting notice, or the task-finished notice
  for a paused Home; none when a user drained it). The inbox, not push, is the guarantee.
