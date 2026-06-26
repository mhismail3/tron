# State Ownership And Lifecycle Inventory

Status: SOL-10 `passed_after_fix`; 594 state-surface rows inventoried and classified.

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
cancellation ownership, SOL-6 added the session lifecycle module contract row,
SOL-8 added the iOS architecture state-ownership doc row, and SOL-9 tagged the
already-inventoried observability/recovery rows for health, logs, storage
maintenance, replay, crash recovery, and shutdown drain visibility. SACB
closeout splits added the capability grant helper and external-worker runtime
lifecycle rows without changing ownership boundaries. Phase 1 iOS affordance
closeout rows cover local audio/camera/session-list state, transcription
runtime state, worker lifecycle projections, and their task/spawn lifecycle
owners. Phase 2 Slice 18A review follow-up added the touched
`capability::execute` context authority gate for read-only memory query/decision
evidence.
The same follow-up records the touched runtime-grant unit test surface as a
test fixture.

State class distribution:

| State class | Rows |
|---|---:|
| `ephemeral_runtime` | 292 |
| `projection_cache` | 124 |
| `durable_substrate` | 81 |
| `canonical_truth` | 41 |
| `secret` | 16 |
| `test_fixture` | 19 |
| `diagnostic_buffer` | 11 |
| `local_device_preference` | 10 |

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

## SOL-7 Settings/Auth/Secrets Lifecycle Proof

| Surface | Owner | Lifecycle proof |
|---|---|---|
| Sparse settings overlay | `settings_profile` | `SettingsStore` owns `profiles/user/profile.toml` writes, serializes sync writes through `SETTINGS_WRITE_LOCK`, validates merged effective settings before atomic temp-file persistence, reloads the global settings cache, and restores prior sparse JSON for rollback. |
| Settings operation rollback | `settings_profile` / `agent_domain` | Settings update/reset handlers take `SettingsStore::operation_lock`, snapshot the sparse overlay, write through the store, reload `ProfileRuntime`, and restore the sparse file plus last-known-good settings if profile compilation fails. |
| Profile runtime snapshot | `agent_domain` | `ProfileRuntime` stores the current valid compiled profile in `ArcSwap`; reloads are all-or-previous, watcher changes are cancellation-token scoped, and the profile hash excludes `auth.json` so secret rotation does not reload profile settings. |
| Auth storage file | `auth_credentials` | `auth.json` accepts only missing or exact `{}` as first-use state; malformed non-empty files hard error. Writes update `last_updated`, persist through same-directory temp files with 0o600 permissions, and cross-process mutation uses `run/auth.lock` with `flock`. |
| Canonical auth operations | `auth_credentials` | `auth_update`, `auth_clear`, OAuth completion, rename, active-credential selection, account removal, and API-key removal acquire the auth lock before mutation, rebuild masked state, and publish `auth.updated` events. |
| Bearer token | `app_lifecycle` / `auth_credentials` | Startup materializes `auth.json.bearerToken` through auth storage; rotation uses the onboarding process mutex plus atomic auth storage writes; HTTP auth caches by file mtime and compares presented bearer tokens in constant time. |
| Pending OAuth flows | `auth_credentials` | Pending flow entries live in the auth domain map, are pruned on begin, removed on completion, and expire after the explicit 600-second TTL before token exchange persistence. |
| Provider OAuth refresh | `auth_credentials` | Anthropic, OpenAI, and Google refresh paths use a process-local refresh mutex, auth-file `flock`, disk re-read after lock acquisition, under-lock persistence with persistence-error propagation, and stale `invalid_grant` retry from the latest disk snapshot. Google was fixed in SOL-7 to match this protocol. |
| Model provider auth copies | `model_domain` | Provider factory re-reads auth snapshots on provider creation; Google provider stores only an ephemeral in-memory token mutex for mid-session continuity and does not persist durable auth truth. |

## SOL-8 iOS Projection And Local-State Lifecycle Proof

| Surface | Owner | Lifecycle proof |
|---|---|---|
| iOS event projection DB | `ios_engine_persistence` / `support_composition` | `EventDatabase` has one production storage root: Documents `.tron/database/prod.db`. Production composition fails at the owner boundary when Documents is unavailable instead of switching substrates. Test and diagnostics harnesses use explicit isolated database paths. |
| Session list projection | `ios_engine_persistence` | `EventStoreManager.refreshSessionList` fetches server sessions, merges or creates local `CachedSession` rows, tags them with server origin, removes server-missing local rows/events, reloads in-memory sessions, and seeds processing state from server data. |
| Session event sync | `ios_engine_persistence` | `SessionSynchronizer` fetches events after the stored sync cursor, inserts server events, records the new cursor, clears and refetches rows on full sync, and fetches fork ancestors from the server without making iOS canonical truth. |
| Stream cursors and ACKs | `ios_engine_persistence` / `engine_transport` | `EngineStreamCursorStore` keys cursors by origin/topic/session/workspace/filter hash. `EngineClient` stores cursors for ACK coalescing and diagnostics only; session history is reconstructed through server APIs. |
| Connection runtime state | `engine_transport` | `EngineConnection`, `EngineClient`, and `ConnectionManager` cancel or clear receive, heartbeat, reconnect, open-timeout, request-timeout, stream-ACK, observation, and hook state on disconnect, cleanup, backgrounding, or deinit. |
| Settings snapshot UI | `ios_session` | `SettingsState` loads and resets through server repositories, clears snapshots when the active server changes, overwrites every field from the active server, and rolls failed edits back to the last loaded snapshot. |
| Paired servers and bearer tokens | `ios_pairing` / `ios_token_storage` | `PairedServerStore` owns the device-local paired-server list and active selection in `UserDefaults`; `PairedServerTokenStore` owns per-server bearer tokens in Keychain and removes them by paired-server id. |
| Drafts, history, and share handoff | `ios_storage` / `ios_share` | Draft saves are debounced and flushed/cleared by session lifecycle; input history is bounded and removes its `UserDefaults` key on clear; pending share content is App Group handoff state with save/load/clear boundaries. |
| MetricKit diagnostics | `ios_diagnostics` | MetricKit payloads live in Application Support behind an `NSLock`, are written atomically, and are pruned by age, file count, and total bytes before diagnostics bundle inclusion. |
| iOS architecture docs | `project_docs` | `packages/ios-app/docs/architecture.md` records that iOS owns projections, local device preferences, Keychain secrets, and diagnostic buffers, never canonical server truth. |

## SOL-9 Observability And Recovery Lifecycle Proof

| Surface | Owner | Lifecycle proof |
|---|---|---|
| Health/deep health/metrics routes | `app_bootstrap` / `app_health` | `TronServer::router` exposes `/health`, `/health/deep`, and `/metrics`. Health reads live connection/session counters, deep health runs database/settings/auth/binary/disk checks through owner facades, and metrics render the installed Prometheus recorder. |
| SQLite log transport | `shared_observability` | `init_subscriber_with_sqlite` installs a batching `SqliteTransport`, exposes a flush handle, flushes warn/error entries immediately, writes batches transactionally into `logs`, and the bootstrap shutdown path aborts the periodic task after a final flush. |
| Logs capabilities | `logs_domain` / `session_event_store` | `logs::ingest` is append-only and idempotent through the engine ledger, stores client logs via `EventStore::ingest_client_logs`, caps batch and message size, deduplicates rows with `INSERT OR IGNORE`, and `logs::recent`/`log_recent` read bounded scoped evidence through `list_recent_logs`. |
| Storage stats and maintenance | `shared_storage` / `engine_primitives` | `storage::stats` is pure read over table and payload-owner statistics. Checkpoint, export, and retention are engine-authorized storage primitives that record `storage_checkpoints`, `storage_exports`, and `storage_retention_runs` audit rows while pruning only retention-eligible diagnostics/expired refs/unowned blobs. |
| Replay manifests | `session_replay` | `replay_manifest` requires the current session, reads event-store rows, resolved payload refs, trace records, and engine replay snapshots, computes stable section hashes plus a replay hash, and regression tests prove it does not create trace records. |
| Crash recovery | `agent_orchestrator` | Startup recovery scans orphaned streaming journals, appends recovered partial output through the session event store, deletes recovered journals, and logs recovery outcomes before the server accepts traffic. |
| Shutdown drain visibility | `app_lifecycle` | `ShutdownCoordinator` tracks registered task counts, rejects late tasks, runs phase callbacks with timeout/panic metrics, records drain duration and timeout counters, aborts slow tasks, and reports any post-abort remaining task count. |

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
| Health/log/storage/replay/shutdown evidence | diagnostic buffer / durable substrate / projection cache | app health, shared observability/storage, logs domain, session replay, app lifecycle | SOL-9 proved these surfaces expose owner-backed evidence without creating alternate truth owners. | SOL-9 |

## Coverage Rules

- SOL-1 added one TSV row for every tracked production Rust/Swift file that
  contains one of the lifecycle markers enforced by the invariant target.
- SOL-1 also added rows for script/CI state surfaces and docs-owned state claims
  named by the scorecard.
- SOL-2 ensures every TSV row uses exactly one allowed state class.
- Later rows may refine broad rows into narrower lifecycle owners, but active
  rows may not describe closed work as open after SOL-10.
