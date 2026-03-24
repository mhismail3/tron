//! # tron
//!
//! Tron agent server binary — wires together all modules and starts the
//! HTTP/WebSocket server.
//!
//! ## Module Architecture
//!
//! ```text
//! tron::core          Foundation types, errors, branded IDs, message model
//! tron::settings      Settings schema, layered loading, global singleton
//! tron::events        SQLite event store, migrations, session reconstruction
//! tron::llm           Provider trait, model registry, SSE streaming, auth
//! tron::tools         Tool trait, registry, filesystem/bash/web/subagent tools
//! tron::skills        SKILL.md parser, registry, context injection
//! tron::transcription Transcription (parakeet-tdt-0.6b via MLX sidecar)
//! tron::runtime       Agent loop, context/compaction, hooks, orchestrator, tasks
//! tron::server        Axum HTTP/WS, RPC handlers, event bridge, APNS
//! ```
//!
//! ## Data Path
//!
//! 1. Client sends JSON-RPC over WebSocket
//! 2. `server` dispatches to RPC handlers
//! 3. Handlers call runtime/orchestrator/event store
//! 4. iOS compatibility adapted at boundary (`rpc/adapters.rs`)
//! 5. Events broadcast back through WebSocket channels
//!
//! ## Core Invariants
//!
//! 1. Canonical internal model per concept; iOS adaptation is boundary-only
//! 2. Unknown model/provider → fail-fast typed error (no fallback)
//! 3. Event reconstruction is deterministic from persisted events
//! 4. Session writes are serialized per-session via in-process locks
//! 5. `agent.ready` is emitted AFTER `agent.complete` (iOS send button)
//! 6. Compaction always runs before ledger writing (deterministic DB ordering)
//! 7. Production DB target is strictly `~/.tron/system/db/log.db`

#[global_allocator]
static GLOBAL: mimalloc::MiMalloc = mimalloc::MiMalloc;

use std::path::PathBuf;
use std::sync::Arc;

use anyhow::{Context, Result};
use clap::Parser;
use parking_lot::RwLock;
use tron::settings::db_path_policy::resolve_production_db_path;
use tron::llm::factory as provider_factory;
use tron::events::{ConnectionConfig, EventStore};
use tron::llm::provider::ProviderFactory;
use tron::runtime::orchestrator::orchestrator::Orchestrator;
use tron::runtime::orchestrator::session_manager::SessionManager;
use tron::runtime::orchestrator::subagent_manager::SubagentManager;
use tron::server::config::ServerConfig;
use tron::server::rpc::context::{AgentDeps, RpcContext};
use tron::server::rpc::registry::MethodRegistry;
use tron::server::server::TronServer;
use tron::server::websocket::event_bridge::EventBridge;
use tron::skills::registry::SkillRegistry;
use tron::tools::registry::ToolRegistry;

#[cfg(feature = "apns")]
type ApnsServiceOption = Option<Arc<tron::server::platform::apns::ApnsService>>;
#[cfg(not(feature = "apns"))]
type ApnsServiceOption = Option<()>;

/// Tron agent — server and CLI tools.
#[derive(Parser, Debug)]
#[command(name = "tron", about = "Tron agent server and tools")]
struct Cli {
    #[command(subcommand)]
    command: Option<Command>,

    /// Host to bind (server mode).
    #[arg(long, default_value = "0.0.0.0", global = true)]
    host: String,

    /// Port to bind (server mode, 0 for auto-assign).
    #[arg(long, default_value = "9847", global = true)]
    port: u16,

    /// Path to the `SQLite` database (events + tasks in one file).
    #[arg(long, global = true)]
    db_path: Option<PathBuf>,

    /// Maximum concurrent sessions (overrides settings if specified).
    #[arg(long, global = true)]
    max_sessions: Option<usize>,

    /// Override database log level (trace, debug, info, warn, error).
    #[arg(long, global = true)]
    log_level: Option<String>,
}

#[derive(clap::Subcommand, Debug)]
enum Command {}

fn ensure_parent_dir(path: &std::path::Path) -> Result<()> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)
            .with_context(|| format!("Failed to create directory: {}", parent.display()))?;
    }
    Ok(())
}

/// Resolve the auth file path (`~/.tron/system/auth.json`).
fn auth_path() -> PathBuf {
    tron::settings::loader::auth_path()
}


/// Configuration for tool registry creation.
///
/// Captures shared resources (event store, API keys) so the
/// tool factory closure can create real provider implementations.
struct ToolRegistryConfig {
    event_store: Arc<tron::events::EventStore>,
    brave_api_key: Option<String>,
    #[cfg_attr(not(feature = "apns"), allow(dead_code))]
    apns_service: ApnsServiceOption,
    /// Shared HTTP client (connection pool reused across tools).
    http_client: reqwest::Client,
}

/// Create a populated tool registry with built-in tools.
///
/// Called once per agent run to create a fresh registry. Registration matches
/// the TypeScript server:
/// - Tools with real backends use real providers
/// - NotifyApp: conditionally registered (only with APNS backend)
/// - Subagent tools: NOT registered (stubs return "not available", confusing LLM)
fn create_tool_registry(config: &ToolRegistryConfig) -> ToolRegistry {
    use tron::tools::backends::{
        RealFileSystem, ReqwestHttpClient,
        StubNotifyDelegate, TokioProcessRunner,
    };

    let fs: Arc<dyn tron::tools::traits::FileSystemOps> = Arc::new(RealFileSystem);
    let runner: Arc<dyn tron::tools::traits::ProcessRunner> = Arc::new(TokioProcessRunner);
    let http: Arc<dyn tron::tools::traits::HttpClient> =
        Arc::new(ReqwestHttpClient::from_client(config.http_client.clone()));

    let mut registry = ToolRegistry::new();

    // 1–3: Filesystem tools
    registry.register(Arc::new(tron::tools::fs::read::ReadTool::new(fs.clone())));
    registry.register(Arc::new(tron::tools::fs::write::WriteTool::new(fs.clone())));
    registry.register(Arc::new(tron::tools::fs::edit::EditTool::new(fs.clone())));

    // 4: Bash (with blob store for large output storage)
    let blob_store: Arc<dyn tron::tools::traits::BlobStore> = config.event_store.clone();
    registry.register(Arc::new(tron::tools::system::bash::BashTool::new(
        runner.clone(),
        Some(blob_store),
    )));

    // 5: Search
    registry.register(Arc::new(tron::tools::search::search_tool::SearchTool::new(
        runner,
    )));

    // 6: Find
    registry.register(Arc::new(tron::tools::fs::find::FindTool::new()));

    // 7: AskUserQuestion
    registry.register(Arc::new(
        tron::tools::ui::ask_user::AskUserQuestionTool::new(),
    ));

    // 8: GetConfirmation
    registry.register(Arc::new(
        tron::tools::ui::get_confirmation::GetConfirmationTool::new(),
    ));

    // 9: NotifyApp — real APNS when available, stub fallback
    let notify_delegate: Arc<dyn tron::tools::traits::NotifyDelegate> = {
        #[cfg(feature = "apns")]
        if let Some(ref apns) = config.apns_service {
            Arc::new(tron::server::platform::apns::delegate::ApnsNotifyDelegate::new(
                apns.clone(),
                config.event_store.pool().clone(),
            ))
        } else {
            Arc::new(StubNotifyDelegate)
        }
        #[cfg(not(feature = "apns"))]
        { Arc::new(StubNotifyDelegate) }
    };
    registry.register(Arc::new(tron::tools::ui::notify::NotifyAppTool::new(
        notify_delegate,
    )));

    // 9: WebFetch (always available)
    registry.register(Arc::new(tron::tools::web::web_fetch::WebFetchTool::new(
        http.clone(),
    )));

    // 10: WebSearch — conditional on Brave API key
    if let Some(ref api_key) = config.brave_api_key {
        registry.register(Arc::new(tron::tools::web::web_search::WebSearchTool::new(
            http,
            api_key.clone(),
        )));
    }

    // Subagent tools: registered separately via SubagentManager (see main)

    tracing::debug!(tool_count = registry.len(), tools = ?registry.names(), "tool registry created");
    registry
}

#[tokio::main]
#[allow(clippy::too_many_lines)]
async fn main() -> Result<()> {
    let args = Cli::parse();

    // Dispatch subcommands before server startup.
    if let Some(_cmd) = args.command {
        // Reserved for future subcommands.
    }

    // INVARIANT: Deploy crash-loop protection runs FIRST (pure filesystem, no dependencies).
    // If the previous deploy crashed the process before self-test could run, this catches it
    // after MAX_DEPLOY_STARTUP_ATTEMPTS and auto-rolls back to the backup binary.
    {
        const MAX_DEPLOY_STARTUP_ATTEMPTS: u32 = 3;
        let deploy_dir = tron::settings::deploy_dir();
        let sentinel = tron::server::deploy::read_sentinel(&deploy_dir);

        if let Some(ref s) = sentinel
            && s.status == "restarting"
        {
            let attempts_path = deploy_dir.join("startup-attempts");
            let attempt = std::fs::read_to_string(&attempts_path)
                .ok()
                .and_then(|s| s.trim().parse::<u32>().ok())
                .unwrap_or(0);

            if attempt >= MAX_DEPLOY_STARTUP_ATTEMPTS {
                eprintln!(
                    "DEPLOY SAFETY: {MAX_DEPLOY_STARTUP_ATTEMPTS} startup attempts exceeded, auto-rolling back"
                );
                let binary_path = tron::settings::tron_home_dir().join("tron");
                tron::server::deploy::auto_rollback(
                    &deploy_dir,
                    &binary_path,
                    &format!("exceeded {MAX_DEPLOY_STARTUP_ATTEMPTS} startup attempts"),
                );
                // auto_rollback never returns
            }

            let _ = std::fs::create_dir_all(&deploy_dir);
            let _ = std::fs::write(&attempts_path, (attempt + 1).to_string());
        }
    }

    // Ensure ~/.tron/ directory structure exists
    {
        let tron_home = tron::settings::tron_home_dir();
        let system = tron_home.join("system");
        for subdir in &["bin", "db", "deployment", "scratch"] {
            let _ = std::fs::create_dir_all(system.join(subdir));
        }
        for subdir in &["sessions", "knowledge", "cron"] {
            let _ = std::fs::create_dir_all(tron_home.join("memory").join(subdir));
        }
        let _ = std::fs::create_dir_all(tron_home.join("user").join("voice"));
        let _ = std::fs::create_dir_all(tron_home.join("memory").join("skills"));
        let _ = std::fs::create_dir_all(tron_home.join("memory").join("rules"));
    }

    // Database (events + tasks share one SQLite file) — set up before logging
    // so that tracing events are persisted from the start.
    let db_path = resolve_production_db_path(args.db_path)?;
    ensure_parent_dir(&db_path)?;
    let db_str = db_path.to_string_lossy();
    let pool = tron::events::new_file(&db_str, &ConnectionConfig::default())
        .context("Failed to open database")?;
    {
        let conn = pool.get().context("Failed to get DB connection")?;
        let _ = tron::events::run_migrations(&conn).context("Failed to run migrations")?;
    }

    // Load settings early (needed for log level before logging init)
    let settings_path = tron::settings::loader::settings_path();
    let settings =
        tron::settings::loader::load_settings_from_path(&settings_path).unwrap_or_default();

    // Initialize logging with SQLite persistence (dedicated connection, separate from pool).
    // Must set WAL + busy_timeout to match pool connections — without busy_timeout,
    // concurrent writes from the pool cause immediate SQLITE_BUSY errors.
    let log_conn =
        rusqlite::Connection::open(&db_path).context("Failed to open logging DB connection")?;
    log_conn
        .execute_batch("PRAGMA journal_mode = WAL; PRAGMA busy_timeout = 5000;")
        .context("Failed to set logging connection pragmas")?;
    let origin = format!("localhost:{}", args.port);
    let module_overrides: Vec<(String, &str)> = settings
        .logging
        .module_overrides
        .iter()
        .map(|(m, lvl)| (m.clone(), lvl.as_filter_str()))
        .collect();
    let effective_log_level = args
        .log_level
        .as_deref()
        .unwrap_or_else(|| settings.logging.db_log_level.as_filter_str());
    let log_handle = tron::core::logging::init_subscriber_with_sqlite(
        effective_log_level,
        &module_overrides,
        log_conn,
        Some(origin.clone()),
    );
    let flush_task = tron::core::logging::spawn_flush_task(log_handle.clone());
    let event_store = Arc::new(EventStore::new(pool));

    // Core services
    let max_sessions = args
        .max_sessions
        .unwrap_or(settings.server.max_concurrent_sessions);
    let session_manager =
        Arc::new(SessionManager::new(event_store.clone()).with_origin(origin.clone()));
    let orchestrator = Arc::new(Orchestrator::new(session_manager.clone(), max_sessions));
    let skill_registry = Arc::new(RwLock::new(SkillRegistry::new()));

    // Load Brave API key for web search (matches TS server conditional registration)
    let brave_api_key = tron::llm::auth::storage::get_service_api_keys(&auth_path(), "brave")
        .into_iter()
        .next();
    if brave_api_key.is_some() {
        tracing::info!("Brave API key loaded — WebSearch tool enabled");
    }

    // APNS service (optional — only if config exists at ~/.tron/system/mods/apns/)
    let apns_service: ApnsServiceOption = {
        #[cfg(feature = "apns")]
        {
            let svc = tron::server::platform::apns::load_apns_config().and_then(|apns_config| {
                match tron::server::platform::apns::ApnsService::new(apns_config) {
                    Ok(svc) => {
                        tracing::info!("APNS service initialized — push notifications enabled");
                        Some(Arc::new(svc))
                    }
                    Err(e) => {
                        tracing::warn!(error = %e, "APNS init failed — push notifications disabled");
                        None
                    }
                }
            });
            if svc.is_none() {
                tracing::info!("No APNS config — push notifications disabled");
            }
            svc
        }
        #[cfg(not(feature = "apns"))]
        { None }
    };

    // Agent dependencies (provider factory + tool factory)
    // The factory creates a fresh provider per request by detecting the provider
    // type from the model ID and loading auth from disk. This means model switches
    // take effect immediately — no server restart needed.
    let default_factory = provider_factory::DefaultProviderFactory::new(&settings);
    let shared_http_client = default_factory.http_client();
    let provider_factory: Arc<dyn ProviderFactory> = Arc::new(default_factory);

    // Clone before move into ToolRegistryConfig
    #[cfg(feature = "apns")]
    let apns_for_deploy = apns_service.clone();

    // Tool registry config (shared resources for per-session tool factories)
    let tool_config = Arc::new(ToolRegistryConfig {
        event_store: event_store.clone(),
        brave_api_key,
        apns_service,
        http_client: shared_http_client,
    });

    // Check auth availability at startup (informational only — auth can be configured later).
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
        tracing::warn!(
            "no auth found at startup — sign in via Settings > Providers"
        );
    }

    // Deferred cron scheduler reference for tool factory (set after CronScheduler creation)
    let cron_scheduler_cell: Arc<std::sync::OnceLock<Arc<tron::cron::CronScheduler>>> =
        Arc::new(std::sync::OnceLock::new());

    // Always create agent deps — ProviderFactory reads auth from disk on each call,
    // so auth configured after startup (e.g. via OAuth) is picked up automatically.
    let subagent_manager = Arc::new(SubagentManager::new(
        session_manager.clone(),
        event_store.clone(),
        orchestrator.broadcast().clone(),
        provider_factory.clone(),
        None,
        None,
    ));
    subagent_manager.set_self_ref();

    // Build tool factory that includes subagent tools + summarizer-backed WebFetch
    let config = tool_config.clone();
    let spawner: Arc<dyn tron::tools::traits::SubagentSpawner> = subagent_manager.clone();
    let sm_for_summarizer = subagent_manager.clone();
    let tool_factory: Arc<dyn Fn() -> ToolRegistry + Send + Sync> = Arc::new(move || {
        let mut registry = create_tool_registry(&config);
        registry.register(Arc::new(
            tron::tools::subagent::spawn::SpawnSubagentTool::new(spawner.clone()),
        ));
        registry.register(Arc::new(
            tron::tools::subagent::wait::WaitForAgentsTool::new(spawner.clone()),
        ));

        // Re-register WebFetch with LLM summarizer (overrides the basic version)
        let summarizer: Arc<dyn tron::tools::traits::ContentSummarizer> = Arc::new(
            tron::runtime::agent::compaction_handler::SubagentContentSummarizer {
                manager: sm_for_summarizer.clone(),
            },
        );
        let http: Arc<dyn tron::tools::traits::HttpClient> = Arc::new(
            tron::tools::backends::ReqwestHttpClient::from_client(config.http_client.clone()),
        );
        registry.register(Arc::new(
            tron::tools::web::web_fetch::WebFetchTool::new_with_summarizer(http, summarizer),
        ));

        registry
    });

    // Break circular dep: SubagentManager needs tool_factory to spawn children
    subagent_manager.set_tool_factory(tool_factory.clone());

    let agent_deps = Some(AgentDeps {
        provider_factory,
        tool_factory,
        guardrails: None,
        hooks: None,
    });
    let shared_subagent_manager = Some(subagent_manager) as Option<Arc<SubagentManager>>;

    // Transcription sidecar (parakeet-mlx via Python worker)
    let transcription_engine = Arc::new(std::sync::OnceLock::new());
    {
        let cell = Arc::clone(&transcription_engine);
        #[allow(clippy::let_underscore_future)]
        let _ = tokio::spawn(async move {
            match tron::transcription::MlxEngine::new().await {
                Ok(engine) => {
                    let _ = cell.set(engine);
                    tracing::info!("transcription sidecar ready (parakeet-mlx)");
                }
                Err(e) => {
                    tracing::warn!(error = %e, "transcription sidecar setup failed");
                }
            }
        });
    }

    // Cron scheduler
    let cron_cancel = tokio_util::sync::CancellationToken::new();
    let cron_config_path = tron::settings::tron_home_dir()
        .join("memory")
        .join("automations.json");
    let cron_backup_path = tron::settings::deploy_dir().join("automations.json.bak");

    let cron_agent_executor = agent_deps.as_ref().map(|deps| {
        Arc::new(tron::cron::impls::CronAgentTurnExecutor::new(
            event_store.clone(),
            session_manager.clone(),
            deps.provider_factory.clone(),
            deps.tool_factory.clone(),
            origin.clone(),
            shared_subagent_manager.clone(),
        )) as _
    });
    let cron_deps = tron::cron::ExecutorDeps {
        agent_executor: cron_agent_executor,
        broadcaster: std::sync::OnceLock::new(), // set after TronServer creation
        push_notifier: {
            #[cfg(feature = "apns")]
            { tool_config.apns_service.as_ref().map(|apns| {
                Arc::new(tron::cron::impls::CronPushNotifier::new(
                    apns.clone(),
                    event_store.pool().clone(),
                )) as _
            }) }
            #[cfg(not(feature = "apns"))]
            { None }
        },
        event_injector: Some(
            Arc::new(tron::cron::impls::CronSystemEventInjector::new(event_store.clone())) as _,
        ),
        http_client: tool_config.http_client.clone(),
        pool: event_store.pool().clone(),
    };
    let cron_scheduler = Arc::new(tron::cron::CronScheduler::new(
        event_store.pool().clone(),
        Arc::new(tron::cron::SystemClock),
        cron_deps,
        cron_config_path,
        cron_backup_path,
        cron_cancel.clone(),
    ));

    // Wire cron scheduler into tool factory (breaks circular dep via OnceLock)
    let _ = cron_scheduler_cell.set(cron_scheduler.clone());

    // Worktree coordinator (with broadcast sender for real-time WebSocket events)
    let worktree_coordinator = {
        let wt_config = tron::worktree::WorktreeConfig::from_settings(&settings.session);
        let coord = Arc::new(tron::worktree::WorktreeCoordinator::with_broadcast(
            wt_config,
            event_store.clone(),
            orchestrator.broadcast().sender(),
        ));
        // Rebuild active worktrees from persisted events, then recover orphans.
        coord.rebuild_from_events();
        let coord_for_recovery = coord.clone();
        #[allow(clippy::let_underscore_future)]
        let _ = tokio::spawn(async move {
            let count = coord_for_recovery.recover_orphans().await;
            if count > 0 {
                tracing::info!(count, "recovered orphaned worktrees");
            }
        });
        // Wire coordinator into SessionManager (for end_session release)
        session_manager.set_worktree_coordinator(coord.clone());
        // Wire coordinator into SubagentManager (for subagent isolation)
        if let Some(ref sm) = shared_subagent_manager {
            sm.set_worktree_coordinator(coord.clone());
        }
        Some(coord)
    };

    // RPC context
    let session_manager_for_startup = session_manager.clone();
    let settings_path_for_selftest = settings_path.clone();
    #[cfg(feature = "apns")]
    let pool_for_deploy = event_store.pool().clone();
    let rpc_context = RpcContext {
        orchestrator: orchestrator.clone(),
        session_manager,
        event_store,
        skill_registry,
        settings_path,
        agent_deps,
        server_start_time: std::time::Instant::now(),
        transcription_engine,
        subagent_manager: shared_subagent_manager,
        health_tracker: Arc::new(tron::llm::ProviderHealthTracker::new()),
        shutdown_coordinator: None, // set by TronServer after creation
        origin: origin.clone(),
        cron_scheduler: Some(cron_scheduler.clone()),
        worktree_coordinator,
        device_request_broker: None, // set after TronServer creation (needs broadcast)
        context_artifacts: Arc::new(
            tron::server::rpc::session_context::ContextArtifactsService::new(),
        ),
        auth_path: auth_path(),
        broadcast_manager: None, // set by TronServer after creation
        oauth_flows: Arc::new(tokio::sync::Mutex::new(std::collections::HashMap::new())),
    };

    // Method registry
    let mut registry = MethodRegistry::new();
    tron::server::rpc::handlers::register_all(&mut registry);
    let method_count = registry.methods().len();

    // Server config
    let config = ServerConfig {
        host: args.host,
        port: args.port,
        ..ServerConfig::default()
    };

    // Install Prometheus metrics recorder (must be before any metrics are recorded)
    let metrics_handle = tron::server::metrics::install_recorder();

    // Build and start server
    let server = TronServer::new(config, registry, rpc_context, metrics_handle);

    // Event bridge: orchestrator events → WebSocket clients
    let bridge = EventBridge::new(
        orchestrator.subscribe(),
        server.broadcast().clone(),
        server.shutdown().token(),
        orchestrator.turn_accumulators().clone(),
    );
    let bridge_handle = tokio::spawn(bridge.run());

    // Wire cron broadcaster (needs BroadcastManager from server)
    cron_scheduler.set_broadcaster(Arc::new(tron::cron::impls::CronEventBroadcaster::new(
        server.broadcast().clone(),
    )));

    // Forward server shutdown to cron scheduler
    {
        let cron_cancel = cron_cancel.clone();
        let shutdown_token = server.shutdown().token();
        #[allow(clippy::let_underscore_future)]
        let _ = tokio::spawn(async move {
            shutdown_token.cancelled().await;
            cron_cancel.cancel();
        });
    }

    // Start cron scheduler (scheduler loop + config file watcher)
    let (cron_sched_handle, cron_watcher_handle) = cron_scheduler.clone().start();

    // Post-deploy self-test (after DB/settings/APNS init, before port binding).
    // If self-test fails, auto-rollback to backup binary immediately.
    {
        let deploy_dir = tron::settings::deploy_dir();
        if let Some(sentinel) = tron::server::deploy::read_sentinel(&deploy_dir)
            && sentinel.status == "restarting"
        {
            let auth = auth_path();
            let binary_path = tron::settings::tron_home_dir().join("tron");
            let test_result = tron::server::deploy::run_self_test(
                &db_path,
                &settings_path_for_selftest,
                &auth,
                &binary_path,
            );

            if !test_result.passed {
                let failed: Vec<&str> = test_result
                    .checks
                    .iter()
                    .filter(|c| !c.passed)
                    .map(|c| c.name.as_str())
                    .collect();
                let reason = format!("self-test failed: {}", failed.join(", "));
                eprintln!("DEPLOY SAFETY: {reason}");
                tron::server::deploy::auto_rollback(&deploy_dir, &binary_path, &reason);
                // auto_rollback never returns
            }

            tracing::info!(
                checks = test_result.checks.len(),
                "post-deploy self-test passed"
            );

            // Clear attempt counter — self-test passed
            let _ = std::fs::remove_file(deploy_dir.join("startup-attempts"));

            // Store self-test result in sentinel for audit
            if let Some(mut s) = tron::server::deploy::read_sentinel(&deploy_dir) {
                s.self_test = Some(test_result);
                let _ = tron::server::deploy::write_sentinel(&deploy_dir, &s);
            }
        }
    }

    let (addr, server_handle) = server.listen().await.context("Failed to bind server")?;

    tracing::info!("Tron agent listening on http://{addr} ({method_count} RPC methods registered)");

    // Auto-create the default chat session if enabled
    if settings.session.chat.enabled {
        match session_manager_for_startup.get_or_create_chat_session(
            &settings.server.default_model,
            &settings.session.chat.working_directory,
        ) {
            Ok((id, true)) => tracing::info!(session_id = %id, "default chat session created"),
            Ok((_, false)) => tracing::debug!("default chat session already exists"),
            Err(e) => tracing::warn!(error = %e, "failed to create default chat session"),
        }
    }

    // Post-deploy sentinel processing
    {
        let deploy_dir = tron::settings::deploy_dir();
        match tron::server::deploy::complete_sentinel(&deploy_dir) {
            Ok(Some(sentinel)) => {
                tracing::info!(
                    commit = sentinel.commit.as_str(),
                    previous = sentinel.previous_commit.as_str(),
                    "post-deploy restart completed successfully"
                );
                if let Err(e) = tron::server::deploy::write_last_deployment(&deploy_dir, &sentinel) {
                    tracing::warn!(error = %e, "failed to write last-deployment.json");
                }

                // Send APNS push notification for successful deploy
                #[cfg(feature = "apns")]
                if let Some(ref apns) = apns_for_deploy {
                    let short_commit = &sentinel.commit[..7.min(sentinel.commit.len())];
                    let commit_subject =
                        tron::server::deploy::resolve_workspace_root().and_then(|root| {
                            std::process::Command::new("git")
                                .args(["log", "-1", "--format=%s", &sentinel.commit])
                                .current_dir(root)
                                .output()
                                .ok()
                                .and_then(|o| {
                                    if o.status.success() {
                                        String::from_utf8(o.stdout)
                                            .ok()
                                            .map(|s| s.trim().to_string())
                                            .filter(|s| !s.is_empty())
                                    } else {
                                        None
                                    }
                                })
                        });
                    let body = match commit_subject {
                        Some(subject) => format!("{short_commit}: {subject}"),
                        None => format!("Tron updated to {short_commit}"),
                    };
                    let tokens: Vec<String> = pool_for_deploy
                        .get()
                        .ok()
                        .and_then(|conn| {
                            conn.prepare(
                                "SELECT device_token FROM device_tokens WHERE is_active = 1",
                            )
                            .ok()
                            .and_then(|mut stmt| {
                                stmt.query_map([], |row| row.get::<_, String>(0))
                                    .ok()
                                    .map(|rows| rows.filter_map(Result::ok).collect())
                            })
                        })
                        .unwrap_or_default();
                    if !tokens.is_empty() {
                        let notification = tron::server::platform::apns::ApnsNotification {
                            title: "Deploy Complete".into(),
                            body,
                            data: std::collections::HashMap::from([
                                ("type".into(), "deploy.completed".into()),
                                ("commit".into(), sentinel.commit.clone()),
                            ]),
                            priority: "high".into(),
                            sound: None,
                            badge: None,
                            thread_id: None,
                        };
                        let apns = apns.clone();
                        drop(tokio::spawn(async move {
                            let _ = apns.send_to_many(&tokens, &notification).await;
                        }));
                    }
                }
            }
            Ok(None) => {}
            Err(e) => tracing::warn!(error = %e, "failed to process restart sentinel"),
        }

        // Send pending rollback notification (written by auto_rollback on previous startup)
        let pending_path = deploy_dir.join("deploy-notification-pending.json");
        if pending_path.exists() {
            #[cfg(feature = "apns")]
            if let Some(ref apns) = apns_for_deploy
                && let Ok(content) = std::fs::read_to_string(&pending_path)
                && let Ok(data) = serde_json::from_str::<serde_json::Value>(&content)
            {
                let tokens: Vec<String> = pool_for_deploy
                    .get()
                    .ok()
                    .and_then(|conn| {
                        conn.prepare("SELECT device_token FROM device_tokens WHERE is_active = 1")
                            .ok()
                            .and_then(|mut stmt| {
                                stmt.query_map([], |row| row.get::<_, String>(0))
                                    .ok()
                                    .map(|rows| rows.filter_map(Result::ok).collect())
                            })
                    })
                    .unwrap_or_default();
                if !tokens.is_empty() {
                    let ntype = data["type"].as_str().unwrap_or("deploy.rolled_back");
                    let reason = data["reason"].as_str().unwrap_or("unknown");
                    let notification = tron::server::platform::apns::ApnsNotification {
                        title: "Deploy Rolled Back".into(),
                        body: format!("Tron restored: {reason}"),
                        data: std::collections::HashMap::from([
                            ("type".into(), ntype.into()),
                            (
                                "commit".into(),
                                data["commit"].as_str().unwrap_or("unknown").into(),
                            ),
                            ("reason".into(), reason.into()),
                        ]),
                        priority: "high".into(),
                        sound: None,
                        badge: None,
                        thread_id: None,
                    };
                    let apns = apns.clone();
                    drop(tokio::spawn(async move {
                        let _ = apns.send_to_many(&tokens, &notification).await;
                    }));
                }
            }
            let _ = std::fs::remove_file(&pending_path);
        }
    }

    // Wait for shutdown signal
    tokio::signal::ctrl_c()
        .await
        .context("Failed to listen for ctrl-c")?;

    tracing::info!("Shutting down...");

    // Collect tracked task handles for coordinated shutdown
    let shutdown_handles: Vec<tokio::task::JoinHandle<()>> = vec![
        server_handle,
        bridge_handle,
        cron_sched_handle,
        cron_watcher_handle,
    ];

    // Graceful shutdown with 30s timeout
    server
        .shutdown()
        .graceful_shutdown(shutdown_handles, None)
        .await;

    // Flush remaining logs to SQLite and stop the periodic flush task
    flush_task.abort();
    log_handle.flush();

    tracing::info!("Shutdown complete");
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use clap::Parser;
    use tron::settings::db_path_policy::{
        PRODUCTION_DB_FILENAME, default_production_db_path, production_db_dir_from_home,
        validate_production_db_path_for_home,
    };
    use tron::settings::TronSettings;

    /// Small pool size for tests — prevents FD exhaustion when many tests
    /// run in parallel, each opening a file-backed SQLite pool.
    fn test_db_config() -> ConnectionConfig {
        ConnectionConfig {
            pool_size: 2,
            ..ConnectionConfig::default()
        }
    }

    #[test]
    fn cli_default_host() {
        let cli = Cli::parse_from(["tron"]);
        assert_eq!(cli.host, "0.0.0.0");
    }

    #[test]
    fn cli_default_port() {
        let cli = Cli::parse_from(["tron"]);
        assert_eq!(cli.port, 9847);
    }

    #[test]
    fn cli_parses_log_level_flag() {
        let cli = Cli::parse_from(["tron", "--log-level", "debug"]);
        assert_eq!(cli.log_level.as_deref(), Some("debug"));
    }

    #[test]
    fn cli_log_level_is_optional() {
        let cli = Cli::parse_from(["tron"]);
        assert!(cli.log_level.is_none());
    }

    #[test]
    fn default_db_path_under_tron_dir() {
        let path = default_production_db_path();
        assert!(path.to_string_lossy().contains(".tron"));
        assert!(path.to_string_lossy().ends_with(PRODUCTION_DB_FILENAME));
    }

    #[test]
    fn ensure_parent_dir_creates_nested() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("a").join("b").join("test.db");
        ensure_parent_dir(&path).unwrap();
        assert!(path.parent().unwrap().exists());
    }

    #[tokio::test]
    async fn factory_unknown_model_returns_unsupported_model_error() {
        let settings = TronSettings::default();
        let factory = provider_factory::DefaultProviderFactory::new(&settings)
            .with_auth_path(PathBuf::from("/tmp/tron-test-no-such-auth.json"));
        let result = factory.create_for_model("unknown-model").await;
        assert!(matches!(
            result,
            Err(tron::llm::provider::ProviderError::UnsupportedModel { .. })
        ));
    }

    #[test]
    fn db_policy_accepts_expected_home_path() {
        let dir = tempfile::tempdir().unwrap();
        let home = dir.path().join("home");
        std::fs::create_dir_all(&home).unwrap();
        let db_path = production_db_dir_from_home(&home).join(PRODUCTION_DB_FILENAME);
        validate_production_db_path_for_home(&db_path, &home).unwrap();
    }

    #[test]
    fn db_policy_rejects_alternate_filename() {
        let dir = tempfile::tempdir().unwrap();
        let home = dir.path().join("home");
        std::fs::create_dir_all(&home).unwrap();
        let db_path = production_db_dir_from_home(&home).join("not-beta.db");
        let err = validate_production_db_path_for_home(&db_path, &home).unwrap_err();
        assert!(err.to_string().contains(PRODUCTION_DB_FILENAME));
    }

    #[test]
    fn db_policy_rejects_wrong_directory_without_creating_it() {
        let dir = tempfile::tempdir().unwrap();
        let home = dir.path().join("home");
        std::fs::create_dir_all(&home).unwrap();

        let bad_parent = home.join("other-db-dir");
        let bad_path = bad_parent.join(PRODUCTION_DB_FILENAME);
        assert!(!bad_parent.exists());

        let err = validate_production_db_path_for_home(&bad_path, &home).unwrap_err();
        assert!(err.to_string().contains("does not exist"));
        assert!(!bad_parent.exists());
    }

    #[cfg(unix)]
    #[test]
    fn db_policy_rejects_symlink_db_file() {
        use std::os::unix::fs::symlink;

        let dir = tempfile::tempdir().unwrap();
        let home = dir.path().join("home");
        std::fs::create_dir_all(&home).unwrap();

        let prod_dir = production_db_dir_from_home(&home);
        std::fs::create_dir_all(&prod_dir).unwrap();

        let target = dir.path().join("escape.db");
        std::fs::write(&target, "x").unwrap();
        let symlink_path = prod_dir.join(PRODUCTION_DB_FILENAME);
        symlink(&target, &symlink_path).unwrap();

        let err = validate_production_db_path_for_home(&symlink_path, &home).unwrap_err();
        assert!(err.to_string().contains("symlink"));
    }

    #[tokio::test]
    async fn openai_returns_none_without_auth() {
        // With no auth.json, OpenAI returns None
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("auth.json");
        let result = tron::llm::auth::openai::load_server_auth(&path)
            .await
            .unwrap();
        assert!(result.is_none());
    }

    #[tokio::test]
    async fn google_returns_none_without_auth() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("auth.json");
        let result = tron::llm::auth::google::load_server_auth(&path)
            .await
            .unwrap();
        assert!(result.is_none());
    }

    #[test]
    fn auth_path_under_tron_dir() {
        let path = auth_path();
        assert!(path.to_string_lossy().contains(".tron"));
        assert!(path.to_string_lossy().ends_with("auth.json"));
    }

    #[tokio::test]
    async fn create_anthropic_with_oauth_from_file() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("auth.json");

        // Save fresh OAuth tokens
        let tokens = tron::llm::auth::OAuthTokens {
            access_token: "sk-ant-oat-test".to_string(),
            refresh_token: "ref".to_string(),
            expires_at: tron::llm::auth::now_ms() + 3_600_000,
        };
        tron::llm::auth::storage::save_provider_oauth_tokens(&path, "anthropic", &tokens).unwrap();

        // load_server_auth should find the OAuth tokens
        let config = tron::llm::auth::anthropic::default_config();
        let result = tron::llm::auth::anthropic::load_server_auth(&path, &config, None)
            .await
            .unwrap();
        let auth = result.unwrap();
        assert!(auth.is_oauth());
        assert_eq!(auth.token(), "sk-ant-oat-test");
    }

    #[tokio::test]
    async fn create_anthropic_oauth_over_api_key() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("auth.json");

        // Save both OAuth and API key
        tron::llm::auth::storage::save_provider_api_key(&path, "anthropic", "sk-api-key").unwrap();
        let tokens = tron::llm::auth::OAuthTokens {
            access_token: "sk-ant-oat-primary".to_string(),
            refresh_token: "ref".to_string(),
            expires_at: tron::llm::auth::now_ms() + 3_600_000,
        };
        tron::llm::auth::storage::save_provider_oauth_tokens(&path, "anthropic", &tokens).unwrap();

        // OAuth takes priority
        let config = tron::llm::auth::anthropic::default_config();
        let result = tron::llm::auth::anthropic::load_server_auth(&path, &config, None)
            .await
            .unwrap();
        let auth = result.unwrap();
        assert!(auth.is_oauth());
        assert_eq!(auth.token(), "sk-ant-oat-primary");
    }

    #[tokio::test]
    async fn create_anthropic_multi_account_select() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("auth.json");

        // Save two accounts
        let work_tokens = tron::llm::auth::OAuthTokens {
            access_token: "work-tok".to_string(),
            refresh_token: "ref1".to_string(),
            expires_at: tron::llm::auth::now_ms() + 3_600_000,
        };
        let personal_tokens = tron::llm::auth::OAuthTokens {
            access_token: "personal-tok".to_string(),
            refresh_token: "ref2".to_string(),
            expires_at: tron::llm::auth::now_ms() + 3_600_000,
        };
        tron::llm::auth::storage::save_account_oauth_tokens(
            &path,
            "anthropic",
            "work",
            &work_tokens,
        )
        .unwrap();
        tron::llm::auth::storage::save_account_oauth_tokens(
            &path,
            "anthropic",
            "personal",
            &personal_tokens,
        )
        .unwrap();

        let config = tron::llm::auth::anthropic::default_config();

        // Select "personal" account
        let result =
            tron::llm::auth::anthropic::load_server_auth(&path, &config, Some("personal"))
                .await
                .unwrap();
        assert_eq!(result.unwrap().token(), "personal-tok");

        // No preference → first account
        let result = tron::llm::auth::anthropic::load_server_auth(&path, &config, None)
            .await
            .unwrap();
        assert_eq!(result.unwrap().token(), "work-tok");
    }

    #[tokio::test]
    async fn create_openai_with_oauth_from_file() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("auth.json");

        let tokens = tron::llm::auth::OAuthTokens {
            access_token: "openai-oauth-tok".to_string(),
            refresh_token: "ref".to_string(),
            expires_at: tron::llm::auth::now_ms() + 3_600_000,
        };
        tron::llm::auth::storage::save_provider_oauth_tokens(
            &path,
            tron::llm::auth::openai::PROVIDER_KEY,
            &tokens,
        )
        .unwrap();

        let result = tron::llm::auth::openai::load_server_auth(&path)
            .await
            .unwrap();
        let auth = result.unwrap();
        assert!(auth.is_oauth());
        assert_eq!(auth.token(), "openai-oauth-tok");
    }

    #[tokio::test]
    async fn create_google_with_oauth_from_file() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("auth.json");

        let gpa = tron::llm::auth::GoogleProviderAuth {
            base: tron::llm::auth::ProviderAuth {
                oauth: Some(tron::llm::auth::OAuthTokens {
                    access_token: "ya29.google-tok".to_string(),
                    refresh_token: "ref".to_string(),
                    expires_at: tron::llm::auth::now_ms() + 3_600_000,
                }),
                ..Default::default()
            },
            endpoint: Some(tron::llm::auth::GoogleOAuthEndpoint::Antigravity),
            ..Default::default()
        };
        tron::llm::auth::storage::save_google_provider_auth(&path, &gpa).unwrap();

        let result = tron::llm::auth::google::load_server_auth(&path)
            .await
            .unwrap();
        let auth = result.unwrap();
        assert_eq!(auth.auth.token(), "ya29.google-tok");
        assert_eq!(
            auth.endpoint,
            Some(tron::llm::auth::GoogleOAuthEndpoint::Antigravity)
        );
    }

    #[tokio::test]
    async fn server_auth_maps_to_anthropic_oauth_auth() {
        let server_auth = tron::llm::auth::ServerAuth::OAuth {
            access_token: "tok".to_string(),
            refresh_token: "ref".to_string(),
            expires_at: 999,
            account_label: Some("work".to_string()),
        };
        assert!(server_auth.is_oauth());
        assert_eq!(server_auth.token(), "tok");
    }

    #[tokio::test]
    async fn server_auth_maps_to_api_key_auth() {
        let server_auth = tron::llm::auth::ServerAuth::from_api_key("sk-123");
        assert!(!server_auth.is_oauth());
        assert_eq!(server_auth.token(), "sk-123");
    }

    #[tokio::test]
    async fn server_boots_and_responds() {
        let dir = tempfile::tempdir().unwrap();
        let db_path = dir.path().join("log.db");
        let settings_path = dir.path().join("settings.json");

        // Single DB for events + tasks
        let db_str = db_path.to_string_lossy();
        let pool = tron::events::new_file(&db_str, &test_db_config()).unwrap();
        {
            let conn = pool.get().unwrap();
            let _ = tron::events::run_migrations(&conn).unwrap();
        }
        let event_store = Arc::new(EventStore::new(pool));

        let session_manager = Arc::new(SessionManager::new(event_store.clone()));
        let orchestrator = Arc::new(Orchestrator::new(session_manager.clone(), 10));
        let skill_registry = Arc::new(RwLock::new(SkillRegistry::new()));

        let rpc_context = RpcContext {
            orchestrator: orchestrator.clone(),
            session_manager,
            event_store,
            skill_registry,
            settings_path,
            agent_deps: None,
            server_start_time: std::time::Instant::now(),
            transcription_engine: Arc::new(std::sync::OnceLock::new()),
            subagent_manager: None,
            health_tracker: Arc::new(tron::llm::ProviderHealthTracker::new()),
            shutdown_coordinator: None,
            origin: "localhost:9847".to_string(),
            cron_scheduler: None,
            worktree_coordinator: None,
            device_request_broker: None,
            context_artifacts: Arc::new(
                tron::server::rpc::session_context::ContextArtifactsService::new(),
            ),
            auth_path: dir.path().join("auth.json"),
            broadcast_manager: None,
            oauth_flows: Arc::new(tokio::sync::Mutex::new(std::collections::HashMap::new())),
        };

        let mut registry = MethodRegistry::new();
        tron::server::rpc::handlers::register_all(&mut registry);

        let config = ServerConfig::default();
        let metrics_handle = metrics_exporter_prometheus::PrometheusBuilder::new()
            .build_recorder()
            .handle();
        let server = TronServer::new(config, registry, rpc_context, metrics_handle);

        let bridge = EventBridge::new(
            orchestrator.subscribe(),
            server.broadcast().clone(),
            server.shutdown().token(),
            orchestrator.turn_accumulators().clone(),
        );
        let _bridge = tokio::spawn(bridge.run());

        let (addr, handle) = server.listen().await.unwrap();

        // Health check
        let resp = reqwest::get(format!("http://{addr}/health")).await.unwrap();
        assert!(resp.status().is_success());
        let body: serde_json::Value = resp.json().await.unwrap();
        assert_eq!(body["status"], "ok");

        server.shutdown().shutdown();
        let _ = handle.await;
    }

    #[test]
    fn server_creates_db_on_first_run() {
        let dir = tempfile::tempdir().unwrap();
        let db_path = dir.path().join("new.db");
        assert!(!db_path.exists());

        let db_str = db_path.to_string_lossy();
        let pool = tron::events::new_file(&db_str, &test_db_config()).unwrap();
        let conn = pool.get().unwrap();
        let _ = tron::events::run_migrations(&conn).unwrap();

        assert!(db_path.exists());
    }

    #[test]
    fn server_runs_migrations() {
        let dir = tempfile::tempdir().unwrap();
        let db_path = dir.path().join("log.db");
        let db_str = db_path.to_string_lossy();
        let pool = tron::events::new_file(&db_str, &test_db_config()).unwrap();
        let conn = pool.get().unwrap();
        let _ = tron::events::run_migrations(&conn).unwrap();

        // Verify tables exist
        let count: i64 = conn
            .query_row(
                "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='events'",
                [],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(count, 1);
    }

    fn make_tool_config() -> ToolRegistryConfig {
        let dir = tempfile::tempdir().unwrap();
        let db_path = dir.path().join("tools-test.db");
        let db_str = db_path.to_string_lossy();
        let pool = tron::events::new_file(&db_str, &test_db_config()).unwrap();
        {
            let conn = pool.get().unwrap();
            let _ = tron::events::run_migrations(&conn).unwrap();
        }
        let event_store = Arc::new(EventStore::new(pool));
        ToolRegistryConfig {
            event_store,
            brave_api_key: None,
            apns_service: None,
            http_client: reqwest::Client::new(),
        }
    }

    #[test]
    fn tool_registry_order() {
        let config = make_tool_config();
        let registry = create_tool_registry(&config);
        let names = registry.names();
        assert_eq!(names[0], "Read");
        assert_eq!(names[1], "Write");
        assert_eq!(names[2], "Edit");
        assert_eq!(names[3], "Bash");
        assert_eq!(names[4], "Search");
        assert_eq!(names[5], "Find");
        assert_eq!(names[6], "AskUserQuestion");
        assert_eq!(names[7], "GetConfirmation");
        assert_eq!(names[8], "NotifyApp");
        assert_eq!(names[9], "WebFetch");
    }

    #[test]
    fn tool_registry_has_notify_app() {
        let config = make_tool_config();
        let registry = create_tool_registry(&config);
        assert!(registry.names().contains(&"NotifyApp".to_string()));
    }

    #[test]
    fn tool_registry_count() {
        let config = make_tool_config();
        let registry = create_tool_registry(&config);
        // 10 tools without Brave API key (no WebSearch), without subagent tools
        assert_eq!(
            registry.len(),
            10,
            "expected 10 tools (no WebSearch without Brave key), got: {:?}",
            registry.names()
        );
    }

    #[test]
    fn tool_registry_count_with_web_search() {
        let config = ToolRegistryConfig {
            brave_api_key: Some("test-key".into()),
            ..make_tool_config()
        };
        let registry = create_tool_registry(&config);
        assert_eq!(
            registry.len(),
            11,
            "expected 11 tools with WebSearch, got: {:?}",
            registry.names()
        );
    }

    #[test]
    fn server_registers_all_rpc_methods() {
        let mut registry = MethodRegistry::new();
        tron::server::rpc::handlers::register_all(&mut registry);
        // Should have a substantial number of methods registered
        assert!(registry.methods().len() >= 50);
    }

    #[tokio::test]
    async fn server_graceful_shutdown() {
        let dir = tempfile::tempdir().unwrap();
        let db_path = dir.path().join("events.db");
        let db_str = db_path.to_string_lossy();
        let pool = tron::events::new_file(&db_str, &test_db_config()).unwrap();
        {
            let conn = pool.get().unwrap();
            let _ = tron::events::run_migrations(&conn).unwrap();
        }
        let event_store = Arc::new(EventStore::new(pool));
        let session_manager = Arc::new(SessionManager::new(event_store.clone()));
        let orchestrator = Arc::new(Orchestrator::new(session_manager.clone(), 10));

        let rpc_context = RpcContext {
            orchestrator,
            session_manager,
            event_store,
            skill_registry: Arc::new(RwLock::new(SkillRegistry::new())),
            settings_path: dir.path().join("settings.json"),
            agent_deps: None,
            server_start_time: std::time::Instant::now(),
            transcription_engine: Arc::new(std::sync::OnceLock::new()),
            subagent_manager: None,
            health_tracker: Arc::new(tron::llm::ProviderHealthTracker::new()),
            shutdown_coordinator: None,
            origin: "localhost:9847".to_string(),
            cron_scheduler: None,
            worktree_coordinator: None,
            device_request_broker: None,
            context_artifacts: Arc::new(
                tron::server::rpc::session_context::ContextArtifactsService::new(),
            ),
            auth_path: dir.path().join("auth.json"),
            broadcast_manager: None,
            oauth_flows: Arc::new(tokio::sync::Mutex::new(std::collections::HashMap::new())),
        };

        let mut registry = MethodRegistry::new();
        tron::server::rpc::handlers::register_all(&mut registry);

        let metrics_handle = metrics_exporter_prometheus::PrometheusBuilder::new()
            .build_recorder()
            .handle();
        let server = TronServer::new(
            ServerConfig::default(),
            registry,
            rpc_context,
            metrics_handle,
        );
        let (_, handle) = server.listen().await.unwrap();

        server.shutdown().shutdown();
        tokio::time::timeout(std::time::Duration::from_secs(5), handle)
            .await
            .expect("shutdown timed out")
            .expect("join error");
    }
}
