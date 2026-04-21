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
//! 7. Production DB target is strictly `~/.tron/system/database/log.db`

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

mod tool_factory;
use tool_factory::ToolRegistryConfig;

/// Resolved push notification transport.
#[cfg(feature = "apns")]
#[derive(Clone)]
enum PushService {
    /// Direct APNs delivery via .p8 key on disk.
    Direct(Arc<tron::server::platform::apns::ApnsService>),
    /// Relay delivery via Cloudflare Worker.
    Relay(Arc<tron::server::platform::apns::relay::RelayClient>),
}

#[cfg(feature = "apns")]
impl PushService {
    /// Get a type-erased push sender for consumers that don't need to know the transport.
    fn as_sender(&self) -> Arc<dyn tron::server::platform::apns::PushSender> {
        match self {
            PushService::Direct(apns) => apns.clone(),
            PushService::Relay(relay) => relay.clone(),
        }
    }
}

#[cfg(feature = "apns")]
type PushServiceOption = Option<PushService>;
#[cfg(not(feature = "apns"))]
type PushServiceOption = Option<()>;

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

    /// Override database log level (trace, debug, info, warn, error).
    #[arg(long, global = true)]
    log_level: Option<String>,

    /// Suppress stderr logging (logs still persist to database).
    #[arg(long, global = true)]
    quiet: bool,
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



/// INVARIANT: Deploy crash-loop protection runs FIRST (pure filesystem, no dependencies).
/// If the previous deploy crashed the process before self-test could run, this catches it
/// after `MAX_DEPLOY_STARTUP_ATTEMPTS` and auto-rolls back to the backup binary.
fn init_crash_recovery() {
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
            tron::server::deploy::auto_rollback(
                &deploy_dir,
                &tron::core::paths::tron_binary_path(),
                &format!("exceeded {MAX_DEPLOY_STARTUP_ATTEMPTS} startup attempts"),
            );
            // auto_rollback never returns
        }

        let _ = std::fs::create_dir_all(&deploy_dir);
        let _ = std::fs::write(&attempts_path, (attempt + 1).to_string());
    }
}

/// Ensure `~/.tron/` directory structure exists and seed the system prompt.
fn init_directories() {
    use tron::core::paths::dirs;
    let tron_home = tron::settings::tron_home_dir();
    let system = tron_home.join(dirs::SYSTEM);
    for subdir in &[dirs::DB, dirs::DEPLOYMENT] {
        let _ = std::fs::create_dir_all(system.join(subdir));
    }
    let _ = std::fs::create_dir_all(
        system.join(dirs::APP_BUNDLE).join("Contents").join("MacOS"),
    );
    for subdir in &[
        dirs::KNOWLEDGE,
        dirs::REPORTS,
        dirs::CRON,
        dirs::SCRATCH,
        dirs::SCREENSHOTS,
    ] {
        let _ = std::fs::create_dir_all(tron_home.join(dirs::WORKSPACE).join(subdir));
    }
    let _ = std::fs::create_dir_all(tron_home.join(dirs::WORKSPACE).join(dirs::VOICE_NOTES));
    let _ = std::fs::create_dir_all(tron_home.join(dirs::SKILLS));
    // Memory workspace: rules (SYSTEM.md, core memories) + sessions (journals)
    let memory = tron_home.join(dirs::WORKSPACE).join(dirs::MEMORY);
    let _ = std::fs::create_dir_all(memory.join(dirs::RULES));
    let _ = std::fs::create_dir_all(memory.join(dirs::SESSIONS));
}

/// Open the SQLite database, run migrations, and return the pool + resolved path.
fn init_database(
    db_path_override: Option<PathBuf>,
) -> Result<(
    r2d2::Pool<r2d2_sqlite::SqliteConnectionManager>,
    PathBuf,
    tron::events::DatabaseLock,
)> {
    let db_path = resolve_production_db_path(db_path_override)?;
    ensure_parent_dir(&db_path)?;

    // INVARIANT: A single process owns the event-store DB. Take the
    // OS-level flock before opening the connection pool so a stray
    // `tron dev` alongside the launchd service aborts at startup
    // instead of silently racing on (session_id, sequence).
    let db_lock = tron::events::acquire_database_lock(&db_path).map_err(|e| match e {
        tron::events::LockError::AlreadyLocked { db_path, holder_pid } => anyhow::anyhow!(
            "Another Tron process (PID {holder_pid}) is already using {}. \
             Stop it (e.g. `launchctl stop com.tron.server` or `kill {holder_pid}`) and retry.",
            db_path.display()
        ),
        tron::events::LockError::Io { path, source } => anyhow::anyhow!(
            "Failed to prepare database lock file at {}: {source}",
            path.display()
        ),
    })?;

    let db_str = db_path.to_string_lossy();
    let pool = tron::events::new_file(&db_str, &ConnectionConfig::default())
        .context("Failed to open database")?;
    {
        let conn = pool.get().context("Failed to get DB connection")?;
        // Catch WAL-recovery-hiding-corruption before any writes
        // happen. The first connection to a file-backed DB triggers
        // automatic WAL replay; if the WAL was corrupt we want to
        // know NOW, not after a session has been partially
        // reconstructed from damaged data.
        tron::events::check_integrity(&conn).context(
            "Database integrity check failed. The event store may be corrupt; \
             restore from a backup or investigate ~/.tron/system/database/log.db.",
        )?;
        let _ = tron::events::run_migrations(&conn).context("Failed to run migrations")?;
    }
    Ok((pool, db_path, db_lock))
}

/// Initialize tracing with SQLite persistence and start the periodic flush task.
fn init_logging(
    db_path: &std::path::Path,
    settings: &tron::settings::TronSettings,
    log_level_override: Option<&str>,
    origin: &str,
    stderr_enabled: bool,
) -> Result<(tron::core::logging::TransportHandle, tokio::task::JoinHandle<()>)> {
    // Dedicated connection, separate from pool. Must set WAL + busy_timeout to match
    // pool connections — without busy_timeout, concurrent writes cause SQLITE_BUSY errors.
    let log_conn =
        rusqlite::Connection::open(db_path).context("Failed to open logging DB connection")?;
    log_conn
        .execute_batch("PRAGMA journal_mode = WAL; PRAGMA busy_timeout = 5000;")
        .context("Failed to set logging connection pragmas")?;
    let module_overrides: Vec<(String, &str)> = settings
        .logging
        .module_overrides
        .iter()
        .map(|(m, lvl)| (m.clone(), lvl.as_filter_str()))
        .collect();
    let effective_log_level =
        log_level_override.unwrap_or_else(|| settings.logging.db_log_level.as_filter_str());
    let log_handle = tron::core::logging::init_subscriber_with_sqlite(
        effective_log_level,
        &module_overrides,
        log_conn,
        Some(origin.to_owned()),
        stderr_enabled,
    );
    let flush_task = tron::core::logging::spawn_flush_task(log_handle.clone());
    Ok((log_handle, flush_task))
}

/// Initialize push notification service.
///
/// Priority: direct .p8 on disk → relay (build-time or runtime env) → disabled.
fn init_push() -> PushServiceOption {
    #[cfg(feature = "apns")]
    {
        use tron::server::platform::apns::{PushConfig, load_push_config};

        match load_push_config() {
            PushConfig::Direct(config) => {
                match tron::server::platform::apns::ApnsService::new(config) {
                    Ok(svc) => {
                        tracing::info!("Push: direct APNs (local .p8 key)");
                        Some(PushService::Direct(Arc::new(svc)))
                    }
                    Err(e) => {
                        tracing::warn!(error = %e, "Direct APNs init failed — checking relay...");
                        // Fall through to relay if direct fails
                        init_push_relay()
                    }
                }
            }
            PushConfig::Relay(config) => {
                tracing::info!(
                    relay_url = %config.relay_url,
                    environment = %config.environment,
                    "Push: relay mode"
                );
                Some(PushService::Relay(Arc::new(
                    tron::server::platform::apns::relay::RelayClient::new(config),
                )))
            }
            PushConfig::Disabled => {
                tracing::info!("Push: disabled (no APNs config or relay)");
                None
            }
        }
    }
    #[cfg(not(feature = "apns"))]
    {
        None
    }
}

/// Try relay as fallback when direct APNs init fails.
#[cfg(feature = "apns")]
fn init_push_relay() -> PushServiceOption {
    if let Some(config) = tron::server::platform::apns::load_relay_config() {
        tracing::info!(
            relay_url = %config.relay_url,
            environment = %config.environment,
            "Push: falling back to relay mode"
        );
        Some(PushService::Relay(Arc::new(
            tron::server::platform::apns::relay::RelayClient::new(config),
        )))
    } else {
        tracing::info!("Push: disabled (direct failed, no relay configured)");
        None
    }
}

/// MCP initialization result.
struct McpState {
    search: Option<Arc<dyn tron::tools::traits::TronTool>>,
    call: Option<Arc<dyn tron::tools::traits::TronTool>>,
    router: Option<Arc<tokio::sync::RwLock<tron::mcp::router::McpRouter>>>,
}

/// Create MCP router, discover tools, and register meta-tools.
async fn init_mcp(settings: &tron::settings::TronSettings, settings_path: &std::path::Path) -> McpState {
    let mcp_configs = settings.mcp.servers.clone();
    if mcp_configs.is_empty() {
        tracing::debug!("no MCP servers configured");
        return McpState { search: None, call: None, router: None };
    }

    tracing::info!(count = mcp_configs.len(), "starting MCP servers");
    let router = tron::mcp::router::McpRouter::new(
        mcp_configs,
        settings_path.to_owned(),
    )
    .await;
    let statuses = router.status();
    let connected: Vec<_> = statuses
        .iter()
        .filter(|s| s.health != tron::mcp::types::McpServerHealth::Failed)
        .map(|s| s.name.as_str())
        .collect();
    if !connected.is_empty() {
        let tool_count: usize = statuses.iter().map(|s| s.tool_count).sum();
        tracing::info!(
            servers = ?connected,
            tool_count,
            "MCP meta-tools registered (McpSearch + McpCall)"
        );
    }
    let router = Arc::new(tokio::sync::RwLock::new(router));
    let search = Arc::new(tron::mcp::search_tool::McpSearchTool::new(router.clone()))
        as Arc<dyn tron::tools::traits::TronTool>;
    let call = Arc::new(tron::mcp::call_tool::McpCallTool::new(router.clone()))
        as Arc<dyn tron::tools::traits::TronTool>;

    // Register shutdown hook
    let router_for_shutdown = router.clone();
    let _shutdown_hook = tokio::spawn(async move {
        let _ = tokio::signal::ctrl_c().await;
        router_for_shutdown.write().await.shutdown_all().await;
    });

    McpState {
        search: Some(search),
        call: Some(call),
        router: Some(router),
    }
}

/// Shared state produced by service initialization, consumed by server setup.
struct ServiceState {
    event_store: Arc<EventStore>,
    session_manager: Arc<SessionManager>,
    orchestrator: Arc<Orchestrator>,
    skill_registry: Arc<RwLock<SkillRegistry>>,
    memory_registry: Arc<parking_lot::Mutex<tron::runtime::memory::MemoryRegistry>>,
    agent_deps: Option<AgentDeps>,
    shared_subagent_manager: Option<Arc<SubagentManager>>,
    hook_abort_tracker: Arc<tron::runtime::hooks::abort_tracker::HookAbortTracker>,
    tool_config: Arc<ToolRegistryConfig>,
    process_manager: Arc<dyn tron::tools::traits::ProcessManagerOps>,
    job_manager: Arc<dyn tron::tools::traits::JobManagerOps>,
    output_buffer_registry: Arc<tron::runtime::orchestrator::output_buffer::OutputBufferRegistry>,
    transcription_engine: Arc<std::sync::OnceLock<Arc<tron::transcription::MlxEngine>>>,
}

/// Build core services: orchestrator, session manager, providers, tools, subagent manager.
async fn init_services(
    event_store: Arc<EventStore>,
    settings: &tron::settings::TronSettings,
    origin: &str,
    push_service: PushServiceOption,
    mcp: McpState,
) -> ServiceState {
    let session_manager =
        Arc::new(SessionManager::new(event_store.clone()).with_origin(origin.to_owned()));
    let orchestrator = Arc::new(Orchestrator::new(session_manager.clone()));

    // Crash recovery: recover partial LLM output from orphaned streaming journals
    let recovered = tron::runtime::orchestrator::recovery::recover_incomplete_turns(&event_store);
    if !recovered.is_empty() {
        tracing::info!(count = recovered.len(), "recovered sessions from crash journals");
    } else {
        tracing::debug!("no orphaned journals found, clean startup");
    }

    let skill_registry = Arc::new(RwLock::new(SkillRegistry::new()));
    let memory_registry = Arc::new(parking_lot::Mutex::new(
        tron::runtime::memory::MemoryRegistry::new(),
    ));

    // Load Brave API key for web search
    let brave_api_key = tron::llm::auth::storage::get_service_api_keys(&auth_path(), "brave")
        .into_iter()
        .next();
    if brave_api_key.is_some() {
        tracing::info!("Brave API key loaded — WebSearch tool enabled");
    }

    let (provider_factory, shared_http_client) =
        init_provider_factory(settings).await;

    // Process manager for background tool execution
    let process_manager: Arc<dyn tron::tools::traits::ProcessManagerOps> = Arc::new(
        tron::runtime::orchestrator::process_manager::ProcessManager::with_deps(
            orchestrator.broadcast().clone(),
            event_store.clone(),
        ),
    );
    let output_buffer_registry = Arc::new(
        tron::runtime::orchestrator::output_buffer::OutputBufferRegistry::new(),
    );

    let tool_config = Arc::new(ToolRegistryConfig {
        event_store: event_store.clone(),
        brave_api_key,
        push_service,
        http_client: shared_http_client,
        sandbox_settings: settings.tools.bash.sandbox.clone(),
        computer_use_settings: settings.tools.computer_use.clone(),
        display_event_tx: Some(orchestrator.broadcast().sender()),
        mcp_search: mcp.search,
        mcp_call: mcp.call,
    });

    // Subagent manager
    let subagent_manager = Arc::new(SubagentManager::new(
        session_manager.clone(),
        event_store.clone(),
        orchestrator.broadcast().clone(),
        provider_factory.clone(),
        None,
        None,
    ));
    subagent_manager.set_self_ref();
    // Wire run-state probe so D4 notification routing can query parent
    // run state server-side (replaces iOS-side agentPhase check).
    subagent_manager.set_run_state_probe(orchestrator.run_state_probe());

    // Unified job manager (processes + subagents)
    let subagent_ops: Arc<dyn tron::tools::traits::SubagentOps> = subagent_manager.clone();
    let job_manager: Arc<dyn tron::tools::traits::JobManagerOps> = Arc::new(
        tron::runtime::orchestrator::job_manager::JobManager::new(
            process_manager.clone(),
            subagent_ops,
        ),
    );

    let tool_factory = build_tool_factory(
        &tool_config,
        &subagent_manager,
        &job_manager,
    );

    // Break circular dep: SubagentManager needs tool_factory to spawn children
    subagent_manager.set_tool_factory(tool_factory.clone());

    let agent_deps = Some(AgentDeps {
        provider_factory: provider_factory.clone(),
        tool_factory,
        guardrails: None,
    });
    let shared_subagent_manager = Some(subagent_manager) as Option<Arc<SubagentManager>>;
    let hook_abort_tracker =
        Arc::new(tron::runtime::hooks::abort_tracker::HookAbortTracker::new());

    let transcription_engine = spawn_transcription_sidecar();

    ServiceState {
        event_store,
        session_manager,
        orchestrator,
        skill_registry,
        memory_registry,
        agent_deps,
        shared_subagent_manager,
        hook_abort_tracker,
        tool_config,
        process_manager,
        job_manager,
        output_buffer_registry,
        transcription_engine,
    }
}

/// Create provider factory and check startup auth availability.
async fn init_provider_factory(
    settings: &tron::settings::TronSettings,
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

/// Build the tool factory closure that creates a fresh ToolRegistry per agent run.
///
/// Adds subagent spawning, job management, and LLM-summarizer-backed WebFetch
/// on top of the base registry from `create_tool_registry()`.
fn build_tool_factory(
    tool_config: &Arc<ToolRegistryConfig>,
    subagent_manager: &Arc<SubagentManager>,
    job_manager: &Arc<dyn tron::tools::traits::JobManagerOps>,
) -> Arc<dyn Fn() -> ToolRegistry + Send + Sync> {
    let config = tool_config.clone();
    let spawner: Arc<dyn tron::tools::traits::SubagentSpawner> = subagent_manager.clone();
    let sm_for_summarizer = subagent_manager.clone();
    let jm_for_tools = job_manager.clone();
    Arc::new(move || {
        let mut registry = tool_factory::create_tool_registry(&config);
        registry.register(Arc::new(
            tron::tools::subagent::spawn::SpawnSubagentTool::new(spawner.clone()),
        ));

        // Job management tools
        registry.register(Arc::new(
            tron::tools::system::manage_process::ManageJobTool::new(jm_for_tools.clone()),
        ));
        registry.register(Arc::new(
            tron::tools::system::wait::WaitTool::new(jm_for_tools.clone()),
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
    })
}

/// Spawn the transcription sidecar (parakeet-mlx via Python worker).
fn spawn_transcription_sidecar() -> Arc<std::sync::OnceLock<Arc<tron::transcription::MlxEngine>>> {
    let transcription_engine = Arc::new(std::sync::OnceLock::new());
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
    transcription_engine
}

/// Cron initialization result.
struct CronState {
    scheduler: Arc<tron::cron::CronScheduler>,
    cancel: tokio_util::sync::CancellationToken,
}

/// Build the cron scheduler with executor dependencies.
fn init_cron(services: &ServiceState, origin: &str) -> CronState {
    let cancel = tokio_util::sync::CancellationToken::new();
    let config_path = tron::core::paths::automations_path();
    let backup_path = tron::settings::deploy_dir().join("automations.json.bak");

    let agent_executor = services.agent_deps.as_ref().map(|deps| {
        Arc::new(tron::cron::impls::CronAgentTurnExecutor::new(
            services.event_store.clone(),
            services.session_manager.clone(),
            deps.provider_factory.clone(),
            deps.tool_factory.clone(),
            origin.to_owned(),
            services.shared_subagent_manager.clone(),
        )) as _
    });
    let deps = tron::cron::ExecutorDeps {
        agent_executor,
        broadcaster: std::sync::OnceLock::new(), // set after TronServer creation
        push_notifier: {
            #[cfg(feature = "apns")]
            {
                services.tool_config.push_service.as_ref().map(|ps| {
                    Arc::new(tron::cron::impls::CronPushNotifier::new(
                        ps.as_sender(),
                        services.event_store.pool().clone(),
                    )) as _
                })
            }
            #[cfg(not(feature = "apns"))]
            {
                None
            }
        },
        event_injector: Some(
            Arc::new(tron::cron::impls::CronSystemEventInjector::new(
                services.event_store.clone(),
            )) as _,
        ),
        http_client: services.tool_config.http_client.clone(),
        pool: services.event_store.pool().clone(),
    };
    let scheduler = Arc::new(tron::cron::CronScheduler::new(
        services.event_store.pool().clone(),
        Arc::new(tron::cron::SystemClock),
        deps,
        config_path,
        backup_path,
        cancel.clone(),
    ));

    CronState { scheduler, cancel }
}

/// Initialize the worktree coordinator, rebuild state, and wire into session/subagent managers.
fn init_worktree(
    services: &ServiceState,
    settings: &tron::settings::TronSettings,
) -> Option<Arc<tron::worktree::WorktreeCoordinator>> {
    let wt_config =
        tron::worktree::WorktreeConfig::from_settings_with_git(&settings.session, &settings.git);
    let coord = Arc::new(tron::worktree::WorktreeCoordinator::with_broadcast(
        wt_config,
        services.event_store.clone(),
        services.orchestrator.broadcast().sender(),
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
    // Rebuild pending-merge state from `.git/MERGE_HEAD` / `.git/rebase-merge/`
    // left behind by a crashed server. Surfaces a banner in iOS and arms
    // the auto-abort timer so half-merged sessions can't linger forever.
    let coord_for_pending = coord.clone();
    #[allow(clippy::let_underscore_future)]
    let _ = tokio::spawn(async move {
        let count = coord_for_pending.rebuild_pending_merges().await;
        if count > 0 {
            tracing::info!(count, "reconstructed pending merges after crash");
        }
    });
    // Wire coordinator into SessionManager (for end_session release)
    services
        .session_manager
        .set_worktree_coordinator(coord.clone());
    // Wire coordinator into SubagentManager (for subagent isolation)
    if let Some(ref sm) = services.shared_subagent_manager {
        sm.set_worktree_coordinator(coord.clone());
    }
    Some(coord)
}

/// Run the post-deploy self-test. If it fails, auto-rollback (never returns).
fn run_deploy_self_test(db_path: &std::path::Path, settings_path: &std::path::Path) {
    let deploy_dir = tron::settings::deploy_dir();
    if let Some(sentinel) = tron::server::deploy::read_sentinel(&deploy_dir)
        && sentinel.status == "restarting"
    {
        let auth = auth_path();
        let binary_path = tron::core::paths::tron_binary_path();
        let test_result = tron::server::deploy::run_self_test(
            db_path,
            settings_path,
            &auth,
            &binary_path,
            &deploy_dir,
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

/// Process deploy sentinel completion and send APNS notifications.
fn process_deploy_sentinel(
    #[cfg_attr(not(feature = "apns"), allow(unused_variables))]
    push_for_deploy: &PushServiceOption,
    #[cfg_attr(not(feature = "apns"), allow(unused_variables))]
    pool_for_deploy: &r2d2::Pool<r2d2_sqlite::SqliteConnectionManager>,
) {
    /// Fetch all active device tokens with their environments from the database.
    #[cfg(feature = "apns")]
    fn active_device_tokens(
        pool: &r2d2::Pool<r2d2_sqlite::SqliteConnectionManager>,
    ) -> Vec<(String, String, Option<String>)> {
        pool.get()
            .ok()
            .and_then(|conn| {
                conn.prepare(
                    "SELECT device_token, environment, bundle_id FROM device_tokens WHERE is_active = 1",
                )
                .ok()
                .and_then(|mut stmt| {
                    stmt.query_map([], |row| {
                        Ok((
                            row.get::<_, String>(0)?,
                            row.get::<_, String>(1)?,
                            row.get::<_, Option<String>>(2)?,
                        ))
                    })
                    .ok()
                    .map(|rows| rows.filter_map(Result::ok).collect())
                })
            })
            .unwrap_or_default()
    }

    /// Send a push notification to all active devices, grouped by `(environment, bundle_id)`.
    ///
    /// Matches the grouping used by the main notify path in
    /// `server::platform::apns::push_helpers::group_tokens`. Without the
    /// bundle_id axis, Beta tokens go out with the production topic and
    /// APNs rejects with `DeviceTokenNotForTopic`.
    #[cfg(feature = "apns")]
    fn send_push(
        push: &PushService,
        tokens_with_meta: Vec<(String, String, Option<String>)>,
        notification: tron::server::platform::apns::ApnsNotification,
    ) {
        let sender = push.as_sender();
        drop(tokio::spawn(async move {
            let mut groups: std::collections::HashMap<(String, Option<String>), Vec<String>> =
                std::collections::HashMap::new();
            for (token, env, bundle_id) in tokens_with_meta {
                groups.entry((env, bundle_id)).or_default().push(token);
            }
            for ((env, bundle_id), tokens) in &groups {
                let bid = bundle_id.as_deref().unwrap_or("");
                let _ = sender
                    .send_to_many(tokens, &notification, env, bid)
                    .await;
            }
        }));
    }

    let deploy_dir = tron::settings::deploy_dir();
    match tron::server::deploy::complete_sentinel(&deploy_dir) {
        Ok(Some(sentinel)) => {
            tracing::info!(
                commit = sentinel.commit.as_str(),
                previous = sentinel.previous_commit.as_str(),
                "post-deploy restart completed successfully"
            );
            if let Err(e) =
                tron::server::deploy::write_last_deployment(&deploy_dir, &sentinel)
            {
                tracing::warn!(error = %e, "failed to write last-deployment.json");
            }

            #[cfg(feature = "apns")]
            if let Some(push) = push_for_deploy {
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
                let tokens = active_device_tokens(pool_for_deploy);
                if !tokens.is_empty() {
                    send_push(push, tokens, tron::server::platform::apns::ApnsNotification {
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
                    });
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
        if let Some(push) = push_for_deploy
            && let Ok(content) = std::fs::read_to_string(&pending_path)
            && let Ok(data) = serde_json::from_str::<serde_json::Value>(&content)
        {
            let tokens = active_device_tokens(pool_for_deploy);
            if !tokens.is_empty() {
                let ntype = data["type"].as_str().unwrap_or("deploy.rolled_back");
                let reason = data["reason"].as_str().unwrap_or("unknown");
                send_push(push, tokens, tron::server::platform::apns::ApnsNotification {
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
                });
            }
        }
        let _ = std::fs::remove_file(&pending_path);
    }
}

/// Build the RPC context that holds all shared state for RPC handlers.
fn build_rpc_context(
    services: ServiceState,
    settings_path: PathBuf,
    origin: String,
    cron: &CronState,
    worktree_coordinator: Option<Arc<tron::worktree::WorktreeCoordinator>>,
    mcp_router: Option<Arc<tokio::sync::RwLock<tron::mcp::router::McpRouter>>>,
) -> RpcContext {
    RpcContext {
        orchestrator: services.orchestrator.clone(),
        session_manager: services.session_manager.clone(),
        event_store: services.event_store.clone(),
        skill_registry: services.skill_registry,
        memory_registry: services.memory_registry,
        settings_path,
        agent_deps: services.agent_deps,
        server_start_time: std::time::Instant::now(),
        transcription_engine: services.transcription_engine,
        subagent_manager: services.shared_subagent_manager,
        health_tracker: Arc::new(tron::llm::ProviderHealthTracker::new()),
        shutdown_coordinator: None,
        origin,
        cron_scheduler: Some(cron.scheduler.clone()),
        worktree_coordinator,
        device_request_broker: None,
        context_artifacts: Arc::new(
            tron::server::rpc::session_context::ContextArtifactsService::new(),
        ),
        auth_path: auth_path(),
        broadcast_manager: None,
        oauth_flows: Arc::new(tokio::sync::Mutex::new(std::collections::HashMap::new())),
        mcp_router,
        display_stream_registry: None,
        process_manager: Some(services.process_manager.clone()),
        job_manager: Some(services.job_manager.clone()),
        output_buffer_registry: Some(services.output_buffer_registry.clone()),
        hook_abort_tracker: services.hook_abort_tracker.clone(),
    }
}

/// TTL for idle session cache eviction. Sessions idle beyond this are
/// dropped from the in-memory cache by the background eviction task.
const IDLE_SESSION_CACHE_TTL: std::time::Duration = std::time::Duration::from_secs(3600);

/// Spawn background maintenance tasks (sandbox cleanup, session eviction, permissions check).
fn spawn_background_tasks(session_manager: &Arc<SessionManager>, server: &TronServer) {
    // Clean up stale sandbox directories from previous sessions (>24h old)
    let _sandbox_cleanup =
        tokio::spawn(async { tron::tools::system::sandbox::cleanup_stale_sandboxes().await });

    // Periodic session cache eviction (prevents unbounded memory growth)
    let eviction_mgr = session_manager.clone();
    let eviction_shutdown = server.shutdown().token();
    let cache_ttl = IDLE_SESSION_CACHE_TTL;
    let _eviction_task = tokio::spawn(async move {
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

    // Check macOS permissions for ComputerUse (Accessibility + Screen Recording).
    // Triggers OS permission prompts on first run so users don't hit errors mid-session.
    let _permissions_check = tokio::spawn(async {
        tron::tools::ui::computer_use::check_permissions_on_startup().await;
    });
}

#[tokio::main]
async fn main() -> Result<()> {
    let args = Cli::parse();

    // Phase 1: Pre-database filesystem operations
    init_crash_recovery();
    init_directories();

    // Phase 2: Database and logging
    // _db_lock is bound for the lifetime of main(); dropping it releases the
    // process-level lock on the event-store DB. Keep in scope explicitly so
    // compilation fails if it's ever moved out without an equivalent guard.
    let (pool, db_path, _db_lock) = init_database(args.db_path)?;
    let settings_path = tron::settings::loader::settings_path();
    let settings =
        tron::settings::loader::load_settings_from_path(&settings_path).unwrap_or_default();
    let origin = format!("localhost:{}", args.port);
    let (log_handle, flush_task) = init_logging(
        &db_path,
        &settings,
        args.log_level.as_deref(),
        &origin,
        !args.quiet,
    )?;
    let event_store = Arc::new(EventStore::new(pool));

    // Opportunistic prompt-history prune on startup. Fire-and-forget: runtime
    // must not block on this. Skipped entirely unless retention is configured.
    {
        let pl = settings.prompt_library.clone();
        if pl.history_auto_prune && (pl.history_max_entries > 0 || pl.history_max_age_days > 0) {
            let pool = event_store.pool().clone();
            let _handle = tokio::task::spawn_blocking(move || {
                let age = (pl.history_max_age_days > 0).then_some(pl.history_max_age_days);
                let cap = (pl.history_max_entries > 0).then_some(pl.history_max_entries);
                match tron::prompt_library::store::prune_history(&pool, age, cap) {
                    Ok(n) if n > 0 => {
                        tracing::debug!(deleted = n, "pruned prompt history on startup");
                    }
                    Ok(_) => {}
                    Err(e) => {
                        tracing::warn!(error = %e, "failed to prune prompt history on startup");
                    }
                }
            });
        }
    }

    // Phase 3: Core services (orchestrator, providers, tools, subagents)
    let push_service = init_push();
    let push_for_deploy = push_service.clone();
    let mcp = init_mcp(&settings, &settings_path).await;
    let mcp_router = mcp.router.clone();
    let services = init_services(event_store, &settings, &origin, push_service, mcp).await;

    // Phase 4: Cron, worktree, RPC context
    let cron = init_cron(&services, &origin);
    let worktree_coordinator = init_worktree(&services, &settings);
    let session_manager_for_startup = services.session_manager.clone();
    let settings_path_for_selftest = settings_path.clone();
    let pool_for_deploy = services.event_store.pool().clone();
    let orchestrator_for_bridge = services.orchestrator.clone();
    let process_manager_for_shutdown = services.process_manager.clone();
    let rpc_context = build_rpc_context(
        services,
        settings_path,
        origin.clone(),
        &cron,
        worktree_coordinator,
        mcp_router,
    );

    // Phase 5: Build and start server
    let mut registry = MethodRegistry::new();
    tron::server::rpc::handlers::register_all(&mut registry);
    let method_count = registry.methods().len();
    let config = ServerConfig {
        host: args.host,
        port: args.port,
        ..ServerConfig::default()
    };
    let metrics_handle = tron::server::metrics::install_recorder();
    let server = TronServer::new(config, registry, rpc_context, metrics_handle);

    // Event bridge: orchestrator events -> WebSocket clients
    let bridge = EventBridge::new(
        orchestrator_for_bridge.subscribe(),
        server.broadcast().clone(),
        server.shutdown().token(),
        orchestrator_for_bridge.turn_accumulators().clone(),
    );
    let bridge_handle = tokio::spawn(bridge.run());

    // Wire cron broadcaster and shutdown forwarding
    cron.scheduler.set_broadcaster(Arc::new(
        tron::cron::impls::CronEventBroadcaster::new(server.broadcast().clone()),
    ));
    {
        let cron_cancel = cron.cancel.clone();
        let shutdown_token = server.shutdown().token();
        #[allow(clippy::let_underscore_future)]
        let _ = tokio::spawn(async move {
            shutdown_token.cancelled().await;
            cron_cancel.cancel();
        });
    }

    // Phase 6: Background tasks, self-test, bind
    spawn_background_tasks(&session_manager_for_startup, &server);
    let (cron_sched_handle, cron_watcher_handle) = cron.scheduler.clone().start();
    run_deploy_self_test(&db_path, &settings_path_for_selftest);

    let (addr, server_handle) = server.listen().await.context("Failed to bind server")?;
    tracing::info!("Tron agent listening on http://{addr} ({method_count} RPC methods registered)");

    process_deploy_sentinel(&push_for_deploy, &pool_for_deploy);

    // Wait for shutdown signal
    tokio::signal::ctrl_c()
        .await
        .context("Failed to listen for ctrl-c")?;

    tracing::info!("Shutting down...");
    let shutdown_handles: Vec<tokio::task::JoinHandle<()>> = vec![
        server_handle,
        bridge_handle,
        cron_sched_handle,
        cron_watcher_handle,
    ];
    process_manager_for_shutdown.cancel_all();
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
#[path = "main_tests.rs"]
mod tests;
