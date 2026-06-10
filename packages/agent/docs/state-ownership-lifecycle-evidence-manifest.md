# State Ownership And Lifecycle Evidence Manifest

Status: **active**

Current score: **59/100**

Scorecard:
[`state-ownership-lifecycle-scorecard.md`](state-ownership-lifecycle-scorecard.md)

Inventory:
[`state-ownership-lifecycle-inventory.md`](state-ownership-lifecycle-inventory.md)
and
[`state-ownership-lifecycle-inventory.tsv`](state-ownership-lifecycle-inventory.tsv)

## Row Ledger

| Row | Status | Evidence | Verification | Open loops | Checkpoint |
|---|---|---|---|---|---|
| SOL-0 | passed_after_fix | Added the campaign scorecard, evidence manifest, inventory scaffolding, machine-readable TSV header, invariant target, and README living-doc links. The invariant target is intentionally red for later rows until inventory coverage and closeout are complete. | `cargo test --manifest-path packages/agent/Cargo.toml --test state_ownership_lifecycle_invariants -- --nocapture` expected to fail on final-state gates at SOL-0. | SOL-1 through SOL-10 remain open by design. | SOL-0 campaign harness checkpoint |
| SOL-1 | passed_after_fix | Generated `state-ownership-lifecycle-inventory.tsv` with an initial 476 rows covering every tracked production Rust/Swift file containing SOL lifecycle markers plus README, SOL docs, scripts, and CI workflow state surfaces. Owner pass removed all `unclassified_owner` rows. SOL-4 added two narrower runtime service rows, bringing the active TSV to 478 rows. | `cargo test --manifest-path packages/agent/Cargo.toml --test state_ownership_lifecycle_invariants sol_inventory -- --nocapture` -> exit 0, 3 passed. | Later rows refine lifecycle proof for engine substrate, session/event store, settings/auth, iOS local state, and observability. | SOL-1 state inventory checkpoint |
| SOL-2 | passed_after_fix | Added and passed owner-scoped truth taxonomy guards over the TSV: allowed classes are documented; `unclassified_owner` is rejected; iOS/script/CI/docs rows cannot claim canonical server truth; canonical truth is restricted to session event-store, settings profile, and shared profile owners; secret rows are restricted to auth/Keychain/token owners; local device preferences remain iOS-local. | `cargo test --manifest-path packages/agent/Cargo.toml --test state_ownership_lifecycle_invariants sol_truth_taxonomy -- --nocapture` -> exit 0; `cargo test --manifest-path packages/agent/Cargo.toml --test state_ownership_lifecycle_invariants sol_inventory_rows_are_structured_and_classified -- --nocapture` -> exit 0. | Later rows prove lifecycle behavior behind each classified owner. | SOL-2 truth taxonomy checkpoint |
| SOL-3 | passed_after_fix | Source-backed bootstrap lifecycle proof now covers directories, bearer-token materialization, canonical DB policy, generation archive, process flock, integrity check, migrations, shared storage schema, logging, startup retention/size-budget maintenance, engine host durable catalog hydration, domain/worker registration, crash-journal recovery, background task registration, bind, graceful shutdown, log flush, and final checkpoint. | `cargo test --manifest-path packages/agent/Cargo.toml --test state_ownership_lifecycle_invariants sol_server_bootstrap_lifecycle_is_source_backed -- --nocapture` -> exit 0; implementation targets listed in the SOL-3 evidence section passed. | Later rows prove steady-state runtime tasks, engine substrate, sessions, settings/auth, iOS state, and observability. | SOL-3 server bootstrap lifecycle checkpoint |
| SOL-4 | passed_after_fix | Deleted dead `SessionManager::plan_mode` state and added source-backed runtime lifecycle proof for active-session cache flags, run/retain RAII guards, sequence/compaction cleanup, invocation abort guards, capability pending cleanup, shutdown task registry, blocking supervisor drain, runtime service cancellation, and app bootstrap task registration. | `cargo test --manifest-path packages/agent/Cargo.toml --test state_ownership_lifecycle_invariants sol_runtime_task_memory_lifecycle_is_source_backed -- --nocapture` -> exit 0; implementation filters listed in SOL-4 evidence passed. | No SOL-4 open loops; later rows prove durable engine substrate, sessions, settings/auth, iOS local state, observability, and final closeout. | SOL-4 runtime task and memory lifecycle checkpoint |
| SOL-5 | passed_after_fix | Added source-backed durable substrate proof for the engine ledger, idempotency rows, queues, streams, resource versions, grants, leases, audit-only compensation records, state store revisions, payload refs, retention, checkpoint, export, and SQLite/in-memory primitive store bundles. | `cargo test --manifest-path packages/agent/Cargo.toml --test state_ownership_lifecycle_invariants sol_engine_durable_substrate_lifecycle_is_source_backed -- --nocapture` -> exit 0; implementation filters listed in SOL-5 evidence passed. | No SOL-5 open loops; later rows prove session/event-store lifecycle, settings/auth/secrets, iOS local/projection state, observability, and final closeout. | SOL-5 engine durable substrate lifecycle checkpoint |
| SOL-6 | pending | Not started. | Not run. | Session/event-store lifecycle proof remains. | pending |
| SOL-7 | pending | Not started. | Not run. | Settings/auth/secrets lifecycle proof remains. | pending |
| SOL-8 | pending | Not started. | Not run. | iOS projection/local state lifecycle proof remains. | pending |
| SOL-9 | pending | Not started. | Not run. | Observability/recovery evidence remains. | pending |
| SOL-10 | pending | Not started. | Not run. | Final verification and clean worktree proof remain. | pending |

## SOL-0 Evidence

Artifacts added:

- `packages/agent/docs/state-ownership-lifecycle-scorecard.md`
- `packages/agent/docs/state-ownership-lifecycle-evidence-manifest.md`
- `packages/agent/docs/state-ownership-lifecycle-inventory.md`
- `packages/agent/docs/state-ownership-lifecycle-inventory.tsv`
- `packages/agent/tests/state_ownership_lifecycle_invariants.rs`
- Root README living architecture links for the SOL artifacts.

Initial red findings captured in the scorecard:

- Unowned/dead `SessionManager::plan_mode`, deleted in SOL-4 after source scan
  confirmed only local setter/getter references.
- Audit-only compensation status was proved in SOL-5: only `recorded` is
  accepted, and future automated rollback requires a new owner, status
  transitions, and tests.
- iOS event-store session metadata merges local projections with server
  session info and needs server-truth proof.
- README living-doc status wording still needs a stale active-label cleanup pass.
- iOS local-only stores need explicit local/projection classifications.

## SOL-1 Evidence

Inventory coverage:

- Total TSV rows: 478. SOL-1 generated 476 initial rows; SOL-4 added explicit
  runtime-service rows for queue-drainer and worker-heartbeat cancellation
  ownership.
- State class counts: `ephemeral_runtime` 262, `projection_cache` 71,
  `durable_substrate` 68, `canonical_truth` 41, `secret` 16,
  `diagnostic_buffer` 11, `local_device_preference` 9.
- Required non-Rust/Swift surfaces are covered: `README.md`,
  `scripts/tron`, `scripts/tron.d/dev.sh`, `scripts/tron.d/quality.sh`,
  `scripts/tron-lib.d/service.sh`, and `.github/workflows/ci.yml`.
- Owner audit: no `unclassified_owner` rows remain.

## SOL-2 Evidence

Taxonomy guard:

- `sol_truth_taxonomy_is_owner_scoped` requires every allowed state class to be
  documented and rejects taxonomy drift in the TSV.
- Canonical truth rows are limited to `session_event_store`,
  `settings_profile`, and `shared_foundation`.
- iOS, script, CI, and docs rows cannot claim canonical server truth.
- Secrets are limited to auth credentials, Keychain, and paired-server token
  storage.
- Local device preference rows are iOS-owned.

## SOL-3 Evidence

Bootstrap lifecycle proof:

- `run_server` performs directory seeding and bearer-token materialization before
  opening the database, then opens the canonical event-store DB, loads profile
  runtime/settings, initializes SQLite-backed logging, runs startup retention
  and size-budget maintenance, constructs the event store and engine host,
  recovers crash journals, registers domain/worker surfaces, starts owned
  runtime services, binds the server, and drains through graceful shutdown.
- `init_database` resolves the production `tron.sqlite` path, creates the
  parent directory, archives non-current storage generations, acquires the
  process `flock` before opening the pool, checks integrity, runs session
  migrations, and ensures shared storage schema.
- `onboarding::load_or_create_bearer_token` reads an existing token or
  serializes first-run materialization through the auth storage writer and
  atomic save path.
- `StorageRuntime` applies WAL/busy-timeout/foreign-key pragmas, records the
  current storage generation, archives stale generation sidecars, and records
  checkpoints.
- `EngineHost::open_sqlite` prepares the shared active DB, checkpoints it,
  opens the SQLite ledger, hydrates durable catalog definitions, attaches
  SQLite primitive stores, and bootstraps primitive/meta capabilities.
- Durable external-worker restart behavior is covered by
  `sqlite_restart_marks_durable_worker_unhealthy_without_socket_reconnect`, so
  a persisted worker definition hydrates as non-runnable until the worker
  reconnects.

## SOL-4 Evidence

Runtime task and memory lifecycle proof:

- `SessionManager::plan_mode`, `set_plan_mode`, and `is_plan_mode` were deleted;
  session manager state is now the reconstructable active-session cache plus
  explicit processing flags.
- Active sessions have cache insert/remove/retain paths, idle eviction, and
  processing flags that are set for active work and cleared afterward.
- Orchestrator active runs are guarded by `StartedRun` drop cleanup; retained
  sessions are guarded by `RetainGuard` drop cleanup; sequence counters,
  compaction handlers, invocation abort tokens, and capability pending calls
  have explicit remove/clear/cancel paths.
- `InvocationAbortRegistry` uses scoped guards and cancellation tokens so child
  tool invocations unregister on drop and can be cancelled by session/id.
- `CapabilityInvocationTracker` owns pending response senders behind a mutex and
  removes or clears them on resolve/cancel-all.
- `ShutdownCoordinator` owns registered task abort handles, phase callbacks,
  timeout-based drain, and self-pruning task completion.
- `BlockingTaskSupervisor` bounds detached blocking work, tracks active guards,
  and registers a shutdown phase callback plus task handles with the shutdown
  coordinator.
- `EngineRuntimeServices` registers queue drainer and worker-heartbeat tasks
  with shutdown and passes cancellation tokens that break each run loop.
- `spawn_background_tasks` registers cache eviction and profile watcher tasks,
  and bootstrap registers blocking-supervisor shutdown before service bind.

## SOL-5 Evidence

Engine durable substrate lifecycle proof:

- Compensation is audit-only durable state. `EngineCompensationStatus` accepts
  only `Recorded`/`recorded`; host finalization appends the audit record,
  records `compensation_status`, and publishes `compensation.recorded`.
- Ledger state is owner-private durable substrate: catalog changes, durable
  worker/function definitions, invocation rows, produced resource refs, session
  listing, and idempotency reserve/complete records are persisted through the
  engine ledger store.
- Queue state has explicit ready, leased, completed, cancelled, and
  dead-lettered statuses. Lease ownership is cleared at terminal transitions,
  and attempt records preserve resource lease and compensation references in
  both memory and SQLite stores.
- Resource state is versioned and typed. Registration, create, update, link,
  inspect, list, CAS conflict handling, current-version pointers, lifecycle
  events, and payload refs stay behind the resource store owner.
- State entries are scoped by namespace/key with monotonic revisions, CAS
  mutation, delete/list paths, and shared-storage payload refs for persisted
  values.
- Stream state persists events and subscriptions with publish, subscribe,
  latest-cursor, poll, acknowledge, unsubscribe, visibility filtering, and
  session-listing paths in memory and SQLite stores.
- Shared storage owns large payload refs with `owner_kind`, `owner_id`,
  `field_name`, `retention_class`, and expiry metadata. Checkpoint, export,
  retention runs, payload pruning, and storage stats are shared-storage
  responsibilities rather than ad hoc engine-store cleanup.
- `PrimitiveStores::sqlite` opens the SQLite stream, state, queue, lease,
  resource, grant, and compensation stores as a single bundle, installs built-in
  resource types, and exposes them through `EngineHost` instead of direct
  external callers.

## Verification Log

- SOL-0 harness proof:
  `cargo test --manifest-path packages/agent/Cargo.toml --test state_ownership_lifecycle_invariants sol_campaign_harness_exists -- --nocapture`
  -> exit 0.
- SOL-0 red static proof:
  `cargo test --manifest-path packages/agent/Cargo.toml --test state_ownership_lifecycle_invariants -- --nocapture`
  -> exit 101, with 3 passing scaffold/shape tests and 8 expected later-row
  failures: inventory coverage, script/CI/docs rows, dead `plan_mode`, Rust
  `tokio::spawn` lifecycle guards, Swift `Task` lifecycle guards, settings/auth
  owner-private write guard, iOS local-state classification rows, and final
  closeout.
- SOL-0 formatting/whitespace proof:
  `cargo fmt --manifest-path packages/agent/Cargo.toml --all -- --check &&
  git diff --check` -> exit 0.
- SOL-1 focused verification:
  `cargo test --manifest-path packages/agent/Cargo.toml --test state_ownership_lifecycle_invariants sol_inventory -- --nocapture`
  -> exit 0, 3 passed.
- SOL-1 full-target status:
  `cargo test --manifest-path packages/agent/Cargo.toml --test state_ownership_lifecycle_invariants -- --nocapture`
  -> exit 101, with 9 passing gates and 2 expected remaining failures:
  `dead_plan_mode_state_is_removed` and `final_closeout_is_complete`.
- SOL-2 focused verification:
  `cargo test --manifest-path packages/agent/Cargo.toml --test state_ownership_lifecycle_invariants sol_truth_taxonomy -- --nocapture`
  -> exit 0; `cargo test --manifest-path packages/agent/Cargo.toml --test state_ownership_lifecycle_invariants sol_inventory_rows_are_structured_and_classified -- --nocapture`
  -> exit 0.
- SOL-3 static source-backed verification:
  `cargo test --manifest-path packages/agent/Cargo.toml --test state_ownership_lifecycle_invariants sol_server_bootstrap_lifecycle_is_source_backed -- --nocapture`
  -> exit 0.
- SOL-3 implementation verification:
  `cargo test --manifest-path packages/agent/Cargo.toml app::lifecycle --lib -- --nocapture`
  -> exit 0, 43 passed; `cargo test --manifest-path packages/agent/Cargo.toml app::bootstrap --lib -- --nocapture`
  -> exit 0, 80 passed; `cargo test --manifest-path packages/agent/Cargo.toml shared::storage --lib -- --nocapture`
  -> exit 0, 6 passed; `cargo test --manifest-path packages/agent/Cargo.toml sqlite_restart_marks_durable_worker_unhealthy_without_socket_reconnect --lib -- --nocapture`
  -> exit 0, 1 passed; `cargo test --manifest-path packages/agent/Cargo.toml process_lock --lib -- --nocapture`
  -> exit 0, 11 passed.
- SOL-4 static source-backed verification:
  `cargo test --manifest-path packages/agent/Cargo.toml --test state_ownership_lifecycle_invariants sol_runtime_task_memory_lifecycle_is_source_backed -- --nocapture`
  -> exit 0; `cargo test --manifest-path packages/agent/Cargo.toml --test state_ownership_lifecycle_invariants dead_plan_mode_state_is_removed -- --nocapture`
  -> exit 0.
- SOL-4 current full-target status:
  `cargo test --manifest-path packages/agent/Cargo.toml --test state_ownership_lifecycle_invariants -- --nocapture`
  -> exit 101, with 13 passing gates and 1 expected remaining failure:
  `final_closeout_is_complete`.
- SOL-4 implementation verification:
  `cargo test --manifest-path packages/agent/Cargo.toml session_manager --lib -- --nocapture`
  -> exit 0, 26 passed; `cargo test --manifest-path packages/agent/Cargo.toml begin_run --lib -- --nocapture`
  -> exit 0, 3 passed; `cargo test --manifest-path packages/agent/Cargo.toml retain --lib -- --nocapture`
  -> exit 0, 5 passed; `cargo test --manifest-path packages/agent/Cargo.toml invocation_abort_registry --lib -- --nocapture`
  -> exit 0, 9 passed; `cargo test --manifest-path packages/agent/Cargo.toml capability_invocation_tracker --lib -- --nocapture`
  -> exit 0, 10 passed; `cargo test --manifest-path packages/agent/Cargo.toml app::lifecycle::shutdown --lib -- --nocapture`
  -> exit 0, 21 passed; `cargo test --manifest-path packages/agent/Cargo.toml shared::server::context --lib -- --nocapture`
  -> exit 0, 24 passed; `cargo test --manifest-path packages/agent/Cargo.toml transport::runtime --lib -- --nocapture`
  -> exit 0, 12 passed; `cargo test --manifest-path packages/agent/Cargo.toml app::bootstrap --lib -- --nocapture`
  -> exit 0, 80 passed.
- SOL-5 static source-backed verification:
  `cargo test --manifest-path packages/agent/Cargo.toml --test state_ownership_lifecycle_invariants sol_engine_durable_substrate_lifecycle_is_source_backed -- --nocapture`
  -> exit 0.
- SOL-5 implementation verification:
  `cargo test --manifest-path packages/agent/Cargo.toml engine::tests::durability --lib -- --nocapture`
  -> exit 0, 41 passed; `cargo test --manifest-path packages/agent/Cargo.toml engine::tests::authority --lib -- --nocapture`
  -> exit 0, 8 passed; `cargo test --manifest-path packages/agent/Cargo.toml engine::tests::invocation::idempotency --lib -- --nocapture`
  -> exit 0, 3 passed; `cargo test --manifest-path packages/agent/Cargo.toml engine::tests::invocation::meta_primitives --lib -- --nocapture`
  -> exit 0, 10 passed; `cargo test --manifest-path packages/agent/Cargo.toml shared::storage --lib -- --nocapture`
  -> exit 0, 6 passed; `cargo test --manifest-path packages/agent/Cargo.toml engine::tests::runtime::external_worker --lib -- --nocapture`
  -> exit 0, 15 passed.
- SOL-5 current full-target status:
  `cargo test --manifest-path packages/agent/Cargo.toml --test state_ownership_lifecycle_invariants -- --nocapture`
  -> exit 101, with 14 passing gates and 1 expected remaining failure:
  `final_closeout_is_complete`.

## Residual Risk Log

- The `@self-inspect` project skill is not available in the current configured
  skill/tool list. The campaign therefore uses direct source scans and focused
  repository tests for the SOL-0 harness; later rows should use any available
  local database inspection paths when a lifecycle claim depends on runtime
  state under `~/.tron/internal/database/`.
