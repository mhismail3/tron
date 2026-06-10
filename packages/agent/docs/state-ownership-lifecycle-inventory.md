# State Ownership And Lifecycle Inventory

Status: SOL-6 `passed_after_fix`; 479 state-surface rows inventoried and classified.

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
cancellation ownership, and SOL-6 added the session lifecycle module contract
row.

State class distribution:

| State class | Rows |
|---|---:|
| `ephemeral_runtime` | 262 |
| `projection_cache` | 72 |
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

## SOL-5 Engine Durable Substrate Lifecycle Proof

| Surface | Owner | Lifecycle proof |
|---|---|---|
| Engine ledger | `engine_invocation` | Catalog changes, durable worker/function definitions, invocation rows, produced resource refs, idempotency reserve/complete records, and session listings are persisted behind the ledger store facade. |
| Idempotency records | `engine_invocation` | Mutating host paths reserve idempotency before handler execution and complete or replay through ledger-owned rows; duplicate handling never calls handlers outside the ledger policy. |
| Queues and attempts | `engine_runtime` / `engine_invocation` | Queue items move through ready, leased, completed, cancelled, and dead-lettered states; terminal transitions clear lease ownership and persist attempt records with resource lease and compensation refs. |
| Streams and subscriptions | `engine_invocation` | Stream stores own publish, subscribe, latest-cursor, poll, acknowledge, unsubscribe, visibility filtering, and session-listing lifecycle paths. |
| Resource store | `engine_resource_store` | Resource type registration, create, update, link, inspect, list, current-version pointers, CAS conflict handling, lifecycle events, and version payload refs remain behind the resource store owner. |
| Grants and leases | `engine_authority` | Grants are resolved from owner-private stores before execution; resource leases have acquire/release/expiration state and emit acquired/released stream events through host bookkeeping. |
| Compensation audit records | `engine_authority` | Compensation is audit-only durable state in this branch: the only accepted status is `recorded`; future automated rollback needs a new owner, status transitions, and tests. |
| Engine state store | `engine_state_store` | Namespaced state entries mutate through monotonic revisions, CAS conflict checks, delete/list paths, and shared-storage payload refs. |
| Shared storage payload refs | `shared_storage` | Large JSON payloads record owner kind, owner id, field name, retention class, and expiry metadata; shared storage owns retention, checkpoint, export, pruning, and stats. |
| Primitive store bundle | `engine_primitives` | `PrimitiveStores::sqlite` opens stream, state, queue, lease, resource, grant, and compensation stores as one SQLite-backed bundle and installs built-in resource types before exposure through `EngineHost`. |

## SOL-6 Session And Event-Store Lifecycle Proof

| Surface | Owner | Lifecycle proof |
|---|---|---|
| Session lifecycle wrappers | `session_lifecycle` | Create normalizes working directories and initializes sequence counters; fork initializes a child counter; archive/unarchive mutates reversible `ended_at` row state; delete removes active-session projections and calls session-scoped event-store cleanup. |
| Session manager active cache | `agent_orchestrator` | Active session entries insert on create/resume/fork, remove on end/delete, retain only while recent or processing, and rebuild on resume from event-store truth after eviction or restart. |
| Event-store create transaction | `session_event_store` | Session creation owns workspace get/create, session row insertion, root `session.start` event insertion, root/head updates, and counter initialization in one event-store boundary. |
| Append ordering and payload refs | `session_event_store` / `shared_storage` | Appends acquire the session lock, derive `MAX(sequence) + 1`, enforce `UNIQUE(session_id, sequence)`, store large payloads as shared-storage refs, and update session head/counters atomically. |
| Forked ancestor history | `session_event_store` | Fork creates a child session row and `session.fork` root event parented to the source event; reconstruction follows the ordered cross-session ancestor chain without copying source-session truth. |
| End/archive/unarchive/delete | `session_event_store` / `session_lifecycle` | End appends `session.end`; archive sets `ended_at`; unarchive clears `ended_at`; delete is the only physical event-row cleanup path and is session-scoped. |
| Append-only message deletion | `session_event_store` | Individual message deletion appends a `message.deleted` event; the unused physical `EventRepo::delete(event_id)` helper and test were removed. |
| Reconstruction and query | `session_event_store` / `session_query` | Resume/list/state/history/export read event-store rows, capped ancestor pagination, blob-backed payload refs, in-flight state, message previews, and ordered `tron.session.v1` event payloads. |
| Replay manifest overlap | `session_replay` | Replay manifests are byte-stable over durable session sections; SOL-9 owns broader observability and recovery evidence. |

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
| `EventRepo::delete(event_id)` | deleted dead state | none accepted | Single-event physical delete was repository-only dead code and conflicted with append-only event ownership; SOL-6 removed it and retained only session-scoped delete cleanup. | SOL-6 |
| Engine compensation records | durable audit substrate | engine authority | Records are appended during invocation and inspectable through the engine host; SOL-5 proved the audit-only lifecycle with the single `recorded` status. Future rollback needs explicit owner/status transitions/tests. | SOL-5 |
| iOS `EventStoreManager` session metadata | projection cache | iOS event persistence | Local counts/head/root are reconstructable local projections and must not override canonical server truth. | SOL-8 |
| iOS pairing/token stores | local device preference / secret | iOS support composition | Pairing list is device-local; bearer tokens are Keychain secrets keyed by paired server id. | SOL-8 |
| iOS drafts/history/share/diagnostics | local device preference / projection / diagnostic buffer | iOS support/session | Drafts and pending share are local user workflow state; diagnostics are observation buffers. | SOL-8 |

## Coverage Rules

- SOL-1 added one TSV row for every tracked production Rust/Swift file that
  contains one of the lifecycle markers enforced by the invariant target.
- SOL-1 also added rows for script/CI state surfaces and docs-owned state claims
  named by the scorecard.
- SOL-2 ensures every TSV row uses exactly one allowed state class.
- Later rows may refine broad rows into narrower lifecycle owners, but active
  rows may not describe closed work as open after SOL-10.
