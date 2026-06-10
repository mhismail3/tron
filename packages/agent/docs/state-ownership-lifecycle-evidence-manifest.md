# State Ownership And Lifecycle Evidence Manifest

Status: **active**

Current score: **97/100**

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
| SOL-1 | passed_after_fix | Generated `state-ownership-lifecycle-inventory.tsv` with an initial 476 rows covering every tracked production Rust/Swift file containing SOL lifecycle markers plus README, SOL docs, scripts, and CI workflow state surfaces. Owner pass removed all `unclassified_owner` rows. SOL-4 added two narrower runtime service rows, SOL-6 added the session lifecycle module contract row, and SOL-8 added the iOS architecture state-ownership doc row, bringing the active TSV to 480 rows. | `cargo test --manifest-path packages/agent/Cargo.toml --test state_ownership_lifecycle_invariants sol_inventory -- --nocapture` -> exit 0, 3 passed. | Later rows refine lifecycle proof for engine substrate, session/event store, settings/auth, iOS local state, and observability. | SOL-1 state inventory checkpoint |
| SOL-2 | passed_after_fix | Added and passed owner-scoped truth taxonomy guards over the TSV: allowed classes are documented; `unclassified_owner` is rejected; iOS/script/CI/docs rows cannot claim canonical server truth; canonical truth is restricted to session event-store, settings profile, and shared profile owners; secret rows are restricted to auth/Keychain/token owners; local device preferences remain iOS-local. | `cargo test --manifest-path packages/agent/Cargo.toml --test state_ownership_lifecycle_invariants sol_truth_taxonomy -- --nocapture` -> exit 0; `cargo test --manifest-path packages/agent/Cargo.toml --test state_ownership_lifecycle_invariants sol_inventory_rows_are_structured_and_classified -- --nocapture` -> exit 0. | Later rows prove lifecycle behavior behind each classified owner. | SOL-2 truth taxonomy checkpoint |
| SOL-3 | passed_after_fix | Source-backed bootstrap lifecycle proof now covers directories, bearer-token materialization, canonical DB policy, generation archive, process flock, integrity check, migrations, shared storage schema, logging, startup retention/size-budget maintenance, engine host durable catalog hydration, domain/worker registration, crash-journal recovery, background task registration, bind, graceful shutdown, log flush, and final checkpoint. | `cargo test --manifest-path packages/agent/Cargo.toml --test state_ownership_lifecycle_invariants sol_server_bootstrap_lifecycle_is_source_backed -- --nocapture` -> exit 0; implementation targets listed in the SOL-3 evidence section passed. | Later rows prove steady-state runtime tasks, engine substrate, sessions, settings/auth, iOS state, and observability. | SOL-3 server bootstrap lifecycle checkpoint |
| SOL-4 | passed_after_fix | Deleted dead `SessionManager::plan_mode` state and added source-backed runtime lifecycle proof for active-session cache flags, run/retain RAII guards, sequence/compaction cleanup, invocation abort guards, capability pending cleanup, shutdown task registry, blocking supervisor drain, runtime service cancellation, and app bootstrap task registration. | `cargo test --manifest-path packages/agent/Cargo.toml --test state_ownership_lifecycle_invariants sol_runtime_task_memory_lifecycle_is_source_backed -- --nocapture` -> exit 0; implementation filters listed in SOL-4 evidence passed. | No SOL-4 open loops; later rows prove durable engine substrate, sessions, settings/auth, iOS local state, observability, and final closeout. | SOL-4 runtime task and memory lifecycle checkpoint |
| SOL-5 | passed_after_fix | Added source-backed durable substrate proof for the engine ledger, idempotency rows, queues, streams, resource versions, grants, leases, audit-only compensation records, state store revisions, payload refs, retention, checkpoint, export, and SQLite/in-memory primitive store bundles. | `cargo test --manifest-path packages/agent/Cargo.toml --test state_ownership_lifecycle_invariants sol_engine_durable_substrate_lifecycle_is_source_backed -- --nocapture` -> exit 0; implementation filters listed in SOL-5 evidence passed. | No SOL-5 open loops; later rows prove session/event-store lifecycle, settings/auth/secrets, iOS local/projection state, observability, and final closeout. | SOL-5 engine durable substrate lifecycle checkpoint |
| SOL-6 | passed_after_fix | Removed dead single-event physical deletion and added source-backed session/event-store lifecycle proof for create, resume, append, fork, end, archive, unarchive, delete, query, reconstruction, export, and session-scoped cleanup. | `cargo test --manifest-path packages/agent/Cargo.toml --test state_ownership_lifecycle_invariants sol_session_event_store_lifecycle_is_source_backed -- --nocapture` -> exit 0; implementation filters listed in SOL-6 evidence passed. | No SOL-6 open loops; later rows prove settings/auth/secrets, iOS projection/local state, observability, and final closeout. | SOL-6 session event-store lifecycle checkpoint |
| SOL-7 | passed_after_fix | Fixed Google credential refresh so persisted tokens are updated only after the refresh path acquires the process-local refresh mutex, auth file lock, and fresh disk snapshot; tightened all OAuth refresh paths so persistence failures fail refresh instead of falling back to stale durable truth; added source-backed proof for sparse settings writes/rollback, profile runtime snapshots, auth.json materialization, bearer-token lifecycle, OAuth pending-flow TTL, canonical auth write boundaries, provider refresh persistence, and ephemeral model-provider auth copies. | `cargo test --manifest-path packages/agent/Cargo.toml --test state_ownership_lifecycle_invariants sol_settings_auth_secrets_lifecycle_is_source_backed -- --nocapture` -> exit 0; implementation filters listed in SOL-7 evidence passed. | No SOL-7 open loops; later rows prove iOS projection/local state, observability/recovery, and final closeout. | SOL-7 settings auth secrets checkpoint |
| SOL-8 | passed_after_fix | Removed production temporary event-database and MetricKit temporary-directory paths; added source-backed proof for iOS projection/local owners, including Documents-backed event cache, server-sync reconstruction, ACK-only stream cursors, connection task cleanup, settings snapshots, paired-server preferences, Keychain tokens, drafts/history/share handoff, bounded diagnostics, SourceGuard/TPC regression gates, and architecture docs. | Focused Rust SOL gates, TPC guard, XcodeGen, and the combined iOS SOL-8 target pass; see SOL-8 verification log below for exact commands. | No SOL-8 open loops; later rows prove observability/recovery and final closeout. | SOL-8 iOS projection/local state checkpoint |
| SOL-9 | passed_after_fix | Added source-backed proof for health/deep/metrics routing, deep-health owner checks, SQLite-backed logging, logs ingestion/query contracts, bounded `log_recent`, storage stats/checkpoint/export/retention audit rows, replay manifests, crash-journal recovery, and shutdown drain/callback metrics. Existing inventory rows for these surfaces are now SOL-9-tagged. | Focused SOL-9 static gate and implementation filters passed; see SOL-9 verification log below for exact commands. | No SOL-9 open loops; SOL-10 final closeout remains. | SOL-9 observability/recovery checkpoint |
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

- Total TSV rows: 480. SOL-1 generated 476 initial rows; SOL-4 added explicit
  runtime-service rows for queue-drainer and worker-heartbeat cancellation
  ownership, SOL-6 added the session lifecycle module contract row, and SOL-8
  added the iOS architecture state-ownership doc row.
- State class counts: `ephemeral_runtime` 262, `projection_cache` 73,
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

## SOL-6 Evidence

Session/event-store lifecycle proof:

- Removed the unused `EventRepo::delete(event_id)` path and its repository-only
  test. Event rows are append-only except for `EventStore::delete_session`,
  which performs session-scoped physical cleanup after the owning session is
  explicitly deleted. Individual message deletion remains represented by a
  `message.deleted` event.
- Session creation is source-backed by a single event-store transaction:
  workspace get/create, session row creation, root `session.start` event,
  session root/head updates, and token/cost counter initialization.
- Append lifecycle is guarded by the event-store append lock, derives the next
  per-session sequence from `SELECT MAX(sequence) + 1`, enforces
  `UNIQUE(session_id, sequence)`, stores large payloads through shared-storage
  payload refs, and updates session head/counters in the same owner boundary.
- Fork lifecycle creates a child session row, appends a `session.fork` root
  event parented to the chosen source event, initializes the child runtime
  sequence counter, and reconstructs ancestor history through the ordered
  cross-session chain owned by the event store.
- End, archive, unarchive, and delete are explicit session lifecycle paths:
  end appends `session.end`; archive sets `ended_at`; unarchive clears
  `ended_at`; delete removes the active cache entry, clears sequence and
  compaction projections, emits `SessionDeleted`, and calls session-scoped
  event-store cleanup.
- Runtime session-manager state is a reconstructable projection over event-store
  truth. Active sessions insert on create/resume/fork, remove on end/delete,
  idle eviction skips processing sessions, and resume rebuilds missing cache
  entries from stored session state.
- Query, reconstruction, and export paths remain event-store owned: resume/list
  read session rows and previews, state reconstruction resolves blob-backed
  payload refs, pagination is capped, fork-inherited ancestors stay owned by
  their source sessions, in-flight state is rebuilt from event data, and export
  emits ordered `tron.session.v1` event payloads.
- Progressive disclosure docs now state the session ownership rules in
  `domains/session/lifecycle`, `domains/session/event_store`, and
  `domains/session/event_store/store/event_store`: archive/unarchive is
  reversible row state, message deletion is append-only, projection cleanup is
  reconstructable, and physical event deletion is valid only inside
  `delete_session`.

## SOL-7 Evidence

Settings/auth/secrets lifecycle proof:

- Settings updates are sparse profile overlay writes owned by `SettingsStore`.
  The store serializes sync writes, validates merged effective settings before
  atomic temp-file persistence, reloads the global settings cache after writes,
  and exposes an async operation lock for higher-level update/reset workflows.
- Settings operation bodies snapshot the previous sparse overlay before update
  or reset, reload `ProfileRuntime`, and restore the sparse file plus
  last-known-good in-memory settings if the compiled profile runtime rejects the
  new state.
- `ProfileRuntime` holds the current valid compiled profile in `ArcSwap`.
  Startup and watcher reloads are all-or-previous: invalid profile edits return
  errors while the previous valid snapshot remains active. The watcher hashes
  profile TOML/MD files and intentionally ignores `auth.json`.
- Auth storage treats only exact `{}` as the pristine installer sentinel. Missing
  files are first-use; malformed non-empty files are hard errors. Writes update
  `last_updated` and persist through same-directory temp files with 0o600
  permissions. Mutating operations acquire the auth file `flock` before saving.
- Bearer-token lifecycle is owned by onboarding/auth storage. Startup
  materializes `auth.json.bearerToken`, rotation is process-mutex serialized,
  HTTP transport caches the token by file mtime, and verification uses
  constant-time comparison.
- Pending OAuth flows live in the auth domain's process-local map, are keyed by
  flow id, pruned on begin, removed on complete, and expire after the explicit
  600-second TTL before token exchange persistence.
- Anthropic, OpenAI, and Google credential refresh now share the same durable
  protocol: process-local refresh mutex, auth file lock, disk re-read after the
  lock, persistence while holding the lock, persistence-error propagation, and
  stale `invalid_grant` retry from the latest disk snapshot.
- Provider factory re-reads auth snapshots when creating model providers.
  Google model providers keep only an ephemeral in-memory token mutex for
  mid-session request continuity and do not write durable `auth.json` state.
- The root README Authentication section now documents the auth-owned refresh
  mutex, auth-file lock, disk re-read, persistence-error propagation, and
  model-provider ephemeral-token boundary.

## SOL-8 Evidence

iOS projection and local-state lifecycle proof:

- `EventDatabase` now has one production substrate: the Documents-backed
  `.tron/database/prod.db` projection cache. The production composition root
  fails at the owner boundary if Documents is unavailable instead of silently
  switching to another database path. Tests and diagnostics harnesses use an
  explicit `init(databasePath:)` isolated-store initializer.
- The old production temporary event database mode, storage-mode diagnostics
  field, and MetricKit temporary-directory path were removed. SourceGuard and
  the True Primitive Cleanup static gate now reject those removed substrate
  markers.
- `EventStoreManager.refreshSessionList` reconstructs local session rows from
  the server session list, preserves local-only projection fields such as
  `rootEventId`/`headEventId`, tags rows with the active server origin, and
  removes stale local sessions/events that the active server no longer reports.
- `SessionSynchronizer` owns session event sync cursors, fetches server events
  after the last synced event id, writes the sync state after insertion, clears
  and refetches rows for full sync, and fetches fork ancestors without copying
  source-session truth into a new canonical client owner.
- Engine stream cursors are keyed by server origin, topic, optional
  session/workspace, and filter hash. `EngineClient` stores them for ACK
  coalescing and diagnostics only; session history is reconstructed from server
  APIs, not replayed from cursor storage.
- `EngineConnection`, `EngineClient`, and `ConnectionManager` have explicit
  task cleanup for receive loops, heartbeat loops, open timeouts, reconnect
  tasks, request timeouts, stream ACK tasks, connection observations, and
  reconnect hooks.
- `SettingsState` is a render snapshot of server-authoritative settings. It
  loads via `settings::get`, resets via `settings::reset`, clears snapshots on
  active-server change, and rolls failed edits back to the last loaded server
  snapshot.
- Pairing and secrets are separated: `PairedServerStore` owns the device-local
  paired-server list and active selection in `UserDefaults`, while
  `PairedServerTokenStore` owns per-server bearer tokens in Keychain and
  removes them by paired-server id.
- Drafts, input history, and pending share content are local workflow state.
  Draft saves are debounced and flushed/cleared by session lifecycle; input
  history is bounded to 100 entries and now removes its `UserDefaults` key on
  clear; pending share content is App Group handoff state with save/load/clear
  boundaries.
- `MetricKitDiagnosticsStore` stores bounded Application Support diagnostic
  payloads behind an `NSLock`, prunes by age, file count, and total bytes, and
  exposes bounded diagnostics bundle snapshots without raw event payloads or
  file paths.
- `packages/ios-app/docs/architecture.md` now has a State Ownership section
  documenting that iOS owns projections, local device preferences, Keychain
  secrets, and diagnostic buffers, not canonical server truth. The SOL
  inventory includes the doc-owned state claim as a SOL-8 row.

## SOL-9 Evidence

Observability and recovery evidence proof:

- `TronServer::router` exposes `/health`, `/health/deep`, and `/metrics`.
  Health reads live connection/session counters; deep health executes
  database, settings, auth, binary, and disk checks through owner boundaries;
  metrics renders the installed Prometheus recorder.
- SQLite-backed logging remains owned by `shared_observability`: the subscriber
  installs `SqliteTransport`, batches entries, flushes warn/error entries
  immediately, persists batches transactionally to `logs`, and exposes a flush
  handle for shutdown.
- `logs::ingest`, `logs::recent`, and execute `log_recent` all pass through the
  event-store owner boundary. Ingestion is bounded, truncates oversized client
  messages, deduplicates via `INSERT OR IGNORE`, and recent-log reads are
  bounded and session/trace scoped.
- Storage evidence is owned by `shared_storage` and exposed through engine
  primitives: `storage::stats` reports table/payload-owner/unowned-blob/expired
  ref data; checkpoint/export/retention writes `storage_checkpoints`,
  `storage_exports`, and `storage_retention_runs` audit rows while pruning only
  eligible diagnostics, expired refs, and unowned blobs.
- `replay_manifest` is a read-only audit projection: it requires a current
  session, reads event-store rows, resolved payload refs, trace records, and
  engine replay snapshots, then emits `tron.replay.v1` section hashes and a
  replay hash. Regression tests prove it does not create trace records.
- Crash recovery scans orphaned streaming journals on startup, appends recovered
  partial output through the session event store, deletes recovered journals,
  and logs the recovery outcome before service bind.
- `ShutdownCoordinator` exposes drain visibility through registered-task
  gauges/counters, callback duration/panic/timeout metrics, drain duration
  histograms, timeout counters, abort counts, and remaining-task warnings.

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
- SOL-6 static source-backed verification:
  `cargo test --manifest-path packages/agent/Cargo.toml --test state_ownership_lifecycle_invariants sol_session_event_store_lifecycle_is_source_backed -- --nocapture`
  -> exit 0.
- SOL-6 implementation verification:
  `cargo test --manifest-path packages/agent/Cargo.toml session_manager --lib -- --nocapture`
  -> exit 0, 26 passed; `cargo test --manifest-path packages/agent/Cargo.toml domains::session::event_store::store::event_store --lib -- --nocapture`
  -> exit 0, 96 passed; `cargo test --manifest-path packages/agent/Cargo.toml domains::session::event_store::sqlite::repositories::event --lib -- --nocapture`
  -> exit 0, 72 passed; `cargo test --manifest-path packages/agent/Cargo.toml domains::session::event_store::sqlite::repositories::session --lib -- --nocapture`
  -> exit 0, 30 passed; `cargo test --manifest-path packages/agent/Cargo.toml domains::session::lifecycle --lib -- --nocapture`
  -> exit 0, 9 passed; `cargo test --manifest-path packages/agent/Cargo.toml domains::session::query --lib -- --nocapture`
  -> exit 0, 5 passed; `cargo test --manifest-path packages/agent/Cargo.toml domains::session::reconstruction --lib -- --nocapture`
  -> exit 0, 9 passed; `cargo test --manifest-path packages/agent/Cargo.toml domains::session::replay --lib -- --nocapture`
  -> exit 0, 2 passed; `cargo test --manifest-path packages/agent/Cargo.toml --test integration session_create_reconstruct_and_execute_observe_stay_on_primitive_surface -- --nocapture`
  -> exit 0, 1 passed.
- SOL-6 current full-target status:
  `cargo test --manifest-path packages/agent/Cargo.toml --test state_ownership_lifecycle_invariants -- --nocapture`
  -> exit 101, with 15 passing gates and 1 expected remaining failure:
  `final_closeout_is_complete`.
- SOL-7 static source-backed verification:
  `cargo test --manifest-path packages/agent/Cargo.toml --test state_ownership_lifecycle_invariants sol_settings_auth_secrets_lifecycle_is_source_backed -- --nocapture`
  -> exit 0.
- SOL-7 implementation verification:
  `cargo test --manifest-path packages/agent/Cargo.toml domains::settings --lib -- --nocapture`
  -> exit 0, 122 passed; `cargo test --manifest-path packages/agent/Cargo.toml domains::auth --lib -- --nocapture`
  -> exit 0, 205 passed; `cargo test --manifest-path packages/agent/Cargo.toml profile_runtime --lib -- --nocapture`
  -> exit 0, 5 passed; `cargo test --manifest-path packages/agent/Cargo.toml app::lifecycle::onboarding --lib -- --nocapture`
  -> exit 0, 22 passed; `cargo test --manifest-path packages/agent/Cargo.toml transport::http::auth --lib -- --nocapture`
  -> exit 0, 21 passed; `cargo test --manifest-path packages/agent/Cargo.toml domains::model::providers::factory --lib -- --nocapture`
  -> exit 0, 25 passed; `cargo test --manifest-path packages/agent/Cargo.toml domains::auth::credentials::google --lib -- --nocapture`
  -> exit 0, 14 passed.
- SOL-7 current full-target status:
  `cargo test --manifest-path packages/agent/Cargo.toml --test state_ownership_lifecycle_invariants -- --nocapture`
  -> exit 101, with 16 passing gates and 1 expected remaining failure:
  `final_closeout_is_complete`.
- SOL-8 static source-backed verification:
  `cargo test --manifest-path packages/agent/Cargo.toml --test state_ownership_lifecycle_invariants ios_local_state_is_documented_as_projection_or_local_state -- --nocapture`
  -> exit 0; `cargo test --manifest-path packages/agent/Cargo.toml --test state_ownership_lifecycle_invariants sol_ios_projection_local_state_lifecycle_is_source_backed -- --nocapture`
  -> exit 0; `cargo test --manifest-path packages/agent/Cargo.toml --test true_primitive_cleanup_invariants ios_engine_protocol_roots_are_split_and_event_database_has_one_substrate -- --nocapture`
  -> exit 0.
- SOL-8 iOS project and implementation verification:
  `cd packages/ios-app && xcodegen generate` -> exit 0.
  The first combined iOS test run exposed a stale `SettingsStateTests`
  hardcoded-home fixture and an exact near-budget row drift for
  `EventDatabaseTests.swift`; both were fixed before final verification.
  Final command:
  `xcodebuild test -scheme Tron -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:TronMobileTests/EventDatabaseTests -only-testing:TronMobileTests/DraftRepositoryTests -only-testing:TronMobileTests/DiagnosticsBundleBuilderTests -only-testing:TronMobileTests/MetricKitDiagnosticsStoreTests -only-testing:TronMobileTests/InputHistoryStoreTests -only-testing:TronMobileTests/SourceGuardTests -only-testing:TronMobileTests/CachedSessionTests -only-testing:TronMobileTests/SyncStateTests -only-testing:TronMobileTests/SessionEventTests -only-testing:TronMobileTests/EngineConnectionReconnectTests -only-testing:TronMobileTests/SettingsStateTests -only-testing:TronMobileTests/PairedServerStoreTests -only-testing:TronMobileTests/PairedServerTokenStoreTests -only-testing:TronMobileTests/DraftStoreTests`
  -> exit 0, 94 XCTest tests and 68 Swift Testing tests passed.
- SOL-8 formatting, whitespace, and residue verification:
  `cargo fmt --manifest-path packages/agent/Cargo.toml --all -- --check`
  -> exit 0; `git diff --check` -> exit 0; removed-substrate marker scan
  for `temporaryCache`, `temporaryCachePath`, `EventDatabaseStorageMode`,
  `eventDatabaseStorageMode`, and the old temporary event DB path returned only
  negative-test/static-guard string references.
- SOL-8 current full-target status:
  `cargo test --manifest-path packages/agent/Cargo.toml --test state_ownership_lifecycle_invariants -- --nocapture`
  -> exit 101, with 17 passing gates and 1 expected remaining failure:
  `final_closeout_is_complete`.
- SOL-9 static source-backed verification:
  `cargo test --manifest-path packages/agent/Cargo.toml --test state_ownership_lifecycle_invariants sol_observability_recovery_lifecycle_is_source_backed -- --nocapture`
  -> exit 0.
- SOL-9 implementation verification:
  `cargo test --manifest-path packages/agent/Cargo.toml app::health --lib -- --nocapture`
  -> exit 0, 15 passed; `cargo test --manifest-path packages/agent/Cargo.toml shared::observability --lib -- --nocapture`
  -> exit 0, 29 passed; `cargo test --manifest-path packages/agent/Cargo.toml shared::storage --lib -- --nocapture`
  -> exit 0, 6 passed; `cargo test --manifest-path packages/agent/Cargo.toml domains::session::replay --lib -- --nocapture`
  -> exit 0, 2 passed; `cargo test --manifest-path packages/agent/Cargo.toml --test primitive_trace_execution execute_replay_manifest_is_read_only_and_does_not_create_trace_record -- --nocapture`
  -> exit 0, 1 passed; `cargo test --manifest-path packages/agent/Cargo.toml --test primitive_trace_execution execute_log_recent_exposes_bounded_session_trace_logs -- --nocapture`
  -> exit 0, 1 passed; `cargo test --manifest-path packages/agent/Cargo.toml recovery --lib -- --nocapture`
  -> exit 0, 8 passed; `cargo test --manifest-path packages/agent/Cargo.toml app::lifecycle::shutdown --lib -- --nocapture`
  -> exit 0, 21 passed.
- SOL-9 current full-target status:
  `cargo test --manifest-path packages/agent/Cargo.toml --test state_ownership_lifecycle_invariants -- --nocapture`
  -> exit 101, with 18 passing gates and 1 expected remaining failure:
  `final_closeout_is_complete`.

## Residual Risk Log

- The `@self-inspect` project skill is not available in the current configured
  skill/tool list. The campaign therefore uses direct source scans and focused
  repository tests for the SOL-0 harness; later rows should use any available
  local database inspection paths when a lifecycle claim depends on runtime
  state under `~/.tron/internal/database/`.
