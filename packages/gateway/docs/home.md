# Tron Home

Tron Home is an opt-in persistent conversation, one per Gateway installation:
`~/.tron` and
`~/.tron-dev` each own one. This document owns the designation record, physical
chapters, the
runtime profile, memory, the request seam, delegated tasks, the wake inbox, the
`home.*` RPCs and
the terminal client. Ordinary sessions are unaffected by every rule here. Signal
names and reasons
are owned by [observability.md](observability.md).

## The designation record

`<tronHome>/gateway/home/home.json` is written `0600` and published atomically and
durably (temp
file, rename, fsync of the file and its directory). It holds one record per
installation:

| field | meaning |
| --- | --- |
| `version` | `2`. Other versions, unknown fields and invalid chapter topology are preserved and refused. `policyRevision` may be newer: a profile change is not a format change. |
| `homeId` | Stable identity of this installation's Home, generated once. |
| `chapters` | Ordered, unique `{ sessionId, ordinal, state, createdAt, activationStarted, ... }`. `state` is `active`, `sealed`, `reserved` or `materializing`; `activationStarted` is a durable one-way boolean. Designation starts with one `active` chapter; rollover appends one `reserved` successor. |
| `bindingRevision` | Advances when designation or reserved-chapter activation binds Home to a different physical session. |
| `generation` | Advances on every profile change (designate, re-enable, disable) and fences in-flight operations. |
| `routeGeneration` | Required positive route epoch. Set at designation; unchanged by disable, re-enable and rollover; advanced only on missing-session replacement. |
| `policyRevision` | The curated-profile revision in force. A re-enable writes this build's revision. |
| `enabled` | Whether Home is currently designated. |
| `model` | The model applied at the last designation, updated when the Home session's model changes. |
| `memory` | Optional `{ model, paused?: true }`. Absent means unconfigured; there are no memory defaults. |
| `createdAt`, `updatedAt` | ISO-8601 instants. |

The record is read through the Gateway's bounded owner-only JSON boundary. A missing
file means no
designation. A **malformed, empty, symlinked, oversized or group/world-readable**
file is
**preserved and reported unavailable**: `home.status` returns `available: false`
with a `reason`,
and `home.designate` refuses with a conflict. An unusable record is not evidence
that the user has no
Home. Runtime admission from Home's neutral workspace refuses with a typed conflict
while the record is
unavailable, matched by canonical installation workspace identity (so a symlinked
installation is
covered). Sessions in ordinary project directories are unaffected.

Version-1 records are preserved and refused, not migrated. A version-2 record
without a positive
`routeGeneration` is preserved and refused. There is no migration path.

**Rollback:** a build older than the record format refuses the record (Home
unavailable) and leaves it
unchanged. There is no down-conversion. `home-owner.test.ts` proves the refusal and
the unchanged bytes.

### Neutral working directory

`<tronHome>/gateway/home/workspace` is created `0700` on the first designation and
stays empty. Designation
records an explicit **untrusted** decision for it through `TrustService`, so
`requireResolved` never blocks
on it and no project resource can load from it. The profile's `noExtensions`,
`noSkills`,
`noPromptTemplates` and `noContextFiles` are a second, independent guard.

## Chapters

A physical chapter is one canonical session holding part of Home's history. The
record's ordered chapter ledger decides which chapter is writable.

### Limits and rollover

- At a quiescent turn boundary, crossing the **soft** limit (24 MiB canonical bytes
  or 50,000 entries) seals the active chapter and durably reserves its successor,
  writing only bounded metadata.
- Before a `home.prompt` receipt binds its target, a chapter at or above the
  **hard** limit (200 MiB or 100,000 entries) is sealed and its successor reserved,
  before any activation effect.
- Only the next `home.prompt` activation materializes a reserved chapter.
- A sealed chapter stays readable and refuses mutation whether Home is enabled or
  disabled and whatever the runtime profile. The check belongs to the physical
  session.
- Rollover follows growth at quiescent boundaries; it is not an inbox-starvation
  trigger. A persistent capacity limit needs a suitable model or input, not a new
  limit or trigger.

**Hard admission.** HomeOwner owns one policy for logical routes and physical prompt
targets:

- Cold metrics stream the canonical file under a stat fence, excluding the header
  from the entry count. Missing, torn or changing metrics refuse; they never count
  as an empty chapter.
- A logical admission rolls over before it binds its command receipt.
- Every physical prompt (explicit terminal targets, held prompts, steer and
  follow-up) rechecks the policy in its slot lane after admission awaits and before
  SDK effects. A full target refuses without redirecting. Ordinary sessions are not
  subject to Home thresholds.

**Running activations.** A running activation's canonical writes are never refused
at the hard limit. RuntimeSlot observes the crossing and requests Stop for that
operation. The crossing entry and abort-settlement writes stay canonical; no turn,
tool dispatch, steering or follow-up is admitted while the stop settles. The receipt
terminalizes as interrupted with `chapter-limit`, and the next admission rolls over.

Gateway-owned stop owners (chapter limit, task report, task Stop, deadline) record
their reason on the live invocation before cancellation yields; a user Stop records
only its intent. Every terminal observer reads that reason at the common receipt
boundary, so a successful crossing is `chapter-limit`, never `user-abort`, whichever
settles first. Receipt retirement owns the volatile reason; no parallel map exists.

**Serialization.** Registry serializes attention set and acknowledge, archive,
delete and sealing per physical session. Admitted mutations settle before a seal,
and seal-first refuses later mutations. The session serializer precedes the
Registry, slot and attention lanes. HomeOwner takes its record lock only for the
final ledger replacement, never before the serializer. Queue tails retire at
settlement, so a failed mutation cannot poison the next.

### Sealed-chapter boundary

- RuntimeSlot's serialized owners consult a chapter-state provider before prompt
  admission, configuration, rename and label edits, branch changes, bash, and
  extension-driven replacement. Registry owners preflight attention, archive and
  delete. A sealed result is a typed `conflict` (`details.reason: "sealed-chapter"`)
  and is never redirected.
- A bound Home slot refuses physical identity or path replacement (RPC fork;
  extension `newSession`, `fork`, `switchSession`), active or disabled, with
  `conflict` `home-identity-replacement`, before any SDK effect. Only HomeOwner
  transfers the logical binding, to a separately Registry-owned chapter. Ordinary
  slot replacement is unchanged.
- The canonical append guard is installed before SDK bootstrap, once per
  SessionManager, and carries the immutable slot owner. Reloads and profile rebuilds
  reuse it and never stack wrappers. A different manager gets its own guard, retired
  with the manager.
- A sealed check before a custom-entry append is a clean typed refusal that leaves
  the bounded ownership-write retry without draining or fencing the runtime.
- Sealed memory reads use the read-only canonical JSONL projection, never a
  writer-capable SessionManager.

### Materialization and recovery

- The Registry materializer claims one attempt per reserved chapter and scans every
  candidate before adopting or creating a file. The same strict complete-file scan
  runs before a cold Home runtime opens or is searched. The scan uses the exact
  canonical file's owning directory, not one re-encoded from the cwd, so workspace
  aliases cannot change evidence ownership.
- Generic JSONL import is a separate Registry admission followed by an SDK fork. It
  keeps the source in `parentSession`, checks capacity before construction, and does
  no Home chapter scanning.
- The version-3 scanner validates the header, supported entry and message and usage
  shapes, and unique IDs, and requires one append-ordered parent chain starting at a
  null parent. Cycles, forward or missing parents, duplicate IDs, extra roots and
  branches refuse before SDK construction. Unknown entry shapes and
  non-newline-terminated evidence block before Pi's loader can repair them. Evidence
  streams one line at a time under an unchanged-file stat fence.
- The 200 MiB bound applies only to the matching identity or expected path being
  adopted. A retained oversized stopped predecessor cannot block its successor, and
  no per-entry cap discards valid abort evidence.
- The materializer durably records the exact SDK path and attempt ID before the
  runtime reaches the caller. The constructed RuntimeSlot holds immutable authority
  for that chapter, attempt and path until disposal; receipt persistence and the
  first conversation append use it. Authority is checked against the live ledger and
  session identity, never granted by an operation or receipt lifetime.
- Unreadable, malformed, torn, duplicate, symlinked or path-mismatched evidence
  blocks recovery without changing canonical bytes. A durable attempt whose path is
  now absent also blocks: the pinned SDK has no verified exact-path constructor, and
  its new-session API picks a different timestamped path.
- A reserved chapter contributes nothing until canonical evidence exists. If an SDK
  operation fails after staging canonical entries, RuntimeSlot keeps the
  uncertain-outcome fence, not a clean refusal.
- **Chapter start.** An absent file with `activationStarted: false` admits the
  chapter's empty preceding history, once sealed prior memory validates. An absent
  file with `activationStarted: true` refuses as data loss. HomeOwner marks the
  chapter started after freezing its valid prefix and before inbox or provider
  admission. The SDK writes no canonical file until a user or assistant entry
  exists. There is no installation-wide empty-view exception.
- **Publication-error fence.** A post-rename ledger publication error fences all
  Home admissions and profile transitions. The owner securely reloads the visible
  record, and Registry retires every live Home slot after its current operation
  settles; the writer never awaits that retirement from its own lane. Home stays
  unavailable until reload and retirement both finish. The next acquisition builds a
  fresh slot from the reloaded ledger and the canonical transcript. A failed reload
  or retirement keeps the fence closed.
- **Exports.** JSONL and HTML exports are noncanonical. RuntimeSlot's
  temporary-artifact boundary snapshots the canonical source into a fresh directory
  and registers that artifact. Home exposes no arbitrary export destination, and
  export leaves the chapter path unchanged.

Home transition signals are typed in `home/home-diagnostic.ts` and pass one
privacy-preserving logger boundary. They carry no canonical IDs, paths, transcript,
credentials or free-text failure; owner unavailability is the bounded reason
`owner-fenced`. [observability.md](observability.md) owns the vocabulary.

## Logical route and receipts

- `home.open` returns the logical route and binding. It creates no runtime and
  materializes no successor. It emits `home.route-bound` with `category=open`, which
  is neither an activation nor a receipt.
- `home.prompt` persists an idempotency receipt (Home identity, binding revision,
  selected chapter) before materialization or dispatch, then verifies that binding
  again before sending. A stale binding never redirects a command.
- A completed receipt replays its original result and target, even after rollover or
  disable, without resolving a route, materializing or dispatching again. Pending or
  uncertain receipts remain outcome-unknown fences; a reconnect never resends
  accepted input. The receipt owner emits `home.route-bound` with `category=fresh`
  or `category=replay`.
- Each distinct joined command has its own durable target and slot admission.
  Accepted input is submitted once; a busy contender is refused before SDK
  submission; a duplicate joins its receipt lane, not another input. Registry shares
  only reserved-chapter construction, never input or receipts.
- Extension commands cannot carry attachments on either route.

## Runtime profile

A runtime's profile is decided once, at creation, from the Home owner's answer for
its session: `home` when the enabled record names it as a chapter, `ordinary` when a
disabled record names it, and `unnamed` when the record names another session. A new
Home's first runtime is created with the Home profile (`RuntimeRegistry.create(cwd,
"home")`), which applies only to that session and only while the record does not
name it. Bound Home slots cannot fork, reset or switch their identity. A separately
imported Registry target is ordinary unless the ledger names it.

| | Home | Ordinary |
| --- | --- | --- |
| Extensions | `tron-context-window`, `tron-compaction-policy`, `tron-ask-user`, `tron-display`, `tron-notify`, `tron-home` | every Tron module, Pi built-ins (codemode, tool-search, MCP) and the Tron-pinned managed subagent provider |
| Discovery | `noExtensions`, `noSkills`, `noPromptTemplates`, `noContextFiles`; no subagent discovery | agent directory and trusted project resources; managed-provider settings exclude user pi-subagents declarations |
| System prompt | agent-directory `SYSTEM.md` and `APPEND_SYSTEM.md` dropped (`systemPromptOverride`, `appendSystemPromptOverride`) | loaded |
| Executable tools | `ask_user`, `display`, `notify`, `zoom`, `date`, `memory_search`, `delegate`, `task` (`HOME_TOOL_NAMES`) | SDK defaults plus Tron's direct bash tool |
| Compaction | disabled per session | canonical policy |
| Model | fixed physical model | any, including virtual routing |
| Model runtime | session-local view of the Gateway-wide user-scope runtime | one per session runtime |
| Cache warming | zero requests | unchanged |

- Managed pi-subagents loaders, producer-bound factories, wake admission and
  completed-load admission apply only to ordinary runtimes, including task workers.
  Home is delegate-only: `session.resources` returns an empty subagent catalog
  without provider discovery, through reload, replacement and cold acquisition.
- `tron-home` is loaded only for Home. It contributes Home's operating context,
  registers the memory tools, `delegate` and `task`, and is the single answer to the
  SDK's `cache_warming_decision`. It is not in `modules.list`.
- MCP is excluded structurally: no MCP extension loads for Home. From SDK 1.0.4, an
  allowlist naming no `mcp__*` tool keeps MCP tools registered, so omission from the
  allowlist would not exclude them.
- Compaction is disabled through the constructor option of
  `CompactionOperationPolicy`, which reapplies the per-session overlay from
  canonical settings at each idle admission. `session.compact` is refused for Home
  with a typed conflict.
- **Cache warming** is excluded by mechanism. The SDK warmer calls the model runtime
  outside every request wrapper, its decision listener fails open, and the last
  handler wins. `tron-home` returns `{ action: "stop" }` unconditionally and cannot
  throw, and no other extension can answer `warm`. The integration suite checks that
  Home sends zero warm requests while an ordinary session on the same model warms.

**Model runtime.** Home runs on the Gateway-wide model runtime, which serves the
catalog, admits `home.designate` and backs Home's summarizer. User provider packages
(for example CortexKit's `anthropic` override) register there through
`GlobalProviderResources`. Ordinary sessions keep a runtime each, since a project
extension may register a provider. Sharing is safe for Home because:

- Home loads no extension that can register a provider.
- Each Home runtime uses its own view of the shared runtime: reads and calls reach
  it, and property writes stay with the view. The context-window policy replaces
  `getModel`, which would otherwise change Gateway-wide lookups and stack under
  every replacement.
- Eligibility installation belongs to the model runtime's owner. A Home slot
  borrowing the Gateway runtime delegates eligibility lookup to that installation
  and never registers filters or detaches it. Ordinary slots and standalone Home
  runtimes attach and detach eligibility with their slot lifecycle.

**Model resolution.** Designation uses the requested model, or, for a fresh session
only, the Gateway default. Re-enable uses the requested model, else the last
designated one, applied through `session.setModel` when the live model differs.
Runtime construction supplies the recorded model explicitly. A virtual (routed)
model is refused everywhere, because routing runs on the canonical transcript, which
the Home profile does not own. A model applied to the **enabled** Home is written
back to the record, the single source for re-enable. A model applied while disabled
is an ordinary change and does not touch the record.

**Tool loadout.** A profile change does not rewrite the loadout, because Pi replays
the declared loadout at every runtime creation. A disabled Home starts with
`ask_user`, `display` and `notify`; the ordinary tools are only registered
(`runtime-tool-loadout.integration.test.ts`). The memory tools belong to the
Home-only module and are never registered or activated for an ordinary profile.
`session.setTools` restores the ordinary tools.

## Profile changes

Enable, disable, and profile or model changes go through one serialized owner. A
profile change takes effect before the next prompt, so a live runtime is **replaced
in place** inside the slot's serialized lane. The idle check, the durable record
write and the rebuild form one critical section, and prompt admission uses the same
lane. This includes a live runtime for a `reserved` or `materializing` chapter,
which keeps its chapter, attempt and exact path. The session identity, subscribers,
presentation and in-memory manager all survive.

- A session that is not idle refuses with a retryable `busy` error, and nothing
  changes.
- A session with no live runtime and no construction in flight needs no rebuild;
  Registry commits under its construction-selection mutex, so the next constructor
  reads the new record.
- When a reserved materialization or cold load is in flight, the owner joins that
  single-flight before selecting and rebuilding the slot. A failed constructor
  settles first; the change then re-reads ownership, and no stale candidate is
  published.
- Disable always enters this owner, even when the catalog has not seen the reserved
  session.
- Lifecycle updates merge against the current record at the serialized commit
  boundary. Memory and model updates share one record-commit serialization, separate
  from the lifecycle mutex, so a model callback from a slot lane cannot invert lock
  order.

## Activations and prompt caching

An **activation** is one admitted input and everything it triggers: its tool loop,
SDK retries and continuations, and any steering
or follow-up joining the run. It opens at prompt admission, where the canonical leaf
is captured before Pi sees the input, and
closes when Tron settles the operation that owns it.

Every provider request of an activation carries exactly: (1) the system messages as
they stood at the activation's start, (2) ONE
memory view, frozen at the first request, and (3) the activation's own messages from
its start entry onward. Prior activations are never
re-sent, and the view is never persisted; the canonical transcript stays the only
durable history. The view is a `custom` message the seam
inserts. `newMessages`, `message_end` and the JSONL never carry it.

Three fail-closed wrappers enforce this. A refusal sends no provider request and
leaves a readable canonical assistant error.

| wrapper | where | what it does |
| --- | --- | --- |
| `prepareRequest` | outermost | cuts the request into system messages, the view and the activation's messages |
| `transformContext` | outermost | refuses unless non-system messages survive the SDK's context stages unchanged; records a single-use digest expectation |
| `streamFunction` | innermost | refuses unless the outgoing request carries the activation nonce exactly once with the recorded digest |

The digest uses the agent's own settings-aware converter, so `images.blockImages`
placeholders are not a false refusal, even when the
setting changes between turns. Only Home-profile runtimes get the seam.

Receipt settlement, inbox acknowledgement and configuration readiness are distinct
owner cuts, not one idle predicate.

### Prompt caching

Each request can re-read what the previous one sent (#491). The exceptions are the
first request after a view rebalance, invalidation,
restart, or cache expiry.

- The system prompt and tool list carry no dates or per-turn state.
- The view only grows between rebalances. It rebalances after passing its view-byte
  target and then leaves an eighth of that target for later
  turns ([episodic-memory.md](episodic-memory.md)): about one start rewrite every
  twenty turns at production sizes.
- The memory message is split into blocks (`viewPieces` in `home/home-memory.ts`):
  the header and every line the previous request sent; one block per
  later line; the footer; the activation nonce last. The blocks rejoin to exactly
  the view text. After a rebalance the whole view is one block, written once.
- The previous request's line count and digest are recorded only after every refusal
  check, so a refused activation sends nothing.
- **Cache marks.** OpenAI and DeepSeek reuse the prefix themselves. For
  `anthropic-messages`, the `before_provider_request` handler marks the first block
  and
  the last line, keeps pi-ai's request-end mark, and stays within four marks by
  dropping the tool mark, then the system mark. It runs after the seam validates and
  changes only `cache_control`; on failure, pi-ai's unmarked payload is sent. A
  provider composing its own request must call pi-ai's `onPayload` for the marks to
  apply.
- **Long retention.** Home's chat and summarizer requests ask for `long` retention
  (Anthropic's one-hour TTL, OpenAI's longest), via the Home session's own view of
  the
  shared runtime (`applyHomeCacheRetention`). Ordinary sessions are unaffected.

## Memory and readiness

HomeOwner owns ONE `EpisodicMemory` ([episodic-memory.md](episodic-memory.md)) keyed
by `homeId`, outside the physical runtime, so eviction, reload or profile change
cannot lose its projection. Its source reads active, sealed and materializing
chapters in ledger order. RuntimeSlot reports canonical changes; HomeMemory ingests
after
its cursor and builds missing summaries in the background under episodic bounds.
Each activation waits for and freezes the preceding view before provider admission.

- **Summarizer.** An injected dependency resolved from the Gateway-wide model
  runtime, never from a session. The episodic memory has no other compactor
  dependency.
- **Checkpoints.** Opening the store publishes a checkpoint only when the episodic
  store's threshold is crossed, not on every open
  ([episodic-memory.md](episodic-memory.md)).
- **Configuration.** There is no default model. `home.configureMemory` writes
  `memory.model`, refuses virtual or unregistered models, and returns the
  projection. The same model changes nothing.
- **No budget.** Spend is bounded by construction
  ([episodic-memory.md](episodic-memory.md)): a summary is built when missing, with
  bounded tries, and rebuilt only after its source changes. `spentTokens` is
  reported as information.
- **Lifecycle.** Rollover and replacement keep the same `homeId`, configuration,
  pause decision, store and spend; the successor adds a chapter, not a namespace.
  Disable closes the
  memory owner without deleting its store. Re-enable or restart restores cursor,
  summaries, block and spend without rebuilding completed summaries.
- **Refusal.** An unconfigured, operator-paused or blocked memory, or one that
  cannot place the activation's start entry, refuses every activation with a
  readable reason and zero provider requests.

### Bounds and measurements

- **Per record and per cursor, not per history.** Projected text is capped at
  `recordCapChars` (128 Ki characters); a tool result at `capChars`; the view at
  `viewBytes`
  (128,000 bytes). The raw source is read one line at a time under
  `maxSourceLineBytes` (about 46 MiB), the largest prompt line: inline images, text
  and envelope. The
  inline-image term mirrors Pi's unexported 4.5 MiB limit (`image-resize-core`);
  `shrinks a photo over the inline limit` checks the persisted base64 against it, so
  a Pi
  change the mirror misses fails there. Task results and assistant turns are bounded
  by model budgets, not by this bound.
- **Growth.** The catalog keeps every projected message (`messages`, `nodes`,
  `entryIndex`) in memory, so live heap grows with message count.
- **Measured.** At production caps, 2,000 messages in four chapters measure about 8
  MB of live heap while open: about 4 KB per message, against about 1.25 KB of
  average
  projected text. Cold ingestion ran at about 70–80 ms per message. Only these
  measured numbers are claimed; larger histories are not extrapolated.

### Source and cursors

- Ingestion streams and caps each entry before retaining it; raw chapter histories
  are never concatenated.
- Per-chapter cursors follow linear active appends (including non-message entries).
  Unchanged sealed files are stat-checked, not reopened. A navigation or context
  edit
  rebuilds only the active chapter's capped branch and cannot omit earlier chapters.
  The last writes before sealing are ingested before that cursor becomes immutable.
  A changed sealed identity, size, mtime or ctime blocks ingestion before the
  projection updates.
- **Historical cuts** stream a compact ID and parent index only through each
  chapter's ingested offset, verify the full prefix digest and physical provenance,
  and may read
  sealed bytes for proof, never later active appends. Boundaries resolve to
  permanent logical indices at that cursor; off-branch entries have no cut.
- The source cursor is version 2 and requires sealed-file metadata. Older cursors
  are preserved and refused with memory unavailable, with no migration or automatic
  rebuild.

### Operator pause

HomeOwner's ledger is the only durable pause authority; `home.status.memory.paused`
is reported even with no open store. Pause and resume commit under the lifecycle
mutex,
then the Registry session serializer, then the ledger record lock. They neither
change the profile nor rebuild a busy session.

- An activation that holds its frozen view continues, including tool loop, steering
  and bounded retries. An activation still preparing the view (including its
  readiness wait), or any new
  activation while paused, fails closed with `memory-paused`: the input and the
  refusal stay visible, with zero provider requests. Resume never replays that
  input. Stop still owns cancellation.
- Canonical ingestion may continue while paused, but no new summary node starts.
  Started nodes finish their bounded calls and durable append, so pause is not an
  instant zero-spend
  promise, and an accepted summary is never discarded to rebuild it. Committed nodes
  survive restart. A crash before an external call's result is committed cannot
  guarantee
  exactly-once spend; that is the existing compactor crash boundary, not a replay
  queue.
- Pause and resume are receipted: pending is durable before effects, and completion
  is recorded before the success response. After a crash between them the receipt
  stays
  pending or outcome-unknown, whether or not the ledger effect landed. Status
  reports the ledger's actual decision. Reconcile status rather than resubmitting.
- `home.client-control` is the one-step diagnostic for configure, pause and resume
  owner outcomes. Polls emit no record.

### Recovery

| block | what clears it |
| --- | --- |
| `retries-exhausted` | The next activation resumes once by itself, re-arming bounded retries; if it blocks again while that activation waits, the activation is refused with the reason. |
| `permanent-failure`, `source-unavailable` | `home.resumeMemory` (receipted): the operator's statement that the cause is gone. |
| any block | `home.configureMemory` with a *different* model, which resumes it while reopening the store. |

None of these waits for summary catch-up. The block clears, the source is re-read,
and the pump restarts; the activation waits only for the lines it will send. Resume
refuses a
memory that is neither paused nor blocked. Reconfiguring with the same model does
not clear a block. Changing the model or resuming never discards completed
summaries.

An activation waits for its memory before it sends anything, so an unbuilt line is
never sent. The wait is abortable: Stop cancels it and leaves the message
unanswered. A Stop before Pi appends
the input revokes the admitted prompt, so nothing is written or sent. Later steps
reuse the frozen text byte-for-byte.

## The memory tools

Three tools open a line of the view back up: the recipe's `zoom` and `date`, and
Tron's `memory_search`. `tron-home` registers them, and `HOME_TOOL_NAMES` is the
executable allowlist, so a Home
runtime neither calls nor has registered a tool outside it.

| tool | what it answers |
| --- | --- |
| `zoom(id, n)` | Line `id+n` of the view, opened into the two lines of `n/2` under it. `n = 1` gives message `id` whole, as `id+0\|kind: text`. |
| `date(id)` | The local date and time of message `id` from its canonical entry, as `2026-01-02 15:04:05 -07:00`. |
| `memory_search(query, from?, to?)` | Case-insensitive substring search over projected messages in `[from, to)`: at most 20 one-line hits `id+0\|kind: snippet` (snippet at most 300 characters) and the range's match count. |

- **The answer is the projection, never the source.** Text is reasoning-excluded,
  credential-redacted, path-preserving and capped. A line not yet built (or
  invalidated by a context edit)
  answers `(not summarized yet: zoom it)`, never its old text; an `[omitted]`
  message answers `[omitted]`.
- **Never stale.** Each tool ingests canonical commits appended since its last read
  before answering, then re-reads state. An ingest that stops the memory (for
  example, a canonical line over the
  reader's bound) answers `memory-blocked`, never the old catalog.
- **Addresses that are not lines are refused.** `n` must be a power of two, `id % n
  == 0` and `id + n <= T`; otherwise `No line id+n.` is answered with the numbers.
  Arguments are plain numbers, so a
  fractional, negative or zero value reaches that refusal. A `date` for a missing
  message answers `No line id+1.` A query that is empty or over 200 characters is
  refused.
- **Absence is never proof.** Hits are one line each, with newlines flattened. The
  header counts `[omitted]` and capped-text messages in the range, so an
  unsearchable message is named, never
  mistaken for a non-match.
- **Bounded.** Each result is capped at the recipe's `CAP` (30,000 characters, head
  and tail kept, with a marker).
- **Home-only.** Tools resolve memory through the Home owner on every call. A
  session that is not the enabled Home, or a memory that is not configured, not
  open, stopped or replaced mid-call, answers a typed
  `unavailable`: `not-home-session`, `memory-not-configured`, `memory-unavailable`,
  `memory-blocked` or `timestamp-unavailable`. A call never opens, configures or
  resumes a memory.
- **Dates.** A `date` answers the instant its catalog record holds; the store
  refuses records without one, and a catalog without instants is refused on open
  (`memory-unavailable`). An unreadable instant answers
  `timestamp-unavailable`. The memory never invents a time.

The view preamble is constant text (the line format, the kinds, zooming before
acting on a summary, and `date`), so the system prompt, tool list and preamble are
byte-identical across activations and head every
cached prefix. Only the summaries below the preamble move, and they remain
request-local evidence, never instructions. `memory_search` is Tron's addition; the
recipe's tree navigation is otherwise unchanged.

## Tasks

Home delegates finite project work through `delegate` into ordinary worker sessions.
Each worker writes an explicit immutable
report. Results wait in the wake inbox
([below](#task-wake-inbox-and-terminal-push)).

### Persistence

`HomeTaskStore` owns `<tronHome>/gateway/home/tasks/`, separate from the v2 ledger,
workspace content, canonical JSONL and episodic
memory. The directory is `0700`; every JSON file is `0600`, bounded, and read
without following symlinks; parents are owner-only
real directories.

- Initialization publishes an empty `authorization.json`, syncs the namespace and
  parents, then publishes
  `gateway/workspace-state/home-tasks-initialized.json` (exactly `{ "version": 1
  }`). No task or authorization write precedes it. A
  partial setup is preserved and refused. Once initialized, a missing namespace,
  marker or authorization file is lost state, not a fresh install.
- Each task is `tasks/<13-digit-createdAt>-<taskId>.json`, at most 256 KiB, with
  exactly these v1 keys:
  - `version`, `taskId`, `revision`: filename-matched identity; create at revision
    1, then replace only at expected + 1.
  - `createdAt`, `updatedAt`: store-owned Unix ms. `createdAt` is immutable and
    strictly advances across creates; updates never regress.
  - `homeId`, `generation`, `routeGeneration`: immutable originating identity,
    enabled generation and route epoch.
  - `intent`, `intentDigest`: immutable `{ revision, text }` (at most 64 KiB UTF-8);
    digest is SHA-256 of `JSON.stringify({ revision, text })`.
  - `target`, `workerProfile`, `policyRevision`: immutable absolute target (at most
    4 KiB), profile identity and positive policy revision. Storage is not admission
    authority.
  - `grantRef`, `scopeRef`: nullable, at most one set, each naming an existing
    authorization record, filled once, never swapped.
  - `lifecycle`: `pending`, `active` or `terminal`. `active` requires authority and
    session, operation and controller identity; `terminal` requires terminal
    evidence and a co-committed wake event.
  - `sessionId`, `operationId`, `controllerGeneration`: set by dispatch; shared
    control fences the active operation and controller generation.
  - `stopIntent`: null or exact `{ operationId, controllerGeneration, requestedAt
    }`, durable and never replaced.
  - `spend`: null or exact `{ sourceDigest, inputTokens, outputTokens }`. Counts are
    safe nonnegative integers. No cost is recorded.
  - `reportRefs`: null or at most 256 unique `{ resultId, sessionId, entryId, digest
    }`; the digest pins the canonical report payload.
  - `wake`: null before terminal, then the event (stable identity, route epoch,
    creation time, delivery state, push decision, exact activation binding and
    message digest, acknowledgement and redelivery audit).
  - `terminalEvidence`: null or exact `{ outcome, sessionId, entryIds, reason }`.
    `outcome` is `progress`, `needs-input`, `final`, `limited`, `interrupted` or
    `unknown`; at most 256 entry IDs. `final` requires a report reference.
- `authorization.json` (owned by `HomeTaskAuthorization` through the store's durable
  adapter) has exact v1 keys `version`, `revision`, `scopes`, `requests`,
  `decisions`, `grants`. It is at most 4 MiB, with at most 10,000 records per array
  and unique IDs. A request has an exact binding and a stable SHA-256 identity
  (`authorizationRequestId`). A decision names one request, which is decided once. A
  grant names one approved decision, matches its binding and expiry, and carries
  that request's restore epoch. Only the adapter advances the revision; concurrent
  saves on one revision cannot overwrite each other. Command payloads are
  snapshotted before queuing.
- Both files replace durably (unique temp, file fsync, rename, directory fsync)
  before acknowledgment. Unknown versions or keys and malformed, unsafe, oversized
  or contradictory records preserve their bytes and refuse with
  `HomeTaskStoreError`; `home.task.store-refused` names only the bounded reason. An
  uncertain publication fences the instance until a fresh owner securely reloads. A
  failed pre-rename write removes only its own temp file. A crash-staged
  `<name>.json.<pid>.<12 hex>.tmp` is skipped by enumeration and removed by startup
  recovery only when it is this user's regular file; any other entry refuses
  recovery.
- The creation filename survives every replacement. ID lookup scans names only and
  refuses multiple matching suffixes; the creation time in name and record must
  agree. Enumeration validates every file in one pass and refuses a second name for
  any task ID. There is no second catalog, growing snapshot, task-count cap or
  silent pruning. By-ID operations read only their target and check its authority
  against one read of `authorization.json`. Authority saves may only append or mark;
  removing a cited scope or grant is refused. A never-initialized absence is an
  empty read; missing-after-initialization still blocks.
- There is no task-membership index. Result and worker-marker owners preserve and
  block on missing or invalid referenced tasks. Reports live in the worker's
  canonical history, pinned by references and digests. Terminal result and authority
  fields are immutable. Only WakeInboxOwner advances the nested delivery event,
  through the terminal-only adapter.
- **Authority epoch.** Authority derives from the task directory's `dev`, `ino` and
  birthtime, not a persisted or startup-minted epoch. Restart and atomic replacement
  keep it. A restore, copy or migration of the Tron home changes it: old scopes and
  grants are preserved but refused (`scope-reconfirmation-required`) until
  reconfirmed. An unreadable identity fails closed. An in-place overwrite that keeps
  the directory is not detectable, and the epoch is not protection against a
  privileged actor restoring files into the live directory.
- **Retention.** No deletion API exists. Tombstones remain for the task's lifetime.
  Pending, unacknowledged, blocked and outcome-unknown evidence is never age-pruned.
- Startup neither initializes the namespace nor enables a scope. The first dispatch
  initializes it and enables the initial trusted-project scope. Existing, revoked
  and stale authority is never silently renewed.

### Authorization

`HomeTaskAuthorization` owns authority separately from execution. The initial
standing scope covers any currently trusted project, with trust resolved again at
admission. The scope binds to the restore epoch.

- A request outside an active scope needs a one-use grant, recorded separately from
  the decision. It binds the intent revision and digest, canonical target,
  authorization scope, worker profile, policy revision, expiry and restore epoch.
  Admission consumes it atomically. Revoked, expired, spent, mismatched or
  stale-epoch grants never authorize. Authorization never infers a restore from
  startup.
- A `grant-required` refusal durably records the binding before returning a stable
  `requestId` (also shown by the `delegate` error); repeats across restart refer to
  the same request.
- Approval atomically records the decision and a one-use grant. Denial records the
  decision with no grant and returns a successful receipt. A decided request never
  mints a second grant. Approval never replays the refused task; delegate again with
  a new task ID.
- Revocation and consumption serialize under one mutex; whichever enters first wins.
  Revocation does not stop admitted work; use Stop.
- Restart reloads scopes and unused grants unchanged; consumed grants stay consumed.
  Only `home.reconfirmPermissions` re-stamps active standing scopes to the current
  epoch. Revoked scopes and one-use grants are never renewed.
- Maintainer RPCs and terminal controls list, revoke and decide. Home's model tools
  cannot approve grants.

### Dispatch and workers

Only the enabled Home's active chapter may call `delegate` with a stable `taskId`, a
bounded finite `intent` and a trusted `target`. The dispatcher records pending
intent before any worker effect, authorizes the exact snapshot, creates an ordinary
worker through `OwnedSessionDispatch`, and binds its exact operation before prompt
admission. A task ID never replays an accepted prompt.

- A task worker has normal project tools and resources plus `report`, and cannot
  replace its owned session. Its canonical `tron-home-task` marker binds the task,
  Home identity and generation, intent revision, session and operation. Cold
  construction checks the marker before loading executable resources. Missing or
  contradictory tasks are never recreated.
- Task Stop (report, control or deadline) is terminal, unlike ordinary chat Stop,
  which continues with queued steering. Accepted but unconsumed steers are removed
  with `task-stopped-before-delivery` receipts and never replayed. A steering
  preflight in progress is fenced by the sealed or stopping report owner and
  receives its own refusal receipt.
- The `OwnedSessionDispatch` seam has a fixed 24-hour wall-time ceiling. Only a
  caller that opts in owns it; ordinary sessions and Automations do not. Expiry
  cancels the exact operation and waits for its terminal completion before reporting
  a joined stop. Task dispatch applies the seam before asynchronous prompt
  preflight. No user-configurable limit exists.
- Task workers load the same Tron-managed subagent provider as ordinary chats; Home
  does not. In v1, task workers cannot run subagents, which keeps the 24-hour
  guarantee for operation-owned work.
- The first-party task extension refuses subagent executions (even `async:false`,
  which the pinned configuration can force async), revival, mutating management and
  the schedule tool. Only read-only management from the verified `0.76.1-tron.5`
  provider is admitted: `guide`, `children.list`, `status`, `list`, `get`, `models`,
  and supervisor `status`, `pending`, `list`. The blocking `bg_wait` is allowed and
  is aborted and joined with the operation; `nonBlocking: true` is refused, since
  its durable subscription can wake the session after report. Unknown versions or
  owners refuse all subagent, supervisor and `bg_wait` calls. A later pin requires a
  new explicit review before this gate changes. Nested codemode calls cross the same
  gate.
- Trusted extensions are not a sandbox. If detached-work tracking still sees
  task-session work after foreground settlement, the outcome is `unknown` with
  `detached-work-outlived-task`, never a clean-termination claim.

**The `report` tool** takes `resultId`, a claimed `outcome` (`progress`,
`needs-input`, `final`), `text` (at most 64 KiB UTF-8) and `evidence` (at most 64
strings of 4,096 bytes; payload at most 128 KiB). It supplies no task, Home, session
or cost identity. Acceptance appends one immutable `tron-home-task-report`, seals
it, and requests an exact Stop without awaiting it from the tool that joins.
Settlement joins that Stop before publishing the result. RuntimeSlot's settlement
owns the single terminal receipt write and notifies the task observer after it. The
task lease alone acknowledges the operation marker, and only the exact task
operation suppresses the ordinary completion push. Identical duplicates reuse one
entry; conflicts refuse. References carry the exact entry ID and digest, never a
latest-assistant pointer.

**Outcomes.** A final reply without a report is `unknown`. A provider length stop or
a joined deadline without a report is `limited`. The last assistant entry is
evidence only. A failed exact stop is `unknown` (`deadline-stop-failed`,
`task-stop-failed`, `report-stop-failed`). Admission alone never establishes
success.

**Spend.** Canonical usage is deduplicated by entry identity over the operation's
history and persisted before live status and settlement. Contradictory duplicates,
invalid counters or overflow refuse. Input totals include cache read and write;
output is always shown. Pi's `usage.cost` is not authoritative billing evidence,
so no provider amount is recorded or shown; spend is tokens only.

**Live settlement** joins the worker's terminal and Stop boundary, then reads the
same Registry durable canonical cut as cold recovery. Session serialization orders
before the RuntimeSlot lane, which excludes late steering receipt writes. File and
parent-directory sync precede report qualification, terminal and outbox publication,
and marker acknowledgement. A sync or validation failure rejects settlement and
leaves the task active with no result, reference, wake or push; cold recovery
reconciles it later without replaying the prompt. If no conversation file exists,
the boundary syncs its parent and verifies absence. Only a settled in-process
operation with a durable append-only Stop intent can settle `interrupted`
(`stopped-before-conversation`) with no references; without that intent, absence
cannot qualify a live result.

Reports enter the task-owned inbox, never a result-triggered Home model call.
`home.task.transition`, `home.task.spend` and `home.task.runaway-stop` emit only
bounded or hashed references after durable publication.

### Cold reconciliation

Startup retires abandoned `pending` and `active` records before task admission
opens. It does not construct a worker, resume an operation, recreate callbacks or
replay a prompt or tool. Pending identities, including authorization consumed before
worker binding, become `unknown`. Scopes and unspent grants stay byte-identical, and
restart never initializes, enables, renews, revokes or re-stamps authority.

Recovery streams one record at a time, settling and publishing each before
advancing; it retains no backlog. It is not a startup dependency: it runs after the
listener serves, following attention recovery (`RuntimeRegistry.recoverHomeTasks`).
Until it settles, `home.status.taskRecovery` is `not-started`, which refuses task
work. One per-process result is shared by every task surface.

- A store or workspace refusal keeps its typed reason until the next start, with no
  in-process repair. It emits `home.task.store-refused` once and leaves ordinary
  sessions working. `home.status.taskRecovery` is always present: `{ available: true
  }` or `{ available: false, reason }`, independent of phase.
- While fenced, dispatch, task tools, steer, Stop, reconfirmation and redelivery
  refuse with that `conflict`. Inbox admission and settlement are no-ops: nothing is
  delivered or settled, but the Home prompt still runs. Writes that precede a later
  publication refusal stay durable.
- A readable canonical marker also refuses construction before executable resources
  load. If the namespace and the marker are both unreadable or missing, ownership
  cannot be inferred; there is no second session-to-task index, and this never
  authorizes recreation or replay.
- A task becomes report-backed only if the read-only canonical boundary proves
  exactly one matching `tron-home-task` marker and one valid `tron-home-task-report`
  after it. Task, intent revision, Home identity and generation, session, operation
  and receipt must agree, and the payload is re-checked. Addresses are file-wide, so
  navigation cannot discard an accepted report. The session format, unique IDs,
  append-ordered parents, a stable untorn file identity and canonical file and
  directory fsync are required.
- Missing, duplicate, contradictory, malformed or unsynced evidence settles
  `unknown`, is never repaired, and is never success. A canonical interruption
  without a report stays `unknown`; the last assistant reply is evidence only. A
  valid report keeps its outcome, digest and address. Usage is reconstructed when
  provable; previously published spend is kept if the source is unavailable or
  regresses.
- Recovered terminal results co-commit their wake event through the same owner as
  live settlement. Startup publishes an undecided advisory push for a committed
  outbox entry; a decided push is never retried. Inbox consumption waits for the
  next maintainer Home message. The signal is `home.task.transition` with
  `cold-explicit-report`, `cold-no-report` or `cold-evidence-unavailable`.

### Control and spend status

- **`home.taskList`** (maintainer-only) orders by `createdAt` descending, then task
  ID ascending. It scans names within a bounded window and reads at most `limit`
  records, never report bodies. The opaque cursor binds the last key to the restore
  epoch; foreign, restored and malformed cursors refuse (`conflict`,
  `invalid-record`). Each row carries task ID, dates, intent title (first 160 code
  points), target, lifecycle, terminal outcome or null, spend or null, `attention`
  (needs-input or unknown) and `pendingGrant`. Null spend is unavailable, not zero;
  A never-initialized listing returns `{ items: [] }`
  without creating authority.
- **`home.taskStatus`** returns the record, exact active operation and controller
  generation, spend and the immutable result. Viewing never changes control. Home's
  `task` tool exposes `status`, `steer` and `stop`, only for tasks bound to the
  enabled Home's identity and generation; it can never reconfirm, revoke or decide.
  Status follows Home across disable and re-enable but never transfers control.
- **Steer and Stop** read status, then send the exact fenced command; an intervening
  change refuses rather than targeting a successor. Stop receipts can be repeated
  after settlement without repeating cancellation.
- Home and maintainer steering share RuntimeSlot's session lane; accepted lane order
  is authoritative. Steering cannot start a successor, and a report that races a
  delayed steer prevents it. There is no takeover state and no transfer command.
- Stop lives outside that lane. The binding persists the exact generation-fenced
  `stopIntent` before aborting the pre-admission signal and joining the root prompt
  owner. Automatic compaction or retry can carry another primitive ID; cancellation
  follows root ownership, not ID comparison. Settlement updates the latest durable
  task under the store mutex, so it cannot erase the intent or overwrite newer
  usage. Canonical interrupted evidence plus the intent yields `interrupted`, pinned
  to the exact terminal receipt; otherwise the result is `unknown`. An accepted
  canonical report stays authoritative. Callbacks retire with the worker lease on
  every outcome, so late reports and steers are refused. A leftover foreground
  operation keeps RuntimeSlot's exact Stop escape hatch without rewriting a terminal
  task.
- **`home.reconfirmPermissions`** (`/home reconfirm-permissions`) is an explicit
  maintainer mutation, never a model tool, startup refresh, renewal or replay. It
  fails closed if the namespace identity changes during the command. The iOS task
  sheet calls it too.
- Replay of a command ID returns its original receipt, even after consumption or
  revocation, and never re-decides a request. After the receipt horizon, the
  once-decided request still blocks a new grant. Restart preserves denials and grant
  state; a copied namespace never renews grants or pending requests.
- `home.task.authorization` diagnoses request, decision and revocation transitions
  with hashed references only.
- `home.decideTaskGrant` decides the exact pending request; the command ID is the
  decision ID. A missing or decided request, a stale epoch, an expired input or lost
  trust refuses. The caller cannot substitute intent, target, scope, profile or
  policy.

## Task wake inbox and terminal push

The terminal task and its wake event share one atomic, fsynced record. There is no
terminal-to-outbox gap, no orphan
event catalog and no independent retention sweep. Event identity is
SHA-256-qualified by task identity. Result IDs, report
references, terminal evidence and spend remain authoritative.

WakeInboxOwner moves an event through `pending → claimed → admitted → terminal →
acknowledged`, and it also holds
`blocked` and `outcome-unknown`. Only a new actual user Home activation admits
pending results, in creation and event-ID
order. RuntimeSlot inserts each as a context-bearing `tron.home-task-result.v1`
message after that activation's start
boundary, with an exact `tron.context-delivery.v4` attribution receipt. The model
receives the immutable report alongside
the user's input, never a background prompt. Ordinary chats, steers and
continuations do not drain the inbox.

- **Envelope.** Each activation has one delivery envelope, derived from the frozen
  memory prefix, the incoming text and
  images, the effective model window and the response reserve, bounded by the
  chapter's byte and entry headroom. Selection
  scans for the next creation and event-ID minimum with a cursor and one candidate;
  it never builds an unbounded array or
  sorts. Whole results deliver in order. An event that does not fit this activation
  stays pending and untouched, and so do
  its successors. `tron.home-task-pending.v1` states how many results remain,
  including when none fit now.
- **References.** A maximal report request (128 KiB plus framing) cannot fit every
  model window, so there is no forced
  whole-report floor. A result larger than the fresh-prefix headroom arrives as an
  attributed immutable **reference** with
  task ID, outcome and full byte size, not truncated content. The reference and its
  terminal proof acknowledge the event,
  so the next result can proceed.
- **Proofs.** Delivery proof reads its chapter one line at a time under
  `maxSourceLineBytes`, keeping only the entries that
  belong to that delivery: its result message, its terminal invocation receipt and
  its attribution receipt. An unreadable
  proof (over-bound line, torn tail, or a source that is not this session) makes
  only that event `outcome-unknown` with
  `admission-proof-unreadable` or `terminal-proof-unreadable`; the activation
  proceeds. A transient read or fsync failure
  leaves the event for the next activation to re-prove, which is neither a refusal
  nor an uncertain outcome. A delivery whose
  admitted message was never appended (Stop between admission and append) returns to
  `pending` under the same mutex with
  `admission-aborted`.
- **Report reads.** Home reads a report with `task { action: "report", taskId,
  offset, limit }`. Offsets are UTF-8 bytes,
  `limit` is 1–4096 bytes, pages hold complete characters, and `nextOffset` is null
  at EOF. Invalid offsets and oversized
  pages refuse. Reading many pages still consumes normal request-policy context.
- **Admission and acknowledgement.** Admission records the physical chapter, exact
  operation, lifecycle generation, route
  epoch and message digest before any canonical mutation. Acknowledgement requires
  exactly one canonical work message with a
  matching digest and immutable references, its exact attribution, and a validated
  terminal receipt for that operation and
  chapter. Canonical bytes and the parent directory are fsynced before the ack. A
  crash after claim but before admission
  returns the event to `pending`. Unproven admitted work becomes `outcome-unknown`
  and is never replayed automatically. Proven
  terminal work can be acknowledged on recovery without being consumed twice.
- **Routes.** Events bind `{ homeId, routeGeneration }`, not a chapter or the
  enabled operation generation. Disable pauses
  delivery. Disable and re-enable cycles keep the route and event IDs. Rollover
  delivers only into the current writable
  chapter; sealed chapters are unchanged. Missing-session replacement advances the
  route epoch, so old pending events become
  `blocked`, never retargeted. A stale-route acknowledgement refuses.
- **Redelivery.** `home.redeliverTaskResult` and `/home redeliver <id>` are
  receipted maintainer-only controls. They re-stamp
  one **unadmitted** (`pending` or `blocked`) event to the current route and record
  both epochs. Idempotent and route-fenced
  under Home's record owner. Model tools cannot invoke it. Admitted, uncertain work
  cannot be re-stamped and replayed.
- **Push.** The task terminal owner suppresses ordinary `agent_finished` for task
  operations only. There is at most one push
  per terminal result. A crash at that exact boundary may omit it, and the Home
  inbox is the guaranteed delivery. The event
  durably records `push: decided` before one NotificationService enqueue with its
  stable identity. There is no retry or
  re-decision after restart, even past NotificationService's 24-hour dedupe. Push
  failure or quota refusal cannot reopen a
  task or delay acknowledgement. The fixed-content hint routes to logical `home`,
  qualified by machine ID, never to the old
  worker or a sealed chapter.

`home.task.inbox` reports only a hashed event ID, state and coded reason;
[observability.md](observability.md) owns its
vocabulary.

## RPCs

`home.v1` is advertised in `hello` and `system.info` when the Gateway has a Home
owner. `home-memory-browser.v1`
additionally gates the memory-browser reads below; `home.v1` alone promises no
browser contract. Parameter objects are
strict: unknown fields are `invalid_request`. **Receipted** mutations carry a
`commandId` and use the bounded receipt
described in [Logical route and receipts](#logical-route-and-receipts).

| method | parameters | kind | contract |
| --- | --- | --- | --- |
| `home.status` | none | read | The `HomeStatus` shape below. |
| `home.context` | none | read | Bounded request context of the current or last activation. Never a message body. |
| `home.open` | none | read | Logical route and binding. Creates no runtime and materializes no successor. |
| `home.prompt` | `commandId`, `text`, `uploadIds` (at most 10, into the resolved chapter), `behavior` (`steer` or `followUp` while a turn runs), `resourceInvocation` | receipted | The composer's whole prompt contract, admitted by the same code as `session.prompt`. Returns the physical session and operation. |
| `home.designate` | `commandId`, `model?` | receipted | With no record: creates the working directory and its trust decision, a **new** session whose first runtime has the Home profile, applies the model, writes the record, and returns `{ homeId, sessionId, generation }`. An enabled record whose session still exists is idempotent when the model is absent or matches; a different model refuses with a conflict directing to `session.setModel`. A disabled record re-enables the same session at `generation + 1`, preserving any `reserved` or `materializing` successor for the next `home.prompt`. A record whose session is **gone** is given a fresh session at `generation + 1`, enabled or not: the record is the only evidence of the designation, and the dangling ID is never re-enabled. |
| `home.disable` | `commandId` | receipted | `enabled: false` at `generation + 1`. The session stays ordinary. A record whose session is gone is only marked disabled. |
| `home.configureMemory` | `commandId`, `model` (required) | receipted | Names a registered physical model; virtual or unavailable refuses. Refused on a disabled Home. Resumes a block its change addresses, never clears operator pause. Returns the memory projection. |
| `home.pauseMemory` | `commandId` | receipted | Requires an enabled, configured Home. Durably pauses; idempotent. Returns the memory projection. |
| `home.resumeMemory` | `commandId` | receipted | Clears pause and or block, re-reads canonical deltas and restarts the pump without awaiting catch-up. A memory that is neither paused nor blocked refuses with conflict. An empty Home resumes without creating a store. |
| `home.reconfirmPermissions` | `commandId` | receipted | Re-stamps active standing scopes to the current epoch. See [Authorization](#authorization). |
| `home.taskList` | `limit?` (1–50, default 20), `cursor?` (at most 1,024 characters) | read | Maintainer summary; see [Control and spend status](#control-and-spend-status). |
| `home.taskStatus` | `taskId` (at most 160 characters) | read | Record, active operation and controller generation, spend, immutable result. |
| `home.taskPermissions` | none | read | Strict scopes, requests, decisions and grants with the revision. Refuses before the first dispatch, never granting permission. |
| `home.steerTask` | `commandId`, `taskId`, `operationId`, `controllerGeneration`, `text` (at most 64 KiB) | receipted | Steers the exact active operation. It cannot start a successor. |
| `home.stopTask` | `commandId`, `taskId`, `operationId`, `controllerGeneration` | receipted | Persists the exact Stop intent and joins terminal settlement. Repeatable after settlement without repeating cancellation. |
| `home.redeliverTaskResult` | `commandId`, `taskId`, `homeId`, `routeGeneration` (positive) | receipted | Re-stamps one unadmitted wake event; see [Task wake inbox](#task-wake-inbox-and-terminal-push). |
| `home.revokeTaskScope` | `commandId`, `scopeId` | receipted | Revokes the standing scope. Repeated or missing references are no-ops. A revoked initial scope is never recreated by dispatch. |
| `home.revokeTaskGrant` | `commandId`, `grantId` | receipted | Revokes an available grant. Consumed, revoked or missing grants are no-ops and never resurrected. |
| `home.decideTaskGrant` | `commandId`, `requestId`, `approved` (boolean), `expiresAt` (future Unix milliseconds) | receipted | Decides the exact pending request; the command ID is the decision ID. Returns `{ decision, grant }`, with `grant: null` for deny. |
| `home.memory.page` | `limit?` (1–50, default 20), `cursor?` | disposable read | [Typed memory browser](#typed-memory-browser). |
| `home.memory.evidence` | `evidence`, `offset?` | disposable read | [Typed memory browser](#typed-memory-browser). |

### `home.status`

`home.status` is one bounded read that composes the record, the memory status and
`home.context`. It is the only Home
status shape; other documents link here.

```text
HomeStatus {
  taskRecovery: { available: true } | { available: false, reason },   // always present
  phase: "unavailable" | "undesignated" | "disabled" | "missing-session" | "rollover-pending"
       | "blocked" | "paused" | "active" | "ready",
  activation: HomeContextProjection,       // body-free; same projection as home.context
  readiness: { ready, gaps[] },
  recovery: { action: "inspect-record" | "designate" | "configure-memory" | "resume-memory" | "none", reason? },
  available, reason?, enabled,
  homeId?, sessionId?, openSessionId?, generation?, routeGeneration?, bindingRevision?, model?,
  chapter?: { count, currentBytes?, currentEntries?, recoveryDecision: "none" | "reserved" | "materializing" },
  live, sessionPresent,
  memory: HomeMemoryStatus
}
HomeMemoryStatus {
  paused?: true,            // durable operator suspension, independent of any source or compactor block
  configured, open, model?,
  spentTokens?,             // persisted over the memory's life; reported, never a ceiling
  episodic?,                // the memory owner's bounded status; absent until its store opens
  blocked?, reason?         // reported even when no store is open
}
```

- `phase`, readiness and recovery are derived on every read, not stored. Readiness
  gaps name an unavailable record, a
  missing or disabled designation, an unconfigured, blocked or operator-paused
  memory (`memory-paused`). An idle paused Home is
  `paused`. An activation holding its frozen view stays `active` until it settles.
- `openSessionId` is `sessionId` when that chapter exists, and the sealed
  predecessor while a successor is `reserved` or
  `materializing` (`rollover-pending`). It is absent when nothing is openable, so a
  client routes by this field alone. It never
  makes a sealed chapter writable: `session.prompt` to the predecessor refuses with
  `sealed-chapter`, and only `home.prompt`
  materializes the successor.
- `live` reports whether the session holds a runtime now. `sessionPresent` reports
  whether it exists, live or on disk. Before the
  first catalog cut completes, `sessionPresent` is `true`, because an unread catalog
  cannot prove absence.
- `taskRecovery` fences only task surfaces until the next Gateway start. It does not
  gate ordinary readiness or `ok`.
- The memory projection carries counters and state only, never messages or view
  text. `spentTokens` is present whenever a store
  exists. An open activation without request sizes reads as awaiting preparation
  unless a refusal reason is present.

### Typed memory browser

`home.memory.page` and `home.memory.evidence` are disposable authenticated reads,
not receipted mutations. Their types live in
`src/protocol/types.ts`, and parameter admission and bounds live in
`src/home/home-memory-browser.ts`. They read the configured
memory, including a disabled or paused Home. They may open its store and refresh the
catalog through the episodic ingestion owner,
but they **never admit compactor calls, resume a block, send a prompt or materialize
a chapter**. Already-running compactor work may
finish. Unconfigured memory refuses with `conflict`; no provable canonical cut
refuses with retryable `busy`.

- **`home.memory.page`** returns `{ homeId, revision, totalItems, items, nextCursor?
  }` in stable catalog-index order: at most `limit`
  rows and **128 KiB of encoded JSON**. A byte-limited page continues at the first
  unreturned index. A row has `index`, `kind`,
  `attribution` (`user`, `assistant`, `tool`, `event`), canonical `timestamp` when
  known, `evidence`, `projection` and `summary`.
  - `projection` is `{ format: "memory-projection", text, omitted, omissions }`:
    capped and redacted catalog text, **never exact
    evidence**. It keeps at most 4,096 UTF-16 characters without splitting a
    surrogate pair, adding `browser-cap` when it clips.
    Context replacements carry `context-edit`. An omitted or off-branch slot stays
    visible rather than renumbering later rows.
  - `summary` is `{ format: "memory-summary", text, truncated }` under the same
    bound, or `null` when unbuilt or invalidated. It is never
    an exact transcript.
  - `evidence` is `{ index, sessionId, entryId, sourceDigest }`: the physical
    chapter, the canonical entry identity and the SHA-256 of its
    original JSONL line. It is not a path or a projected address. Identity strings
    are bounded to 200 UTF-8 bytes, the digest is 64 lowercase
    hex digits, and references must match the current catalog. Cross-session or
    arbitrary identities refuse with `conflict`.
  - **Continuations** are canonical base64url `{ revision, offset, limit }` (at most
    1,024 characters). Repeat the same `limit`. Replay returns
    the same page while unchanged. The content-derived revision covers the Home
    identity, generation, committed catalog and node revision, and
    per-chapter source cuts. Any append, invalidation, summary settlement or changed
    cut returns a retryable `conflict` with
    `home-memory-revision-changed`. The client reloads page one. There is no cursor
    cache and no automatic retry. Offsets beyond the catalog and
    changed limits refuse rather than clamp.
- **`home.memory.evidence`** accepts `{ evidence, offset? }` and returns `{ format:
  "canonical-history", evidence, text, offset, nextOffset?,
  previousOffset?, totalCharacters, metadata }`. At most **24,000 UTF-16
  characters** per page, with surrogate-safe offsets. Text comes from the
  original canonical entry, not the redacted catalog or a context replacement. It is
  canonical history content, not raw JSONL, attachment bytes or a
  lossless encoding of every field. It can include credentials that were written
  into history, so it is for the authenticated reader only and never a
  diagnostic payload. An out-of-range or surrogate-interior offset is
  `invalid_request`.

Every read proves the complete frozen Home cut through the per-chapter index before
it returns anything, then fences the exact ledger, binding and
memory revision after its awaits. The evidence reader keeps only the selected
bounded line and re-proves its chapter prefix at use. It never opens a
writer-capable `SessionManager`. Missing, changed or malformed sources yield no
partial page or evidence, even when an earlier chapter was readable
(`busy`, `home-memory-source-unavailable`). Unknown fields and malformed bounds are
`invalid_request`. Source details, references and content are never
logged. Both endpoints use the shared disposable read deadline. Cancellation never
cancels a prompt or an accepted mutation. Proof streams raw lines but
traverses the compact index, so its cost scales with the Home history, not only with
the page size. No persisted format and no client cache is introduced.

## The terminal client

`tron-chat` (`packages/gateway/src/client/terminal-chat.ts`) is the terminal client.
iOS designates, configures and pauses memory, reads status and runs task controls
through the same `home.*` RPCs. An ordinary iOS chat sends `session.prompt` to the
session it shows. A Home chat opens `openSessionId` and sends `home.prompt`, so its
next send materializes a reserved successor and then follows `sessionId`. It never
sends `session.prompt` to a sealed chapter.

The terminal prompts the logical route the same way: with no `--session`, it asks
for the logical route, and while Home is enabled, ordinary input goes through
`home.prompt` as chapters change. A reserved successor is not opened just to attach;
its runtime is created only when a prompt activates it. `--session` remains an
explicit physical route. The terminal subscribes to the physical runtime only after
a chapter is active. Ordinary routes are unchanged.

- **Attachment.** The connection owns one chapter attachment. A candidate token owns
  the new attachment until sync and installation succeed; a failed candidate closes
  its token and the prior attachment stays owned. A successful transfer installs the
  successor's snapshot and listeners before closing the outgoing token. Resync and
  disconnect retire the previous protocol client first, including a still-connected
  one, so its subscriptions cannot outlive their owner and block idle eviction.
- **Prompt loop.** One accepted operation is owned with its chapter, submission leaf
  and settlement reads. Only that chapter's validated canonical
  `tron.chat-invocation.v1` terminal receipt for the exact operation retires the
  waiter. `command.status` proves acceptance, not completion. An outgoing idle
  chapter, an assistant reply or a newly idle snapshot is never terminal evidence.
  Receipt reads run even while Home still projects `running`.
  `session.history.entry` walks parent identities from the synchronized leaf to the
  terminal receipt, the submission leaf or the invocation's start. There is no
  older-page or transcript-row fallback, so paged-out user rows and input hooks that
  create no user row are covered. Every await is fenced to the operation, client,
  session and branch cut; a changed cut is re-evaluated, never published as
  settlement.
- **Reconnect** keeps the operation and renders new assistant text before its
  response arrives. A pending receipt is polled on the healthy replacement without
  repeatedly closing it. Token-matched `session.rebaseline` frames install their
  snapshot as authority. Chapter transfer and subscription close never require a
  WebSocket disconnect. Reconnect reason and event-gap markers are in
  [observability.md](observability.md).

`/home` is resolved without touching the Gateway, so a bad argument is answered
before any RPC. Malformed arguments are caught in the loop, and assistant refusals
render from the canonical `errorMessage`. `/home` alone is `/home status`. An
unknown or incomplete command prints usage. A model not spelled `provider/id` is
reported with its reason. `/home memory` takes exactly one model argument. A refused
RPC is printed and the chat continues. The table is generated from `HOME_USAGE` in
`terminal-chat.ts`; every usage entry has a row.

| command | RPC | what it does |
| --- | --- | --- |
| `/home [status]` | `home.status` | Phase, activation, readiness gaps, memory and recovery action. |
| `/home designate [provider/id]` | `home.designate` | Designates Home. Without a model, the Gateway's default is used for a fresh session. |
| `/home disable` | `home.disable` | Disables Home; the session becomes an ordinary session. |
| `/home memory <provider/id>` | `home.configureMemory` | Configures memory, then prints the memory projection it returns. Exactly one model argument. |
| `/home resume` | `home.resumeMemory` | Resumes paused or blocked memory, then prints the memory projection it returns. |
| `/home context` | `home.context` | The activation's start, whether it is open, the request sizes and its refusal. |
| `/home reconfirm-permissions` | `home.reconfirmPermissions` | Reconfirms standing scopes for the current restore epoch; revoked scopes and grants are not renewed. |
| `/home permissions` | `home.taskPermissions` | Prints the strict durable scopes, requests, decisions and grants as JSON. |
| `/home revoke-scope <id>` | `home.revokeTaskScope` | Revokes a standing scope. Already-admitted work is unchanged. |
| `/home revoke-grant <id>` | `home.revokeTaskGrant` | Revokes an available grant. Already-admitted work is unchanged. |
| `/home approve-grant <request-id> <expiry-ms>` | `home.decideTaskGrant` | Approves a pending request with a one-use grant that expires at the given Unix-millisecond time. |
| `/home deny-grant <request-id> <expiry-ms>` | `home.decideTaskGrant` | Denies a pending request. Records the decision without a grant. |
| `/home task <id>` | `home.taskStatus` | Lifecycle, result outcome, and input and output tokens. |
| `/home steer <id> <text>` | `home.taskStatus`, then `home.steerTask` | Steers an active task with the exact operation and controller generation read from status. |
| `/home stop <id>` | `home.taskStatus`, then `home.stopTask` | Stops an active task with the exact operation and controller generation read from status. |
| `/home redeliver <id>` | `home.status`, then `home.redeliverTaskResult` | Re-stamps an unadmitted task result to the current Home route. |

## Evidence

Each row names a test file, the failure modes it proves, its artifact (a retained
path or the variable that sets one), and the regeneration command. Run from
`packages/gateway` under the pinned Node runtime. Rows marked "none" prove behavior
without a retained artifact.

| test file | failure modes proven | artifact | regenerate |
| --- | --- | --- | --- |
| `src/sessions/home-activation.e2e.test.ts` | chapter admission and rollover; receipt replay; joined submissions; signal privacy; real SDK byte stop; cyclic cold evidence; memory browser contract; reserved and cold profile orderings; pause receipts; inline-photo mirror; terminal child cases | `test-results/home-activation/report.json`; `test-results/terminal-chat-home/attachments-{rollover,failed-sync,handled-input}.json` (`-t 'owns exact Home attachments'`) | `npx vitest run src/sessions/home-activation.e2e.test.ts` |
| `src/sessions/home-request-seam.integration.test.ts` | seam identity, path and byte refusal; five rebuilds and five reloads per manager | `test-results/home-activation/seam-report.json` | `npx vitest run src/sessions/home-request-seam.integration.test.ts` |
| `src/sessions/home-cache-layout.e2e.test.ts` | cache layout across the frozen view; post-terminal quiescence; refused-activation readiness | `test-results/home-cache-layout/report.json` | `npx vitest run src/sessions/home-cache-layout.e2e.test.ts` |
| `src/sessions/home-managed-provider.integration.test.ts` | Home delegate-only versus ordinary managed-provider sessions through reload, replacement and cold acquisition | `test-results/home-managed-provider.integration.json` (or `TRON_HOME_MANAGED_REPORT`) | `npx vitest run src/sessions/home-managed-provider.integration.test.ts` |
| `src/sessions/home-provider-runtime.e2e.test.ts` | shared eligibility and filter identity across three rebuilds and disposal; ordinary eligibility retirement | `test-results/home-provider-runtime/report.json` | `npx vitest run src/sessions/home-provider-runtime.e2e.test.ts` |
| `src/sessions/home-memory-tools.e2e.test.ts` | the three memory tools, end to end | `test-results/home-memory-tools/report.json` | `npx vitest run src/sessions/home-memory-tools.e2e.test.ts` |
| `src/sessions/runtime-tool-loadout.integration.test.ts` | disable keeps the loadout; `session.setTools` restores the active set | none | `npx vitest run src/sessions/runtime-tool-loadout.integration.test.ts` |
| `src/transport/rpc-idle-admission.integration.test.ts` | ordinary-session Stop continuation is unaffected by task Stop | none | `npx vitest run src/transport/rpc-idle-admission.integration.test.ts` |
| `src/episodic/home-source.e2e.test.ts` | cross-chapter replay, restart, navigation and frozen-cut proof | `test-results/home-memory/continuity.json` | `npx vitest run src/episodic/home-source.e2e.test.ts` |
| `src/episodic/home-source.scale.test.ts` | streamed source bound (`heap.json`); 2,000 messages at production caps (`heap-production.json`); 20 messages of 2 MiB at production caps (`heap-over-cap.json`) | `test-results/home-memory/{heap,heap-production,heap-over-cap}.json` | `npx vitest run --config vitest.scale.config.ts src/episodic/home-source.scale.test.ts` (`-t production` for `heap-production.json`) |
| `src/home/home-owner.test.ts` | strict admission; unknown-version, malformed-topology, corrupt, empty and permissive records preserved and refused; unavailable workspace, including through a symlink | none | `npx vitest run src/home/home-owner.test.ts` |
| `src/home/home-session-recovery.test.ts` | reserved-chapter scan: absence proven only after a complete scan; duplicate IDs; path mismatch; uninspectable entries; enumeration errors | none | `npx vitest run src/home/home-session-recovery.test.ts` |
| `src/home/home-task-dispatch.e2e.test.ts` | the real `delegate` tool; report addresses and digests; duplicate and conflict refusals; length and no-report outcomes; live and cold settlement; sync failure; stopped-before-conversation; report and steer race; RPC authorization; attributed wake delivery; four deadline adversaries; frozen-owner cuts at commit, grant consumption, worker creation, binding, report append and terminal commit | `HOME_TASK_REPORT=<artifact-path>` | `HOME_TASK_REPORT=<artifact-path> npx vitest run src/home/home-task-dispatch.e2e.test.ts` |
| `src/home/home-wake-inbox.integration.test.ts` | frozen-owner cuts for claim, admission, terminal and acknowledgement; route replacement; redelivery | `HOME_WAKE_REPORT=<artifact-path>` | `HOME_WAKE_REPORT=<artifact-path> npx vitest run src/home/home-wake-inbox.integration.test.ts` |
| `src/home/home-materialization-crash.e2e.test.ts` | frozen-owner cuts at claim, path record, first flush and post-rename or pre-directory-fsync; visible-publication fence; `publication-uncertain` retirement; disabled-profile reconstruction | `HOME_MATERIALIZATION_CRASH_REPORT=<artifact-path>` | `HOME_MATERIALIZATION_CRASH_REPORT=<artifact-path> npx vitest run src/home/home-materialization-crash.e2e.test.ts` |
| `src/home/home-ledger-crash.e2e.test.ts` | seal and reserve with a real child process killed by SIGKILL | `test-results/home-ledger-crash/report.json` | `npx vitest run src/home/home-ledger-crash.e2e.test.ts` |
| `src/home/home-receipt-crash.e2e.test.ts` | SIGKILL after binding, during SDK effects before completion, and after completion before response: pending fences and exact replay | `test-results/home-receipt-crash/report.json` | `npx vitest run src/home/home-receipt-crash.e2e.test.ts` |
| `src/sessions/runtime-registry.integration.test.ts` (`-t deadline`) | 24-hour owned-operation deadline: endless no-effect and successful-read turns; a blocked provider request; joined stop | `test-results/owned-session-deadline/report.json` | `npx vitest run src/sessions/runtime-registry.integration.test.ts -t deadline` |
| `src/home/home-request-policy.test.ts`, `home-memory-tools.test.ts`, `home-memory.test.ts`, `home-task-spend.test.ts` | cache marks on the view's first block and last line; typed unavailable tool results; serialized opens and coded ingest failure; usage deduplication and contradictory-usage refusal | none | `npx vitest run src/home/home-request-policy.test.ts src/home/home-memory-tools.test.ts src/home/home-memory.test.ts src/home/home-task-spend.test.ts` |

Two limits apply:

- **No power-loss proof.** Frozen-owner, SIGKILL and receipt cuts prove
  process-abandonment recovery at the persistence boundary. They are not physical
  power-loss tests or live-provider Gateway process tests.
- **Injected thresholds.** Threshold diagnostics inject measurements at the owning
  metrics seam and are not large-file proofs. The canonical-admission and
  input-crossing cases in `home-activation.e2e.test.ts` append real SDK entries and
  lower only the shared hard constants in the test module (64 KiB and 100 entries).
  Their artifact records the measured bytes and entries and the thresholds used.
