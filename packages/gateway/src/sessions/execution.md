# Session execution and presentation

Live execution as clients see it: snapshots and progress, Stop, extension forms,
queues, compaction, creation, terminals, workspace reads and resource invocation.
Owner: `gateway/run` ([README](README.md)); canonical reads are in
[catalog](catalog.md), producer attribution in
[delegated activity](../kernel/delegation/delegated-activity.md), shared admission in
[protocol](../transport/protocol.md).

## Snapshots and progress

- Snapshot and `session.progress` frames are built only for a session with a
  subscriber. The transport subscribes a client before installing its barrier and is
  the only writer of the subscriber record (a closed slot does not end it). An
  unsubscribed change publishes only `session.summary`; a snapshot with no ready
  recipient counts as unaudienced (`UNAUDIENCED_SNAPSHOT_WARNING`).
- Progress republishes the cumulative live message at most once per 150 ms (the first
  after a quiet window is immediate; a snapshot flushes a pending frame first). Each
  live message is ≤ 24,000 encoded bytes; tool arguments yield first to response text
  through `{ truncated: true, preview? }`, ordinals, call IDs and complete groups
  survive, and groups that cannot fit are omitted whole.
- At assistant start the runtime captures one presentation ID, parent anchor and
  timestamp, and binds it to the canonical entry in the microtask after `message_end`.
  A snapshot takes one synchronous branch cut for both the page and paged-out tool
  ownership. Every content part carries its source ordinal (thinking runs also a run
  ordinal). A long silent tool publishes nothing; the socket's pings prove liveness.
- Tool lifecycle is a disposable overlay: a `toolResult` is observed at `message_end`
  and verified canonical in the next microtask, then its runtime row retires (timing
  and grouping kept); late callbacks cannot resurrect it, and a snapshot omits runtime
  state whose call already has a canonical result anywhere on the branch.
- Tool rows keep the canonical name plus the extension's declared `label` and, when
  exactly one extension owns the tool, provenance from `sourceInfo`. Parallel events
  carry a per-run ordinal; each call a progress sequence, bounded output tail,
  monotonic duration that never decreases (refreshed on every progress and snapshot,
  preserved through canonical handoff) and timestamps. A newer nonempty output frame
  replaces the previous one; an empty one keeps it. Clients join by call ID. Direct
  `session.bash` rows use the same metadata.
- Pi nested calls keep `<parent>/<n>` identity under the parent, never their own rows
  or receipts: up to `NESTED_CALL_LIMIT` (256) children, arguments ≤ 1 KiB each and
  32 KiB per parent (else a byte count and `complete:false`), `failed` also for
  `isError` results, Pi's `unfinished` kept, errors ≤ 512 bytes.
- Statistics include the runtime's latest cache-hit rate.

## Stop and process ownership

The active-run flag outranks an older settlement callback. Stop's operation kind is
advisory: after fencing the operation ID the Gateway cancels agent, compaction, retry,
branch summary, direct bash and built-in `bash` (which freezes its process group,
captures its descendants and kills groups they created) and answers only when the
operation and every owned process settle; otherwise it returns an error. The same
owner enforces `bash`'s `timeout` (Pi's message and partial output; the group is
killed even after the shell exits). After shell exit a call keeps reading while the
pipe is busy but settles after 100 ms of silence, and at most two seconds after a
termination request. Detached subagents are not Stop's.

Stop is per invocation: the stopped message carries Pi's `aborted` reason so
extensions decide whether to continue; Tron never disables continuation. Queued
steering survives Stop: RuntimeSlot closes Pi queue admission, keeps each original
input record, clears Pi's copies before the abort, then redelivers in order through
normal admission (handlers run again; #617 tracks a no-rerun API), logging
`session.stop-steering-continuation`. `rpc-idle-admission.integration.test.ts` pins
this to the SDK's `clearQueue()`/`prompt()`; requalify on every Pi upgrade.

Every runtime installs an abort-aware adapter on the Agent stream: a terminal error
whose exact request signal was aborted is classified `aborted`, so Pi does not retry
or compact a cancelled response. Pre-prompt compaction has no Agent signal yet, so
the invocation cancellation set fences the `preflightResult` callback; Stop at
`compaction_start` revokes admission; auth waits cannot be cancelled, so Stop may
return retryable pending after its grace. A rejected preflight persists an
interrupted or failed receipt and retires its marker before idle is published.

## Extension forms and retained presentation

- Extension commands resolve before streaming rejection and run through Pi's prompt
  path. Tron's `ask_user` is one semantic form tool (`tron:ask-user.v1`): one to four
  questions, two to four options, single/multi select, optional Other, explicit
  `allowCancel`, one atomic answer; one pending form per session, Other ≤ 32 KiB,
  envelope ≤ 192 KiB. Closing the sheet keeps the draft and the interaction pending.
  Its guideline puts copyable text in the message or a fenced `context` block. A
  foreign same-name registration fails closed.
- Extensions detect `tron.form.v1` on the Pi UI context; `undefined` means no answer
  (cancel, retirement or abort), never a decision. The audited
  `@zhushanwen/pi-ask-user@7.0.15` adapter (exact source, manifest and lock
  integrities including `@xyz-agent/extension-protocol@0.7.0`) maps its
  `\0XYZ_ASK_USER` marker to a form; unaudited contracts fail closed. Arbitrary TUI is
  never executed remotely; the RPC host rejects blocking and overlay custom calls,
  and retained component widgets become read-only bounded surfaces.
- `ExtensionPresentationStore` owns a host epoch and aggregate revision over statuses
  (32), string widgets (24), interactions (8, 64 options, 192 KiB), surfaces (64,
  160×120, 4,096 runs, 256 KiB each) within 700 KiB. Each change emits one
  `session.extensionPresentation` v3 envelope at the exact next revision. `ui.notify`
  persists as non-context `tron.extension-notification.v1` receipts. Under pressure,
  interactions and identity outrank decoration; omission is explicit; the editor text
  and revision are one baseline; status text and its owner clear together; a bad
  widget update leaves the old one. `extension.toolsExpanded` toggles Pi's
  `setToolsExpanded` under command/epoch/revision checks. Interactions survive
  disconnect and never enter the offline cache; dialog kinds are method-discriminated.
- Reload or replacement retires captured callbacks. The lifecycle coordinator counts
  preflights, commands, interactions, foreground work and deferred shutdown as work;
  decoration protects only automatic eviction. Drain clears new queues and aborts
  continuations after its cutoff. `ctx.shutdown()` waits for `session_shutdown`;
  disposal gives cleanup five seconds, and eviction skips slots with unsettled receipt
  persistence. Extension commands persist a provisional run marker first.

## Queues and prompt admission

- `queue-management.v1`: every snapshot has `queueRevision` and `queuedItems` (stable
  IDs, behavior, text, attachment counts and upload descriptors); a steer or follow-up's
  operation ID is its queue entry ID. RuntimeSlot keeps the admission ID because Pi
  exposes only strings. `session.queue.replace` validates against the revision and
  rebuilds Pi's queue atomically; steering precedes follow-ups. Bounds: 32 entries,
  64 KiB each, 256 KiB total. Legacy string arrays never authorize edits.
- `acceptsQueuedPrompts` follows Pi streaming state and is also true while compacting:
  prompts then join a Gateway-owned waiting queue after Pi's (default steer), editable
  synchronously, flushed in order when compaction settles (also after Stop), paused by
  a new compaction, holding `queued-mutation` drain work. Automation prompts and
  extension commands never wait there. Queues are process-local and never replayed
  after restart; iOS restores unresolved accepted work for review.
- The runtime's preflight callback is the only admission outcome. Admission waits
  behind the foreground owner while settlement, compaction or retry is still active
  after streaming ends. `pendingPrompt` carries display content until the exact Pi user
  message persists, whose `presentationId` is the prompt operation ID.
  `session.operationFailed` is only for an operation proven unable to produce input;
  other failures are `session.diagnostic`. `retrying` is projected while a provider
  retry waits; `agent_start` restores `running`.

## Compaction execution

Manual compaction has one Gateway-owned admission slot (a second request is
rejected). During a run it publishes `compactionQueued`, persists its own marker and
is adopted by the next SDK compaction of any reason; that compaction's failure fails
the request. Every `compaction_end` publishes one fitted snapshot;
`session.compaction.completed` logs reason and outcome; automatic failures emit
`session.operationFailed` while still owning the slot; cancellation is not failure.
The operation ID stays on the compaction entry so compacting and compacted content
share one row. Snapshots project `automaticCompactionEnabled`. Settings:
[runtime configuration](../admin/runtime-configuration.md#compaction).

Prompt attachments are bounded by RuntimeSlot through the SDK's image pipeline before
they become canonical (the original upload stays); an undecodable image is kept. A
provider HTTP 413 is classified `context_length_exceeded`, so Pi's compact-and-retry
applies; **Compact Now** remains available.

## Creation, worktrees and invalidation

`session.create` takes an exact strategy: `existingCheckout`, `newBranchWorktree`
(from `HEAD` or a validated base; dirty checkouts refused) or `existingBranchWorktree`.
Git runs without a shell with validated refs; only a proven successful add may clean
up its worktree and compare-delete its branch; uncertain residue is kept; process
groups are retired or the outcome is unknown. Roots are checked no-follow and by
realpath containment. Worktrees outlive sessions. `git.inspect` returns ≤ 200
branches and 100 commits as hints only. Git operations share
`util/workspace-git-environment.ts`, which ignores inherited `GIT_DIR`,
`GIT_WORK_TREE`, `GIT_INDEX_FILE` and object-directory variables. Structure, context
and resource changes refresh open surfaces; provider, settings, trust, package and
custom-model changes publish bounded global invalidations.

## Session-bound operations

- Context, tree, resources, commands, exports, transcript pages, terminal inventory
  and every live mutation need an established subscription to that session (rename
  and delete are catalog-scoped). Terminal input, resize and termination also need
  attachment ownership; closing a session revokes it. PTYs: 128 records, 16 active,
  64 KiB UTF-8-safe output events, replay below the frame ceiling, termination
  resolves after `terminal.exit`.
- `workspace-inspector.v1`: `session.workspace.inspect|list|file|git.diff|
  git.history.list|get` and `workspace-history-diff.v1` derive their root from the
  slot's cwd, reject traversal and symlinks, revalidate inode identity, fail whole at
  1,000 entries or 768 KiB, and register file previews in the blob store. Git runs with
  no shell, pager, external diff or textconv, a fixed locale and a killed process
  group on timeout; history cursors are authenticated and pinned to the tip.
- Accepted `session.prompt` retains its runtime before receipt
  I/O. A prompt starts its run-marker write before answering; settlement awaits it.
- `session.commands`: runtime order, ≤ 1,000 rows and 700 KiB, unique `source:name`;
  a skill row carries its SKILL.md frontmatter `title` when set (display only);
  `session.commandDetail` returns one source document ≤ 96 KiB;
  `session.subagentDetail` returns one discovered subagent's row and its
  credential-redacted definition body under the same bound, never its file path.
  `session.prompt.resourceInvocations` (#311): up to 16 skills and prompts once each
  with empty arguments, or one extension command whose arguments equal the text
  (no attachments). RuntimeSlot composes expansions then the visible prompt with Pi
  expansion off; names ≤ 512 bytes, arguments ≤ 5,000. Start receipts keep the typed
  list and submitted text; binding receipts attach them to the user entry, so chips
  and Automation provenance survive restart; queue edits terminalize and re-append.
- A new Pi session is memory-only until its first message; earlier custom-entry
  receipts persist with it. The Gateway never writes Pi's JSONL itself. Persisted
  skill envelopes (≤ 4 MiB) are stripped of body and path in mobile projection.
