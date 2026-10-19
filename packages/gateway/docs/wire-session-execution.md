# Session execution and presentation wire contract

[Gateway wire index](../README.md#transport)

Live execution, semantic extension presentation, queues and session-bound tools. [Connection protocol](wire-transport.md) owns shared admission and encoded bounds. Canonical discovery and read pages belong to [session inspection](wire-session-inspection.md); producer attribution belongs to [delegated activity](delegated-activity.md). Native composition remains with [presentation parity](../../ios-app/docs/architecture.md#presentation-parity).

Command and plain-text source paths retain their original repository/Gateway-root context; Markdown links are document-relative.

## Live projections and foreground operations

Clients subscribe
to `session.snapshot`, progress, tool, queue, and extension events only for chats
they actually open. No client consumes a session's snapshot for a session it has
not opened, so the Gateway builds and serializes one only for a session with a
subscriber: the transport subscribes a client before it installs that client's
synchronization barrier, so a pending barrier is always a subscriber, and a
state change for an unsubscribed session publishes its `session.summary` with no
transcript projection at all. The transport is the only writer of that
subscriber record: a slot that closes without the client unsubscribing does not
end the subscription, so a re-acquired session still reaches the client that was
watching it. The transport also counts the recipients of every snapshot frame it
is handed, and a projection no ready socket could receive is recorded as
unaudienced and warns (`UNAUDIENCED_SNAPSHOT_WARNING`) rather than passing as an
ordinary build. A client that subscribes later receives its snapshot through the
ordinary open and synchronization path. Streaming progress follows the same
rule: without a subscriber the slot projects and serializes no `session.progress`
frame, neither the paced cumulative one nor message_end's finalized declaration;
stream identity capture and the tool-invocation group latch those frames are
built beside stay slot state and still run, and the first frame after a client
subscribes carries the cumulative message its snapshot already restored.
Streaming progress republishes the cumulative live message, so
updates are throttled to at most one frame, carrying the newest message, per
150 ms window while they keep arriving (the first update after a quiet window
stays immediate, and a snapshot publishes any pending frame ahead of itself),
and each live message is bounded to 24,000 exact encoded bytes, including inside
reconnect snapshots. Under pressure, tool arguments yield first to response
text and invocation identity through the existing `{ truncated: true, preview? }`
JSON representation. Only remaining content pressure trims the live tail; an
oversized write argument alone must never replace useful response text with an
ellipsis. Source ordinals, call IDs and complete finalized groups survive argument
compaction. Groups whose structure itself cannot fit are omitted atomically rather
than falsely advertised as complete. Snapshot-wide pressure can still shed the
live overlay after other disposable content; canonical history remains independently
bounded and unchanged. The large-write runtime regression checks actual
file bytes, declaration-before-execution ordering and canonical identity handoff.
At assistant-message start the runtime captures one opaque presentation ID, fixed
canonical parent anchor, and fixed timestamp. A snapshot takes one synchronous
canonical branch cut and derives both the bounded transcript page and paged-out
canonical tool-result ownership from it; this is a disposable projection cut, not
another transcript mirror or cache. Every projected content part carries
its required source ordinal; adjacent thinking parts also carry their fixed run
ordinal, including after leading live-tail trimming. Pi's `message_end` callback
precedes canonical append, so the runtime binds that same presentation ID to the
new canonical entry in the following microtask before publishing the settled
snapshot. The binding ledger is capped beyond the maximum mobile transcript page;
canonical entry IDs and JSONL remain authoritative and unmodified. A long tool with no output
publishes no session event; the connection's own ping and pong traffic proves the stream is live.
Tool lifecycle state is a disposable overlay, not a second transcript: the pinned Pi SDK's ordinary
`toolResult` persistence is observed at its exact `message_end` handoff (not only through
`entry_appended`) and verified against canonical ownership in the following microtask, so a
failed append cannot create a projection gap. The matching runtime call ID is then retired while
timing, grouping, and provenance metadata remain available for canonical projection. Late terminal callbacks cannot
resurrect that ID. Snapshot admission also checks the full canonical branch, rather than only
the bounded transcript tail, and omits any runtime state whose exact call ID already has a
canonical result. This keeps long turns and paged-out history free of duplicate or phantom
terminal tool rows while preserving running calls and canonical enrichment.
The embedded runtime's active-run flag outranks an older settlement callback when
an extension completion immediately triggers a continuation, so phase, operation,
and Stop controls cannot become idle while a newer turn is executing. Stop's client-supplied
operation kind is advisory presentation metadata, never cancellation authority: after
fencing the exact operation ID, the Gateway fans cancellation out across agent, compaction,
retry, branch-summary, direct-bash, and built-in foreground `bash` ownership. The latter
freezes its process group, captures its direct descendant tree, and terminates descendants
that created their own process groups. Gateway does not acknowledge Stop until the exact
foreground operation and every owned process settle; an unsuccessful postcondition returns
an error rather than `{ aborted: true }`. Runtime replacement also drains the outgoing
process owner before installing its successor. Extension-managed detached subagents never
enter that owner and are not cancelled by foreground Stop. The same owner enforces the
tool's `timeout` (seconds, validated as Pi validates it): on expiry it terminates the owned
tree the same way, and the call fails with Pi's "Command timed out after N seconds" and the
output written so far. If the shell has already exited, its process group is still killed.
After the shell exits, a call keeps reading output while descendants write to the inherited
pipe, as Pi does (pi#5303). The pipe must stay busy: once it has been silent for 100 ms after
the shell's exit, the call settles, so a quiet descendant that holds the pipe cannot hang it,
and output that descendant writes after that silence is not read. Once a timeout or Stop has
asked for termination, that output can extend the call by at most two seconds, so a
descendant that escaped the group cannot hold it open. Pi's tool only passes the timeout to the operations it runs on, so operations that
ignore it leave every command unbounded (#499).
Stop is scoped to one invocation, not to an extension workflow. A stopped run's canonical
assistant message carries Pi's `aborted` stop reason, so an extension that schedules its own
continuations can distinguish a user stop from a completed run and decide whether to
continue; Tron never silently disables extension continuation on the user's behalf, and the
Stop affordance must not claim that it does. Accepted steering remains Gateway-owned through
consumption. If Stop aborts a run with queued steering, RuntimeSlot closes Pi queue admission
and preserves each original input record (raw submitted text, images, source, command and
operation identity). It clears Pi's queued copies before the full abort so Pi cannot consume
those copies at the abort boundary; steering accepted during settlement stays Gateway-owned.
After the shared abort set settles, all originals are redelivered in order through normal
serialized admission. The first starts the run and later items queue with
their original behavior; a queue row retires only at its exact message-start or terminal
admission boundary. Input handlers run again on redelivery because the first processed copy
never reached the model and is discarded. Stop without queued steering leaves the session idle.
The Gateway `session.stop-steering-continuation` log records the accepted steer count and
continuation outcome. A continuation that starts after a stop reuses the accepted input's
identity rather than resurrecting the stopped run. A future Pi API that accepts an already
processed input without rerunning handlers is tracked separately in #617. The
real-WebSocket `rpc-idle-admission.integration.test.ts` case pins this boundary to the pinned
Pi SDK's public `AgentSession.clearQueue()` and `prompt()` lifecycle: clearing must retire both
session- and Agent-level queue copies, and normal prompt admission must preserve the AgentSession
run, transcript and terminal callbacks. Requalify this case on every Pi SDK upgrade.

## Extension forms and retained presentation

Extension commands are resolved before ordinary streaming rejection and still execute through
Pi's prompt path. Tron registers its release-owned `ask_user` capability as one sequential
semantic form tool (`tron:ask-user.v1`). Its title, descriptions, multi-select/Other policy,
question and option order, and bounded answer details are retained in one canonical result
shape; native Cancel is admitted only when `allowCancel` is true, while closing the native
sheet preserves the draft and leaves the interaction pending. Its prompt guideline tells agents to
put commands, URLs, paths and IDs the user may need to copy in normal assistant text before asking
(or in `context` as a fenced code block), not only in the question sentence. A same-name foreign registration
fails closed with an actionable destination-only settings migration message. Historical
`@zhushanwen/pi-ask-user` results remain readable through the audited adapter below.
The explicit extension adapter registry identifies only the pinned
`@zhushanwen/pi-ask-user@7.0.15` package through exact package source/path metadata,
the installed manifest and npm-lock integrity
`sha512-FqsIq4cOXVVX12Jotdj4o9BkZBa5DC/8Hg9w5yhxl+AmsA8UGX3a5kpThCzmFdf0lxaVaWN5/plAsJBSdWjZ3g==`,
the exact `@xyz-agent/extension-protocol@0.7.0` dependency and its locked
`sha512-08cGiK4NEwdqBRJRemyphlLLWKxG+8uaM+Fk3r95qi9eNVmP7l5hRfWGcJIYYkaseSv3S+GGfFAeBXth8x6rAw==`
integrity, the `ask_user` tool name, and its complete bounded public parameter
shape. Pi invokes the extension override before attaching canonical package metadata,
so the adapter also admits only Pi's exact provisional `local`/`temporary`/`top-level`
source shape when the owning user/project settings pin, package manifest, and both npm
lock integrities prove the audited installation. Its original execute function,
validation, result formatting, renderer callbacks, events, abort signal, and
channel behavior remain authoritative. A scoped UI adapter translates the package's
exact `\0XYZ_ASK_USER` select marker into one first-class semantic form interaction;
the same adapter is installed on the extension event context captured by its subagent
channel handler. Form v1 admits one to four questions, two to four options per question,
stable question/option IDs, single or multiple selection, optional Other text, explicit
cancel policy, and one atomic structured response. The Gateway permits one pending form
per session, preserves canonical option order, caps each Other response at 32 KiB and the
interaction/answer envelope at 192 KiB, and never falls back to primitive dialog scripting. Mobile sheet dismissal does not send cancellation or settle the extension promise: the authoritative interaction remains pending until an explicit answer, package timeout/abort, host retirement, or an explicit protocol cancellation from a client that intentionally offers one.
Malformed or unaudited marker contracts fail closed. Arbitrary custom/overlay TUI is not
inferred or remotely executed.
The capability is published to extensions as one documented, versioned host property,
`tron.form.v1`, on the Pi UI context: presence of that property is the capability signal,
and its absence means the extension must fall back to Pi's standard primitive dialogs. An
independently authored extension can therefore feature-detect and request a native form
without importing Tron internals or receiving a bespoke package adapter. A returned
`undefined` means no answer was admitted — explicit cancellation, host retirement, or
abort — and is never a user decision; caller aborts are not treated as answers either.
A per-bind host epoch and monotonic presentation revision scope
all retained semantic state and actionable responses; reload/replacement retires
captured callbacks instead of letting them mutate the replacement host. The lifecycle coordinator counts prompt preflights, command handlers, interactions,
foreground agent/retry/compaction/bash/queue work, and deferred session-scoped
shutdown as operational work. Decorative retained presentation protects automatic
eviction only; it cannot deadlock trust revocation or explicit deletion. Administrative
drain establishes a cutoff, repeatedly clears newly added queues, and aborts
extension continuations that begin after that cutoff. `ctx.shutdown()` waits for Pi's
`session_shutdown` before reporting closure and closes only the owning runtime slot.
Automatic eviction skips slots with unsettled canonical receipt persistence rather
than committing an eviction that waits behind them. Runtime disposal then gives
extension `session_shutdown` cleanup a five-second grace before synchronously
invalidating the Pi extension context and retiring the slot. Cleanup and disposal
instrumentation are advisory after disposal begins: they cannot strand a canonical
session behind committed idle eviction or make later `session.open` calls time out.

`ExtensionPresentationStore` is the sole owner of an extension host epoch and its
aggregate presentation revision. It atomically retains semantic state, actionable
interactions, generic surfaces, the projected input lease, capabilities, and bounded
diagnostics. Producer state is bounded before retention or broadcast: 32 statuses,
24 string widgets, eight pending interactions, 64 select options, 192 KiB
interaction/editor budgets, at most 64 surfaces, 160 columns by 120 lines, 4,096
runs and 256 KiB per full frame, and a 700 KiB aggregate presentation ceiling. The
lower aggregate ceiling leaves room inside the 1 MiB WebSocket frame for lifecycle
identity and a bounded canonical transcript tail.

Every committed change emits exactly one `session.extensionPresentation` v3 envelope
with the current host epoch and exact next aggregate revision. Semantic patches,
authoritative interaction lists, full-frame surface upserts, explicit removals,
lease replacement/clear, capabilities, and diagnostics share this stream. Extension
`ui.notify` calls never use the app-notice channel: the Gateway persists them as
bounded, non-context `tron.extension-notification.v1` receipts so they remain ordered,
centered session status after reconnect. Malformed upserts never mean removal. Responses retain the
interaction's admission revision; native editor patches retain bounded operation IDs
so the originating presentation can suppress its own echo. Native clients may toggle Pi's public
`setToolsExpanded` state through the command-ID/epoch/revision-checked `extension.toolsExpanded`
mutation; retained component frames rerender only after that authoritative mutation. Under snapshot pressure,
actionable interactions and epoch/revision identity outrank decorative frames;
omission is explicit through projection diagnostics; omitted surface identity and
revision remain as a bounded delta baseline, while blocking/focused/leased surfaces
are retained ahead of decoration so exact-next full frames converge without loops.
The revisioned editor text and revision are retained as one inseparable baseline;
pressure may omit decorative statuses/widgets but never fabricate an empty editor at
a nonzero revision. Status text and its extension-owner attribution are one atomic
projection: pressure clears both so an orphan owner can never invalidate `session.open`.
String-widget updates are also admitted atomically: unsupported or
oversized content leaves the prior widget unchanged and never throws through an
extension-owned timer or event callback into the Gateway process.
Pending interactions remain live across ordinary client disconnect and all imperative
presentation is excluded from offline mobile cache. Wire interactions are method-discriminated
by Gateway and native admission: select requires options; confirm forbids select/input/form
fields; input and editor permit text defaults but no form; form requires the bounded form v1
descriptor and forbids every primitive-dialog field. Native editor updates admit an
empty or whitespace-only text payload without trimming; per-session clients coalesce
possibly-sent updates and treat revision conflicts as ordinary convergence rather than
user-visible failures. Exact extension commands persist a provisional run marker
before their handler starts; forced shutdown preserves admitted-work markers while a
verified clean idle shutdown removes them.

The dormant Phase 4A feasibility harness uses only the public `@earendil-works/pi-tui`
package root. A bounded in-memory terminal drives `TuiMainScreen` without stdin or
stdout; recording proxies retain one result per mount/compositor pass without a
second host render call, and
a fail-closed parser converts logical lines into bounded plain text, concrete RGB
style runs, safe HTTP(S)/mailto links, and cursor position. The parser strips terminal
movement, device, clipboard, title, image/file, DCS/APC/PM, and other control
sequences and never forwards ANSI. Production remains bound as `mode: "rpc"`:
semantic status/widgets and select/confirm/input/editor dialogs use the RPC
projection, while retained component-valued widgets are captured as bounded,
read-only generic surfaces. Terminal images, Kitty key releases, and component input
remain unavailable.

Phase 4C currently exposes a bounded first UI validation pass: one bounded,
epoch-scoped host/store owner, generic full-frame protocol models, strict admission,
atomic revisions, stale-callback protection, exact-once disposal/settlement, and
reload/shutdown/drain/reconnect-safe ownership. The direct harness admits at most one
non-overlay blocking custom call and uses the pinned public pi-tui keybindings
manager; the production RPC host rejects blocking custom calls before invoking
extension factories because no native client surface exists for them. Overlay
custom calls fail closed before factory invocation with one bounded
deferred diagnostic and publish no overlay surface. Component input, arbitrary custom
UI, native custom/overlay rendering, footer/header/editor/autocomplete, theme UI,
renderer hosting, package-specific integration, and truthful TUI activation remain
deferred.

## Tool identity, progress and nested calls

Live and canonical transcript projections preserve the canonical tool name while optionally carrying the bounded human-readable `label` declared by the mounted Pi extension tool definition; native clients use that label for presentation and never derive extension titles from snake_case names. Project Resources exposes the same label beside the canonical name. Live tool projections may also carry an optional extension provenance record derived from the public Pi tool `sourceInfo` and the loaded extension inventory. The Gateway emits that record only when exactly one extension owns the tool and the source path agrees; unknown or ambiguous ownership omits provenance and fails open to the ordinary tool projection. This metadata is disposable presentation state and never modifies Pi JSONL.

Parallel tool events carry a monotonic per-run ordinal; each call additionally has
a monotonic progress sequence, bounded display-safe live-output tail, runtime start,
last-progress/completion timestamps, and a duration measured from the tool callback
with a monotonic clock. Every running progress delivery and reconnect snapshot refreshes the monotonic duration sample,
even when the tool emits no output; the completion carries the final call-to-return duration. Accepted samples never decrease.
Canonical result handoff refreshes the current running sample before retiring only the
disposable runtime row, then preserves the original monotonic start and bounded timing metadata
until terminal delivery or agent settlement. A snapshot between handoff and a late compatible
terminal callback therefore cannot expose the stale near-zero start sample, and the callback
cannot reset the call to a near-zero duration. A fresh lifecycle replaces noncanonical stale
metadata; an exact tool-call ID that already owns a canonical result fails closed instead of
inheriting timing or lineage across invocations. The Gateway
coalesces high-rate updates without losing the newest state. Direct `session.bash` execution
uses the same runtime-only metadata projection keyed by its canonical Bash entry, so current-
Gateway rows carry exact start, completion, and monotonic duration while older history remains
valid without those optional fields. Running readable output is a bounded current-frame
channel: each newer nonempty frame replaces the previous display in place, while an empty advisory
frame preserves the last readable output so detail views never flash blank. A nonempty terminal result
is authoritative. Clients join
calls, progress, and results by canonical call ID rather than arrival order. A live assistant
frame is projected only while its explicit Gateway presentation identity remains owned. After
canonical binding retires that identity, a briefly retained Pi `streamingMessage` cannot create
a second stream identity or duplicate finalized tool groups in a settlement snapshot.

Pi nested tool calls keep their `<parent>/<n>` identity under the model-issued call; they are
never independent transcript rows, invocation receipts, segments, or extension activities.
Live parent progress and the canonical parent result carry the same bounded child list: every
call Pi records (`NESTED_CALL_LIMIT`, Pi's own 256), with each call's arguments at most 1 KiB and
all of a parent's arguments together at most 32 KiB (Pi's total); an argument outside either bound
is replaced by its byte count and clears the `complete` flag. Child failures use `failed` even when the tool returns `isError` instead of
throwing; Pi's `unfinished` child status remains an explicit terminal presentation state when
recovered from history, and each child error is projected to at most 512 UTF-8 bytes. Opaque
`structuredContent` is not forwarded by generic live tool-result projection.
The integration E2E in `runtime-registry.integration.test.ts` exercises a faux-provider codemode
script with parallel `read`, `bash`, and non-throwing failure calls; it retains
`test-results/pi-sdk-099-nested-calls.json` for live and cold-reload inspection.

## Queues, prompt admission and compaction execution

Active message queues are projected with stable per-entry IDs, delivery behavior,
display text, total attachment count, optional photo/file counts, optional bounded upload descriptors,
and a monotonic queue revision. Descriptors contain only upload/blob ID, safe name, MIME type, and size;
attachment bytes remain in the owned upload store and are fetched only through authenticated blob access.
For newly admitted steering/follow-up work, the returned prompt operation ID is the queue entry ID;
clients can therefore settle one optimistic submission without content-based queue guessing.
A Gateway advertising
`queue-management.v1` includes both `queueRevision` and `queuedItems` in every authoritative
session snapshot. The pinned Pi queue itself still exposes string arrays rather than
queue records. RuntimeSlot therefore retains the exact admission ID before accepting another
queued mutation, publishes it from the same serialized lane, and treats later text arrays only
as bounded live-runtime delivery evidence. Every snapshot separately exposes
`acceptsQueuedPrompts`, derived directly from Pi streaming state rather than broad presentation
phase or the queue-management CRUD capability, except that it is also true while compaction runs.
Pi rejects input during manual compaction, and its own front end keeps an "after compaction"
queue; RuntimeSlot is that front end for Tron. A client prompt sent while the session is
compacting, or while earlier such prompts still wait, returns its operation ID at once and joins
a Gateway-owned waiting queue projected after Pi's queue in `queuedItems` (default behavior
steer). `session.queue.replace` and `session.clearQueue` edit, reorder, and remove waiting entries
synchronously rather than behind the compaction that owns the session lane; one edit spanning
waiting entries and Pi's queue is rejected as a retryable conflict. When compaction settles,
including after Stop, the waiting entries are admitted in order through the ordinary prompt path:
the first starts a run when the session is idle and becomes its `pendingPrompt` in the same
publication, and later ones join Pi's queue with their behavior. A new compaction pauses that
flush. An entry proven unable to start emits `session.operationFailed` with its operation ID; an
uncertain outcome emits a diagnostic. Waiting entries hold `queued-mutation` work, so an
administrative drain waits for them, and they are process-local like Pi's queue. Automation
prompts and extension commands never join it. A Gateway process restart does not replay or claim
identity for an SDK-only queue; reconnect reports only surviving canonical/runtime truth. If the
runtime generation changes before canonical delivery, iOS restores unresolved accepted work for
explicit user review without replay. This includes the one bounded local handoff retained after an
exact queue row already retired the optimistic admission.
The legacy steering and follow-up string arrays remain a compatibility projection for older
clients and Gateways; they never authorize entry-level mutation. Pi reports steering removal
before its user-message callback, so RuntimeSlot retains the exact consumed steering
operation through that callback, writes its canonical binding, and terminalizes only that
queue operation; the enclosing foreground run keeps its own marker and completion owner.
`session.queue.replace`
serializes with prompt admission and clear operations, validates bounded replacement
state, rejects stale revisions, and rebuilds the pinned runtime queue atomically.
Steering entries always precede follow-ups because that is the runtime's delivery
order; reordering is authoritative within either behavior, and changing behavior
moves an entry into the corresponding delivery stage. Attachments remain bound to
their original queued identity and cannot be fabricated by clients. Queue snapshots
are bounded to 32 entries, 64 KiB per display message, and 256 KiB total.
Prompt RPC admission follows the pinned runtime's preflight callback as its sole outcome.
Provider retry waiting is projected as `retrying`; the pinned SDK's `agent.continue()`
emits `agent_start` and restores `running` before the resumed response. Retry-attempt
metadata remains until `auto_retry_end` at assistant completion, so its presence is not
waiting-state authority. The focused RuntimeRegistry retry-resumption test exercises this
real SDK sequence and a fresh acquisition during the blocked resumed response.
Because the pinned Pi SDK can clear its streaming flag before the final `agent_settled` choreography reaches
the Gateway, ordinary admission additionally waits behind the existing sequenced foreground operation
owner whenever runtime streaming is false but settlement/compaction/retry state is still active. The
Gateway re-evaluates delivery behavior after that transition and never invokes an ordinary Agent prompt
inside the settlement gap. If Pi becomes idle inside an asynchronous input hook, RuntimeSlot resolves
that exact admission from the resulting queue update, user-message callback, or handled-input completion
instead of retaining a stale queue latch. A Pi call rejected before any of those disposition facts
terminalizes and releases the exact admission rather than leaving the serialized RPC pending. It does not race preflight against a local deadline that could report rejection while
the same uncancelled runtime call later starts canonical work. While the canonical user
entry is pending, the snapshot's bounded `pendingPrompt` projection carries ordinary display
content only; requested queue behavior appears only after Pi actually enqueues it. The Gateway claims the exact Pi user-message object,
retires the projection only for that same message at persistence, and exposes the prompt
operation ID as the canonical user's bounded `presentationId`; repeated text therefore
cannot settle the wrong mobile admission. A known operation ID never falls back to content matching on
iOS. `session.operationFailed` is reserved for an exact operation proven unable to produce canonical
input; only that sequenced fact may retire and restore its matching composer admission. Receipt,
binding, and post-admission runtime failures emit non-settling `session.diagnostic` events instead of
lying about accepted execution. Definitive transport rejection/no-agent settlement clears
the same owner, so iOS can reconstruct an in-flight prompt across navigation without replay.

Every session runtime installs an abort-aware adapter on the public Agent stream boundary,
shared by ordinary responses and compaction/branch summaries. The pinned SDK's lazy request
setup can report an already-aborted signal as an ordinary assistant error; after cancelled
between-turn compaction, that misclassification can trigger a replacement automatic compaction
while Stop waits for idle. The adapter preserves streamed progress, content, usage, and successful
results, but classifies terminal errors as `aborted` when their exact request signal is aborted.
Pi's existing cancellation guard then prevents post-run retry/compaction of that cancelled response.
It does not infer cancellation from error text, disable future compaction, or synthesize idle;
Stop still waits for real runtime settlement and durable invocation/marker retirement. The focused
`runtime-compaction.integration.test.ts` exercises this sequence against the pinned SDK and proves
that the next explicit prompt can compact normally. Pre-prompt compaction is different:
Pi has not created its Agent abort signal yet. The existing invocation cancellation set
therefore fences the exact public `preflightResult` admission callback as well. Gateway
projects its owned preflight as running while auth/preparation is pending. Stop at
`compaction_start` also revokes compaction admission before a late SDK controller can
start generation. Automatic compaction additionally checks its enclosing prompt's
cancellation after summary auth, since the display operation ID may rotate after Stop. The
pinned SDK exposes no cancellation signal for its auth/preflight wait, so Stop may return a
retryable pending/conflict outcome after the bounded grace; Gateway does not claim settlement
until the exact receipt completes. A rejected preflight joins its SDK promise, persists an interrupted
(`user-abort`) or failed receipt, retires the exact marker, and only then publishes idle.
No cancellation is inferred from the spinner, and a late Stop cannot cancel a successor.

Manual compaction has a separate Gateway-owned single-entry maintenance admission. Its
synchronous claim covers pending, direct, and queued execution, so a second request is rejected
rather than serialized behind the first. An idle request starts canonical compaction immediately.
A request accepted during an active agent run publishes `compactionQueued` and persists its own exact
run marker. The first SDK compaction that starts after the request was queued adopts it, regardless
of whether its reason is manual, threshold, or overflow; the queued flag clears at that start, and
the original command receipt settles with that compaction's result only after its exact marker is
durably removed. If the adopting compaction fails or is cancelled, the queued request fails instead
of launching another manual compaction. The enclosing prompt still owns and persists its own terminal
receipt independently of adopted-marker cleanup. Each preceding prompt retires its own marker, and
compaction never sweeps a successor's marker. A completed manual-reason compaction retires its exact
compacting projection after marker cleanup, unless a successor already owns the slot. Every successful or failed
`compaction_end` publishes one immediate fitted authoritative snapshot with the current canonical
tail/leaf and restored prompt/automatic-idle state; manual work remains compacting until its durable
marker retires. Each terminal compaction is logged as `session.compaction.completed` with the exact
session, available operation ID, trigger reason and success/failure/cancellation outcome. Automatic
failures emit `session.operationFailed` while that compaction still owns the slot, so iOS shows a
sequenced failure notice without allowing late cleanup to report against a successor. Exhausted
overflow recovery can end without a new start; it is logged and surfaced without inventing an
operation ID or changing the current operation. Cancellation is not
reported as failure, and diagnostics contain only bounded, redacted provider error text—not prompts,
transcripts or credentials. The focused failure, cancellation and successful-compaction regressions
live in `runtime-compaction.integration.test.ts`. Manual admission keeps its operation ID and start
time through the SDK's
`compaction_start`. A hook-launched successor gets its own visible Stop identity at `agent_start`;
older cleanup retains its captured compaction owner across SDK and marker awaits and cannot erase
the successor's abort intent, phase, or marker. The
compaction operation identity is retained on the projected canonical compaction entry as presentation-only metadata, so compacting and compacted content occupy one physical row even
when bounded transcript ranges change precision. Hooks may append after the compaction entry, so
the Gateway does not spend a cursor on a single-entry delta that is already a non-leaf.

This state is not a
prompt queue entry and is never replayed by iOS. Snapshots also project the runtime's effective
`automaticCompactionEnabled` value; both fields remain optional for rolling clients.

## Session creation and worktrees

Session structure/context/resource invalidations refresh
already-presented secondary surfaces. Provider, settings, trust, package, and
custom-model mutations publish bounded global invalidations so another connected
client refreshes its explicitly scoped canonical projection. `session.create` accepts an
optional source-control strategy. The Gateway admits only exact mode-specific objects and
rejects unknown or cross-mode fields before constructing the internal request. `existingCheckout`
passes the selected directory through unchanged; `newBranchWorktree` creates a managed Git worktree on a new branch from `HEAD` or
a validated committed base ref. Read-only `git.inspect` includes up to 200 local branch choices
with worktree occupancy and 100 recent commits reachable from refs; these are bounded UI hints,
not permission to create a checkout, and creation revalidates current Git state.
`existingBranchWorktree` creates a managed worktree from
an existing local branch. Git arguments are passed without a shell, branch/ref inputs are
validated, implicit-`HEAD` creation refuses dirty checkouts, and a worktree is removed again
if session creation fails. Only a proven successful add may clean up its exact managed worktree and
compare-delete its branch at the recorded base commit. A failed or uncertain add grants no branch
cleanup authority; ambiguous residue is preserved rather than deleting a concurrent winner's branch.
Cleanup verifies the current worktree association and preserves moved branches. Git output retention is
byte-bounded. Success and failure both check descendant process-group retirement; a timeout requests
termination and returns a non-retryable unknown outcome at its hard deadline if retirement cannot be
proven. No destructive rollback races an unresolved Git command. Managed worktree roots and repository directories are created and
checked with non-following directory metadata, then realpath containment is proven before Git
runs, so pre-existing symlinks cannot redirect a target. Pi itself receives only the resulting
canonical `cwd`; its SDK has no Git/worktree creation option. Persisted worktrees remain available
for later sessions and are never silently deleted with a session.

Explicit workspace Git operations share `machine/workspace-git-environment.ts`:
`cwd`, not an enclosing hook's `GIT_DIR`, `GIT_WORK_TREE`, `GIT_COMMON_DIR`,
`GIT_INDEX_FILE`, `GIT_OBJECT_DIRECTORY` or `GIT_ALTERNATE_OBJECT_DIRECTORIES`,
selects repository/index/object storage. Both inspection and worktree mutation use
this policy, including cleanup. Normal user/global Git config and repository-owned
object alternates remain available; the read and mutation runners retain their
distinct limits and process-retirement contracts. The real-repository workspace
inspection and worktree integration journeys prove foreign context cannot replace
the selected root, HEAD, staged state or refs, and preserve configured checkout hooks.

## Session-bound terminals and subscriptions

PTY output has an independent monotonic
sequence and wire-safe attach replay for gap/reconnect convergence. The global
terminal catalog retains at most 128 records in insertion order, evicting only
the oldest exited records before creation, while at most 16 PTYs may remain
active. Destructive termination signals the complete PTY process group and its RPC
resolves only after the node-pty exit callback has retired canonical active-terminal
state and published `terminal.exit`. Output is split at UTF-8 boundaries into at most 64 KiB events, and
replay uses encoded JSON byte accounting below the 1 MiB frame ceiling. Context, tree,
resources, commands, exports, transcript paging, terminal inventory, and all live-runtime mutations
require an established open subscription for that exact session. Dashboard rename and delete remain
explicit catalog-scoped exceptions. Terminal creation and attachment require the terminal's current
session subscription; each connection's installed subscription-token map is the sole local
subscription index for routing, admission, rekey, and revocation. Input, resize, and termination additionally require attachment ownership on the
requesting connection. Closing a session immediately revokes attachment admission. These checks
prevent stale client selection or reconnect races from reading or mutating a different runtime,
controlling another connection's PTY, or leaving an orphan terminal process.

## Session-bound workspace inspection

`workspace-inspector.v1` adds only session-bound reads: `session.workspace.inspect`,
`list`, `file`, `git.diff`, and paginated `git.history.list/get` all require an
established subscription and derive their root from the runtime slot's canonical
`cwd`; mobile input can never substitute an absolute workspace. Directory and
status projections fail atomically at their count/byte ceilings, relative paths
cannot traverse or follow symbolic links, and directory/file reads revalidate canonical containment and inode
identity before publication. Directory metadata uses a fixed 16-operation concurrency ceiling instead of serial
filesystem round trips. File previews are no-follow snapshots registered in the existing 25 MiB bounded blob store;
the content-addressed blob identity also owns their revision, avoiding a second full-file hash. Git runs without a
shell, pager, external diff, or text conversion, uses the configured Git executable and deterministic locale, and
kills the detached process group on timeout or output overflow. Concurrent identical workspace inspections share
one in-flight status projection without caching completed truth. Status uses porcelain-v2 NUL records and represents named,
detached, and unborn heads explicitly. Per-file working-tree diffs are produced lazily and bounded before transport;
staged, unstaged, history, and commit-detail reads use an operation-scoped canonical repository context and avoid a
full recursive status scan when they only need a selected path or immutable commit evidence. Independent commit
metadata and changed-name commands execute concurrently after commit visibility admission.
`workspace-history-diff.v1` adds the equally bounded `session.workspace.git.history.diff` read: it admits only a
full commit already visible in the session workspace's history and a contained relative file path, then renders that
commit's first-parent patch without external diff or text-conversion hooks. History cursors are authenticated, client/root/scope
bound, expiring, and pinned to the selected tip/ref generation, so reset, rebase,
or ref mutation forces a fresh traversal rather than mixing pages. Clients use
visibility-scoped reconciliation reads for live presentation; filesystem state
is never mirrored into canonical session storage.

Workspace browsing streams directory entries
from an identity-checked directory handle and fails visibly, without returning a partial listing,
above 1,000 examined entries or 768 KiB of projected metadata; ordinary folders retain the established directory-first
ordering and exact paths.

## Accepted runtime leases

Accepted `session.prompt` and `terminal.open` mutations synchronously retain their
exact live runtime before receipt I/O and pre-effect materialization/resolution
awaits. The idempotent lease is released on success or rejection; existing
automation leases share that slot-retention authority. Retention does not recreate
an observer or a missing runtime. Completed receipt results remain available on
ordinary reconnect without requiring a new session subscription or replaying the
operation. A foreground prompt starts its durable run-marker write before returning
its admission, but does not wait for the fsync; the exact marker owner remains in
the drain set and the write is observed for retry/blocking diagnostics. Settlement
and marker clear still await that owner, so a failed marker cannot be mistaken for
a settled or replayable run.

## Commands and typed resource invocation

`session.commands` preserves runtime sort order and rejects catalogs above 1,000 rows
or 700 KiB, duplicate full `source:name` identities, empty names, invalid resource scope/origin,
names above 512 UTF-8 bytes, or other command metadata strings above 8 KiB before generic JSON projection can truncate the response.
Each row includes the runtime loader's source, scope, origin, and path when available. The lazy
`session.commandDetail` read requires one exact current `source:name` identity and returns
that selected prompt, skill, or extension source document only; content is UTF-8 bounded
to 96 KiB with original byte count and explicit truncation metadata, so catalog loading
never reads or copies every resource body. `session.prompt` accepts `resourceInvocations`, the ordered typed resources one message invokes (#311):
any mix of at most 16 skills and prompts, each at most once and with empty `arguments`, or exactly one
extension command whose `arguments` equal `text`. The Gateway revalidates each exact live `(source,name)`
identity and extension-command precedence. An extension command is Pi's literal leading command and
rejects attachments at the Gateway boundary regardless of client behavior. Skills and prompts are
composed by the runtime in its lane (`composeResourcePrompt`): each expansion in order, then the visible
prompt once, handed to Pi with expansion off, so text that looks like a command stays message text. A skill
block is byte-identical to Pi's own expansion; a prompt template expands as Pi would with no arguments.
A saved automation still names at most one skill or prompt and runs it as a one-resource message by the same rule.
Pending and queued projections retain the same typed list; start receipts record it as `resources` with
the typed text as `submittedText`, and canonical binding receipts attach both to the resulting user entry,
whose projected text is the typed text, so native chips survive restart without exposing expanded skill
contents or private paths. A start receipt written before multi-resource messages names its one resource
through `source`, `name` and `arguments` and still projects as that resource. Resource names are bounded to
512 UTF-8 bytes and arguments to 5,000 bytes (the receipt-safe semantic bound); newline, carriage return, and
tab are allowed prompt content, while other controls and unknown fields are rejected. Extension and skill
commands typed as text use Pi's literal ASCII-space delimiter; prompt templates retain Pi's whitespace
delimiter after extension precedence. Binding receipts
contain canonical target identity only; start receipts own resource identity and trusted producer
provenance and are recovered from canonical JSONL if live runtime maps have already settled. Image-bearing
prompt starts also retain the exact submitted text (bounded by the prompt limit); Pi may append generated
image-resize coordinate guidance to its canonical user-message text. Transcript clients use this receipt
provenance for display only and must preserve canonical model history, attachment parts, and user-authored
text that resembles an SDK note. Full
and paged transcript projection apply that start-receipt origin only through the exact canonical
binding, so Gateway-owned Automation prompts retain their `Automation` producer, Automation ID,
and `automation:<run UUID>` operation namespace across reconnect and cold reconstruction while
unbound ordinary prompts remain user-originated. Queue edits preserve immutable intent by
terminalizing the prior invocation and appending a replacement start/accepted pair under the stable
queue operation ID. Explicit removal appends an interrupted terminal receipt rather than leaving an
accepted orphan, so later canonical binding and cold projection describe the text Pi actually receives. Receipt construction never silently truncates semantic data; persistence/binding diagnostics
are not operation failures and cannot retire an accepted composer row.

A new Pi session remains memory-only until it receives its first user or assistant message.
`appendCustomEntry` receipts recorded before that point are persisted together when the first user
message is appended; a crash before any user or assistant message can still lose the entire new
session and those in-memory receipts. Once the first user message is appended, its invocation receipt
survives a Gateway runtime teardown and reopen from the canonical JSONL. iOS disconnect alone does
not trigger this window, and sessions with a persisted message append receipts immediately. Gateway
must not poll for the file, write Pi's JSONL directly, fabricate an assistant entry, or create a second
receipt journal.

Canonical mobile projection recognizes
only Pi's exact 4 MiB-bounded persisted skill envelope, strips the private skill body/path, and
projects its user arguments through the existing attachment extractor. Malformed skill-looking
envelopes become a generic omission rather than leaking or destructively guessing private data.
Summarizing tree navigation owns foreground branch-summary state only for the exact
awaited call; success, extension cancellation, and provider failure all retire that
state and publish the settled snapshot before the serialized mutation lane advances.
Session statistics include the runtime-calculated latest cache-hit rate used by the
terminal footer, so mobile clients do not invent a different ratio.
