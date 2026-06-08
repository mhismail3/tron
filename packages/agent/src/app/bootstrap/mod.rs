//! Server startup/runtime wiring for the `tron` binary.
//!
//! The thin `main.rs` entry point handles process-level dispatch. This module
//! owns long-running server initialization so bootstrap, service construction,
//! shutdown registration, and background task wiring stay below one audited
//! boundary.

use std::path::{Path, PathBuf};
use std::sync::Arc;

use anyhow::{Context, Result};
pub mod config;
pub mod disk;
pub mod server;

use crate::app::bootstrap::config::ServerConfig;
use crate::app::bootstrap::server::TronServer;
use crate::app::cli::{Cli, run_subcommand};
use crate::domains::agent::r#loop::{Orchestrator, SessionManager, recover_incomplete_turns};
use crate::domains::model::providers::factory as provider_factory;
use crate::domains::model::providers::provider::ProviderFactory;
use crate::domains::session::event_store::{ConnectionConfig, EventStore};
use crate::domains::settings::db_path_policy::resolve_production_db_path;
use crate::shared::server::context::{
    AgentDeps, ServerRuntimeContext, register_blocking_supervisor_shutdown,
};
use crate::transport::runtime::streams::EngineStreamEventPump;

/// Run either the requested CLI subcommand or the long-running server.
pub async fn run(args: Cli) -> Result<()> {
    if let Some(ref cmd) = args.command {
        return run_subcommand(cmd);
    }
    run_server(args).await
}

pub(crate) fn initialize_bearer_token_at(path: &Path) -> Result<String> {
    crate::app::lifecycle::onboarding::load_or_create_bearer_token(path)
        .with_context(|| format!("Failed to initialize bearer token at {}", path.display()))
}

/// Build the human-readable startup log line, naming the bind address
/// and its trust assumption.
///
/// Extracted as a pure function so tests can pin the operator-visible
/// message — a regression here means the operator can't tell which
/// network the server is exposed to, which is the whole point of the
/// trusted-local trust marker on the `host` arg.
///
/// * `0.0.0.0` — annotated with a pointer at the Tailscale ACL
///   assumption.
/// * `127.0.0.1` / `localhost` — annotated as loopback-only.
/// * Any other explicit host — left bare, since the operator chose it
///   deliberately.
pub(crate) fn format_listening_log(addr: &std::net::SocketAddr, bind_host: &str) -> String {
    let trust_note = if bind_host == "0.0.0.0" || bind_host == "::" {
        " — reachable on all interfaces (trusted-local threat model: ensure Tailscale ACLs or firewall gating is in place)"
    } else if bind_host == "127.0.0.1" || bind_host == "::1" || bind_host == "localhost" {
        " — loopback-only"
    } else {
        ""
    };
    format!("Tron agent listening on http://{addr} (/engine protocol enabled){trust_note}")
}

#[cfg(unix)]
pub(crate) fn shutdown_signal_names() -> &'static [&'static str] {
    &["SIGINT", "SIGTERM"]
}

#[cfg(not(unix))]
pub(crate) fn shutdown_signal_names() -> &'static [&'static str] {
    &["SIGINT"]
}

async fn wait_for_shutdown_signal() -> Result<&'static str> {
    #[cfg(unix)]
    {
        let mut terminate =
            tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate())
                .context("Failed to listen for sigterm")?;
        tokio::select! {
            result = tokio::signal::ctrl_c() => {
                result.context("Failed to listen for ctrl-c")?;
                Ok("SIGINT")
            }
            _ = terminate.recv() => Ok("SIGTERM"),
        }
    }

    #[cfg(not(unix))]
    {
        tokio::signal::ctrl_c()
            .await
            .context("Failed to listen for ctrl-c")?;
        Ok("SIGINT")
    }
}

pub(crate) fn ensure_parent_dir(path: &std::path::Path) -> Result<()> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)
            .with_context(|| format!("Failed to create directory: {}", parent.display()))?;
    }
    Ok(())
}

/// Resolve the auth file path (`~/.tron/profiles/auth.json`).
pub(crate) fn auth_path() -> PathBuf {
    crate::domains::settings::loader::auth_path()
}

/// Ensure `~/.tron/` has the primitive Tron Home layout.
pub(crate) fn init_directories() -> Result<crate::shared::foundation::constitution::SeedReport> {
    crate::shared::foundation::constitution::ensure_tron_home()
        .context("Failed to initialize primitive Tron Home")
}

/// Open the SQLite database, run migrations, and return the pool + resolved path.
pub(crate) fn init_database(
    db_path_override: Option<PathBuf>,
) -> Result<(
    r2d2::Pool<r2d2_sqlite::SqliteConnectionManager>,
    PathBuf,
    crate::domains::session::event_store::DatabaseLock,
)> {
    let db_path = resolve_production_db_path(db_path_override)?;
    ensure_parent_dir(&db_path)?;
    let archive_report =
        crate::shared::storage::prepare_active_database(&db_path).with_context(|| {
            format!(
                "Failed to prepare unified database files for {}",
                db_path.display()
            )
        })?;
    if archive_report.moved_any() {
        tracing::info!(
            archive_dir = ?archive_report.archive_dir,
            files = archive_report.files.len(),
            "archived non-current database files before unified storage startup"
        );
    }

    // INVARIANT: A single process owns the event-store DB. Take the
    // OS-level flock before opening the connection pool so a stray
    // `tron dev` alongside the launchd service aborts at startup
    // instead of silently racing on (session_id, sequence).
    let db_lock = crate::domains::session::event_store::acquire_database_lock(&db_path).map_err(
        |e| match e {
            crate::domains::session::event_store::LockError::AlreadyLocked {
                db_path,
                holder_pid,
            } => anyhow::anyhow!(
                "Another Tron process (PID {holder_pid}) is already using {}. \
             Stop it (e.g. `launchctl stop com.tron.server` or `kill {holder_pid}`) and retry.",
                db_path.display()
            ),
            crate::domains::session::event_store::LockError::Io { path, source } => {
                anyhow::anyhow!(
                    "Failed to prepare database lock file at {}: {source}",
                    path.display()
                )
            }
        },
    )?;

    let db_str = db_path.to_string_lossy();
    let pool =
        crate::domains::session::event_store::new_file(&db_str, &ConnectionConfig::default())
            .context("Failed to open database")?;
    {
        let conn = pool.get().context("Failed to get DB connection")?;
        // Catch WAL-recovery-hiding-corruption before any writes
        // happen. The first connection to a file-backed DB triggers
        // automatic WAL replay; if the WAL was corrupt we want to
        // know NOW, not after a session has been partially
        // reconstructed from damaged data.
        crate::domains::session::event_store::check_integrity(&conn).context(
            "Database integrity check failed. The unified engine store may be corrupt; \
             restore from a backup or investigate ~/.tron/internal/database/tron.sqlite.",
        )?;
        let _ = crate::domains::session::event_store::run_migrations(&conn)
            .context("Failed to run migrations")?;
        crate::shared::storage::ensure_storage_schema(&conn)
            .context("Failed to initialize storage metadata schema")?;
    }
    Ok((pool, db_path, db_lock))
}

/// Initialize the server-owned live capability engine host.
pub(crate) fn init_engine_host(db_path: &Path) -> Result<crate::engine::EngineHostHandle> {
    crate::engine::EngineHostHandle::open_sqlite(db_path).with_context(|| {
        format!(
            "Failed to initialize engine host storage at {}",
            db_path.display()
        )
    })
}

/// Initialize tracing with SQLite persistence and start the periodic flush task.
fn init_logging(
    db_path: &std::path::Path,
    settings: &crate::domains::settings::TronSettings,
    log_level_override: Option<&str>,
    stderr_enabled: bool,
) -> Result<(
    crate::shared::observability::TransportHandle,
    tokio::task::JoinHandle<()>,
)> {
    // Dedicated connection, separate from pool. Must set WAL + busy_timeout to match
    // pool connections — without busy_timeout, concurrent writes cause SQLITE_BUSY errors.
    let log_conn =
        rusqlite::Connection::open(db_path).context("Failed to open logging DB connection")?;
    crate::shared::storage::apply_runtime_pragmas(&log_conn)
        .context("Failed to set logging connection pragmas")?;
    let module_overrides: Vec<(String, &str)> = settings
        .logging
        .module_overrides
        .iter()
        .map(|(m, lvl)| (m.clone(), lvl.as_filter_str()))
        .collect();
    let effective_log_level =
        log_level_override.unwrap_or_else(|| settings.observability.log_level.as_filter_str());
    let log_handle = crate::shared::observability::init_subscriber_with_sqlite(
        effective_log_level,
        &module_overrides,
        log_conn,
        stderr_enabled,
    );
    let flush_task = crate::shared::observability::spawn_flush_task(log_handle.clone());
    Ok((log_handle, flush_task))
}

/// Shared state produced by service initialization, consumed by server setup.
struct ServiceState {
    event_store: Arc<EventStore>,
    session_manager: Arc<SessionManager>,
    orchestrator: Arc<Orchestrator>,
    agent_deps: Option<AgentDeps>,
}

/// Build core services: orchestrator, session manager, providers, and capabilities.
async fn init_services(
    event_store: Arc<EventStore>,
    settings: &crate::domains::settings::TronSettings,
) -> anyhow::Result<ServiceState> {
    let session_manager = Arc::new(SessionManager::new(event_store.clone()));
    let orchestrator = Arc::new(Orchestrator::new(session_manager.clone()));

    // Crash recovery: recover partial LLM output from orphaned streaming journals
    let recovered = recover_incomplete_turns(&event_store);
    if !recovered.is_empty() {
        tracing::info!(
            count = recovered.len(),
            "recovered sessions from crash journals"
        );
    } else {
        tracing::debug!("no orphaned journals found, clean startup");
    }

    let (provider_factory, shared_http_client) = init_provider_factory(settings).await;
    let _ = shared_http_client;

    let agent_deps = Some(AgentDeps {
        provider_factory: provider_factory.clone(),
    });

    Ok(ServiceState {
        event_store,
        session_manager,
        orchestrator,
        agent_deps,
    })
}

/// Create provider factory and check startup auth availability.
async fn init_provider_factory(
    settings: &crate::domains::settings::TronSettings,
) -> (Arc<dyn ProviderFactory>, reqwest::Client) {
    let default_factory = provider_factory::DefaultProviderFactory::new(settings);
    let shared_http_client = default_factory.http_client();
    let provider_factory: Arc<dyn ProviderFactory> = Arc::new(default_factory);

    let startup_auth_ok = provider_factory
        .create_for_model(&settings.server.default_model)
        .await
        .is_ok();
    if startup_auth_ok {
        tracing::info!(
            provider = settings.server.default_provider.as_str(),
            model = settings.server.default_model.as_str(),
            "auth available for default model"
        );
    } else {
        tracing::warn!("no auth found at startup — sign in via Settings > Providers");
    }

    (provider_factory, shared_http_client)
}

/// Build the runtime context that holds shared state for domain functions.
fn build_server_runtime_context(
    services: ServiceState,
    engine_host: crate::engine::EngineHostHandle,
    settings_path: PathBuf,
    profile_runtime: Arc<crate::domains::agent::r#loop::ProfileRuntime>,
    origin: String,
) -> ServerRuntimeContext {
    ServerRuntimeContext {
        orchestrator: services.orchestrator.clone(),
        session_manager: services.session_manager.clone(),
        event_store: services.event_store.clone(),
        engine_host,
        settings_path,
        profile_runtime,
        agent_deps: services.agent_deps,
        server_start_time: std::time::Instant::now(),
        health_tracker: Arc::new(crate::domains::model::providers::ProviderHealthTracker::new()),
        shutdown_coordinator: None,
        origin,
        auth_path: auth_path(),
        oauth_flows: Arc::new(tokio::sync::Mutex::new(std::collections::HashMap::new())),
        // Provisional defaults; `TronServer::new` overwrites both with the
        // actual `ServerConfig::port` and the canonical onboarded marker path
        // so handlers see the live values from the start of the first request.
        ws_port: Arc::new(std::sync::atomic::AtomicU16::new(0)),
        onboarded_marker_path: crate::app::lifecycle::onboarding::onboarded_marker_path(),
    }
}

/// TTL for idle session cache eviction. Sessions idle beyond this are
/// dropped from the in-memory cache by the background eviction task.
const IDLE_SESSION_CACHE_TTL: std::time::Duration = std::time::Duration::from_secs(3600);

/// Spawn background maintenance tasks for primitive server state.
///
/// INVARIANT: ordinary startup must not touch macOS TCC permissions. The
/// Mac onboarding wrapper owns that UX after the install heartbeat, and a
/// daemon-side startup probe can surface permission prompts while the user is
/// still on the install step.
fn spawn_background_tasks(session_manager: &Arc<SessionManager>, server: &TronServer) {
    // Periodic session cache eviction (prevents unbounded memory growth)
    let eviction_mgr = session_manager.clone();
    let eviction_shutdown = server.shutdown().token();
    let cache_ttl = IDLE_SESSION_CACHE_TTL;
    let eviction_task = tokio::spawn(async move {
        let mut interval = tokio::time::interval(std::time::Duration::from_secs(60));
        let _ = interval.tick().await; // first tick is immediate, skip it
        loop {
            tokio::select! {
                _ = interval.tick() => {
                    let evicted = eviction_mgr.evict_idle_sessions(cache_ttl);
                    if evicted > 0 {
                        tracing::debug!(evicted, "session cache eviction sweep");
                    }
                }
                () = eviction_shutdown.cancelled() => break,
            }
        }
    });
    server.shutdown().register_task(eviction_task);
}

pub(crate) async fn run_server(args: Cli) -> Result<()> {
    // Phase 1: Pre-database filesystem operations
    init_directories()?;
    let bearer_token_path = crate::app::lifecycle::onboarding::bearer_token_path();
    let _bearer_token = initialize_bearer_token_at(&bearer_token_path)?;

    // Phase 2: Database and logging
    // _db_lock is bound for the lifetime of main(); dropping it releases the
    // process-level lock on the event-store DB. Keep in scope explicitly so
    // compilation fails if it's ever moved out without an equivalent guard.
    let (pool, db_path, _db_lock) = init_database(args.db_path)?;
    let profile_runtime = Arc::new(
        crate::domains::agent::r#loop::ProfileRuntime::load(
            crate::shared::foundation::paths::tron_home(),
        )
        .context("Failed to load active profile runtime")?,
    );
    let settings_path = crate::domains::settings::loader::settings_path();
    let settings = profile_runtime.current().settings.clone();
    crate::domains::settings::init_settings(settings.clone());
    let origin = format!("localhost:{}", args.port);
    let (log_handle, flush_task) =
        init_logging(&db_path, &settings, args.log_level.as_deref(), !args.quiet)?;
    if settings.storage.retention_enabled {
        match crate::shared::storage::StorageRuntime::new(db_path.clone())
            .retention_run(false, settings.observability.verbose_retention_days)
        {
            Ok(report) => tracing::debug!(
                rows_deleted = report.rows_deleted,
                blobs_deleted = report.blobs_deleted,
                verbose_retention_days = report.verbose_retention_days,
                "storage retention completed on startup"
            ),
            Err(error) => tracing::warn!(error = %error, "storage retention failed on startup"),
        }
    }
    if settings.storage.max_database_mb > 0 {
        match crate::shared::storage::StorageRuntime::new(db_path.clone()).enforce_size_budget(
            settings.storage.max_database_mb,
            settings.observability.verbose_retention_days,
        ) {
            Ok(report) if report.over_limit => tracing::warn!(
                max_database_bytes = report.max_database_bytes,
                before_total_bytes = report.before_total_bytes,
                after_total_bytes = report.after_total_bytes,
                retention_rows_deleted = report
                    .retention
                    .as_ref()
                    .map(|retention| retention.rows_deleted)
                    .unwrap_or_default(),
                retention_blobs_deleted = report
                    .retention
                    .as_ref()
                    .map(|retention| retention.blobs_deleted)
                    .unwrap_or_default(),
                "storage soft size budget exceeded; safe retention and checkpoint completed"
            ),
            Ok(_) => {}
            Err(error) => tracing::warn!(
                error = %error,
                max_database_mb = settings.storage.max_database_mb,
                "storage soft size budget check failed"
            ),
        }
    }
    let event_store = Arc::new(EventStore::new(pool));
    let engine_host = init_engine_host(&db_path)?;

    // Phase 3: Core services (orchestrator, providers, primitive agent deps)
    let services = init_services(event_store, &settings).await?;

    // Phase 4: Runtime context
    let session_manager_for_startup = services.session_manager.clone();
    let orchestrator_for_stream_events = services.orchestrator.clone();
    let profile_runtime_for_watcher = profile_runtime.clone();
    let runtime_context = build_server_runtime_context(
        services,
        engine_host,
        settings_path,
        profile_runtime,
        origin.clone(),
    );

    // Phase 5: Build and start server
    let bind_host_label = args.host.clone();
    let config = ServerConfig::from_settings(args.host, args.port, &settings.server);
    let metrics_handle = crate::app::health::metrics::install_recorder();
    let server = TronServer::new(config, runtime_context, metrics_handle);
    crate::transport::runtime::setup::register_server_domains_for_context(server.runtime_context())
        .context("Failed to register server domain workers")?;
    register_blocking_supervisor_shutdown(server.shutdown());

    // Stream pump: orchestrator events -> engine streams.
    let pump = EngineStreamEventPump::new(
        orchestrator_for_stream_events.subscribe(),
        server.runtime_context().engine_host.clone(),
        server.shutdown().token(),
        orchestrator_for_stream_events.turn_accumulators().clone(),
    );
    let stream_event_pump_handle = tokio::spawn(pump.run());
    crate::transport::runtime::EngineRuntimeServices::start(&server);

    // Phase 6: Background tasks and bind
    spawn_background_tasks(&session_manager_for_startup, &server);
    server
        .shutdown()
        .register_task(profile_runtime_for_watcher.spawn_watcher(server.shutdown().token()));
    let (addr, server_handle) = server.listen().await.context("Failed to bind server")?;
    tracing::info!("{}", format_listening_log(&addr, &bind_host_label));

    // Wait for shutdown signal
    tracing::debug!(
        signals = ?shutdown_signal_names(),
        "waiting for shutdown signal"
    );
    let shutdown_signal = wait_for_shutdown_signal().await?;

    tracing::info!(signal = shutdown_signal, "Shutting down...");
    let shutdown_handles: Vec<tokio::task::JoinHandle<()>> =
        vec![server_handle, stream_event_pump_handle];
    server
        .shutdown()
        .graceful_shutdown(shutdown_handles, None)
        .await;

    // Flush remaining logs to SQLite and stop the periodic flush task
    flush_task.abort();
    log_handle.flush();
    match crate::shared::storage::StorageRuntime::new(db_path.clone()).checkpoint() {
        Ok(report) => tracing::debug!(
            wal_bytes = report.wal_bytes,
            checkpointed_pages = report.checkpointed_pages,
            "storage checkpoint completed on shutdown"
        ),
        Err(error) => tracing::warn!(error = %error, "storage checkpoint failed on shutdown"),
    }

    tracing::info!("Shutdown complete");
    Ok(())
}

#[cfg(test)]
mod tests;
