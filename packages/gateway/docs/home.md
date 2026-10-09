# Tron Home

Tron Home is an opt-in persistent conversation, one per Gateway installation:
`~/.tron` and `~/.tron-dev` each own their own Home. This document owns what
Home does today: its designation record, its curated runtime, its memory, and the
request seam that sends each activation the memory's view instead of the
canonical transcript. Home delegates finite project work through `delegate` into
ordinary worker sessions with explicit immutable reports, shared task controls
and durable spend status. Results wait in Home's durable inbox for the next user message, with one advisory push at most. Home's own client surface is a later slice. Ordinary sessions
are unaffected by every rule here.

## Physical chapter mutation boundary

RuntimeSlot owns physical-session mutations. Its serialized owners consult a
chapter-state provider before prompt admission, configuration, rename/label
edits, branch changes, bash, and extension-driven session replacement. Registry
owners also preflight attention, archive and delete mutations against that same
provider. A sealed result is a
typed `conflict` (`details.reason: "sealed-chapter"`) and is never redirected.
Every bound Home slot also refuses physical identity/path replacement (RPC fork,
extension newSession/fork/switchSession), including active and disabled chapters,
with typed `conflict` (`details.reason: "home-identity-replacement"`). One slot
replacement boundary rejects before SDK effects; HomeOwner alone transfers the
logical binding to a separately Registry-owned chapter. Ordinary slot replacement
is unchanged.
The canonical append guard is installed before SDK runtime bootstrap, once per
SessionManager instance. The manager's append method carries its immutable slot
owner; reloads and profile rebuilds reuse it, never stack wrappers. A different
manager gets its own guard at construction, and manager retirement retires it.
`home-request-seam.integration.test.ts` retains identity/path/byte refusal and
five rebuilds plus five reloads per ordinary/Home manager in
`test-results/home-activation/seam-report.json`.
The version-2 Home record carries an ordered chapter ledger. At a quiescent
turn boundary, crossing either the 24 MiB canonical-byte or 50,000-entry soft
limit seals the active chapter and durably reserves its successor; this writes
only bounded metadata. Before a new `home.prompt` receipt binds its physical
target, Home checks canonical bytes and entries; a chapter already at or above
200 MiB or 100,000 entries is sealed and its successor reserved before any
activation effect. The next `home.prompt` activation is the only path that
materializes that reservation. A sealed chapter remains readable but refuses
mutation regardless of Home's enabled state or the runtime's ordinary/Home
profile. The chapter-state check is physical-session-owned and is not bypassed
when Home is disabled. Registry serializes attention set/acknowledge, archive,
delete and sealing per physical session: admitted mutation work settles before
seal; seal-first refuses later mutations. The session serializer precedes the
existing Registry/slot/attention lanes; HomeOwner takes its record lock only for
the final ledger replacement, never before the session serializer. Queue tails
retire at settlement and a failed mutation cannot poison the next one.
The Registry materializer claims one attempt per reserved
chapter, scans every candidate before adoption or creation. The same strict
complete-file scan runs before a cold Home runtime is opened or searched.
Generic JSONL import is a separate Registry admission followed by an SDK fork:
it preserves the caller's source path in `parentSession` and checks capacity
before source construction, without Home chapter scanning. The Home scan uses
the exact canonical file's owning directory, not a directory re-encoded from cwd:
workspace aliases must not change evidence ownership, including cold search.
The version-3 scanner validates the header, supported entry/message content and
usage shapes, unique IDs, and one
append-ordered parent chain beginning with a null parent. Cycles, forward or
missing parents, duplicate IDs, extra roots and branches refuse before SDK
construction; parent validation is one pass, never a graph traversal. Unknown
entry shapes and non-newline-terminated evidence block before Pi's loader can
repair it. Evidence is streamed one line at a time under an unchanged-file stat
fence. The 200 MiB scan bound applies only to the matching identity or expected
path being adopted: a retained oversized stopped predecessor cannot block its
successor. No arbitrary per-entry cap discards valid abort settlement evidence.
Sealed chapter memory reads use
the read-only canonical JSONL projection, never a writer-capable SessionManager.
`home-session-recovery.test.ts` covers malformed graphs and supported entry
shapes. The real-byte-stop and cyclic-cold cases in `home-activation.e2e.test.ts`
retain rows in `test-results/home-activation/report.json`: real SDK appends stop
a running operation over 200 MiB, preserve its oversized chapter and prompt a
successor; malformed cold evidence reaches zero writer-capable constructions.
The materializer durably records
the exact SDK path and attempt ID before the caller can receive the runtime.
The constructed RuntimeSlot owns immutable authority for that exact Home chapter,
attempt, and path through its disposal; receipt persistence and the first
conversation append use that same owner. Authority is checked against the live
ledger and exact session identity, not granted by an individual operation or
receipt lifetime. Unreadable, malformed, torn, duplicate, symlinked, or
path-mismatched evidence blocks recovery without changing canonical bytes. If a
durable prior attempt names a path that is now absent, recovery also preserves
and blocks: the pinned SDK has no verified exact-path constructor, and its
ordinary new-session API selects a different timestamped path. A post-rename
ledger publication error fences all Home admissions and profile transitions.
The owner securely reloads the visible record, and Registry retires every live
Home slot through its existing disposal path after that slot's current operation
settles. The writer does not await retirement from inside that operation's lane.
Home remains unavailable until both reload and retirement complete; the next
acquisition constructs a fresh slot from the reloaded ledger and canonical
transcript. A failed reload or retirement keeps the fence closed rather than
trusting stale memory. Gateway JSONL and HTML exports
are noncanonical destination writes owned by RuntimeSlot's existing temporary-
artifact export boundary: it snapshots the canonical source into a fresh temporary
directory, then registers that artifact. Home does not expose arbitrary SDK export
destinations, and export leaves the chapter path unchanged.

`home-materialization-crash.e2e.test.ts` freezes the actual old ledger writer at
claim, path-record, first conversation flush, and post-rename/pre-directory-fsync
cuts, then opens a fresh Registry over the same files without disposing the old
owner. It also exercises a live Registry's visible-publication error fence,
`publication-uncertain` retirement, and fresh disabled-profile reconstruction.
Run the focused file with `HOME_MATERIALIZATION_CRASH_REPORT=<artifact-path>` to
retain its JSON report. The separate `home-ledger-crash.e2e.test.ts` exercises
seal/reserve with a real child process and SIGKILL; frozen-owner cuts prove
process-abandonment recovery, not power-loss durability.

`home.open` returns Home's logical route and current binding. `home.prompt`
persists an idempotency receipt containing the Home identity, binding revision,
and selected physical chapter before materialization or dispatch, then verifies
that binding again before sending the input. A stale binding cannot silently
redirect a command. Completed receipt replay returns the original result and
physical target, even after rollover or disable, without resolving a new route,
materializing a chapter, or dispatching the input again. Pending or uncertain
receipts remain outcome-unknown fences; a reconnect never resends accepted input.
The receipt owner emits `home.route-bound` with `category=fresh|replay` at its
durable-target/replay decision. `home.open` emits `category=open` and is not an
activation or receipt. Registry shares only reserved-chapter construction, never
command input or receipts. Every distinct joined command has its own durable
target and slot admission: accepted input is submitted once; a busy contender is
explicitly refused before SDK submission. A duplicate command joins/replays its
receipt lane, not another input. The joined user/terminal cases in
`home-activation.e2e.test.ts` hold claim, scan, recorded-path and first-flush
boundaries and retain their outcomes in `test-results/home-activation/report.json`.
Their soft-rollover setup injects metrics; these cases prove submission/receipt
ownership, not chapter-size thresholds.

`home-receipt-crash.e2e.test.ts` retains
`test-results/home-receipt-crash/report.json`. Its child fixture,
`test-support/home-receipt-crash-child.ts`, uses the real receipt atomic writer and
pinned SDK canonical flush, reusing `home-ledger-crash-preload.mjs` and the ledger
harness's parent-owned pipe lifetime. SIGKILL cuts after durable binding, during
SDK effects before completion, and after durable completion before response
prove pending fences and exact completed replay without rerouting or effects.
These are receipt/SDK persistence-boundary tests, not a live-provider Gateway
process or power-loss test. Regenerate with the named Vitest file.

Terminal chat uses these logical RPCs when Home is enabled and subscribes to the
physical runtime only after a chapter is active. Ordinary session routes are
unchanged.

Home transition signals are typed in `home/home-diagnostic.ts` and go through
one privacy-preserving logger boundary. Recovery uses `absent|adopt` (not
`create`) and `conversation-published`. Hard admission refusal uses
`home.chapter-refused` with `hard-bytes|hard-entries` and the measured chapter
ordinal, before rollover or a busy response awaiting settlement. A running
crossing instead emits `home.chapter-limit-stop` at warning level after exact
Stop settlement: chapter ordinal, boundary, crossing bytes/entries and settled
bytes/entries survive both JSONL persistence and tail reload. No canonical IDs,
paths, transcript, credentials or free-text owner failure explanation belong in
these signals; owner unavailability is the bounded reason `owner-fenced`.
The observability catalog owns the complete emitted reason vocabulary.
`home-activation.e2e.test.ts` retains `test-results/home-activation/report.json`
for exact receipt replay and signal privacy. Threshold diagnostic tests inject
measurements at the owning metrics seam; they are not actual large-file proofs.
The canonical-admission and response/input-crossing cases instead append real SDK
entries and lower only the shared hard constants in the test module (64 KiB / 100
entries); their artifact records measured bytes/entries and the test thresholds.
They prove cold logical rollover, immutable physical refusal, post-await
revalidation before canonical effects, a pre-provider input crossing, and both
completion-first and abort-first settlement of a successful assistant crossing.
They do not prove the unrelated full writer/crash matrix.

HomeOwner owns one hard-admission policy for both logical routes and physical
prompt targets. Cold Registry metrics stream the actual canonical file under a
stat fence, excluding its header from the entry count; missing, torn or changing
metrics refuse rather than pretending the chapter is empty. Logical admission
rolls over before binding its command receipt. Every physical prompt (including
explicit terminal targets, held prompts and steer/follow-up admissions) rechecks
the policy in its slot lane after admission awaits, before invocation/SDK effects;
a full physical target refuses without silently redirecting. Ordinary sessions
are not subject to Home thresholds. The exact Stop owner synchronously records
its reason on the live invocation before cancellation yields. Every terminal
observer reads that reason at the common receipt boundary, so a successful
assistant crossing is interrupted with `chapter-limit`, never `user-abort`,
regardless of completion/abort settlement ordering. Receipt retirement owns
retirement of that volatile reason; no parallel cancellation-reason map exists.

Home memory remains one bounded projection keyed by stable `homeId`, not by a
physical chapter. Its canonical source reads active, sealed, and materializing
chapters in ledger order and retains each physical session ID as provenance.
Delta ingestion streams and caps each entry before retaining a chapter projection;
it never concatenates raw chapter histories. Per-chapter cursors continue linear
active appends (including non-message entries) and stat-check, rather than reopen,
unchanged sealed files. A navigation or context edit rebuilds only the active
chapter's capped branch; it cannot omit earlier chapters. The last writes before
sealing are ingested before that chapter's cursor becomes immutable. Missing or
changed sealed identity, size, modification time or change time blocks ingestion
before updating the projection.

Historical-cut lookup is a separate contract: it streams a compact ID/parent
index only through each chapter's **ingested** byte offset and verifies the full
prefix digest and physical provenance. It may read sealed bytes for this proof,
never later active appends. Message and non-message boundaries resolve to the
permanent logical indices at that exact cursor; off-branch entries have no cut.
The Home source cursor format is version 2 and requires its sealed-file metadata.
Older Home cursors are preserved and refused, with memory unavailable; there is
no migration or automatic rebuild. Ordinary session formats are unchanged.

`home-source.e2e.test.ts` retains `test-results/home-memory/continuity.json` for
cross-chapter replay, restart, navigation and frozen-cut proof.
`home-source.scale.test.ts` retains `test-results/home-memory/heap.json` for four
chapters containing at least 64 MiB of canonical payload, with post-GC live heap
samples at ingestion cuts and a retained heap sample. Regenerate with the named
file and `vitest.scale.config.ts`; the heap report does not claim an allocation
peak or power-loss proof.

A reserved chapter contributes nothing until canonical evidence exists. If an SDK
operation fails after staging canonical entries, RuntimeSlot retains the existing
uncertain-outcome fence rather than treating the staged mutation as a clean
refusal. A sealed check before a custom-entry append is a clean typed refusal: it
exits the bounded ownership-write retry path without draining or fencing the
runtime.

A running activation's canonical writes are never refused at the hard limit.
RuntimeSlot observes successful canonical growth and, on the first crossing,
requests Stop for that exact operation. The crossing entry and all writes needed
to settle that abort remain canonical. No new turn, tool dispatch, steering, or
follow-up is admitted while that stop settles. The bounded
`home.chapter-limit-stop` signal records the chapter ordinal, hard boundary, and
canonical byte/entry counts at crossing and after settlement. The activation
receipt is terminalized as interrupted with error code `chapter-limit`; the next
admission rolls over to the successor.

## The record

`<tronHome>/gateway/home/home.json`, written 0600 and published atomically and
durably (temp file, rename, fsync of the file and its directory), holds one
record per installation:

| field | meaning |
| --- | --- |
| `version` | `2`; other versions, unknown fields, and invalid chapter topology are preserved and refused |
| `homeId` | Stable identity of this installation's Home, generated once |
| `chapters` | Ordered, unique physical sessions; designation starts with one `active` chapter, then quiescent rollover appends one `reserved` successor; each chapter requires its durable one-way `activationStarted` boolean |
| `bindingRevision` | Advances when designation or reserved-chapter activation binds Home to a different physical session |
| `generation` | Advances on every profile change (designate, re-enable, disable); fences in-flight operations |
| `routeGeneration` | Required positive route epoch: set at designation, unchanged through disable/re-enable and chapter rollover, advanced only on missing-session replacement |
| `policyRevision` | The curated-profile revision in force; a re-enable writes this build's |
| `enabled` | Whether Home is currently designated |
| `model` | The model applied at the last designation, updated when the Home session's model changes |
| `createdAt` / `updatedAt` | ISO-8601 instants |

The file is read with the Gateway's bounded owner-only JSON boundary: a missing file
means no designation, while a **malformed, empty, symlinked, oversized or
group/world-readable** one is **preserved and reported as unavailable**
(`home.status` returns `available: false` with a `reason`) and `home.designate`
refuses with a conflict. The strict version-2 format admits a newer
`policyRevision` without treating it as a format change, but rejects unknown
fields and invalid chapter topology. Version-1 records are preserved and refused,
not migrated. An unusable record is not evidence that
the user has no Home. Runtime admission from Home's neutral workspace also
refuses with a typed conflict while the record is unavailable; this is the
canonical installation workspace identity that distinguishes sessions which
may be Home's, including installations reached through a symlink. Sessions in
ordinary project directories remain unaffected.

## Task persistence and rollback

`HomeTaskStore` owns a separate capability namespace at
`<tronHome>/gateway/home/tasks/`, beside (not inside) the v2 Home ledger. It is
not workspace content, canonical session JSONL, or episodic memory. The directory
is 0700; every JSON file is 0600, bounded, and securely read without following a
file symlink. Parent directories must also be owner-only real directories.
There is no change to the Home record version or the frozen shared workspace
setup record.

Explicit namespace initialization publishes an empty `authorization.json` and
synchronizes the namespace and parent directories before publishing the separate
`gateway/workspace-state/home-tasks-initialized.json` marker. The marker has
exactly `{ "version": 1 }`. No task or authorization write is allowed before
this setup. An existing partial setup is preserved and refused, never completed
by guessing. Once initialized, a missing namespace, marker, or authorization
file is lost state, not a fresh installation.

Each task occupies `tasks/<taskId>.json`, at most 256 KiB of encoded JSON. The
strict v1 format requires exactly these keys:

| fields | contract |
| --- | --- |
| `version`, `taskId`, `revision` | Version 1, filename-matching identity, positive safe-integer revision; create at 1, replace only at expected revision + 1 |
| `homeId`, `generation`, `routeGeneration` | Immutable originating Home identity, enabled operation generation and logical route epoch |
| `intent`, `intentDigest` | Immutable `{ revision, text }` snapshot (text at most 64 KiB UTF-8); SHA-256 of `JSON.stringify({ revision, text })` in that key order |
| `target`, `workerProfile`, `policyRevision` | Immutable absolute target (at most 4 KiB UTF-8), qualified worker-profile identity and positive policy revision; storage is not trust/admission authority |
| `grantRef`, `scopeRef` | Nullable authority references; at most one, must name an existing authorization record, fill once then cannot swap |
| `lifecycle` | `pending`, `active`, or `terminal`; active requires authority and session/operation/controller identity; terminal requires terminal evidence and a co-committed wake event |
| `sessionId`, `operationId`, `controllerGeneration` | Nullable execution identity, populated by dispatch; shared control fences the active operation/controller generation |
| `stopIntent` | Null or exact `{ operationId, controllerGeneration, requestedAt }`; durable exact-operation Stop intent, never cleared or replaced |
| `spend` | Null or exact `{ sourceDigest, inputTokens, outputTokens, knownCostUSD, pricingProvenance, unpriced }`; safe nonnegative token counts, finite nonnegative known cost only with bounded price provenance, and an explicit unpriced flag |
| `reportRefs` | Null or at most 256 unique result references, each exact `{ resultId, sessionId, entryId, digest }`; SHA-256 pins the exact canonical report payload, which the result owner verifies |
| `wake` | Null before terminal; terminal outbox/inbox event with stable identity, logical route epoch, creation time, delivery state, push decision, exact activation binding/message digest, acknowledgement time and explicit redelivery audit |
| `terminalEvidence` | Null or exact `{ outcome, sessionId, entryIds, reason }`; outcome is `progress`, `needs-input`, `final`, `limited`, `interrupted`, or `unknown`, at most 256 unique entry IDs and a bounded coded reason; `final` requires a report reference, never a last-reply substitution |

`authorization.json` is independently owned by `HomeTaskAuthorization` through
the store's durable adapter. Its exact v1 keys are `version`, `revision`,
`scopes`, `requests`, `decisions`, `grants`; it is at most 4 MiB, with at most 10,000 records
in each array. Scope/request/decision/grant fields are strict and IDs unique.
Each request owns an exact authorization binding and a stable SHA-256 identity
(key order is defined by `authorizationRequestId`). Each decision names one
request and records its approval and expiry; one request can be decided only
once. Each grant names one approved decision, must match its request binding
and expiry, and carries that request's restore epoch. Only the adapter advances revision. Concurrent saves based on the same
revision cannot overwrite each other. Command payloads are snapshotted before
queuing, so later caller edits cannot change an accepted write.

Both file kinds replace durably via unique temporary file, file fsync, rename,
and directory fsync before acknowledgment. Unknown versions/keys, malformed,
unsafe, oversized or contradictory records preserve bytes and refuse with a
typed `HomeTaskStoreError`. `home.task.store-refused` names only the bounded
reason. A visible publication whose durability is uncertain fences the store
instance; a fresh owner must securely reload it rather than continue with stale
state. Failed pre-rename writes remove only their own temporary artifacts.
Enumeration streams bounded directory entries and validates every file: no
second task catalog, growing task snapshot, total task-count cap, or silent
pruning. Never-initialized absence is an empty read, not setup or a diagnostic
refusal; missing-after-initialization still blocks. A listing that later refuses
is not a publishable complete projection.

There is deliberately no task-membership index. The result and canonical
worker-marker owners preserve and block on missing/invalid referenced tasks;
the inbox does the same. An absent unreferenced task is
indistinguishable from one never created and has no consumer. Immutable reports
live in the worker's canonical history, pinned by task references and payload
digests, not in a second transcript store. Terminal result/authority fields cannot be replaced. Only WakeInboxOwner may
advance the nested delivery event through the store's terminal-only adapter.

Ordinary restart reloads scopes and unused grants unchanged; consumed grants
stay consumed. HomeTaskStore derives authority from the physical task directory's
`dev`, `ino` and birthtime, not a persisted document or a startup-minted epoch.
Restart and atomic file replacement retain that identity. A restore, copy or
migration of the Tron home requires reconfirming Home task permissions: directory
recreation changes the epoch, and old scopes/grants are preserved but refused
with `scope-reconfirmation-required`. An unreadable identity fails closed.
In-place overwrite that preserves the physical directory is not distinguishable
from ordinary file replacement; this is not protection against a privileged
actor restoring files into the live directory. Only explicit `home.reconfirmPermissions` (terminal `/home reconfirm-permissions`)
re-stamps active standing scopes to the current epoch. Revoked scopes stay revoked;
one-use grants are never re-stamped or renewed. Future deletion may atomically retire terminal
acknowledged task/result/event evidence only 90 days after ack; pending,
unacknowledged, blocked and outcome-unknown evidence is never age-pruned.
There is no deletion API yet.

**Rollback contract:** A build older than the record format refuses the record
(Home unavailable) and preserves it unchanged; there is no down-conversion.
The unreleased held pre-route build rejects the required `routeGeneration` field
in v2 without changing the format version or adding a version gate. Home is
unavailable for the Home-workspace cwd; ordinary chats elsewhere are unaffected.
`home-task-rollback.integration.test.ts` executes that build's actual
`home-owner.ts` from the held base ref against populated task and authorization
files. It verifies unavailable status, unchanged record/namespace/marker bytes,
and that the current owner afterwards still reads the enabled Home record. This
is an owner-level rollback integration proof, not a full installed older Gateway
binary or power-loss test.

HomeOwner constructs the store, its authorization adapter and dispatcher beside
Home's memory. Startup does not initialize the task namespace or enable a scope:
first dispatch explicitly initializes it and enables the initial trusted-project
scope. Existing/revoked/stale authority is never silently renewed. Task status/control RPCs expose durable projections and exact commands; there
is no automatic Home activation.

## Task authorization foundation

`HomeTaskAuthorization` owns the authorization rules separately from execution:
the initial standing scope covers any currently trusted project, and trust is
resolved again at admission. The standing scope is bound to the externally
supplied restore epoch; after that epoch changes, the old scope cannot authorize
work until the maintainer explicitly reconfirms it for the new epoch. A request outside an active scope requires a
one-use grant recorded separately from the human decision. The grant binds the
intent revision and digest, canonical trusted target, requested authorization
scope, worker profile, policy revision, expiry, and restore epoch; admission
atomically consumes it. Revoked,
expired, spent, mismatched, or stale-epoch grants do not authorize work. HomeTaskStore supplies the physical-directory epoch; authorization never infers
restore from ordinary startup. Dispatch uses this owner before prompt admission;
authenticated maintainer RPC/terminal controls list authority, revoke scopes or
grants, and decide pending requests. Home's model tools cannot approve grants.
A `grant-required` refusal durably records the canonical binding before returning
its stable `requestId` (also visible in the real delegate tool error). Repeated
refusals across restart refer to that same request. Decisions are not dialogs:
approval atomically records the human decision and a separate one-use grant;
denial records the decision without a grant and returns a successful receipt.
A decided request cannot mint a second grant after denial, expiry, consumption
or revocation. Approval never replays the refused task: delegate the exact intent
and target with a new task ID. Revocation and grant consumption serialize under
the same authorization mutex; whichever enters first wins. Revocation does not
stop already-admitted work (use Stop for that).

The shared `OwnedSessionDispatch` seam contains a fixed 24-hour wall-time
ceiling. Only a caller that opts in owns that deadline; ordinary sessions and
Automations do not inherit it. Expiry cancels the exact operation and waits for
its terminal completion before reporting a joined stop. The
`owned-operation.deadline-stop` diagnostic records only an opaque operation
hash, elapsed time and whether cancellation joined. The step-4 faux-provider
RuntimeSlot integration cases exercise both nonproductive and successful tool
loops, blocked provider I/O, and foreground-process join. Task dispatch applies
this same seam before asynchronous prompt preflight. The task-level faux-provider
E2E repeats those adversaries through durable task settlement and spend, with a
test-only controlled expiry of the fixed timer. No user-configurable limit or
pause-to-raise-limit exists.

## Dispatch and immutable reports

Only the enabled Home's active chapter may call `delegate` with a stable `taskId`,
bounded finite `intent` and trusted `target`. The dispatcher records pending intent
before worker effects, authorizes the exact snapshot, creates an ordinary worker
through `OwnedSessionDispatch`, and binds its exact operation before prompt
admission. Task IDs never replay an accepted prompt. A task worker has normal
project tools/resources plus `report`, but cannot replace its owned session.
The worker's canonical `tron-home-task` marker binds the task, originating Home
identity/generation, intent revision, worker session and exact operation. Cold
runtime construction checks the reference before loading executable resources;
missing/contradictory tasks are not recreated.

Finite task Stop (report, explicit control, or deadline) is terminal, unlike
ordinary chat Stop's queued-steering continuation. Accepted but unconsumed task
steers are removed with their exact interrupted canonical invocation receipts
and `task-stopped-before-delivery` error code. They are never delivered or
replayed after task settlement. A steering preflight already in progress is
fenced by the sealed/stopping report owner and receives its own refusal receipt.
`home-task-dispatch.e2e.test.ts` covers these transitions and ordinary-session
Stop continuation remains covered by `rpc-idle-admission.integration.test.ts`.

Task workers are ordinary sessions and load the same Tron-managed subagent
provider as ordinary chats; Home itself does not load it. The verified managed
closure owns provider identity/version, not a user package manifest. In v1,
Home task workers cannot run subagents; this preserves the 24-hour
termination guarantee for operation-owned work. A provider-supported
foreground-only contract will lift this. The first-party task extension refuses
subagent executions (even `async:false`, whose pinned provider configuration can
force async), revival/mutating management, and the schedule tool. Only proven
read-only management from the verified `0.76.1-tron.5` provider is admitted:
`guide`, `children.list`, `status`, `list`, `get`, `models`, plus supervisor
`status`, `pending`, `list`. The same provider's blocking `bg_wait` is allowed
and is aborted/joined with the operation; `nonBlocking: true` is refused because
its durable subscription can wake the session after report. Unknown versions or
owners refuse all subagent, supervisor and `bg_wait` calls. The tron.5 review
retains tron.4's input schema/read-only actions: only context-only progress and
child notes plus causing-tool lifecycle attribution changed; no execution route
was added. A later pin requires a new explicit review before this gate changes. Nested codemode
calls cross the same gate and explicit report/Stop boundary. Ordinary chats do
not load this gate. Trusted extensions are not a sandbox:
if the existing detached-work tracking still sees task-session work after
foreground settlement, outcome is `unknown`, reason
`detached-work-outlived-task`, never a claim of clean termination. Untracked
third-party side effects are outside the proven operation-owned guarantee.

`report` takes `resultId`, claimed `outcome` (`progress`, `needs-input`, `final`),
`text` (at most 64 KiB UTF-8), and separate `evidence` (at most 64 bounded strings;
the whole payload is at most 128 KiB). The worker cannot supply task/Home/session
identity or cost. Acceptance appends one immutable `tron-home-task-report` with
those owner identities and accepted time, seals it, and requests exact Stop
without awaiting that Stop from the tool it is joining. Task settlement joins
Stop before publishing the result. RuntimeSlot's operation settlement owns the
single terminal invocation receipt write and notifies the task observer only
after it; assistant attention completion never adds a second write path. A
successor's input joins the predecessor's terminal receipt persistence. The task
lease alone acknowledges its operation marker after durable result publication,
and only the exact task operation suppresses ordinary completion push.
Identical duplicates reuse the same entry;
conflicts refuse. References include the exact entry ID and payload digest,
never a latest-assistant pointer.

A normal final reply without report is `unknown`; a provider length stop or a
joined deadline stop without report is `limited`. The last canonical assistant
entry is attached only as evidence. A failed exact stop is `unknown`, with
`deadline-stop-failed`, `task-stop-failed` or `report-stop-failed`, not a false successful join.
Canonical provider usage is deduplicated by canonical entry identity over this
exact operation's history and persisted before live status publication and
terminal settlement. Contradictory duplicate identities or invalid/overflowing
counters refuse publication. A digest pins the source identities and deltas.
Input totals include cache read/write; output tokens are always shown. Pi's
computed `usage.cost` has no authoritative billing provenance, so all current
provider amounts are explicitly unpriced, never estimated bills.
`home.task.transition`, `home.task.spend` and `home.task.runaway-stop` emit only
bounded/hash references after durable publication. Live settlement joins the
worker's terminal/Stop boundary, then uses the same Registry durable canonical
file cut as cold `readTaskEvidence`. Live `readLiveTaskEvidence` orders Registry
session serialization before the RuntimeSlot lane, excluding late steering
receipt writes from inspection. Canonical file and parent-directory sync precede
report qualification, terminal/result/outbox publication and operation-marker
acknowledgement. Sync or source-validation failure rejects settlement, leaving
the task active without a terminal result, report references, wake or push;
existing cold recovery reconciles it on restart, never by replaying its prompt.
If no conversation file was created, the shared boundary syncs its parent and
verifies absence again. Only a settled in-process operation with a durable,
append-only Stop intent can then settle live `interrupted`, reason
`stopped-before-conversation`, with no canonical entry/report references.
Without that intent or settled operation, absence cannot qualify a live result.
Cold recovery still uses exact canonical evidence or settles `unknown`.
`home-task-dispatch.e2e.test.ts` covers live file/directory sync failure, absence
of publication/ack, report recovery without replay, stopped-before-conversation,
absent-without-Stop refusal, and the serialized report/steer race.
Reports enter the task-owned inbox described below, never a result-triggered Home
model call. Home's provider instructions describe attributed delivery on the
next maintainer message and the at-most-once advisory push, not automatic wake;
admission alone never establishes task success.

### Cold task reconciliation

Gateway startup retires abandoned `pending` and `active` task records before
exposing task admission. It does not construct an executable worker runtime,
resume an operation, recreate control callbacks, or replay a prompt/tool. Pending
identities (including authorization consumed before worker binding) become
terminal `unknown`. Scopes and unspent grants remain byte-identical; consumed
grants stay consumed. Restart never initializes an absent namespace or enables,
renews, revokes or re-stamps authority.

Cold task recovery consumes the secure store stream one record at a time, settles and publishes that record before advancing, and retains no backlog array. Inbox recovery and settlement likewise release each task before the next; the store remains the only task catalog.

Task recovery is an optional capability, not a Gateway startup dependency. The
Dispatcher owns one per-process recovery result; all task surfaces join it. A
store/workspace refusal is retained with its typed reason until the next Gateway
start (no in-process repair/retry), emits `home.task.store-refused` once, and
leaves ordinary sessions functional. `home.status.taskRecovery` exposes
`{ available: true }` or `{ available: false, reason }`, independently of the
Home conversation's phase. Dispatch, task tools/status, steering/Stop, permission
reconfirmation, redelivery and inbox admission/ack refuse with that same
`conflict` reason while fenced; no task/inbox writes or effects are attempted.
A readable canonical task marker also refuses worker construction before any
executable resources are loaded. If both the task namespace and canonical marker
are unreadable/missing, ownership cannot be inferred: there is no second
session-to-task index. That limitation does not authorize recreation or replay.
Successful recovery writes preceding a later publication refusal remain durable
evidence; the refusal does not roll them back.

An active task becomes report-backed only if the Registry's read-only canonical
file boundary proves exactly one matching `tron-home-task` marker and one valid
`tron-home-task-report` after it. Task, intent revision, Home identity/generation,
worker session, operation and report receipt must agree; the full payload schema
is checked again. These are file-wide immutable addresses, not the selected
model branch: navigation cannot discard an accepted report. The current session
format, unique entry IDs, append-ordered parents, stable untorn file identity and
canonical file/directory fsync are required. Missing, duplicate, contradictory,
malformed or unsynced evidence settles terminal `unknown`, not success, and is
never repaired. A canonical interruption without a report is still `unknown`
on cold recovery; a last assistant reply is evidence only. Valid reports retain
their `progress`, `needs-input` or `final` outcome and exact payload digest/address.
Canonical usage is reconstructed when provable; previously published spend is
preserved if the source is unavailable or regresses.

Recovered terminal results co-commit their wake event through the same task-file
owner as live settlement. Startup also publishes an undecided advisory push for
a previously committed terminal/outbox; a decided push is never retried. Inbox
consumption still waits for the next maintainer Home message. The one-step signal
is `home.task.transition` with `cold-explicit-report`, `cold-no-report` or
`cold-evidence-unavailable`; it contains only task/operation hashes and revision.
`home-task-dispatch.e2e.test.ts` (`HOME_TASK_REPORT=<artifact-path>`) retains
frozen-owner cuts at pending commit, grant consumption, worker creation,
operation binding, provider/tool execution before report, report append before
terminal commit, and terminal/outbox commit before publication, plus adversarial
canonical evidence. These prove process-abandonment behavior, not physical
power-loss durability.

## Task wake inbox and terminal push

The terminal task and its wake event share one atomic/fsynced record: there is no
terminal-to-outbox publication gap, orphan event catalog or independent retention
sweep. Event identity is SHA-256-qualified by task identity. Immutable result IDs,
canonical report references, terminal evidence and spend remain authoritative.
Tombstones remain for the entire task lifetime; no task deletion or age pruning
surface is currently implemented. Unknown/blocked/pending events never expire.

WakeInboxOwner transitions `pending → claimed → admitted → terminal → acknowledged`.
It also preserves `blocked`, `outcome-unknown` and `cancelled-before-admission`
states. Only a new actual user Home activation admits pending results, in
creation/event-ID order. RuntimeSlot inserts context-bearing
`tron.home-task-result.v1` messages after that activation's exact start boundary,
with an exact Gateway-owned `tron.context-delivery.v4` attribution receipt. The
existing inbound-context presentation carries the Home-task sender. The model
receives the immutable attributed report alongside the user's input, not a new
background prompt; ordinary chats/steers/continuations do not drain the inbox.

Each activation has one delivery envelope derived from HomeRequestPolicy's same
frozen memory prefix, incoming user text/images, effective model window and existing
response reserve, also bounded by the current chapter's byte/entry headroom.
Selection scans for the next creation/event-ID minimum using a cursor and one
candidate, never an unbounded result array or sort. It delivers whole results in
order; an event that fits the fresh prefix but not this activation stays pending
and untouched, as do its successors. The attributed `tron.home-task-pending.v1`
line states how many more results remain, including when none fit now.

A maximal report request is 128 KiB plus canonical identity framing; that cannot
fit every supported model window, so there is no forced whole-report floor. If a
result exceeds fresh-prefix headroom for the current model, Home receives an
attributed immutable **reference** with task ID, outcome and full report byte
size, rather than truncated content. The exact canonical reference and terminal
proof acknowledge that event, allowing the next result to proceed in order.
Home reads its full immutable report with `task { action: "report", taskId,
offset, limit }`: UTF-8 byte offsets, `limit` 1–4096 bytes, complete characters,
`nextOffset` or null at EOF. Invalid offsets/oversized pages refuse. Each page is
bounded, not an unlimited whole-report response; reading many pages within one
activation still consumes normal request-policy context.

The SDK stages chapter metadata and writes no canonical file until a user or
assistant entry. All chapter kinds (initial designation, replacement, rollover)
share one rule: absent file plus `activationStarted: false` admits that chapter's
empty preceding history after validating all sealed prior memory; absent file
plus `activationStarted: true` refuses as data loss. HomeOwner durably marks the
chapter started after freezing its valid prefix and before inbox/provider admission;
there is no installation-wide empty-view exception or initial-only flag. The
strict unreleased chapter schema has no migration/down-conversion path.

Existing #547 rollover is driven by chapter growth at its quiescent soft/hard
boundaries; it is not an inbox-starvation trigger. A temporarily too-large input
can defer delivery; persistent prefix/current-model capacity constraints require
a suitable model/input rather than a new limit, pruning or invented rollover
trigger. No pending event expires or is skipped to deliver a smaller successor.

Admission records the physical chapter, exact operation, lifecycle generation,
route epoch and SHA-256 message digest before canonical mutation. Acknowledgement
requires exactly one canonical work message with matching digest and immutable
references, its exact attribution, and a validated terminal invocation receipt
for that operation/chapter. Canonical bytes and parent directory are fsynced
before ack. A crash after claim but before admission safely returns to pending.
Unproven admitted work becomes outcome-unknown and is not automatically replayed;
proven terminal work can be acknowledged on recovery without consuming it twice.
These cuts are covered by `home-wake-inbox.integration.test.ts` using the
`test-support/home-ledger-crash-frozen-owner.ts` harness. This proves frozen-owner
abandonment, not a physical power-loss test. `HOME_WAKE_REPORT=<artifact-path>`
retains its regeneration artifact.

Events bind `{ homeId, routeGeneration }`, not a chapter ID or the enabled
operation generation. Disable pauses delivery; any number of disable/re-enable
cycles preserves the route and event IDs without rebinding. Chapter rollover
also preserves the route and delivers only into the current writable chapter;
sealed chapters remain unchanged. Missing-session replacement advances the route
epoch, so old pending events become blocked, never silently retargeted.
`home.redeliverTaskResult { commandId, taskId, homeId, routeGeneration }` and
`/home redeliver <id>` are explicit, receipted maintainer-only controls that
re-stamp a chosen unadmitted event to the current route, recording old/new epochs.
The command is idempotent and route-fenced under Home's record owner; model tools
cannot invoke it. Uncertain admitted work cannot be re-stamped and replayed by
this control. Stale-route acknowledgements refuse. The unreleased v2 record now
requires `routeGeneration`; older v2 data missing it is preserved/refused without
migration.

The task terminal owner suppresses ordinary `agent_finished` for task operations
only; normal sessions keep their existing terminal alerts. One push at most per
task terminal result; a crash at that exact boundary may omit it; the Home inbox
is the guaranteed delivery. The task event durably records `push: decided`
before a single NotificationService enqueue with its stable event identity.
There is no retry/re-decision after restart, even beyond NotificationService's
24-hour dedupe window. Push failure/unavailability/quota refusal cannot reopen a
task or delay result acknowledgement. The fixed-content hint routes to logical
`home`, qualified by machine ID, never to the old worker or sealed chapter.

`home.task.inbox` reports only a hashed event ID, state and coded reason. The
faux-provider `home-task-dispatch.e2e.test.ts` artifact (`HOME_TASK_REPORT`) covers
input → task → immutable report → one push + pending wake → next Home input →
canonical attributed consumption/ack, repeated disable/re-enable, receipted
replacement redelivery, rollover, failed fsync and ordinary-chat isolation.
The route E2Es hold the real `terminal → acknowledged` publication and await the
durable wake state before asserting consumption. An exact invocation receipt
proves the operation settled; neither it nor `!isBusy` proves that the inbox's
separate acknowledgement write has finished.

## Shared task control and spend status

`home.taskStatus { taskId }` reads the task's durable record, exact active
operation/controller generation, cumulative token spend and immutable result.
Status/viewing never changes control. Terminal `/home task <id>` shows lifecycle,
result outcome, input/cache and output tokens, and explicit unpriced money.
Home's `task` tool exposes `status`, `steer` and `stop`; it can only control tasks
bound to the enabled Home's exact identity/generation, never reconfirm permissions, revoke authority or decide grants.
Read-only status follows Home identity across disable/re-enable; it does not
transfer executable control.

`home.steerTask { commandId, taskId, operationId, controllerGeneration, text }`
and `home.stopTask { commandId, taskId, operationId, controllerGeneration }`
are receipt-backed maintainer controls. Terminal `/home steer <id> <text>` and
`/home stop <id>` read status then issue the exact fenced command; an intervening
operation change refuses rather than targeting a successor. Stop receipts may be
queried/repeated after terminal settlement without repeating cancellation.

Home and maintainer steering share RuntimeSlot's ordinary session lane. Accepted
lane order, not the caller's wall-clock arrival before asynchronous resolution,
is authoritative. Steering cannot start a successor operation: both lane admission
and SDK preflight check the original operation and retired report/Stop admission.
A report racing a delayed steer prevents that steer from starting after settlement.
There is no takeover state or transfer command.

Stop is deliberately outside that lane. The operation-owned report/control
binding persists exact generation-fenced `stopIntent` before aborting its
pre-admission signal and cancelling/joining the exact RuntimeSlot root prompt
owner. Automatic compaction/retry presentation can carry a different primitive
ID: cancellation follows its root ownership, not a snapshot-ID comparison. An
ordinary session Stop on that task-owned primitive reaches the same durable
intent owner. Terminal settlement modifies the latest durable task under the store mutex, so
it cannot erase Stop intent or overwrite a newer usage projection. Canonical
interrupted evidence plus that intent yields `interrupted`, pinned to the exact
canonical terminal invocation receipt; absent proof remains
`unknown`. An already-accepted canonical report remains authoritative. The
operation binding retires its executable callbacks with the worker lease on all
settlement outcomes, including failed Stop; late reports/steers are refused.
An uncertain leftover foreground operation still has RuntimeSlot's exact Stop
escape hatch, without rewriting an already immutable terminal task.

`home.reconfirmPermissions { commandId }` is an explicit maintainer mutation;
`/home reconfirm-permissions` is its terminal spelling. It is not a model tool,
startup refresh, grant renewal or recovery replay. It fails closed if the physical
namespace identity changes during the command. No iOS task surface is added here.

### Maintainer authorization RPC and terminal controls

These controls share the existing authenticated maintainer transport and mutation
receipts, not the Home model's `task`/`delegate` tools. The task namespace is
created by the first dispatch, never by startup or listing.

| RPC parameters | Terminal spelling | Contract |
| --- | --- | --- |
| `home.taskPermissions {}` | `/home permissions` | Read strict durable scopes, requests, decisions and grants plus revision; no authority renewal. Before first dispatch, the uninitialized namespace refuses rather than granting permission. |
| `home.revokeTaskScope { commandId, scopeId }` | `/home revoke-scope <id>` | Revoke the standing scope; repeated/already-revoked or missing references are harmless no-ops. The next dispatch cannot recreate a revoked initial scope. |
| `home.revokeTaskGrant { commandId, grantId }` | `/home revoke-grant <id>` | Revoke only an available grant. Consumed/revoked or missing grants are no-ops, never resurrected. |
| `home.decideTaskGrant { commandId, requestId, approved, expiresAt }` | `/home approve-grant <request-id> <expiry-ms>` or `/home deny-grant <request-id> <expiry-ms>` | Decide the exact pending request, with future Unix-millisecond expiry and explicit boolean approval. The command ID is the decision ID. Return `{ decision, grant }` (`grant: null` for deny). A missing/already-decided request, stale physical epoch, expired input or lost trust refuses; the caller cannot substitute intent/target/scope/profile/policy. |

Replaying a mutation's command ID returns its original receipt, even after grant
consumption/revocation; it does not re-decide the request. After the bounded receipt
horizon, the durable once-decided request still prevents a new grant. Restart
preserves denied decisions and grant state. A copied namespace never renews grants
or old pending requests; a decision must match the current physical epoch.
`home.task.authorization` diagnoses request, decision and revocation transitions
with hashed references only. RPC E2Es in `home-task-dispatch.e2e.test.ts` exercise
all terminal spellings, exact one-use admission, expiry/mismatch refusal, durable
deny, receipt replay/stale commands and both revoke/consume orderings.

Regenerate task E2E evidence with the named `home-task-dispatch.e2e.test.ts` file
and `HOME_TASK_REPORT=<artifact-path>`. It includes the actual Home delegate tool,
exact report addresses/digests, duplicate refusal, length/no-report outcomes,
ordinary-chat isolation and four deadline adversaries. The producer tests use
an installed fixture package at the verified identity/version and an injected
detached tracking projection, not the external provider's complete execution
suite.

## The neutral working directory

`<tronHome>/gateway/home/workspace` is created 0700 on the first designation and
kept empty; nothing else ever writes there. Designation records an explicit
**untrusted** decision for it through `TrustService`, so `requireResolved` never
blocks on an undecided directory and no project resource can load from it. The
runtime profile's `noExtensions`/`noSkills`/`noPromptTemplates`/`noContextFiles`
is the second, independent guard.

## The curated runtime profile

The profile is decided at runtime creation, once per runtime, from the Home
owner's answer for that session id: `home` when the enabled record names it as a
chapter, `ordinary` when a disabled record names it, and `unnamed` when the
record names another session. A new Home's *first* runtime is already the Home profile:
`RuntimeRegistry.create(cwd, "home")` carries an explicit creation profile,
which applies only to that session and only while the record does not name it.
Bound Home slots cannot fork/reset/switch their physical identity; a separately
imported Registry target is ordinary unless the ledger names it.

| | Home | Ordinary |
| --- | --- | --- |
| Extensions | `tron-context-window`, `tron-compaction-policy`, `tron-ask-user`, `tron-display`, `tron-notify`, `tron-home` | every Tron module plus Pi built-ins (codemode, tool-search, MCP) and the Tron-pinned managed subagent provider |
| Discovery | `noExtensions`, `noSkills`, `noPromptTemplates`, `noContextFiles`; no subagent discovery | agent directory and trusted project resources; managed provider settings view excludes user declarations of pi-subagents |
| System prompt | the agent directory's `SYSTEM.md` and `APPEND_SYSTEM.md` are dropped through `systemPromptOverride`/`appendSystemPromptOverride` | loaded |
| Executable tool allowlist | `ask_user`, `display`, `notify`, `zoom`, `date`, `memory_search`, `delegate`, `task` | the SDK defaults plus Tron's direct bash tool |
| Compaction | disabled per session | canonical policy |
| Model | fixed physical model | any, including virtual routing |
| Model runtime | a session-local view of the Gateway-wide user-scope runtime | one per session runtime |
| Cache warming | zero requests | unchanged |

The managed pi-subagents async loader, producer-bound factories, wake admission
and completed-load admission apply only to ordinary runtimes (including task
workers).
Home is delegate-only through Home tasks, not subagents: `session.resources`
returns an empty subagent catalog without invoking provider discovery. This
boundary follows the live runtime's profile through reload, profile replacement
and cold acquisition. `home-managed-provider.integration.test.ts` exercises
those transitions beside an ordinary managed-provider session.

Home runs on the Gateway-wide model runtime, the one that serves the model
catalog, admits `home.designate` and backs Home's summarizer. User provider
packages (for example CortexKit's `anthropic` override, which carries a Claude
subscription) register their providers there through `GlobalProviderResources`,
so Home reaches its designated model through the same provider the catalog
offered. Ordinary sessions keep a runtime each, because a project extension may
register a provider into it. Sharing is safe for Home only because of these
ownership boundaries:
- Home loads no extension that can register a provider.
- Each Home runtime sees the shared runtime through its own view. Reads and
  calls reach the shared runtime, while property writes stay with the view. The
  session context-window policy replaces `getModel` to project its budget, so
  without the view a Home override would change Gateway-wide lookups and stack
  under every replacement runtime.
- Model eligibility installation belongs to the model runtime's owner. A Home
  slot borrowing the Gateway runtime delegates eligibility lookup to its shared
  installation; it never registers provider filters or detaches that installation.
  Rebuilding or disposing Home therefore cannot stack filters or retain old views
  in shared provider closures. Ordinary slots and standalone Home runtimes own
  their model runtime and attach/detach eligibility with their slot lifecycle.

Without this, Home reached Pi's built-in provider instead (#480).

`tron-home` is a first-party module loaded only for Home. It contributes Home's
operating context, registers the three memory tools (see
[The memory tools](#the-memory-tools)) and is the single answer to the SDK's
per-session `cache_warming_decision`. It is not in `modules.list`, which reports
what every session registers.

The cache-warming exclusion is the mechanism, not a setting: the SDK's warmer
calls the model runtime directly (outside every request wrapper), its decision
listener fails open when a handler throws, and the last handler wins. So Home's
handler returns `{ action: "stop" }` unconditionally and cannot throw, and the
curated profile guarantees no other extension can answer `warm`. The
integration suite proves both halves: Home reports `stopped by extension` and
sends zero warm requests, while an ordinary session in the same Gateway and on
the same model does warm.

MCP is excluded structurally — no MCP extension is loaded for Home — rather than
by omission from the allowlist, because from SDK 1.0.4 an allowlist that names no
`mcp__*` tool keeps MCP tools registered.

Compaction is disabled through the constructor option of the existing
`CompactionOperationPolicy`, which reapplies the per-session overlay from
canonical settings at every idle admission; ordinary sessions and global
settings are untouched. `session.compact` is refused for Home at admission with a
typed conflict, rather than late by the SDK.

The model is resolved at designation: the model named in the request, or — only
for a fresh session — this Gateway's default for new sessions. Re-enabling a
disabled Home resolves the request's model, else the one the record was last
designated with, and applies it to the live session through the normal
`session.setModel` path when the live model differs. When the runtime is unloaded,
runtime construction supplies the recorded Home model explicitly rather than
restoring an incidental model from the transcript. A virtual (routed) model is
refused at every one of those points, because routing runs on the canonical
transcript, which the Home profile does not own. `session.setModel` refuses a
virtual model for a Home session too, and any model applied to the *enabled* Home
is written back to the record, which is the single source of truth for the model
a re-enable restores. A model applied while Home is disabled is an ordinary
session's change and does not touch the record.

## RPCs and capability

`home.v1` is advertised in `hello`/`system.info` when the Gateway has a Home
owner.

- `home.status` is one bounded read that composes the record, memory status and
  `home.context`: `{ phase, activation, readiness, recovery, available, reason?,
  enabled, homeId?, sessionId?, generation?, routeGeneration?, model?, live, sessionPresent,
  chapter?, memory }`. `chapter` contains a bounded ledger count, current canonical
  byte/entry measurements when available, and the current recovery decision. `phase` and the recovery action are derived on each read; they are
  not additional lifecycle state. Readiness gaps identify an unavailable record,
  missing/disabled designation, unconfigured memory or blocked memory. `activation`
  is the same body-free projection returned by `home.context`. The memory
  projection includes only bounded counters and memory state, never canonical
  messages or frozen memory-view text. The terminal reports admitted/summarized
  coverage, unbuilt view parts, pump activity and any degradation reason; an open
  activation without request sizes is described as awaiting preparation unless a
  refusal reason is present. `live` reports whether the session
  currently holds a live runtime; `sessionPresent` reports whether it exists at
  all — live, or still a canonical session in the catalog. A Gateway whose first
  catalog cut has not completed reports `sessionPresent: true`, because an
  unread catalog cannot prove absence.
- `home.open` returns the logical Home route and current binding without
  creating a runtime or materializing a reserved successor. `home.prompt` binds
  one command receipt to that route before effects, materializes a reserved
  chapter only when needed, rechecks the exact binding, and returns the physical
  session and operation identity.
- `home.designate` is a mutation with a command-id receipt. With no record it
  creates the working directory and trust decision, creates a **new** session
  whose first runtime is the Home profile, applies the model, writes the record,
  and returns `{ homeId, sessionId, generation }`. An enabled record whose
  session still exists is idempotent when no model is supplied or the explicit
  model matches the recorded model. A different explicit model is refused with
  a typed conflict directing callers to `session.setModel`; designation enables
  Home but does not own changes to its enabled session's model. A disabled record
  re-enables the same session with `generation + 1`. If rollover left a durable
  `reserved` or `materializing` successor, re-enable preserves that exact
  reservation; the next `home.prompt` recovers/materializes it rather than
  replacing it with a new chapter. A record whose session is **gone** (a session
  that was never written, or was deleted) is kept and given a fresh session with
  `generation + 1`, whether it was enabled or disabled: the record is the only
  evidence of the designation, and the dangling id must not be re-enabled.
- `home.disable` is a mutation. It sets `enabled: false` with `generation + 1`;
  the session stays an ordinary session afterwards. A record whose session is
  gone is only marked disabled.
- `home.configureMemory` is a mutation with a command-id receipt:
  `{ model }` must name a registered physical model; a virtual or unavailable
  one is refused. There is no budget to set (#493): memory spend is bounded by
  construction and reported. It is refused on a disabled Home, and it resumes a block its change
  addresses (see [Recovery](#recovery)). It returns the bounded memory projection.
- `home.resumeMemory` is a mutation with a command-id receipt. It clears any block
  and returns the bounded memory projection.
- `home.context` is a read with no parameters: the bounded request context of
  Home's current or last activation (see [Activations](#activations)), never a
  message body.

Enable, disable and profile/model changes use the same serialized profile owner.
A profile change must take effect before the session's next prompt, so a live
runtime is **replaced in place** inside the slot's own serialized lane: the idle
check, the durable record write and the rebuild are one critical section, and
prompt admission uses the same lane. This includes a live runtime for a `reserved`
or `materializing` chapter; re-enabling preserves its chapter, attempt and exact
path while rebuilding the runtime before routing is exposed. The session identity,
its subscribers, its presentation and its (possibly never-persisted) in-memory
session manager all survive. If the session is not idle the mutation is refused
with a retryable `busy` error and nothing changes. A session with no live runtime
and no construction in flight needs no rebuild: Registry commits under its
construction-selection mutex so the next constructor reads the new record,
including its model. When reserved materialization or a cold load is in flight,
the profile owner joins that existing single-flight before selecting the
published slot and rebuilding it. A failed constructor settles first, then the
profile change re-reads current ownership; no stale candidate is published under
the changed ledger. Disable always enters this owner, even when the catalog has
not seen the reserved session. The four reserved/cold disable/re-enable orderings
and failed-construction case in `home-activation.e2e.test.ts` retain their final
profile/identity evidence in `test-results/home-activation/report.json`.
Lifecycle updates merge against the current record at the serialized profile
commit boundary. Durable record commits use one serialization authority for
memory and model updates; it is separate from the lifecycle mutex so a model
callback arriving from a slot lane cannot invert the slot/lifecycle lock order.

## The terminal client

`tron-chat` (`packages/gateway/src/client/terminal-chat.ts`) is the terminal
client, and today it is the only surface that can designate Home, configure its
memory and recover it. With no explicit `--session`, it first asks for the
logical Home route; while Home is enabled, ordinary input goes through
`home.prompt` even as physical chapters change. A reserved successor is not
opened just to attach the terminal: its first runtime is created only when a
prompt activates it. `--session` remains an explicit physical-session route.

The connection owns one installed chapter attachment. The synchronization
boundary owns a candidate token until sync and installation succeed, and closes
that exact token on failure; failed transfer leaves the prior attachment owned
by the terminal. Successful transfer installs the successor snapshot/listeners
before closing the exact outgoing token. Exit closes the current token. Resync
and disconnect both retire the previous protocol client before replacement,
including a still-connected resync client: otherwise its server subscriptions
would survive without a terminal owner and prevent idle eviction.

The prompt loop owns one accepted operation, including its physical chapter,
submission leaf and any settlement read. Only that chapter's validated canonical
`tron.chat-invocation.v1` terminal receipt for the exact operation retires the
waiter. `command.status` proves acceptance, not completion; an outgoing idle
chapter, assistant reply, or newly idle snapshot is never terminal evidence.
Foreground retirement schedules the receipt read even while Home quiescence
still projects `running`. The existing `session.history.list` supplies a finite
canonical-entry bound; `session.history.entry` reads directly from the synchronized
leaf through parent identities, stopping at the exact terminal receipt, the
submission leaf, or that invocation's start in a newly attached chapter. No older
history-page traversal or transcript-row fallback is used. This also handles
paged-out user rows and ordinary input hooks that create no user row at all.
Every await is fenced to the accepted operation, client, physical session and
runtime/branch cut; a changed cut is re-evaluated, never published as settlement.

Reconnect preserves that operation and renders new assistant text even before
its response arrives. It joins recovery of the exact failed transport, while a
pending command receipt is polled on the healthy replacement without repeatedly
closing it. Token-matched `session.rebaseline` frames install their nested
snapshot as authority across coalesced sequences; they are not ordinary
sequenced events. Neither chapter transfer nor subscription close requires a
WebSocket disconnect. The terminal's reconnect reason and event-gap marker
are catalogued in `docs/observability.md`.

The real terminal child cases in `home-activation.e2e.test.ts` retain
`test-results/terminal-chat-home/attachments-rollover.json`,
`attachments-failed-sync.json` and `attachments-handled-input.json`
(run that file with `-t 'owns exact Home attachments'`). They cover response loss,
held command-receipt completion, exact receipt settlement before phase becomes
idle, a held successor across reconnect, settlement during transfer sync, a
paged-out user invocation, an ordinary input-hook-handled operation, actual
outgoing-runtime eviction, exact-token retirement, and failed candidate sync.
The fixture injects soft-limit metrics, owns all gates, publishes sequenced cuts
through RuntimeSlot, and uses public SDK context appends for page pressure. It
is not a large-chapter, real-provider or Gateway-process-crash proof.

Its `/home` line is resolved without touching the Gateway, so a bad argument is
answered before any RPC. Malformed
arguments are caught within the command loop, and assistant refusals are rendered
from the canonical message's `errorMessage`, even when it has no content text:

| command | what it does |
| --- | --- |
| `/home`, `/home status` | `home.status`, printed with phase, activation, readiness gaps, memory and recovery action |
| `/home designate [provider/id]` | `home.designate`; without a model the Gateway's default is used |
| `/home disable` | `home.disable` |
| `/home memory <provider/id>` | `home.configureMemory`, then the memory projection it returns |
| `/home resume` | `home.resumeMemory`, then the memory projection it returns |
| `/home context` | `home.context`: the activation's start, whether it is open, the request's sizes and its refusal |

An unknown or incomplete command prints the usage line; a value that cannot be
read — a model that is not spelled `provider/id`, a budget that is not a whole
number of tokens — is reported with its own reason. A refused RPC is printed and
the chat continues.

## Disable keeps the transcript's tool loadout

A profile change does not rewrite the chat's tool loadout, because Pi replays
the *declared* loadout from the canonical transcript at every runtime creation.
A disabled Home starts with the Home tools its ordinary profile can activate —
`ask_user`, `display`, `notify` — while the ordinary tools are merely registered,
exactly as every other session keeps the loadout its chat declared
(`runtime-tool-loadout.integration.test.ts`). The three memory tools belong to
the Home-only module, so an ordinary profile neither registers nor activates them. The user restores the
ordinary tools with `session.setTools`, which is the same control every session
has; the integration suite asserts the active set across a disable and that
`setTools` restores it.

## Diagnostics

The Gateway log carries one record per designation lifecycle outcome:
`home.designated`, `home.enabled`, `home.disabled` (info), and
`home.unavailable`, `home.refused` (warning). It also carries one
`home.activation` record per activation (the effective size of the request and how
long it waited for its view), a `home.activation-refused` record for every refusal
with its reason, a `home.memory-ingest` record when the memory could not read
committed entries (coded, never a path), and the memory's own `episodic.*`
records. `home.status` and `home.context` are the bounded projections. See
[observability.md](observability.md).

## Activations

An **activation** is one admitted input and everything it triggers: its tool loop,
the SDK's retries and continuations, and any steering or follow-up that joins the
same run. It opens at Tron's prompt admission, where the session's canonical leaf
is captured immediately before the input reaches Pi (so the input's own entry, and
every later steering entry, is inside the activation), it is renamed when Tron
transfers the run's owning operation to a dequeued follow-up, and it closes when
Tron settles the operation that owns it.

Every provider request of an activation carries exactly three things:

1. the session's system messages, as they stood before the activation's start,
2. ONE memory view, frozen at the activation's first request (see below), and
3. the activation's own messages, from its start entry onward.

Prior activations are never re-sent, and the memory view is never persisted: a
canonical transcript of the whole conversation stays the only durable history, and
Home's continuity comes from the view. That view is a `custom` message the seam
inserts; `newMessages`, `message_end` and the session JSONL never carry it.

Three wrappers enforce it, all fail-closed (no activation, no provider request,
and the refusal is a canonical assistant error entry the user can read):

| wrapper | where | what it does |
| --- | --- | --- |
| `prepareRequest` | outermost | cuts the request into system messages + memory view + the activation's own messages |
| `transformContext` | outermost | refuses unless the activation's non-system messages survived the SDK's context stages unchanged, then records the single-use digest expectation |
| `streamFunction` | innermost | refuses unless the outgoing request carries the activation nonce exactly once with the recorded digest |

The digest expectation uses that agent's own settings-aware message converter,
the same one Pi invokes in its agent loop. Thus `images.blockImages` replaces
images with Pi's disabled-image placeholder without triggering a false refusal,
including when the setting changes between turns. Non-system context mutation
and subsequent outgoing message mutation still fail closed.

Only a runtime whose profile is Home's gets them. A separate ordinary Registry
target has no Home seam or activation; bound Home slot replacement is refused.

### Prompt caching

Each request can re-read from the provider's cache everything the previous one
sent (#491). The exceptions are the request right after a view rebalance, an
invalidation or a restart, and any request after the provider's cache expired:

- **Constant system prompt and tools.** The system prompt and tool list carry no
  dates or per-turn state.
- **The view only grows between rebalances.** It rebalances only once it passes
  its budget, and then leaves an eighth of the budget for later turns
  ([episodic-memory.md](episodic-memory.md)), so a rebalance rewrites its start
  once in about every twenty turns at production sizes.
- **The memory message's blocks** (`viewPieces` in `home/home-memory.ts`):
  - the header plus every line the previous activation's request sent;
  - one block per line after those;
  - the footer;
  - the activation's nonce, last.

  The blocks rejoin to exactly the view text the model reads. Anything that
  changes every activation follows the view. Between rebalances the first block
  ends exactly where the previous request's view ended. After a rebalance the
  start changed, so the whole view is one block, written once.
- **What the previous request sent.** It is held per opened memory as a line
  count and digest. It is recorded only once the seam has passed every refusal
  check, because a refused activation sends nothing. The first request after a
  restart therefore writes the view once.
- **Where the cache marks go.** OpenAI and DeepSeek reuse the shared prefix on
  their own. For the `anthropic-messages` API, tron-home's
  `before_provider_request` handler marks the first block and the last line:
  - the next request re-reads the first mark exactly, or finds the last-line mark
    within Anthropic's 20-block lookback;
  - it keeps pi-ai's request-end mark;
  - it stays within Anthropic's four marks by dropping the tool mark first, then
    the system mark.

  The handler runs after the seam validated the request, and changes only
  `cache_control`. If it fails, pi-ai's own payload is sent unmarked. A provider
  that composes its own request must call pi-ai's `onPayload` for these marks to
  apply (pi's custom-provider contract).
- **Long retention.** Home's chat requests and its summarizer's calls ask pi-ai
  for `long` cache retention: Anthropic's one-hour TTL, OpenAI's longest. Home is
  used on and off through a day, so a five-minute cache would expire between most
  turns. The chat's request goes through the Home session's own view of the
  shared model runtime (`applyHomeCacheRetention`).

Ordinary sessions are not affected: the handler, the layout and the retention
belong to the Home profile.

`home-cache-layout.e2e.test.ts` also holds post-terminal chapter quiescence to
prove that actionable work may have retired while model configuration is still
blocked. Its refused-activation case awaits `configurationBlocker: null` before
changing the model, then verifies that the next actual provider request extends
the previous cached view. Terminal-client receipt settlement, inbox
acknowledgement and configuration readiness are distinct owner cuts, not a
single idle predicate. Home runtime fixtures likewise await configuration
readiness before changing chapter thresholds, profile/lifecycle, or reading
post-settlement canonical state. The hard-threshold cases hold the preceding
chapter-quiescence callback explicitly; terminal response-ordering cuts use the
accepted operation's exact canonical receipt instead of a configuration wait
that could depend on releasing the response under test.

## Memory and readiness

Home currently owns ONE `EpisodicMemory` ([episodic-memory.md](episodic-memory.md))
over the active chapter's canonical entries, outside the session's runtime so an idle
eviction, a reload or a profile change cannot lose it. The runtime only reports
that canonical entries changed (persisted messages, custom entries, navigation);
the memory re-reads the log after its cursor and builds its tree in the background
under its own bounds.

There is **no default model** (decision D4). The record's optional `memory` field
holds the model: `home.configureMemory` (a command-id-receipted mutation,
`{ model }`, refusing a virtual or unregistered model) writes it, and its result
is the same bounded memory projection `home.status` carries as `memory`.
Reconfiguring with the same model changes nothing.

There is **no budget to manage** (maintainer decision on #411, #493). Memory
spend is bounded by construction ([episodic-memory.md](episodic-memory.md)): a
summary is built only when missing, with bounded tries and retries, and rebuilt
only after its source changed, so spend grows only with the conversation and its
edits. Token spend is persisted with the memory's state and reported as
`spentTokens`, as information.

A fresh-session designation keeps the memory configuration (the model is the
user's decision about *how* Home remembers), but the replacement session gets a
NEW memory store with its own spend, because the store is keyed by session id. Disabling Home and re-enabling it keeps the same session and store,
so nothing is re-spent.

A Home whose memory is unconfigured, blocked, or unable to place the activation's
start entry refuses every activation with a readable reason and makes zero
provider requests. `home.context` is the bounded read for the other side of that:
for Home's current or last activation it returns the activation's start entry id,
whether it is still open, the frozen view's line and byte counts, the effective
token estimate the request was measured at, the model's window, and *that*
activation's refusal reason and detail (the sizes are absent when it was refused
before it prepared a request) — never a message body and never the view text.

### Recovery

A blocked memory is visible state with a deliberate way out. Which one applies is
the block's reason:

| block | what clears it |
| --- | --- |
| `retries-exhausted` | the next activation resumes it once by itself, re-arming the bounded retries; if it blocks again while that activation waits, the activation is refused with the reason |
| `permanent-failure`, `source-unavailable` | `home.resumeMemory` (a command-id-receipted mutation): the operator's statement that the cause is gone |
| any block | `home.configureMemory` with a *different model*, which resumes it as part of re-opening the store |

None of these waits for the summary catch-up: the block is cleared, the canonical
log is re-read and the pump restarts, while the activation that asked waits only
for the lines it will send. Resuming a memory that is *not* blocked, or one whose
block a budget raise would not address, is refused as a conflict with the reason,
so the caller learns what is actually wrong rather than being told a no-op
succeeded.

An activation waits for the memory before it sends anything (the recipe's "wait,
don't cut"): the wait covers the lines the view will carry, so an unbuilt line is
never sent, and it is abortable, so the user's Stop cancels it and leaves their
message in the log unanswered. Later steps of the same activation reuse the frozen
text byte-for-byte.

## The memory tools

Home reads the memory directly, and three tools are how it opens a line back up
(the recipe's `zoom` and `date`, plus Tron's own `memory_search`). `tron-home`
registers them and `HOME_TOOL_NAMES` is the executable allowlist, so a Home
runtime can neither call a tool outside it nor have one registered that it cannot
call.

| tool | what it answers |
| --- | --- |
| `zoom(id, n)` | Line `id+n` of the view, opened into the two lines of `n/2` under it; `n = 1` gives message `id` whole, as `id+0|kind: text` |
| `date(id)` | The local date and time of message `id`, from its canonical entry: `2026-01-02 15:04:05 -07:00` |
| `memory_search(query, from?, to?)` | A case-insensitive substring search over the projected messages in an index range `[from, to)`: at most 20 one-line hits `id+0|kind: snippet`, each snippet bounded to 300 characters, plus the range's match count |

Rules the tool results hold to:

- **The answer is the projection, never the source.** `zoom(id, 1)` returns the
  catalog's current projected text: reasoning excluded, credentials redacted,
  file paths kept, oversized text capped. A child line that is not built right
  now — never built, or invalidated by a context edit and not yet rebuilt —
  answers the recipe's `(not summarized yet: zoom it)` placeholder, never the
  text it held before, and an `[omitted]` message answers `[omitted]`.
- **The projection is never stale.** Every tool ingests the canonical commits
  appended since the last read before it answers, never waits for the pump the
  ingest starts, and re-reads the memory's state afterwards: an ingest that stops
  the memory — a canonical line over the reader's per-line bound, say — answers
  `memory-blocked` instead of serving the catalog it held before that commit.
- **An address that is not a line is refused**, not guessed at: a power-of-two
  `n`, `id % n == 0` and `id + n <= T` are required, and anything else answers
  `No line id+n.` with the numbers. `zoom`'s arguments are plain numbers on
  purpose, so a fractional, negative or zero `id` or `n` reaches that refusal
  rather than failing schema validation. A `date` for a message that does not
  exist answers `No line id+1.` the same way, and a query that is empty or over
  200 characters is refused with the bound it broke.
- **Absence is never proof.** Every hit is one line: its snippet has the
  message's newlines flattened, as a view line renders text, so a message's own
  text cannot look like another hit's line. The search header names its range as
  `[from, to)` and reports how many messages in it are `[omitted]` and how many
  hold capped text, so a message that could not be searched is named rather than
  looking like a message that never matched. An `[omitted]` message holds no
  searchable text: its placeholder is counted in the header, never reported as a
  hit.
- **A result is bounded.** Every tool result is capped at the recipe's `CAP`
  (30,000 characters, head and tail kept with a marker), so a 128 KiB message
  cannot enter the transcript whole.
- **The tools belong to Home.** They resolve their memory through the Home owner
  at every call, so a session that is not the enabled Home — or a memory that is
  not configured, not open, stopped, or replaced by a reconfiguration while the
  call ran — answers a typed `unavailable` result with its reason:
  `not-home-session`, `memory-not-configured`, `memory-unavailable`,
  `memory-blocked` or `timestamp-unavailable`. A tool call is only reachable from
  an activation, which has already opened and waited for this memory; a call never
  opens, configures or resumes one.

The view preamble carries the navigation paragraph the recipe's `VIEW_DOC`
requires (the line format, the kinds — `talk` covers a reply and the tool calls
in it — zooming before acting on a summary, and `date`). That preamble is constant
text, so the system prompt, the tool list and the preamble that opens every view
are byte-identical across activations: they are the head of every cached prefix,
and only the summaries below the preamble move. The summaries themselves stay
request-local evidence, never instructions.

A `date` for a message whose catalog record was written before that field
existed is answered from the source by entry id — every parsed entry, not only
the branch — so a record that has since left the branch still answers, and only an
entry the file no longer holds is `timestamp-unavailable`.

`memory_search` is a Tron addition to the recipe's tools, not a recipe section.
The recipe's tree navigation is otherwise unchanged, and both surfaces are
exercised end to end by
`packages/gateway/src/sessions/home-memory-tools.e2e.test.ts`
(`test-results/home-memory-tools/report.json`). The runtime lifecycle cases also
retain `packages/gateway/test-results/home-provider-runtime/report.json`, including
shared eligibility/filter identity across three Home rebuilds and disposal, and
ordinary-runtime eligibility retirement; regenerate it with `npx vitest run
src/sessions/home-provider-runtime.e2e.test.ts`.

## Not built yet

Home has no iOS surface of its own and no
scheduled or background work. It is one conversation whose turns run on its
memory. Those are separately approved slices of the same epic, and none of them
changes the rules above without updating this document.
