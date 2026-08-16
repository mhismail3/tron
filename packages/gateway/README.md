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
does not maintain a session database or event journal.

## Runtime and state

- Agent state: `PI_CODING_AGENT_DIR`, default `~/.pi/agent`
- Gateway state: `<TRON_DATA_DIR|~/$TRON_HOME_NAME|~/.tron>/gateway/`
- Local wrapper credential: `gateway/local-auth.json` (`0600`)
- Hashed mobile devices: `gateway/devices.json`
- Current invitation: `gateway/enrollment.json` (`0600`, ten minutes, one use)
- Run markers and command receipts: gateway-owned bounded operational state
- Uploads: transient and bounded; unclaimed staging expires, while prompt attachments remain session-owned until canonical deletion

Legacy `~/.tron/auth.json` is not gateway auth and is never overwritten. It is
read only by the explicit legacy importer.

## Transport

- `GET /health` — unauthenticated readiness and compatibility metadata
- `POST /v1/pair` — rate-limited one-time enrollment exchange
- `POST /v1/uploads` — authenticated bounded upload
- `GET /v1/blobs/:id` — authenticated transient projected blob
- `GET /v1/socket` — authenticated protocol version 2 WebSocket

The pairing limiter keeps the exact rolling per-address window while retaining at most 4,096
least-recently-used address keys and periodically deleting expired windows; address churn cannot
create append-only process state. Uploads retain the 25 MiB per-request limit and additionally
serialize admission against 128-entry and eight-times-per-upload (200 MiB by default) aggregate ceilings. Unclaimed uploads
expire after 24 hours, malformed/partial folders self-clean, prompt attachment IDs are unique, and
one prompt cannot materialize more than the per-request byte ceiling. Successful imports remove
their staging folder; deleting a canonical session removes its claimed attachment folders. Cleanup
failure is best effort after canonical import/deletion success and cannot turn that success into an
ambiguous command receipt; failed session-folder cleanup remains pending in the live store and retries
on later inventory work. The retired `/engine` protocol is not exposed.

Every WebSocket starts with:

```json
{"type":"hello","protocolVersion":2}
```

Requests use `{type,id,method,params}` and receive `{type,id,ok,result|error}`.
Mutations require `params.commandId`; receipts deduplicate completed commands.
After an uncertain disconnect, clients reconnect and poll `command.status`, reuse
a completed result, retry only a confirmed-missing command with the same ID, and
never blindly replay a pending command. An observed application rejection removes
its pending receipt so the definitive error remains definitive; process loss or failure
to persist a successful completion leaves pending state and therefore cannot enable a
blind duplicate. Receipt execution serializes identical command keys only; unrelated commands and sessions remain concurrent.
The gateway sends WebSocket ping control frames every 25 seconds and terminates
connections that fail the next heartbeat, so half-open Tailscale/iOS paths are
observable. Reconnect and foreground activation converge through an authoritative
snapshot. `session.summary` is a bounded, per-session revisioned global projection
of phase, name, activity time, message count, and first-message title. It updates every connected
dashboard immediately without broadcasting full transcripts; clients subscribe
to `session.snapshot`, progress, tool, queue, and extension events only for chats
they actually open. Active operations also emit a bounded sequenced heartbeat, so
a long tool with no output remains distinguishable from a broken mobile stream.
The embedded runtime's active-run flag outranks an older settlement callback when
an extension completion immediately triggers a continuation, so phase, operation,
and Stop controls cannot become idle while a newer turn is executing. Extension-
owned detached work remains distinct from that foreground phase: its portable
widget projection stays visible after the parent turn settles, while aborting a
wait does not falsely claim to stop the detached worker.
Parallel tool events carry a monotonic per-run ordinal; each call additionally has
a monotonic progress sequence, bounded display-safe live-output tail, runtime start,
last-progress/completion timestamps, and duration. The Gateway coalesces high-rate
updates without losing the newest state. Clients join calls, progress, and results
by canonical call ID rather than arrival order.

Active message queues are projected with stable per-entry IDs, delivery behavior,
display text, attachment count, and a monotonic queue revision. A Gateway advertising
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
the same uncancelled runtime call later starts canonical work.

Session structure/context/resource invalidations refresh
already-presented secondary surfaces. Provider, settings, trust, package, and
custom-model mutations publish bounded global invalidations so another connected
client refreshes its explicitly scoped canonical projection. Settings projections include
scope-owned documents and effective values, but write-only proxy credentials are removed
from both; clients receive only `httpProxyConfigured` and can set or explicitly clear the
canonical value. Trust changes reload
idle live runtimes before acknowledgement; project resources therefore cannot stay
loaded from an obsolete decision. PTY output has an independent monotonic
sequence and bounded attach replay for gap/reconnect convergence. Context, tree,
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
`session.list` and `model.list` are cursor-paginated so Pi catalogs remain
complete without exceeding bounded gateway frames. Pi's configured `sessionDir`, or its
canonical per-workspace directories under `agentDir/sessions`, remain authoritative; Tron does
not move or mirror those files. `session.list` defaults to user sessions, while `scope: "all"`
additively includes extension-owned children classified from nested canonical storage or their
durable `subagent-*` session metadata. Ordinary user forks remain user sessions. If more than
one canonical file claims the same embedded session ID, the Gateway omits every ambiguous copy
and rejects open/delete by that ID until the duplicate is repaired; traversal order never chooses
canonical ownership. Every session-list traversal is one immutable, disposable catalog materialization: every
page carries the same structural `listRevision`, and its authenticated opaque cursor
is bound to the connection, scope, materialization, offset, and revision. Traversal
leases expire after 30 seconds, are released on disconnect, and are bounded by
per-client lease quotas plus per-lease/global row and encoded-byte limits with LRU eviction. Runtime `session.summary` revisions remain independent, so activity heartbeats
and ordinary row updates neither rescan nor tear catalog pagination; a later traversal
observes newer canonical truth. Clients still fail closed and restart from a nil cursor
when interoperating with an older Gateway that changes revisions between pages.
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
owning runtime and projected onto settled results; older Pi JSONL entries, which do
not persist execution timing, use the canonical call-to-result interval as an
observed fallback. Completed results leave the live overlay as soon as their
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
ordinary text part and never sends the Mac path to clients. Older protocol-v2
clients therefore degrade to the safe filename instead of failing on a new
content discriminant. A page carries the next
visible entry as its branch anchor and fails retryably if tree navigation changed
that boundary while the request was in flight. Oversized responses return
a correlated protocol error instead of disconnecting the device. `session.context`
and `session.resources` return runtime-native resource projections. The resource
projection includes display-safe extension, prompt, skill, context-file, and tool
metadata while canonical resource files and runtime loaders remain authoritative.
`session.tree` returns a bounded flat outline with depth, child-count, role, and
current-path metadata; it never recursively serializes an unbounded canonical tree.
Summarizing tree navigation owns foreground branch-summary state only for the exact
awaited call; success, extension cancellation, and provider failure all retire that
state and publish the settled snapshot before the serialized mutation lane advances.
Session statistics include the runtime-calculated latest cache-hit rate used by the
terminal footer, so mobile clients do not invent a different ratio.
Custom model documents are validated by a temporary instance of the pinned runtime
before an atomic write. Read projections redact secret-looking strings; matching
redaction placeholders are restored from canonical state during update so mobile
editing cannot erase credentials it was never allowed to read.

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
   and captures a snapshot cursor, returns that snapshot plus an ephemeral sync token,
   then releases only later sequenced events after `session.sync` acknowledges the exact
   baseline. A bounded barrier overflow requests another full sync. A failed open
   transaction removes its barrier immediately, so retrying cannot produce a stale
   “already synchronizing” conflict.
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
be reviewed before installation.

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

This client uses the stable Tron protocol, local wrapper credential, atomic
snapshot/event catch-up, command IDs, and reconnect convergence. It does not open
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
