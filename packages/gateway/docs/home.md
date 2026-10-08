# Tron Home

Tron Home is an opt-in persistent conversation, one per Gateway installation:
`~/.tron` and `~/.tron-dev` each own their own Home. This document owns what
Home does today: its designation record, its curated runtime, its memory, and the
request seam that sends each activation the memory's view instead of the
canonical transcript. Tasks, the wake inbox and Home's own client surface are
later slices. Ordinary sessions are unaffected by every rule here.

## Physical chapter mutation boundary

RuntimeSlot owns physical-session mutations. Its serialized owners consult a
chapter-state provider before prompt admission, configuration, rename/label
edits, branch changes, bash, and extension-driven session replacement. Registry
owners also preflight attention, archive and delete mutations against that same
provider. A sealed result is a
typed `conflict` (`details.reason: "sealed-chapter"`) and is never redirected.
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
complete-file scan runs before a cold Home runtime is opened and before a Home
chapter is used as a fork source. It scans the exact canonical file's owning
directory, not a directory re-encoded from cwd: workspace aliases must not change
evidence ownership, including cold search. The version-3 scanner validates the
header, supported entry/message content and usage shapes, unique IDs, and one
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
| `chapters` | Ordered, unique physical sessions; designation starts with one `active` chapter, then quiescent rollover appends one `reserved` successor |
| `bindingRevision` | Advances when designation or reserved-chapter activation binds Home to a different physical session |
| `generation` | Advances on every profile change (designate, re-enable, disable) |
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
which applies only to that session and only while the record does not name it —
so a fork or a reset, which produce a new session id, is never Home.

| | Home | Ordinary |
| --- | --- | --- |
| Extensions | `tron-context-window`, `tron-compaction-policy`, `tron-ask-user`, `tron-display`, `tron-notify`, `tron-home` | every Tron module plus Pi built-ins (codemode, tool-search, MCP) |
| Discovery | `noExtensions`, `noSkills`, `noPromptTemplates`, `noContextFiles` | agent directory and trusted project resources |
| System prompt | the agent directory's `SYSTEM.md` and `APPEND_SYSTEM.md` are dropped through `systemPromptOverride`/`appendSystemPromptOverride` | loaded |
| Executable tool allowlist | `ask_user`, `display`, `notify`, `zoom`, `date`, `memory_search` | the SDK defaults plus Tron's direct bash tool |
| Compaction | disabled per session | canonical policy |
| Model | fixed physical model | any, including virtual routing |
| Model runtime | a session-local view of the Gateway-wide user-scope runtime | one per session runtime |
| Cache warming | zero requests | unchanged |

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
  enabled, homeId?, sessionId?, generation?, model?, live, sessionPresent,
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
needs no rebuild: the next runtime creation reads the record, including its model.
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

An accepted operation can settle before its response. A new authoritative idle
snapshot settles it immediately, whether it arrives on the same chapter,
reconnect or successor transfer. The idle cut preceding prompt submission is
not proof of that operation's settlement. Reconnect reconciles the receipt and
snapshot without replaying accepted input. New assistant text in that authoritative
snapshot is rendered even while the command response is pending; consuming it
silently would lose a settled refusal before its operation ID arrives.

The real terminal child cases in `home-activation.e2e.test.ts` retain
`test-results/terminal-chat-home/attachments-rollover.json` and
`attachments-failed-sync.json` (run that file with `-t 'owns exact Home attachments'`).
They cover response loss after acceptance, same-chapter settlement, a still-running
operation whose response precedes presentation events, repeated idle-baseline
rollover, actual outgoing-runtime eviction, exact-token retirement, and failed
candidate sync. The fixture injects soft-limit metrics to request rollover and
holds selected presentation broadcasts to isolate snapshot/response orderings;
it is not a large-chapter or Gateway-process-crash proof.

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

## Fork and disable both keep the transcript's tool loadout

Designation is keyed by session id, so forking the Home session yields an
ordinary session: it registers the ordinary extensions and tools, uses the
canonical compaction budget, and is not cache-warming excluded.

A profile change does not rewrite the chat's tool loadout, because Pi replays
the *declared* loadout from the canonical transcript at every runtime creation.
So both a fork of Home and a disabled Home start with the Home tools this
profile can activate — `ask_user`, `display`, `notify` — while the ordinary
tools are merely registered, exactly as every other session keeps the loadout
its chat declared (`runtime-tool-loadout.integration.test.ts`). The three memory
tools belong to the Home-only module, so an ordinary profile neither registers
nor activates them: a fork of Home can never read Home's memory, and its memory
tool accessor answers `undefined` for that session id. The user restores the
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

Only a runtime whose profile is Home's gets them. A fork of the Home session is a
different session id, hence an ordinary session with no seam and no activation.

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

Home has no task coordination, no wake inbox, no iOS surface of its own, and no
scheduled or background work. It is one conversation whose turns run on its
memory. Those are separately approved slices of the same epic, and none of them
changes the rules above without updating this document.
