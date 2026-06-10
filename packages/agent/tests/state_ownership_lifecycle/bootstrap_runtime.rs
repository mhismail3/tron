use super::support::*;

#[test]
fn sol_server_bootstrap_lifecycle_is_source_backed() {
    let bootstrap = read_repo_file("packages/agent/src/app/bootstrap/mod.rs");
    let run_server = bootstrap
        .split("pub(crate) async fn run_server")
        .nth(1)
        .expect("run_server must remain the server bootstrap entry point");
    assert_contains_in_order(
        "server bootstrap sequence",
        run_server,
        &[
            "init_directories()",
            "initialize_bearer_token_at",
            "init_database(args.db_path)",
            "ProfileRuntime::load",
            "init_logging",
            "retention_run(false",
            "enforce_size_budget",
            "EventStore::new",
            "init_engine_host",
            "init_services",
            "build_server_runtime_context",
            "TronServer::new",
            "register_server_domains_for_context",
            "EngineStreamEventPump::new",
            "EngineRuntimeServices::start",
            "spawn_background_tasks",
            "spawn_watcher",
            "server.listen()",
            "wait_for_shutdown_signal",
            "graceful_shutdown",
            "flush_task.abort",
            "log_handle.flush",
            "checkpoint()",
        ],
    );
    assert_contains_in_order(
        "database bootstrap sequence",
        &bootstrap,
        &[
            "resolve_production_db_path",
            "ensure_parent_dir",
            "prepare_active_database",
            "acquire_database_lock",
            "new_file",
            "check_integrity",
            "run_migrations",
            "ensure_storage_schema",
        ],
    );
    assert!(
        bootstrap.contains("recover_incomplete_turns(&event_store)"),
        "bootstrap must recover crash journals before accepting traffic"
    );

    let onboarding = read_repo_file("packages/agent/src/app/lifecycle/onboarding/mod.rs");
    assert_contains_in_order(
        "bearer-token materialization sequence",
        &onboarding,
        &[
            "load_or_create_bearer_token",
            "read_token(path)",
            "rotate_lock().lock()",
            "load_or_init_for_write(path)",
            "generate_bearer_token()",
            "save_auth_storage(path",
        ],
    );

    let storage = read_repo_file("packages/agent/src/shared/storage/mod.rs");
    assert_contains_in_order(
        "storage runtime startup sequence",
        &storage,
        &[
            "pub const CURRENT_STORAGE_GENERATION",
            "pub fn open_connection",
            "apply_runtime_pragmas(&conn)",
            "ensure_storage_schema(&conn)",
            "pub fn prepare_for_startup",
            "prepare_active_database(&self.path)",
        ],
    );

    let archive = read_repo_file("packages/agent/src/shared/storage/archive.rs");
    assert_contains_in_order(
        "storage generation archive sequence",
        &archive,
        &[
            "archive_non_current_active_database",
            "active_database_generation",
            "CURRENT_STORAGE_GENERATION",
            "archive_named_files",
            "fs::rename",
        ],
    );

    let schema = read_repo_file("packages/agent/src/shared/storage/schema.rs");
    for required in [
        "PRAGMA journal_mode = WAL",
        "PRAGMA busy_timeout = 5000",
        "CREATE TABLE IF NOT EXISTS storage_metadata",
        "STORAGE_GENERATION_KEY",
    ] {
        assert!(
            schema.contains(required),
            "storage schema bootstrap missing `{required}`"
        );
    }

    let engine_host = read_repo_file("packages/agent/src/engine/invocation/host/bootstrap.rs");
    assert_contains_in_order(
        "engine host sqlite bootstrap sequence",
        &engine_host,
        &[
            "pub fn open_sqlite",
            "prepare_for_startup",
            "open_connection",
            "checkpoint",
            "SqliteEngineLedgerStore::open",
            "hydrate_durable_catalog_from_ledger",
            "PrimitiveStores::sqlite",
            "bootstrap_meta_capabilities",
        ],
    );

    let process_lock =
        read_repo_file("packages/agent/src/domains/session/event_store/sqlite/process_lock.rs");
    for required in [
        "flock(2)",
        "Every production startup path acquires this lock before",
        "DatabaseLock",
        "AlreadyLocked",
        "try_flock_exclusive",
    ] {
        assert!(
            process_lock.contains(required),
            "database process-lock owner missing `{required}`"
        );
    }

    let inventory = inventory_by_path();
    for required in [
        "packages/agent/src/app/bootstrap/mod.rs",
        "packages/agent/src/app/bootstrap/server.rs",
        "packages/agent/src/app/lifecycle/onboarding/mod.rs",
        "packages/agent/src/shared/storage/archive.rs",
        "packages/agent/src/shared/storage/schema.rs",
        "packages/agent/src/shared/foundation/paths/mod.rs",
    ] {
        assert!(
            inventory
                .get(required)
                .is_some_and(|rows| rows.iter().any(|row| row.sol_rows.contains("SOL-3"))),
            "SOL inventory must tag {required} as part of SOL-3"
        );
    }
}

#[test]
fn sol_runtime_task_memory_lifecycle_is_source_backed() {
    let session_manager =
        read_repo_file("packages/agent/src/domains/agent/loop/orchestrator/session_manager/mod.rs");
    for forbidden in ["plan_mode", "set_plan_mode", "is_plan_mode"] {
        assert!(
            !session_manager.contains(forbidden),
            "SessionManager still contains unowned dead state marker `{forbidden}`"
        );
    }
    for required in [
        "active_sessions: DashMap<String, CachedSession>",
        "last_accessed: Mutex<Instant>",
        "is_processing: AtomicBool",
        "insert(session_id.clone()",
        "insert(session_id.to_owned()",
        "active_sessions.remove",
        "active_sessions.retain",
        "cached.is_processing.load",
        "cached.is_processing.store(true",
        "cached.is_processing.store(false",
    ] {
        assert!(
            session_manager.contains(required),
            "SessionManager runtime cache lifecycle missing `{required}`"
        );
    }

    let core = read_repo_file("packages/agent/src/domains/agent/loop/orchestrator/core/mod.rs");
    assert_contains_in_order(
        "StartedRun cleanup",
        &core,
        &[
            "pub struct StartedRun",
            "impl Drop for StartedRun",
            "self.registry.remove",
            "self.permit.take",
        ],
    );
    assert_contains_in_order(
        "RetainGuard cleanup",
        &core,
        &[
            "pub struct RetainGuard",
            "impl Drop for RetainGuard",
            "self.set.remove",
        ],
    );
    for required in [
        "run_semaphore: Arc<Semaphore>",
        "active_runs: Mutex<HashMap<String, ActiveRun>>",
        "sequence_counters: Arc<DashMap<String, Arc<AtomicI64>>>",
        "remove_sequence_counter",
        "compaction_handlers.remove",
        "capability_invocation_tracker.lock().cancel_all()",
        "sequence_counters.clear()",
        "compaction_handlers.clear()",
        "invocation_abort_registry: Arc<InvocationAbortRegistry>",
    ] {
        assert!(
            core.contains(required),
            "Orchestrator runtime lifecycle missing `{required}`"
        );
    }

    let abort_registry = read_repo_file(
        "packages/agent/src/domains/agent/loop/orchestrator/invocation_abort_registry.rs",
    );
    assert_contains_in_order(
        "InvocationAbortGuard cleanup",
        &abort_registry,
        &[
            "pub struct InvocationAbortGuard",
            "impl Drop for InvocationAbortGuard",
            "self.registry",
            ".unregister",
        ],
    );
    for required in [
        "entries: DashMap<Key, CancellationToken>",
        "token.cancel()",
        "remove(&(",
    ] {
        assert!(
            abort_registry.contains(required),
            "Invocation abort registry lifecycle missing `{required}`"
        );
    }

    let tracker = read_repo_file(
        "packages/agent/src/domains/agent/loop/orchestrator/capability_invocation_tracker.rs",
    );
    for required in [
        "pending: HashMap<String, oneshot::Sender<Value>>",
        "pending.insert",
        "pending.remove",
        "pending.clear",
    ] {
        assert!(
            tracker.contains(required),
            "Capability invocation tracker lifecycle missing `{required}`"
        );
    }

    let shutdown = read_repo_file("packages/agent/src/app/lifecycle/shutdown.rs");
    for required in [
        "abort_handles: Mutex<HashMap<u64, AbortHandle>>",
        "register_task",
        "handle.abort()",
        "registry.finish(task_id)",
        "wait_for_empty",
        "register_phase_callback",
        "run_phase_callbacks",
        "tokio::time::timeout",
    ] {
        assert!(
            shutdown.contains(required),
            "Shutdown coordinator lifecycle missing `{required}`"
        );
    }

    let server_context = read_repo_file("packages/agent/src/shared/server/context.rs");
    assert_contains_in_order(
        "blocking supervisor lifecycle",
        &server_context,
        &[
            "pub struct BlockingTaskSupervisor",
            "semaphore: Arc<tokio::sync::Semaphore>",
            "struct BlockingTaskGuard",
            "impl Drop for BlockingTaskGuard",
            "self.active.fetch_sub",
            "register_blocking_supervisor_shutdown",
            "shutdown.register_phase_callback",
        ],
    );
    assert!(
        server_context.contains("shutdown.register_task(handle)"),
        "detached blocking tasks must register with the shutdown coordinator"
    );

    let runtime = read_repo_file("packages/agent/src/transport/runtime/mod.rs");
    for required in [
        "EngineRuntimeServices",
        "shutdown.register_task(tokio::spawn(service.run()))",
        "shutdown.register_task(tokio::spawn(heartbeat.run()))",
    ] {
        assert!(
            runtime.contains(required),
            "Engine runtime service ownership missing `{required}`"
        );
    }
    for (path, owner) in [
        (
            "packages/agent/src/transport/runtime/queue_drainer.rs",
            "queue drainer",
        ),
        (
            "packages/agent/src/transport/runtime/worker_heartbeat.rs",
            "worker heartbeat",
        ),
    ] {
        let source = read_repo_file(path);
        assert!(
            source.contains("CancellationToken") && source.contains("cancel.cancelled()"),
            "{owner} must select on its shutdown cancellation token"
        );
    }

    let bootstrap = read_repo_file("packages/agent/src/app/bootstrap/mod.rs");
    for required in [
        "spawn_background_tasks",
        "server.shutdown().register_task(eviction_task)",
        "register_blocking_supervisor_shutdown(server.shutdown())",
        "EngineRuntimeServices::start(&server)",
        "register_task(profile_runtime_for_watcher.spawn_watcher",
    ] {
        assert!(
            bootstrap.contains(required),
            "app bootstrap background task ownership missing `{required}`"
        );
    }

    let inventory = inventory_by_path();
    for required in [
        "packages/agent/src/app/bootstrap/mod.rs",
        "packages/agent/src/app/bootstrap/server.rs",
        "packages/agent/src/app/lifecycle/shutdown.rs",
        "packages/agent/src/domains/agent/loop/orchestrator/capability_invocation_tracker.rs",
        "packages/agent/src/domains/agent/loop/orchestrator/core/mod.rs",
        "packages/agent/src/domains/agent/loop/orchestrator/invocation_abort_registry.rs",
        "packages/agent/src/domains/agent/loop/orchestrator/session_manager/mod.rs",
        "packages/agent/src/shared/server/context.rs",
        "packages/agent/src/transport/runtime/mod.rs",
        "packages/agent/src/transport/runtime/queue_drainer.rs",
        "packages/agent/src/transport/runtime/worker_heartbeat.rs",
    ] {
        assert!(
            inventory
                .get(required)
                .is_some_and(|rows| rows.iter().any(|row| row.sol_rows.contains("SOL-4"))),
            "SOL inventory must tag {required} as part of SOL-4"
        );
    }
}
