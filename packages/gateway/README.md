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
- Uploads: transient, bounded, and removed after materialization/expiry

Legacy `~/.tron/auth.json` is not gateway auth and is never overwritten. It is
read only by the explicit legacy importer.

## Transport

- `GET /health` — unauthenticated readiness and compatibility metadata
- `POST /v1/pair` — rate-limited one-time enrollment exchange
- `POST /v1/uploads` — authenticated bounded upload
- `GET /v1/blobs/:id` — authenticated transient projected blob
- `GET /v1/socket` — authenticated protocol version 2 WebSocket

The retired `/engine` protocol is not exposed.

Every WebSocket starts with:

```json
{"type":"hello","protocolVersion":2}
```

Requests use `{type,id,method,params}` and receive `{type,id,ok,result|error}`.
Mutations require `params.commandId`; receipts deduplicate completed commands.
After an uncertain disconnect, clients reconnect and poll `command.status`, reuse
a completed result, retry only a confirmed-missing command with the same ID, and
never blindly replay a pending command. Receipt execution serializes identical
command keys only; unrelated commands and sessions remain concurrent.
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
Session structure/context/resource invalidations refresh
already-presented secondary surfaces. Provider, settings, trust, package, and
custom-model mutations publish bounded global invalidations so another connected
client refreshes its explicitly scoped canonical projection. Trust changes reload
idle live runtimes before acknowledgement; project resources therefore cannot stay
loaded from an obsolete decision. PTY output has an independent monotonic
sequence and bounded attach replay for gap/reconnect convergence. Context, tree,
resources, commands, exports, and terminal inventory require an established open
subscription for that exact session, preventing stale client selection from
reading a different live runtime projection.

Primary operation groups are `system`, `device`, `legacy`, `session`,
`extension`, `provider`, `model`, `auth`, `settings`, `trust`, `packages`,
`models.custom`, `filesystem`, `git`, `terminal`, and uploads/blobs over HTTP.
`session.list` and `model.list` are cursor-paginated so Pi catalogs remain
complete without exceeding bounded gateway frames. Every session-list page carries
the same registry revision; clients restart pagination if summaries change between
pages instead of installing a torn dashboard. `session.open` carries a
byte-bounded authoritative transcript tail with `transcriptStart` and
`transcriptTotal`; `session.transcript` pages backward through the same canonical
Pi branch without enlarging the WebSocket frame limit. Live tool arguments,
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
Session statistics include the runtime-calculated latest cache-hit rate used by the
terminal footer, so mobile clients do not invent a different ratio.
Custom model documents are validated by a temporary instance of the pinned runtime
before an atomic write. Read projections redact secret-looking strings; matching
redaction placeholders are restored from canonical state during update so mobile
editing cannot erase credentials it was never allowed to read.

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
10. The gateway is the sole mutable runtime owner. Terminal and mobile chat surfaces
   must attach to this runtime; opening the JSONL in an independent Pi process is
   unsupported because Pi has no cross-process session lock.

## Trust and execution

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
