# Tron Gateway

Tron Gateway is the minimal always-running Mac service behind the Tron iPhone
app. It embeds `@earendil-works/pi-coding-agent` 0.84.1 through supported SDK
exports. User-facing copy calls the product and agent **Tron**; source may use
Pi-specific names only where it identifies the backing SDK contract.

## Ownership

Gateway owns only mobile infrastructure:

- one-time enrollment, hashed device credentials, revocation, and rate limits;
- authenticated HTTP uploads/blobs and JSON WebSocket requests/events;
- one serialized mutation lane and one live runtime per canonical session;
- detached run supervision, bounded idempotency receipts, and crash markers;
- authoritative transcript snapshots projected from canonical JSONL;
- filesystem/Git browsing, bounded uploads, and bounded PTY replay;
- settings, credentials, packages, trust, custom-model administration, and
  generic extension UI forwarding.

The embedded runtime remains canonical for sessions, provider/model semantics,
credentials, settings, packages, resources, compaction, and retries. Gateway
does not maintain a session database or event journal. A process lock is held per
agent directory and any configured external session directory because the session
format has no cross-process lock; another Gateway must use separate canonical
storage, not the same JSONL tree. Runtime `sessionDir` changes are rejected until
the Gateway is stopped and restarted; the runtime also snapshots the admitted
session directory at startup so an out-of-band settings edit cannot redirect
new work around the ownership lock.

## Moonshot Kimi K3

The built-in Moonshot K3 model uses the Open Platform OpenAI-compatible endpoint
and preserves K3 reasoning/tool message fields. Gateway caps the requested
completion reservation at 32,768 tokens and sends the documented
`max_completion_tokens` field; this is separate from K3's 1M-token context
window because Moonshot TPM accounting includes the requested completion budget.
Terminal Moonshot account/org quota responses are normalized as non-retryable;
max-concurrency responses with explicit provider guidance receive one bounded
retry, while transient engine overload responses remain retryable. This prevents
the same over-budget request from consuming the account's RPM through repeated
retries. The provider key still belongs in the runtime credential store and is
never persisted by Gateway.

## Runtime and state

- Agent state: `PI_CODING_AGENT_DIR`, default `~/.pi/agent`; the isolated Xcode
  Dev LaunchAgent sets `TRON_AGENT_DIR_NAME=agent-dev`, so Dev sessions live in
  `~/.pi/agent-dev` and never share production JSONL with `~/.pi/agent`
- Physical-machine group identity: a bounded random ID in
  `~/.tron-machine-group-id`, shared by separate Tron homes only for connection
  grouping; it is not a session, credential, or runtime-data store
- Gateway state: `<TRON_DATA_DIR|~/$TRON_HOME_NAME|~/.tron>/gateway/`; `gateway.json` is an exact-shape, 16 KiB maximum document with a 256-byte machine ID, 1 KiB machine name, and optional 8 KiB default workspace; malformed/oversized existing files fail startup without rekeying
- Local wrapper credential: `gateway/local-auth.json` (`0600`)
- Hashed mobile devices: `gateway/devices.json`
- Current invitation: `gateway/enrollment.json` (`0600`, ten minutes, one use)
- Run markers and command receipts: gateway-owned bounded operational state
- Uploads: transient and bounded; unclaimed staging expires, while prompt attachments remain session-owned until canonical deletion

Legacy `~/.tron/auth.json` is not gateway auth and is never overwritten. It is
read only by the explicit legacy importer. That importer rejects duplicate or
oversized identities and bounded page/history/payload overflow, detects stalled
cursors, and persists each completed legacy-to-canonical mapping before moving
to the next session so a retry safely skips partial success. Known append or
index-write failures remove the new canonical file; cleanup failure is surfaced
with the original failure, while process termination in the narrow interval
before the index rename remains outside that cleanup.

## Transport

- `GET /health` — unauthenticated readiness and compatibility metadata
- `POST /v1/pair` — rate-limited one-time enrollment exchange
- `POST /v1/uploads` — authenticated bounded upload
- `GET /v1/blobs/:id` — authenticated transient projected blob
- `GET /v1/socket` — authenticated protocol version 2 WebSocket

The pairing limiter keeps the exact rolling per-address window while retaining at most 4,096
least-recently-used address keys and periodically deleting expired windows; address churn cannot
create append-only process state. Paired-device storage admits at most 256 unique device IDs and
token hashes with bounded names/timestamps; capacity rejection leaves the one-time invitation valid
so an old device can be revoked before retrying. Device metadata is capped at 1 MiB, the local wrapper
credential at 4 KiB, and the one-time invitation at 16 KiB before JSON decode. Local credentials and
invitations also require exact versions, purposes, bounded identities/codes, and canonical timestamps. Uploads retain the 25 MiB per-request limit and additionally
serialize reservation and commit against a 1,024-entry and eight-times-per-upload (200 MiB by default) aggregate ceiling. The aggregate byte bound remains the primary storage limit so many small photos do not exhaust capacity prematurely.
A separate admission permits at most half that ratio concurrently (four default 25 MiB bodies). Authenticated request
chunks stream directly into protected store-owned files; exact declared and observed sizes are checked before atomic
metadata publication. Persisted upload metadata is limited to an exact 64 KiB document with canonical timestamps and fields; malformed or oversized entries self-clean before quota admission or direct materialization. Every success, rejection, overflow, truncation, or disconnect removes uncommitted staging
and releases its slot. Unclaimed uploads
expire after 24 hours, malformed/partial folders self-clean, prompt attachment IDs are unique, and
one prompt cannot materialize more than the per-request byte ceiling. Successful imports remove
their staging folder; deleting a canonical session removes its claimed attachment folders. Cleanup
failure is best effort after canonical import/deletion success and cannot turn that success into an
ambiguous command receipt; failed session-folder cleanup remains pending in the live store and retries
on later inventory work. Transient image/export blobs reject individual values above 25 MiB or MIME metadata above 1 KiB
and retain at most 128 items/200 MiB; exact content deduplicates and access refreshes 30-minute idle
expiry. Generated exports move into protected transient storage and stream to authenticated readers with backpressure,
without retained export `Buffer` values. HTML renders the active branch; JSONL audit export copies the bounded canonical
append-only session file verbatim so abandoned branches and parent identities remain present. Default admission allows at most 32 concurrent blob readers and four simultaneous
export generations, derived from the existing item/aggregate limits; canonical session files above the item ceiling fail
before SDK export work begins. Active downloads survive pruning; expired IDs admit no new readers, and physical capacity
releases after the final reader. Startup scavenges transient files only after the Gateway binds successfully.
Capacity admission never evicts an ID already published to a client: excess projected images become bounded omission
text, while later requests can retry after expiry. Blob storage rejects control-bearing MIME metadata. Downloads remain
full-body responses without Range support.
The retired `/engine` protocol is not exposed.

Every WebSocket starts with:

```json
{"type":"hello","protocolVersion":3}
```

The hello and pairing response identify the runtime with `machineId` (stable per
Tron home) and, on current gateways, `machineGroupID` (stable across separate
production and isolated-Dev homes on one physical Mac). Older gateways omit the
latter; clients fall back to `machineId`. The group identifier is only a bounded
connection-group hint and never names or shares session files, credentials, or
other canonical runtime data.

Requests use `{type,id,method,params}` and receive `{type,id,ok,result|error}`.
Mutations require `params.commandId`; receipts deduplicate completed commands.
After an uncertain disconnect, clients reconnect and poll `command.status`, reuse
a completed result, retry only a confirmed-missing command with the same ID, and
never blindly replay a pending command. An observed application rejection removes
its pending receipt so the definitive error remains definitive; process loss or failure
to persist a successful completion leaves pending state and therefore cannot enable a
blind duplicate. Each receipt is capped at one response frame plus 4 KiB of
identity/envelope overhead before decode and persistence. The store admits at most
32,768 direct entries and 64 MiB of aggregate evidence, reserving one maximum
completion before a mutation executes; full capacity returns retryable `busy`.
Admission keeps an in-process usage total and periodically reconciles it from
disk, so sustained revisioned activity is not quadratic in the receipt count;
owned interrupted atomic-write temporaries are scavenged but arbitrary files are
not treated as receipt evidence.
Only expired, valid completed receipts are reclaimed; revisioned editor updates use
a ten-minute receipt window because newer revisions supersede them. Pending,
malformed, oversized, or identity-mismatched evidence remains outcome-unknown, is
never pruned, and can never authorize replay. Receipt execution serializes identical command keys only;
unrelated commands and sessions remain concurrent.
The gateway sends WebSocket ping control frames every 25 seconds and terminates
connections that fail the next heartbeat, so half-open Tailscale/iOS paths are
observable. Reconnect and foreground activation converge through an authoritative
snapshot. `session.summary` is a bounded, per-session revisioned global projection
of phase, name, activity time, message count, and first-message title. It updates every connected
dashboard immediately without broadcasting full transcripts; clients subscribe
to `session.snapshot`, progress, tool, queue, and extension events only for chats
they actually open. Streaming progress republishes the cumulative live message, so
updates are coalesced to one frame per short window (the first update stays
immediate) and each frame is bounded to a marked live tail; intermediate frames
are presentation-identical and the settled canonical message always pages through
transcript projection. Active operations also emit a bounded sequenced heartbeat, so
a long tool with no output remains distinguishable from a broken mobile stream.
The embedded runtime's active-run flag outranks an older settlement callback when
an extension completion immediately triggers a continuation, so phase, operation,
and Stop controls cannot become idle while a newer turn is executing. Extension
commands are resolved before ordinary streaming rejection and still execute through
Pi's prompt path. The explicit extension adapter registry identifies the installed
`@pi9/ask` package only by package source metadata and its public parameter shape.
Its original execute function, result formatting/events, timeout signal, and replay
behavior remain authoritative; a scoped UI proxy admits one additive questionnaire
v1 descriptor on a primitive select/input interaction. Capable clients submit
bounded structured selections, comments, and freeform text through the existing
response mutation (single-select allows 64 options without freeform or 63 with the
legacy Type-a-response choice; multi-select/input allows 64; 2 KiB labels/descriptions;
32 KiB previews/context; 192 KiB interaction/response envelope), while older clients continue the original
sequential primitive RPC fallback. Arbitrary custom/overlay TUI is not inferred or
remotely executed.
A per-bind host epoch and monotonic presentation revision scope
all retained semantic state and actionable responses; reload/replacement retires
captured callbacks instead of letting them mutate the replacement host. The lifecycle coordinator counts prompt preflights, command handlers, interactions,
foreground agent/retry/compaction/bash/queue work, and deferred session-scoped
shutdown as operational work. Decorative retained presentation protects automatic
eviction only; it cannot deadlock trust revocation or explicit deletion. Administrative
drain establishes a cutoff, repeatedly clears newly added queues, and aborts
extension continuations that begin after that cutoff. `ctx.shutdown()` waits for Pi's
`session_shutdown` before reporting closure and closes only the owning runtime slot.

`ExtensionPresentationStore` is the sole owner of an extension host epoch and its
aggregate presentation revision. It atomically retains semantic state, actionable
interactions, generic surfaces, the projected input lease, capabilities, and bounded
diagnostics. Producer state is bounded before retention or broadcast: 32 statuses,
24 string widgets, eight pending interactions, 64 select options, 192 KiB
interaction/editor budgets, at most 64 surfaces, 160 columns by 120 lines, 4,096
runs and 256 KiB per full frame, and a 700 KiB aggregate presentation ceiling. The
lower aggregate ceiling leaves room inside the 1 MiB WebSocket frame for lifecycle
identity and a bounded canonical transcript tail.

Every committed change emits exactly one `session.extensionPresentation` v2 envelope
with the current host epoch and exact next aggregate revision. Semantic patches,
authoritative interaction lists, full-frame surface upserts, explicit removals,
lease replacement/clear, capabilities, diagnostics, and transient notifications
share this stream. Malformed upserts never mean removal. Responses retain the
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
a nonzero revision.
Pending interactions remain live across ordinary client disconnect and all imperative
presentation is excluded from offline mobile cache. Native editor updates admit an
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
non-overlay blocking custom call and uses a real public pi-tui 0.84.1 keybindings
manager; the production RPC host rejects blocking custom calls before invoking
extension factories because no native client surface exists for them. Overlay
custom calls fail closed before factory invocation with one bounded
deferred diagnostic and publish no overlay surface. Component input, arbitrary custom
UI, native custom/overlay rendering, footer/header/editor/autocomplete, theme UI,
renderer hosting, package-specific integration, and truthful TUI activation remain
deferred.

Live tool projections may carry an optional extension provenance record derived from the public Pi tool `sourceInfo` and the loaded extension inventory. The Gateway emits that record only when exactly one extension owns the tool and the source path agrees; unknown or ambiguous ownership omits provenance and fails open to the ordinary tool projection. This metadata is disposable presentation state and never modifies Pi JSONL. When an extension-owned tool returns the public structured delegated-run convention (`details.runId`/`asyncId` plus bounded `results[].progress`), the Gateway additionally projects `ExtensionRunActivity` with stable child identities, active time, tool/turn counts, current tool/path, and a bounded output tail. It is carried on the live tool projection and retained as a bounded recent `extensionActivities` snapshot; native clients must not infer it from rendered widget text or open a child JSONL concurrently. The runtime also admits the explicit `pi-subagents` lifecycle-artifact contract: allowlisted `status.json` files are matched to the canonical session file, read with a hard byte bound, and projected as one workflow activity with bounded child progress so detached async runs remain visible after the launching tool returns. Temporary runtime roots and the project-local `.pi/subagents/async-subagent-runs` layout are scanned. A bounded Gateway-owned `runId` binding maps lifecycle events and artifacts to one real tool-call identity; a synthetic `subagent:<runId>` identity is used only for an initially unmatched, session-owned artifact and is re-keyed when the real tool call arrives. Terminal lifecycle status is authoritative, while later artifacts only enrich retained details and cannot resurrect a completed run. Watchers stop on terminal state, disposal, and retention eviction.

Remote restart is advertised only when `TRON_GATEWAY_SUPERVISED=1` is present from a managed LaunchAgent or repository background supervisor; direct foreground processes fail closed for remote restart. The Gateway exits with code 75 only after the registry drain completes, leaving process replacement to the owning supervisor.

Extension callbacks are wrapped through the public `DefaultResourceLoaderOptions.extensionsOverride` seam on every load and reload. An AsyncLocalStorage owner (an opaque SHA-256 identity derived from stable source/path provenance, a generic humanized title, and exact `sourceInfo.source`) follows handlers, tools, commands, renderers, promises, and timers. Raw extension paths never enter owner IDs. The semantic broker records optional widget owners and per-key status owners; rendered component surfaces retain only exact source provenance. Unattributed calls remain ownerless rather than being guessed, and protocol owner records are bounded at the store and native admission boundary.

Parallel tool events carry a monotonic per-run ordinal; each call additionally has
a monotonic progress sequence, bounded display-safe live-output tail, runtime start,
last-progress/completion timestamps, and a duration measured from the tool callback
with a monotonic clock. Running progress carries the latest monotonic duration sample;
the completion carries the final call-to-return duration. The Gateway coalesces high-rate
updates without losing the newest state. Clients join calls, progress, and results
by canonical call ID rather than arrival order.

Active message queues are projected with stable per-entry IDs, delivery behavior,
display text, total attachment count, optional photo/file counts, and a monotonic queue revision.
A Gateway advertising
`queue-management.v1` includes both `queueRevision` and `queuedItems` in every authoritative
session snapshot. The legacy steering and follow-up string arrays remain a compatibility
projection for older clients and Gateways; they never authorize entry-level mutation.
`session.queue.replace`
serializes with prompt admission and clear operations, validates bounded replacement
state, rejects stale revisions, and rebuilds the pinned runtime queue atomically.
Steering entries always precede follow-ups because that is the runtime's delivery
order; reordering is authoritative within either behavior, and changing behavior
moves an entry into the corresponding delivery stage. Attachments remain bound to
their original queued identity and cannot be fabricated by clients. Queue snapshots
are bounded to 32 entries, 64 KiB per display message, and 256 KiB total.
Prompt RPC admission follows the pinned runtime's preflight callback as its sole outcome;
the Gateway does not race it against a local deadline that could report rejection while
the same uncancelled runtime call later starts canonical work. While the canonical user
entry is pending, the snapshot's bounded `pendingPrompt` projection carries the display
text and requested delivery behavior. It is cleared by the canonical user entry or a
definitive rejection, so iOS can reconstruct an in-flight prompt across navigation without
replaying it.

Manual compaction has a separate Gateway-owned single-entry maintenance admission. Its
synchronous claim covers pending, direct, and queued execution, so a second request is rejected
rather than serialized behind the first. An idle request starts canonical compaction immediately.
A request accepted during an active agent run publishes `compactionQueued`, retains the run marker,
and keeps its command receipt pending until the exact compaction starts after final `agent_settled`
and completes or fails. Handoff revalidates that no newer agent run owns the session, and queued
completion awaits durable marker removal before publishing settled. Gateway shutdown synchronously
closes runtime-slot admission, drains any already-entered creation/import critical section through the
registry mutex, then cancels unstarted queued work and drains every captured runtime before blob disposal.
This state is not a
prompt queue entry and is never replayed by iOS. Snapshots also project the runtime's effective
`automaticCompactionEnabled` value; both fields remain optional for rolling clients.

Session structure/context/resource invalidations refresh
already-presented secondary surfaces. Provider, settings, trust, package, and
custom-model mutations publish bounded global invalidations so another connected
client refreshes its explicitly scoped canonical projection. `session.create` accepts an
optional source-control strategy. `existingCheckout` passes the selected directory through
unchanged; `newBranchWorktree` creates a managed Git worktree on a new branch from `HEAD` or
a validated committed base ref; and `existingBranchWorktree` creates a managed worktree from
an existing local branch. Git arguments are passed without a shell, branch/ref inputs are
validated, implicit-`HEAD` creation refuses dirty checkouts, and a worktree is removed again
if session creation fails. Pi itself receives only the resulting canonical `cwd`; its SDK has
no Git/worktree creation option. Persisted worktrees remain available for later sessions and
are never silently deleted with a session.
Settings projections include
scope-owned documents and effective values, but write-only proxy credentials are removed
from both; clients receive only `httpProxyConfigured` and can set or explicitly clear the
canonical value. Persisted settings documents and their responses fail closed before generic JSON
projection if their depth, members, nodes, strings, or encoded size would be truncated or exceed
the mobile frame; rejected updates leave the prior document intact. Trust changes reload
idle live runtimes before acknowledgement; project resources therefore cannot stay
loaded from an obsolete decision. PTY output has an independent monotonic
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
session subscription; input, resize, and termination additionally require attachment ownership on the
requesting connection. Closing a session immediately revokes attachment admission. These checks
prevent stale client selection or reconnect races from reading or mutating a different runtime,
controlling another connection's PTY, or leaving an orphan terminal process.

Primary operation groups are `system`, `device`, `legacy`, `session`,
`extension`, `provider`, `model`, `auth`, `settings`, `trust`, `packages`,
`models.custom`, `filesystem`, `git`, `terminal`, and uploads/blobs over HTTP.
Provider authentication admits at most eight operations globally and two per
client. Each operation has a 15-minute Gateway-owned lifetime, so providers that
ignore abort cannot retain broker capacity; completion, failure, cancellation,
disconnect, and timeout retire exactly once. Provider prompt/event projections
are limited to 128 KiB before broadcast, and late callbacks from retired operations
are inert. A bounded one-minute tombstone window makes duplicate or reordered
`auth.respond`/`auth.cancel` requests harmless without retaining prompt values.
`session.list` and `model.list` are cursor-paginated so Pi catalogs remain
complete without exceeding bounded gateway frames. Workspace browsing streams directory entries
from an identity-checked directory handle and fails visibly, without returning a partial listing,
above 1,000 examined entries or 768 KiB of projected metadata; ordinary folders retain the established directory-first
ordering and exact paths. Package inventory and update projections reject duplicate stable
identities, more than 256 packages/updates, more than 1,000 resources of any kind, strings above
8 KiB, or encoded responses above 768 KiB before generic JSON projection can truncate them. The bounded JSON projector tracks only the active recursion path, so shared Pi metadata objects are expanded for each sibling resource while true cycles remain marked and bounded. Pi's configured `sessionDir`, or its
canonical per-workspace directories under `agentDir/sessions`, remain authoritative; Tron does
not move or mirror those files. `session.list` defaults to user sessions, while `scope: "all"`
additively includes extension-owned children classified from nested canonical storage or their
durable `subagent-*` session metadata. Ordinary user forks remain user sessions. If more than
one canonical file claims the same embedded session ID, the Gateway omits every ambiguous copy
and rejects open/delete by that ID until the duplicate is repaired; traversal order never chooses
canonical ownership. Before materialization, recursive discovery streams at most 50,001 directory entries,
retains at most 25,001 canonical directories/8 MiB of traversal paths, and admits at most 25,000 session
records/8 MiB of retained metadata; overflow fails retryably without publishing a partial catalog. The pinned
SDK remains the canonical direct-directory JSONL scanner, while Gateway immediately discards its unused
transcript-wide picker search text. A fresh `session.list` still uses that complete canonical SDK row materialization. The pinned SDK constructs `allMessagesText` before returning, so its transient pre-return memory peak remains SDK-owned; Gateway discards the field immediately and never retains it. Canonical path normalization runs with at most 16 concurrent filesystem operations.

`RuntimeRegistry` separately retains only a bounded acquisition admission: canonical header ID/path/cwd, structural user-versus-subagent classification, the atomic ambiguous-ID set, and a fixed-size digest. It never retains transcript text or a second summary catalog. The normal cold-acquire path uses an independent mutex and builds or validates this admission from canonical JSONL membership, canonicalized paths, and bounded header ID/cwd/parent evidence, without waiting for transcript-wide catalog materialization. Ordinary message/tool appends do not change the digest. Additions, removals, aliases, duplicate identities, or same-path header identity replacement do. A malformed unrelated JSONL header does not globally block valid sessions: incomplete lightweight evidence falls back, without holding the acquisition mutex, to two matching SDK-derived fingerprints over the full normalized canonical identity set. That one-off result is not cached and its exact SDK identity fingerprint is validated again immediately before runtime creation. Directories named `*.jsonl` are not file candidates.

The exact opened manager must still reproduce the admitted ID and canonical cwd, and its current name is checked for the durable `subagent-*` classification. Normal complete-header acquisition runs a second bounded structure/header comparison after manager open and before runtime resources load; fallback acquisition instead repeats its full SDK-derived identity validation. Changes reject retryably, while the unavoidable cross-process race after that final validation point is not presented as eliminated. Header validation starts with 512-byte reads, runs in deterministic batches of at most 16 files, permits at most 64 KiB per candidate with a strict shared 64 MiB aggregate budget apportioned across the candidate set, and inserts at most 25,000 identities/4 MiB into transient or reusable evidence. Gateway-owned mutations are generation-checked before and after every lightweight build and again immediately before a full catalog identity is published. An unstable lightweight scan or full list retries once and then fails retryably without publishing stale evidence. Hot slots not marked ambiguous by the latest full catalog bypass global header validation; known ambiguous IDs continue validating until duplicate repair is observed. Thus idle resume normally avoids a transcript-wide catalog parse while JSONL and the pinned manager remain canonical.

Every session-list traversal is one
immutable, disposable catalog materialization: every page carries the same structural `listRevision`, and its authenticated opaque cursor
is bound to the connection, scope, materialization, offset, and revision. Traversal
leases expire after 30 seconds, are released on disconnect, and are bounded by
per-client lease quotas plus per-lease/global row and encoded-byte limits with LRU eviction. Runtime `session.summary` revisions remain independent, so activity heartbeats
and ordinary row updates neither rescan nor tear catalog pagination; a later traversal
observes newer canonical truth. Clients still fail closed and restart from a nil cursor
when interoperating with an older Gateway that changes revisions between pages. Model-list
cursors bind their offset to an exact whole-catalog SHA-256 fingerprint and a 30-second immutable
runtime-local materialization, so changes cannot mix pages and later pages do not rebuild or rehash
the catalog. At most four traversals remain per runtime and eight globally. Each traversal is limited to 25,000 items
and 16 MiB of encoded model entries; each page is additionally capped at 800,000 encoded entry bytes
beneath the socket envelope ceiling. Provider catalogs reject more than 1,000 rows, duplicate IDs,
or 4 MiB of strings before generic projection can truncate them.
`session.open` carries a
byte-bounded authoritative transcript tail with `transcriptStart` and
`transcriptTotal`; `session.transcript` pages backward through the same canonical
Pi branch without enlarging the WebSocket frame limit. Snapshot tails and pages are
bounded by both encoded bytes and 512 items. Page responses carry exact `start`, `end`,
and `total` bounds; `end - start` always equals the returned item count, so generic JSON
projection cannot silently truncate a tiny-item page. Paging is a bounded read for an
already-open presentation and never creates or revives event-subscription ownership.
Live tool arguments,
structured current results, and readable output are independently projected to
bounded previews; current output updates the existing chip/detail view in place
rather than creating transcript rows. Exact timing is retained for the current
owning runtime using a monotonic start-to-end measurement and projected onto settled
results; older Pi JSONL entries, which do not persist execution timing, use the
canonical call-to-result interval as an observed fallback. Completed results leave the live overlay as soon as their
canonical transcript entry exists. A final snapshot fitter compacts duplicate live
detail before canonical rows. Active snapshots preserve their baseline page so a
tool burst cannot reveal a new pagination boundary in an already-open chat; resumed
idle sessions may begin from a smaller bounded tail. iOS retains explicitly loaded
earlier pages while installing an overlapping authoritative tail. Phase, operation,
tool identity/order, and canonical paging cursors remain authoritative. Arbitrarily
large active runs therefore remain openable; no canonical Pi content is modified or
discarded. Canonical non-image upload
envelopes retain their runtime-owned readable paths, but the mobile transcript
projection replaces those tags with bounded name/type/size metadata on an
ordinary text part and never sends the Mac path to clients. Active protocol-v3 clients therefore receive the safe filename instead of the
Mac path for a new content discriminant. A page carries the next
visible entry as its branch anchor and fails retryably if tree navigation changed
that boundary while the request was in flight. Oversized responses return
a correlated protocol error instead of disconnecting the device. `session.context`
and `session.resources` return runtime-native resource projections. The resource
projection includes display-safe extension, prompt, skill, context-file, and tool
metadata while canonical resource files and runtime loaders remain authoritative.
`session.tree` returns the existing newest-first-selected, chronologically restored
flat outline of at most 1,000 nodes and 700 KiB with depth, child-count, role, and
current-path metadata; it never recursively serializes an unbounded canonical tree.
The projection rejects duplicate canonical entry IDs and oversized retained strings;
omitted older parents are valid because the bounded outline is not a canonical mirror.
`session.commands` preserves runtime sort order and rejects catalogs above 1,000 rows
or 700 KiB, duplicate full `source:name` identities, empty names, or command metadata
strings above 8 KiB before generic JSON projection can truncate the response.
Summarizing tree navigation owns foreground branch-summary state only for the exact
awaited call; success, extension cancellation, and provider failure all retire that
state and publish the settled snapshot before the serialized mutation lane advances.
Session statistics include the runtime-calculated latest cache-hit rate used by the
terminal footer, so mobile clients do not invent a different ratio.
Custom model documents are validated by a temporary instance of the pinned runtime
before an atomic write. Canonical reads, validation files, redaction traversal, and locked
updates share a 768 KiB file ceiling plus bounded depth, nodes, and collection members.
Read projections redact secret-looking strings; matching redaction placeholders are restored
from canonical state during update so mobile editing cannot erase credentials it was never
allowed to read.

Administrative restart is a drain, not an abort: the Gateway freezes new mutations,
allows every admitted agent run to settle canonically, then exits with the supervised
restart code. Live PTYs block restart because process replacement cannot preserve them.
LaunchAgent supervises packaged Gateways; `scripts/tron dev --background` runs the isolated
Gateway behind an equivalent development supervisor. `scripts/tron dev --restart` uses the
same protocol request and is safe to invoke from a Gateway-owned agent tool; direct self-stop
is rejected. Clients receive `system.stopping`, reconnect with bounded backoff, and replace
live state from a new authoritative snapshot. An unexpected process death remains an
interruption represented by the durable run marker and is never automatically replayed.

## Session invariants

1. `RuntimeRegistry` owns at most one `RuntimeSlot` per session in this process.
2. `RuntimeSlot` serializes mutations for its session. Different slots execute
   concurrently.
3. Prompt admission returns an operation ID; client disconnect does not abort it.
4. Subscribe/open establishes a two-phase baseline barrier: the connection subscribes
   and captures a snapshot cursor, returns that snapshot plus an ephemeral `syncToken` and
   explicit `subscriptionToken` ownership credential. The client acknowledges the exact
   baseline with `session.sync`, after which only later sequenced events are released.
   While the barrier owns a session's catch-up it is the only delivery path, so every
   in-window event reaches the client exactly once and in sequence. A bounded barrier
   overflow converges the client with a fresh authoritative `session.rebaseline`
   snapshot instead of a resync dead end; only an unavailable session falls back to
   `transport.resyncRequired`.
   A failed open transaction revokes
   its barrier, timer, and subscription ownership immediately, so retrying cannot produce
   a stale “already synchronizing” conflict. Concurrent opens for the same connection and
   session are rejected before they can replace the owner; establishment and synchronization
   commit are request-and-token exact. Distinct sessions and connections remain independent.
5. Reconnect/open returns complete current runtime state plus a bounded canonical
   transcript tail, not durable missed-event replay; older transcript pages remain
   available through branch-stable anchors.
6. A run marker exists only for an admitted active operation. Startup projects a
   surviving marker as `interrupted`; prompts are never replayed automatically.
7. A foreground snapshot cannot be idle while the embedded runtime is streaming,
   and an idle snapshot cannot retain a running foreground-tool overlay. Detached
   extension work is represented separately by extension UI state.
8. Fork/session replacement rekeys the same owning slot and subscriptions.
9. Idle runtimes may be evicted only while not busy and unsubscribed.
10. Administrative restart waits for admitted agent runs to settle and requires an
    external supervisor; it never claims that in-process runtime memory survives replacement.
11. The gateway is the sole mutable runtime owner. Terminal and mobile chat surfaces
   must attach to this runtime; opening the JSONL in an independent Pi process is
   unsupported because Pi has no cross-process session lock.

## Trust and execution

Each project session has an isolated mutable model/provider runtime. Tron's
administration/onboarding runtime composes global providers without loading
untrusted project resources.

Unresolved trust blocks project resource loading. A trusted project may load
settings, extensions, skills, prompts, packages, and system prompt files with the
Mac user's authority. This is not sandboxing. Package and extension source must
be reviewed before installation. Trust mutations serialize, prepare every open project runtime with
the exact proposed decision, and persist only after all reload attempts settle successfully. A reload
or persistence failure restores the exact prior saved decision and reapplies that runtime state before the mutation can fail; rollback
activation failures remain explicit instead of reporting a failed-but-applied trust change.

The PTY implementation uses node-pty's architecture-specific macOS spawn
helper. The locked package's install hook is followed by Tron's `postinstall`
repair, which enforces executable permissions on that helper; terminal tests
open a real PTY so packaging cannot silently ship a non-executable helper.

## Development

```bash
npm ci
npm run build
npm test
npm audit --omit=dev
```

Attach a terminal chat surface to the same Gateway-owned runtime as iOS:

```bash
scripts/tron chat --session <session-id>
# or select the newest session for the current working directory
scripts/tron chat
```

This client uses the stable Tron protocol, a 64 KiB-bounded local wrapper credential,
atomic snapshot/event catch-up, command IDs, and reconnect convergence. Automatic
session selection admits at most 126 pages/25,000 unique rows/8 MiB, rejects cursor
cycles and malformed pages, and restarts mixed revisions once rather than recursing.
It does not open
or watch JSONL directly. Running `pi --session <same-file>` concurrently remains
unsupported because that creates a second mutable runtime owner.

Run one test owner while iterating:

```bash
npx vitest run src/transport/session-sync.test.ts
npx vitest run src/sessions/runtime-registry.integration.test.ts
npx vitest run src/admin/legacy-import-service.test.ts
```

The integration tests use the SDK's faux provider to verify concurrent real
session runtimes, detached completion, and fork rekeying without network
credentials. Additional deterministic tests exercise interactive API-key and
OAuth brokering, project trust, native local-package persistence, legacy import,
and credential separation.
