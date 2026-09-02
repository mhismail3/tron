# Tron Gateway

## Protocol v4 chat semantics

The Gateway is the sole live owner of invocation, operation, and activity
identity. Canonical Pi JSONL remains authoritative; Gateway-owned bounded
`tron.chat-invocation.v1` records persist causal start/terminal/binding facts in
the same session branch and never enter model context. Plain prompt bodies remain
only in their canonical user entries rather than being duplicated into receipts;
resource arguments are bounded but preserve tabs and multiline text. A missing
terminal record after an accepted start is `outcomeUnknown` and is never
automatically replayed.

Transcript order is canonical branch order, never timestamp or activity recency.
The v4 projection separates inbound context, agent output/invocations, ambient
status, and hidden state. `custom_message` is model input; `custom`/`appendEntry`
is extension state. Producer attribution is only exact at a Gateway callback
boundary, receipt, trusted adapter, or registered tool ownership; unknown remains
unknown. Every projection is bounded by count and byte limits and malformed
recognized data fails closed for authoritative resynchronization.

Protocol v4 deliberately has no v3 runtime path. The deployed v3 update helper
cannot promote a candidate whose required range is strictly v4, so that one-time
major transition must use the Mac app's manual local Release reinstall runbook:
install the Mac app containing the v4 Gateway payload while preserving
`~/.tron`, verify the registered Gateway, and only then install a v4-only iOS
client. The repository protocol manifest is projected into Gateway payload,
Mac app, and iOS app metadata; launch/build/install validators require one exact
range. A replacement launcher's bundled payload is the migration bootstrap when
a previously selected external payload advertises an older range. Same-major
promotion and rollback treat that rejected external pointer as bounded history
and use the validated signed bundle as their recovery authority; they never
require the incompatible payload to become admissible again. Do not widen the
advertised minimum or allow a mixed v3/v4 pair merely to bypass that handoff.
Ordinary same-major updates continue through the owned Gateway update flow.

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
- filesystem/Git browsing, bounded uploads, durable display artifacts, and bounded PTY replay;
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

A supervised payload validates its architecture-specific immutable `node` and
technical `pi` command aliases before model services or extension packages load.
The aliases must have exact relative target text, remain inside
`TRON_GATEWAY_PAYLOAD_ROOT`, and resolve respectively to the running Node file and
the payload's executable Pi SDK CLI. Stable makes those selected bundled commands
deterministic; Debug preserves a valid developer Node first and adds the payload
commands as fallback. Invalid aliases fail startup rather than silently consulting
Homebrew, NVM, or a mutable user shim. Unsupervised source/test execution retains
its supplied environment. Extension-owned void presentation callbacks are
transactional best-effort projections: malformed or over-budget updates are
rejected with bounded diagnostics and can never become an uncaught process exit.

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
- Uploads: transient and bounded; clients may immediately discard their unclaimed staging, remaining unclaimed staging expires, and prompt attachments remain session-owned until canonical deletion
- Tool invocation lineage: Gateway stamps every live and canonical tool declaration with a `toolSegmentId` owned by one visible conversation segment, then publishes each complete contiguous declaration group at finalized assistant `message_end` with runtime-only `groupId`, `groupIndex`, `groupCount`, and `groupFinalized` metadata before any corresponding tool start. Lifecycle operation IDs may rotate while a tool-only agent continuation settles; the display segment remains stable until user input or visible assistant content ends it. Equal segment IDs authorize bounded cross-message display aggregation; missing or different segment IDs do not. Group IDs derive from the stable assistant presentation ID plus first projected content ordinal. Cold canonical projection deterministically derives the same segment boundary from authoritative conversation input and visible barriers. All lineage is bounded presentation metadata, survives live/canonical/result reconciliation, is never written to Pi JSONL, and never implies parallel execution.
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

The first-party inline Pi extension reserves `notify({message})` and subscribes to Pi's `agent_settled` lifecycle event. A successful final assistant entry queues one product-authored “finished responding” alert only when Pi is still idle, so automatic retries, compaction retries, queued follow-ups, and extension continuations do not announce an intermediate response. The completion entry ID is the durable deduplication source and also keys one bounded RuntimeSlot observation disposition shared with attention state. An exact mobile subscription may publish `session.presentation.set` only after synchronization; monotonically revisioned visible/hidden updates are token-bound, one per connection, removed on close/replacement/disconnect/rekey/delete, and visible leases expire after 45 seconds unless iOS renews them. If that disposition observes an active chat, the extension does not invoke notification enqueue: NotificationService writes only a durable `suppressed` receipt for the completion, creates no relay intent or inbox row, and excludes it from delivery quota. Completion alerts otherwise carry the bounded session title plus the exact Gateway machine/session route; tapping is therefore profile-qualified rather than inferred from whichever server is selected on iOS. The extension receives only narrow enqueue and automatic-suppression closures: the model cannot choose a device, APNs token, environment, topic, relay origin, request ID, priority, badge, payload dictionary, or presentation policy. Admission is persisted before dispatch, expires after fifteen minutes, and returns `queued`, `suppressed`, `rate_limited`, or `unavailable`; APNs acceptance is never described as user delivery. Durable abuse ceilings admit up to 240 intents per session per hour and 480 intents per day globally or per target. Rate-limited attempts are returned synchronously but are not persisted, consume no quota, and cannot extend their own lockout. Preview-disabled grants still replace model-authored `notify` text with fixed generic copy; automatic completion body copy is fixed by Tron rather than the model. The session title is the product-required completion-alert title and is therefore shown independently of that model-text preview flag.

The Gateway also owns a bounded 512-entry user-facing notification inbox in the same owner-only state transaction as delivery admission. A visible `queued` inbox row proves durable admission, not relay or APNs acceptance. New notification content, exact session route, per-target APNs request identities, delivery outcome, and global read state are canonical there; the iOS cache is only a bounded disposable projection. Pre-inbox version-1 documents are admitted without migration loss and gain the optional inbox on their next owned write. `notification.inbox.list` pages newest-first under an exact branch-independent revision/cursor, while `notification.inbox.read` accepts exactly one public inbox ID or APNs request ID and `notification.inbox.readAll` clears all unread entries through ordinary command receipts. Every admission, terminal delivery transition, and read mutation broadcasts `notification.inbox.changed`. Unknown, unavailable, suppressed, and rate-limited attempts create no inbox row. Preview-disabled explicit model text remains generic in both APNs and inbox storage.

Every successfully admitted semantic interaction (`select`, `confirm`, `input`, `editor`, or form) emits one detached input-required callback from the shared `SemanticUIBroker` boundary while that exact interaction remains pending. This includes forms produced by the provenance-checked `@zhushanwen/pi-ask-user@7.0.15` adapter without giving that adapter a second notification path. The generated interaction ID is the durable notification deduplication source. RuntimeSlot samples the same token-bound `session.presentation.set` lease synchronously at interaction admission: an already-visible chat writes only a `suppressed` receipt, with no relay intent, inbox row, or quota charge; a hidden chat queues fixed “Input needed” copy with the exact Gateway machine/session route. Notification failure never delays or fails the interaction. The persisted `notifyWhenAskPresented` field retains its wire name for registration compatibility but governs all semantic input-required alerts. Producer `needsAttention` activity, status text, widgets, retained surfaces, and ordinary runtime phases do not prove a response-capable user interaction and therefore do not trigger this hook.

Authenticated push RPCs are `push.registration.upsert`, `push.registration.remove`, and `push.registration.status`; authenticated notification-resource RPCs are `notification.inbox.list`, `notification.inbox.read`, and `notification.inbox.readAll`. Upsert derives `deviceId` from the connection and accepts only an opaque installation ID, endpoint-scoped grant ID/secret, the exact public relay origin that issued it, and preview/policy booleans; preview disclosure defaults off. Status returns the Gateway-owned relay origin and a bounded rotation requirement. A mobile grant issued by another origin, missing legacy origin identity, or rejected by the relay is never reactivated in place: iOS rotates it through App Attest and transfers the replacement capability. Upsert, removal, and `device.revoke` enter one bounded lane per target device before command-receipt execution, so cross-method invocation order is authoritative while different devices remain concurrent. Revocation disables local push authority before removing the paired bearer; a later admitted upsert revalidates that the device remains paired, and remote revocation retains a bounded tombstone. A grant ID awaiting revocation cannot be admitted as active again: upsert requires rotated endpoint authority, and restart retires any legacy active projection that overlaps a durable tombstone. Thus a delayed revoke can address only the old capability, never a newly active grant. The public relay origin is read from the canonical maintainer-owned `config/PushService.xcconfig`, embedded into both signed products, and must be an exact public HTTPS origin. It is never accepted from tools, RPC, user settings, or runtime environment. Missing development configuration leaves notification delivery unavailable without affecting Gateway readiness; official packaging fails closed.

Outbound relay requests use one fixed `/v3/notifications` route, no redirects, a twenty-second deadline that exceeds the relay's bounded APNs deadline, a 2 KiB request and 16 KiB response boundary, and a lowercase-hex HMAC over method, path, timestamp, stable request ID, and the exact body's lowercase-hex SHA-256. Restart recovery retries transient outcomes with the same request ID. When the relay specifically reports that this ID still owns an active provider attempt, the Gateway polls it through the same bounded retry schedule; the relay ledger returns the eventual terminal result without creating a second APNs request. Unclassified ambiguous outcomes remain terminal and are never blindly replayed. Exact relay `invalid_signature` and `installation_unavailable` errors invalidate that grant without persisting or logging response bodies; mobile registration then rotates the capability instead of retrying an identity that cannot reach APNs. Quotas apply across the installation, canonical session, and target grant.

## Transport

- `GET /health` — unauthenticated readiness and compatibility metadata. The bound listener reports `starting`, `catalog-warming`, `attention-recovery`, or `storage-warming` with HTTP 503 until all startup prerequisites complete, then reports `ok` with HTTP 200; every other HTTP route and WebSocket upgrade remains retryable `busy`/503 during warmup and does not enter session APIs.
- `POST /v1/pair` — rate-limited one-time enrollment exchange
- `POST /v1/uploads` — authenticated bounded upload
- `DELETE /v1/uploads/:id` — authenticated discard of unclaimed client staging; prompt-owned attachments fail closed
- `GET /v1/uploads/:id` — authenticated stream for a prompt-owned canonical attachment
- `GET /v1/blobs/:id` — authenticated transient projected blob
- `GET /v1/sessions/:sessionId/display-artifacts/:id` — authenticated, session-authorized immutable display artifact with single-range resume/streaming
- `GET /v1/socket` — authenticated protocol version 4 WebSocket

The first-party reserved `display` tool advertises `display-artifacts.v1` and persists one ordinary `tron.display.v1` tool result in canonical Pi JSONL. The result carries bounded title, caption, alt/fallback text, semantic content kind, requested `sheet`/`inline`/`floating` surface, and an opaque artifact or public HTTPS URL reference—never workspace paths, bytes, credentials, cookies, dimensions, or screen coordinates. Gateway validates the closed shape into a typed transcript field before mobile rendering; malformed or non-`display` lookalikes remain ordinary tool output. Project sources are visible paths relative to the trusted session workspace, reject hidden/private components, traversal, and symlinks, open with no-follow semantics, are copied while hashing, and must preserve descriptor identity through publication. Magic/container signatures and UTF-8 validation fail closed for recognized types. Public URL display is credential-free HTTPS, rejects query/fragment persistence, local DNS suffixes, and local, private, reserved, link-local, or multicast IP literals; Gateway does not fetch or proxy it.

Display bytes live under a separate durable Gateway store owned by `RuntimeRegistry`, not transient `BlobStore`. Random logical IDs reference immutable SHA-256 objects; logical session-owner links survive restart and are granted to a fork before its identity commit. Canonical display-result handoff and runtime binding reconcile session ownership against the complete JSONL tree, removing cancelled/provisional publications without deleting artifacts retained on reversible abandoned branches. Session deletion and catalog maintenance remove owner links, while shared objects remain until the last owner and active reader release them. The store bounds item/type bytes, logical bytes/count, concurrent ingestion/readers, owner fan-out, and a 1 GiB filesystem floor. Retention ownership alone never authorizes a read: the requested ID must also occur on the exact active canonical branch, so abandoned branches and deletion races fail closed. Downloads support one inclusive byte range, return 416 for malformed or unsatisfiable display ranges, honor a stable immutable ETag, send `nosniff`, and never enter WebSocket snapshots. Unknown, missing, or corrupt objects remain explicit unavailable displays with canonical text fallback rather than being regenerated.

The pairing limiter keeps the exact rolling per-address window while retaining at most 4,096
least-recently-used address keys and periodically deleting expired windows; address churn cannot
create append-only process state. Paired-device storage admits at most 256 unique device IDs and
token hashes with bounded names/timestamps; capacity rejection leaves the one-time invitation valid
so an old device can be revoked before retrying. Device metadata is capped at 1 MiB, the local wrapper
credential at 4 KiB, and the one-time invitation at 16 KiB before JSON decode. Local credentials and
invitations also require owner-only regular-file boundaries (symlinks are rejected), exact versions,
purposes, bounded identities/codes, and canonical timestamps. A pairing invitation is consumed before
its device record is written; a failed device write explicitly issues a fresh invitation while the
pairing mutex remains held. Uploads retain the 25 MiB per-request/prompt limit. Active and unclaimed
staging has its own 1,024-entry and eight-times-per-upload (200 MiB by default) quota; claimed canonical
history does not consume that quota, so older sessions cannot starve a new draft. Retained ownership is
separately bounded to 16,384 logical entries and 400 GiB of logical bytes by default; those retained
limits are checked only when a prompt claims staging, never while a user is still attaching a draft.
Every body reservation and temporary session-import copy conservatively preserves a 1 GiB filesystem
free-space floor, and every import copy is owned by a release lease so success and failure both remove it. A separate admission permits at most half the staging ratio
concurrently (four default 25 MiB bodies).

Authenticated chunks stream directly into protected staging files while computing SHA-256. Commit
atomically adopts one immutable, sharded content-addressed object and hard-links the stable logical UUID
path to it. Exact duplicate bytes therefore occupy one physical object while filename, MIME type, prompt
ownership, and public `upload:<uuid>` identity remain logical metadata. Version-1 UUID folders migrate
in place during ordinary startup/maintenance inventory: the Gateway stream-hashes the existing file,
creates or adopts its object, atomically relinks the stable path, writes version-2 metadata, and keeps the
legacy path readable throughout. The migration is restart-idempotent; ordinary version-2 inventory checks
inode/size ownership without rehashing every retained object. The first read verifies a digest once per
process and caches that immutable-object proof; each maintenance pass rotates through one additional bounded
integrity audit. A failed digest retains logical/canonical metadata, marks the object unavailable, and fails
reads explicitly rather than silently dropping history. Orphan objects and malformed shards are removed only
after logical inventory is reconciled.

Exact declared and observed sizes are checked before atomic metadata publication. Persisted logical
metadata remains limited to an exact 64 KiB canonical document; malformed or oversized entries self-clean
during startup inventory or direct materialization. Ordinary upload admission and periodic maintenance use the rebuildable in-memory
attachment index rather than reparsing retained history; only the at-most-1,024 unclaimed set is checked for expiry on each admission. Every rejection, overflow, truncation, or disconnect
removes uncommitted staging and releases its reservation. An authenticated client may immediately discard
an unclaimed upload when its local chip or presentation is retired; claimed prompt attachments reject that
operation. Remaining unclaimed uploads expire after 24 hours. Prompt attachment IDs are unique, and one
prompt cannot materialize more than the per-prompt byte ceiling. Startup performs the one physical inventory,
legacy migration, integrity/ownership reconciliation, and orphan-object sweep. The ten-minute pass then removes
stale bodies, expires indexed unclaimed files, retries pending cleanup, and removes claimed logical references
only when the canonical session catalog proves their owner no longer exists; it does not rescan every retained
metadata file. A later process start can always rebuild the disposable index from physical metadata.

`uploads.status` v2 exposes staging/claimed logical counts and bytes, unique object count/bytes,
deduplicated bytes, staging headroom, filesystem headroom/floor, pressure state, active body/import admissions,
unavailable objects, and cleanup backlog—never IDs, session IDs, paths, names, digests, or MIME data. Capacity failures identify
`staging_entries`, `staging_bytes`, `retained_entries`, or `disk` and include only bounded actionable
capacity facts. Publication fsyncs object/metadata files and their parent directories after atomic
link/rename boundaries, so acknowledged uploads are durable across power loss rather than merely process crashes.
The local-only retained tier remains subordinate to canonical session deletion; true
external/remote cold offload is intentionally deferred until an operator-owned destination and
lease-protected document rehydration contract exist. Mobile projection derives the
opaque upload identity from the validated store-owned canonical path, strips that private path, and
exposes the identity solely as an authenticated preview route; no extra identifier is added to the model
prompt. Unclaimed staging is never readable, while a prompt-owned file streams from its already-open
descriptor with its exact declared size and MIME type.
Successful imports remove
their staging folder; deleting a canonical session removes its claimed attachment folders. Cleanup
failure after canonical import/deletion success cannot turn that success into an ambiguous command receipt;
failed session-folder cleanup remains pending in the live store and periodic canonical-catalog maintenance
recovers it after process restart. Transient image blobs retain their 25 MiB item, 128-item, and 200 MiB aggregate
bounds; exact content deduplicates and access refreshes 30-minute idle expiry. Session archives use a separate protected,
file-backed export store because their capacity is unrelated to media admission. It admits one disk-reserved generation,
four readers, eight retained artifacts, 2 GiB per artifact, and 4 GiB aggregate, with a 64 MiB filesystem floor checked before copy/registration. Export registration and authenticated
HTTP delivery remain streamed with backpressure, support a single `bytes=start-end` range for bounded resume, and never retain a complete archive `Buffer` in Gateway memory.

An export captures one newline-terminated canonical descriptor/byte-length cut while briefly serialized with the live
runtime, then copies exactly that immutable prefix outside the session lane. Later appends therefore continue normally
and are excluded deterministically. A first-turn session whose Pi JSONL has not yet been created uses the runtime owner's
public append-only header/entry projection for that cut. JSONL preserves the complete canonical tree verbatim, including
abandoned branches and parent identities. HTML renders the captured active branch through Pi's documented standalone
export command in a child process, isolating the pinned renderer's current whole-document memory work from the Gateway
event loop. The response includes the exact generated size and advertises `session-export.v2`; older clients retain the
legacy 25 MiB download path. Active downloads survive pruning; expired IDs admit no new readers, and physical capacity
releases after the final reader. A requester disconnect does not alter the already captured cut: admitted generation remains
single-flight, HTML rendering retains its 15-minute kill bound, and any unclaimed completed artifact expires normally. Startup scavenges both disposable stores only after the Gateway binds successfully.
Capacity admission never evicts an ID already published to a client: excess projected images become bounded omission
text, while later requests can retry after expiry. Blob storage rejects control-bearing MIME metadata. Blob downloads
advertise byte ranges; malformed or unsatisfiable multi-range requests fail closed.
The retired `/engine` protocol is not exposed.

Gateway updates are an explicit, bounded control-plane contract. Rebuild, update,
rollback, promotion, and restart mutations are user-initiated operations: repository
agents and automation may prepare and validate source or artifacts, but must not submit
those RPCs or run a mutating Gateway lifecycle helper. The user or maintainer performs
the confirmed action that transitions the running Gateway. `gateway.update.status`
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
changes does the bounded startup deadline begin. Readiness requires one different PID/start
identity stable across an authenticated exact fingerprint/revision/epoch probe. Normal candidate
startup belongs exclusively to launchd; listener absence cannot authorize a kickstart because a
live startup process may not have bound yet. Candidate startup uses the launcher's atomic
attempt/commit marker. After the candidate deadline, recovery restores and revalidates the prior
selection under that marker's lock, then conditionally kickstarts and verifies the restored payload
directly; it never depends on RPC to the failed Gateway.
Debug handoff is exposed as Debug
origin only when its bounded provenance (candidate version/fingerprint, tested Debug fingerprint,
source revision, tested runtime epoch, and candidate runtime epoch) matches the verified Stable
candidate manifest. Generic automatic/source updates never infer a Debug-origin candidate from
state; promotion must pin its exact candidate version and fingerprint.
`gateway.update.config.status` and `gateway.update.status` are bounded projections; the latter
includes build/staging/draining/promotion/rollback/failure progress. The mutation is usable only when the helper is
configured, in which case `gateway-update.v1` appears in capabilities. Candidate transition health uses a 60-second default deadline; an owned decimal-millisecond override is admitted only from 2,000 through 300,000 milliseconds.

A separate supervised macOS control plane advertises `ios-device-install.v2`. Receipt-backed `device.install.config` binds one authorized Gateway device to a validated Tron source checkout; it never accepts a physical target from the client. At install admission the Mac runs bounded `xcrun devicectl` discovery and reuses an owner-only exact CoreDevice binding when available. Otherwise it binds only when exactly one Developer Mode physical iOS device is eligible, failing closed and asking the user to disconnect other devices rather than guessing by Gateway device ID or display name. CoreDevice identifiers, serials, UDIDs, and complete discovery documents remain owner-only Mac state. The per-device configuration is stored under `gateway/ios-device-installs/` with mode `0600`; source roots must be absolute, symlink-free directories containing the canonical iOS project, pinned-toolchain configuration, fixed install helper, artifact validator, and protocol validator. Config/status reads revalidate paired-device authority and never accept an executable, scheme, build configuration, bundle ID, CoreDevice identifier, or arbitrary command from RPC.

`device.install` admits only the paired-device ID plus command ID, serializes one Mac-wide install, and launches an immutable Gateway-bundled helper detached from the initiating socket. That helper re-reads owner-only configuration, revalidates the source and physical target, and invokes only `scripts/tron-ios-device install --device-id <owner-bound target>`. It passes the absolute fingerprinted XcodeGen executable from the active signed payload; the source checkout's cache and launchd `PATH` are not runtime dependencies. The script requires the canonical pinned version, fixes `Tron Device` + `LocalDevice`, rejects Release/DevicePerformance, validates development signing and the exact Gateway protocol contract, overwrite-installs without uninstalling, and relaunches the app. Stable-channel installs remain Mac-first and verify `/Applications/Tron.app`; Debug-channel installs use the explicit source protocol target. `device.install.status` is the bounded reconnect-safe authority for requested/running/succeeded/failed state. Generated multi-line tool output is normalized before persistence and legacy generated multi-line failures are admitted through the same bounded sanitizer, so a failed build cannot poison later status/config reads. Dispatch acknowledgement does not claim completion. A two-hour helper deadline and owner-only active record prevent overlapping Xcode builds; Gateway update, rollback, and restart admission are mutually exclusive with an active iOS install, and revocation removes the device's source/target mapping. No Stable Gateway transition, production archive, App Store upload, or automated production deployment is part of this path.

Every WebSocket starts with:

```json
{"type":"hello","protocolVersion":4}
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
Outbound WebSocket admission keeps the 1 MiB encoded-frame ceiling and an 8 MiB per-connection aggregate queue ceiling. A connection-local ordered writer hands exactly one frame to the WebSocket implementation at a time; enqueue acceptance is the response/event ordering boundary, so a response remains ahead of its synchronization suffix while concurrent startup catalogs cannot manufacture `bufferedAmount` pressure. The queue includes its active frame, clears on disconnect, and closes with `1013` only on true aggregate overflow. Asynchronous write failures are logged and terminate that exact connection. Each socket also owns abort controllers for in-flight requests: disconnect releases disposable `session.list` waits immediately while the coalesced canonical materialization may finish for another caller; accepted prompts and durable mutations never inherit socket cancellation.
The gateway sends WebSocket ping control frames every 25 seconds and terminates
only after three consecutive unanswered rounds, so half-open Tailscale/iOS paths
are observable without allowing one delayed timer or transient callback stall to destroy a healthy epoch. Pong, ping, and application frames all reset the consecutive-miss counter; mobile clients issue transport-level pings every ten seconds from a liveness task that does not depend on application event reduction. Inbound event traffic therefore cannot starve the client-activity proof. Heartbeat timeouts include the disposable connection ID and miss count, and heartbeat timer drift of 25 seconds or more emits bounded event-loop-delay telemetry. WebSocket close codes/reasons remain credential-free so transient transport failures are diagnosable. Reconnect and foreground activation converge through an authoritative
snapshot. `session.summary` is a bounded, per-session revisioned global projection
of aggregate phase, narrow foreground phase, active-subagent presence, pending-user-input state, name, activity time, message count, and first-message title. Pi's pre-append `message_end` boundary invalidates cached canonical row facts and schedules their post-append publication, so a new session exposes its first-prompt title while the initial response is still running rather than waiting for a Gateway restart. Live activity time overlays the canonical tail with foreground agent events, detached extension lifecycle observations, and a ten-second heartbeat while either remains active; administrative receipt persistence does not make a row active. When detached subagents outlive the parent response, aggregate `phase` remains active while `foregroundPhase` is settled and `hasActiveSubagents` remains true, allowing shallow dashboard clients to present delegated work without opening the transcript. `waitingForUser` is orthogonal to those phases and transitions immediately with the first pending semantic interaction and final settlement, so dashboards can identify that only a user response can advance the session. The additive `activeSince` fact is fixed for one continuous Gateway-observed active period, so catalog ordering keeps active rows first and stable while `updatedAt` continues to advance for truthful freshness labels. Settled history remains reverse chronological by parsed instant rather than ISO text precision, and Gateway restart naturally falls back to canonical persistence time. Summary updates reach every connected
dashboard immediately without broadcasting full transcripts or changing the structural list revision; clients subscribe
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
Tool lifecycle state is a disposable overlay, not a second transcript: Pi 0.84.1's ordinary
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
enter that owner and are not cancelled by foreground Stop.
Extension commands are resolved before ordinary streaming rejection and still execute through
Pi's prompt path. The explicit extension adapter registry identifies only the pinned
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
non-overlay blocking custom call and uses a real public pi-tui 0.84.1 keybindings
manager; the production RPC host rejects blocking custom calls before invoking
extension factories because no native client surface exists for them. Overlay
custom calls fail closed before factory invocation with one bounded
deferred diagnostic and publish no overlay surface. Component input, arbitrary custom
UI, native custom/overlay rendering, footer/header/editor/autocomplete, theme UI,
renderer hosting, package-specific integration, and truthful TUI activation remain
deferred.

Live and canonical transcript projections preserve the canonical tool name while optionally carrying the bounded human-readable `label` declared by the mounted Pi extension tool definition; native clients use that label for presentation and never derive extension titles from snake_case names. Project Resources exposes the same label beside the canonical name. Live tool projections may also carry an optional extension provenance record derived from the public Pi tool `sourceInfo` and the loaded extension inventory. The Gateway emits that record only when exactly one extension owns the tool and the source path agrees; unknown or ambiguous ownership omits provenance and fails open to the ordinary tool projection. This metadata is disposable presentation state and never modifies Pi JSONL.

Every canonical `custom_message` is context-bearing input under Pi semantics. Producer-visible messages project as right-aligned inbound context; producer-hidden messages remain absent from ordinary chat. At the exact Pi message boundary, Gateway captures owner identity from the wrapped extension callback and whether the message was stored for a later turn or delivered during active work. Pi exposes stored custom messages after their canonical append and turn-triggering messages immediately before it; the Gateway binds the exact canonical tail identity at those respective lifecycle boundaries and appends a bounded `tron.context-delivery.v4` receipt targeting that entry. It never scans forward for an unowned payload candidate. Receipts may follow later branch entries, so projection validates exact target identity and target-before-receipt branch order rather than current-leaf adjacency. Text, title, custom type, timestamps, details, and renderer registration never infer producer identity or delivery. Canonical `custom`/`appendEntry` state remains available to extensions but is omitted from chat and tree projection unless it is a validated Gateway invocation-start receipt; validated extension-notification receipts are promoted only into the chat timeline and never become navigation nodes. When an extension-owned tool returns the public structured delegated-run convention (`details.runId`/`asyncId` plus bounded `results[].progress`), the Gateway additionally projects `ExtensionRunActivity` with stable child identities, active time, tool/turn counts, current tool/path, and a bounded output tail. It is carried on the live tool projection and retained as a bounded recent `extensionActivities` snapshot; native clients must not infer it from rendered widget text or open a child JSONL concurrently. The runtime also admits the explicit `pi-subagents` lifecycle-artifact contract: allowlisted `status.json` files are matched to the canonical session file, read with a hard byte bound, and projected as one workflow activity with bounded child progress so detached async runs remain visible after the launching tool returns. Temporary runtime roots and the project-local `.pi/subagents/async-subagent-runs` layout are scanned under one hard work budget; exact live `asyncDir` bindings refresh before bounded ambient enumeration, and terminal ambient evidence outranks decorative live enrichment. A bounded Gateway-owned `runId` binding maps lifecycle events and artifacts to one real tool-call identity; a synthetic `subagent:<runId>` identity is used only for an initially unmatched, session-owned artifact and is re-keyed when the real tool call arrives. Terminal lifecycle status is authoritative, while later artifacts only enrich retained details and cannot resurrect a completed run; terminal recency uses the producer's completion time rather than the later discovery time. Current artifacts are admitted by their exact schema version; historical versioned or unversioned artifacts can supply terminal evidence only after an exact canonical tool-call/`asyncDir` binding proves ownership, so a Gateway reload cannot strand already-finished delegated work in restart drain. Watchers stop on terminal state, disposal, and retention eviction.

Remote restart is advertised only when `TRON_GATEWAY_SUPERVISED=1` is present from a managed LaunchAgent or repository background supervisor; direct foreground processes fail closed for remote restart. Planned restart exits with code 75 only after the registry drain completes. A handled signal in a supervised runtime also exits 75, while an ordinary foreground signal remains a clean exit; process replacement belongs to the supervisor.

Extension callbacks are wrapped through the public `DefaultResourceLoaderOptions.extensionsOverride` seam on every load and reload. An AsyncLocalStorage owner (an opaque SHA-256 identity derived from stable source/path provenance, a generic humanized title, and exact `sourceInfo.source`) follows handlers, tools, commands, renderers, promises, and timers. Raw extension paths never enter owner IDs. The semantic broker records optional widget owners and per-key status owners; rendered component surfaces retain only exact source provenance. Callbacks that originate outside a wrapped owner context—such as a package-owned long-lived timer created during extension initialization—remain ownerless rather than being guessed, and protocol owner records are bounded at the store and native admission boundary.

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

Active message queues are projected with stable per-entry IDs, delivery behavior,
display text, total attachment count, optional photo/file counts, optional bounded upload descriptors,
and a monotonic queue revision. Descriptors contain only upload/blob ID, safe name, MIME type, and size;
attachment bytes remain in the owned upload store and are fetched only through authenticated blob access.
For newly admitted steering/follow-up work, the returned prompt operation ID is the queue entry ID;
clients can therefore settle one optimistic submission without content-based queue guessing.
A Gateway advertising
`queue-management.v1` includes both `queueRevision` and `queuedItems` in every authoritative
session snapshot. The pinned Pi 0.84.1 queue itself still exposes string arrays rather than
queue records. RuntimeSlot therefore retains the exact admission ID before accepting another
queued mutation, publishes it from the same serialized lane, and treats later text arrays only
as bounded live-runtime delivery evidence. A Gateway process restart does not replay or claim
identity for an SDK-only queue; reconnect must report only surviving canonical/runtime truth.
The legacy steering and follow-up string arrays remain a compatibility projection for older
clients and Gateways; they never authorize entry-level mutation.
`session.queue.replace`
serializes with prompt admission and clear operations, validates bounded replacement
state, rejects stale revisions, and rebuilds the pinned runtime queue atomically.
Steering entries always precede follow-ups because that is the runtime's delivery
order; reordering is authoritative within either behavior, and changing behavior
moves an entry into the corresponding delivery stage. Attachments remain bound to
their original queued identity and cannot be fabricated by clients. Queue snapshots
are bounded to 32 entries, 64 KiB per display message, and 256 KiB total.
Prompt RPC admission follows the pinned runtime's preflight callback as its sole outcome.
Because Pi 0.84.1 can clear its streaming flag before the final `agent_settled` choreography reaches
the Gateway, ordinary admission additionally waits behind the existing sequenced foreground operation
owner whenever runtime streaming is false but settlement/compaction/retry state is still active. The
Gateway re-evaluates delivery behavior after that transition and never invokes an ordinary Agent prompt
inside the settlement gap. It does not race preflight against a local deadline that could report rejection while
the same uncancelled runtime call later starts canonical work. While the canonical user
entry is pending, the snapshot's bounded `pendingPrompt` projection carries the display
text and requested delivery behavior. The Gateway claims the exact Pi user-message object,
retires the projection only for that same message at persistence, and exposes the prompt
operation ID as the canonical user's bounded `presentationId`; repeated text therefore
cannot settle the wrong mobile admission. A known operation ID never falls back to content matching on
iOS. `session.operationFailed` is reserved for an exact operation proven unable to produce canonical
input; only that sequenced fact may retire and restore its matching composer admission. Receipt,
binding, and post-admission runtime failures emit non-settling `session.diagnostic` events instead of
lying about accepted execution. Definitive transport rejection/no-agent settlement clears
the same owner, so iOS can reconstruct an in-flight prompt across navigation without replay.

Manual compaction has a separate Gateway-owned single-entry maintenance admission. Its
synchronous claim covers pending, direct, and queued execution, so a second request is rejected
rather than serialized behind the first. An idle request starts canonical compaction immediately.
A request accepted during an active agent run publishes `compactionQueued`, retains the run marker,
and keeps its command receipt pending until the exact compaction starts after final `agent_settled`
and completes or fails. Handoff revalidates that no newer agent run owns the session, and queued
completion awaits durable marker removal before publishing settled. Every successful or failed
`compaction_end` publishes one immediate fitted authoritative snapshot with the current canonical
tail/leaf and restored prompt/automatic-idle state; manual work remains compacting until its durable
marker retires. The compaction operation identity is retained on the projected canonical compaction
entry as presentation-only metadata, so compacting and compacted content occupy one physical row even
when bounded transcript ranges change precision. Hooks may append after the compaction entry, so
the Gateway does not spend a cursor on a single-entry delta that is already a non-leaf.
Gateway shutdown synchronously
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
Provider authentication admits at most eight operations globally and two per
authenticated device identity. Each operation has a 15-minute Gateway-owned lifetime, so providers that
ignore abort cannot retain broker capacity; completion, failure, explicit cancellation,
device revocation, Gateway shutdown, and timeout retire exactly once. A WebSocket disconnect
only detaches event delivery: `auth.resume` rebinds the same stable-device-owned operation to a
replacement connection and replays its latest bounded event/prompt or terminal tombstone. Current
clients send a `commandId` with `auth.begin`; a bounded in-memory admission receipt returns the
same operation for an uncertain duplicate without claiming that login completed. Provider prompt/event projections
are limited to 128 KiB before broadcast, and late callbacks from retired operations
are inert. Bounded 15-minute tombstones make duplicate or reordered
`auth.respond`, `auth.callback`, `auth.resume`, and `auth.cancel` requests harmless without retaining prompt values.

For phone browser OAuth, the Gateway derives an optional callback descriptor only from Pi's
provider-authored `auth_url` (`redirect_uri` or `callback_url`) and only for explicit HTTP loopback
hosts. iOS may answer Pi's existing `manual_code` prompt with the complete captured redirect. For
providers such as Radius without that prompt, `auth.callback` accepts only the operation/callback ID
and bounded query: the host, port, and path remain Gateway-retained, exactly one authorization code or
provider error plus unambiguous state is required before a fixed no-proxy loopback GET reaches Pi's
already-listening callback server, and neither callback data nor
response bodies are logged, persisted, or returned. Pi remains the sole state/PKCE, token exchange,
refresh, and credential-storage authority.
`session.list` and `model.list` are cursor-paginated so Pi catalogs remain
complete without exceeding bounded gateway frames. Workspace browsing streams directory entries
from an identity-checked directory handle and fails visibly, without returning a partial listing,
above 1,000 examined entries or 768 KiB of projected metadata; ordinary folders retain the established directory-first
ordering and exact paths. Package inventory and update projections reject duplicate stable
identities, more than 256 packages/updates, more than 1,000 resources of any kind, strings above
8 KiB, or encoded responses above 768 KiB before generic JSON projection can truncate them. The bounded JSON projector tracks only the active recursion path, so shared Pi metadata objects are expanded for each sibling resource while true cycles remain marked and bounded. Pi's configured `sessionDir`, or its
canonical per-workspace directories under `agentDir/sessions`, remain authoritative; Tron does
not move or mirror those files. `session.list` defaults to user sessions, while `scope: "all"`
additively includes delegated children through one positive pi-subagents topology contract. The
only delegated identities are canonical JSONL files at exactly
`<canonical-parent-stem>/forks/<fork-session>.jsonl` or
`<canonical-parent-stem>/<producer>/run-N/session.jsonl` inside the canonical catalog. Extra path
components and alternate basenames are not delegated topology. This reservation is authoritative even when the parent file was deleted or its embedded ID
is ambiguous. An optional header may bind `parentSessionId` only when it names the exact parent path
derived from topology. A contradictory header remains mutation-protected but fails closed and is
omitted rather than becoming a user row. The same classifier owns list, acquisition/open, and delete
decisions. Ordinary top-level forks—including parented, unnamed snapshots and names beginning with
`subagent-`—remain user sessions, as do arbitrary deep files outside the two reserved producer shapes.
No session name/title, `session_info`, transcript text, timestamp ordering, generic directory depth,
or transcript-tail read participates in classification or structural evidence. Existing top-level
files created by older subagent producers have no runtime compatibility inference and require
explicit pre-deployment disposition. They are not silently migrated or deleted. The Gateway does not
rename, delete, or otherwise mutate `~/.pi` as part of that disposition. If more than
one canonical file claims the same embedded session ID, the Gateway omits every ambiguous copy
and rejects open/delete by that ID until the duplicate is repaired; traversal order never chooses
canonical ownership. A newly created session has no canonical Pi JSONL until Pi records its first
assistant content; a retained user-only fork is deferred by the same pinned persistence policy. While the
Gateway owns that bounded live runtime slot, `session.list` projects one runtime-only empty user row with
its stable slot-creation time, cwd, phase, and revisioned summary fields. A fresh fork whose retained branch
has not produced an assistant entry additionally projects the exact pre-fork
session ID as `parentSessionId`, so dashboards classify it immediately without inferring from paths or
fabricating a row. If the new JSONL joins a warmed structural cut before its normalized parent alias, that
same mutation-owned ID bridges only the live transition; cold catalogs derive the relationship from canonical
header/path evidence. That row is visible to every connected dashboard and remains directly openable/deletable,
but it is not a second session store: idle slot retirement or Gateway restart removes it if Pi never persisted
content. Once Pi creates JSONL, the canonical row replaces the runtime-only projection under the same ID
without duplication.
Before materialization, recursive discovery streams at most 50,001 directory entries,
retains at most 25,001 canonical directories/8 MiB of traversal paths, and admits at most 25,000 session
records/8 MiB of retained metadata; overflow fails retryably without publishing a partial catalog. The pinned
Gateway performs its own bounded direct-directory JSONL metadata scan for catalog rows, so catalog discovery does not construct the SDK's unused transcript-wide picker search text. The first complete structural read after startup or an uncertain canonical mutation uses this scan. Gateway then retains one bounded normalized disk index containing only canonical identity/classification metadata—never transcript text—and revalidates it with bounded header evidence. Later `session.list` traversals dynamically overlay live-only slots and revisioned summaries without rebuilding transcript-wide picker text. Empty live-slot create/delete updates preserve the warmed disk index, and a confirmed persisted delete repairs it from post-delete header evidence. Canonical path normalization runs with at most 16 concurrent filesystem operations.

`RuntimeRegistry` separately retains only a bounded acquisition admission: canonical header ID/path/cwd, structural user-versus-subagent classification, the atomic ambiguous-ID set, and a fixed-size digest. It never retains transcript text or a second canonical catalog. The normal cold-acquire path uses an independent mutex and builds or validates this admission from canonical JSONL membership, canonicalized paths, and bounded header ID/cwd/parent evidence, without waiting for transcript-wide catalog materialization. A warmed structural index supplies the same admission without another SDK scan; exact header evidence and the selected manager's ID/cwd are still revalidated before runtime resources load. Ordinary message/tool appends do not change the digest. Additions, removals, aliases, duplicate identities, or same-path header identity replacement do. A malformed file under the reserved `subagent-artifacts` diagnostic subtree is ignored as a non-session artifact and cannot poison evidence completeness. Malformed files in canonical session locations still fail closed. Stable generic header/acquisition-budget incompleteness may fall back to the independently bounded full metadata scanner for that one list response, but cannot certify a reusable structural index, durable sidecar generation, or runtime acquisition. An observed non-newline or changing canonical file is a distinct unstable condition and makes list fail retryably, except that append-only tail growth of the exact inode currently owned by a live RuntimeSlot is permitted; cold, unowned, replaced, symlinked, duplicate, or header-rewritten files remain strict. Incomplete lightweight acquisition falls back, without holding the acquisition mutex, to two matching Gateway-scanned fingerprints over the full normalized canonical identity set. That one-off result is not cached and its exact identity fingerprint is validated again immediately before runtime creation. Directories named `*.jsonl` are not file candidates.

The exact opened manager must still reproduce the admitted ID and canonical cwd. Normal complete-header acquisition runs a second bounded structure/header comparison after manager open and before runtime resources load; fallback acquisition instead repeats its full SDK-derived identity validation. Changes reject retryably, while the unavoidable cross-process race after that final validation point is not presented as eliminated. Header validation starts with 512-byte reads, runs in deterministic batches of at most 16 files, permits at most 64 KiB per candidate with a strict shared 64 MiB aggregate budget apportioned across the candidate set, and inserts at most 25,000 identities/4 MiB into transient or reusable evidence. Validation reads only the canonical session header; later `session_info` and transcript appends do not change the structural digest. Gateway-owned mutations are generation-checked before and after every lightweight build and again immediately before a full catalog identity is published. Mutable summary/attention overlays are captured only after structural materialization, so heartbeats cannot starve a list projection. Delete admits only the hardened structural identity/path/cwd/classification record and revalidates its structural digest and user classification immediately before inode-safe quarantine, so a new parent file, duplicate ID, or topology change cannot commit stale deletion. An unstable lightweight scan or full list retries once and then fails retryably without publishing stale evidence. Hot slots not marked ambiguous by the latest full catalog bypass global header validation; known ambiguous IDs continue validating until duplicate repair is observed. Same-session cold opens share one startup, while distinct session starts reserve capacity atomically and perform manager/runtime initialization outside the registry-global publication mutex. Creation uses the same short reservation boundary, so one slow project resource loader cannot serialize unrelated starts. Administrative drain and shutdown wait for already-admitted starts before snapshotting runtime ownership. Thus idle resume normally avoids a transcript-wide catalog parse while JSONL and the pinned manager remain canonical. Startup binds the HTTP listener before RuntimeRegistry recovery begins. RuntimeRegistry loads the bounded durable attention/marker inputs while health remains `starting`, performs one bounded structural evidence cut (`catalog-warming`), then reconciles attention and interrupted markers from that same cut (`attention-recovery`); blob storage follows as `storage-warming`. Only after all three phases succeed does GatewayServer publish `ok`. Catalog validation, SDK materialization, target manager open, runtime creation, attention resolution/persistence, and startup attention reconciliation are separately timed with privacy-safe stage records; they report only method/stage, outcome, and duration and never log IDs, paths, prompts, or parameters. Runtime snapshots reuse exact statistics/context and latest-cache derivation for an unchanged runtime revision, then invalidate naturally at canonical event, branch, compaction, or rebind revisions.

Interactive cold opening has one remaining dependency boundary: pinned `@earendil-works/pi-coding-agent` `SessionManager.open()` synchronously parses and retains the complete JSONL before runtime construction. Gateway deliberately does not bypass that owner with a transcript mirror, private-field hydration, or a `node_modules` patch. History-length-independent opening requires an upstream public SDK seam that opens asynchronously through one validated descriptor, restores the current leaf and active context from a compaction checkpoint plus indexed suffix, exposes seekable canonical transcript/tree reads, and invalidates disposable offsets on inode/size/mtime/boundary disagreement while preserving the existing canonical append/migration semantics. Until that seam ships in a pinned dependency, listener/catalog readiness is bounded as documented above, but a first cold open can still scale with the selected file's complete history.

Every session-list traversal is one
immutable, disposable catalog materialization: every page carries the same structural `listRevision`, and its authenticated opaque cursor
is bound to the connection, scope, materialization, offset, and revision. RuntimeRegistry supplies a disposable page-source generation for indexed catalog cuts; the pagination store leases that source and hydrates requested pages, while preserving the older full `catalog()` API for internal snapshot owners. Single-page results are not retained as generations. A Gateway-owned `gateway/catalog-metadata-v1.json` acceleration file may persist only bounded identity/summary metadata, canonical file identity, size/mtime/EOF, and a fixed tail-boundary hash. It is versioned and root-bound, written through a 0600 temp-file/fsync/rename/directory-fsync transaction, and is discarded on any schema/root/inode/size/mtime/boundary mismatch; JSONL remains authoritative and persistence failure degrades to the canonical in-memory projection. The current query builds one bounded compact seed source, sorts it once, and hydrates only the requested offset page; canonical JSONL remains authoritative and true keyset indexing remains a later phase. Traversal
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
catalog mirroring. Membership is resolved against the exact structural/acquisition admission outside the serialized attention lane. The commit boundary rechecks deletion and generation, takes fresh bounded catalog identity evidence, and verifies the selected inode/header; this remains a whole-catalog header cost until durable indexing replaces it, but no transcript metadata materialization occurs beneath the lane. A bounded atomic `gateway/session-attention.json` document
stores only completion/read-through revisions, a manual-unread flag, a bounded
recent-completion deduplication set, and a restart-reconciliation cursor. Only an
accepted prompt turn's canonical assistant entry ending with Pi `stop` or `length`
at truthful agent settlement advances completion; generic idle, compaction,
abort/error/deferred output, runtime close, and intermediate tool-use messages do
not. A private per-session marker document retains at most 16 accepted operation
records and their exact canonical completion stamps using synced file-and-directory
replacement; a full document rejects newer admission rather than dropping evidence.
Legacy v1 single-operation markers migrate on mutation without inferring an unstamped
completion. Marker creation and exact stamping run independently of serialized
attention admission, so a failing older projection cannot hide a completed extension
continuation. Assistant `message_end` captures its operation owner in the
callback turn before Pi's synchronous canonical append; an extension continuation
that starts inside the append/microtask gap therefore rotates to a distinct owner
instead of inheriting the completed turn. Terminal stamping atomically reasserts
that exact owner with completion evidence in one per-session marker transaction,
so overlapping turn cleanup cannot erase newer work. A conflicting completion
claim for an already-stamped operation is permanent and fails immediately while
ordinary storage failures retain durable retry, preventing that impossible claim from indefinitely
blocking later prompts, `session.open`, or administrative drain. Cleanup remains
scoped to that operation ID. Open/drain
joins live settlement; after restart, a bounded canonical JSONL scan admits every
successful completion named by the ordered exact durable stamps, and no markerless
or temporal completion, before advancing its cursor. Catalog rows and
revisioned `session.summary` events project
`completionRevision`, `attentionRevision`, and `isUnread` without changing
structural `listRevision`. `session.attention.set` uses ordinary command receipts and returns the complete
monotonic attention projection; when a cold row has no retained live summary,
Gateway emits a list invalidation rather than fabricating a summary event.
Mark-read carries the exact rendered completion revision so a racing newer
completion stays unread. A live completion whose shared disposition observes an
active mobile presentation advances completion and read-through together in one
durable attention replacement, clears manual unread, and publishes no transient
unread summary. Successful `session.open` returns its current completion revision,
and first-party clients acknowledge it only after installing the snapshot and
retry transient acknowledgement failure against that same absolute revision.
Protocol-v4 clients require the complete attention and presentation contract;
they do not attach to an earlier Gateway that lacks the method or revisioned
response.
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
ordinary text part and never sends the Mac path to clients. Protocol-v4 clients therefore receive the safe filename instead of the
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
duplicate or malformed canonical entries and oversized retained metadata strings. Producer-authored
compaction and branch summaries may exceed one tree field because Pi owns their canonical context;
`session.tree` validates their shape and emits only the existing 240-character bounded preview.
Omitted older parents are valid because the bounded outline is not a canonical mirror.
`session.commands` preserves runtime sort order and rejects catalogs above 1,000 rows
or 700 KiB, duplicate full `source:name` identities, empty names, invalid resource scope/origin,
names above 512 UTF-8 bytes, or other command metadata strings above 8 KiB before generic JSON projection can truncate the response.
Each row includes the runtime loader's source, scope, origin, and path when available. The lazy
`session.commandDetail` read requires one exact current `source:name` identity and returns
that selected prompt, skill, or extension source document only; content is UTF-8 bounded
to 96 KiB with original byte count and explicit truncation metadata, so catalog loading
never reads or copies every resource body. Protocol-v4 `session.prompt` accepts one typed
`resourceInvocation` with source, canonical name, and visible arguments. The Gateway revalidates
exact live `(source,name)` identity and extension-command precedence before constructing Pi's
normalized leading invocation. Pending and queued projections retain the same typed resource;
canonical binding receipts attach it to the resulting user entry so native chips survive restart
without exposing expanded skill contents or private paths. Resource names are bounded to 512
UTF-8 bytes and arguments to 5,000 bytes (the receipt-safe semantic bound); newline, carriage return, and tab are allowed prompt content,
while other controls and unknown fields are rejected. `text` and resource `arguments` are one exact
contract, including valid empty arguments for no-argument resources; extension commands reject
attachments at the Gateway boundary regardless of client behavior. Extension and skill commands
use Pi's literal ASCII-space delimiter; prompt templates retain Pi's whitespace delimiter after
extension precedence. The same source-specific rules govern typed admission and queue checks. Binding receipts
contain canonical target identity only; start receipts own resource identity and are recovered from
canonical JSONL if live runtime maps have already settled. Queue edits preserve immutable intent by
terminalizing the prior invocation and appending a replacement start/accepted pair under the stable
queue operation ID. Explicit removal appends an interrupted terminal receipt rather than leaving an
accepted orphan, so later canonical binding and cold projection describe the text Pi actually receives. Receipt construction never silently truncates semantic data; persistence/binding diagnostics
are not operation failures and cannot retire an accepted composer row.

One upstream durability boundary remains for the first turn of a brand-new Pi session. The pinned
`SessionManager` admits `appendCustomEntry` into its canonical in-memory branch but intentionally
does not create/flush the JSONL until the first assistant entry. An abrupt Gateway-process or machine
failure after first-prompt admission but before that entry can therefore lose the new session, user
message, and invocation receipts together; iOS disconnect alone does not trigger this window, and
sessions with any assistant history append receipts immediately. Gateway must not poll for the file
(the first assistant cannot run while admission is blocked), write Pi's JSONL directly, fabricate an
assistant entry, or create a second receipt journal. Closing this boundary requires a pinned upstream
public eager-flush/durable-append API that preserves Pi ordering and internal state; acceptance requires
a crash/reopen integration test proving the first start receipt is disk-visible before provider or
extension execution.

Canonical mobile projection recognizes
only Pi's exact 4 MiB-bounded persisted skill envelope, strips the private skill body/path, and
projects its user arguments through the existing attachment extractor. Malformed skill-looking
envelopes become a generic omission rather than leaking or destructively guessing private data.
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

Administrative restart is a deadline-free drain, not an abort: the Gateway synchronously
closes session and administration admission, lets every admitted owner settle without
cancelling accepted work, then exits with the supervised restart code. Unexpected
signal/error shutdown may request exact fenced cancellation and logs if its bounded
cleanup grace expires with ownership still outstanding. `GatewayWorkRegistry` is a
bounded, process-local registry with separate normal and derived-settlement capacity. It
never persists or expires work by age and does not duplicate Pi's runtime, JSONL, or run
markers. Prompt preflight transfers one token into accepted foreground, queue, or
extension-command ownership without a release/reacquire gap. Exact accepted queue owners
run naturally during a graceful drain; only an explicit client clear/replace settles them
without execution. A command-triggered agent turn owns a distinct foreground token even
while the command handler unwinds; agent settlement retires that token independently when
the turn fails or produces no successful assistant completion. During drain, a foreground
token is marked suspect only when no exact live runtime, queue, prompt, command, or terminal
settlement projection represents it and Pi no longer reports a live run. The owning slot
then removes its exact durable marker before retiring that process-local orphan, reasserting
the marker if exact ownership returns while cleanup yields; age alone never authorizes
cleanup. Foreground work without any captured owning slot fails the drain invariant instead
of waiting forever, allowing supervised shutdown/replacement to recover. Direct Bash and
idle compaction persist interruption markers before canonical SDK work, and reliable
bounded-frequency marker/terminal-receipt retries keep the same owner live until durability
succeeds.
Package inventory/update discovery and provider login remain exact administrative owners
until their underlying asynchronous operation settles; retiring mobile UI does not infer
provider settlement. Registry tokens are the normal drain authority. Exact-owned
nonterminal extension artifacts are the sole compatibility exception until the pinned
extension host exposes direct detached-work registration.
The pinned SDK exposes no disposal API for the retained administration resource loader or
model runtime, so admission closure plus exact operation settlement is the truthful
resource boundary; Tron does not pretend those SDK objects were explicitly disposed.

`gateway.drain.status` returns a bounded in-memory `AdministrativeDrainSnapshot` before
and during a drain. The accepted `gateway.restart` response includes the same initial
drain identity and revision while retaining its legacy fields. Snapshots contain category
counts, at most 64 opaque hashed blocker summaries, omitted and suspect-projection counts,
and monotonic revisions—never session/run IDs, prompts, output, paths, provider data, or
credentials. They are diagnostics only; exact tokens, runtime settlement, terminal
artifacts, and durable receipts remain liveness authority. While waiting the Gateway also
emits bounded `gateway.restart-drain.waiting` log records every 15 seconds, plus an
explicit completion record, so operators can distinguish progress from a failed restart.
Live PTYs block restart because process replacement cannot preserve them. Restart closes
terminal admission atomically only after proving no PTY is live, so an already-dispatched
`terminal.open` cannot resume across the cutoff and spawn a shell.
The installed Release wrapper supervises Stable only. `scripts/tron dev` owns the
separate Debug lifecycle on 9848 through the same immutable payload store and launcher.
Its loopback-by-default handoff copies only an authenticated, selected Debug
artifact into Stable as an inactive candidate after proving the same exact Debug
identity before and after the copy; it never selects or restarts Stable. Compatibility
is checked against the actual installed/active Stable runtime, and Node/helper drift
requires a manual Mac app replacement. Promotion pins version and fingerprint,
atomically selects, requests a real drain-aware restart, and accepts readiness only
from a different stable PID/start plus the candidate's exact fingerprint, source revision,
and runtime epoch. Apply and rollback serialize per channel; failed pointer changes restore
the prior selection and use direct, fixed Stable supervisor recovery with exact health
verification rather than RPC to the failed process. Status keeps observed live identity separate from the
selected pointer so publication cannot report readiness early. Each immutable payload fingerprints a regular `app/PushService.xcconfig`.
Stable staging, promotion, source updates, rollback, launcher/Swift admission,
and packaging require its one exact non-empty public HTTPS origin; dev alone
may carry one explicit empty assignment. Stable source updates normally inherit the selected validated payload. If a new
payload requirement makes that predecessor inadmissible, bootstrap is limited to
three explicit, fully fingerprint-validated runtime bases: the configured artifact,
the bundled payload root exported by the signed launcher, then the prepared Gateway
bundle under the already-admitted source checkout. The copied base is revalidated
against the exact admitted manifest before any candidate file changes, closing the
mutable-projection race. No historical version scan or unvalidated runtime fallback
is allowed. Source updates preserve that base's product configuration and team-signed
Darwin native modules rather than consulting environment configuration. Source
rebuilds require a byte-identical dependency lock; dependency changes require a newly
signed app or artifact. Preflight loads every host-architecture native module before
pointer publication, and a failed first external candidate restores the validated
bundled fallback rather than requiring a `previous.json` pointer. Notification state stays
outside payload version directories. Payload staging,
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
8. Fork/session replacement rekeys the same owning slot and subscription-token map entry. An open that overlaps rekey uses the slot's post-acquire canonical ID for synchronization, snapshot, and attention. A replacement open rotates the carried token; an old-ID close may resolve through the bounded alias but cannot revoke that newer token. Pre-commit rekey failure restores the source runtime and removes any uniquely created fork JSONL/artifact directory before reporting failure.
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

## Session subagent activity

The additive `process-activity.v1` projection observes only structured synchronous and
asynchronous delegated subagents that already have an authoritative producer. It does
not add another shell tool, detached executor, PTY, process supervisor, or event journal.
Assistant `bash`, direct user `!` bash, Terminal-sheet PTYs, ordinary tools,
administrative work, and shell grandchildren inferred from command syntax remain outside
this surface and continue through their existing transcript/tool presentation.

`SessionProcessActivity` gives subagent rows a stable namespaced `processId`, typed
source/mode/lifecycle, bounded current-tool/output facts,
an optional bounded `durationMs` derived only from existing producer timing or canonical
start/terminal timestamps, and an optional opaque validated child-session reference. The
installed pi-subagents foreground producer uses one bounded child index consistently
across progress and terminal result arrays. Gateway admits that positional identity only when
the exact `subagent` tool owner matches the installed pi-subagents extension and the bounded
shape has unique safe-integer indexes (or the terminal result array preserves the already
owned child order), an agent, and recognized lifecycle evidence. The normalized
`foreground-index:N` producer is scoped by the canonical parent tool call. Generic extension
tools continue to require explicit structured `runId`/`asyncId` evidence and can never turn
array position into ownership.

For an exact-owned asynchronous pi-subagents artifact, Gateway applies the producer's stable
child contract: explicit `childId`, then workflow key, then child `runId`, with `step:N` as the
canonical bounded top-level default. A fresh workflow child's `runId` is also its separately validated
session-path owner and must be present from launch; pi-subagents 0.59 and newer publish that evidence
for foreground workflow children. Older artifacts that expose only a workflow key and path remain
visible but cannot authorize a live transcript. Thus ordinary single/parallel/chain artifacts have an exact child
row before and after terminal persistence even when a step has no independent run ID. A single async
run may reserve its fresh child path under the parent fan-out root rather than its detached async run
ID. In that shape, Gateway reads the exact-owned private recovery descriptor and accepts its root only
when descriptor version, source run, exact session file, and fan-out contract all match the live status
step; a missing, foreign, replaced, or malformed descriptor leaves the transcript unavailable. The
same producer identity enriches that row with a validated session reference rather than
re-keying it. If status publishes the owned session target just before Pi creates its canonical JSONL,
Gateway retries that exact artifact binding on a bounded backoff and once on an explicit transcript-open
request; no ambient path scan or client inference participates. Bare launcher acknowledgements remain hidden until the lifecycle artifact
contains child execution evidence. This keeps the composer activity overview continuous
without treating labels or generic extension array positions as ownership.
Absolute session and
artifact paths, PIDs, environment values, and unbounded task/output data never cross
the wire. Bounded delegated-output previews conservatively mask environment assignments,
headers/cookies, long and short credential flags, JSON/query keys, URL userinfo, PEM
blocks, recognizable provider tokens, JWTs, and high-entropy bearer-like strings without
modifying canonical JSONL. `SessionProcessOverview` is the shallow composer authority:
active/recent/problem counts, revision, Gateway `asOf`, and nearest expiry. High-frequency
output remains in bounded process deltas and does not require a transcript rebuild.

The Gateway owns process recency for exactly five minutes from authoritative terminal
admission. It converts that wall deadline to a monotonic in-process timer, emits a
revisioned expiry snapshot even when no other session event occurs, and reconstructs
recent subagents from their canonical receipts after runtime acquisition. Existing 15-minute extension
compatibility fields do not extend the process deadline. Active work always outranks
recent terminal work. Expiry removes only the disposable projection while retaining a
bounded terminal tombstone so late advisory artifacts cannot resurrect the same process.
Process replacement deltas carry exact removed process IDs, including removal-only frames.
A native sheet may follow a temporary aggregate only when exactly one admitted successor has
the same immutable tool-call and root-run correlation; ambiguous replacements fail closed.

`session.processHistory.list` and `.get` page only normalized subagent terminal receipts
under one bounded branch-derived revision and opaque cursor. Pagination stops before a row that exhausts the current page's byte
remainder so that row remains reachable at the next cursor; only a row that cannot fit
an empty page is omitted and reported in omission count/bytes. Cursors conflict when the
canonical generation changes. Old `tron.extension-activity.v1` entries remain readable by
extension history;
process history admits individual historical children only when the receipt records their
exact producer ID and a known synchronous or asynchronous execution mode. Supervisor/control
receipts and unknown modes fail closed rather than authoring invalid process DTOs. Canonical
receipts retain the exact child producer, optional fresh-session owner, and validated opaque
child-session ID so historical transcript authorization does not depend on an unbounded runtime
cache; they continue to omit paths, task text, and output.

The companion `process-history.v1` capability advertises canonical history reads.
The `process-transcript.v1` capability authorizes `session.processTranscript.open`,
`.page`, and `.close` through the exact parent process-to-child relationship. The separate
`process-transcript-abort.v1` capability authorizes only
`session.processTranscript.abort`: the Gateway requires the caller's exact live lease,
serializes with that lease's reads, revalidates parent/process/run, path, and file identity,
then routes stop through an idempotent command receipt. Synchronous children use the
parent session's ordinary settled agent abort, matching the composer stop control; asynchronous
children use only the exact installed subagent controller owner with the exact root run and exact
child producer. Authority follows the installed opaque owner identity rather than Pi's mutable
package source label. The open response sets `canAbort` only when that route exists; synchronous leases
also capture the exact foreground operation ID, so a stale lease cannot abort newer parent work.
It exposes no generic child mutation or writable transcript authority. A
connection-owned lease watches only the validated canonical child file, installs that
watch before capturing its initial page, latches any append in the baseline-publication
window, emits bounded invalidation events, and reopens it through a read-only projection
for canonical paging. In-flight opens reserve the same per-client and per-parent capacity
as established leases. Page and invalidation/live-refresh requests serialize per lease and
recheck the client's expected revision inside that lane, so an older observer read or a
canceled mobile prepend cannot race a refresh and advance the same lease generation out of order.
Open, page, and invalidation reads each revalidate the exact live parent process/tool/run
binding, exact reserved child path, header identity, and original file identity. Ownership admission
reads only the immutable bounded header, so an in-progress tail append cannot masquerade as an
identity replacement. Page projection pins one newline-complete prefix from the already-open inode;
a later canonical append advances the lease through its watcher rather than invalidating that prefix.
Fresh children are
admitted only at `<parent-stem>/<session-owner>/run-N/session.jsonl`, with exactly three relative
path components. The session owner is separately proven as either the exact root run (ordinary
single/parallel/chain, including the status-matched private recovery descriptor for a detached single
run) or an exact artifact child `runId` (detached workflow child); it is never inferred from the path
or process producer. Fork-context children are admitted only at
`<parent-stem>/forks/<fork-session>.jsonl` when their header resolves to the mounted parent. In
both layouts the process producer comes only from the trusted lifecycle identity contract, never
a filename, name, title, or generic extension array position. Fresh children may omit the parent
header because exact tool/run ownership plus the separately validated session-owner path remain
authoritative. Session names and `session_info` never participate in admission. Replacement
or ambiguity closes/fails the lease. Transcript projection
parses the already-open, identity-pinned descriptor through a pure read-only branch adapter
under an explicit 64 MiB per-session parse budget, so a replace/read/swap-back race cannot
redirect parsing to another inode and a legitimate but unbounded child file cannot exhaust
Gateway memory.
Read-only open/page/refresh never call `RuntimeRegistry.acquire` for the child and the
lease keeps no second transcript mirror. Only the separately advertised exact-lease abort
may reacquire the already-owned parent runtime, and only to invoke its existing settled
foreground abort or trusted subagent stop control. Producer admission requires the exact owning tool/run,
a unique child identity, and a regular session file structurally nested beneath the
canonical parent session's child root; persisted reopening repeats the parent/process/run,
producer-token, and catalog checks. Reads reject missing ownership, symlinks, oversized headers,
identity/path replacement, foreign or ambiguous catalog identities, incomplete trailing
JSONL appends, stale page anchors, and retired leases. Leases are bounded per connection
and per parent session. Closing the parent presentation or client retires every owned
child observer.

## Extension activity lifecycle and history

Structured extension runs retain the legacy coarse `status` alongside the additive
versioned lifecycle record (`queued`, `running`, `paused`, `completed`, `failed`,
`stopped`, `rejected`, or `unknown`). Gateway projection sequence and terminal
latches own ordering; producer timestamps are display evidence only. Terminal
activities receive Gateway-owned `terminalAt`/`recentUntil` facts and are recent for
exactly 15 minutes. Active lifecycle rows use `visibility: current` without a terminal
`remainingMs`; only recent/historical terminal rows carry that countdown. A single coalesced expiry deadline republishes
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
`endedAt` may precede the final persistence `lastUpdate`; admission requires the complete
`startedAt <= endedAt <= lastUpdate` timeline (including the legacy `completedAt` alias),
and keeps `updatedAt` bound to persistence while `completedAt` remains logical completion.
Exact-owned rejection is observable through rate-limited, hard-bounded reason codes
(`invalid-timestamp`, `missing-terminal-time`, `ownership-mismatch`,
`malformed-artifact`, or `artifact-replacement-in-progress`) keyed only by opaque hashes.
Unowned ambient junk is silent, and warnings never include artifact paths or content.
Oversized status files
remain outside the projection byte cap; an exact-owned run may recover only its bounded
top-level lifecycle header when a matching terminal record is also present in the bounded
`events.jsonl` tail, without parsing or projecting oversized step data. Administrative
drain also refreshes exact-owned artifacts directly on a bounded interval, so terminal
work does not depend on watcher delivery or ambient scan scheduling. Atomic status replacement receives bounded retries; if an exact-owned nonterminal status or run directory remains absent for 30 seconds, Gateway changes that disposable lifecycle to `unknown`, removes its active process row, and releases drain/activity claims rather than projecting a zombie forever. Reappearance of the same exact-owned artifact may publish newer evidence. Shared recency scheduling
removes only the disposable ambient projection at its wall-clock deadline,
while canonical history remains available. Detached nonterminal work protects
its session lane from idle eviction and administrative drain.
