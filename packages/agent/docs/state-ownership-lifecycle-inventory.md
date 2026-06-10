# State Ownership And Lifecycle Inventory

Status: SOL-4 `passed_after_fix`; 478 state-surface rows inventoried and classified.

This inventory classifies stateful Tron surfaces by owner, lifecycle class,
scope, creation path, mutation boundary, hydration or reconstruction path,
retirement or retention path, and concurrency or task guard.

Machine-readable rows live in
[`state-ownership-lifecycle-inventory.tsv`](state-ownership-lifecycle-inventory.tsv).

## Allowed State Classes

| Class | Meaning |
|---|---|
| `canonical_truth` | Durable fact read by agents/operators as source of truth. |
| `durable_substrate` | Low-level persisted backing store owned behind a facade. |
| `projection_cache` | Reconstructable local or derived view over canonical truth. |
| `ephemeral_runtime` | In-memory/task state valid only for a process or view lifetime. |
| `local_device_preference` | Device-local preference or UI setting. |
| `secret` | Credential, token, or sensitive material with a narrow owner. |
| `diagnostic_buffer` | Logs, metrics, health state, or diagnostics retained for observation. |
| `test_fixture` | Test-only state excluded from production lifecycle claims. |

## SOL-1 Inventory Summary

The machine-readable inventory now covers every tracked production Rust/Swift
file containing one of the SOL lifecycle markers, plus the required script/CI
and docs-owned state claim rows. SOL-1 generated 476 initial rows; SOL-4 added
two narrower runtime-service rows for queue-drainer and worker-heartbeat
cancellation ownership.

State class distribution:

| State class | Rows |
|---|---:|
| `ephemeral_runtime` | 262 |
| `projection_cache` | 71 |
| `durable_substrate` | 68 |
| `canonical_truth` | 41 |
| `secret` | 16 |
| `diagnostic_buffer` | 11 |
| `local_device_preference` | 9 |

## SOL-2 Taxonomy Proof

The inventory is guarded by `sol_truth_taxonomy_is_owner_scoped`:

- Every row uses exactly one allowed state class.
- No row has an unclassified owner.
- Canonical truth is server-side only and limited to session event-store,
  settings profile, and shared profile owners.
- iOS, script, CI, and docs rows cannot claim canonical server truth.
- Secret rows are owned by auth credentials, Keychain, or paired-server token
  storage.
- Local device preference rows stay iOS-local.

## SOL-3 Server Bootstrap Lifecycle Proof

| Surface | Owner | Lifecycle proof |
|---|---|---|
| Tron Home directories | `shared_foundation` / `app_bootstrap` | `run_server` calls `init_directories`, which delegates to the constitution seeder before token, database, logging, or network work begins. |
| Bearer token | `app_lifecycle` / `auth_credentials` | Startup calls `initialize_bearer_token_at`; `load_or_create_bearer_token` reads existing `auth.json.bearerToken` or serializes first-run materialization through `load_or_init_for_write`, `generate_bearer_token`, and `save_auth_storage`. |
| Active database path | `settings_profile` / `session_event_store` | `init_database` resolves and validates the canonical `internal/database/tron.sqlite` path before opening storage. Alternate filenames, wrong parents, and symlink DB files are rejected by policy tests. |
| Database generation and archive | `shared_storage` | `prepare_active_database` archives a non-current `tron.sqlite` plus WAL/SHM sidecars under `internal/database/archive/` before the active DB is opened. |
| Process flock and migrations | `session_event_store` | `acquire_database_lock` takes the `tron.sqlite.lock` process lock before `new_file`; startup then runs integrity check, session migrations, and shared storage schema initialization. |
| SQLite logging | `shared_observability` / `app_bootstrap` | `init_logging` opens a dedicated SQLite connection, applies storage pragmas, installs the subscriber, and owns a registered flush task that is aborted and flushed during shutdown. |
| Startup storage maintenance | `shared_storage` | Startup runs configured retention and size-budget enforcement after logging initialization and before service construction; shutdown records a final checkpoint. |
| Engine host hydration | `engine_invocation` | `EngineHost::open_sqlite` prepares startup storage, opens the SQLite ledger, hydrates durable catalog definitions, attaches SQLite primitive stores, and bootstraps primitive/meta capabilities. |
| Worker hydration | `engine_runtime` | Durable worker definitions hydrate as catalog records, but restart tests prove they are marked unhealthy/stopped until the local worker reconnects. |
| Crash journal recovery | `agent_runtime` / `app_bootstrap` | `init_services` calls `recover_incomplete_turns` before server bind and logs whether orphaned journals were recovered. |
| Bind and shutdown | `app_bootstrap` / `app_lifecycle` | Domain workers, stream pump, runtime services, cache eviction, and profile watcher are registered before `server.listen`; shutdown drains server/pump handles, registered tasks, log flush, and storage checkpoint. |

## SOL-4 Runtime Task And Memory Lifecycle Proof

| Surface | Owner | Lifecycle proof |
|---|---|---|
| Session manager active cache | `agent_orchestrator` | `SessionManager` owns only reconstructable active-session cache state: insert on create/resume, remove on end/delete, idle eviction through `retain`, and processing flags set/cleared around active turns. Dead `SessionManager::plan_mode` state was deleted. |
| Orchestrator active runs | `agent_orchestrator` | `StartedRun` owns active-run registration and semaphore permit release through `Drop`; retained sessions use `RetainGuard` drop cleanup. |
| Sequence and compaction runtime state | `agent_orchestrator` | Sequence counters and compaction handlers are owner-private maps with remove/clear paths on session cleanup and orchestrator shutdown. |
| Invocation abort registry | `agent_orchestrator` | `InvocationAbortRegistry` owns session/id cancellation tokens; `InvocationAbortGuard` unregisters entries on drop and abort paths cancel matching tokens. |
| Capability invocation tracker | `agent_orchestrator` | Pending capability responders live behind the tracker mutex and are inserted, removed on resolve, or cleared on cancel-all. |
| Shutdown coordinator | `app_lifecycle` | Registered tasks are tracked by abort handles, self-prune on completion, run phase callbacks in order, time out slow drains, and abort slow tasks. |
| Blocking task supervisor | `shared_server` | Detached blocking work is bounded by semaphore guards, decremented on guard drop, registered as shutdown tasks, and drained by a shutdown phase callback. |
| Runtime service loops | `runtime_transport` | Queue drainer and worker-heartbeat tasks are registered with shutdown and receive cancellation tokens that break their select loops. |
| App background tasks | `app_bootstrap` | Cache eviction, blocking-supervisor shutdown, runtime services, and profile watcher are registered during bootstrap before the server binds. |

Non-source state surfaces covered by SOL-1:

- `README.md`
- `packages/agent/docs/state-ownership-lifecycle-scorecard.md`
- `packages/agent/docs/state-ownership-lifecycle-evidence-manifest.md`
- `packages/agent/docs/state-ownership-lifecycle-inventory.md`
- `packages/agent/docs/state-ownership-lifecycle-inventory.tsv`
- `scripts/tron`
- `scripts/tron.d/dev.sh`
- `scripts/tron.d/quality.sh`
- `scripts/tron-lib.d/service.sh`
- `.github/workflows/ci.yml`

## SOL-0 Seed Findings

| Surface | Current classification | Owner | Lifecycle note | SOL rows |
|---|---|---|---|---|
| `SessionManager::plan_mode` | deleted dead state | none accepted | `DashMap<String, bool>` had only local setter/getter references and was removed in SOL-4. | SOL-4 |
| Engine compensation records | durable audit substrate | engine authority | Records are appended during invocation and inspectable through the engine host; SOL-5 must prove audit-only status is intentional or add terminal transitions. | SOL-5 |
| iOS `EventStoreManager` session metadata | projection cache | iOS event persistence | Local counts/head/root are reconstructable local projections and must not override canonical server truth. | SOL-8 |
| iOS pairing/token stores | local device preference / secret | iOS support composition | Pairing list is device-local; bearer tokens are Keychain secrets keyed by paired server id. | SOL-8 |
| iOS drafts/history/share/diagnostics | local device preference / projection / diagnostic buffer | iOS support/session | Drafts and pending share are local user workflow state; diagnostics are observation buffers. | SOL-8 |

## Coverage Rules

- SOL-1 added one TSV row for every tracked production Rust/Swift file that
  contains one of the lifecycle markers enforced by the invariant target.
- SOL-1 also added rows for script/CI state surfaces and docs-owned state claims
  named by the scorecard.
- SOL-2 must ensure every TSV row uses exactly one allowed state class.
- Later rows may refine broad rows into narrower lifecycle owners, but active
  rows may not describe closed work as open after SOL-10.
