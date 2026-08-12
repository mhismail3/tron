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
Mutations require `params.commandId`; receipts deduplicate completed commands and
surface uncertain in-flight duplicates rather than blindly replaying work.
The gateway sends WebSocket ping control frames every 25 seconds so idle mobile
connections remain observable through Tailscale and iOS network transitions;
reconnect still converges through an authoritative snapshot.

Primary operation groups are `system`, `device`, `legacy`, `session`,
`extension`, `provider`, `model`, `auth`, `settings`, `trust`, `packages`,
`models.custom`, `filesystem`, `git`, `terminal`, and uploads/blobs over HTTP.
`session.list` and `model.list` are cursor-paginated so Pi catalogs remain
complete without exceeding bounded gateway frames. `session.open` carries a
byte-bounded authoritative transcript tail with `transcriptStart` and
`transcriptTotal`; `session.transcript` pages backward through the same canonical
Pi branch without enlarging the WebSocket frame limit. Oversized responses return
a correlated protocol error instead of disconnecting the device. `session.context`
and `session.resources` return runtime-native resource projections. Custom model documents are validated
by a temporary instance of the pinned runtime before an atomic write.

## Session invariants

1. `RuntimeRegistry` owns at most one `RuntimeSlot` per session in this process.
2. `RuntimeSlot` serializes mutations for its session. Different slots execute
   concurrently.
3. Prompt admission returns an operation ID; client disconnect does not abort it.
4. Reconnect/open returns complete current runtime state plus a bounded canonical
   transcript tail, not missed event replay; older transcript pages remain available.
5. A run marker exists only for an admitted active operation. Startup projects a
   surviving marker as `interrupted`; prompts are never replayed automatically.
6. Fork/session replacement rekeys the same owning slot and subscriptions.
7. Idle runtimes may be evicted only while not busy and unsubscribed.

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

Run one test owner while iterating:

```bash
npx vitest run src/sessions/runtime-registry.integration.test.ts
npx vitest run src/admin/legacy-import-service.test.ts
```

The integration tests use the SDK's faux provider to verify concurrent real
session runtimes, detached completion, and fork rekeying without network
credentials. Additional deterministic tests exercise interactive API-key and
OAuth brokering, project trust, native local-package persistence, legacy import,
and credential separation.
