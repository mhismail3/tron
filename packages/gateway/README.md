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
- settings, credentials, packages, trust, custom-model administration, generic
  extension UI forwarding, and bounded push-notification admission. Extension activity history revisions are
  derived from the globally sorted canonical receipt sequence; filters and
  duplicate-content collapse select page content but never change cursor
  identity. Component placement metadata is committed only with registry
  admission, so bounded capacity failures cannot orphan surfaces.

The embedded runtime remains canonical for sessions, provider/model semantics,
credentials, settings, packages, resources, compaction, and retries. Gateway
does not maintain a session database or event journal. A process lock is held per
agent directory and any configured external session directory because the session
format has no cross-process lock; another Gateway must use separate canonical
storage, not the same JSONL tree. The aggregate runtime-lock release is shared and
idempotent across concurrent shutdown callers. Runtime `sessionDir` changes are rejected until
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
- Local wrapper credential: `gateway/local-auth.json` (`0600`, owner-UID-only regular non-symlink file;
  an existing malformed, wrong-version, or wrong-purpose credential fails closed)
- Hashed mobile devices: `gateway/devices.json` (bounded owner-UID-only regular non-symlink file;
  legacy `lastSeenAt` is read for migration but removed on the next owned write; auth contexts expose
  only `kind` and `deviceId`)
- Current invitation: `gateway/enrollment.json` (`0600`, owner-UID-only regular non-symlink file;
  ten minutes, one use; pairing consumes it before device persistence and regenerates it if persistence fails)
- Run markers and command receipts: gateway-owned bounded operational state; per-session
  marker mutex lanes are retained only while queued or executing callers use them
- Uploads: transient and bounded; unclaimed staging expires, while prompt attachments remain session-owned until canonical deletion
- Tool invocation groups: at finalized assistant `message_end`, Gateway publishes the complete contiguous declaration group before any corresponding tool start, with runtime-only `groupId`, `groupIndex`, `groupCount`, and `groupFinalized` metadata. Group IDs derive from the stable assistant presentation ID plus first projected content ordinal, survive live/canonical/result reconciliation, remain bounded until agent settlement, and are never written to Pi JSONL or interpreted as proof of parallel execution.
- Push grants and short-lived intents: `gateway/notifications.json`, an exact 1 MiB owner-only document. It stores endpoint-scoped grants, at most 64 active devices, 256 pending intents, 512 bounded receipts, and 192 revocation tombstones (128 rotation slots plus a 64-device revocation reserve). It never stores raw APNs tokens. Secrets and message content are excluded from RPC projections, logs, and Pi session JSONL.

Legacy `~/.tron/auth.json` is not gateway auth and is never overwritten. It is
read only by the explicit legacy importer. That importer rejects duplicate or
oversized identities and bounded page/history/payload overflow, detects stalled
cursors, and persists each completed legacy-to-canonical mapping before moving
to the next session so a retry safely skips partial success. Known append or
index-write failures remove the new canonical file; cleanup failure is surfaced
with the original failure, while process termination in the narrow interval
before the index rename remains outside that cleanup.

## Push notifications

The first-party inline Pi extension reserves `notify({message})`. It receives only a narrow enqueue closure: the model cannot choose a device, APNs token, environment, topic, relay origin, request ID, priority, badge, or payload dictionary. Admission is persisted before dispatch, deduplicated by canonical session/tool-call identity, expires after fifteen minutes, and returns `queued`, `suppressed`, `rate_limited`, or `unavailable`; APNs acceptance is never described as user delivery. Preview-disabled grants receive fixed generic lock-screen text.

The exact `@pi9/ask` package adapter emits a detached callback only when its first structured questionnaire is admitted. The typed global `notifyWhenAskPresented` boolean defaults on, is persisted with notification state, and produces one fixed generic intent per Ask tool-call ID. Relay failure never delays or fails Ask. This is intentionally not a generic policy engine.

Authenticated mobile RPCs are `push.registration.upsert`, `push.registration.remove`, and `push.registration.status`. Upsert derives `deviceId` from the connection and accepts only an opaque installation ID, endpoint-scoped grant ID/secret, and preview/policy booleans; preview disclosure defaults off. `device.revoke` disables local push authority before removing the paired bearer and retains a bounded remote-revocation tombstone. The public relay origin is read from the canonical maintainer-owned `config/PushService.xcconfig`, embedded into both signed products, and must be an exact public HTTPS origin. It is never accepted from tools, RPC, user settings, or runtime environment. Missing development configuration leaves notification delivery unavailable without affecting Gateway readiness; official packaging fails closed.

Outbound relay requests use one fixed `/v3/notifications` route, no redirects, a twenty-second deadline that exceeds the relay's bounded APNs deadline, a 2 KiB request and 16 KiB response boundary, and a lowercase-hex HMAC over method, path, timestamp, stable request ID, and the exact body's lowercase-hex SHA-256. Restart recovery retries only transient outcomes with the same request ID; ambiguous outcomes are not blindly replayed. Quotas apply across the installation, canonical session, and target grant.

## Transport

- `GET /health` — unauthenticated readiness and compatibility metadata
- `POST /v1/pair` — rate-limited one-time enrollment exchange
- `POST /v1/uploads` — authenticated bounded upload
- `GET /v1/uploads/:id` — authenticated stream for a prompt-owned canonical attachment
- `GET /v1/blobs/:id` — authenticated transient projected blob
- `GET /v1/socket` — authenticated protocol version 3 WebSocket

The pairing limiter keeps the exact rolling per-address window while retaining at most 4,096
least-recently-used address keys and periodically deleting expired windows; address churn cannot
create append-only process state. Paired-device storage admits at most 256 unique device IDs and
token hashes with bounded names/timestamps; capacity rejection leaves the one-time invitation valid
so an old device can be revoked before retrying. Device metadata is capped at 1 MiB, the local wrapper
credential at 4 KiB, and the one-time invitation at 16 KiB before JSON decode. Local credentials and
invitations also require owner-only regular-file boundaries (symlinks are rejected), exact versions,
purposes, bounded identities/codes, and canonical timestamps. A pairing invitation is consumed before
its device record is written; a failed device write explicitly issues a fresh invitation while the
pairing mutex remains held. Uploads retain the 25 MiB per-request limit and additionally
serialize reservation and commit against a 1,024-entry and eight-times-per-upload (200 MiB by default) aggregate ceiling. The aggregate byte bound remains the primary storage limit so many small photos do not exhaust capacity prematurely.
A separate admission permits at most half that ratio concurrently (four default 25 MiB bodies). Authenticated request
chunks stream directly into protected store-owned files; exact declared and observed sizes are checked before atomic
metadata publication. Persisted upload metadata is limited to an exact 64 KiB document with canonical timestamps and fields; malformed or oversized entries self-clean before quota admission or direct materialization. Every success, rejection, overflow, truncation, or disconnect removes uncommitted staging
and releases its slot. Unclaimed uploads
expire after 24 hours, malformed/partial folders self-clean, prompt attachment IDs are unique, and
one prompt cannot materialize more than the per-request byte ceiling. Mobile projection derives the
opaque upload identity from the validated store-owned canonical path, strips that private path, and
exposes the identity solely as an authenticated preview route; no extra identifier is added to the model
prompt. Unclaimed staging is never readable, while a prompt-owned file streams from its already-open
descriptor with its exact declared size and MIME type.
Successful imports remove
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

Gateway updates are an explicit, bounded control-plane contract. `gateway.update.status`
projects only the selected channel's `deployment-state.json`, `current.json`,
`previous.json`, and version manifests (each document is capped at 64 KiB); malformed
or oversized state fails closed. `gateway.update` accepts only `channel` (`stable` or `dev`), `mode` (`source`,
`artifact`, or `auto`), candidate version/fingerprint, and a command ID. Artifact
promotion requires both exact candidate fields; version-only requests fail closed.
`gateway.rollback` is the authenticated, receipt-backed companion mutation; it accepts
only a bounded channel and command ID and launches the supervised helper's existing
rollback operation. Each runtime is bound to `TRON_GATEWAY_CHANNEL`: Stable can
inspect/mutate only Stable, and Debug only Debug; developer handoff is a local CLI
operation rather than a cross-channel RPC. Both mutations acknowledge helper admission only; status remains
authoritative and includes the active command ID and rollback availability.
`gateway.update.config` separately accepts only a trusted repository `sourceRoot` and
optional `artifactRoot`; both are checked as absolute, non-symlinked directories before
being stored in `gateway/update-config.json`. It invokes no client-supplied command or
path. The LaunchAgent-owned helper reads that projection only: source mode invokes the
repository's local TypeScript compiler with its checked-in config and a private temporary
`outDir` (it never writes the trusted repository's `packages/gateway/dist`), then stages
only verified output; artifact mode only promotes a verified candidate, and auto prefers
staged artifacts before source. A successful RPC acknowledges helper launch, not eventual
build or promotion success; asynchronous helper failures are reported in update progress. A
planned restart publishes a distinct `draining` phase and may wait without a startup deadline
for already-accepted runs; only after the exact captured old PID/start identity disappears or
changes does the bounded candidate health deadline begin. Listener or health loss alone is not
transition evidence. Candidate startup uses an atomic attempt/commit marker shared
with the launcher: an uncommitted relaunch crash-rolls back, while a committed exact selection
and authenticated identity cannot be raced into rollback. If bounded recovery health fails after
selection restoration, the helper removes the now-mismatched attempt marker under the launcher's
shared attempt lock so the launcher can start the restored payload instead of failing closed forever.
Debug handoff is exposed as Debug
origin only when its bounded provenance (candidate version/fingerprint, tested Debug fingerprint,
source revision, tested runtime epoch, and candidate runtime epoch) matches the verified Stable
candidate manifest. Generic automatic/source updates never infer a Debug-origin candidate from
state; promotion must pin its exact candidate version and fingerprint.
`gateway.update.config.status` and `gateway.update.status` are bounded projections; the latter
includes build/staging/draining/promotion/rollback/failure progress. The mutation is usable only when the helper is
configured, in which case `gateway-update.v1` appears in capabilities. Candidate transition health uses a 60-second default deadline; an owned decimal-millisecond override is admitted only from 2,000 through 300,000 milliseconds.

Every WebSocket starts with:

```json
{"type":"hello","protocolVersion":3}
```

The hello, pairing response, and authenticated `system.info` identify the runtime
with `machineId` (stable per Tron home), `gatewayChannel` (exactly `stable` or
`dev`), and, on current gateways, `machineGroupID` (stable across separate
production and isolated-Dev homes on one physical Mac). Runtime construction
validates `TRON_GATEWAY_CHANNEL`; absence retains the launcher's stable
compatibility default, while every other value fails closed before identity can
be projected. Older gateways omit `machineGroupID`; clients fall back to
`machineId`. The group identifier is only a bounded connection-group hint and
never names or shares session files, credentials, or other canonical runtime
data.

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
Outbound WebSocket admission keeps the 1 MiB encoded-frame ceiling and an 8 MiB per-connection aggregate queue ceiling. A connection-local ordered writer hands exactly one frame to the WebSocket implementation at a time; enqueue acceptance is the response/event ordering boundary, so a response remains ahead of its synchronization suffix while concurrent startup catalogs cannot manufacture `bufferedAmount` pressure. The queue includes its active frame, clears on disconnect, and closes with `1013` only on true aggregate overflow. Asynchronous write failures are logged and terminate that exact connection.
The gateway sends WebSocket ping control frames every 25 seconds and terminates
connections that fail the next heartbeat, so half-open Tailscale/iOS paths are
observable. Pong, ping, and application frames all refresh liveness; mobile clients also issue an application-level probe before that interval for compatibility with URLSession paths that do not reliably surface automatic pong handling. Heartbeat timeouts and bounded WebSocket close codes/reasons are recorded without device credentials so transient transport failures remain diagnosable. Reconnect and foreground activation converge through an authoritative
snapshot. `session.summary` is a bounded, per-session revisioned global projection
of phase, name, activity time, message count, and first-message title. It updates every connected
dashboard immediately without broadcasting full transcripts; clients subscribe
to `session.snapshot`, progress, tool, queue, and extension events only for chats
they actually open. Streaming progress republishes the cumulative live message, so
updates are coalesced to one frame per short window (the first update stays
immediate) and each frame is bounded by exact encoded bytes to a marked live tail.
At assistant-message start the runtime captures one opaque presentation ID, fixed
canonical parent anchor, and fixed timestamp. Every projected content part carries
its required source ordinal; adjacent thinking parts also carry their fixed run
ordinal, including after leading live-tail trimming. Pi's `message_end` callback
precedes canonical append, so the runtime binds that same presentation ID to the
new canonical entry in the following microtask before publishing the settled
snapshot. The binding ledger is capped beyond the maximum mobile transcript page;
canonical entry IDs and JSONL remain authoritative and unmodified. Active operations also emit a bounded sequenced heartbeat, so
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
presentation is excluded from offline mobile cache. Wire interactions retain one flat JSON
shape but are method-discriminated by Gateway and native admission: select requires options;
confirm forbids select/input fields; input permits text defaults and questionnaires; editor
permits text defaults without select options or questionnaires. Native editor updates admit an
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

Live tool projections may carry an optional extension provenance record derived from the public Pi tool `sourceInfo` and the loaded extension inventory. The Gateway emits that record only when exactly one extension owns the tool and the source path agrees; unknown or ambiguous ownership omits provenance and fails open to the ordinary tool projection. This metadata is disposable presentation state and never modifies Pi JSONL. When an extension-owned tool returns the public structured delegated-run convention (`details.runId`/`asyncId` plus bounded `results[].progress`), the Gateway additionally projects `ExtensionRunActivity` with stable child identities, active time, tool/turn counts, current tool/path, and a bounded output tail. It is carried on the live tool projection and retained as a bounded recent `extensionActivities` snapshot; native clients must not infer it from rendered widget text or open a child JSONL concurrently. The runtime also admits the explicit `pi-subagents` lifecycle-artifact contract: allowlisted `status.json` files are matched to the canonical session file, read with a hard byte bound, and projected as one workflow activity with bounded child progress so detached async runs remain visible after the launching tool returns. Temporary runtime roots and the project-local `.pi/subagents/async-subagent-runs` layout are scanned under one hard work budget; exact live `asyncDir` bindings refresh before bounded ambient enumeration, and terminal ambient evidence outranks decorative live enrichment. A bounded Gateway-owned `runId` binding maps lifecycle events and artifacts to one real tool-call identity; a synthetic `subagent:<runId>` identity is used only for an initially unmatched, session-owned artifact and is re-keyed when the real tool call arrives. Terminal lifecycle status is authoritative, while later artifacts only enrich retained details and cannot resurrect a completed run; terminal recency uses the producer's completion time rather than the later discovery time. Current artifacts are admitted by their exact schema version; historical versioned or unversioned artifacts can supply terminal evidence only after an exact canonical tool-call/`asyncDir` binding proves ownership, so a Gateway reload cannot strand already-finished delegated work in restart drain. Watchers stop on terminal state, disposal, and retention eviction.

Remote restart is advertised only when `TRON_GATEWAY_SUPERVISED=1` is present from a managed LaunchAgent or repository background supervisor; direct foreground processes fail closed for remote restart. The Gateway exits with code 75 only after the registry drain completes, leaving process replacement to the owning supervisor.

Extension callbacks are wrapped through the public `DefaultResourceLoaderOptions.extensionsOverride` seam on every load and reload. An AsyncLocalStorage owner (an opaque SHA-256 identity derived from stable source/path provenance, a generic humanized title, and exact `sourceInfo.source`) follows handlers, tools, commands, renderers, promises, and timers. Raw extension paths never enter owner IDs. The semantic broker records optional widget owners and per-key status owners; rendered component surfaces retain only exact source provenance. Unattributed calls remain ownerless rather than being guessed, and protocol owner records are bounded at the store and native admission boundary.

Parallel tool events carry a monotonic per-run ordinal; each call additionally has
a monotonic progress sequence, bounded display-safe live-output tail, runtime start,
last-progress/completion timestamps, and a duration measured from the tool callback
with a monotonic clock. Running progress carries the latest monotonic duration sample;
the completion carries the final call-to-return duration. The Gateway coalesces high-rate
updates without losing the newest state. Running readable output is a bounded current-frame
channel: each newer nonempty frame replaces the previous display in place, while an empty advisory
frame preserves the last readable output so detail views never flash blank. A nonempty terminal result
is authoritative. Clients join
calls, progress, and results by canonical call ID rather than arrival order.

Active message queues are projected with stable per-entry IDs, delivery behavior,
display text, total attachment count, optional photo/file counts, optional bounded upload descriptors,
and a monotonic queue revision. Descriptors contain only upload/blob ID, safe name, MIME type, and size;
attachment bytes remain in the owned upload store and are fetched only through authenticated blob access.
For newly admitted steering/follow-up work, the returned prompt operation ID is the queue entry ID;
clients can therefore settle one optimistic submission without content-based queue guessing.
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
optional source-control strategy. The Gateway admits only exact mode-specific objects and
rejects unknown or cross-mode fields before constructing the internal request. `existingCheckout`
passes the selected directory through unchanged; `newBranchWorktree` creates a managed Git worktree on a new branch from `HEAD` or
a validated committed base ref; and `existingBranchWorktree` creates a managed worktree from
an existing local branch. Git arguments are passed without a shell, branch/ref inputs are
validated, implicit-`HEAD` creation refuses dirty checkouts, and a worktree is removed again
if session creation fails. Managed worktree roots and repository directories are created and
checked with non-following directory metadata, then realpath containment is proven before Git
runs, so pre-existing symlinks cannot redirect a target. Pi itself receives only the resulting
canonical `cwd`; its SDK has no Git/worktree creation option. Persisted worktrees remain available
for later sessions and are never silently deleted with a session.
Settings projections include
scope-owned documents and effective values, but write-only proxy credentials are removed
from both; clients receive only `httpProxyConfigured` and can set or explicitly clear the
canonical value. Persisted settings documents and their responses fail closed before generic JSON
projection if their depth, members, nodes, strings, or encoded size would be truncated or exceed
the mobile frame; rejected updates leave the prior document intact. Tree projection validates every
canonical entry discriminant and required payload before selecting its bounded newest candidates;
content and blob registration are performed only for admitted candidates. Trust changes reload
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
session subscription; each connection's installed subscription-token map is the sole local
subscription index for routing, admission, rekey, and revocation. Input, resize, and termination additionally require attachment ownership on the
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
canonical ownership. A newly created session has no canonical Pi JSONL until Pi records its first
content. While the Gateway owns that bounded live runtime slot, `session.list` projects one runtime-only
empty user row with its stable slot-creation time, cwd, phase, and revisioned summary fields. That row is
visible to every connected dashboard and remains directly openable/deletable, but it is not a second
session store: idle slot retirement or Gateway restart removes it if Pi never persisted content. Once Pi
creates JSONL, the canonical row replaces the runtime-only projection under the same ID without duplication.
Before materialization, recursive discovery streams at most 50,001 directory entries,
retains at most 25,001 canonical directories/8 MiB of traversal paths, and admits at most 25,000 session
records/8 MiB of retained metadata; overflow fails retryably without publishing a partial catalog. The pinned
SDK remains the canonical direct-directory JSONL scanner, while Gateway immediately discards its unused
transcript-wide picker search text. The first complete structural read after startup or an uncertain canonical mutation uses that SDK materialization. Gateway then retains one bounded normalized disk index containing only canonical identity/classification metadata—never transcript text—and revalidates it with bounded header evidence. Later `session.list` traversals dynamically overlay live-only slots and revisioned summaries without rebuilding transcript-wide picker text. Empty live-slot create/delete updates preserve the warmed disk index, and a confirmed persisted delete repairs it from post-delete header evidence. The pinned SDK constructs `allMessagesText` before returning, so the unavoidable cold pre-return memory peak remains SDK-owned; Gateway discards the field immediately and never retains it. Canonical path normalization runs with at most 16 concurrent filesystem operations.

`RuntimeRegistry` separately retains only a bounded acquisition admission: canonical header ID/path/cwd, structural user-versus-subagent classification, the atomic ambiguous-ID set, and a fixed-size digest. It never retains transcript text or a second canonical catalog. The normal cold-acquire path uses an independent mutex and builds or validates this admission from canonical JSONL membership, canonicalized paths, and bounded header ID/cwd/parent evidence, without waiting for transcript-wide catalog materialization. A warmed structural index supplies the same admission without another SDK scan; exact header evidence and the selected manager's ID/cwd are still revalidated before runtime resources load. Ordinary message/tool appends do not change the digest. Additions, removals, aliases, duplicate identities, or same-path header identity replacement do. A malformed unrelated JSONL header does not globally block valid sessions: incomplete lightweight evidence falls back, without holding the acquisition mutex, to two matching SDK-derived fingerprints over the full normalized canonical identity set. That one-off result is not cached and its exact SDK identity fingerprint is validated again immediately before runtime creation. Directories named `*.jsonl` are not file candidates.

The exact opened manager must still reproduce the admitted ID and canonical cwd, and its current name is checked for the durable `subagent-*` classification. Normal complete-header acquisition runs a second bounded structure/header comparison after manager open and before runtime resources load; fallback acquisition instead repeats its full SDK-derived identity validation. Changes reject retryably, while the unavoidable cross-process race after that final validation point is not presented as eliminated. Header validation starts with 512-byte reads, runs in deterministic batches of at most 16 files, permits at most 64 KiB per candidate with a strict shared 64 MiB aggregate budget apportioned across the candidate set, and inserts at most 25,000 identities/4 MiB into transient or reusable evidence. Gateway-owned mutations are generation-checked before and after every lightweight build and again immediately before a full catalog identity is published. An unstable lightweight scan or full list retries once and then fails retryably without publishing stale evidence. Hot slots not marked ambiguous by the latest full catalog bypass global header validation; known ambiguous IDs continue validating until duplicate repair is observed. Same-session cold opens share one startup, while distinct session starts reserve capacity atomically and perform manager/runtime initialization outside the registry-global publication mutex. Creation uses the same short reservation boundary, so one slow project resource loader cannot serialize unrelated starts. Administrative drain and shutdown wait for already-admitted starts before snapshotting runtime ownership. Thus idle resume normally avoids a transcript-wide catalog parse while JSONL and the pinned manager remain canonical. Privacy-safe stage and RPC-completion records report only method/stage, outcome, and duration; they never log IDs, paths, prompts, or parameters.

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

Cross-client read attention is narrow Gateway-owned metadata, not transcript or
catalog mirroring. A bounded atomic `gateway/session-attention.json` document
stores only completion/read-through revisions, a manual-unread flag, a bounded
recent-completion deduplication set, and a restart-reconciliation cursor. Only an
accepted prompt turn's canonical assistant entry ending with Pi `stop` or `length`
at truthful agent settlement advances completion; generic idle, compaction,
abort/error/deferred output, runtime close, and intermediate tool-use messages do
not. Settlement retains the run marker and blocks open/drain until attention is
committed; a bounded canonical JSONL scan after restart reconciles the latest
successful completion before advancing its durable cursor. Catalog rows and
revisioned `session.summary` events project
`completionRevision`, `attentionRevision`, and `isUnread` without changing
structural `listRevision`. `session.attention.set` uses ordinary command receipts;
mark-read carries the exact rendered completion revision so a racing newer
completion stays unread. Successful `session.open` returns its current completion
revision, and first-party clients acknowledge it only after installing the
snapshot, retries transient acknowledgement failure against that same absolute
revision, and treats an older Gateway without the additive method as compatible.
Delete removes attention metadata, true identity replacement moves it without
overwriting a target, switches preserve both identities, and new/imported/forked
sessions begin read.

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
canonical transcript entry exists. A final snapshot fitter removes duplicate terminal
detail and compacts running payloads before canonical rows. Every legal fitted snapshot
retains at least the newest 24 display-bearing canonical transcript entries when that continuity floor can
fit; an individually oversized item is compacted before rows are removed. iOS preserves a
compatible recent continuity suffix—and any explicitly loaded earlier pages—while installing
an overlapping authoritative tail. Phase, operation,
tool identity/order, and canonical paging cursors remain authoritative. Arbitrarily
large active runs therefore remain openable; no canonical Pi content is modified or
discarded. Canonical non-image upload
envelopes retain their runtime-owned readable paths, but the mobile transcript
projection replaces those tags with bounded name/type/size metadata on an
ordinary text part and never sends the Mac path to clients. Active protocol-v3 clients therefore receive the safe filename instead of the
Mac path for a new content discriminant. A page carries and echoes the next projected entry as its branch anchor plus the current runtime
generation and leaf identity. Raw canonical parent links may pass through filtered session-info,
hidden custom, or extension-receipt entries and therefore never define projected-row adjacency.
Requests may supply all three expected identities; the
Gateway fails retryably if runtime replacement or tree navigation changed any boundary
while the request was in flight. Oversized responses return
a correlated protocol error instead of disconnecting the device. `session.context`
and `session.resources` return runtime-native resource projections. The resource
projection includes display-safe extension, prompt, skill, context-file, and tool
metadata while canonical resource files and runtime loaders remain authoritative.
`session.tree` returns the existing newest-first-selected, chronologically restored
flat outline of at most 1,000 nodes and 700 KiB with depth, child-count, role, and
current-path metadata; it never recursively serializes an unbounded canonical tree.
Every source node, parent link, timestamp, label, child list, and canonical entry ID is
validated before selection. Content and image blobs are projected only for admitted newest
candidates, so omitted images do not consume BlobStore capacity. The projection rejects
duplicate or malformed canonical entries and oversized retained strings; omitted older parents
are valid because the bounded outline is not a canonical mirror.
`session.commands` preserves runtime sort order and rejects catalogs above 1,000 rows
or 700 KiB, duplicate full `source:name` identities, empty names, or command metadata
strings above 8 KiB before generic JSON projection can truncate the response. `session.prompt`
may carry one optional, 512-byte-bounded `skillName` alongside nonempty text or attachments when hello advertises `skill-prompt.v1`. The Gateway admits it only when the live
runtime catalog contains exactly one matching `source == skill` / `skill:<name>` command and no colliding extension command, then
adds Pi's `/skill:<name>` prefix only at runtime admission while retaining the original prompt
for pending and queue presentation. Queue ownership retains the private skill identity across text/behavior edits and revalidates it before rebuilding Pi's queue. Canonical mobile projection recognizes only Pi's exact,
4 MiB-bounded persisted skill envelope, strips the private skill body/path, and projects its
user arguments through the existing attachment extractor. Malformed or newer skill-looking
envelopes become a generic omission rather than leaking private skill bodies/paths or being destructively guessed.
Absence of `skillName` retains rolling-compatible prompt behavior.
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

Administrative restart is a deadline-free drain, not an abort: the Gateway freezes new
mutations, allows every admitted agent run to settle canonically, then exits with the
supervised restart code. While waiting it emits bounded, count-only
`gateway.restart-drain.waiting` diagnostics every 15 seconds with the combined count of
in-flight slot admissions and drain-busy sessions, plus an explicit completion record,
so the Logs sheet distinguishes a healthy drain from a stuck or failed restart.
Live PTYs block restart because process replacement cannot preserve them.
The installed Release wrapper supervises Stable only. `scripts/tron dev` owns the
separate Debug lifecycle on 9848 through the same immutable payload store and launcher.
Its loopback-by-default handoff copies only an authenticated, selected Debug
artifact into Stable as an inactive candidate after proving the same exact Debug
identity before and after the copy; it never selects or restarts Stable. Compatibility
is checked against the actual installed/active Stable runtime, and Node/helper drift
requires a manual Mac app replacement. Promotion pins version and fingerprint,
atomically selects, requests a real drain-aware restart, and accepts readiness only
from the candidate's exact fingerprint, source revision, and runtime epoch. Apply and
rollback serialize per channel; failed pointer changes perform a compensating restart
and exact health verification. Status keeps observed live identity separate from the
selected pointer so publication cannot report readiness early. Payload staging,
promotion, and rollback use `scripts/gateway-payload-deploy.mjs`. Restart requests use the authenticated drain-aware Gateway protocol; direct self-stop
is rejected. Clients receive `system.stopping`, reconnect with bounded backoff, and replace
live state from a new authoritative snapshot. Staging preserves package-manager relative
symlinks verbatim so copied artifacts remain self-contained; cleanup never follows links,
which lets it remove a malformed failed staging tree without touching an external target.
An unexpected process death remains an interruption represented by the durable run marker
and is never automatically replayed.

## Session invariants

1. `RuntimeRegistry` owns at most one `RuntimeSlot` per session in this process.
2. `RuntimeSlot` serializes mutations for its session. Different slots execute
   concurrently.
3. Prompt admission returns an operation ID; client disconnect does not abort it.
4. Subscribe/open establishes a two-phase baseline barrier: the connection subscribes
   and captures a snapshot cursor, returns that snapshot plus an ephemeral `syncToken` and
   explicit `subscriptionToken` ownership credential. The connection-local token map is the
   sole installed-subscription representation; replacing a session atomically replaces its slot.
   The client acknowledges the exact
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
8. Fork/session replacement rekeys the same owning slot and subscription-token map entry.
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

## Extension activity lifecycle and history

Structured extension runs retain the legacy coarse `status` alongside the additive
versioned lifecycle record (`queued`, `running`, `paused`, `completed`, `failed`,
`stopped`, `rejected`, or `unknown`). Gateway projection sequence and terminal
latches own ordering; producer timestamps are display evidence only. Terminal
activities receive Gateway-owned `terminalAt`/`recentUntil` facts and are current
or recent for exactly 15 minutes. A single coalesced expiry deadline republishes
visibility; history is not deleted at expiry. Live artifact heartbeats publish one
`session.extensionActivity` delta with the exact activity and live revision; they do
not rebuild or broadcast the full transcript snapshot. Reconnect/open snapshots remain
authoritative baselines, and terminal/expiry transitions converge through the same
revisioned activity facts.

The `extension-activity-history.v1` capability exposes
`session.extensionActivity.list` and `.get`. Terminal facts are written as
reserved `tron.extension-activity.v1` Pi custom entries through the session
mutation lane. Receipts are bounded, exactly-once by activity identity, and retain
only child identity, label, lifecycle/attention, and aggregate tool/turn counts;
child task, output, path, current-tool, and timing fields never persist. They
remain in raw JSONL/export but are excluded from transcript, tree, and model projection. History cursors
carry an immutable receipt/branch revision and reject generation mixing.

Artifact discovery is bounded, validates the supported versioned lifecycle
artifact shape, and prioritizes queued/running/paused then newest observations
before routing them. One Gateway registry owns discovery and the watcher
lifecycle; RuntimeSlot remains the authority for exact session/tool ownership.
Per-slot watchers are therefore permitted only after that exact ownership has
already been proven, and never perform global scans. Pure artifact state and timestamp
normalization is shared by discovery and watcher refresh, while their admission,
ownership, receipt, and fail-closed policies remain slot-owned. A producer's logical
`endedAt` may precede the final persistence `lastUpdate`; both must follow `startedAt`,
but persistence after completion is valid terminal evidence. Administrative drain
also refreshes exact-owned artifacts directly on a bounded interval, so terminal work
does not depend on watcher delivery or ambient scan scheduling. Shared recency scheduling
removes only the disposable ambient projection at its wall-clock deadline,
while canonical history remains available. Detached nonterminal work protects
its session lane from idle eviction and administrative drain.
