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

## Display identity

Every chapter of Home presents the session title **Home**, independently of its
canonical authored or generated name. Runtime snapshots, live summaries, cold
catalog/search cuts and iOS Home-route chrome project that role without rewriting
JSONL or opaque session IDs. Ordinary sessions retain their own names.

Notification admission uses the designation owner's chapter membership to choose
**Home** for all Home notification producers, including input requests and settings
approvals, before persisting the relay retry envelope. Historical inbox rows project
that role title on read without rewriting receipts or already-sent payloads. Task-wake notifications use
the same title. The role title is product copy, so preview-disabled explicit
notifications retain **Home** while preserving their existing model-text body redaction. The focused `runtime-terminal-notifications.integration.test.ts`
Home-title journey checks a real registry, notification store and local HTTP relay;
its payload artifact is not physical APNs-delivery evidence.

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
| `policyRevision` | The curated-profile revision in force; `3` added the learned profile tool (#731), `2` the research tools (#724). Designation and re-enable both write this build's revision, so an older record advances the next time Home is enabled. |
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
unchanged. There is no down-conversion. The refusal leaves the record's bytes unchanged.

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

### Dashboard list

The record's chapter set is the only identity for Home (not the workspace cwd: only
the record names a chapter, and a reserved successor has no file yet). The
`session.list` projection (`scope: "user"`) omits every chapter the record names,
current or sealed, enabled or disabled, so Home is never a dashboard row. Live
`session.summary` events for a chapter still reach clients: the status owner refreshes
Home on them, and a client applies a summary only to a row it already lists. Catalog
membership is unchanged, so search (`catalog("user")`, `readSearchCut`), `session.open`
by id, `scope: "all"` and Home's own reads are not filtered. A designation or rollover
that changes the chapter set publishes a list change, so clients re-list.
`session.open` of a sealed chapter loads it read-only, warm or cold (#911): the catalog header
proves the file's tail complete before the SDK opens it (an in-progress append is `busy`), opening
writes no byte, and the runtime's chapter state refuses every write. Only a materializing chapter,
or a file the ledger does not name, refuses to open (`home-session-catalog.e2e.test.ts`,
`home-request-seam.integration.test.ts`).

### Chapter contents

`home.chapterList` gives each chapter a `contents` object, absent when its canonical file cannot
be read (a partial count is never shown): `userMessages`, `homeReplies` (assistant messages
without a tool call), `tasksDelegated` (successful `delegate` tool results), the canonical
`firstAt` and `lastAt` timestamps, and `topics`. `topics` holds at most eight of the chapter's
newest summaries, drawn from the largest built merged nodes covering it (level-0 summaries only
when no merged node is built yet). Each is one line of at most 200 characters, ended at a word
boundary, with kind prefixes, tool/event lines and tool-call syntax removed. They are read from
the open memory only; with no open memory it is empty. A reserved chapter has no file yet, so its counts are zero.

The counts are derived, never persisted. `HomeChapterContentsReader`
(`home/home-chapter-contents.ts`) caches each chapter's last scan in memory, keyed by its
file identity (device, inode, size and mtime). An unchanged file costs one `stat`. An appended
file parses only its new complete lines, once a SHA-256 of the 4 KiB before the cached offset
proves its earlier bytes unchanged; a changed, replaced or shrunken file is scanned again from
its start. The first read after a Gateway start scans each chapter once, so that read costs the
size of the Home history (at most the rollover limits per chapter). A later `home.chapterList`
costs one `stat` per chapter, the appended bytes, and one in-memory pass over the memory
catalog for topics, with no source read.

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

Gateway-owned stop owners (chapter limit, task Stop, deadline, and a task report
that must retire queued steering) record
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
| Extensions | `tron-context-window`, `tron-compaction-policy`, `tron-settings`, `tron-ask-user`, `tron-display`, `tron-notify`, `tron-home`, `tron-home-research` | every Tron module, Pi built-ins (codemode, tool-search, MCP) and the Tron-pinned managed subagent provider |
| Discovery | `noExtensions`, `noSkills`, `noPromptTemplates`, `noContextFiles`; no subagent discovery | agent directory and trusted project resources; managed-provider settings exclude user pi-subagents declarations |
| System prompt | agent-directory `SYSTEM.md` and `APPEND_SYSTEM.md` dropped (`systemPromptOverride`, `appendSystemPromptOverride`) | loaded |
| Executable tools | `ask_user`, `display`, `notify`, `zoom`, `date`, `memory_search`, `delegate`, `task`, `profile`, `web_search`, `web_fetch`, `session_search`, `knowledge`, `read_file`, `settings` (`HOME_TOOL_NAMES`) | SDK defaults plus Tron's direct bash tool |
| Compaction | disabled per session | canonical policy |
| Model | fixed physical model | any, including virtual routing |
| Model runtime | session-local view of the Gateway-wide user-scope runtime | one per session runtime |
| Cache warming | zero requests | unchanged |

- Managed pi-subagents loaders, producer-bound factories, wake admission and
  completed-load admission apply only to ordinary runtimes, including task workers.
  Home is delegate-only: `session.resources` returns an empty subagent catalog
  without provider discovery, through reload, replacement and cold acquisition.
- `tron-home` is loaded only for Home. It registers the memory tools, `delegate`,
  `task` and `profile`, and is the single answer to the SDK's
  `cache_warming_decision`. It is not in `modules.list`. It has no `before_agent_start`
  hook: Home's system prompt (the operating context and the learned profile section,
  read once per activation) is framed by the request seam for every request, user or
  wake (`homeSystemPrompt`, #749).
- `tron-home-research` is loaded only for Home (#724). It registers the
  [read-only research tools](#the-research-tools). It is not in `modules.list`.
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
designated one, applied through the session's model setter when the live model differs.
Runtime construction supplies the recorded model explicitly. A virtual (routed)
model is refused everywhere, because routing runs on the canonical transcript, which
the Home profile does not own. A model applied to the **enabled** Home is written
back to the record, the single source for re-enable. A model applied while disabled
is an ordinary change and does not touch the record.
`session.setThinking` and `session.setContextWindow` apply to the enabled Home session like any
session. Each activation is measured against the window its session's model reports, which
`home.context.breakdown.contextWindow` shows.

**Tool loadout.** A profile change does not rewrite the loadout, because Pi replays
the declared loadout at every runtime creation. A disabled Home starts with
`ask_user`, `display` and `notify`; the ordinary tools are only registered
(`runtime-tool-loadout.integration.test.ts`). The memory and research tools belong
to the Home-only modules and are never registered or activated for an ordinary
profile. A Chat-layer `tools.active` change (`settings.change`) restores the ordinary tools.

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

### Request breakdown

`home.context` (and `home.status.activation`) reports the last request an activation prepared as
`breakdown`: `activation` (`state` `running` or `settled`, `kind` `user` or `wake`, `startedAt`),
the request's `contextWindow` and `effectiveTokens`, and its `sections`, which sum to
`effectiveTokens`:

| section | holds | `count` |
| --- | --- | --- |
| `instructions` | the SDK's base prompt and Home's operating context | none |
| `profile` | the learned profile section | active profile notes it lists |
| `memory` | the frozen memory view | summary lines |
| `chapter` | the activation's other messages: its tool calls and results, steers and pending notices | canonical entries |
| `results` | task results delivered in the activation | results, not counting a wake's trigger |
| `input` | the maintainer's message, or a wake's trigger result | none |

Tokens are estimates. `effectiveTokens` includes the system prompt, which is the request's head,
so the overflow refusal measures it too. Recorded system messages are replaced by that head and
are not counted. A wake is started by the task result that woke Home, so that trigger is its
`input` and a wake that delivered one result reports `results` as zero. The breakdown is absent
until the activation prepares a request, and a refused activation before that has no sizes.

### Prompt caching

Each request can re-read what the previous one sent (#491). The exceptions are the
first request after a view rebalance, invalidation,
restart, or cache expiry.

- The system prompt and tool list carry no dates or per-turn state. The learned
  profile section is the one part of the system prompt that varies, and it changes only
  when a profile item changes: one prompt-cache miss, then stable again
  ([the learned profile](#the-learned-profile)).
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
- **Refusal text.** A refusal's chat error is one fixed sentence per reason
  (`HOME_REFUSAL_SENTENCES`, `home-request-policy.ts`), with no counts, IDs or memory text.
  The SDK retries an assistant error that its transient classifier matches, and the
  classifier matches substrings such as `500`, so a deterministic refusal that embedded
  `effective 4500 tokens` ran its retry budget. The variable detail stays on the refusal
  record, which `home.context` reports as `lastRefusalReason` and `lastRefusalDetail`; the
  chat error does not carry it. Every reason's text is never retryable, and C12 of `home-request-seam.integration.test.ts` proves an overflow
  refusal produces one refusal and no retry.
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
  runtime, never from a session. It returns summary content only: Home labels each
  leaf line from its canonical item kind, labels multi-message lines as summaries rather than a single speaker, and refuses
  echoed role labels or compactor repair instructions. Rejected output receives
  same-conversation corrective feedback within the shared five-attempt size/content
  bound; it is never stored or selected as a shortest candidate. If no valid
  candidate survives, memory stays blocked until supported operator recovery.
  Older invalid stored
  summaries are revoked through the episodic projection and rebuilt on demand.
- **Checkpoints.** Opening the store publishes a checkpoint only when the episodic
  store's threshold is crossed, not on every open
  ([episodic-memory.md](episodic-memory.md)).
- **Configuration.** There is no default model. The memory model is the Home
  profile key `model.ref[role=memory]`, changed through `settings.change`
  ([settings-model.md](settings-model.md)); its applier writes `memory.model` in
  `<tronHome>/gateway/home/profile.json` through `HomeOwner` and refuses virtual
  or unregistered models. The same model changes nothing. `home.json` keeps only
  memory pause state. Runtime reads never fall back to its former model field.
  Before Home admission, a one-time transfer preserves the old configured model
  and pause state, publishes an idempotent settings audit, then removes the old
  model field. A bounded durable intent makes interrupted publication recoverable;
  conflicting store bytes preserve both files and refuse Home with
  `home.unavailable reason=memory-profile-transfer`. This is a startup transfer,
  not a live migration command. No memory nodes, spend or credentials move.
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
| any block | Setting a *different* memory model (`settings.change`, `model.ref[role=memory]`), which resumes it while reopening the store. |

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

## The research tools

Home gets a curated **read-only** tool set (#724, maintainer decision) so it can
find things out and remember them, while real work still goes to delegated worker
sessions. `tron-home-research` registers five tools; all five are inside
`HOME_TOOL_NAMES`, always registered (the tool list heads every cached prefix, so
availability answers inside a result, never by changing the registration surface),
and constant in description.

| tool | what it answers |
| --- | --- |
| `web_search(query, maxResults?)` | Public web results (DuckDuckGo's HTML endpoint): title, URL and snippet per hit, at most 10. |
| `web_fetch(url)` | One public http(s) page's readable text with its title and final URL, through capture's transport: credential-bearing URLs refused, every redirect hop DNS-resolved and refused when private (SSRF), the body read to a 2 MB bound. |
| `session_search(query, maxResults?)` | This installation's chats through `SessionSearchService`: session, entry, kind, title and a bounded snippet per hit, with coverage and ranking state. |
| `knowledge(action, ...)` | Exactly the read-only subset of the Knowledge tool: `search`, `recall`, `read` and `list`. Writes, connectors, curation and paid assessment are structurally absent from the schema, so Home cannot name them. |
| `read_file(path, offset?, limit?)` | A bounded page of one file inside an **explicitly trusted** project, by absolute path. The canonical (symlink-resolved) location decides trust, and only a recorded `true` decision counts — the "always" default-trust setting never does — so a link inside a trusted project cannot read outside it, and Home's own workspace (recorded `false` at designation) is unreadable. No directory listing, no writes. |

- **Bounded.** Every result is capped at the memory projection's tool-result bound
  (30,000 characters, head and tail kept, with a marker), at the tool itself.
- **Seam-unchanged.** The module registers tools only: no extension `context`
  handler, no provider registration, no per-turn state in a tool description.
  Every call runs inside an ordinary Home activation and passes the request seam
  as-is (`home-research-tools.integration.test.ts` proves each tool with zero seam
  refusals, and that ordinary sessions gain none of this).
- **Owners per call.** Knowledge and session search resolve their service at every
  call and answer a typed `unavailable` when absent; trust is read from the trust
  store at every call, so a revoked decision takes effect immediately.

**Injection surface.** Web results, fetched pages, other chats' snippets and
Knowledge records are untrusted content, and Home can delegate tasks under the
maintainer's standing scopes — so retrieved text could try to talk Home into
dispatching work. The v1 decision is to **not** gate delegation on whether a turn
fetched external content: standing scopes are maintainer-granted and revocable,
every task is admitted with a durable attributed record and an explicit report, the
maintainer shares steering, and a fetched-content fence would be per-turn state the
request seam forbids in anything heading the cached prefix. Instead, each web and
session result carries a constant untrusted-content banner, the operating context
says retrieved text is never instructions or authorization to delegate, and this
paragraph records the residual risk: a prompt-injected Home could still dispatch a
task inside an existing standing scope, exactly as it could from a maintainer
message that quoted the same text.

## The settings tool

Home is the chief of staff for settings: it changes any setting its writers allow
with the `settings` tool (`tron-settings`, the same module every session loads),
through the one change path, recorded as `home` with its chapter session and the
tool call ([settings-model.md](settings-model.md) 5.1). Its tier is enforced like
any agent's (5.4): a quiet floor applies, notify applies and pushes, approve holds
a pending change for the maintainer's tap. `web_search`, `web_fetch` and the other
tools that do not declare `openWorldHint: false` mark the activation (`bash` is
declared trusted, decision 33), which
raises the tier one step; unlike delegation (above), a settings change is gated on
fetched content, because the mark is Gateway state read when the change is
planned, never request text. The mark lives in the module, not in the cached
prefix. A declined, expired or superseded change Home asked for is named in one
custom message on Home's next maintainer-prompted activation (a wake starts its
run from the task result alone, so it carries none).

## The learned profile

Home keeps what the maintainer taught it as Knowledge notes (#731, epic #734). The
Knowledge owner is the only store: there is no Home-side profile file, cache or
timer. The `profile` tool is the only writer, and every change is one Knowledge note
mutation.

- **Membership.** A personal-scope note is a profile item when it carries the
  `home-profile` label and exactly one `kind-<kind>` label, where kind is
  `preference`, `standing-decision`, `delegation-default` or `fact`. Provenance never
  decides membership: it changes when the maintainer edits a note natively.
- **Writes.** `profile` takes `learn(kind, text)`, `refine(id, text)`,
  `supersede(id, kind, text)` and `retire(id, reason)`, plus an optional `reason` on
  refine and supersede. Every write carries provenance `actor: agent`, `source: home`,
  the Home chapter session, and a `sessionEntry` citation of the last maintainer
  message on the chat's branch, the message the turn answers. Items are always written
  unconfirmed. Only Knowledge's native confirmation owner sets `confirmed`. The tool
  result states what was saved, and the call is a visible transcript entry.
- **Ledger.** Each action is a note revision carrying its reason
  (`provenance.reason`). Refine keeps every earlier revision, readable by revision ID
  through `knowledge read`. Supersede creates a new item whose `supersedes` relation
  names the old item's current revision and leaves the old record untouched. Retire
  writes a revision with `retired: true`.
- **Lifecycle.** An item is *active*, *superseded* (derived: a profile item's current
  revision names it in a `supersedes` relation, even when that replacement is itself
  retired), or *retired*. `refine`, `supersede` and `retire` act only on an active
  item, and a refused action leaves its revision unchanged. Knowledge exclusion or
  forgetting also removes an item from the profile. Excluding a replacement brings back
  the item it superseded.
- **Injection.** Each activation's system prompt carries the section after the
  operating context: the heading `## Learned profile`, a fixed introduction, and one
  line per active item in kind order, then creation time:
  `- note <id> (<kind>, confirmed|inferred): <text>`. The text is verbatim. The read
  is a pure Knowledge `list` of personal notes, paged, with no model call. An
  unchanged profile yields a byte-identical prompt, which `home-profile.integration.test.ts`
  proves.
- **Bound.** `HOME_PROFILE_BOUND_BYTES` is 8 KiB, the UTF-8 size of the item lines:
  about two thousand tokens on every Home turn, enough for several dozen one-sentence
  items. Over the bound, no item text is injected, whole or partial, because a
  truncated preference is worse than none. The section says the profile is over its
  bound, names its items by ID and kind until the bound, and tells Home to consolidate
  them with refine, supersede or retire.
- **Unavailable.** When Knowledge is absent or the read fails, the section says so.
  It never reads as an empty profile.
- **Native edits.** iOS and the Mac dashboard save notes from typed drafts that do not
  model labels or retirement. The Knowledge owner keeps `tags` and `retired` when an
  update or correction omits them, so a native confirmation, edit or correction keeps
  the item in the profile, marked confirmed (`knowledge.md`, "Note labels and
  retirement").
- **Briefs.** The operating context instructs Home to put every applicable item into
  each delegation's intent and to end the brief with a `Preferences applied` section
  listing each note ID and its text. That instruction governs the model's composition;
  the runtime does not check the brief. `home-profile.integration.test.ts` proves the
  path from the injected section to the worker's first request, with a scripted Home
  that composes the brief from the prompt.
- **Observation.** Knowledge's automatic observation never reads a Home chapter. The
  Gateway passes `homeChapterObservationExcluded` as the observer's exclusion
  predicate. It excludes every chapter the Home record names, whether Home is enabled
  or disabled. A forked ordinary session is observed normally.
- **Costs and limits.** Each activation reads every personal note page by page to
  find the profile, so the read grows with the personal note count. A single personal
  note over Knowledge's 750 KB page budget makes the read fail, and the section then
  reports unavailable. The delivery-headroom estimate does not count the section
  (up to about 2,000 tokens, against a 1,024-token reserve); the request seam still
  refuses an overflowing request explicitly. The trigger is the last user-role message
  on the chat's branch, which is the maintainer message for an ordinary turn.

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
  - `intent`, `intentDigest`: immutable `{ text }` (at most 64 KiB UTF-8); the digest
    is SHA-256 of the text.
  - `target`: immutable absolute target (at most 4 KiB). Storage is not admission
    authority.
  - `grantRef`, `scopeRef`: nullable, at most one set, each naming an existing
    authorization record, filled once, never swapped.
  - `lifecycle`: `pending`, `active` or `terminal`. `active` requires authority and
    session and operation identity; `terminal` requires terminal
    evidence and a co-committed wake event.
  - `sessionId`, `operationId`: set by dispatch; shared control fences the active
    operation.
  - `stopIntent`: null or exact `{ operationId, requestedAt }`, durable and never
    replaced.
  - `spend`: null or exact `{ sourceDigest, inputTokens, outputTokens }`. Counts are
    safe nonnegative integers. No cost is recorded.
  - `budget`: absent (no limit) or `{ inputTokens?, outputTokens? }`, the Home
    profile's `permissions.budget.task` fixed when the task was admitted; no later
    publication may change it.
  - `reportRef`: null or exact `{ resultId, sessionId, entryId, digest }`, the one
    canonical report the task sealed; the digest pins its payload.
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
  the decision. It binds the intent digest, canonical target,
  authorization scope, expiry and restore epoch.
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

**Bounded admission (#919).** Every awaited admission step (`choice`, `setup`,
`lookup`, `budget`, `target`, `create`, `authorize`, `restore-epoch`,
`create-worker`, `configure-worker`, `bind`) runs under a 60 s per-step deadline
and the delegating Home turn's Stop. The steps themselves cannot be interrupted (a
stalled store or session lane ignores signals), so a refusal stops waiting for
the step, the `delegate` tool fails at once, and the step's late result returns to
its owner: a late task record or operation binding is settled, a late worker lease is
released and never prompted. A refused step after the pending record exists
settles the task `unknown` with `admission-cancelled` (Stop) or
`admission-timeout` (deadline), outside the Stop path, and like every terminal task
its one result wake follows. A step that took 5 s or more, timed out or was cancelled
logs `home.task.dispatch-stage` naming the stage.

**Worker model and thinking.** At each `delegate` call the Gateway resolves `model.ref[role=worker]`
and `model.thinking[role=worker]` from the typed Home profile. The built-in value for either
field is same-as-Home, read from Home's live session at that boundary. An explicit `model` or
`thinking` supplied by Home wins only for that field and requires a short `reason`; a missing
field still resolves from the profile. Choices are copied into the task brief and are never
re-resolved for that worker. A later Home model/profile change therefore affects only a later
delegation. Ordinary sessions never read this profile and keep their repo/Mac defaults.

The resolved model must be registered, usable (its provider has credentials) and not virtual.
An unavailable profile-derived model falls through to the worker's normal Gateway/project
default, including when the unavailable choice came from same-as-Home. The fallback and
reason are recorded in the task brief; an explicit invalid model remains a refusal.
A fallback does not discard the independently selected thinking field: the worker's
actual default model clamps it at start, and the canonical worker brief records that
result without rewriting the authorized task intent/digest. Thinking is clamped to the closest level the actual selected model supports. The
Gateway applies the resulting fixed choices through the worker slot's `setModel` and
`setThinking` before its first prompt, recording Home-at-start provenance for the generic
settings badge (same as Home, Home profile, chosen for this task, or worker-default
fallback, with its reason). The fixed metadata survives cold reads rather than consulting
Home again. A `thinking` without an explicit model is permitted when it resolves with a
profile/Home model or its recorded fallback; a direct dispatcher request without a model still refuses thinking. Invalid
explicit choices return `invalid_request`; model admission refusals name at most twenty fixed,
usable models.

The operating context names Home’s live chat model and thinking at activation preparation. Unknown task IDs return `not_found`, including a not-yet-created namespace; foreign Home identities and damaged namespaces still refuse. Direct Home dispatch without a pre-resolved profile choice inherits Home’s live model/thinking; ordinary chats remain profile-free.

**Worker title.** `delegate` takes an optional `title` (at most 80 characters, not blank after
trimming). It names the worker session through the session's canonical name, written before the
worker's first prompt, and is never persisted with the task record. A refused title is
`invalid_request` (`Invalid task title`) and creates no task. Home's operating context asks for
one on every delegation.

- A task worker has normal project tools and resources plus `report`, and cannot
  replace its owned session. Its canonical `tron-home-task` marker binds the task,
  Home identity and generation, session and operation. Cold
  construction checks the marker before loading executable resources. Missing or
  contradictory tasks are never recreated.
- A sealed `report` ends the task at that turn's boundary (Pi's `finishTurn`
  `end`): no further model request starts, a later tool call in the same batch is
  refused, and the run settles `completed` with no aborted reply. Only when
  steering is still queued does the report take the task's exact stop, so that
  input is retired rather than stranded.
- Task Stop (control or deadline) is terminal, unlike ordinary chat Stop,
  which continues with queued steering. Accepted but unconsumed steers are removed
  with `task-stopped-before-delivery` receipts and never replayed. A steering
  preflight in progress is fenced by the sealed or stopping report owner and
  receives its own refusal receipt.
- The `OwnedSessionDispatch` seam has a fixed 24-hour wall-time ceiling. Only a
  caller that opts in owns it; ordinary sessions and Automations do not. Expiry
  cancels the exact operation and waits for its terminal completion before reporting
  a joined stop. Task dispatch applies the seam before asynchronous prompt
  preflight, and the same ceiling bounds the subagent join ([Subagent runs](#subagent-runs)).
  No user-configurable limit exists.
- Task workers load the same Tron-managed subagent provider as ordinary chats; Home
  does not. A worker may launch subagents, foreground, async or workflows. Every run its
  session starts is owned by the task operation, and its `report` waits for them
  ([Subagent runs](#subagent-runs)).
- The first-party task extension admits `subagent` launches, even `async:false`, which
  the pinned configuration can force async, and the read-only management of the
  verified `0.76.1-tron.6` provider: `guide`, `children.list`, `status`, `list`, `get`,
  `models`, and supervisor `status`, `pending`, `list`. It admits the run controls
  `steer`, `resume`, `interrupt`, `stop`, and `command.status`, `command.yield`,
  `command.cancel`, only for a run this session owns, addressed by `id` or `runId` and
  never by `dir`. A run is owned when this session's canonical history launched it, or when
  it is a child a workflow of this session names in its own provider status (`steps[].runId`).
  So a child is controlled by its own run id, as the provider's guidance names it, or through
  its workflow's run and `index`. A run id that no owned run or owned workflow names is refused,
  and so is a child of another task's workflow. A `resume` is owned when it
  starts: the run it returns is a canonical launch of the task. It admits a supervisor
  `reply` only with `replyTo` naming a request whose child run is owned; a reply with
  `to` or no `replyTo` names no request the gate can prove, so it is refused. It refuses
  every other mutating management action (create, update, worktree, schedule, budget and
  the rest), a run the task did not start, `dir` targets, revival of a run the task
  did not start, the schedule tool, any launch or control that attaches a mission
  (`mission` other than `false`, or `missionId`, since a mission outlives its run), and
  `bg_wait` with `nonBlocking: true`, whose durable subscription can wake the session
  after report. The blocking `bg_wait` is aborted and joined with the operation. Unknown
  versions or owners refuse all subagent, supervisor and `bg_wait` calls. A later pin
  requires a new explicit review before this gate changes. Nested codemode calls cross
  the same gate.
- Trusted extensions are not a sandbox. If detached-work tracking still sees
  task-session work after the subagent join, the outcome is `unknown` with
  `detached-work-outlived-task`, never a clean-termination claim.
- A task waits across turns while it owns live work (see [Subagent runs](#subagent-runs)).
  Only the task's own turns and its provider wakes run in its operation; a wake that
  arrives while the task is not waiting is refused as before.

### Subagent runs

A task owns every subagent run its worker session starts. The worker session is created
for one task and never reused, so its runs end with the task. Ownership is canonical:
a launch is a `subagent` call without an `action` that the gate admitted, a resume is a
launch of the run it returns, and an async run is identified by the `asyncDir` in its
launch result. A child run of a workflow the task owns is owned too: the workflow's own
provider status names it (`steps[].runId`), and the owner reads that status from the
workflow's canonical directory. A supervisor request is the task's when its child run is owned, and its
`subagent_supervisor_request` message names that run. Runs are never tracked by a
slot-wide map that outlives the session, and no field is persisted to prove ownership.

Per run, the states are:

- **launching → running**: the admitted call returns the run's identity. A foreground
  run is live inside that call; an async run is live from its published `asyncDir`.
- **running → terminal**: the provider reports `complete`, `failed`, `partial`,
  `stopped` or `rejected`, or a paused run has its process-terminal proof. A foreground
  run ends when the operation abort reaches its tool signal.
- **stop requested → stopped**: settlement calls the provider's own `stop` for each live
  async run through the installed controller. An accepted stop is counted, and the run
  becomes terminal once the provider writes `stopped`.
- **unjoinable**: the run is still live at the bound, or its stop was refused and it stayed
  live. The task is `unknown` with `detached-work-outlived-task`. A run is never reported
  as stopped unless it was joined.

A workflow can complete while the children it launched in their own runners keep running.
Such a child is live work of its run, under the same liveness rule as a live run: it keeps
the session running, blocks drain and eviction, and keeps the task join waiting. Its state
is read from its own `status.json`. Settlement stops a completed workflow's live child by
its run id, because the workflow itself can no longer be stopped. A live workflow is stopped
as itself, and the provider's workflow stop reaches its children.

Settlement runs in this order: operation terminal; report stop joined; the Gateway stops
and joins the live async runs and live workflow children; each async run's completion
notice is recorded (below); the worker's settlement fact is appended; the evidence cut; the
outcome. The join waits until no run is live. Its bound is one minute after the stops are
requested, or the task's 24-hour deadline (which stays armed through settlement) if that
comes first; after the bound, the join waits one disposal grace (5 s) more. A stopped runner settles within seconds, so a run still live
then (a refused stop, an unreadable status) keeps the detached outcome rather than
holding the sealed task open. The settlement fact is the worker's canonical custom entry
`tron-home-task-subagents` with `{ receiptId: "subagents:<operationId>", operationId,
stoppedAtEnd }`. It is written only when the task launched async runs, so its absence
proves zero Gateway stops. Its value is `null` unless every stop was accepted and every
run was joined. Stop-target enumeration takes one snapshot of the activity rows before
awaiting workflow-child status. Artifact refresh may reorder the live activity map but
cannot make the same row receive or count a second stop. The managed-provider journey
in `home-task-subagents.e2e.test.ts` forces a real artifact refresh during that read and
checks the canonical one-child stop count and terminal provider state.

**Completion notices.** The provider writes an async run's completion as a `subagent-notify`
custom message after the run is terminal, and the Gateway records a
`tron.context-delivery.v4` receipt for it. The notice can land after the report that
settled the run's status, so settlement joins until every async run the task started has a
recorded notice: a `subagent-notify` whose text names the run id, with its receipt present.
The join uses the same bound as the stop join. The notice has no structured run identity, so
the match is on the run id in its text. The fact and the evidence cut come after this join, so
a settled task has no later append from its runs. A notice still unrecorded at the bound is
counted as `noticesUndelivered` in `home.task.subagents`; a non-zero count is the
`notice-undelivered` condition. The outcome does not change, since the run itself is terminal.

The provider also creates a mission record for a default task-based launch unless
`mission: false` is specified. This is provider-owned history, not another Home task.
Its async completion watcher settles a stopped run's linked mission to `cancelled`;
Home does not rewrite mission files. Provider retention bounds terminal mission history
(default 200), not abandoned active records. The real Stop journey in
`home-task-subagents.e2e.test.ts` checks the exact run's mission after task settlement
and writes `test-results/stopped-subagent-mission.json`. A terminal run paired with an
active mission after settlement is a provider lifecycle defect, not expected retention.

The counts are projections read from canonical evidence and are never persisted with the
task record:

- `started` counts the subagent launches the task admitted, and each resume it admitted
  (a resume starts a new run). A call the gate blocked never counts. A provider that rejects an admitted launch before creating a run still counts,
  because its result carries no run identity to tell the two apart.
- `stoppedAtEnd` counts the async runs and workflow children the Gateway stopped at
  settlement. Foreground runs end with the operation abort and are not Gateway stops.

`home.taskStatus` returns `subagents: { started, stoppedAtEnd }`. `stoppedAtEnd` is
`null` while async work is unsettled or its stops cannot be proven. Without async runs,
it is `0`. Every Home result header states both counts. Settlement emits
`home.task.subagents`.

**Owner lifecycle is not work success.** For a terminal `unknown:no-report` task,
`home.taskStatus.ownerSettlement` is either `null` or a bounded read-only proof:
`{ taskId, sessionId, operationId, markerEntryId, terminalEntryId, settlementEntryId,
stoppedAtEnd }`. The dispatcher reads a durable canonical file cut and requires a
unique exact task marker, matching Gateway invocation start/terminal receipts, and
an ordered subagent settlement receipt at the end of the cut. The marker binds the
task, Home generation, session and operation; the invocation binds the same session,
operation and Gateway task origin. Missing, malformed, ambiguous, mismatched or
racing evidence stays unproven. A terminal invocation with unknown lifecycle and a
failed child settlement (`stoppedAtEnd: null`) also refuse. A successful join may
record zero stops when children finished naturally. No async settlement receipt is
not proof, even when projected live-run counts are zero: terminal `subagentRuns` is
synthetic. Task identity/lifecycle is rechecked after projection awaits. The local
claim helper rechecks status and the same operation/proof before returning `settled`;
other unknown reasons (including cold recovery, detached work and failed stops)
remain excluded. This never turns `unknown` into a successful work outcome or grants
control of another task. The proof requires an updated Gateway and rebuilt helper;
an old Gateway remains fail-closed. The canonical corruption/race regression is in
`home-task-subagents.e2e.test.ts`; `scripts/test-work-handoff.py` exercises the built
helper and real claim command, including refusal preservation and status races.

**Task waits across turns.** A task turn that ends normally (its final assistant message
stopped with `stop`, not `length`, `error` or `aborted`) without a report, while the task
owns live work, does not settle the task. The task holds its operation open between turns.
The provider's wake for that work starts the task's next turn in the same operation: a
run's completion notice, or a supervisor request from one of its children. The next turn
reports under the task's own operation, so its `report` seals the task, and a further
wake may start a further turn. The task settles on a report, on Stop, at the 24-hour
deadline, on a failed or aborted turn, or at a turn end with no live owned run and no
report. Stop and the deadline settle the waiting task at once; the live runs are stopped
and joined as at any settlement. The hold is in memory only: a restart leaves a waiting
task to cold reconciliation, which reports `detached-work-outlived-task` for a live run.
A live run of a waiting task is listed by `home.taskStatus`.

**Report waits for live runs.** `report` is refused while any run the task started is live,
by the settlement liveness rule above, including a live child of a completed workflow. The
refusal is an ordinary tool error that names the live count and the remedy: wait for the runs
(`subagent` status, or a blocking `bg_wait`) or stop them, then report. It seals nothing and the
turn continues. A stop request is not an ended run: a run stays live until its status is
terminal, so a report after `stop` waits for that terminal status. Settlement therefore has no
live run to stop when a report is accepted; it stops live runs on Stop, at the deadline,
or on a failed or aborted turn, never on a turn that ends with live work and no report.

Provider completion notices reach a task worker as context of its operation. No turn
starts after settlement: a wake starts a turn only while the task holds its operation open
between turns, and the no-turn checks in `home-task-subagents.e2e.test.ts` cover that
property.


**The `report` tool** takes `resultId`, a claimed `outcome` (`progress`,
`needs-input`, `final`), `text` (at most 64 KiB UTF-8) and `evidence` (at most 64
strings of 4,096 bytes; payload at most 128 KiB). It supplies no task, Home, session
or cost identity. It is refused while a run the task started is live
([Subagent runs](#subagent-runs)); the check runs at the seal, inside the report owner's
mutex, so a refused report never seals. Acceptance appends one immutable
`tron-home-task-report`, seals it, and requests an exact Stop without awaiting it from the tool that joins.
Settlement joins that Stop before publishing the result. RuntimeSlot's settlement
owns the single terminal receipt write and notifies the task observer after it. The
task lease alone acknowledges the operation marker, and only the exact task
operation suppresses the ordinary completion push. Identical duplicates reuse one
entry; conflicts refuse. References carry the exact entry ID and digest, never a
latest-assistant pointer.

**Outcomes.** A final reply without a report is `unknown`. A provider length stop,
a joined deadline or a reached task budget without a report is `limited` (reason
`length`, `deadline` or `budget`). The last assistant entry is
evidence only. A failed exact stop is `unknown` (`deadline-stop-failed`,
`task-stop-failed`, `report-stop-failed`). A subagent run still live after the join is
`unknown` (`detached-work-outlived-task`), whatever the report says. Admission alone
never establishes success.

**Budget.** The Home profile key `permissions.budget.task` (settings-model.md 6.1)
caps a task's own spend counters. Admission resolves it once through the settings
resolver and fixes it on the record. At each worker turn boundary the runtime
computes spend from the operation's canonical entries with the same projection as
the record, against the lower of the start budget and the current profile value per
field: a lowered budget applies to running tasks, a raised one only to later tasks.
Reaching it ends the run at that boundary, like a sealed report (queued steering
takes the exact stop), so no further model request starts; settlement records
`limited` with reason `budget`. Unset is no limit.

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
replay a prompt or tool. It stops no subagent run, since it has no runtime to stop one
through. Each async run of the abandoned task is checked against its own `status.json`
under the admitted artifact root: `complete`, `failed`, `partial`, `stopped` or `rejected`
has ended; any other state, or an unreadable status, is live. Each runner-backed workflow
child of that run is checked the same way under its own run directory. A live run or child
makes the outcome `unknown` with `detached-work-outlived-task`, even with a valid report. A
malformed settlement fact refuses the evidence rather than being guessed. Pending identities, including authorization consumed before
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
  after it. Task, Home identity and generation, session, operation
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
  ID ascending. A page and its `counts: { active, finished }` come from one read of
  every task record under the store mutex, never a report body: the counts need every
  record anyway, so the page is a consistent snapshot with them. `counts` are exact
  and independent of `limit`: `active` is every non-terminal lifecycle (`pending` and
  `active`), `finished` is `terminal`. Identical requests in flight share that one read,
  and a request whose client disconnected leaves the store queue (#906). The opaque cursor binds the last key to the restore
  epoch; foreign, restored and malformed cursors refuse (`conflict`,
  `invalid-record`). Each row carries task ID, dates, `title`, `project`, `sessionId`, target, lifecycle, terminal outcome or null, spend or null, `attention` (needs-input or unknown) and `pendingGrant`. `title` is the worker session's canonical name when it has one, else the brief's first non-empty line, at most 80 characters; `project` is the target's last path component; `sessionId` is the worker session the task dispatched (the record's `sessionId`), null before dispatch. A live worker's name comes from its slot (never a snapshot build) and a settled one's from the catalog's index of its file, so no transcript is read. Null spend is unavailable, not zero;
  A never-initialized listing returns `{ items: [] }`
  without creating authority.
- **`home.taskStatus`** returns the record (its `sessionId` is the worker session), `title` and `project` (as in `home.taskList`), the exact active operation, spend, the
  immutable result, `workerModel`, `subagents` (see [Subagent runs](#subagent-runs)) and
  `subagentRuns`. `workerModel` is the worker session's current `{ provider, id }`, read
  from its canonical `model_change` entries. A running worker answers from its live slot; a
  settled one reads its conversation file, through the same evidence cut as recovery. It is
  `null` before the worker records a model or when it has no conversation file. It is a read
  projection and is never persisted with the record. `subagentRuns` is `{ total, runs }`: the
  worker's live runs while the task is active, read from the live slot under the same liveness
  rule as the report gate. `runs` holds at most 20 entries, newest first, each `{ runId, agent,
  state, startedAt, lastActivityAt }`; `total` counts every live run. A settled task lists none,
  and nothing is persisted: the task record stays strict v1. The field is additive, so released
  iOS decodes the status without it. A run's `state` is its own lifecycle, or a live workflow
  child's when the run's own work has ended. Viewing never changes control. Home's
  `task` tool exposes `status`, `steer` and `stop`, only for tasks bound to the
  enabled Home's identity and generation; it can never reconfirm, revoke or decide.
  Status follows Home across disable and re-enable but never transfers control.
- **Steer and Stop** read status, then send the exact fenced command; an intervening
  change refuses rather than targeting a successor. Stop receipts can be repeated
  after settlement without repeating cancellation.
- Home and maintainer steering share RuntimeSlot's session lane; accepted lane order
  is authoritative. Steering cannot start a successor, and a report that races a
  delayed steer prevents it. There is no takeover state and no transfer command.
- Stop lives outside that lane. The binding persists the exact operation-fenced
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
terminal-to-outbox gap, no orphan event catalog and no independent retention sweep.
Event identity is SHA-256-qualified by task identity. Result IDs, report references,
terminal evidence and spend remain authoritative.

WakeInboxOwner moves an event through `pending → claimed → admitted → terminal →
acknowledged`, and it also holds `blocked` and `outcome-unknown`. Two things admit
pending results. A user activation admits them as context after its start boundary,
in creation and event-ID order. The **wake owner** (below) admits them as the trigger of
a Gateway-started activation with no user input. In both cases RuntimeSlot inserts each
result as a context-bearing `tron.home-task-result.v1` message with an exact
`tron.context-delivery.v4` attribution receipt. Ordinary chats, steers and continuations
do not drain the inbox.

**Quiet inbox (#922).** Recovery, admission, settlement and wake attempts run on Home's
session lane, so each reads only records whose wake it may still act on. A complete
pass that finds none (every wake absent, `acknowledged`, `blocked`, or
`outcome-unknown` with its push decided), with no task-store write during it, proves
the inbox quiet until the store's next write; until then those steps read no record.
The Gateway is the namespace's only writer, and every durable publication (a new
result, a delivery, an acknowledgement) ends the proof. A quiet Home turn therefore
reads zero task records, whatever the history size.

Every other step before a Home prompt is accepted is needed for that prompt: the
attention barrier, live run settings, the archive gate (a cheap check for an
unarchived Home), the invocation start receipt, and the delivery headroom, which waits
for the memory view only when a result is selected and is cancelled by Stop.
`home.inbox.admission-slow` names a slow inbox admission.

- **Wake (#749).** A settled result wakes an idle Home. One owner decides every wake,
  `HomeOwner`'s wake scheduler, which runs one drain at a time and has no timers or
  polling. It is asked by exactly these events: a result settles while Home is eligible
  (enabled, memory configured, not paused or blocked); startup recovery succeeds; and a
  user activation or a delivered wake goes idle. A wake attempt that finds Home busy
  stops, and the activation holding Home asks again when it settles. A refused or failed
  wake asks for nothing more, so a wake cannot retry itself. A wake starts with no user
  text: the wake's trigger is the **last** result it selects. The inbox returns it
  without appending, and the run's `sendCustomMessage(…, { triggerTurn: true })` appends
  and starts it. Earlier results are appended first, and a pending-count line, when one
  is needed, precedes the trigger. The wake goes through the same admission as a user
  activation: the same memory prefix, the same request seam, chapter materialization and
  rollover, and the same idle-admission block, which keeps SDK auto-compaction disabled
  for Home (`CompactionOperationPolicy`) and applies the context window. The wake's
  `prompt()` steps that a trigger does not reach are proven irrelevant or handled in
  `src/sessions/runtime-slot.ts` (`assertHomeWakeAdmissible`): busy, compaction, model and
  credential checks.
- **Wake canonical record.** The invocation start receipt has source `homeWake`. The
  trigger's `message_end` persists two receipts before the reply: a `binding` receipt
  whose target is that `tron.home-task-result.v1` custom message (the only binding that
  is not a user message), and its attribution receipt. The wake's turn therefore begins
  with the delivered-context row of its result, then Home's reply. iOS already renders a
  `customMessage` row and an assistant row; no user row is ever written. Its text starts
  with one human-readable line containing the task title (the intent's first line, capped
  at 160 characters), outcome, subagent counts and elapsed milliseconds; it then presents
  the accepted report text and evidence items without serializing the canonical task or
  report record. Task/session identities, immutable report reference and terminal proof
  remain in `details`. A never-fit report includes its task paging handle in the
  reference text, because model payloads do not expose custom-message details.
- **Ceiling (#749).** At most eight consecutive wake activations run with no user message
  between them. The count is derived from the canonical result messages: distinct
  operations that delivered results after the last user message, across chapters, read
  newest first and continuing into an older chapter only while the newer ones hold no
  user message. A user activation's drained results precede its own user message, so they
  never count toward the ceiling (`home-wake.e2e.test.ts`). Nothing is stored, so the Home and task formats do not change. At the
  ceiling no wake runs, results wait for the maintainer, and a waiting notice is sent.
- **Rollback (#749).** `homeWake` is an additive invocation-receipt source, following
  `subagentWake`. A Gateway built before it skips a receipt whose source it does not know
  (the reader returns no receipt for it), so the session still opens. The rolled-back
  wake's rows become unattributed, not refused.
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
- **Push (#749).** Each settled result gets at most one push, decided durably before
  its one NotificationService enqueue. A result settled while Home is wake-eligible
  is decided by its wake. The wake's reply sends no inbox notice: its turn's own terminal
  push (the runtime's ordinary agent-finished notice, opening Home's chat) is the one push
  for the wake. The inbox records that decision as `push-wake-reply`. A wake that delivered
  only uncertain results, or was refused (`ceiling`, `nothing-deliverable`, `failed`), sends one
  waiting notice that Home is waiting. A paused, disabled or blocked Home keeps the
  task-finished notice of today, decided when the result settles or when its wake is
  refused. A result a user activation drains is decided without a notice, since the user
  is in Home. The store refuses a push decision after acknowledgement, so the operation's
  push is decided before its results are acknowledged. A crash between the durable
  decision and the enqueue may omit a push; the inbox is the guaranteed delivery, and
  recovery never re-decides a decided event.
- **Stop.** An activation that Stop or abort ended never requests a wake, whether it was a
  user activation or a wake: a stopped run never reaches the idle notice that asks for one
  (`HomeOwner.noteHomeIdle`; the `home-wake.e2e` Stop cases). Results still pending after a
  stopped activation wait for the next user message or the next settled result.
- **Operating context.** Home is told the settled-result wake, the one-push rule and the
  paused/disabled/blocked fallback (`tron-home-extension.ts`). It reads its learned profile
  and system prompt once per activation at the request seam, so a wake carries the same
  bytes as a user activation (#749).
`home.task.inbox` reports only a hashed event ID, state and coded reason;
[observability.md](observability.md) owns its
vocabulary.

## RPCs

`home.v1` is advertised in `hello` and `system.info` when the Gateway has a Home
owner. `home-memory-view.v1`
additionally gates the memory-browser reads below, and `home-chapter-list.v1`
gates `home.chapterList`; `home.v1` alone promises neither. Parameter objects are
strict: unknown fields are `invalid_request`. **Receipted** mutations carry a
`commandId` and use the bounded receipt
described in [Logical route and receipts](#logical-route-and-receipts).

| method | parameters | kind | contract |
| --- | --- | --- | --- |
| `home.status` | none | read | The `HomeStatus` shape below. |
| `home.context` | none | read | Bounded request context of the current or last activation, with its `breakdown` by section ([Request breakdown](#request-breakdown)). Never a message body. |
| `home.open` | none | read | Logical route and binding. Creates no runtime and materializes no successor. |
| `home.chapterList` | none | read | The whole chapter ledger in ledger order, each chapter with state, `createdAt`, `sealedAt?`, `activationStarted`, `sessionPresent` and metrics, plus the shared soft and hard rollover limits (`home-chapter-list.v1`, #740). Each chapter also carries `contents` ([Chapter contents](#chapter-contents)). Sealed chapters answer exactly their recorded seal metrics (a disable-sealed chapter has none); only the active chapter is measured live, and only while its session is present, so absent sizes mean unmeasured, never zero. Undesignated refuses `not_found`; an unavailable record refuses `conflict`, never a partial list. A disabled Home still lists its chapters. |
| `home.prompt` | `commandId`, `text`, `uploadIds` (at most 10, into the resolved chapter), `behavior` (`steer` or `followUp` while a turn runs), `resourceInvocation` | receipted | The composer's whole prompt contract, admitted by the same code as `session.prompt`. Returns the physical session and operation. |
| `home.designate` | `commandId`, `model?` | receipted | With no record: creates the working directory and its trust decision, a **new** session whose first runtime has the Home profile, applies the model, writes the record, and returns `{ homeId, sessionId, generation }`. An enabled record whose session still exists is idempotent when the model is absent or matches; a different model refuses with a conflict directing to `settings.change`. A disabled record re-enables the same session at `generation + 1`, preserving any `reserved` or `materializing` successor for the next `home.prompt`. A record whose session is **gone** is given a fresh session at `generation + 1`, enabled or not: the record is the only evidence of the designation, and the dangling ID is never re-enabled. |
| `home.disable` | `commandId` | receipted | `enabled: false` at `generation + 1`. The session stays ordinary. A record whose session is gone is only marked disabled. |
| `home.pauseMemory` | `commandId` | receipted | Requires an enabled, configured Home. Durably pauses; idempotent. Returns the memory projection. |
| `home.resumeMemory` | `commandId` | receipted | Clears pause and or block, re-reads canonical deltas and restarts the pump without awaiting catch-up. A memory that is neither paused nor blocked refuses with conflict. An empty Home resumes without creating a store. |
| `home.reconfirmPermissions` | `commandId` | receipted | Re-stamps active standing scopes to the current epoch. See [Authorization](#authorization). |
| `home.taskList` | `limit?` (1–50, default 20), `cursor?` (at most 1,024 characters) | read | Maintainer summary: each row with its `title`, `project` and `sessionId`, and the result's exact `counts` (`active`, `finished`) over the whole store; see [Control and spend status](#control-and-spend-status). |
| `home.taskStatus` | `taskId` (at most 160 characters) | read | Record (its `sessionId` is the worker session), `title`, `project`, active operation, spend, immutable result, worker model, subagent counts, live subagent runs and nullable canonical owner-settlement proof. |
| `home.taskPermissions` | none | read | Strict scopes, requests, decisions and grants with the revision. Refuses before the first dispatch, never granting permission. |
| `home.steerTask` | `commandId`, `taskId`, `operationId`, `text` (at most 64 KiB) | receipted | Steers the exact active operation. It cannot start a successor. |
| `home.stopTask` | `commandId`, `taskId`, `operationId` | receipted | Persists the exact Stop intent and joins terminal settlement. Repeatable after settlement without repeating cancellation. |
| `home.redeliverTaskResult` | `commandId`, `taskId`, `homeId`, `routeGeneration` (positive) | receipted | Re-stamps one unadmitted wake event; see [Task wake inbox](#task-wake-inbox-and-terminal-push). |
| `home.revokeTaskScope` | `commandId`, `scopeId` | receipted | Revokes the standing scope. Repeated or missing references are no-ops. A revoked initial scope is never recreated by dispatch. |
| `home.revokeTaskGrant` | `commandId`, `grantId` | receipted | Revokes an available grant. Consumed, revoked or missing grants are no-ops and never resurrected. |
| `home.decideTaskGrant` | `commandId`, `requestId`, `approved` (boolean), `expiresAt` (future Unix milliseconds) | receipted | Decides the exact pending request; the command ID is the decision ID. Returns `{ decision, grant }`, with `grant: null` for deny. |
| `home.memory.view` | `limit?` (1–50, default 30), `cursor?`, `sessionId?`, or `part?` (aligned power-of-two range) | disposable read | [Typed memory browser](#typed-memory-browser). |
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

`home.memory.view` and `home.memory.evidence` are disposable authenticated reads,
not receipted mutations. Their types live in
`src/protocol/types.ts`, and parameter admission and bounds live in
`src/home/home-memory-browser.ts`. They read the configured
memory, including a disabled or paused Home. They may open its store and refresh the
catalog through the episodic ingestion owner,
but they **never admit compactor calls, resume a block, send a prompt or materialize
a chapter**. Already-running compactor work may
finish. Unconfigured memory refuses with `conflict`; no provable canonical cut
refuses with retryable `busy`.

- **`home.memory.view`** returns `{ homeId, revision, totalMessages, lines, nextCursor? }`:
  the lines of Home's current memory view (the parts `renderView` renders), **newest first**,
  at most `limit` lines and **128 KiB of encoded JSON**. An older range is one summary line
  covering `span` messages; a recent message is its own line. Each line is
  `{ start, span, text, truncated, kind?, firstAt?, lastAt?, item? }`: `text` is the node's
  text with each `user:`/`talk:`/`echo:`/`event:` kind prefix stripped and newlines joined,
  at most 4,096 UTF-16 characters (`truncated` when cut), and `null` while the node is
  unbuilt. `firstAt` and `lastAt` are the canonical timestamps of the range's first and last
  message. A message line (`span: 1`) carries its `kind` and `item`. `totalMessages` counts
  the catalog, or the chapter's messages when filtered.
  - `item` has `index`, `kind`, `attribution` (`user`, `assistant`, `tool`, `event`),
    canonical `timestamp` when known, `evidence`, `projection` and `summary`.
    `projection` is `{ format: "memory-projection", text, omitted, omissions }`: capped and
    redacted catalog text, **never exact evidence**, at most 4,096 UTF-16 characters without
    splitting a surrogate pair (`browser-cap` when it clips; `context-edit` for context
    replacements; an omitted slot stays visible rather than renumbering). `summary` is
    `{ format: "memory-summary", text, truncated }` under the same bound, or `null` when
    unbuilt. `evidence` is `{ index, sessionId, entryId, sourceDigest }`: the physical
    chapter, the canonical entry identity and the SHA-256 of its original JSONL line,
    identity strings bounded to 200 UTF-8 bytes; references must match the current catalog.
  - **Continuations** are canonical base64url `{ revision, offset, limit, sessionId? }` (at
    most 1,024 characters). Repeat the same `limit` and filter. The content-derived revision
    covers the Home identity, generation, committed catalog and node revision, and
    per-chapter source cuts; any append, invalidation, summary settlement or changed cut
    returns a retryable `conflict` with `home-memory-revision-changed`, and the client
    reloads the first page. Offsets beyond the lines refuse rather than clamp.
  - **`sessionId`** filters to one chapter: a line crossing the chapter's boundary is split
    into its halves recursively until each piece is inside or outside, so no line covers
    another chapter's messages. A session that is not a chapter of this Home refuses with
    `not_found`.
  - **`part: { start, span }`** (aligned start, power-of-two span ≥ 2, within the catalog)
    returns the two lines that range covers, in ascending order, so a client opens a
    summary down to single messages. `part` and `cursor` cannot be combined.
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
| `/home memory <provider/id>` | `settings.change` (`model.ref[role=memory]`), then `home.status` | Configures memory, then prints the memory projection. Exactly one model argument. |
| `/home resume` | `home.resumeMemory` | Resumes paused or blocked memory, then prints the memory projection it returns. |
| `/home context` | `home.context` | The activation's start, whether it is open, the request sizes and its refusal. |
| `/home reconfirm-permissions` | `home.reconfirmPermissions` | Reconfirms standing scopes for the current restore epoch; revoked scopes and grants are not renewed. |
| `/home permissions` | `home.taskPermissions` | Prints the strict durable scopes, requests, decisions and grants as JSON. |
| `/home revoke-scope <id>` | `home.revokeTaskScope` | Revokes a standing scope. Already-admitted work is unchanged. |
| `/home revoke-grant <id>` | `home.revokeTaskGrant` | Revokes an available grant. Already-admitted work is unchanged. |
| `/home approve-grant <request-id> <expiry-ms>` | `home.decideTaskGrant` | Approves a pending request with a one-use grant that expires at the given Unix-millisecond time. |
| `/home deny-grant <request-id> <expiry-ms>` | `home.decideTaskGrant` | Denies a pending request. Records the decision without a grant. |
| `/home task <id>` | `home.taskStatus` | Lifecycle, result outcome, and input and output tokens. |
| `/home steer <id> <text>` | `home.taskStatus`, then `home.steerTask` | Steers an active task with the exact operation read from status. |
| `/home stop <id>` | `home.taskStatus`, then `home.stopTask` | Stops an active task with the exact operation read from status. |
| `/home redeliver <id>` | `home.status`, then `home.redeliverTaskResult` | Re-stamps an unadmitted task result to the current Home route. |

## Evidence

Each row names a test file, the failure modes it proves, its artifact (a retained
path or the variable that sets one), and the regeneration command. Run from
`packages/gateway` under the pinned Node runtime. Rows marked "none" prove behavior
without a retained artifact.

| test file | failure modes proven | artifact | regenerate |
| --- | --- | --- | --- |
| `src/sessions/home-activation.e2e.test.ts` | chapter admission and rollover; receipt replay; joined submissions; signal privacy; real SDK byte stop; cyclic cold evidence; memory browser contract; reserved and cold profile orderings; pause receipts; inline-photo mirror; terminal child cases | `test-results/home-activation/report.json`; `test-results/terminal-chat-home/attachments-{rollover,failed-sync,handled-input}.json` (`-t 'owns exact Home attachments'`) | `npx vitest run src/sessions/home-activation.e2e.test.ts` |
| `src/sessions/home-request-seam.integration.test.ts` | seam identity, path and byte refusal; an overflow refusal is one refusal with no SDK retry and a fixed chat sentence (C12); five rebuilds and five reloads per manager | `test-results/home-activation/seam-report.json` | `npx vitest run src/sessions/home-request-seam.integration.test.ts` |
| `src/sessions/home-cache-layout.e2e.test.ts` | cache layout across the frozen view; post-terminal quiescence; refused-activation readiness | `test-results/home-cache-layout/report.json` | `npx vitest run src/sessions/home-cache-layout.e2e.test.ts` |
| `src/sessions/home-managed-provider.integration.test.ts` | Home delegate-only versus ordinary managed-provider sessions through reload, replacement and cold acquisition | `test-results/home-managed-provider.integration.json` (or `TRON_HOME_MANAGED_REPORT`) | `npx vitest run src/sessions/home-managed-provider.integration.test.ts` |
| `src/sessions/home-provider-runtime.e2e.test.ts` | shared eligibility and filter identity across three rebuilds and disposal; ordinary eligibility retirement | `test-results/home-provider-runtime/report.json` | `npx vitest run src/sessions/home-provider-runtime.e2e.test.ts` |
| `src/sessions/home-memory-tools.e2e.test.ts` | the three memory tools, end to end | `test-results/home-memory-tools/report.json` | `npx vitest run src/sessions/home-memory-tools.e2e.test.ts` |
| `src/sessions/home-research-tools.integration.test.ts` | the five research tools inside real activations with zero seam refusals; result caps; SSRF and trust-escape refusals; Knowledge writes structurally unreachable; ordinary sessions unaffected | `test-results/home-research-tools/report.json` | `npx vitest run src/sessions/home-research-tools.integration.test.ts` |
| `src/sessions/home-profile.integration.test.ts` | learn through a real activation with its evidence and unconfirmed state; verbatim injection with a byte-stable prompt; refine, supersede and retire lifecycles; refusals of retired and superseded items; a native confirmation and correction keep the item; the over-bound refusal; a worker receives the brief; Home chapters unobserved; ordinary sessions without the profile tool | `test-results/home-profile/report.json` | `npx vitest run src/sessions/home-profile.integration.test.ts` |
| `src/sessions/runtime-tool-loadout.integration.test.ts` | disable keeps the loadout; a Chat-layer `tools.active` change restores the active set | none | `npx vitest run src/sessions/runtime-tool-loadout.integration.test.ts` |
| `src/transport/rpc-idle-admission.integration.test.ts` | ordinary-session Stop continuation is unaffected by task Stop | none | `npx vitest run src/transport/rpc-idle-admission.integration.test.ts` |
| `src/episodic/home-source.e2e.test.ts` | cross-chapter replay, restart, navigation and frozen-cut proof | `test-results/home-memory/continuity.json` | `npx vitest run src/episodic/home-source.e2e.test.ts` |
| `src/home/home-task-worker-model.e2e.test.ts` | `delegate`'s model and thinking choice: the worker's provider request runs on explicit/profile/Home values; profile model and thinking resolve independently, unsupported thinking is clamped, provenance is captured in the brief and worker Chat, direct Home dispatch inherits the live Home choice, Home’s context names its identity, unknown tasks return not_found, and ordinary chats retain their own defaults; unavailable profile models fall through; invalid explicit choices are refused before any task or session; status reports the worker model while running and after a restart | none | `npx vitest run src/home/home-task-worker-model.e2e.test.ts` |
| `src/home/home-task-dispatch.e2e.test.ts` | the real `delegate` tool; report addresses and digests; duplicate and conflict refusals; length and no-report outcomes; live and cold settlement; sync failure; stopped-before-conversation; report and steer race; RPC authorization; attributed wake delivery; four deadline adversaries plus a deterministically held empty-PID publication interval (positive identity before cancellation, unchanged reaping and no-further-effects assertions); frozen-owner cuts at commit, grant consumption, worker creation, binding, report append and terminal commit | `HOME_TASK_REPORT=<artifact-path>` | `HOME_TASK_REPORT=<artifact-path> npx vitest run src/home/home-task-dispatch.e2e.test.ts` |
| `src/sessions/managed-workflow-children.integration.test.ts` | ordinary session: a workflow completes while its runner-backed child runs; the session stays active until the child ends | none | `npx vitest run --config vitest.nested.config.ts src/sessions/managed-workflow-children.integration.test.ts` |
| `src/home/home-task-subagents.e2e.test.ts` | real managed-provider children: foreground and async launches joined before a report; a run's late completion notice recorded before the settlement fact, with nothing appended after it, and a notice the bound never records counted without changing the outcome; a report refused while an async run or a completed workflow's child is live, the task staying active, then accepted once it ends; a worker's own stop, then an accepted report; live runs listed in task status, then none; Stop and the 24-hour deadline stop an async run; task Stop leaves the exact provider mission cancelled (sanitized artifact `test-results/stopped-subagent-mission.json`); a refused stop is `unknown` with `detached-work-outlived-task` at the one-minute stop-join bound, before the deadline; foreground abort through the tool signal; kept refusals; cold restart with a live run or a live child of a completed workflow; async workflows and a child that outlives its completed workflow stopped by run id when the worker ends without a report, and on Stop; no turn after settlement | none | `npx vitest run --config vitest.nested.config.ts src/home/home-task-subagents.e2e.test.ts` |
| `src/home/home-wake-inbox.integration.test.ts` | frozen-owner cuts for claim, admission, terminal and acknowledgement; route replacement; redelivery | `HOME_WAKE_REPORT=<artifact-path>` | `HOME_WAKE_REPORT=<artifact-path> npx vitest run src/home/home-wake-inbox.integration.test.ts` |
| `src/home/home-wake.e2e.test.ts` | a settled result wakes an idle Home with no user message; coalescing during a user turn; paused and disabled Home stay asleep with the task-finished notice; the ninth wake is refused and says Home is waiting; a restart wakes exactly once; a user prompt racing a wake keeps one delivery; the wake turn projects as its result then the reply, with compaction disabled | none (faux provider; reports under the fixture) | `npx vitest run src/home/home-wake.e2e.test.ts` |
| `src/home/home-system-prompt.e2e.test.ts` | every request of an activation carries one identical Home system prompt, framed at the request seam | none | `npx vitest run src/home/home-system-prompt.e2e.test.ts` |
| `src/home/home-materialization-crash.e2e.test.ts` | frozen-owner cuts at claim, path record, first flush and post-rename or pre-directory-fsync; visible-publication fence; `publication-uncertain` retirement; disabled-profile reconstruction | `HOME_MATERIALIZATION_CRASH_REPORT=<artifact-path>` | `HOME_MATERIALIZATION_CRASH_REPORT=<artifact-path> npx vitest run src/home/home-materialization-crash.e2e.test.ts` |
| `src/home/home-ledger-crash.e2e.test.ts` | seal and reserve with a real child process killed by SIGKILL | `test-results/home-ledger-crash/report.json` | `npx vitest run src/home/home-ledger-crash.e2e.test.ts` |
| `src/home/home-receipt-crash.e2e.test.ts` | SIGKILL after binding, during SDK effects before completion, and after completion before response: pending fences and exact replay | `test-results/home-receipt-crash/report.json` | `npx vitest run src/home/home-receipt-crash.e2e.test.ts` |
| `src/sessions/runtime-registry.integration.test.ts` (`-t deadline`) | 24-hour owned-operation deadline: endless no-effect and successful-read turns; a blocked provider request; joined stop | `test-results/owned-session-deadline/report.json` | `npx vitest run src/sessions/runtime-registry.integration.test.ts -t deadline` |

Two limits apply:

- **No power-loss proof.** Frozen-owner, SIGKILL and receipt cuts prove
  process-abandonment recovery at the persistence boundary. They are not physical
  power-loss tests or live-provider Gateway process tests.
- **Injected thresholds.** Threshold diagnostics inject measurements at the owning
  metrics seam and are not large-file proofs. The canonical-admission and
  input-crossing cases in `home-activation.e2e.test.ts` append real SDK entries and
  lower only the shared hard constants in the test module (64 KiB and 100 entries).
  Their artifact records the measured bytes and entries and the thresholds used.
