# Tron

**A persistent, event-sourced AI coding agent for macOS.**

Tron is a local-first AI coding agent that runs as a persistent background service. A Rust server handles LLM communication, capability execution, grants, typed resources, and event-sourced session persistence. A native iOS app provides a thin chat and Engine Console harness over the server-owned substrate.

This README is the single, canonical reference for the project and is expected to stay in sync with the code. The Rust codebase is self-documenting: `packages/agent/src/lib.rs` declares the module tree, `mod.rs` files map submodules, and `// INVARIANT:` comments mark critical correctness constraints. iOS documentation lives in `packages/ios-app/docs/`. When you change anything described here — modules, CLI commands, capabilities, engine protocol methods, event types, settings fields, DB tables, install layout — update this file in the same commit.

---

## Table of Contents

- [Architecture](#architecture)
- [Modular Engine Audit](#modular-engine-audit)
- [Collapsed Modular Engine](#collapsed-modular-engine)
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
|  |  Anthropic  |  | search     |  |  loader    |  |  Session lifecycle     | |
|  |  OpenAI     |  | inspect    |  |  compaction|  |  Turn management       | |
|  |  Google     |  | execute    |  |  skills    |  |  Event routing         | |
|  |  MiniMax    |  | workers    |  |  rules     |  |  Subagent coordination | |
|  +-------------+  +------------+  +------------+  +------------------------+ |
+------------------------------------+----------------------------------------+
                                     |
                                     v
+-----------------------------------------------------------------------------+
|                         Event Store (SQLite)                                |
|   - Immutable event log with tree structure (fork/rewind)                   |
|   - Session state reconstruction via ancestor traversal                     |
|   - SQLite-backed sessions, events, branches, cron, prompts, and devices    |
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

## Modular Engine Audit

The durable audit for the post-mobile-first direction lives in
[`docs/modular-engine-audit.md`](docs/modular-engine-audit.md). It inventories
the Rust server and iOS app, classifies engine-kernel, core-runtime,
capability-module, and product-shell surfaces, and defines the target direction:
Tron as a modular local capability engine with a thin chat and generated-native
UI harness.

The cleanup proof map for removing product-shell surfaces and consolidating the
recent modular-engine additions lives in
[`docs/modular-engine-cleanup-audit.md`](docs/modular-engine-cleanup-audit.md).

## Collapsed Modular Engine

The implementation target for the modular-engine rebuild lives in
[`docs/collapsed-modular-engine-architecture.md`](docs/collapsed-modular-engine-architecture.md).
The next substrate checkpoint is planned in
[`docs/modular-engine-next-phase-plan.md`](docs/modular-engine-next-phase-plan.md).
The core rule is one substrate: workers invoke capabilities against typed
resources under scoped grants. Artifacts, goals, claims, evidence, decisions,
generated UI surfaces, module config, worker packages, activation records,
secret refs, and materialized files are modeled as resource kinds rather than
separate persistence planes. The current substrate slice has engine-owned
`grant::*` authority, built-in resource type definitions for artifacts, goals,
claims, evidence, decisions, generated UI surfaces, materialized files, patch
proposals, execution outputs, agent results, worker packages, module configs,
and activation records, thin wrapper capabilities over the generic
`resource::*` kernel, resource-backed output enforcement for converted
durable-output paths, a fixed `tron.ui.catalog.core.v1` generated UI catalog,
server-authored `ui::*` surface/action capabilities, `module::*` package
lifecycle, health, integrity, and recovery capabilities, and control
projections that expose `uiSurfaceRefs` plus module resource refs without
adding durable control-plane state.

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
|   +-- tron                CLI for build, deploy, service management
|   +-- tron-version        Version print/check/sync helper used by CI + releases
|   +-- tron-release-notes  Deterministic tagged-release changelog generator
|   +-- tron-lib.sh         Shared bash helpers used by scripts/tron
|   +-- tron-cli            Contributor CLI helper for local service management
|   +-- tron-ios-beta       Local physical-device build/install/stop helper for the iOS beta
|   +-- auto-deploy         Background auto-deploy worker (contributor-only; refuses to run outside a git repo)
+-- docs/
|   +-- collapsed-modular-engine-architecture.md Collapsed worker/capability/resource target
|   +-- manual-testing-readiness.md Clean manual-QA checklist for the capability runtime
|   +-- modular-engine-audit.md     Audit and target direction for the modular engine pivot
|   +-- modular-engine-cleanup-audit.md Proof map for cleanup/removal decisions
+-- .github/
|   +-- workflows/          CI + Mac/iOS release pipelines
|   +-- ISSUE_TEMPLATE/     Structured bug/feature report forms
|   +-- dependabot.yml      Weekly Cargo + GitHub Actions updates, monthly Swift
|   +-- pull_request_template.md
+-- .claude/
    +-- CLAUDE.md           AI agent project instructions
    +-- rules/              Path-scoped AI navigation rules
```

---

## Rust Modules

The agent is a single `tron` crate (see `packages/agent/Cargo.toml`). The crate tree now mirrors the pure engine model: app/bootstrap, thin transports, the engine fabric, worker-owned domains, platform integrations, and shared foundation/protocol helpers. Dependencies flow inward: transports build engine requests, domains own behavior, and the engine owns policy/ledger/streams/queues/workers.

```
app/        Binary/server bootstrap, health, metrics, onboarding, shutdown
transport/  /engine client protocol, /engine/workers socket transport, auth gate
engine/     Live capability fabric: catalog, workers, triggers, ledger, streams, queues
domains/    Every Tron worker: contracts, deps, handlers, operations, local services, tests
platform/   OS/vendor integrations: APNS, device broker, updater
shared/     Foundation IDs/errors/paths, protocol DTOs, unified storage helpers
main.rs     Thin CLI/startup entry point
```

| Module | Purpose | Key Types |
|--------|---------|-----------|
| `app` | Startup/bootstrap + HTTP shell | `TronServer`, `ServerConfig`, `ShutdownCoordinator` |
| `transport` | Thin protocol surfaces over the engine envelope | `EngineTransportRequest`, `run_engine_ws_session`, `BearerTokenStore` |
| `engine` | Live capability fabric, primitive workers, local worker protocol, typed resource kernel | `LiveCatalog`, `EngineHostHandle`, `FunctionDefinition`, `WorkerDefinition`, `Invocation`, `InvocationRecord`, `EngineResource`, `EngineResourceTypeDefinition` |
| `domains` | Worker-owned Tron behavior and implementation code, including the collapsed capability harness and registry/index projection | `registration::register_domain_workers_for_context()`, `capability::worker_module()`, `capability::registry::CapabilityRegistrySnapshot`, `DomainWorkerModule`, per-domain contracts/deps/handlers |
| `platform` | OS/vendor/product-protocol integrations | APNS senders, updater scheduler |
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
`domains/agent/runtime/*`, `domains/session/event_store/*`,
`domains/capability_support/implementations/*`, and `domains/worktree/implementation/*`.
`domains/program/*` owns the parent-side program capability plus the
`tron-program-worker` OS process runtime. Provider-native stream/function-call
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
3. Launch `Tron.app`. The wizard handles Tailscale detection, required permissions, server install, local transcription preference, and the iOS handoff.
4. On iPhone, scan the wizard's Tron iOS Beta QR code to open the public TestFlight invite, install the latest available Tron beta, then scan the Mac pairing QR or enter the pairing fields manually.

The wizard and menu bar surface everything else (`Check for updates`, `Send feedback`, `Restart server`, etc.) — you never need the CLI unless you want to.

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

Build with the `Tron` scheme (or `Tron Beta` for the beta variant). The app starts without a server until the user pairs a Mac through onboarding.

Codex app local actions are checked in under
`.codex/environments/environment.toml`. Open this project root in the Codex app
to get toolbar actions for starting `scripts/tron dev -bdt`, stopping the dev
server with `scripts/tron dev --stop`, rebuilding/installing/launching the local
iOS beta with `scripts/tron-ios-beta install`, and launching the already-installed
beta with `scripts/tron-ios-beta launch`. If the device was locked during install,
the launch action relaunches the already-installed app without rebuilding. The
iOS helper deliberately does not store personal device details;
it auto-selects the only available physical iOS device, or you can set
`TRON_IOS_DEVICE_ID` or `TRON_IOS_DEVICE_NAME` in your local terminal
environment before running it.

See [CONTRIBUTING.md](CONTRIBUTING.md) for commit conventions, TDD expectations, and release workflows.

---

## CLI Reference

The `scripts/tron` CLI manages workspace development and contributor service workflows. The dispatch table is at the bottom of `scripts/tron` (the `case "$1" in` block); when adding or renaming a subcommand, update this table.

### Development (workspace only)

| Command | Description |
|---------|-------------|
| `tron dev` | Start the dev-profile server in the foreground (`-b` build first, `-t` test first, `-d` background via `nohup`). Stops the installed `com.tron.server` job before binding port `9847`, loads push relay env from `packages/mac-app/.env.local` when present, waits for `/health` in background mode, writes pre-database startup output to `~/.tron/internal/run/tron-dev-background.log`, and restores the installed helper through `/Applications/Tron.app` on exit/stop. |
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
| `tron auto-deploy` | Contributor-only auto-deploy watcher (`install`, `uninstall`, `status`, `pause`, `resume`, `logs`). Refuses to run outside a git repo — for DMG users, see `tron self-update` instead. |
| `tron self-update` | User-mode GitHub Releases updater (`check`, `status`, `pause`, `resume`, `logs`, `reset`). Opt-in via `server.update.enabled`; gated by `~/.tron/internal/run/auto-update.pause` sentinel. |

### Runtime

| Command | Description |
|---------|-------------|
| `tron start` | Start the launchd service (`com.tron.server`) |
| `tron stop` | Stop the service |
| `tron restart` | Restart the service |
| `tron status` | Show service status, PID, port |
| `tron rollback` | Restore the previous binary from backup (`--yes` skips confirm) |
| `tron login` | Authenticate with a provider (`--label <name>` for multi-account) |
| `tron auth rotate` | Rotate the WebSocket bearer token (forces every paired iOS device to pair again) |
| `tron logs` | Query database logs (`-h` for filter options) |
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

The model-facing harness is intentionally collapsed to three live capability
primitives registered by the `domains::capability` worker:

| Primitive | Description |
|-----------|-------------|
| `search` | Search the live catalog for contracts, implementations, workers, plugins, examples, and docs visible to the current actor/session/workspace. |
| `inspect` | Inspect one capability contract and selected implementation, including schemas, risk, authority, idempotency, approval, leases, compensation, provenance, schema digest, and expected revision. |
| `execute` | Invoke a selected capability through the engine ledger, or run a bounded JavaScript program that composes capabilities through the same primitive surface. |

Filesystem, code search, shell/process, web, plugin source, iOS/app interaction, display,
notifications, subagents, and sandbox workers are not provider-facing built-ins.
They are worker-owned capabilities discovered and invoked through the three
primitives. Provider integrations do not expose their implementation names directly.

The default `coreFirstParty` primer is generated from registry metadata and
includes the high-use first-party capabilities the agent should know without a
search round trip. The same registry projection also generates
`AgentCapabilityRecipe` records for search and inspect results, so capability
discovery returns copyable `execute` templates, required payload fields,
approval behavior, lifecycle notes, and result expectations instead of bare ids.
Important parity anchors are:

| Previous surface | Capability contract |
|------------------|---------------------|
| file read/write/edit/list/find/search/diff | `filesystem::read_file`, `filesystem::write_file`, `filesystem::edit_file`, `filesystem::list_dir`, `filesystem::find`, `filesystem::glob`, `filesystem::search_text`, `filesystem::diff`, `filesystem::apply_patch` |
| shell/process | `process::run` |
| web search/fetch | `web::search`, `web::fetch` |
| app notification | `notifications::send` |
| capability discovery/execution | `capability::search`, `capability::inspect`, `capability::execute` |

`process::run` and `notifications::send` both have direct, low-overhead paths
for safe/default use. `process::run` requires `executionMode`: classifier-
approved read-only checks such as `date`, `git status`, and `git log` run
directly with `executionMode = "read_only"`, while write-like commands must use
`executionMode = "sandbox_materialized"` with declared `expectedOutputs` that
are materialized back through resource refs. It defaults to the active session
worktree/workspace when `cwd` is omitted and accepts bounded timeout fields in
milliseconds. `notifications::send` sends through the first-party notification
delegate with an idempotency key and normal audit/event records.

Capability identity is projected from the live catalog:

| Shape | Meaning |
|-------|---------|
| `contractId` | Stable abstract interface. First-party functions default to their canonical engine id unless richer plugin manifests provide explicit contracts. |
| `implementationId` | Concrete provider. First-party catalog functions default to `first_party.<worker>.v<revision>.<function>`, while external/session workers must register implementation metadata within their namespace claims. |
| `pluginId` | Owning package/domain. Existing first-party workers default to `first_party.<worker>`, while plugin source defaults to `external.pluginSources`. |

`search` runs through the durable capability registry in the engine ledger
database, not a handwritten capability list. The registry stores projected
contracts, implementations, plugin manifests, bindings, inspection handles,
binding decisions, audit events, index documents, and `sqlite-vec` vector
metadata over the live runnable catalog. Semantic ranking is local-only via the
first-party `fastembed` ONNX/tokenizer bundle embedded in the Rust agent binary
plus a persistent `sqlite-vec` `vec0` index in `tron.sqlite`, with deterministic
lexical/vector fusion. The default `hybridLocal` policy prefers local vectors
and explicitly reports degraded lexical status while the vector index is
warming or unavailable, rather than failing the agent's catalog search. Profile
TOML can opt into strict vector-required behavior for tests or specialized
profiles. Profile TOML v3 keeps runtime-shaping policy separate: provider
primitive exposure lives in `primitiveSurfacePolicies.*`, concrete execution
constraints live in `capabilityExecutionPolicies.*`, search behavior lives in
`capabilitySearchPolicies.*`, and generated first-party recipe context lives in
`capabilityContextPrimerPolicies.*`. See
[`packages/agent/docs/profile-control-plane.md`](packages/agent/docs/profile-control-plane.md)
for the profile v3 control-plane schema and invariants.
Engine Console/admin status refreshes synchronously update registry metadata,
then warm the persistent vector index on a detached path. Agent search skips
metadata resync when the durable registry already matches the live catalog
revision; meaningful catalog/plugin/schema changes update metadata once and
warm missing vectors in the background. Operator search can request an explicit
degraded lexical mode while the local model or vector rows warm up; the response
reports `ready`, `unavailable`, or degraded status so the
UI never silently pretends semantic search ran. Search kind filters accept the
public document kinds plus `function` as the runnable implementation view, so
agents can ask for worker functions without knowing the registry document name.
The search request path never re-embeds the whole catalog: registry document
rows carry text hashes and vector rows are refreshed only when a document is new
or changed. Warm searches embed the query once, read the persistent
`sqlite-vec` rows, fuse lexical/vector hits, and return. `search` also accepts a
bounded `queries` array for related lookups against one registry snapshot, and
`inspect` accepts bounded `targets` so the agent can inspect several candidate
capabilities without serial round trips.
Engine Console mutations such as plugin state changes, conformance runs,
binding edits, and policy updates are system-idempotent operator actions. They
do not require a chat session id, but they still go through normal capability
schema validation, approval, audit, trace, and compensation records.

Mutating or medium/high-risk execution requires a fresh `inspect` result and
the returned `inspectionHandle`, `expectedRevision`, and
`expectedSchemaDigest`; `inspect` surfaces these both in structured
`executionRequirements` and in the text result so provider models can copy them
directly into the next `execute` call. The same inspect summary calls out the
required payload fields from the selected contract schema, so agents do not have
to infer the nested `execute.payload` shape from raw JSON alone. Mutating calls also require stable idempotency; model
capability invocations derive a child key from the parent call when one is not passed
explicitly. External/session workers connect with a scoped `workerToken` that
bounds plugin id, namespace claims, authority grant id/revision/hash, resource
selectors, visibility ceiling, trust tier, scope binding, expiry, and signature
status before their functions can enter the capability registry.

`execute` program mode is implemented by the first-party
`program::run_javascript` worker. The parent engine spawns the
`tron-program-worker` OS process with a stripped environment and a temporary
working directory, then communicates over the program JSON-line protocol. The
child process owns QuickJS, freezes the JavaScript host surface to
`tools.search`, `tools.inspect`, `tools.execute`, and exposes no filesystem,
network, process, import, environment, secret, mutable-clock, native-module,
or arbitrary host-object access. Program requests carry explicit limits for
timeout, memory, stack, output/log bytes, child-call count, recursion depth,
allowed contracts/implementations, and risk budget. Child approvals pause the
run; programs cannot self-approve or recursively invoke program mode. Every run
is recorded in the capability registry store with parent/root invocation ids,
binding decision id, code/args hashes, limits, child invocations, selected
implementations, approval state, retained `execution_output` resource refs,
logs, compensation attempts, trace id, and final status. Loose program
`artifacts` are rejected; durable outputs must be created by child resource or
materialization capabilities.

Source-control operations are canonical engine capabilities as well as iOS Source Control sheet actions. Safe worktree operations such as acquire/release/stage/unstage are agent-visible only with explicit idempotency and resource leases; destructive, merge/rebase, push, clone, finalize, discard, delete, and conflict-automation capabilities require approval for autonomous agents. Read-only shell checks such as `git status`, `git diff`, `git show`, and `git log` may run through `process::run` with `executionMode = "read_only"` without a prior inspect turn; `process::run` defaults to the active session worktree/workspace and also treats `cd <dir> && git status/log/diff/show` as read-only when every segment is otherwise safe. Mutating or publishing git commands still require inspection and approval, and write-like process commands must run in sandbox materialization mode with declared outputs.

The same capability worker also registers operator/admin functions for native
clients and the Engine Console. These are normal engine catalog functions, not
provider-facing primitives:

| Function family | Functions |
|-----------------|-----------|
| Status/snapshot/audit | `capability::status`, `capability::registry_snapshot`, `capability::audit_query`, `capability::program_run_list` |
| Bindings | `capability::binding_list`, `capability::binding_set` |
| Plugins/conformance | `capability::plugin_list`, `capability::plugin_inspect`, `capability::plugin_install`, `capability::plugin_update`, `capability::plugin_set_state`, `capability::plugin_promote`, `capability::conformance_run` |
| Implementations/policy | `capability::implementation_set_state`, `capability::policy_get`, `capability::policy_validate`, `capability::policy_update` |

Admin mutations carry high-risk capability metadata, approval requirements,
idempotency, policy evaluation, tracing, and audit records. Read paths return
redacted audit data by default; reveal behavior remains server-authoritative.

Engine-owned primitive workers additionally expose the substrate control and
generated UI surfaces. `control::snapshot` and `control::inspect` are read-only
projections over catalog, invocation, grant, resource, queue, lease, approval,
storage, module, and worker truth; they may include `uiSurfaceRefs`,
`modulePackages`, `moduleConfigs`, `activationRecords`, and
`moduleSourceTrust`, but do not inline large layouts or stored action templates.
Generated UI is persisted as
`Resource(kind = "ui_surface")` and managed by `ui::catalog`,
`ui::create_surface`, `ui::surface_for_target`, `ui::validate_surface`,
`ui::refresh_surface`, `ui::expire_surface`, `ui::update_surface`,
`ui::inspect_surface`, `ui::discard_surface`, and `ui::submit_action`. iOS
submits only the stored
surface/version/action coordinates, user input, and idempotency key; the server
reconstructs and authorizes the canonical target invocation.

The module package lifecycle is also resource-native. `module::register_package`
validates manifest digest, provenance, namespace ownership, declared capability
effects/risks/idempotency/output contracts, config schema, and grant ceiling
before creating a normalized `worker_package`. The normalized package payload
stores engine-owned source trust fields such as `sourceTrustStatus`,
`effectiveTrustTier`, `sourceEvidenceRefs`, `sourceApprovalRefs`,
`conformanceEvidenceRefs`, and bounded `policyDiagnostics`; the manifest's
declared `trustTier` is never permission truth. `module::configure` validates
config and rejects raw secret-like values unless they are `secret_ref`/vault
handles.

Package source trust is explicit. `module::verify_source` verifies package
digest, provenance, materialized file refs/hashes, and redaction, then writes
bounded `evidence` and CAS-updates the package source trust fields. Explicit
signature material fails closed until local trust roots and signature
verification are added; unsigned local packages must stay digest-pinned.
`module::approve_source` records a scoped operator `decision` for a local
digest-pinned package digest/version/scope, trust ceiling, grant ceiling,
file/network bounds, and expiry.
`module::revoke_source_approval` archives that decision and writes evidence.
`module::policy_decide` is a pure read projection over package source evidence,
approval decisions, requested child grant, and conformance refs. Local unsigned
`local_process` packages cannot activate until source verification and an
unexpired scoped approval decision pass policy.

`module::activate`, `module::disable`, `module::upgrade`,
`module::rollback`, and `module::quarantine` produce `activation_record`
versions, derive or revoke engine grants, and never rely on a package table,
`control::act`, or client-side policy. Activation binds existing/built-in
workers directly and launches `local_process` packages only by creating a child
`worker::spawn` invocation with manifest-derived command, expected function ids,
grant bounds, file roots, network policy, visibility, timeout, and idempotency.
The activation record stores spawn lineage, spawn result, integrity diagnostics,
worker lifecycle, health status, registered capability evidence, source-policy
state, and the derived grant hash. Upgrade requires the activation being
replaced, creates a replacement activation first, then revokes the superseded
grant and disconnects superseded volatile workers only after the replacement
succeeds.

Runtime package integrity is also capability-driven. `module::run_conformance`
writes bounded evidence for static manifest rules, grant simulation,
registration bounds, health policy, resource-output contracts, redaction, and
cleanup behavior. `module::check_health` writes bounded `evidence` and updates
the activation record through CAS using either catalog/heartbeat inspection or a
manifest-declared read-only health function invoked under the activation grant.
`module::verify_integrity` recomputes package digests, materialized file hashes,
config validation hashes, grant state, worker registration bounds,
visibility/risk/file/network policy, and redaction invariants without rewriting
damaged bytes. `module::recover_activation` reconstructs incomplete or unsafe
activations from invocation, grant, worker, and resource records, revokes leaked
derived grants, disconnects volatile workers through canonical lifecycle APIs,
and persists failed/quarantined activation evidence. Scheduled checks are
derived from active `activation_record` resources and enqueued through the
existing `module` queue; there is no package, health, policy, conformance, or
recovery table.

---

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

Hidden functions remain in the engine catalog for queue, cron, runtime, and
domain side effects such as agent apply/run-turn, prompt-history capture, and
auto-retain. Normal discovery excludes them and the public transport cannot
invoke them directly.

The core request set is `hello`, `discover`, `inspect`, `watch`, `invoke`,
`promote`, `subscribe`, `poll`, `ack`, `heartbeat`, and `goodbye`. Every request
translates into an internal `EngineTransportRequest`, carrying actor,
authority, trace, scope, payload, expected revision, and explicit idempotency.
Correlation ids are never command ids or idempotency keys. Stream clients should
persist delivered cursors locally and ACK the latest delivered cursor per
subscription, not every event in a burst; ACK responses use normal engine
backpressure so catch-up traffic does not become a socket-fatal overload.

`/engine/workers` is the local-first worker protocol. A worker performs a
versioned hello with `WorkerIdentity`, auth policy, registration mode, visibility
scope, heartbeat interval, and supported capability labels; then it registers
canonical function and trigger definitions with the same schema, authority,
effect/risk, idempotency, approval, lease, compensation, visibility, and
provenance metadata as in-process domain workers. Volatile worker entries are
removed on disconnect or missed heartbeat. Durable local worker entries stay in
the catalog but are marked unhealthy when the worker disconnects, so invocation
fails closed until the worker reconnects and re-registers. Workers publish
events by asking the engine to invoke `stream::publish`; there is no direct
socket event bypass. Worker connect/register/disconnect/heartbeat-timeout
events are stored on `worker.lifecycle` through the stream primitive and are
visible in `observability::trace_get`.

Agents do not need to inspect Tron source to create a local worker.
`worker::protocol_guide` is a canonical read-only worker primitive that returns
the current `/engine/workers` message flow, required environment variables, JSON
field casing, enum values, and a standard-library Python worker template. It
accepts common JavaScript/TypeScript language aliases as a request affordance,
but still returns the current Python template so the agent receives executable
guidance instead of searching source after a schema rejection.
`worker::spawn` injects `TRON_ENGINE_WORKER_ENDPOINT` as a complete
`ws://` or `wss://` URL ending in `/engine/workers`, so generated workers do not
derive socket paths from client URLs. The intended loop is: `search`/`inspect`
`worker::protocol_guide`, write the worker script from that template, `execute`
`worker::spawn` with expected function ids and a stable idempotency key,
search or inspect the new catalog entry, execute the new `namespace::function`,
then disconnect it with `worker::disconnect`.

Engine primitives are first-class worker surfaces. `stream::*`, `state::*`,
`queue::*`, `resource::*`, `grant::*`, and `approval::*` preserve the runtime
semantics for delivery, projection state, queued handoff, typed durable objects,
engine-owned authority, and human approval. `artifact::*`, `goal::*`,
`claim::*`, `evidence::*`, and `decision::*` are wrapper capabilities that
compose the generic resource kernel; they do not create separate stores.
`catalog::*`, `worker::*`, `control::*`, and `observability::*` expose live
catalog snapshots, worker health/lifecycle, substrate projections, trace
summaries, spans, structured log projections, and metrics through the same
canonical invocation path.
`storage::*` owns stats, retention, checkpoints, and portable snapshot export
for the unified engine database. A practical debugging trace includes
invocation records, resource versions/links/events, stream publications,
approvals, resource leases, and compensation records, all tied together by
`traceId` plus `parentInvocationId`. Query
response shaping for these privileged primitive workers lives under
`packages/agent/src/engine/primitives/runtime.rs`; `EngineHost` coordinates
catalog, ledger, stream, resource, lease, approval, and compensation access
without owning primitive response contracts.

Sandbox-created capabilities enter through the high-risk `worker::spawn`
capability. It requires explicit idempotency, `worker.write` authority, a
worker resource lease, compensation notes, and the sandbox autonomy contract
recorded on the capability. Before launch it derives
a child worker grant from the caller's parent grant; the child grant is limited
by expected function ids, namespaces, resource selectors, file roots, network
policy, risk, budget, and delegation=false. It starts a local worker process
with scoped `/engine/workers` environment plus a worker token carrying
`authorityGrantId`, grant revision/hash, and resource selectors, waits for the
expected registration, and returns the worker id, derived grant id, registered
functions, catalog revision, visibility, and process metadata without a
separate approval prompt. Session visibility is the default; workspace/system
promotion is still only `engine::promote`. `sandbox::list_spawned_workers`,
`sandbox::get_spawned_worker`, and `sandbox::stop_spawned_worker` expose the
local process lifecycle; stop kills the process, unregisters volatile catalog
entries through `worker::disconnect`, and publishes `sandbox.lifecycle`.

---

## Event System

The event store uses an immutable, append-only log with **81 typed event variants**. Sessions are tree-structured, supporting fork and rewind. State is always reconstructed from events; no mutable session state is stored outside the log.

The event enum is generated by the `define_events!` macro in `packages/agent/src/domains/session/event_store/types/macros.rs`, invoked from `events/types/generated.rs`. Adding a new event means editing `generated.rs` and adding a payload type — the macro generates the `EventType` enum, wire-format helpers, and `ALL_EVENT_TYPES` automatically. The table below lists active event categories used by the current runtime.

### Event Categories

| Domain | Events |
|--------|--------|
| `session` | `session.start`, `session.end`, `session.fork` |
| `message` | `message.user`, `message.assistant`, `message.system`, `message.deleted`, `message.queued`, `message.dequeued` |
| `capability` | `capability.invocation.generating`, `capability.invocation.started`, `capability.invocation.progress`, `capability.invocation.completed` |
| `stream` | `stream.text_delta`, `stream.thinking_delta`, `stream.turn_start`, `stream.turn_end` |
| `config` | `config.model_switch`, `config.prompt_update`, `config.reasoning_level` |
| `notification` | `notification.interrupted`, `notification.process_result`, `notification.user_job_action` |
| `compact` | `compact.boundary`, `compact.summary`, `compact.summary_staging` |
| `context` | `context.cleared` |
| `skill` | `skill.activated`, `skill.deactivated`, `skills.cleared` |
| `rules` | `rules.loaded`, `rules.indexed`, `rules.activated` |
| `metadata` | `metadata.update`, `metadata.tag` |
| `file` | `file.read`, `file.write`, `file.edit` |
| `worktree` | `worktree.acquired`, `worktree.commit`, `worktree.released`, `worktree.merged`, `worktree.renamed`, `worktree.main_synced`, `worktree.session_finalized`, `worktree.merge_started`, `worktree.conflict_detected`, `worktree.conflict_resolved`, `worktree.merge_continued`, `worktree.merge_aborted`, `worktree.pushed`, `worktree.pending_merge_detected`, `worktree.rebased_on_main`, `worktree.post_rebase_stash_conflict`, `worktree.auto_recovered_commits` |
| `repo` | `repo.lock_acquired`, `repo.lock_released`, `repo.main_advanced` |
| `error` | `error.agent`, `error.capability`, `error.provider` |
| `subagent` | `subagent.spawned`, `subagent.status_update`, `subagent.completed`, `subagent.failed` |
| `process` / `user_job_actions` | `process.results_consumed`, `user_job_actions.consumed` |
| `todo` / `turn` | `todo.write`, `turn.failed` |
| `hook` | `hook.triggered`, `hook.completed`, `hook.background_started`, `hook.background_completed`, `hook.llm_result` |
| `memory` | `memory.retained`, `memory.auto_retain_triggered`, `memory.auto_retain_failed` |
| `device` | `device.token_invalidated` |
| `server.update` | `server.update_available` |

`capability.invocation.generating`, `capability.invocation.started`,
`capability.invocation.progress`, and `capability.invocation.completed` are
immutable capability lifecycle labels. `generating` is emitted as soon as the
provider starts a primitive call so clients can render a running chip before
the worker invocation completes; `completed` uses the canonical
`content`/`isError`/`duration` payload shape for both live and reconstructed
sessions.
Active runtime/UI identity is capability-native: payloads carry `modelPrimitiveName`, `contractId`,
`implementationId`, `functionId`, `pluginId`, `workerId`, `schemaDigest`,
`catalogRevision`, `trustTier`, `riskLevel`, `effectClass`, `traceId`,
`rootInvocationId`, and `bindingDecisionId` when available. iOS renders active
work from those capability fields and does not map retired built-in names to
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
Engine stream (`events.session`, `approvals`, `catalog`, `jobs`, ...)
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

High-risk engine capabilities publish `approval.pending` records to the
`approvals` stream only after the target payload and authority preflight pass.
Thin clients render those records and resolve them by invoking the canonical
`approval::resolve` primitive; the decision, resumed child invocation, ledger
entry, and `approval.resolved` stream event all remain engine-owned. Agents can
not see or invoke `approval::*` functions in their live catalog. Approval-required
capability invocations keep the originating turn open until the approval record
is resolved, denied, failed, or timed out, then return that outcome to the model
as the original `execute` result. Broad first-party capabilities may declare a
conditional approval contract: for example, `process::run` allows read-only
checks such as `date`, `pwd`, `git status`, `git log`, and test/build commands
without a prompt, while privileged, destructive, package-installing, source-control
mutating, or file-redirection shell commands require the sandbox materialization
request shape and may pause for user approval before execution.

The `EngineStreamEventPump` also routes browser CDP frames and `Display` capability frames when iOS clients are subscribed.

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
    "transcription": { "enabled": false },
    "tailscaleIp": null,            // Cached by the Mac wrapper after live Tailscale pairing resolution
    "update": {                     // User-mode update checks. All fields off / safest by default.
      "enabled": false,             // Master switch — false means the scheduler never runs + no GitHub API traffic
      "channel": "stable",          // "stable" ignores pre-release tags; "beta" includes them
      "frequency": "daily",         // "manual" | "startup" | "hourly" | "daily" | "weekly"
      "action": "notify"            // notify-only; installing remains DMG replacement
    }
  },

  "agent": {
    "maxTurns": 250,
    "subagentMaxDepth": 3,
    "subagentModel": "claude-haiku-4-5-20251001"
  },

  "context": {
    "compactor": {
      "maxTokens": 25000,           // Context budget
      "compactionThreshold": 0.85,  // Hard ceiling that triggers compaction
      "targetTokens": 10000,        // Target token count after compaction
      "charsPerToken": 4,           // Token estimation factor
      "bufferTokens": 4000,         // Response buffer
      "triggerTokenThreshold": 0.70,// Soft threshold for proactive compaction (also used as preserved-turn budget)
      "preserveRecentCount": 5      // Always preserve N most recent messages
    },
    "rules": {
      "discoverStandaloneFiles": true  // Pick up AGENTS.md / CLAUDE.md outside .claude/rules/
    }
  },

  "capabilities": {
    "process": { "defaultTimeoutMs": 120000 }
  },

  "skills": {
    "compactionPolicy": "clearAll",   // "clearAll" | "autoRestore" | "askUser"
    "showIndex": "always"             // "always" | "never" | "whenNoActiveSkills"
  },

  "memory": {
    "autoRetainInterval": 10,                   // Turns between auto-retentions. 0 disables.
    "retainModel": "claude-sonnet-4-6"          // Model used by the retain summarizer subagent.
  },

  "observability": {
    "logLevel": "info",                         // "trace" | "debug" | "info" | "warn" | "error"
    "payloadCapture": "normal",                 // "normal" | "debug" | "trace"; full payloads use blob refs
    "verboseRetentionDays": 7,                  // Short retention window for verbose diagnostics
    "maxInlinePayloadBytes": 8192               // Larger payloads store a preview + blob ref
  },

  "storage": {
    "retentionEnabled": true,                   // Startup/manual retention may prune low-signal diagnostics
    "maxDatabaseMb": 512                        // Soft cap surfaced by storage reports
  },

  "retry":  { "maxRetries": 1 },
  "hooks":  { "defaultTimeoutMs": 5000, "discoveryTimeoutMs": 10000, "extensions": [".prompt", ".ts", ".js", ".mjs", ".sh"] },

  "promptLibrary": {
    "historyEnabled": true,         // Auto-save interactive prompts to history
    "historyMaxEntries": 10000,     // 0 = unlimited
    "historyMaxAgeDays": 0,         // 0 = unlimited
    "historyAutoPrune": true        // Opportunistic pruning on record + startup
  },

  "git": {
    "targetBranch": null,                       // null → auto-detect via init.defaultBranch / main / master
    "protectedBranches": ["main", "master", "develop"],
    "sessionBranchPolicy": "keep",              // "keep" | "deleteOnFinalize"
    "mergeStrategy": "merge",                   // "merge" | "rebase" | "squash"
    "autoSetUpstream": true,
    "crashRecoveryAbortTimeoutMs": 1800000,     // 30 min — auto-abort a pending merge recovered at startup
    "opTimeoutNetworkMs": 60000,                // Timeout for fetch / push / ls-remote
    "opTimeoutLocalMs": 30000,                  // Timeout for local git ops
    "subagentConflictResolutionEnabled": true   // Spawn a child subagent to resolve merge conflicts
  },

  "pluginSources": {
    "servers": [],                              // plugin source server configs
    "schemaRefreshTtlMs": 30000                 // Proactive schema re-fetch TTL. 0 disables.
  }
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

The context system manages the LLM's input window. Each turn assembles: system prompt + rules + generated capability primer + skills + conversation history + capability results.

`context::get_snapshot` and `context::get_detailed_snapshot` report the
server-owned context total. Before a provider call this is the chars/4 local
component estimate; after a provider call it uses the exact provider-reported
context count. When provider tokenizer/cache accounting is higher than the sum
of local sections, the response includes `breakdown.providerAdjustment` so the
UI can show the attributed sections plus the provider tokenizer delta without
guessing.

For the full source-grounded map of what can enter model context, how it is constructed, where it is persisted, and which Constitution/config surfaces are still incomplete, see [`packages/agent/docs/context-architecture.md`](packages/agent/docs/context-architecture.md).

### Compaction Pipeline

When context approaches the token budget (default `compactionThreshold: 0.85` of `maxTokens`), compaction triggers:

1. **Summarize**: A subagent condenses older messages into a summary.
2. **Boundary**: A `compact.boundary` event marks the cutoff point in the event log.
3. **Trim**: Messages before the boundary are replaced with the summary on reconstruction.
4. **Preserve recent**: The most recent `preserveRecentCount` messages always survive the cut.

Compaction is observable via the canonical `context::should_compact`, `context::preview_compaction`, and `context::confirm_compaction` capabilities. Programmatic compaction is exposed via `context::compact`.

### Context Assembly Order

```
System prompt    (stable, per-model)
  + Rules        (path-scoped from .claude/rules/, project-relative AGENTS.md / CLAUDE.md)
  + Capabilities (generated from the live registry; core first-party by default)
  + Skills       (@skill references from prompt + always-on skills)
  + History      (messages since the most recent compaction boundary)
  + Pending      (current user prompt + capability results)
```

`capabilities.primer` is rendered after active rules and before skill context.
The default `coreFirstParty` policy includes compact recipe-style schemas and
examples for trusted first-party core capabilities, using `contractId` execute
templates. `allVisibleCompact` is available as an opt-in profile policy for
every visible worker/plugin/plugin source/OpenAPI/session capability under a
strict budget.

### Skills

Reusable context packages stored as `SKILL.md` files with optional YAML frontmatter.

**Locations** — scanned across every service folder in `SKILL_SERVICE_DIRS` (currently `tron`, `claude`):
- `~/.tron/skills/`, `~/.claude/skills/` — Global (all projects). First-party skills under `packages/agent/skills/` are bundled into the Mac app at `Contents/Resources/Skills/` and synced into `~/.tron/skills/` by the Mac installer/menu-bar start path, `tron dev`, and `tron install`. The Mac wrapper serializes its managed-skill sync and skips already-current directories so idle menu-bar launches do not rewrite this tree. Managed skills carry a `.managed` sentinel file; user-owned same-name directories are preserved. `~/.claude/skills/` is read-only to Tron (Claude Code owns that tree) but its contents are detected automatically.
- `.tron/skills/` or `.claude/skills/` under the working directory (any depth) — Project-local (higher precedence than globals). `.tron/skills/` wins over `.claude/skills/` on same-name collision within a single scope.

**Usage:** Reference with `@skill-name` in prompts. The injector extracts references, resolves them from the registry, and prepends the skill content as `<skills>` XML context. Session-scoped activation is also exposed via the canonical `skills::activate` / `skills::deactivate` capabilities.

### Hooks

Async lifecycle hooks execute before/after capability invocations and around prompts:

- **Discovery:** `.agent/hooks/` (project), `~/.config/tron/hooks/` (global)
- **Extensions:** configurable via `hooks.extensions` (default `.prompt`, `.ts`, `.js`, `.mjs`, `.sh`)
- **Background hooks:** drained before accepting a new prompt and before session reconstruction (see Core Invariant #7)
- **AddContext budget:** fixed at 16384 characters per event inside `HookEngine`; over-budget context is dropped all-or-nothing and is not a user-facing setting

---

## Database Schema

All active server storage lives in `~/.tron/internal/database/tron.sqlite`. WAL mode stays enabled at runtime with a 5 s busy timeout, foreign keys, bounded auto-checkpointing, and a shutdown checkpoint; `storage::export_snapshot` creates a portable single-file copy when needed. The active DB carries a `storage_generation = "modular-engine-v2"` marker in `storage_metadata`; if startup sees a `tron.sqlite` without the current marker, it archives `tron.sqlite`, `tron.sqlite-wal`, and `tron.sqlite-shm` into `internal/database/archive/modular-engine-v2-*` and starts fresh. Old product/session data is archived, not migrated or read by the new runtime. Retired pre-unified database artifacts are archived the same way and are never read as active storage.

The unified database has one migration surface for session/log/blob tables and engine-owned stores for primitive state. Fresh databases start from consolidated `packages/agent/src/domains/session/event_store/sqlite/migrations/v001_schema.sql`; additive follow-up migrations such as `v002_constitution_audit.sql`, `v004_session_profile.sql`, and `v005_drop_profile_migrations.sql` are registered in `migrations/mod.rs` (the source of truth for schema versioning). Every constraint is declared inline on `CREATE TABLE`: `UNIQUE(session_id, sequence)` on events, `CHECK (payload IS NOT NULL OR content_blob_id IS NOT NULL)` on events, `CHECK (use_worktree IS NULL OR use_worktree IN (0, 1))` on sessions, and a `COALESCE`-nullable unique index on `device_tokens (device_token, platform, workspace_id, bundle_id)` so the same APNs push token can register across multiple workspaces or bundles without clobbering. The runner applies pending versions in order, verifies each applied migration with `PRAGMA foreign_key_check`, and refuses to commit if any dangling reference would be left behind.

Engine ledger rows, grants, streams, state, queues, typed resources, approvals, resource leases, compensation records, worker lifecycle records, bounded server/iOS logs, and compressed content-addressed blobs share that same file. Large correctness and audit payloads flow through `StoredPayloadRef`: primary rows keep compact inline JSON only below the configured threshold, otherwise they store an internal payload-ref envelope while the full bytes live once in `blobs` and are owned by `storage_payload_refs`. Retention operates from `storage_payload_refs`, so blobs are deleted only when no live owner remains. Startup enforces `storage.max_database_mb` as a soft budget: when the active DB plus WAL/SHM sidecars exceed it, the server records a warning, runs only safe verbose-log/blob retention, and checkpoints the WAL; audit-critical rows and owner refs are not automatically deleted. `storage::stats`, `storage::retention_run`, `storage::checkpoint`, and `storage::export_snapshot` are canonical system capabilities; the observability worker reads the same local truth for `observability::trace_get`, `observability::trace_list`, `observability::span_list`, `observability::log_query`, and `observability::metrics_snapshot`. Trace and log queries return previews/refs by default; callers must explicitly request full payload expansion through blob refs.

### Tables

| Table | Purpose |
|-------|---------|
| `schema_version` | Migration version tracking |
| `workspaces` | Project/directory contexts (id, path, name, timestamps) |
| `sessions` | Session metadata: head pointer, title, model, execution `profile`, token counts, tags, fork lineage, spawn metadata, optional `use_worktree` per-session worktree override |
| `events` | Immutable append-only event log. Denormalized columns (`role`, `model_primitive_name`, `invocation_id`, `turn`, token counts, `model`, `latency_ms`, `stop_reason`, `provider_type`, `cost`, ...) extracted from payloads for indexed queries |
| `blobs` | Content-addressable deduplicated storage (hash, compressed content, MIME type, size/compression metadata) |
| `branches` | Named positions in the event tree (root + head pointer per branch) |
| `logs` | Application logs (level, component, message, error fields, trace IDs, origin) |
| `engine_invocations` | Engine invocation ledger: function, worker, trace, parent, idempotency, status, result/error summaries |
| `engine_grants`, `engine_grant_events` | Engine-owned authority model: parent/child grants, subject binding, allowed capabilities/namespaces/resource selectors/file roots/network/risk/budget/expiry/delegation, plus lifecycle events |
| `engine_stream_events` | Engine stream publication history with cursor, topic, visibility, trace, and compact payload |
| `engine_catalog_changes` | Live catalog audit trail for worker/function/trigger registration, health, visibility, and lifecycle changes |
| `engine_idempotency_entries` | Durable idempotency reservations and replay records |
| `engine_state_entries`, `engine_queue_items`, `engine_approvals`, `engine_resource_leases`, `engine_compensation_records` | Primitive worker state owned by the engine runtime |
| `engine_resource_type_definitions`, `engine_resources`, `engine_resource_versions`, `engine_resource_links`, `engine_resource_events` | Generic typed resource substrate for artifacts, goals, claims, evidence, decisions, generated UI surfaces, worker packages, module configs, activation records, secret refs, materialized files, patch proposals, execution outputs, and agent results; resource versions carry `available`, `quarantined`, `damaged`, or `discarded` state |
| `capability_plugins`, `capability_implementations`, `capability_bindings` | Durable capability registry layer over the live catalog: plugin manifests, concrete implementations, conformance state, signature status, and policy-selected bindings |
| `capability_index_documents`, `capability_vector_metadata` | Search documents and persistent local vector-index metadata for hybrid capability search |
| `capability_inspection_handles`, `capability_binding_decisions`, `capability_audit_events`, `capability_pause_records`, `capability_run_records`, `capability_program_runs` | Fresh inspect handles plus auditable records for binding resolution, pauses, async runs, program runs, and search/inspect/execute lifecycle decisions |
| `storage_metadata`, `storage_payload_refs` | Storage generation marker plus owner refs for blob-backed payloads (owner kind/id, field, preview, hash, size, retention, trace/session/workspace) |
| `storage_checkpoints`, `storage_exports`, `storage_retention_runs` | Storage operations audit records for checkpoint/export/retention capabilities |
| `device_tokens` | iOS push notification tokens — identity is `(device_token, platform, workspace_id, bundle_id)` (COALESCE-nullable unique index collapses NULL workspace/bundle to a single canonical row; `bundle_id` lets the relay send Beta-scheme tokens to the correct APNs topic) |
| `notification_read_state` | Per-event read receipts for client notifications |
| `cron_jobs` | Cron job definitions: schedule, payload, delivery, overlap/misfire policies, runtime state (next/last run, consecutive failures) |
| `cron_runs` | Per-run history for cron jobs (status, started/completed timestamps, output, exit code) |
| `prompt_history` | Deduplicated interactive-prompt history keyed by normalized text hash (use_count, first/last_used_at, char_count) |
| `prompt_snippets` | User-authored reusable prompt snippets (`name`, `text`, timestamps) |
| `constitution_home_audit` | Audited creates, updates, moves, deletes, seeds, repairs, and external edits for files under `~/.tron/` |
| `constitution_resolution_audit` | Settings, instruction, context, provider-payload, vault, automation, and outcome resolution records with effective hashes and blob refs |
| `constitution_context_blocks` | Typed model-context blocks for replay: source home/path/blob, hash, sensitivity, cache class, inclusion reason, precedence, and provider surface |

The events table enforces correctness with `UNIQUE(session_id, sequence)` and a single ordering index on `(session_id, sequence)` — most other access patterns are intentionally allowed to scan/filter at our volumes. Prompt history and cron state live in their dedicated tables; session/task views are reconstructed from the canonical event log.

---

## iOS App

**Minimum iOS:** 26.0 | **Swift:** 6.0 | **Build system:** XcodeGen

### Architecture

The app uses MVVM with coordinators, event plugins, and SwiftUI's `@Observable` macro. The authoritative architecture document is `packages/ios-app/docs/architecture.md`.

```
packages/ios-app/Sources/
+-- App/                  App entry point, delegates, scene phases
+-- Core/                 DI, EventDispatchCoordinator, plugins, payloads
+-- Database/             SQLite event database, queries
+-- Models/               Data models, engine protocol codables, event types
+-- Protocols/            Coordinator and view model protocols
+-- Services/             Network (engine client, WebSocket, deep links), paired servers, audio,
+                         push notifications, local diagnostics,
+                         feedback composer, Engine Console cache, Keychain tokens
+-- ViewModels/           Chat view models, handlers, managers, @Observable state,
+                         OnboardingState, EngineConsoleState
+-- Views/                SwiftUI views (chat, Engine Console, capability views, settings, Onboarding/, ...)
+-- Theme/                Colors, typography, design tokens
+-- Utilities/            Shared helpers
+-- Extensions/           Type extensions
+-- Resources/            Localized strings, fixtures
+-- Assets.xcassets/      Icons and images
+-- IconLayers/           Source layers for the app icon
+-- Info.plist            App metadata
+-- PrivacyInfo.xcprivacy Apple privacy manifest
```

### Key Patterns

- **MVVM + Extensions**: Large view models split across extension files (`ChatViewModel+Connection.swift`, etc.)
- **Coordinator pattern**: Stateless logic in coordinators, state in view models via context protocols
- **Event plugins**: Live WebSocket events parsed by plugins, dispatched by `EventDispatchCoordinator`
- **History transformer**: Stored events reconstructed into `ChatMessage` arrays by `UnifiedEventTransformer`
- **Capability-native chat UI**: active work is rendered as `capabilityInvocation` / `capabilityResult` content from capability identity and schema/result metadata. Retired capability descriptors, old built-in names, and plugin source-specific capability sheets are not active UI routes.
- **Dependency injection**: All services via SwiftUI `@Environment(\.dependencies)`
- **Engine Console mode**: A top-level `NavigationMode.engine` surface uses `CapabilityClient` and `EngineConsoleState` to inspect the live capability registry, vector index state, program runs, substrate workers/resources/grants/module packages, and generated `ui_surface` refs through a simplified Overview/Capabilities/Program Runs/Substrate flow. Advanced sections expose plugin manifests, workers, bindings, policies, redacted audit rows, trace summaries, and primer inputs behind an explicit toggle. It invokes capability admin functions rather than hardcoded capability descriptors. `EngineConsoleCache` stores read-only summaries and redacted generated-UI refs for disconnected browsing; surface authoring, refresh, validation, module actions, and generated-UI actions stay server-authoritative and are disabled while offline.
- **Onboarding sheet**: `TronMobileApp.readyContent()` always mounts `ContentView`; when `@AppStorage("onboardingComplete")` is false it presents `OnboardingFlowView`. Settings can reopen the same flow at the Connect page for another server or token refresh, with a dismiss button. New-server onboarding requires a scanned/pasted/manual token before Connect is enabled; an already paired server row can reuse that server's Keychain token unless the user edits its host or port. Setup pages require a pairing probe plus engine invocations for `settings::get` and setup hydration.
- **Local paired-server model**: `PairedServerStore` keeps the paired Mac list and active server id in iOS storage, while `PairedServerTokenStore` stores each server's bearer token in Keychain. The server never stores the iOS pair list in `profiles/user/profile.toml`.
- **Live engine stream state**: `EngineClient` treats subscription ids as WebSocket-local. It clears active subscriptions when the transport disconnects, recreates the current session subscription at the live topic tail after reconnect/reconstruction, and coalesces stream ACKs to the latest cursor so turn bursts stay inside the engine stream protocol.
- **Setup hydration**: after QR/manual pairing, onboarding reads the active Mac's `settings::get` response and best-effort `auth::get` masked credential state before unlocking setup pages. Pairing a previously forgotten Mac therefore shows the server's existing workspace/model choices and credential hints without storing server settings or secrets on iOS; OAuth/API-key saves refresh those cards immediately from the returned `AuthState`.
- **Forgetting a server**: Settings → Servers → menu → "Forget" removes the server and token locally. If another paired server remains, the app switches locally; if none remain, Settings shows the onboarding CTA.
- **Local diagnostics + feedback**: Tron ships no outbound analytics SDKs and `PrivacyInfo.xcprivacy` declares no collected data. iOS registers `MetricKitDiagnosticsStore` for Apple MetricKit payloads, stores them locally with bounded retention, and includes them only when the user taps Settings -> Send Feedback. `DiagnosticsBundleBuilder` creates one redacted JSON attachment with app/server state, recent local/server logs, session/event summaries, and MetricKit payloads; Settings opens the native Mail composer with the tracked `TRON_FEEDBACK_EMAIL` recipient, subject, body, and JSON attachment, including a body time range when real log timestamps are available. If Mail is unavailable or recipient config is unresolved, Settings shows an alert instead of a share-sheet alternate path. App Store/TestFlight crash diagnostics remain available through Apple's Xcode Organizer path, and release builds keep `dwarf-with-dsym`.

### Data Flow

```
Live:    WebSocket -> EngineClient -> EventRegistry -> Plugin -> EventDispatchCoordinator -> ChatViewModel
Stored:  EventDatabase -> UnifiedEventTransformer -> [ChatMessage] -> ChatViewModel -> ChatView
Console: /engine invoke(capability::*) -> CapabilityClient -> EngineConsoleState -> EngineConsoleView
```

### Build Configurations

| Config | Use |
|--------|-----|
| Beta | Debug build, side-by-side bundle ID |
| Prod | Release build, production bundle ID |

### Documentation

Detailed iOS documentation lives in `packages/ios-app/docs/`:

- `architecture.md` — App architecture, patterns, file placement
- `development.md` — Xcode setup, builds, testing
- `events.md` — Event plugin system
- `capability-ui.md` — Engine Console, capability DTOs, schema forms, offline cache, and admin client boundaries
- `apns.md` — Push notification setup
- `onboarding.md` — First-run onboarding sheet, QR/deep-link handling, local paired servers, and bearer persistence

---

## Mac App

**Minimum macOS:** 15 Sequoia | **Swift:** 6.0 | **Bundle ID:** `com.tron.mac` | **Build system:** XcodeGen

`Tron.app` is a SwiftUI wrapper around the headless Rust agent. It ships as a notarized DMG via `.github/workflows/release-mac.yml`; production installs run only from `/Applications/Tron.app`. The app bundles a signed helper at `Contents/Library/LoginItems/Tron Server.app`, a bundled LaunchAgent plist, managed skills under `Contents/Resources/Skills/`, Constitution defaults under `Contents/Resources/Constitution/`, and the small transcription sidecar source files under `Contents/Resources/Transcription/`. The helper app contains both `tron` and its sibling `tron-program-worker`; the agent binary embeds the first-party capability-search ONNX/tokenizer bundle, and the program worker is required for `execute(mode: "program")` in dev and packaged flows. The wizard registers the helper through `SMAppService`, syncs bundled managed skills into `~/.tron/skills/`, confirms permissions, optionally enables local transcription, presents the Tron iOS Beta TestFlight QR, and reveals pairing info for iOS. After the wizard, the app transforms into a menu-bar icon (`LSUIElement = YES`) that checks server health by invoking `system::ping` through `/engine` `invoke`.

```
packages/mac-app/Sources/
+-- TronMacApp.swift           App entry: branches on ~/.tron/internal/run/.onboarded sentinel
+-- EnvironmentSetup.swift     Dev vs release bundle-ID wiring, log paths, shared state root
+-- Wizard/                    First-run flow
|   +-- WizardState.swift      @Observable state machine + `WizardStep` enum
|   +-- WizardView.swift       NavigationStack shell
|   +-- Steps/                 Welcome, Tailscale, Install, Permissions, Transcription, iOS Beta, Pairing, Done
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
    +-- Transcription/worker.py + requirements.txt
    +-- Library/
        +-- LoginItems/Tron Server.app/Contents/MacOS/tron
        +-- LaunchAgents/com.tron.server.plist
        +-- LaunchAgents/com.tron.server.dev.plist
```

### Wizard Steps

1. **Welcome** — introduces Tron.
2. **Tailscale prerequisite** — detects `/Applications/Tailscale.app` or the Tailscale CLI, then reads `tailscale status --peers=false --json` for a running backend and 100.x IPv4.
3. **Install** — detects whether the bundled Login Item is registered, but treats that as registered-not-ready until the user presses Install/Start and `system::ping` answers through `/engine` `invoke`. It validates that release builds are running from `/Applications/Tron.app`, validates the helper/plist/signature, registers or refreshes `com.tron.server` through `SMAppService`, handles `requiresApproval` by opening Login Items settings, and polls `system::ping` after the initial `hello.ok` frame.
4. **Permissions** — Full Disk Access, Screen Recording, and Accessibility. Deep-links to System Settings, labels the exact app entry to enable for each permission, polls wrapper-owned TCC state, starts a short-lived fast-probe watcher after wizard-opened Settings panes, and keeps Re-check as a non-restarting probe.
5. **Transcription** — opt-in step for local voice transcription. The step copies `worker.py` and `requirements.txt` from the signed app bundle into `~/.tron/internal/transcription/` so the setting can be enabled later. Enabling writes `server.transcription.enabled = true`, restarts the helper once, and lets the Parakeet model download into `~/.tron/internal/transcription/models/hf/` when the sidecar starts. Skipping writes `enabled = false` and does not restart the server.
6. **iOS Beta** — shows the public Tron TestFlight invite (`https://testflight.apple.com/join/xbuX1Grx`) as a QR code for the iPhone camera, with copy/open alternatives. TestFlight then owns beta availability and update selection.
7. **Pairing** — reads the agent-issued bearer token, confirms the local server heartbeat, resolves this Mac's Tailscale IP live (then caches it in `profiles/user/profile.toml`), detects the Mac's user-facing computer name, and displays host + port + token + server name with copy buttons and a QR code encoding `tron://pair?host=<ip>&port=<port>&token=<token>&label=<server-name>`.
8. **Done** — touches `.onboarded` sentinel, transforms to menu-bar mode.

### Menu-bar Actions

| Item | Action |
|------|--------|
| Custom status header | Shows `Tron`, the Tailscale endpoint, color-coded state, PID, normalized live uptime, and a `Dev Server active` marker when `tron dev` owns port 9847 |
| Show pairing info | Opens a pairing-only window that shows one emerald resolving spinner directly on the window background until the QR + manual copy buttons for host, port, token, and server name crossfade in; copy actions quickly show a checkmark for two seconds on success |
| Restart / Pause / Resume server | `SMAppService.register` repair/load before restart or resume, then `launchctl kickstart` when the label was already loaded; shows busy state and posts success/failure notifications |
| Update finalization | On the first menu-bar launch for a new app build, syncs managed skills, refreshes stale SMAppService metadata, and restarts the bundled server once; `tron dev` takeover defers this until the production server is active again |
| Stop dev server | Appears with the server controls whenever `Tron-Dev.app` owns port 9847; stops the dev process and resumes the installed Login Item. Pause, restart, and uninstall are disabled while dev takeover is active. |
| Show logs | Opens the native logs window backed by the read-only `logs::recent` capability |
| Send feedback | Opens a prefilled GitHub issue with app/server context and redacted recent logs |
| Check for updates | Opens the latest GitHub Release |
| Uninstall Tron | Confirm dialog + `SMAppService.unregister`; clears `internal/run/` runtime state; optional checkboxes remove `profiles/user/profile.toml` settings overrides and/or `profiles/auth.json`. The database and workspace are always preserved. |
| Quit Tron | Quits wrapper; server keeps running via LaunchAgent |

### Variants & Workflows

The wrapper coexists with local Release testing, Xcode Debug UI dogfood, an isolated Xcode install sandbox, and the `tron dev` agent-only workflow. Production workflows share `port 9847` and the `~/.tron/internal/` data tree; the isolated install scheme deliberately uses `port 9848`, `~/.tron-dev`, and `com.tron.server.dev`.

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
- LaunchAgent ownership — installed Release is authoritative for `com.tron.server` and repairs stale Debug/DerivedData registrations before restart; default Xcode Debug is companion-only. The `TronMac Isolated Install` scheme owns `com.tron.server.dev` on port `9848` with `TRON_HOME_NAME=.tron-dev`.
- Port `9847` — `tron dev` calls `launchctl bootout com.tron.server` before binding, so the installed helper is paused while dev-mode runs.
- Direct server guard — if no LaunchAgent owns the service but port `9847` is already bound or `internal/database/tron.sqlite.lock` is held, the app reports another Tron server instead of registering a second helper or choosing a different port.

A contributor can have the DMG installed AND run the default Xcode Debug wrapper for menu/wizard UI work; both menu icons can coexist and both observe the production server. Running `tron dev` is still the explicit server-takeover path for Rust-agent iteration: the wrapper's menu bar keeps pinging port 9847, reports the `Tron-Dev.app` PID/uptime, and shows `Dev Server active` while dev owns the port. Quitting `tron dev` restarts the installed helper by invoking `/Applications/Tron.app/Contents/MacOS/Tron --tron-start-server-and-quit`, which re-enters the same `SMAppService` registration path used by the app. Pre-onboarding production cleanup uses the installed app's paired internal command `--tron-uninstall-and-quit` so stale Login Item registrations are removed by `SMAppService.unregister` instead of only being booted out of launchd; Debug companion command mode refuses to uninstall production. See [`packages/mac-app/docs/architecture.md` → Workflows & Variants](packages/mac-app/docs/architecture.md#workflows--variants) for the full breakdown including the on-disk artifacts each workflow shares.

### Documentation

- `packages/mac-app/docs/architecture.md` — wizard + menu bar + helper-binary lifecycle
- `packages/mac-app/docs/development.md` — workflow quick reference for Xcode Debug, local Release install testing, `tron dev`, and DMG release, plus XcodeGen/signing setup

---

## Permissions

The Mac wizard surfaces three system permissions after the server is installed. Each permission has an "Open System Settings" deep link when revoked, and each row names the exact app entry macOS expects in that pane.

| Permission | Why | Required | Probe |
|------------|-----|----------|-------|
| Full Disk Access | Agent reads/writes user-selected files and app data outside the sandbox | Yes | Wrapper process opens FDA-gated user data |
| Screen Recording | ComputerUse screenshots and visual inspection | Yes | Wrapper `CGPreflightScreenCaptureAccess()` plus a fresh wrapper probe process |
| Accessibility | ComputerUse mouse/keyboard control | Yes | `AXIsProcessTrusted()` in the wrapper |

The install step validates the signed `Tron Server.app`, registers the bundled LaunchAgent through `SMAppService`, and waits for the first heartbeat. Ordinary agent startup does not probe TCC or open System Settings, so macOS permission prompts cannot appear while the user is still on the install step. The LaunchAgent's `AssociatedBundleIdentifiers` lists the wrapper bundle IDs, so macOS presents the helper's privacy grants under the responsible wrapper app: `Tron.app` in Release and `TronMac.app` in Debug. All three wizard rows therefore name the wrapper app, not `Tron Server.app`. The settings buttons only open System Settings; they never call prompt APIs that would create a second modal over the already-open pane. Screen Recording additionally shows a small draggable wrapper-app icon for the macOS case where the row is not inserted automatically; the row copy tells the user to drag that icon into the list. Re-check/app activation use native non-prompting probes. Screen Recording probes the current wrapper first; if macOS still reports the current process as stale after a Settings change, the wizard starts the same wrapper executable once as a quiet child probe and reads that fresh process result from `~/.tron/internal/run/`. Once all three rows are green, Continue restarts the helper one time so launch-time-applied grants are visible to the server before pairing.

---

## Deployment

### Deploy Pipeline

```bash
tron deploy          # Full pipeline with confirmations
tron deploy --force  # Skip uncommitted-changes / test-failure prompts
tron deploy --ci     # Non-interactive: any failure aborts
```

`tron deploy` is a contributor-only script path and is not the production Mac distribution mechanism. Production releases are the notarized DMG pipeline below; end users replace `/Applications/Tron.app` from that DMG.

The deploy process (`scripts/tron::cmd_deploy`) is retained for local contributor workflows:

1. Aborts if a dev server is bound to the prod port.
2. Warns on uncommitted changes (errors out under `--ci`).
3. Builds the release binary (`cargo build --release`).
4. Runs `cargo test`. Failures prompt for continuation unless `--ci`.
5. Under `--ci`, also runs the benchmark gate.
6. Uses contributor-only artifacts directly under `~/.tron/internal/run/`.
7. Syncs managed skills and transcription support.
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
|   |   +-- prompts/               Main, chat, local, workflow, and process prompts
|   |   |   +-- processes/         Summarizer, hook, automation, and subagent process prompts
|   |   +-- context/               Context block assembly policy
|   |   +-- providers/             Provider-specific presentation defaults
|   |   +-- capabilities/          Capability presentation policy
|   +-- normal/                    Managed standard workspace/session profile
|   |   +-- profile.toml           Inherits default; profileClass = "normal"
|   +-- chat/                      Managed quick-chat profile
|   |   +-- profile.toml           Inherits default; maps main entrypoint to chat prompt
|   +-- local/                     Managed local-provider profile
|   |   +-- profile.toml           Inherits default; maps main entrypoint to local prompt/context/runtime policies
|   +-- user/                      Sparse user profile/settings/prompt overrides
|       +-- profile.toml           Sparse `[settings]` overrides
+-- skills/                       Global skills (SKILL.md files); managed entries have a .managed sentinel
+-- memory/                       Durable user/agent continuity
|   +-- MEMORY.md                  Canonical single-file root (name, preferences, active projects)
|   +-- rules/                     Detail files listed in context, read on demand
|   +-- sessions/                  Auto-generated retain summaries
+-- workspace/                    Active work and generated artifacts
|   +-- inbox/
|   |   +-- voice-notes/           Transcribed voice notes
|   +-- projects/                  Project-local active work
|   +-- automations/               Cron job definitions and working directories
|   +-- plans/                     Plan files and TODOs
|   +-- reports/                   Analysis and investigation reports
|   +-- renders/                   Rendered pages displayed in chat
|   +-- screenshots/               Saved screenshots from the computer-use capability
|   +-- scratch/                   Downloads, temp files, experiments
|   +-- labs/                      Manifested experimental spaces
|   +-- archive/                   Retired workspace material
|   +-- knowledge/                 Curated wiki/research experiment
|   +-- vault/                     Skill-owned local fast secret storage
+-- internal/                     Tron-owned runtime machinery
    +-- database/                  Unified SQLite engine storage and archives
    |   +-- tron.sqlite            Events, sessions, logs, blobs, engine ledger, streams, state, queues, typed resources, approvals, leases, compensation, workers, capability registry/index/audit
    |   +-- tron.sqlite.lock       OS-level flock sidecar; one Tron process owns it while running
    |   +-- archive/               One-way archive of retired or incompatible storage generations
    |   +-- journals/              Streaming journals for crash recovery of partial LLM output
    +-- run/                       Mutable runtime state and local contributor artifacts
    |   +-- auth.lock              Auth-file refresh lock
    |   +-- auto-deploy.lock       Contributor deploy concurrency lock
    |   +-- auto-deploy.pause      Contributor deploy pause sentinel
    |   +-- auto-update.pause      User-mode updater pause sentinel
    |   +-- deploy.lock            Manual deploy concurrency lock
    |   +-- .mac-wrapper.*.lock    Per-wrapper menu app lock
    |   +-- .onboarded             First-run sentinel; presence drives `system::get_info.paired`
    |   +-- mac-app-version.json   Last app build whose menu-bar launch finalized the server
    |   +-- updater-state.json     Update-check scheduler state
    |   +-- Tron-Dev.app           Optional `tron dev` headless agent bundle
    +-- transcription/             Speech-to-text sidecar
        +-- worker.py              parakeet-mlx Python worker
        +-- requirements.txt       Pip deps for the venv
        +-- venv/                  Auto-created when enabled and the sidecar starts
        +-- models/hf/             HuggingFace model cache (HF_HOME)
```

Notes:
- The five top-level homes are the primitives: behavior in `profiles`, capabilities in `skills`, continuity in `memory`, active substrate in `workspace`, and runtime machinery in `internal`.
- Credentials for external CLIs (Google Workspace, etc.) live in `~/.tron/workspace/vault/`. Tron-owned provider auth and the bearer token live in `~/.tron/profiles/auth.json`.
- Pause/lock sentinels live under `~/.tron/internal/run/` with the rest of the runtime machinery. They are managed by the respective CLI subcommands, not user-edited at the Tron Home root.

### Service (SMAppService)

The production Mac app registers `com.tron.server` with `SMAppService.agent(plistName: "com.tron.server.plist")`. The notarized app must live at `/Applications/Tron.app`; the bundled LaunchAgent lives inside the app at `Contents/Library/LaunchAgents/com.tron.server.plist`, and its `BundleProgram` points at `Contents/Library/LoginItems/Tron Server.app/Contents/MacOS/tron` with `ProgramArguments` of `tron --port 9847 --quiet`. `AssociatedBundleIdentifiers` lists the wrapper bundle IDs (`com.tron.mac`, `com.tron.mac.dev`) so Login Items/TCC attribution follows the responsible wrapper app. No production code writes `~/Library/LaunchAgents` or copies an app bundle into `~/.tron/internal/`. An enabled Login Item registration without a loaded launchd job is not treated as installed/running; the current app replaces that registration through SMAppService and still waits for the server heartbeat. If `launchctl print` reveals a stale event trigger pointing at a missing/mismatched helper executable, a stale parent bundle build number for the same installed app, or a Debug/DerivedData parent owns the production label, the installed app boots it out, unregisters the stale registration, and re-registers `/Applications/Tron.app` before restarting.

Local Release builds use the same path rule: copy the built `Tron.app` to `/Applications/Tron.app` before testing install/registration. If a DMG build is already installed, the local Release build replaces that same slot; reopen `/Applications/Tron.app` and restart/resume the helper so the wrapper repairs SMAppService before launchd executes the bundled server. Default Debug Xcode builds use bundle ID `com.tron.mac.dev`, may run from DerivedData, and are companion-only: they can show the menu bar and observe the production server, but server pause/restart/uninstall/install actions are disabled. Use the `TronMac Isolated Install` scheme when testing the first-run/reinstall wizard from Xcode; it registers `com.tron.server.dev`, runs on port `9848`, and stores data under `~/.tron-dev`. For agent-only iteration, `tron dev` stops the production LaunchAgent, binds port `9847`, and later restores the installed helper through the wrapper's internal `--tron-start-server-and-quit` command so ServiceManagement remains the only production registration path.

For local Mac wrapper builds and `tron dev` takeovers that need real push delivery, copy `packages/mac-app/.env.local.example` to `packages/mac-app/.env.local` and set `TRON_RELAY_URL`, `TRON_RELAY_SECRET`, and optionally `TRON_RELAY_ENVIRONMENT`. `packages/mac-app/scripts/bundle-agent.sh` and `scripts/tron dev` read only those relay keys from the ignored file immediately before Cargo compiles the helper, so Xcode Debug, local Release, and agent-only dev tests do not require repeated shell exports. Production DMG builds still get relay values only from GitHub Actions secrets.

### DMG Release Pipeline

End-users install `Tron.app` via a notarized DMG published to GitHub Releases. Release identity is centralized in `VERSION.env`: the first beta is canonical `0.1.0-beta.1`, Apple bundles receive numeric `MARKETING_VERSION = 0.1.0` / `CURRENT_PROJECT_VERSION = 1`, and human-facing UI renders `v0.1 (Beta 1)`. The pipeline lives at `.github/workflows/release-mac.yml` and triggers on a matching `server-v*` tag push:

1. Checkout + Rust toolchain/cache (`actions-rust-lang/setup-rust-toolchain`).
2. `scripts/tron version check` verifies `VERSION.env`, Cargo, Cargo.lock, Mac/iOS `project.yml`, custom bundle canonical version keys, and release docs agree before any artifact is built. A tag push must equal `server-v$(TRON_VERSION)`.
3. `cargo build --release --bin tron --bin tron-program-worker --locked` in `packages/agent/`, with `TRON_RELAY_URL`, `TRON_RELAY_SECRET`, and `TRON_RELAY_ENVIRONMENT=production` supplied from GitHub secrets so push delivery is enabled for release users without local config.
4. Install XcodeGen + `create-dmg`.
5. `packages/mac-app/scripts/bundle-agent.sh --skip-build` stages `packages/agent/target/release/tron` and its sibling `tron-program-worker` into `Contents/Library/LoginItems/Tron Server.app/Contents/MacOS/` and writes the bundled LaunchAgent plist.
6. `xcodegen generate` inside `packages/mac-app/`.
7. Create an isolated release keychain from the signing/notarization secrets, or fall back to dry-run ad-hoc signing when secrets are absent.
8. `xcodebuild archive` with `-scheme TronMac -configuration Release`.
9. Verify the bundled helper app, both helper executables, LaunchAgent plist, managed skills, and transcription resources are present in the archive.
10. Sign the helper app first, then sign `Tron.app` with hardened runtime + `TronMac.entitlements`; verify inside-out signatures before DMG packaging.
11. `xcrun notarytool submit` the signed `Tron.app` with `$NOTARIZE_PROFILE` (`tron-notarize`); staple the app on success.
12. Build the DMG with `create-dmg`, sign the DMG, submit that signed DMG to `notarytool`, then staple the DMG. The app and DMG require separate notary tickets.
13. Keep dSYMs in the Xcode archive/release artifacts for Apple crash diagnostics.
14. `scripts/tron-release-notes` writes a bounded draft changelog body from first-parent git history since the previous release tag, including the DMG filename, SHA256, and a full compare link. The body starts below GitHub's release title so the rendered page does not repeat the release name. The beta1-to-beta2 pump recognizes the historical Mac-scoped beta1 tag so the first `server-v*` release does not include the entire repo history.
15. `gh release create server-v0.1.0-beta.1 ./tron-v0.1.0-beta1.dmg` creates a draft GitHub pre-release titled `Tron Server v0.1 (Beta 1)` with the generated changelog; maintainers publish after installing and verifying the DMG.

A parallel dry-run job runs on every PR that touches `packages/mac-app/**` or the workflow itself. The dry-run stops before notarization (no cert needed) so PR contributors can verify the assembly pipeline without secrets.

The iOS TestFlight pipeline lives at `.github/workflows/release-ios.yml` and triggers on the same `server-v*` tag push. It regenerates `packages/ios-app/TronMobile.xcodeproj` from XcodeGen, verifies `VERSION.env` mirrors, runs the iOS simulator tests, archives the `Tron` scheme with the `Prod` configuration (`com.tron.mobile` / App ID `6761511764`), exports an App Store Connect IPA with Xcode's `app-store-connect` export method, uploads with `asc builds upload`, waits for the Apple build to become valid, resolves TestFlight export compliance, updates What to Test notes, submits TestFlight beta review when Apple requires it for external testing, and branches on the ASC review state. First external builds for a new marketing version normally enter `WAITING_FOR_BETA_REVIEW`; CI treats that as a successful pending-review checkpoint instead of timing out. Once Apple approves the version, rerunning the workflow or uploading later builds in the same version continues to group validation and assigns the build to the public external TestFlight group when one is configured or can be auto-discovered. The public group is the same TestFlight link shown by the Mac onboarding QR code. TestFlight group checks are warning-only after the build is uploaded and processed because successful public distribution must not be blocked by stale or renamed group variables that CI does not need to create the beta build. Reruns are idempotent: if the Apple build number already exists in App Store Connect, CI skips the binary upload and reuses that build for processing/distribution. Manual workflow runs default to `dry_run=true` and stop before ASC upload.

Required iOS release credentials are GitHub Actions secrets `ASC_KEY_ID`, `ASC_ISSUER_ID`, and `ASC_KEY_P8_BASE64`. `ASC_TESTFLIGHT_PUBLIC_GROUP_ID` and `ASC_TESTFLIGHT_INTERNAL_GROUP_ID` are optional repository variables used for group assignment diagnostics; CI can auto-discover a single public-link group and otherwise skips group assignment without failing an uploaded/processed build. CI can export with automatic Xcode cloud signing through the ASC key, or with local signing secrets when `IOS_DISTRIBUTION_CERT_P12_BASE64`, `IOS_DISTRIBUTION_CERT_PASSWORD`, `IOS_APPSTORE_PROFILE_BASE64`, and `IOS_SHARE_EXTENSION_APPSTORE_PROFILE_BASE64` are set. Local signing supports both manually managed App Store profiles and matching Xcode-managed App Store profiles. `ASC_KEY_ID` and the `.p8` path can be checked locally with `asc auth status --verbose` / `asc auth doctor`; `ASC_ISSUER_ID` is shown in App Store Connect under Users and Access -> Integrations -> App Store Connect API -> Team Keys. The iOS app and share extension declare `ITSAppUsesNonExemptEncryption=false`; CI verifies that key in the archive/export and can apply the same App Store Connect API build setting to already-uploaded builds that predate the plist key. TestFlight/App Store Connect remains the distribution and audit surface for iOS binaries. Do not create separate GitHub releases for iOS unless an iOS artifact is intentionally published through GitHub too; the shared `VERSION.env` keeps Mac/server and iOS version labels aligned without adding duplicate tags.

### User-mode Update Checks

For users installed via DMG (no git remote), the server can poll GitHub Releases and surface the notarized DMG URL per the `server.update.*` settings. The module lives at `packages/agent/src/platform/updater/mod.rs`. Installing an update remains a visible replacement of `/Applications/Tron.app` from the notarized DMG; the server does not mutate the signed app bundle or stage update artifacts under `~/.tron`. After app replacement, the wrapper syncs bundled managed skills into `~/.tron/skills/` the next time the menu-bar app opens or starts the helper.

| Phase | Action | Effect |
|-------|--------|--------|
| Check | `system.checkForUpdates` | Queries `api.github.com/repos/mhismail3/tron/releases`; returns the highest semver allowed by `channel` (`stable` excludes pre-release tags, `beta` includes them). Cached 60s to avoid rate-limit thrash. |
| Notify | `action: "notify"` | Emits `server.update_available`; iOS banner + menu-bar submenu surface the release and DMG URL. No server-side download. |

Safety invariants (all test-covered):

- No app-bundle mutation: runtime files stay outside `Tron.app`, and replacing the app is a user-visible DMG install.
- Skipped if a dev server has taken over port 9847 (same guard as `auto-deploy`).
- Pause-able via `~/.tron/internal/run/auto-update.pause` sentinel; `tron self-update pause|resume` manages it.

**Contrast with `tron auto-deploy`**: the latter is contributor-only, pulls from `origin/main`, and refuses to run outside a git repo. Users on DMG-installed builds use `tron self-update` exclusively. See [CLI Reference → Deployment](#cli-reference) for the full command surface.

---

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

### Manual Readiness

Use [docs/manual-testing-readiness.md](docs/manual-testing-readiness.md) before
broad manual QA. It covers clean local state, helper packaging, capability
search/inspect/execute, program runs, provider-switch history reconstruction,
Engine Console checks, offline behavior, Mac wrapper smoke, and relay/APNs
smoke checks.

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

5. **Event ordering (iOS send button)**: `agent.ready` is emitted AFTER `agent.complete`. iOS `handleComplete()` sets `isPostProcessing=true`, `handleAgentReady()` clears it. Three independent send-button concerns: `isPostProcessing`, `isCompacting`, and ledger (fully async).

6. **Compaction before ledger**: Memory manager runs compaction then ledger sequentially. `compact.boundary` events always precede `memory.ledger` events in the event log.

7. **Hook drain ordering**: Background hooks are drained before accepting a new prompt (pre-run) and before session reconstruction (resume). Prevents stale hook state from interfering.

8. **Production DB guard**: Startup validates the database path is `~/.tron/internal/database/tron.sqlite` only. Rejects alternate filenames, wrong directories, and symlinked paths.

9. **Single-process DB ownership**: Startup takes an OS-level `flock(2)` on `tron.sqlite.lock` before opening the connection pool. A second `tron` process pointed at the same database aborts with a clear error naming the holder's PID, instead of silently racing on `(session_id, sequence)` writes. Released on process exit (normal or abnormal). Enforced by `domains/session/event_store/sqlite/process_lock.rs::acquire_database_lock` called from startup database initialization.

---

## License

MIT
