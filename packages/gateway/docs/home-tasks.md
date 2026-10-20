# Home tasks

Owner: [gateway/home](../src/home/README.md). Home delegates finite project work through
`delegate` into ordinary worker sessions; each worker seals an explicit immutable report, and
results reach Home through the wake inbox. This contract spans the Home owner, RuntimeSlot and
`OwnedSessionDispatch`, the managed subagent provider and the iOS task surfaces. Signal names
are owned by [observability.md](observability.md).

## Persistence

`HomeTaskStore` owns `<tronHome>/gateway/home/tasks/` (`0700`), apart from the Home record,
workspace, canonical JSONL and episodic memory. Every JSON file is `0600`, bounded and read
without following symlinks; parents are owner-only real directories.

- The first dispatch initializes: it publishes an empty `authorization.json`, syncs, then
  publishes `gateway/workspace-state/home-tasks-initialized.json` (`{ "version": 1 }`) and
  enables the initial trusted-project scope. Startup never initializes or enables. A partial
  setup is preserved and refused; after initialization a missing namespace, marker or
  authorization file is lost state, not a fresh install.
- A task is `tasks/<13-digit-createdAt>-<taskId>.json` (≤ 256 KiB), strict v1 keys:
  `version`, `taskId`, `revision` (create at 1, replace only at expected + 1); store-owned
  `createdAt` (immutable, strictly advancing) and `updatedAt`; immutable `homeId`,
  `generation`, `routeGeneration`, `intent` (`{ text }` ≤ 64 KiB) with `intentDigest`
  (SHA-256), and absolute `target` (≤ 4 KiB, not admission authority); `grantRef` or
  `scopeRef` (at most one, filled once); `lifecycle` `pending | active | terminal`;
  `sessionId`, `operationId`; `stopIntent` (`{ operationId, requestedAt }`, never replaced);
  `spend` (`{ sourceDigest, inputTokens, cacheReadTokens, cacheWriteTokens, outputTokens }`,
  fresh input only; records without cache fields count cache in `inputTokens`; never a cost);
  `budget` (the profile's `permissions.budget.task` fixed at admission, or absent = no
  limit); `reportRef` (`{ resultId, sessionId, entryId, digest }`); `wake` (the delivery
  event); `terminalEvidence` (`{ outcome, sessionId, entryIds ≤ 256, reason, detail?,
  failureCause? }`, outcome `progress | needs-input | final | limited | interrupted |
  unknown`, `final` requires a report; `failureCause` is only `provider-usage-limit` or
  `provider-error`, from the last canonical assistant error, never raw provider text).
- `authorization.json` (owned by `HomeTaskAuthorization` through the store adapter): strict
  v1 `version`, `revision`, `scopes`, `requests`, `decisions`, `grants`; ≤ 4 MiB, ≤ 10,000
  unique records per array. A request has an exact binding and SHA-256 identity; a decision
  names one request, decided once; a grant names one approved decision, matching its binding,
  expiry and restore epoch. Only the adapter advances the revision; payloads are snapshotted
  before queuing.
- Both files replace durably (unique temp, fsync, rename, directory fsync) before
  acknowledgement. Unknown, malformed, unsafe, oversized or contradictory records keep their
  bytes and refuse with `HomeTaskStoreError` (`home.task.store-refused`, bounded reason). An
  uncertain publication fences the instance until a fresh owner reloads. Startup removes a
  crash-staged `<name>.json.<pid>.<12 hex>.tmp` only when it is this user's regular file.
- The creation filename survives every replacement; ID lookup scans names and refuses
  duplicate suffixes. There is no second catalog, membership index, task-count cap, pruning
  or deletion API. By-ID operations read their target plus one `authorization.json` read.
  Authority saves only append or mark. Reports stay in the worker's canonical history, pinned
  by reference and digest; terminal and authority fields are immutable; only WakeInboxOwner
  advances the wake event.
- **Authority epoch** derives from the task directory's `dev`, `ino` and birthtime. Restart
  and atomic replacement keep it; a restore, copy or migration changes it, so old scopes and
  grants are kept but refused (`scope-reconfirmation-required`). An unreadable identity fails
  closed. It does not detect an in-place overwrite by a privileged actor.

## Authorization

`HomeTaskAuthorization` owns authority apart from execution. The initial standing scope
covers any currently trusted project (trust resolved again at admission), bound to the epoch.

- Outside an active scope a task needs a one-use grant binding intent digest, canonical
  target, scope, expiry and epoch, consumed atomically at admission. A `grant-required`
  refusal durably records the request first and returns a stable `requestId`.
- Approval records the decision plus one grant; denial records the decision only. A decided
  request never mints a second grant, and approval never replays the refused task.
- Revocation and consumption share one mutex; revocation does not stop admitted work (Stop
  does). Restart keeps scopes and grants unchanged; only `home.reconfirmPermissions`
  re-stamps active standing scopes. Revoked scopes and grants are never renewed.
- Only maintainer RPCs and terminal controls list, revoke and decide; Home's tools cannot.

## Worker progress check-ins

`checkin` sits beside `report` on the current task-worker operation only and never seals,
pauses or ends work. Fields: `step` (256 bytes), `done`, `next`, optional `blocker` (512
each), optional `refs` (`branch`, `commit`, `issue`, 256 each), `needsAttention`; request
≤ 4 KiB; invalid requests write nothing. The task record keeps 12 entries with Gateway ID,
time, identity and attention disposition; status and list surfaces show the latest three.
Resumed successors carry the history unchanged. Routine check-ins cause no wake or push.
`needsAttention` requires a blocker and requests at most one wake per 30 minutes per worker
lineage through a task-owned outbox sharing the result wake path (`requested`,
`rate-limited`, `pending`, `none`). An unavailable or paused Home keeps that outbox for its
next eligible activation, with no fallback push. Progress is never success evidence.

## Dispatch and workers

Only the enabled Home's active chapter calls `delegate` with a stable `taskId`, bounded
`intent`, trusted `target` and optional `title` (≤ 80 characters, the worker session's
canonical name, set before its first prompt). The dispatcher records pending intent,
authorizes the exact snapshot, creates the worker through `OwnedSessionDispatch` and binds its
operation before prompt admission. A task ID never replays an accepted prompt.

- **Bounded admission.** Each awaited step (`choice` … `bind`) has a 60 s deadline and follows
  the delegating turn's Stop. A refused step fails `delegate` at once, its late result returns
  to its owner (late leases are released, never prompted), and a task already pending settles
  `unknown` with `admission-cancelled` or `admission-timeout`. Slow steps log
  `home.task.dispatch-stage`.
- **No worker cap.** Every authorized task starts at once; heavy verification steps wait in
  the host-wide heavy queue ([host-load.md](host-load.md)).
- **Model and thinking.** Each `delegate` takes the first available `model.queue[role=worker]`
  model (Home's live model when empty; unavailable models are skipped as in
  [settings-model.md 6.3](settings-model.md#63-model-fallback-queues)) and
  `model.thinking[role=worker]` (same as Home when unset), clamped to the model. An explicit
  `model`/`thinking` wins for that field and needs a `reason`. Choices are fixed in the brief,
  applied before the first prompt with provenance, and reported as `worker` and
  `subagentModels`; the brief's explicit subagent choice is authoritative, else
  `tron/subagent`. A mid-run usage limit moves to the next worker model in place.
- A worker has normal project tools plus `report`, cannot replace its session, and carries a
  canonical `tron-home-task` marker binding task, Home identity and generation, session and
  operation, checked before cold construction loads executable resources.
- A sealed `report` ends the task at that turn boundary; later tool calls in the batch are
  refused. Task Stop (control or deadline) is terminal; unconsumed steers get
  `task-stopped-before-delivery` receipts. `OwnedSessionDispatch` has a fixed 24-hour
  ceiling that cancels and joins the exact operation.
- Workers load the managed subagent provider (Home does not). The task extension admits
  launches, read-only management, and the run controls (`steer`, `resume`, `interrupt`,
  `stop`, `command.*`) and supervisor `reply` only for runs the task owns, by `id`/`runId`,
  never `dir`. It refuses other mutating actions, missions, the schedule tool and
  non-blocking `bg_wait`; unknown provider versions refuse all of them. Nested codemode calls
  cross the same gate. Trusted extensions are not a sandbox.

## Subagent runs

A task owns every run its single-use worker session starts: canonical launches (a resume is a
launch of the run it returns), async runs by their `asyncDir`, and children an owned workflow
names in its own status (`steps[].runId`). Nothing is persisted to prove ownership.

- Runs go launching → running → terminal (`complete`, `failed`, `partial`, `stopped`,
  `rejected`, or process-terminal proof). A child of a completed workflow is live by its own
  run-level `state`, keeps the session running and blocks drain.
- **Settlement order:** operation terminal; report stop joined; live async runs and workflow
  children stopped through the provider and joined; completion notices recorded; settlement
  fact appended; evidence cut; outcome. The join is bounded by one minute after the stops or
  the 24-hour deadline, plus a 5 s grace; a run still live is `unknown` with
  `detached-work-outlived-task`, never claimed stopped.
- The settlement fact `tron-home-task-subagents` (`{ receiptId: "subagents:<operationId>",
  operationId, stoppedAtEnd }`) is written only when async runs were launched; `stoppedAtEnd`
  is `null` unless every stop was accepted and joined.
- **Completion notices.** Settlement also waits, under the same bound, until each async run's
  `subagent-notify` message (matched by run id in its text) has its context-delivery receipt;
  misses count as `noticesUndelivered` without changing the outcome.
- Provider missions are provider history; a stopped run's mission settles `cancelled` by the
  provider. A terminal run with an active mission after settlement is a provider defect.
- `home.taskStatus.subagents` is `{ started, stoppedAtEnd }`, projected from canonical
  evidence (admitted launches and resumes; Gateway stops at settlement). Settlement emits
  `home.task.subagents`.
- **Owner settlement proof.** For terminal `unknown:no-report`, `ownerSettlement` is `null` or
  `{ taskId, sessionId, operationId, markerEntryId, terminalEntryId, settlementEntryId,
  stoppedAtEnd }`, proven from a durable canonical cut (unique marker, matching invocation
  receipts, ordered settlement receipt). It never makes `unknown` a success.
- **Waiting across turns.** A normal `stop` turn without a report while the task owns live
  work keeps the operation open; the provider's completion or supervisor wake starts the next
  turn in the same operation. Report, Stop, deadline, a failed/aborted turn, or a turn end with
  no live run settles it. The hold is in memory only.
- **Report waits.** `report` is refused (an ordinary tool error naming the live count) while
  any owned run is live; a stop request is not an ended run.

## Reports and outcomes

- `report` takes `resultId`, `outcome` (`progress`, `needs-input`, `final`), `text`
  (≤ 64 KiB) and `evidence` (≤ 64 strings of 4,096 bytes; payload ≤ 128 KiB), and no
  identity. Acceptance, checked inside the report owner's mutex, appends one immutable
  `tron-home-task-report` and requests the exact Stop; settlement joins it before publishing.
  Duplicates reuse the entry; conflicts refuse. References carry entry ID and digest.
- **Reminder.** A plain assistant `stop` with no report, live child, queued input or
  continuation gets one hidden `tron.home-task-report-reminder.v1` message per task
  (`home.task.report-reminder`); a second plain reply is `unknown:no-report`. Cold recovery
  never prompts.
- **Outcomes.** No report: `unknown`. Provider length, joined deadline or reached budget:
  `limited` (`length`, `deadline`, `budget`). Failed exact stop: `unknown`
  (`deadline-stop-failed`, `task-stop-failed`, `report-stop-failed`). Live run after the
  join: `unknown` (`detached-work-outlived-task`). The last assistant entry is evidence only.
- **Budget.** `permissions.budget.task` ([settings-model.md](settings-model.md) 6.1) caps a
  task's spend counters against the lower of its admission value and the current profile
  value, checked at each turn boundary; reaching it ends the run like a report.
- Reports enter the inbox, never a result-triggered Home call. `home.task.transition`,
  `home.task.spend` and `home.task.runaway-stop` carry only bounded or hashed references.

## Cold reconciliation

After the listener serves (`RuntimeRegistry.recoverHomeTasks`), startup retires abandoned
`pending` and `active` records one at a time. It constructs no worker and replays nothing.
Async runs and workflow children are read from their `status.json`; a live or unreadable one
makes the task `unknown` (`detached-work-outlived-task`). A durable Stop intent without a
report settles `interrupted` (`task-stop`). A task is report-backed only when the read-only
canonical boundary proves one matching marker and one valid report after it; anything else is
`unknown`, never repaired. Authority stays byte-identical. Until recovery settles,
`home.status.taskRecovery` refuses task work; a store refusal keeps its typed reason until the
next start: dispatch, task tools, steer, Stop, reconfirmation and redelivery refuse with that
`conflict`, inbox admission and settlement are no-ops, and ordinary sessions and Home prompts
continue. Recovered
results co-commit their wake event (`cold-explicit-report`, `cold-no-report`,
`cold-evidence-unavailable`).

## Control and spend status

- **`home.taskList`** pages by `createdAt` desc, task ID asc, with exact `counts: { active,
  finished }` from one consistent read; identical requests share it. Cursors bind the restore
  epoch. Rows carry ID, dates, `title` (worker session name, else the brief's first line),
  `project`, `sessionId`, target, lifecycle, outcome, spend (null = unavailable), `attention`
  and `pendingGrant`, without reading transcripts.
- **`home.taskStatus`** adds the active operation, immutable result, `workerModel` (from
  canonical `model_change`), `subagents`, and `subagentRuns` (`{ total, runs ≤ 20 }` of live
  runs, newest first). Viewing never changes control.
- **Home's `task` tool** is one flat schema: `action` (`list`, `status`, `report`, `steer`,
  `interrupt`, `stop`, `resume`, `rename`) with optional `taskId`, `text`, `title`,
  `operationId`, `offset`, `limit`, admitted by `admitHomeTaskToolRequest`. It acts only on
  tasks of the enabled Home's identity and generation and never reconfirms, revokes or decides.
- **Steer, Stop, Resume, Rename** resolve to the named task's current successor and operation;
  an explicit `operationId` is a race guard. Inapplicable actions are refused with the state
  and the action to use. Rejections leave one `home.task.control` record with a finite reason.
  Rename writes the canonical session name through `RuntimeSlot.rename`; the brief stays.
- **Interrupt** aborts only a running worker's in-flight tool calls (bash: SIGINT to the
  group, then SIGTERM, then SIGKILL to every seen descendant, 5 s apart; abandoned after 15 s)
  and queues `text` as steering; the worker, worktree and claim are untouched.
- Steering shares RuntimeSlot's session lane and cannot start a successor. Stop persists the
  exact `stopIntent`, aborts and joins the root prompt owner; canonical interrupted evidence
  plus the intent yields `interrupted`, else `unknown`. An active task no launch in this
  process owns is reconciled at once from its canonical file on Stop, and steering it is
  refused. Callbacks retire with the worker lease, so late reports and steers are refused.
- `home.reconfirmPermissions`, `home.decideTaskGrant` and revocations are maintainer-only and
  receipted; replays return the original receipt and never re-decide.

## Task wake inbox and terminal push

The terminal task and its wake event share one atomic fsynced record (event identity is
SHA-256-qualified by task). WakeInboxOwner moves events `pending → claimed → admitted →
terminal → acknowledged`, plus `blocked` and `outcome-unknown`.

- **Delivery.** A user activation admits pending results as context after its start; the wake
  owner admits them as the trigger of a Gateway-started activation. Each becomes a
  `tron.home-task-result.v1` message (`details.taskTitle`) with a `tron.context-delivery.v4`
  receipt. Ordinary chats, steers and continuations never drain the inbox.
- **Quiet inbox.** A complete pass that finds nothing actionable, with no store write during
  it, proves the inbox quiet until the next write; a quiet turn reads zero task records.
  `home.inbox.admission-slow` names a slow admission.
- **Wake.** `HomeOwner`'s single-flight wake scheduler (no timers) runs when a result settles
  while Home is eligible, after startup recovery, after `home.resumeMemory`, and when an
  activation goes idle. A busy Home defers to the active activation's idle; a refused wake
  asks for nothing more. The wake's trigger is the last selected result, appended with
  `triggerTurn`, and admission is the same as a user activation's
  (`assertHomeWakeAdmissible`). Its receipts use source `homeWake`; no user row is written.
  The result text opens with one line (title, outcome, subagent counts, elapsed ms), then the
  report text and evidence; identities and proofs stay in `details`. A blocked memory does not
  make Home ineligible: the wake's activation re-arms it.
  Each new batch starts one wake, however many wake-only turns preceded it.
- **Envelope.** Each activation delivers whole results in creation/event order within its
  context and chapter headroom; the rest stays pending, counted by
  `tron.home-task-pending.v1`. A result larger than the headroom arrives as an immutable
  reference; Home pages it with `task { action: "report", taskId, offset, limit ≤ 4096 }`.
- **Proof and acknowledgement.** Admission records chapter, operation, generation, route and
  digest first. Acknowledgement needs the exact canonical message, attribution and terminal
  receipt, fsynced. Unreadable proof makes only that event `outcome-unknown`; a transient
  failure retries next activation; Stop before append returns it to `pending`
  (`admission-aborted`). Unproven admitted work is never replayed.
- **Routes.** Events bind `{ homeId, routeGeneration }`. Disable pauses delivery; rollover
  delivers into the writable chapter; missing-session replacement blocks old events.
  `home.redeliverTaskResult` re-stamps one unadmitted event (maintainer only, receipted).
- **Push.** Each result gets at most one durably decided push: a wake's reply is its push
  (`push-wake-reply`); a refused or uncertain wake sends one waiting notice; a paused or
  disabled Home gets the task-finished notice; a user-drained result gets none. A crash
  between decision and enqueue may omit a push; the inbox is the guaranteed delivery.
- A stopped activation never requests a wake. `home.task.inbox` reports only a hashed event
  ID, state and coded reason.
