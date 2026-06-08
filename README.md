# Tron

**A persistent, event-sourced AI coding agent for macOS.**

Tron is a local-first AI coding agent that runs as a persistent background service. On the primitive teardown branch, a Rust server handles provider communication, a single `execute` primitive, agent-owned state, and event-sourced session persistence. The native iOS app is being reduced to a thin chat and generic runtime shell; fixed product panels are teardown targets, not supported branch behavior.

This README is the single, canonical reference for the project and is expected to stay in sync with the code. The Rust codebase is self-documenting: `packages/agent/src/lib.rs` declares the module tree, `mod.rs` files map submodules, and `// INVARIANT:` comments mark critical correctness constraints. iOS documentation lives in `packages/ios-app/docs/`. When you change anything described here — modules, CLI commands, capabilities, engine protocol methods, event types, settings fields, DB tables, install layout — update this file in the same commit.

---

## Table of Contents

- [Architecture](#architecture)
- [Living Architecture Docs](#living-architecture-docs)
- [Repository Structure](#repository-structure)
- [Rust Modules](#rust-modules)
- [Quick Start](#quick-start)
- [CLI Reference](#cli-reference)
- [Capabilities](#capabilities)
- [Engine Protocol API](#engine-protocol-api)
- [Event System](#event-system)
- [Settings](#settings)
- [Authentication](#authentication)
- [Context and Compaction](#context-and-compaction)
- [Database Schema](#database-schema)
- [iOS App](#ios-app)
- [Mac App](#mac-app)
- [Permissions](#permissions)
- [Deployment](#deployment)
- [Testing](#testing)
- [Core Invariants](#core-invariants)

---

## Architecture

```
+-----------------------------------------------------------------------------+
|                              iOS App (SwiftUI)                              |
|                           packages/ios-app                                  |
|              MVVM  -  Coordinators  -  Event Plugins  -  Swift 6            |
+-------------------------------+---------------------------------------------+
                                | WebSocket (`/engine`), port 9847
                                v
+-----------------------------------------------------------------------------+
|                          Rust Agent Server                                  |
|                         packages/agent                                      |
|                                                                             |
|  +-------------+  +------------+  +------------+  +------------------------+ |
|  |  Providers  |  | Capability |  |  Context   |  |     Orchestrator       | |
|  |  Anthropic  |  | execute    |  |  soul      |  |  Session lifecycle     | |
|  |  OpenAI     |  | state ops  |  |  state     |  |  Turn management       | |
|  |  Google     |  | file ops   |  |  compaction|  |  Event routing         | |
|  |  MiniMax    |  | process op |  |  messages  |  |  Turn recovery         | |
|  +-------------+  +------------+  +------------+  +------------------------+ |
+------------------------------------+----------------------------------------+
                                     |
                                     v
+-----------------------------------------------------------------------------+
|                         Event Store (SQLite)                                |
|   - Immutable event log with tree structure (fork/rewind)                   |
|   - Session state reconstruction via ancestor traversal                     |
|   - SQLite-backed sessions, events, blobs, logs, engine ledger/state        |
+-----------------------------------------------------------------------------+

```

### Data Path

1. Client connects to `/engine` and sends engine protocol messages
2. The `server` module validates framing and builds an `EngineTransportRequest`
3. The envelope invokes a canonical `namespace::function` engine capability through a transport trigger
4. Canonical functions call runtime, orchestrator, event store, or domain services as needed
5. Domain output is serialized at the transport boundary
6. Runtime events publish neutral `ServerEventPayload` records to engine streams, and `/engine` subscriptions deliver stream records

---

## Living Architecture Docs

The durable architecture docs live beside the code they describe. The root
README is the map; source files, `mod.rs` docs, `INVARIANT:` comments, and
concern-owned tests are the durable truth. One-off phase plans, migration
rubrics, and audit snapshots are not kept as source-of-truth docs because they
drift after the code changes.

Current living entry points:

- `packages/agent/src/lib.rs`: Rust crate/module tree.
- `packages/agent/src/engine/mod.rs`: engine fabric ownership.
- `packages/agent/src/engine/resources/mod.rs`: resource substrate ownership.
- `packages/agent/src/engine/primitives/mod.rs`: primitive capability surface.
- `packages/agent/src/domains/capability/mod.rs`: model-facing `execute`
  primitive and provider export.
- `packages/agent/docs/primitive-engine-teardown-scorecard.md`: completed
  clean-break primitive engine teardown scorecard for stripping hard-coded
  capabilities, policies, skills, rules, helper launch products, and fixed iOS product
  surfaces down to the smallest provider loop, single `execute` primitive,
  agent-owned state workspace, event/ledger truth, and dynamic client shell.
- `packages/agent/docs/primitive-engine-teardown-evidence-manifest.md`:
  companion evidence manifest for the completed primitive engine teardown
  scorecard.
- `packages/agent/docs/primitive-engine-teardown-inventory.md`: PET-1
  source-audited deletion map for every current Rust domain, engine primitive
  worker, runner context plane, managed skill, doc, iOS source/view root, and
  settings surface.
- `packages/agent/docs/primitive-code-cleanup-scorecard.md`: active whole-repo
  primitive cleanup scorecard for folder ownership, file budgets, generated
  artifact hygiene, and final retained-surface proof.
- `packages/agent/docs/primitive-code-cleanup-evidence-manifest.md`: companion
  evidence manifest for the active primitive cleanup scorecard.
- `packages/agent/docs/primitive-code-cleanup-inventory.md`: PCC-1
  whole-repo tracked-file inventory, classification summary, and canonical
  cleanup target tree.
- `packages/agent/docs/primitive-code-cleanup-file-inventory.tsv`:
  machine-readable per-file cleanup classification used by static gates.
- `packages/agent/tests/primitive_engine_teardown_plan_invariants.rs`:
  absence, traceability, schema, registration, and documentation gates for the
  primitive branch.
- `packages/agent/tests/primitive_code_cleanup_invariants.rs`: cleanup
  scorecard, folder-justification, file-budget, deleted-term, and tracked-junk
  gates.
- `packages/ios-app/docs/architecture.md`: iOS thin-client architecture.
- `packages/mac-app/docs/architecture.md`: Mac wrapper architecture.

Deleted product campaign scorecards and guides are absent on this branch.

Capability-backed truth means durable facts that affect agents or operators are
owned by resources, decisions, evidence, invocations, grants, queues, leases, or
generated UI resources; domain-owned hidden files or tables are acceptable only
as explicitly documented low-level cache/substrate boundaries with static gates,
and they are not policy, lineage, or product truth.

---

## Repository Structure

```
tron/
+-- VERSION.env             Canonical release version + Apple build source of truth
+-- packages/
|   +-- agent/              Rust agent server (single `tron` crate, modular layout)
|   +-- ios-app/            SwiftUI iOS application
|   +-- mac-app/            SwiftUI Mac menu-bar wrapper (Tron.app) — install wizard + server lifecycle
+-- scripts/
|   +-- tron                CLI dispatcher for build, deploy, service management
|   +-- tron.d/             Workspace CLI command-family modules
|   +-- tron-version        Version print/check/sync helper used by CI + releases
|   +-- tron-release-notes  Deterministic tagged-release changelog generator
|   +-- tron-lib.sh         Shared bash configuration and module loader
|   +-- tron-lib.d/         Runtime CLI service/log/auth/bundle modules
|   +-- tron-cli            Contributor CLI helper for local service management
|   +-- tron-ios-beta       Local physical-device build/install/stop helper for iOS app variants
|   +-- auto-deploy         Background auto-deploy worker (contributor-only; refuses to run outside a git repo)
+-- .github/
|   +-- workflows/          CI + Mac/iOS release pipelines
|   +-- ISSUE_TEMPLATE/     Structured bug/feature report forms
|   +-- dependabot.yml      Weekly Cargo + GitHub Actions updates, monthly Swift
|   +-- pull_request_template.md
+-- .claude/
    +-- CLAUDE.md           AI agent project instructions
    +-- skills/             Repo-local Claude helper skills for contributors
```

---

## Rust Modules

The agent is a single `tron` crate (see `packages/agent/Cargo.toml`). The crate tree now mirrors the pure engine model: app/bootstrap, thin transports, the engine fabric, worker-owned domains, platform integrations, and shared foundation/protocol helpers. Dependencies flow inward: transports build engine requests, domains own behavior, and the engine owns policy/ledger/streams/queues/workers.

```
app/        Binary/server bootstrap, health, metrics, onboarding, shutdown
transport/  /engine client protocol, /engine/workers socket transport, auth gate
engine/     Live capability fabric: catalog, workers, triggers, ledger, streams, queues
domains/    Every Tron worker: contracts, deps, handlers, operations, local services, tests
platform/   OS/vendor integrations retained by the primitive loop
shared/     Foundation IDs/errors/paths, protocol DTOs, unified storage helpers
main.rs     Thin binary entry point
main_cli.rs CLI parsing and auth subcommand dispatch
main_runtime.rs Server startup/runtime wiring
```

| Module | Purpose | Key Types |
|--------|---------|-----------|
| `app` | Startup/bootstrap + HTTP shell | `TronServer`, `ServerConfig`, `ShutdownCoordinator` |
| `transport` | Thin protocol surfaces over the engine envelope | `EngineTransportRequest`, `run_engine_ws_session`, `BearerTokenStore` |
| `engine` | Live capability fabric, primitive workers, local worker protocol, typed resource kernel | `LiveCatalog`, `EngineHostHandle`, `FunctionDefinition`, `WorkerDefinition`, `Invocation`, `InvocationRecord`, `EngineResource`, `EngineResourceTypeDefinition` |
| `domains` | Worker-owned Tron behavior and implementation code, including the collapsed capability harness | `registration::register_domain_workers_for_context()`, `capability::worker_module()`, `DomainWorkerModule`, per-domain contracts/deps/handlers |
| `platform` | OS/vendor integrations | paired-device broker |
| `shared` | Foundation vocabulary, protocol DTOs, and neutral storage helpers | `Message`, `TronError`, `StreamEvent`, `SessionId`, `StorageRuntime`, `ServerRuntimeContext`, `CapabilityError` |

The domain package is intentionally vertical. A domain root is only docs,
exports, and worker registration. Shared worker registration types live in
`domains::worker`; the startup aggregator in `domains::registration`
iterates each domain's `worker_module(...)`. `contract.rs` owns the canonical
function ids, schemas, authority, idempotency, risk, leases, compensation, and
declared stream topics; `deps.rs` narrows setup into the handles that domain
uses; `handlers.rs` binds operation keys to local handler structs; `operations/`
contains executable operation bodies. Runtime support is split the same way in
domain-owned folders such as `domains/agent/runner/*`,
`domains/agent/runtime/*`, `domains/session/event_store/*`, and
`domains/agent/runner/agent/primitive_surface.rs`. Provider-native stream/function-call
argument parsing and provider-specific invocation id remapping are isolated
under `domains/model/provider_protocol/*` before any canonical capability
history reaches the runner, ledger, registry, audit, or iOS DTO layers.
`stream.rs` publishes only that domain's declared topics. Cross-domain access
goes through explicit domain services or shared DTOs, so an engineer can follow
a capability by reading one domain folder instead of a central dispatch table.

---

## Quick Start

### End Users (recommended)

1. Install [Tailscale](https://tailscale.com) and sign in on the Mac that will host the agent.
2. Download the latest `tron-v*.dmg` from [GitHub Releases](https://github.com/mhismail3/tron/releases) and drag `Tron.app` into `/Applications`.
3. Launch `Tron.app`. The wizard handles Tailscale detection, required permissions, server install, and the iOS handoff.
4. On iPhone, scan the wizard's Tron iOS Beta QR code to open the public TestFlight invite, install the latest available Tron beta, then scan the Mac pairing QR or enter the pairing fields manually.

The wizard and menu bar surface runtime actions such as pairing info, logs, feedback, restart, pause, resume, and uninstall — you never need the CLI unless you want to.

### Contributors (build from source)

Prerequisites:

- **Rust**: `rustup` + `cargo` (stable toolchain)
- **Xcode 26+** for the iOS app; **Xcode 16+** for the Mac app
- **XcodeGen**: `brew install xcodegen`

First-time setup:

```bash
./scripts/tron setup       # Check prerequisites, build, create ~/.tron/
./scripts/tron login       # Authenticate with Claude (OAuth browser flow)
```

Build and run:

```bash
# Build the server
cd packages/agent
cargo build --release

# Development mode (foreground, auto-rebuild)
./scripts/tron dev

# Or install as launchd service
./scripts/tron install
```

iOS app:

```bash
cd packages/ios-app
brew install xcodegen
xcodegen generate
open TronMobile.xcodeproj
```

Mac app wrapper (optional; for DMG development):

```bash
cd packages/mac-app
xcodegen generate
open TronMac.xcodeproj
```

Build with the `Tron` scheme for optimized production builds, `Tron Fast` for
debug-speed builds that install over the production app, or `Tron Beta` for the
side-by-side beta variant. The app starts without a server until the user pairs
a Mac through onboarding.

Codex app local actions are checked in under
`.codex/environments/environment.toml`. Open this project root in the Codex app
to get toolbar actions for starting `scripts/tron dev -bdt`, stopping the dev
server with `scripts/tron dev --stop`, and clear physical-device iOS actions.
`Rebuild + Install + Launch ...` actions call `scripts/tron-ios-beta install`,
which regenerates the Xcode project, builds current source, installs the fresh
app bundle, and launches it. `Just Launch Installed ...` actions call
`scripts/tron-ios-beta launch`, so they only open the app that is already on
the device.
The install helper installs the requested configuration's `iphoneos` product, so
production actions do not accidentally launch a stale Beta or ProdDebug build
from DerivedData. Production rebuild actions call `install`, not `launch`, so
source changes are built into the app before it is installed and post-install
launched.
The iPhone environments are Beta (`Tron Beta`/`Beta`), Prod Fast (`Tron
Fast`/`ProdDebug`), and Prod Release (`Tron`/`Prod`). Because the two
production builds share `com.tron.mobile`, there is one deduplicated production
just-launch action; it opens whichever production-bundle binary is currently
installed. iPad currently has Beta rebuild/install/launch and just-launch
actions.
The iOS actions pass generic `TRON_IOS_DEVICE_NAME=iPhone` or
`TRON_IOS_DEVICE_NAME=iPad` selectors so the repo does not store personal device
details. Post-install launch is bounded by the helper's launch timeout so a
stuck `devicectl` launch exits cleanly. The matching launch action relaunches
the already-installed app without rebuilding.

See [CONTRIBUTING.md](CONTRIBUTING.md) for commit conventions, TDD expectations, and release workflows.

---

## CLI Reference

The `scripts/tron` CLI manages workspace development and contributor service workflows. The dispatch table is at the bottom of `scripts/tron` (the `case "$1" in` block); command-family bodies live in `scripts/tron.d/`, while runtime service/log/auth/bundle helpers loaded by both `scripts/tron` and the installed `tron-cli` live in `scripts/tron-lib.d/`. When adding or renaming a subcommand, update the dispatcher and the owning module together.

### Development (workspace only)

| Command | Description |
|---------|-------------|
| `tron dev` | Start the dev-profile server in the foreground (`-b` build first, `-t` test first, `-d` launchd-backed background takeover). Stops the installed `com.tron.server` job before binding port `9847`, defaults dev logging to `RUST_LOG=info,ort=error` unless the caller already set `RUST_LOG`, waits up to 30 seconds for `/health` in background mode by default, writes startup/exit output to `~/.tron/internal/run/tron-dev-background.log`, and restores the installed helper through `/Applications/Tron.app` on exit/stop only after `/health` passes. Agent automation should use `tron dev -bd --json --wait <seconds>` so the final stdout object reports the actual listener PID and health state. |
| `tron ci` | CI checks: any subset of `fmt`, `check`, `clippy`, `test`, `bench`, `doc` |
| `tron bench` | Performance benchmarks (`run`, `bless`, `compare`) |
| `tron version` | Central release version helper (`print`, `check`, `sync`, `bump`). `VERSION.env` is the only hand-edited release identity source; platform files are generated mirrors. |
| `tron setup` | First-time project setup |

### Deployment (workspace only)

| Command | Description |
|---------|-------------|
| `tron preflight` | Pre-deploy infrastructure check |
| `tron deploy` | Build, test, swap binary, restart, health-check (`--force` skips confirms; `--ci` is non-interactive) |
| `tron install` | Contributor-only shell install for workspace testing. The distributed Mac app does not call this; real installs use `/Applications/Tron.app` + `SMAppService`. |
| `tron uninstall [--reset-settings] [--reset-credentials]` | Remove launchd service/runtime bundles and reset Mac onboarding. Preserves the database and workspace; optional flags remove `profiles/user/profile.toml` settings overrides and/or `profiles/auth.json`. |
| `tron auto-deploy` | Contributor-only auto-deploy watcher (`install`, `uninstall`, `status`, `pause`, `resume`, `logs`). Refuses to run outside a git repo. |

### Runtime

| Command | Description |
|---------|-------------|
| `tron start` | Start `com.tron.server`. When `/Applications/Tron.app` is installed, this enters the wrapper's `--tron-start-server-and-quit` path so `SMAppService` owns production registration and success is reported only after `/health` passes; the older contributor `~/Library/LaunchAgents` path is used only when no installed Release wrapper is available. |
| `tron stop` | Stop the service |
| `tron restart` | Stop and start the service through the same health-gated path as `tron start`. |
| `tron status` | Show service/dev-takeover status, PID, port, health, uptime, and stale dev pid-file diagnostics. Use `tron status --json` for deterministic automation. |
| `tron rollback` | Restore the previous binary from backup (`--yes` skips confirm) |
| `tron login` | Authenticate with a provider (`--label <name>` for multi-account) |
| `tron auth rotate` | Rotate the WebSocket bearer token (forces every paired iOS device to pair again) |
| `tron logs` | Query unified `~/.tron/internal/database/tron.sqlite` logs (`-h` for filter options) |
| `tron errors` | Show recent errors |

### Build Profiles

```bash
cd packages/agent
cargo check                        # Fast correctness check (no binary)
cargo build --profile dev-server   # Dev server (thin LTO, fast iteration)
cargo build --release              # Production (fat LTO, maximum optimization)
cargo test                         # Run the full test suite
cargo clippy -- -D warnings        # Lint with warnings as errors
```

---

## Capabilities

This branch is in the primitive-engine teardown path. The server-side model
surface is intentionally collapsed to one provider-visible function:

| Provider tool | Engine function | Purpose |
|---------------|-----------------|---------|
| `execute` | `capability::execute` | Run one primitive host operation and return a bounded observation/result to the turn loop. |

`capability::execute` is a direct primitive operation endpoint. Its request
schema requires an `operation` field and accepts only operation-specific
primitive fields such as `input`, `scope`, `namespace`, `key`, `value`, `path`,
`content`, `command`, `traceId`, `traceRecordId`, `limit`, `timeoutMs`,
`maxOutputBytes`, `idempotencyKey`, and `reason`.
Agent-launched `execute` invocations carry provider type, provider call id,
run/turn ids, canonical working directory, and trace parentage as trusted engine
runtime metadata; trace records use those facts directly instead of inferring
provider ownership from model id strings.

Current primitive operations:

| Operation | Effect |
|-----------|--------|
| `observe` | Record text as an assistant-visible observation. |
| `state_get` | Read an agent-owned state value. |
| `state_set` | Write an agent-owned state value. |
| `state_list` | List agent-owned state entries for a scope/namespace. |
| `file_read` | Read a UTF-8 file under the current working directory. |
| `file_write` | Write UTF-8 content under the current working directory. |
| `process_run` | Run a bounded local shell command with timeout and output limits. |
| `trace_list` | List durable Agent Trace-style records for the current session, optionally filtered by trace id. |
| `trace_get` | Read one durable trace record by id within the current session. |
| `log_recent` | Read bounded recent log evidence, optionally filtered by trace id, through the same `execute` primitive. |

Startup registration currently keeps only loop infrastructure domains: `system`,
`capability`, `blob`, `message`, `settings`, `auth`, `agent`, `logs`, `session`,
`context`, and model-provider modules. Product/tool domains such as `filesystem`,
`process`, `program`, `web`, `git`, `worktree`, `browser`, `display`, `plan`,
`prompt_library`, `cron`, `mcp`, `skills`, `sandbox`, `self_extension`,
`worker`, `notifications`, `voice_notes`, and transcription/import surfaces are
not registered by default on this branch.

The agent namespace is prompt-loop infrastructure, not an extra model toolbox.
Public registered functions are limited to `agent::prompt`, `agent::abort`,
`agent::abort_invocation`, and `agent::status`. Hidden internal functions
`agent::prompt_apply` and `agent::run_turn` serialize accepted prompts into the
provider loop and keep session truth consistent.
Deleted product routes such as `agent::run_goal`, `agent::work_snapshot`,
`agent::ask_user`, `agent::spawn_subagent`, subagent status/result/cancel, and
public queue management are not registered.

The teardown scorecard is complete. Retained source is limited to the primitive
loop, generic shell, and evidence paths described here; deleted product routes
are not supported branch behavior.

## Engine Protocol API

Tron exposes one public client capability protocol: the authenticated `/engine`
WebSocket. Domain behavior is addressed only by live canonical
`namespace::function` capabilities discovered through the catalog and invoked
with engine protocol messages. Dotted domain method names are not registered.

### Connection

```
Engine clients:    GET /engine            ws://<host>:<port>/engine            Bearer-authenticated client capability protocol
Workers:           GET /engine/workers    ws://<host>:<port>/engine/workers    Loopback-only local engine workers
Health:            GET /health            http://<host>:<port>/health
Metrics:           GET /metrics           http://<host>:<port>/metrics
```

Engine protocol messages are JSON objects with a `type`, optional correlation
`id`, and camelCase fields:

```json
{"type":"hello","id":"h1","protocolVersion":1,"sessionId":"session-1"}
{"type":"invoke","id":"i1","functionId":"system::ping","payload":{"protocolVersion":1}}
{"type":"response","id":"i1","ok":true,"result":{"child":{"value":{"pong":true}}}}
```

`invoke` accepts only canonical function ids such as `system::ping`,
`agent::prompt`, or `settings::get`. Mutating calls must include an explicit
idempotency key. Message ids are correlation ids only.

When test clients invoke `capability::execute` directly, the transport dispatches
it as the agent actor and passes only the envelope's session, workspace, trace,
authority scopes, and explicit runtime metadata through to the engine. The
transport does not derive profile scopes or capability runtime metadata;
`execute` is the primitive operation boundary.

Hidden functions remain in the engine catalog for internal runtime effects such
as agent apply/run-turn and prompt-history capture. Normal discovery excludes
them and the public transport cannot invoke them directly.

The core request set is `hello`, `discover`, `inspect`, `watch`, `invoke`,
`promote`, `subscribe`, `poll`, `ack`, `heartbeat`, and `goodbye`. Every request
translates into an internal `EngineTransportRequest`, carrying actor,
authority, trace, scope, payload, and explicit idempotency.
Correlation ids are never command ids or idempotency keys. Stream clients should
persist delivered cursors locally and ACK the latest delivered cursor per
subscription, not every event in a burst; ACK responses use normal engine
backpressure so catch-up traffic does not become a socket-fatal overload.
Public `promote` is a user-owned `engine::promote` path, not a client-side
catalog edit: it requires a non-empty `idempotencyKey`, workspace/system
authority, and workspace context for workspace promotion. Owner mismatch,
idempotency, and invalid visibility promotion failures return typed public
error codes with structured details.

`/engine/workers` is the local-first worker protocol. A worker performs a
versioned hello with `WorkerIdentity`, auth policy, registration mode, visibility
scope, heartbeat interval, and supported capability labels; then it registers
canonical function and trigger definitions with the same schema, authority,
effect/risk, idempotency, lease, compensation, visibility, and provenance
metadata as in-process domain workers. Volatile worker entries are
removed on disconnect or missed heartbeat. Durable local worker entries stay in
the catalog but are marked unhealthy when the worker disconnects, so invocation
fails closed until the worker reconnects and re-registers. On SQLite-backed
server restart, durable external worker/function definitions hydrate as
stopped/unhealthy with no handler, so an unclean socket loss cannot become an
optimistic callable function. Workers publish events by asking the engine to
invoke `stream::publish`; there is no direct socket event bypass. Worker
connect/register/disconnect/heartbeat-timeout events are stored on
`worker.lifecycle` through the stream primitive and are visible through retained
ledger/log records while PET-10 finishes primitive substrate cleanup.

Agents do not receive a server-authored helper-launch loop. The retained
`/engine/workers` protocol is host infrastructure for already-running external
workers to register functions and triggers; it is not exported as a provider
tool. Model-created helper behavior must start as ordinary `execute` output,
agent-owned state, workspace files, or generic resources. If a future helper
needs to become a live worker, it must be introduced through explicit host
infrastructure rather than a checked-in product lifecycle.

Engine substrate primitives still provide host infrastructure behind the loop:
state, streams, queues, triggers, grants, generic resources, storage operations,
and bounded internal projections. They are not exported as model tools. The
agent-visible evidence path is `execute` with `trace_list`, `trace_get`, and
`log_recent`; trace operations read durable `trace_records` emitted around every
`execute` call, while `log_recent` reads bounded retained logs through the same
single tool.
Each trace record carries the causal trace id, invocation id, provider tool-call
id, session/workspace, turn, model id/provider, authority envelope, VCS revision
when available, result/error hashes, and file attribution with content hashes.
PET-10 owns deleting or collapsing any remaining substrate workers that are not
required once this trace path and the primitive loop are sufficient.

Fixed helper-orchestration routes are not registered on the primitive teardown
branch. Any future parallel helper behavior must be created by the agent
through `execute` and recorded as agent-owned state or generic runtime
artifacts.

---

## Event System

The primitive branch event store uses an immutable, append-only log with **23 typed event variants**. Sessions remain tree-structured for forks, but the persisted event surface is limited to loop truth: session lifecycle, messages, provider streaming, primitive `execute` invocations, compaction/context boundaries, metadata, errors, and turn failure.

The event enum is generated by the `define_events!` macro in `packages/agent/src/domains/session/event_store/types/macros.rs`, invoked from `packages/agent/src/domains/session/event_store/types/generated.rs`. Adding a new event means editing `generated.rs` and adding a payload type only when the event is true loop infrastructure. Product events, fixed capability events, rules/skills/hooks, prompt queue events, worktree/repo events, push-token events, and config mutation events are intentionally absent on this branch.

### Event Categories

| Domain | Events |
|--------|--------|
| `session` | `session.start`, `session.end`, `session.fork` |
| `message` | `message.user`, `message.assistant`, `message.system`, `message.deleted` |
| `capability` | `capability.invocation.started`, `capability.invocation.progress`, `capability.invocation.completed` |
| `stream` | `stream.text_delta`, `stream.thinking_delta`, `stream.turn_start`, `stream.turn_end` |
| `compact` | `compact.boundary`, `compact.summary_staging`; live `agent.compaction_started` / `agent.compaction` stream events show pre-turn compaction progress and terminal no-op/failure state |
| `context` | `context.cleared` |
| `metadata` | `metadata.update`, `metadata.tag` |
| `error` | `error.agent`, `error.capability`, `error.provider` |
| `turn` | `turn.failed` |

`capability.invocation.started`, `capability.invocation.progress`, and
`capability.invocation.completed` are immutable primitive lifecycle labels for
model-requested `execute` calls. `completed` uses the canonical
`content`/`isError`/`duration` payload shape for both live and reconstructed
sessions.
Active runtime/UI identity is primitive-execution native: payloads carry the
model-visible primitive name, invocation id, trace id, turn, operation
arguments, result content, error state, and duration. iOS renders active work
from those primitive fields and does not map deleted built-in names to
capability identity.

### Event Streaming

Runtime events are projected into neutral server event payloads and stored in
engine streams before `/engine` delivery:

```
TronAgent (run loop)  ->  EventEmitter  ->  Runtime event bus
                                                    |
EngineStreamEventPump  <------------------------------------------+
    |
    v
Engine stream (`events.session`, `catalog`, `jobs`, ...)
    |
    v
/engine subscriptions -> Per-connection WebSocket writers
```

Live `/engine` subscriptions are not history loaders. Session screens reconstruct
persisted history through `session::reconstruct`; their `events.session`
subscription then starts at the current topic tail and carries only future
records. Stateless stream polling and non-session catch-up remain explicit cursor
operations. Stream polling applies engine visibility before pagination, so a
session subscriber is never blocked behind older stream rows owned by unrelated
sessions.
`session::reconstruct` paginates with `beforeEventId` / `oldestEventId` event
IDs, not session-local sequence cursors. Forked sessions reconstruct from the
ordered ancestor chain ending at the child head so inherited parent history and
child events arrive in one server-authored timeline. `tree::get_ancestors`
returns resolved wire `events` for the same reason: clients inspect lineage
without maintaining a second tree-only event shape.

Agent authority is declared before the loop starts through the causal authority
envelope and the one model-visible `execute` primitive. The engine does not
create a runtime permission prompt or resumable permission ledger for autonomous work:
schema, idempotency, resource leases, compensation contracts, allowed scopes,
and the selected primitive operation either validate before execution or return
a normal policy error. The trace record for that `execute` call captures the
authority grant id, scopes, provider/model metadata, request/result hashes, and
file/VCS attribution so the agent can inspect why an action did or did not run.

The `EngineStreamEventPump` routes retained neutral engine/session stream
records to subscribed clients.

---

## Settings

**Location:** `~/.tron/profiles/`

Settings are loaded from three layers (highest priority last):

1. **Active profile settings** (`[settings]` in the resolved `profiles/<name>/profile.toml` chain)
2. **User overlay** (`~/.tron/profiles/user/profile.toml` `[settings]`, deep-merged over the active profile)
3. **Environment variables** (`TRON_*` overrides)

Settings are server-authoritative. Engine-native clients read the current valid `ProfileRuntime` snapshot by invoking `settings::get` and write sparse user overrides through `settings::update` / `settings::reset_to_defaults` with explicit idempotency keys. Missing overlays use profile defaults, but malformed TOML or non-object `[settings]` returns an engine/transport error instead of being repaired silently. Successful writes are serialized, validated, written atomically, and then swapped into the cached `Arc<TronSettings>` and `ProfileRuntime`. If the compiled profile runtime rejects the result, the sparse overlay is rolled back and the last valid runtime snapshot remains active.

The managed `profiles/default/profile.toml` is the auditable seeded baseline from `packages/agent/defaults/profiles/default/profile.toml`, compiled into the agent and written into `~/.tron/profiles/default/profile.toml` during startup seeding/recovery. `profiles/user/profile.toml` is intentionally sparse and high-signal: it stores only values the user/app explicitly changed under `[settings]`. If a managed profile default is missing, corrupt, or stale against the current strict profile schema, startup restores it from compiled defaults; malformed user settings fail fast. iOS device-only preferences live in iOS storage/Keychain, not in the server settings profile.

The schema is defined in `packages/agent/src/domains/settings/implementation/types/`. All field names are camelCase on the wire. **The WebSocket port is a CLI flag (`--port`, default 9847), not a settings field.**

### Key Configuration

```jsonc
{
  "version": "0.1.0",
  "name": "tron",

  "server": {
    "heartbeatIntervalMs": 30000,   // WebSocket heartbeat; 1000-600000 ms
    "defaultProvider": "anthropic",
    "defaultModel": "claude-sonnet-4-6",
    "defaultWorkspace": null,       // Optional quick-chat workspace path set by iOS onboarding/settings
    "tailscaleIp": null             // Cached by the Mac wrapper after live Tailscale pairing resolution
  },

  "agent": {
    "maxTurns": 250
  },

  "context": {
    "compactor": {
      "maxTokens": 25000,           // Context budget
      "compactionThreshold": 0.85,  // Hard ceiling that triggers compaction
      "targetTokens": 10000,        // Target token count after compaction
      "charsPerToken": 4,           // Token estimation factor
      "bufferTokens": 4000,         // Response buffer
      "triggerTokenThreshold": 0.70,// Soft threshold for proactive compaction
      "preserveRecentCount": 5      // Always preserve N most recent messages
    }
  },

  "observability": {
    "logLevel": "info",                         // "trace" | "debug" | "info" | "warn" | "error"
    "verboseRetentionDays": 7                   // Short retention window for verbose diagnostics
  },

  "storage": {
    "retentionEnabled": true,                   // Startup/manual retention may prune low-signal diagnostics
    "maxDatabaseMb": 512                        // Soft cap surfaced by storage reports
  },

  "retry":  { "maxRetries": 1 },

  "session": {}
}
```

---

## Authentication

**Storage:** `~/.tron/profiles/auth.json` (mode 600)

The auth system supports OAuth 2.0 (PKCE), API keys, and multi-account selection. OAuth tokens auto-refresh before expiry. The schema is defined in `packages/agent/src/domains/auth/provider_credentials/types.rs` (`AuthStorage` → per-provider `accounts` + `apiKeys` + `activeCredential`).

Fresh Mac installs seed `auth.json` as the exact empty JSON object `{}`. That sentinel is valid only as pristine install state: first server boot materializes it through the normal atomic `0o600` auth writer into `version`, `providers`, `lastUpdated`, and `bearerToken`. Invalid JSON, unsupported versions, and non-empty partial auth objects remain hard errors and are not overwritten.

### Providers

| Provider | Module | Auth Methods | Notes |
|----------|--------|--------------|-------|
| Anthropic | `domains/model/providers/anthropic/` | OAuth (primary), API key | PKCE OAuth flow; cache pruning supported |
| OpenAI    | `domains/model/providers/openai/`    | OAuth, API key            | OAuth uses ChatGPT/Codex metadata; API keys use Platform `/v1/responses` metadata |
| Google    | `domains/model/providers/google/`    | OAuth, API key            | Cloud Code Assist OAuth, Gemini API key |
| MiniMax   | `domains/model/providers/minimax/`   | API key only              | - |
| Kimi      | `domains/model/providers/kimi/`      | API key only              | - |
| Ollama    | `domains/model/providers/ollama/`    | None (local)              | Requires Ollama running locally on the same Mac as the agent |

### Multi-Account

```bash
tron login --label work
tron login --label personal
```

`auth.json` stores accounts under `providers.<name>.accounts[]` (named OAuth entries) and `providers.<name>.apiKeys[]` (named API keys). The active credential per provider is selected by `providers.<name>.activeCredential`, which is `{type: "oauth"|"apiKey", label}`. Manage from the iOS app, CLI, or canonical `auth::*` capabilities through `/engine` `invoke`. When an API key is saved without a custom label, Tron stores it as `Default`.

OpenAI uses the `openai-codex` provider key for both auth modes. ChatGPT OAuth credentials route to `chatgpt.com/backend-api/codex` and use Codex catalog limits such as `gpt-5.5` and `gpt-5.3-codex` at 272K context. OpenAI API keys route to `api.openai.com/v1/responses` and use Platform limits such as `gpt-5.5` at 1.05M context and `gpt-5.3-codex` at 400K context. `model.list` is auth-path-aware: OAuth shows the live Codex catalog plus documented Codex previews, while API keys show all streaming text/image-in-to-text-out Responses models Tron can serve without a separate image, audio, video, embedding, moderation, realtime, or background provider path. Dated snapshots like `gpt-5.5-2026-04-23` are accepted as hidden aliases and preserve the exact request model ID. Retired OpenAI models remain listed with replacement metadata, but `model.switch` rejects them so they cannot be newly selected; non-streaming models such as `gpt-5.5-pro`, `o3-pro`, and `o1-pro` stay hidden and are rejected by the streaming provider.

### Auth Precedence

1. A session-pinned credential, when present
2. The provider's `activeCredential` from `auth.json` (OAuth or API key, by label)
3. The provider's first OAuth account
4. The provider's first API key

### WebSocket Bearer Token

**Storage:** `~/.tron/profiles/auth.json` top-level `bearerToken` (mode 600, atomic writes)

Stored beside provider auth in the same secure file. This single 32-byte URL-safe-base64 token gates every WebSocket upgrade request. The same token is shared across all paired iOS devices for a given server (per-device tokens are deferred to a future version).

The token is generated during first server startup and written as `bearerToken` inside `~/.tron/profiles/auth.json`. If the installer seeded `{}`, startup rewrites that sentinel into the full auth schema at the same time. The Mac onboarding wizard and iOS pairing flow both display it for the user to copy into the iOS pairing step.

```bash
# Rotate the token (forces every paired iOS device to pair again)
tron auth rotate

# Then use iOS Settings → Servers → Connect to a new server to scan or paste a fresh token.
```

Rotation is serialized through a process-wide mutex and the on-disk write is atomic (`tempfile + sync_all + rename`), so a concurrent rotate from the menu bar and CLI cannot corrupt the file. After rotation the daemon's in-memory token cache picks up the new value within a few seconds via mtime comparison; iOS clients carrying the old token receive HTTP 401 on next connect and fall into `ConnectionState.unauthorized`.

The first-run sentinel `~/.tron/internal/run/.onboarded` is created by the Mac wizard at the end of its install flow OR on the first successful WS auth, and is reported via the `paired` field of the canonical `system::get_info` capability (so an iOS device pointed at a fresh server can distinguish "never been onboarded" from "ready to pair").

See [`packages/agent/src/app/onboarding/mod.rs`](packages/agent/src/app/onboarding/mod.rs) for the full token + sentinel lifecycle.

---

## Context and Compaction

The context system manages the LLM's input window for the primitive loop. Each
turn assembles only the agent soul/system prompt, the compact agent-owned state
projection, environment metadata, conversation history, and any pending
`execute` results. Built-in rules, skills, worker guides, hooks, and profile
policy primers are not model-context planes on this branch.

The prompt loop records context totals in session events and trace metadata.
Before a provider call this is the chars/4 local component estimate; after a
provider call it uses the exact provider-reported context count. When provider
tokenizer/cache accounting is higher than the sum of local sections, trace
metadata carries a provider adjustment so clients can show the attributed
sections plus the provider tokenizer delta without guessing.

### Compaction Pipeline

When context crosses the proactive trigger (default
`triggerTokenThreshold: 0.70` of the model context window), compaction runs
before the next provider call:

1. **Summarize**: A deterministic keyword summarizer condenses older messages.
2. **Stage**: A `compact.summary_staging` event durably records the summary before commit.
3. **Boundary**: A `compact.boundary` event commits the cutoff and carries the summary used by server-side reconstruction.
4. **Trim**: Messages before the boundary are replaced with the summary on runtime reconstruction.
5. **Preserve recent**: The most recent `preserveRecentCount` turns always survive the cut.

If a triggered compaction produces no durable token reduction, the server does
not persist `compact.summary_staging` or `compact.boundary`. It still emits a
terminal live `agent.compaction` event with `success=false` so connected
clients can retire any in-progress compaction indicator without reconstructing
a false boundary.

Compaction is internal prompt-loop infrastructure. It is observable through
session events and primitive trace records, not through public `context::*`
capabilities.

### Context Assembly Order

```
Agent soul / system prompt
  + Agent-owned state summary
  + Environment metadata
  + History reconstructed from session truth
  + Pending user prompt and execute results
```

---

## Database Schema

Default production server storage lives in `~/.tron/internal/database/tron.sqlite`; explicit developer/test homes such as the Mac isolated install use the same `internal/database/tron.sqlite` path under their resolved Tron home. WAL mode stays enabled at runtime with a 5 s busy timeout, foreign keys, bounded auto-checkpointing, and a shutdown checkpoint; `storage::export_snapshot` creates a portable single-file copy when needed. The active DB carries a `storage_generation = "modular-engine-v4"` marker in `storage_metadata`; if startup sees a `tron.sqlite` without the current marker, it archives `tron.sqlite`, `tron.sqlite-wal`, and `tron.sqlite-shm` into `internal/database/archive/modular-engine-v4-*` and starts fresh. Non-current product/session data is archived, not migrated or read by the new runtime. Pre-unified database artifacts are archived the same way and are never read as active storage.

The unified database has one fresh migration surface for primitive session/log/blob tables: `packages/agent/src/domains/session/event_store/sqlite/migrations/v001_schema.sql`. The migration runner registers only that schema; deleted product follow-up migrations are not active on this clean-break branch. Every retained session-store constraint is declared inline on `CREATE TABLE`: `UNIQUE(session_id, sequence)` on events, `CHECK (payload IS NOT NULL OR content_blob_id IS NOT NULL)` on events, and foreign-key checks on session/workspace/blob relationships.

Retained session rows, event rows, Agent Trace-style records, bounded
server/iOS logs, and compressed content-addressed blobs share that same SQLite
file. Large correctness and audit payloads flow through blob refs where the
owning row needs them; compact rows keep human/agent-readable JSON inline. The
model-visible evidence read path is `capability::execute` with `trace_list`,
`trace_get`, and `log_recent`. Trace reads are backed by `trace_records`; every
`execute` call inserts a running record before the effect runs and updates that
same record with status, duration, result/error hashes, authority,
provider/model metadata, VCS revision when available, and file
attribution/content hashes after completion.

### Tables

| Table | Purpose |
|-------|---------|
| `schema_version` | Migration version tracking |
| `workspaces` | Project/directory contexts (id, path, name, timestamps) |
| `sessions` | Session metadata: head pointer, title, model, working directory, turn/token counts, tags, and fork lineage |
| `events` | Immutable append-only event log. Denormalized columns (`role`, `model_primitive_name`, `invocation_id`, `turn`, token counts, `model`, `latency_ms`, `stop_reason`, `provider_type`, `cost`, ...) extracted from payloads for indexed queries |
| `blobs` | Content-addressable deduplicated storage (hash, compressed content, MIME type, uncompressed/compressed size metadata) |
| `logs` | Application logs (level, component, message, error fields, trace IDs) |
| `trace_records` | Agent Trace-style durable records for primitive `execute` calls, including trace/session/invocation/provider ids, model primitive name, operation, status, timestamps, duration, and full JSON `record_json` |
| `engine_invocations` | Engine invocation ledger: function, worker, trace, parent, idempotency, status, result/error summaries |
| `engine_grants`, `engine_grant_events` | Engine-owned authority model: parent/child grants, subject binding, allowed capabilities/namespaces/resource selectors/file roots/network/risk/budget/expiry/delegation, plus lifecycle events |
| `engine_stream_events` | Engine stream publication history with cursor, topic, visibility, trace, and compact payload |
| `engine_catalog_changes` | Live catalog audit trail for worker/function/trigger registration, health, visibility, and lifecycle changes |
| `engine_idempotency_entries` | Durable idempotency reservations and replay records |
| `engine_state_entries`, `engine_queue_items`, `engine_resource_leases`, `engine_compensation_records` | Primitive worker state owned by the engine runtime |
| `engine_resource_type_definitions`, `engine_resources`, `engine_resource_versions`, `engine_resource_links`, `engine_resource_events` | Generic typed resource substrate for agent-owned artifacts, generated UI surfaces, execution outputs, and agent results; resource versions carry `available`, `quarantined`, `damaged`, or `discarded` state |
| `storage_metadata`, `storage_payload_refs` | Storage generation marker plus owner refs for blob-backed payloads (owner kind/id, field, preview, hash, size, retention, trace/session/workspace) |
| `storage_checkpoints`, `storage_exports`, `storage_retention_runs` | Storage operations audit records for checkpoint/export/retention capabilities |

The events table enforces correctness with `UNIQUE(session_id, sequence)` and a single ordering index on `(session_id, sequence)`; most other access patterns are intentionally allowed to scan/filter at our volumes. Session views are reconstructed from the canonical event log. Fresh storage contains no branches, push-token tables, cron tables, constitution audit tables, session profiles, worktree overrides, prompt queue events, config mutation events, rules/skills/hooks events, or deleted product catalog tables.

---

## iOS App

**Minimum iOS:** 26.0 | **Swift:** 6.0 | **Build system:** XcodeGen

### Architecture

The app uses MVVM with coordinators, event plugins, and SwiftUI's `@Observable` macro. The authoritative architecture document is `packages/ios-app/docs/architecture.md`.

```
packages/ios-app/Sources/
+-- App/                  App entry point, delegates, scene phases
+-- Engine/               Engine protocol DTOs, transport, event plugins,
                         local event cache, repositories
+-- Session/              Chat/session view models, messages, parsing,
                         activity summaries, token accounting
+-- Support/              Dependency injection, diagnostics, pairing,
                         settings, storage, feedback, utilities
+-- UI/                   SwiftUI shell, theme, chat, input bar, settings,
                         onboarding, dynamic surfaces
+-- Resources/            Localized strings, fixtures
+-- Assets.xcassets/      Icons and images
+-- Resources/IconLayers/ Source layers for the app icon
+-- Info.plist            App metadata
+-- PrivacyInfo.xcprivacy Apple privacy manifest
```

### Key Patterns

- **MVVM + Extensions**: Large view models split across extension files (`ChatViewModel+Connection.swift`, etc.)
- **Coordinator pattern**: Stateless logic in coordinators, state in view models via context protocols
- **Event plugins**: Live WebSocket events parsed by plugins, dispatched by `EventDispatchCoordinator`
- **History transformer**: Stored events reconstructed into `ChatMessage` arrays by `UnifiedEventTransformer`
- **Primitive chat shell**: the app keeps connection/onboarding/settings,
  session navigation, prompt input, message rendering, local reconstruction,
  diagnostics, and generic runtime surfaces. Fixed product panels,
  repository-specific panels, media workflow surfaces, assistant-management
  panels, extension-source surfaces, audio transcription, memory-retain, rules,
  and parallel tree-only projections are removed from the primary source tree.
- **Dependency injection**: All services via SwiftUI `@Environment(\.dependencies)`
- **Generic runtime rendering**: server/agent-authored runtime data renders through `GeneratedRuntimeSurfaceView`; iOS does not map fixed feature names into custom sheets.
- **Onboarding sheet**: `TronMobileApp.readyContent()` always mounts `ContentView`; when `@AppStorage("onboardingComplete")` is false it presents `OnboardingFlowView`. Settings can reopen the same flow at the Connect page for another server or token refresh, with a dismiss button, and posts that launch only after the Settings sheet has dismissed so SwiftUI presents a single modal at a time. New-server onboarding requires a scanned/pasted/manual token before Connect is enabled; an already paired server row can reuse that server's Keychain token unless the user edits its host or port. Setup pages require a pairing probe plus engine invocations for `settings::get` and setup hydration.
- **Local paired-server model**: `PairedServerStore` keeps the paired Mac list and active server id in iOS storage, while `PairedServerTokenStore` stores each server's bearer token in Keychain. The server never stores the iOS pair list in `profiles/user/profile.toml`.
- **Live engine stream state**: `EngineClient` treats subscription ids as WebSocket-local. It clears active subscriptions when the transport disconnects, recreates the current session subscription at the live topic tail after reconnect/reconstruction, and coalesces stream ACKs to the latest cursor so turn bursts stay inside the engine stream protocol.
- **Setup hydration**: after QR/manual pairing, onboarding reads the active Mac's `settings::get` response and best-effort `auth::get` masked credential state before unlocking setup pages. Pairing a previously forgotten Mac therefore shows the server's existing workspace/model choices and credential hints without storing server settings or secrets on iOS; OAuth/API-key saves refresh those cards immediately from the returned `AuthState`.
- **Forgetting a server**: Settings → Servers → menu → "Forget" removes the server and token locally. If another paired server remains, the app switches locally; if none remain, Settings shows the onboarding CTA.
- **Local diagnostics + feedback**: Tron ships no outbound analytics SDKs and `PrivacyInfo.xcprivacy` declares no collected data. iOS registers `MetricKitDiagnosticsStore` for Apple MetricKit payloads, stores them locally with bounded retention, and includes them only when the user taps Settings -> Send Feedback. `DiagnosticsBundleBuilder` creates one redacted JSON attachment with app/server state, recent local/server logs, session/event summaries, and MetricKit payloads; Settings opens the native Mail composer with the tracked `TRON_FEEDBACK_EMAIL` recipient, subject, body, and JSON attachment, including a body time range when real log timestamps are available. Settings also exposes the Logs sheet in every iOS build configuration so production installs can inspect or copy redacted in-memory client logs without enabling verbose production logging. When connected to a paired server, iOS automatically ingests deduplicated client logs into the server `logs` table through `logs::ingest` with send-boundary redaction, deterministic batch idempotency, and client-side entry fingerprints, so server and client logs share the same durable query surface during normal execution without resending unchanged local buffers. Successful `logs::ingest` transport chatter is filtered at the client-ingestion boundary to prevent self-feeding diagnostics loops while preserving ingestion failures and reconnect warnings. If Mail is unavailable or recipient config is unresolved, Settings shows an alert instead of a share-sheet alternate path. App Store/TestFlight crash diagnostics remain available through Apple's Xcode Organizer path, and release builds keep `dwarf-with-dsym`.

### Data Flow

```
Live:    WebSocket -> EngineClient -> EventRegistry -> Plugin -> EventDispatchCoordinator -> ChatViewModel
Stored:  EventDatabase -> UnifiedEventTransformer -> [ChatMessage] -> ChatViewModel -> ChatView
Prompt:  InputBar -> ChatViewModel -> AgentClient -> agent::prompt
Surface: Generated runtime data -> GeneratedRuntimeSurfaceView
```

### Build Configurations

| Config | Use |
|--------|-----|
| Beta | Debug build, side-by-side bundle ID |
| ProdDebug | Debug build, production bundle ID |
| Prod | Release build, production bundle ID |

### Documentation

Detailed iOS documentation lives in `packages/ios-app/docs/`:

- `architecture.md` — App architecture, patterns, file placement
- `development.md` — Xcode setup, builds, testing
- `events.md` — Event plugin system
- `onboarding.md` — First-run onboarding sheet, QR/deep-link handling, local paired servers, and bearer persistence

---

## Mac App

**Minimum macOS:** 15 Sequoia | **Swift:** 6.0 | **Bundle ID:** `com.tron.mac` | **Build system:** XcodeGen

`Tron.app` is a SwiftUI wrapper around the headless Rust agent. It ships as a notarized DMG via `.github/workflows/release-mac.yml`; production installs run only from `/Applications/Tron.app`. The app bundles signed helpers under `Contents/Library/LoginItems/` (`Tron Server.app` for production/local Release and `Tron Server Dev.app` for isolated Debug install testing), bundled LaunchAgent plists, and profile defaults under `Contents/Resources/Constitution/`. Each helper app contains the `tron` agent binary. The wizard registers the active helper through `SMAppService`, confirms permissions, presents the Tron iOS Beta TestFlight QR, and reveals pairing info for iOS. After the wizard, the app transforms into a menu-bar icon (`LSUIElement = YES`) that checks server health by invoking `system::ping` through `/engine` `invoke`.

```
packages/mac-app/Sources/
+-- TronMacApp.swift           App entry: branches on ~/.tron/internal/run/.onboarded sentinel
+-- EnvironmentSetup.swift     Dev vs release bundle-ID wiring, log paths, shared state root
+-- Wizard/                    First-run flow
|   +-- WizardState.swift      @Observable state machine + `WizardStep` enum
|   +-- WizardView.swift       NavigationStack shell
|   +-- Steps/                 Welcome, Tailscale, Install, Permissions, iOS Beta, Pairing, Done
+-- MenuBar/                   NSStatusItem controller, status polling, copy actions, update submenu
+-- Services/
|   +-- Server/                Bearer-token reader, engine transport client, status poller
|   +-- Onboarding/            SMAppService install planner, permission/Tailscale probes, existing-install detection
|   +-- Pairing/               Tailscale live probe + auth.json bearer-token reader; QR + tron:// URL generation
|   +-- Feedback/              GitHub issue composer with redacted log context
|   +-- Observability/         DiagnosticsRedactor (shared pattern with iOS)
|   +-- LaunchAgentManaging.swift
|   +-- TronPaths.swift        ~/.tron/ path helpers (mirrors Rust `core::foundation::paths`)
+-- Resources/
    +-- Library/
        +-- LoginItems/Tron Server.app/Contents/MacOS/tron
        +-- LoginItems/Tron Server Dev.app/Contents/MacOS/tron
        +-- LaunchAgents/com.tron.server.plist
        +-- LaunchAgents/com.tron.server.dev.plist
```

### Wizard Steps

1. **Welcome** — introduces Tron.
2. **Tailscale prerequisite** — detects `/Applications/Tailscale.app` or the Tailscale CLI, then reads `tailscale status --peers=false --json` for a running backend and 100.x IPv4.
3. **Install** — detects whether the bundled Login Item is registered, but treats that as registered-not-ready until the user presses Install/Start and `system::ping` answers through `/engine` `invoke`. It validates that release builds are running from `/Applications/Tron.app`, validates the helper/plist/signature, registers or refreshes `com.tron.server` through `SMAppService`, handles macOS Login Items authorization by opening Settings when needed, and polls `system::ping` after the initial `hello.ok` frame.
4. **Permissions** — Full Disk Access only. Deep-links to System Settings, labels the exact wrapper app entry to enable, polls wrapper-owned TCC state, starts a short-lived fast-probe watcher after the wizard-opened Settings pane, and keeps Re-check as a non-restarting probe.
5. **iOS Beta** — shows the public Tron TestFlight invite (`https://testflight.apple.com/join/xbuX1Grx`) as a QR code for the iPhone camera, with copy/open alternatives. TestFlight then owns beta availability and update selection.
6. **Pairing** — reads the agent-issued bearer token, confirms the local server heartbeat, resolves this Mac's Tailscale IP live (then caches it in `profiles/user/profile.toml`), detects the Mac's user-facing computer name, and displays host + port + token + server name with copy buttons and a QR code encoding `tron://pair?host=<ip>&port=<port>&token=<token>&label=<server-name>`.
7. **Done** — touches `.onboarded` sentinel, transforms to menu-bar mode.

### Menu-bar Actions

| Item | Action |
|------|--------|
| Custom status header | Shows `Tron`, the Tailscale endpoint, color-coded state, PID, normalized live uptime, and a `Dev Server active` marker when `tron dev` owns port 9847 |
| Show pairing info | Opens a pairing-only window that shows one emerald resolving spinner directly on the window background until the QR + manual copy buttons for host, port, token, and server name crossfade in; copy actions quickly show a checkmark for two seconds on success |
| Restart / Pause / Resume server | `SMAppService.register` repair/load before restart or resume, then `launchctl kickstart` when the label was already loaded; start-like actions post success only after `/health` passes |
| Update finalization | On the first menu-bar launch or command-mode start for a new app build, refreshes stale SMAppService metadata and restarts the bundled server once; the app-version marker is recorded only after `/health` passes, and `tron dev` takeover defers this until the production server is active again |
| Stop dev server | Appears with the server controls whenever `Tron-Dev.app` owns port 9847; stops the dev process and resumes the installed Login Item through the same health-gated path. Pause, restart, and uninstall are disabled while dev takeover is active. |
| Show logs | Opens the native logs window backed by the read-only `logs::recent` capability |
| Send feedback | Opens a prefilled GitHub issue with app/server context and redacted recent logs |
| Uninstall Tron | Confirm dialog + `SMAppService.unregister`; clears `internal/run/` runtime state; optional checkboxes remove `profiles/user/profile.toml` settings overrides and/or `profiles/auth.json`. The database and workspace are always preserved. |
| Quit Tron | Quits wrapper; server keeps running via LaunchAgent |

### Variants & Workflows

The wrapper coexists with local Release testing, Xcode Debug UI dogfood, an isolated Xcode install sandbox, and the `tron dev` agent-only workflow. Production workflows share `port 9847` and the `~/.tron/internal/` data tree; the isolated install scheme deliberately uses `port 9848`, `~/.tron-dev`, `com.tron.server.dev`, and the separate `Tron Server Dev.app` helper whose bundle identifier matches that LaunchAgent label.

| Workflow | Build product | Bundle ID | Lives at | What it is |
|---|---|---|---|---|
| **Production (DMG)** | `Tron.app` | `com.tron.mac` | `/Applications/Tron.app` | Notarized SwiftUI wrapper + bundled headless agent — what end users install |
| **Local Release test** (Xcode Release copied into place) | `Tron.app` | `com.tron.mac` | `/Applications/Tron.app` | Same installed-release path as the DMG; useful for validating local changes before packaging |
| **Debug companion** (default Xcode Run) | `TronMac.app` | `com.tron.mac.dev` | `~/Library/Developer/Xcode/DerivedData/.../Build/Products/Debug/TronMac.app` | SwiftUI wrapper dogfood that coexists with `/Applications/Tron.app`; it observes the production server but does not register, pause, restart, or uninstall it |
| **Isolated install test** (`TronMac Isolated Install` scheme) | `TronMac.app` | `com.tron.mac.dev` | DerivedData | First-run/reinstall sandbox with separate LaunchAgent label, port, and data root |
| **Agent dev** (`tron dev`) | `Tron-Dev.app` (no SwiftUI — just a `.app` wrapping the dev Rust binary) | `com.tron.agent` | `~/.tron/internal/run/Tron-Dev.app` | Headless agent only — used by contributors iterating on the Rust server without rebuilding the wrapper |

Mutual exclusion:
- Duplicate wrappers of the same bundle ID — guarded by `~/.tron/internal/run/.mac-wrapper.<bundle-id>.lock` (`fcntl(F_SETLK, F_WRLCK)`). Release and Debug companion wrappers intentionally use different lock files so their menu icons can coexist.
- Production agents — guarded by `~/.tron/internal/database/tron.sqlite.lock` (cross-process exclusive `flock`).
- LaunchAgent ownership — installed Release is authoritative for `com.tron.server` and repairs stale Debug/DerivedData registrations before restart; default Xcode Debug is companion-only. The `TronMac Isolated Install` scheme owns `com.tron.server.dev` on port `9848` with `TRON_HOME_NAME=.tron-dev` and a Debug-first `AssociatedBundleIdentifiers` list so ServiceManagement attributes the job to `TronMac.app`.
- Port `9847` — `tron dev` calls `launchctl bootout com.tron.server` before binding, so the installed helper is paused while dev-mode runs.
- Direct server guard — if no LaunchAgent owns the service but port `9847` is already bound or `internal/database/tron.sqlite.lock` is held, the app reports another Tron server instead of registering a second helper or choosing a different port.

A contributor can have the DMG installed AND run the default Xcode Debug wrapper for menu/wizard UI work; both menu icons can coexist and both observe the production server. Running `tron dev` is still the explicit server-takeover path for Rust-agent iteration: the wrapper's menu bar keeps pinging port 9847, reports the `Tron-Dev.app` PID/uptime, and shows `Dev Server active` while dev owns the port. Quitting `tron dev` restarts the installed helper by invoking `/Applications/Tron.app/Contents/MacOS/Tron --tron-start-server-and-quit`, which re-enters the same `SMAppService` registration path used by the app; the CLI reports the installed service as restarted only after `/health` passes, records the finalized app-version marker on success, and stale installed helpers that cannot parse current profile defaults must be updated rather than papered over. The menu-bar Stop Dev action follows the same rule, showing `Resume failed` when ServiceManagement loads an unhealthy installed helper instead of posting a false recovery. Pre-onboarding production cleanup uses the installed app's paired internal command `--tron-uninstall-and-quit` so stale Login Item registrations are removed by `SMAppService.unregister` instead of only being booted out of launchd; Debug companion command mode refuses to uninstall production. See [`packages/mac-app/docs/architecture.md` → Workflows & Variants](packages/mac-app/docs/architecture.md#workflows--variants) for the full breakdown including the on-disk artifacts each workflow shares.

### Documentation

- `packages/mac-app/docs/architecture.md` — wizard + menu bar + helper-binary lifecycle
- `packages/mac-app/docs/development.md` — workflow quick reference for Xcode Debug, local Release install testing, `tron dev`, and DMG release, plus XcodeGen/signing setup

---

## Permissions

The Mac wizard surfaces one system permission after the server is installed. Full Disk Access has an "Open System Settings" deep link when revoked, and the row names the exact wrapper app entry macOS expects in that pane.

| Permission | Why | Required | Probe |
|------------|-----|----------|-------|
| Full Disk Access | Agent reads/writes user-selected files and app data outside the sandbox | Yes | Wrapper process opens FDA-gated user data |

The install step validates the active signed helper (`Tron Server.app` for production/Release or `Tron Server Dev.app` for isolated Debug), registers the bundled LaunchAgent through `SMAppService`, and waits for the first heartbeat. Ordinary agent startup does not probe TCC or open System Settings, so macOS permission prompts cannot appear while the user is still on the install step. The LaunchAgent's `AssociatedBundleIdentifiers` lists the wrapper bundle IDs in the order appropriate for the active workflow, so macOS presents the helper's privacy grant under the responsible wrapper app: `Tron.app` in Release and `TronMac.app` in Debug. The wizard row therefore names the wrapper app, not the helper app. The settings button only opens System Settings; it never calls prompt APIs that would create a second modal over the already-open pane. Re-check/app activation use native non-prompting probes. Once Full Disk Access is green, Continue restarts the helper one time so launch-time-applied grants are visible to the server before pairing.

---

## Deployment

### Deploy Pipeline

```bash
tron deploy          # Full pipeline with confirmations
tron deploy --force  # Skip uncommitted-changes / test-failure prompts
tron deploy --ci     # Non-interactive: any failure aborts
```

`tron deploy` is a contributor-only script path and is not the production Mac distribution mechanism. Production releases are the notarized DMG pipeline below; end users replace `/Applications/Tron.app` from that DMG.

The deploy process (`scripts/tron.d/deploy.sh::cmd_deploy`) is retained for local contributor workflows:

1. Aborts if a dev server is bound to the prod port.
2. Warns on uncommitted changes (errors out under `--ci`).
3. Builds the release binary (`cargo build --release`).
4. Runs `cargo test`. Failures prompt for continuation unless `--ci`.
5. Under `--ci`, also runs the benchmark gate.
6. Uses contributor-only artifacts directly under `~/.tron/internal/run/`.
7. Seeds managed defaults and runtime support.
8. Runs local health checks for the contributor server.

### Install Directory

Base directories in the tree below are resolved through helpers in `packages/agent/src/shared/foundation/paths.rs`. To rename a directory, change the constant in `dirs::*` there and every call site updates automatically. The engine ledger file is derived from the resolved event DB path in `packages/agent/src/engine/host.rs`.

```
~/.tron/
+-- profiles/                     Agent execution specs and built-in auth
|   +-- active.toml                Active profile pointer
|   +-- auth.toml                  Readable credential-profile registry
|   +-- auth.json                  LLM provider OAuth tokens + API keys + bearerToken (mode 600)
|   +-- default/                   Managed, restorable base AgentExecutionSpec/manual
|   |   +-- profile.toml           Complete typed AgentExecutionSpec v3
|   +-- normal/                    Managed standard workspace/session profile
|   |   +-- profile.toml           Inherits default; profileClass = "normal"
|   +-- chat/                      Managed quick-chat profile
|   |   +-- profile.toml           Inherits default; quick-chat provider defaults
|   +-- local/                     Managed local-provider profile
|   |   +-- profile.toml           Inherits default; local-provider defaults
|   +-- user/                      Sparse user profile/settings/prompt overrides
|       +-- profile.toml           Sparse `[settings]` overrides
+-- memory/                       Durable user/agent continuity
|   +-- MEMORY.md                  Canonical single-file root (name, preferences, active projects)
|   +-- rules/                     Optional user-authored continuity detail files
|   +-- sessions/                  Optional agent-owned session summaries
+-- workspace/                    Active work and generated artifacts
|   +-- projects/                  Project-local active work
|   +-- plans/                     Plan files and TODOs
|   +-- reports/                   Analysis and investigation reports
|   +-- renders/                   Rendered pages displayed in chat
|   +-- screenshots/               Saved screenshots from runtime execution
|   +-- scratch/                   Downloads, temp files, experiments
|   +-- labs/                      Manifested experimental spaces
|   +-- archive/                   Archived workspace material
|   +-- knowledge/                 Curated wiki/research experiment
|   +-- vault/                     Local fast secret storage for agent-owned workspace state
+-- internal/                     Tron-owned runtime machinery
    +-- database/                  Unified SQLite engine storage and archives
    |   +-- tron.sqlite            Events, sessions, logs, blobs, engine ledger, streams, state, queues, typed resources, leases, compensation, workers
    |   +-- tron.sqlite.lock       OS-level flock sidecar; one Tron process owns it while running
    |   +-- archive/               One-way archive of non-current storage generations
    |   +-- journals/              Streaming journals for crash recovery of partial LLM output
    +-- run/                       Mutable runtime state and local contributor artifacts
    |   +-- auth.lock              Auth-file refresh lock
    |   +-- auto-deploy.lock       Contributor deploy concurrency lock
    |   +-- auto-deploy.pause      Contributor deploy pause sentinel
    |   +-- deploy.lock            Manual deploy concurrency lock
    |   +-- .mac-wrapper.*.lock    Per-wrapper menu app lock
    |   +-- .onboarded             First-run sentinel; presence drives `system::get_info.paired`
    |   +-- mac-app-version.json   Last app build whose menu-bar launch finalized the server
    |   +-- Tron-Dev.app           Optional `tron dev` headless agent bundle
        +-- worker.py              parakeet-mlx Python worker
        +-- requirements.txt       Pip deps for the venv
        +-- venv/                  Auto-created when enabled and the sidecar starts
        +-- models/hf/             HuggingFace model cache (HF_HOME)
```

Notes:
- The four top-level homes are the primitives: behavior in `profiles`, continuity in `memory`, active substrate in `workspace`, and runtime machinery in `internal`.
- Credentials for external CLIs (Google Workspace, etc.) live in `~/.tron/workspace/vault/`. Tron-owned provider auth and the bearer token live in `~/.tron/profiles/auth.json`.
- Pause/lock sentinels live under `~/.tron/internal/run/` with the rest of the runtime machinery. They are managed by the respective CLI subcommands, not user-edited at the Tron Home root.

### Service (SMAppService)

The production Mac app registers `com.tron.server` with `SMAppService.agent(plistName: "com.tron.server.plist")`. The notarized app must live at `/Applications/Tron.app`; the bundled LaunchAgent lives inside the app at `Contents/Library/LaunchAgents/com.tron.server.plist`, and its `BundleProgram` points at `Contents/Library/LoginItems/Tron Server.app/Contents/MacOS/tron` with `ProgramArguments` of `tron --port 9847 --quiet`. `AssociatedBundleIdentifiers` lists the wrapper bundle IDs (`com.tron.mac`, then `com.tron.mac.dev`) so Login Items/TCC attribution follows the responsible wrapper app. No production code writes `~/Library/LaunchAgents` or copies an app bundle into `~/.tron/internal/`. An enabled Login Item registration without a loaded launchd job is not treated as installed/running; the current app replaces that registration through SMAppService and still waits for the server heartbeat. If `launchctl print` reveals a stale event trigger pointing at a missing/mismatched helper executable, a stale parent bundle build number for the same installed app, stale launch constraints such as `needs LWCR update`, or a Debug/DerivedData parent owns the production label, the installed app boots it out, unregisters the stale registration, and re-registers `/Applications/Tron.app` before restarting.

Local Release builds use the same path rule: copy the built `Tron.app` to `/Applications/Tron.app` before testing install/registration. If a DMG build is already installed, the local Release build replaces that same slot; reopen `/Applications/Tron.app` or run `tron start`/`tron restart` so the wrapper repairs SMAppService before launchd executes the bundled server. Start-like menu actions, command-mode starts, contributor CLI start/restart, and update finalization wait for `/health` after ServiceManagement reports loaded; the app-version marker is recorded only after that health gate succeeds. Loaded-but-unhealthy helpers remain visible failures until `/Applications/Tron.app` is updated or reinstalled. Default Debug Xcode builds use bundle ID `com.tron.mac.dev`, may run from DerivedData, and are companion-only: they can show the menu bar and observe the production server, but server pause/restart/uninstall/install actions are disabled. Use the `TronMac Isolated Install` scheme when testing the first-run/reinstall wizard from Xcode; it registers `com.tron.server.dev`, points `BundleProgram` at `Tron Server Dev.app`, runs on port `9848`, and stores data under `~/.tron-dev`. For agent-only iteration, `tron dev` stops the production LaunchAgent, binds port `9847`, and later restores the installed helper through the wrapper's internal `--tron-start-server-and-quit` command so ServiceManagement remains the only production registration path.

### DMG Release Pipeline

End-users install `Tron.app` via a notarized DMG published to GitHub Releases. Release identity is centralized in `VERSION.env`: the first beta is canonical `0.1.0-beta.1`, Apple bundles receive numeric `MARKETING_VERSION = 0.1.0` / `CURRENT_PROJECT_VERSION = 1`, and human-facing UI renders `v0.1 (Beta 1)`. The pipeline lives at `.github/workflows/release-mac.yml` and triggers on a matching `server-v*` tag push:

1. Checkout + Rust toolchain/cache (`actions-rust-lang/setup-rust-toolchain`).
2. `scripts/tron version check` verifies `VERSION.env`, Cargo, Cargo.lock, Mac/iOS `project.yml`, custom bundle canonical version keys, and release docs agree before any artifact is built. A tag push must equal `server-v$(TRON_VERSION)`.
3. `cargo build --release --bin tron --locked` in `packages/agent/`.
4. Install XcodeGen + `create-dmg`.
5. `packages/mac-app/scripts/bundle-agent.sh --skip-build` stages `packages/agent/target/release/tron` into both bundled helpers (`Tron Server.app` and `Tron Server Dev.app`) and writes both LaunchAgent plists.
6. `xcodegen generate` inside `packages/mac-app/`.
7. Create an isolated release keychain from the signing/notarization secrets, or fall back to dry-run ad-hoc signing when secrets are absent.
8. `xcodebuild archive` with `-scheme TronMac -configuration Release`.
9. Verify the bundled helper app, both helper executables, LaunchAgent plist, and profile defaults are present in the archive.
10. Sign the helper apps first, then sign `Tron.app` with hardened runtime + `TronMac.entitlements`; verify inside-out signatures before DMG packaging.
11. `xcrun notarytool submit` the signed `Tron.app` with `$NOTARIZE_PROFILE` (`tron-notarize`); staple the app on success.
12. Build the DMG with `create-dmg`, sign the DMG, submit that signed DMG to `notarytool`, then staple the DMG. The app and DMG require separate notary tickets.
13. Keep dSYMs in the Xcode archive/release artifacts for Apple crash diagnostics.
14. `scripts/tron-release-notes` writes a bounded draft changelog body from first-parent git history since the previous release tag, including the DMG filename, SHA256, and a full compare link. The body starts below GitHub's release title so the rendered page does not repeat the release name. The beta1-to-beta2 pump recognizes the historical Mac-scoped beta1 tag so the first `server-v*` release does not include the entire repo history.
15. `gh release create server-v0.1.0-beta.1 ./tron-v0.1.0-beta1.dmg` creates a draft GitHub pre-release titled `Tron Server v0.1 (Beta 1)` with the generated changelog; maintainers publish after installing and verifying the DMG.

A parallel dry-run job runs on every PR that touches `packages/mac-app/**` or the workflow itself. The dry-run stops before notarization (no cert needed) so PR contributors can verify the assembly pipeline without secrets.

The iOS TestFlight pipeline lives at `.github/workflows/release-ios.yml` and triggers on the same `server-v*` tag push. It regenerates `packages/ios-app/TronMobile.xcodeproj` from XcodeGen, verifies `VERSION.env` mirrors, runs the iOS simulator tests, archives the `Tron` scheme with the `Prod` configuration (`com.tron.mobile` / App ID `6761511764`), exports an App Store Connect IPA with Xcode's `app-store-connect` export method, uploads with `asc builds upload`, waits for the Apple build to become valid, resolves TestFlight export compliance, updates What to Test notes, submits TestFlight beta review when Apple requires it for external testing, and branches on the ASC review state. First external builds for a new marketing version normally enter `WAITING_FOR_BETA_REVIEW`; CI treats that as a successful pending-review checkpoint instead of timing out. Once Apple approves the version, rerunning the workflow or uploading later builds in the same version continues to group validation and assigns the build to the public external TestFlight group when one is configured or can be auto-discovered. The public group is the same TestFlight link shown by the Mac onboarding QR code. TestFlight group checks are warning-only after the build is uploaded and processed because successful public distribution must not be blocked by stale or renamed group variables that CI does not need to create the beta build. Reruns are idempotent: if the Apple build number already exists in App Store Connect, CI skips the binary upload and reuses that build for processing/distribution. Manual workflow runs default to `dry_run=true` and stop before ASC upload.

Required iOS release credentials are GitHub Actions secrets `ASC_KEY_ID`, `ASC_ISSUER_ID`, and `ASC_KEY_P8_BASE64`. `ASC_TESTFLIGHT_PUBLIC_GROUP_ID` and `ASC_TESTFLIGHT_INTERNAL_GROUP_ID` are optional repository variables used for group assignment diagnostics; CI can auto-discover a single public-link group and otherwise skips group assignment without failing an uploaded/processed build. CI can export with automatic Xcode cloud signing through the ASC key, or with local signing secrets when `IOS_DISTRIBUTION_CERT_P12_BASE64`, `IOS_DISTRIBUTION_CERT_PASSWORD`, `IOS_APPSTORE_PROFILE_BASE64`, and `IOS_SHARE_EXTENSION_APPSTORE_PROFILE_BASE64` are set. Local signing supports both manually managed App Store profiles and matching Xcode-managed App Store profiles. `ASC_KEY_ID` and the `.p8` path can be checked locally with `asc auth status --verbose` / `asc auth doctor`; `ASC_ISSUER_ID` is shown in App Store Connect under Users and Access -> Integrations -> App Store Connect API -> Team Keys. The iOS app and share extension declare `ITSAppUsesNonExemptEncryption=false`; CI verifies that key in the archive/export and can apply the same App Store Connect API build setting to already-uploaded builds that predate the plist key. TestFlight/App Store Connect remains the distribution and audit surface for iOS binaries. Do not create separate GitHub releases for iOS unless an iOS artifact is intentionally published through GitHub too; the shared `VERSION.env` keeps Mac/server and iOS version labels aligned without adding duplicate tags.

## Testing

### Rust Tests

```bash
cd packages/agent
cargo test                   # Full suite (single `tron` crate)
cargo test paths::           # Filter by module path
cargo test --quiet           # Quiet output
```

The agent is a single `tron` crate, so `cargo test` runs everything (lib unit tests, integration tests, doc tests, the `main_tests.rs` binary tests). Test counts are intentionally not hardcoded in this README — they drift within days and mislead readers. Re-derive from `cargo test --quiet` output when you need the current number.

### iOS Tests

```bash
cd packages/ios-app
xcodegen generate
xcodebuild test -scheme Tron -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

### CI

```bash
tron ci                      # Run every check (fmt, check, clippy, test, bench, doc)
tron ci fmt check            # Subset: formatting + compilation
tron ci clippy test          # Subset: linting + tests
```

Install the local hook once per clone with `scripts/install-hooks.sh`; it
blocks commits with staged Rust formatting drift and runs the personal-info
guard on staged changes.

Rust clippy CI uses the lint policy in `packages/agent/Cargo.toml`: correctness,
suspicious, performance, and a short list of footgun lints fail the build;
style/pedantic suggestions stay advisory so the signal is not buried.

---

## Core Invariants

These constraints are enforced in code with `// INVARIANT:` markers at the enforcement site.

1. **Canonical engine execution**: Production behavior is owned by canonical engine functions. The public `/engine` protocol is only transport; domain behavior is discovered and invoked by canonical `namespace::function` ids.

2. **Fail-fast on unknown models**: Unknown model or provider returns a typed `UnsupportedModel` error immediately. No silent substitution or default provider substitution.

3. **Deterministic event reconstruction**: Session state is always reconstructable from the immutable event log. No mutable session state stored outside events.

4. **Session-serialized writes**: All event appends are serialized per-session via in-process mutex locks. SQLite `UNIQUE(session_id, sequence)` enforces ordering at the DB level.

5. **Event ordering (iOS send button)**: `agent.ready` is emitted AFTER `agent.complete`. Clients see active work as `processing` and every terminal or between-turn window as `idle`; compaction and ledger state stay independent.

6. **Primitive context boundary**: model context contains soul, agent-owned state, environment, session history, and pending `execute` results. Built-in rules, skills, hooks, worker guides, and profile primers are not prompt planes.

7. **Compaction before provider calls**: threshold-triggered compaction runs before the next provider call and only persists a boundary when it reduces durable context.

8. **Database path guard**: Startup validates the database path is exactly `<resolved-tron-home>/internal/database/tron.sqlite`. Rejects alternate filenames, wrong directories, and symlinked paths.

9. **Single-process DB ownership**: Startup takes an OS-level `flock(2)` on `tron.sqlite.lock` before opening the connection pool. A second `tron` process pointed at the same database aborts with a clear error naming the holder's PID, instead of silently racing on `(session_id, sequence)` writes. Released on process exit (normal or abnormal). Enforced by `domains/session/event_store/sqlite/process_lock.rs::acquire_database_lock` called from startup database initialization.

---

## License

MIT
