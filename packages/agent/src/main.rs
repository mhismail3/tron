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
//! tron::mcp           MCP router and always-on McpSearch/McpCall meta-tools
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

use std::path::{Path, PathBuf};
use std::sync::Arc;

use anyhow::{Context, Result};
use clap::Parser;
use parking_lot::RwLock;
use tron::events::{ConnectionConfig, EventStore};
use tron::llm::factory as provider_factory;
use tron::llm::provider::ProviderFactory;
use tron::runtime::orchestrator::orchestrator::Orchestrator;
use tron::runtime::orchestrator::session_manager::SessionManager;
use tron::runtime::orchestrator::subagent_manager::SubagentManager;
use tron::server::config::ServerConfig;
use tron::server::rpc::context::{AgentDeps, RpcContext};
use tron::server::rpc::registry::MethodRegistry;
use tron::server::server::TronServer;
use tron::server::websocket::event_bridge::EventBridge;
use tron::settings::db_path_policy::resolve_production_db_path;
use tron::skills::registry::SkillRegistry;
use tron::tools::registry::ToolRegistry;

mod tool_factory;
use tool_factory::ToolRegistryConfig;

/// Resolved push notification transport.
#[cfg(feature = "apns")]
#[derive(Clone)]
enum PushService {
    /// Relay delivery via Cloudflare Worker.
    Relay(Arc<tron::server::platform::apns::relay::RelayClient>),
}

#[cfg(feature = "apns")]
impl PushService {
    /// Get a type-erased push sender for consumers that don't need to know the transport.
    fn as_sender(&self) -> Arc<dyn tron::server::platform::apns::PushSender> {
        match self {
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
    ///
    /// INVARIANT: defaults to `0.0.0.0` under the trusted-local threat
    /// model — the iOS app reaches the daemon over Tailscale from the
    /// user's own devices. If that assumption shifts (shared network,
    /// multi-user host), flip this default to `127.0.0.1` and gate
    /// remote access behind explicit opt-in. The startup log line built
    /// by `format_listening_log` names the bind address so the operator
    /// can always see what network the server is exposed to.
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
enum Command {
    /// Bearer-token administration for the WebSocket auth gate.
    ///
    /// Currently exposes a single `rotate` subcommand. Future operator
    /// surface (status, revoke-device, etc.) will live here so we don't
    /// pollute the top-level `tron` namespace.
    Auth {
        #[command(subcommand)]
        action: AuthAction,
    },
}

#[derive(clap::Subcommand, Debug)]
enum AuthAction {
    /// Generate a fresh bearer token, persist it to
    /// `~/.tron/system/auth.json` as `bearerToken` (atomic, 0o600), and print it to
    /// stdout. After this completes, every paired iOS device must
    /// re-pair (their cached token is invalidated).
    ///
    /// Safe to run while the server is up — `BearerTokenStore`'s mtime
    /// cache picks the new value up within a few seconds and starts
    /// rejecting upgrade requests carrying the old token with HTTP 401.
    Rotate,
}

/// Dispatch a CLI subcommand and return `true` if a subcommand consumed
/// the invocation (caller should exit without starting the server).
///
/// Kept separate from `main` so the dispatch + side-effect surface stays
/// small and unit-testable. Each branch is responsible for printing a
/// human-readable result on stdout (the user is at a terminal) and a
/// single-line summary on stderr (so `--quiet` redirection still leaves
/// the audit trail visible).
fn run_subcommand(cmd: &Command) -> Result<()> {
    match cmd {
        Command::Auth { action } => match action {
            AuthAction::Rotate => rotate_bearer_token_cli(),
        },
    }
}

fn rotate_bearer_token_cli() -> Result<()> {
    let path = tron::server::onboarding::bearer_token_path();
    let token = tron::server::onboarding::rotate_bearer_token(&path)
        .with_context(|| format!("Failed to rotate bearer token at {}", path.display()))?;
    eprintln!("Bearer token rotated. All paired iOS devices must re-pair with the new token.");
    println!("{token}");
    Ok(())
}

fn ensure_bearer_token_at(path: &Path) -> Result<String> {
    tron::server::onboarding::load_or_create_bearer_token(path)
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
fn format_listening_log(
    addr: &std::net::SocketAddr,
    bind_host: &str,
    method_count: usize,
) -> String {
    let trust_note = if bind_host == "0.0.0.0" || bind_host == "::" {
        " — reachable on all interfaces (trusted-local threat model: ensure Tailscale ACLs or firewall gating is in place)"
    } else if bind_host == "127.0.0.1" || bind_host == "::1" || bind_host == "localhost" {
        " — loopback-only"
    } else {
        ""
    };
    format!(
        "Tron agent listening on http://{addr} ({method_count} RPC methods registered){trust_note}"
    )
}

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

/// System subdirectories created on ordinary server startup.
///
/// Contributor-only directories are intentionally excluded so ordinary
/// startup only creates runtime data required by the installed server.
fn startup_system_subdirs() -> &'static [&'static str] {
    use tron::core::paths::dirs;
    &[dirs::DB, dirs::RUN]
}

/// Ensure `~/.tron/` directory structure exists and seed the system prompt.
fn init_directories() {
    use tron::core::paths::dirs;
    let tron_home = tron::settings::tron_home_dir();
    let system = tron_home.join(dirs::SYSTEM);
    for subdir in startup_system_subdirs() {
        let _ = std::fs::create_dir_all(system.join(subdir));
    }
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
        tron::events::LockError::AlreadyLocked {
            db_path,
            holder_pid,
        } => anyhow::anyhow!(
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
) -> Result<(
    tron::core::logging::TransportHandle,
    tokio::task::JoinHandle<()>,
)> {
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
/// Priority: relay (build-time or runtime env) → disabled.
fn init_push() -> PushServiceOption {
    #[cfg(feature = "apns")]
    {
        use tron::server::platform::apns::{PushConfig, load_push_config};

        match load_push_config() {
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
                tracing::info!("Push: disabled (relay not configured)");
                None
            }
        }
    }
    #[cfg(not(feature = "apns"))]
    {
        None
    }
}

/// MCP initialization result.
struct McpState {
    search: Arc<dyn tron::tools::traits::TronTool>,
    call: Arc<dyn tron::tools::traits::TronTool>,
    router: Arc<tokio::sync::RwLock<tron::mcp::router::McpRouter>>,
}

/// Create the MCP router and meta-tools.
///
/// The router is present even when the server list is empty. That keeps
/// `McpSearch`/`McpCall` in every session and lets settings updates add servers
/// without requiring a daemon restart.
async fn init_mcp(
    settings: &tron::settings::TronSettings,
    settings_path: &std::path::Path,
) -> McpState {
    let mcp_configs = settings.mcp.servers.clone();
    if mcp_configs.is_empty() {
        tracing::debug!("no MCP servers configured; registering empty MCP meta-tools");
    } else {
        tracing::info!(count = mcp_configs.len(), "starting MCP servers");
    }

    let router = tron::mcp::router::McpRouter::new(
        mcp_configs,
        settings_path.to_owned(),
        settings.mcp.schema_refresh_ttl_ms,
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

    // Shutdown is coordinated via `ShutdownCoordinator::register_phase_hook`
    // in main after the server is built — see the `ShutdownPhase::Mcp`
    // registration there. INVARIANT: there is exactly one place that drives
    // `McpRouter::shutdown_all` and that place observes phase ordering.

    McpState {
        search,
        call,
        router,
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
) -> anyhow::Result<ServiceState> {
    let session_manager =
        Arc::new(SessionManager::new(event_store.clone()).with_origin(origin.to_owned()));
    let orchestrator = Arc::new(Orchestrator::new(session_manager.clone()));

    // Crash recovery: recover partial LLM output from orphaned streaming journals
    let recovered = tron::runtime::orchestrator::recovery::recover_incomplete_turns(&event_store);
    if !recovered.is_empty() {
        tracing::info!(
            count = recovered.len(),
            "recovered sessions from crash journals"
        );
    } else {
        tracing::debug!("no orphaned journals found, clean startup");
    }

    let skill_registry = Arc::new(RwLock::new(SkillRegistry::new()));
    let memory_registry = Arc::new(parking_lot::Mutex::new(
        tron::runtime::memory::MemoryRegistry::new(),
    ));

    let (provider_factory, shared_http_client) = init_provider_factory(settings).await;

    // Process manager for background tool execution
    let process_manager: Arc<dyn tron::tools::traits::ProcessManagerOps> = Arc::new(
        tron::runtime::orchestrator::process_manager::ProcessManager::with_deps(
            orchestrator.broadcast().clone(),
            event_store.clone(),
        ),
    );
    let output_buffer_registry =
        Arc::new(tron::runtime::orchestrator::output_buffer::OutputBufferRegistry::new());

    let tool_config = Arc::new(ToolRegistryConfig {
        event_store: event_store.clone(),
        auth_path: auth_path(),
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
    // Wire skill registry so subagents spawned with `skills: [...]`
    // honor each skill's frontmatter `deniedTools` / `allowedTools`
    // via hard tool-registry removal. Without this, subagent skill
    // restrictions would silently no-op (see
    // `SubagentManager::compute_denied_tools`).
    subagent_manager.set_skill_registry(skill_registry.clone());

    // Unified job manager (processes + subagents)
    let subagent_ops: Arc<dyn tron::tools::traits::SubagentOps> = subagent_manager.clone();
    let job_manager: Arc<dyn tron::tools::traits::JobManagerOps> =
        Arc::new(tron::runtime::orchestrator::job_manager::JobManager::new(
            process_manager.clone(),
            subagent_ops,
        ));

    let tool_factory = build_tool_factory(&tool_config, &subagent_manager, &job_manager);

    // Break circular dep: SubagentManager needs tool_factory to spawn children
    subagent_manager.set_tool_factory(tool_factory.clone());

    let agent_deps = Some(AgentDeps {
        provider_factory: provider_factory.clone(),
        tool_factory,
        guardrails: None,
    });
    let shared_subagent_manager = Some(subagent_manager) as Option<Arc<SubagentManager>>;
    let hook_abort_tracker = Arc::new(tron::runtime::hooks::abort_tracker::HookAbortTracker::new());

    let transcription_engine = spawn_transcription_sidecar(settings.server.transcription.enabled);

    Ok(ServiceState {
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
    })
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
///
/// INVARIANT: `SubagentManager` and `JobManager` are created once at startup
/// (`main.rs` bootstrap) and are NEVER swapped. The closure below captures
/// `Arc` clones of each and relies on this invariant — if either becomes
/// swap-capable later, the closure's captured `Arc` would pin the old
/// instance and the factory would silently diverge from new subagent/job
/// work. Revisit M33 in the audit plan if introducing a swap path.
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
        registry.register(Arc::new(tron::tools::system::wait::WaitTool::new(
            jm_for_tools.clone(),
        )));

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

/// Spawn the transcription sidecar (parakeet-mlx via Python worker) when enabled.
fn spawn_transcription_sidecar(
    enabled: bool,
) -> Arc<std::sync::OnceLock<Arc<tron::transcription::MlxEngine>>> {
    let transcription_engine = Arc::new(std::sync::OnceLock::new());
    if !enabled {
        tracing::info!("transcription sidecar disabled");
        return transcription_engine;
    }
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
    let backup_path = tron::core::paths::automations_backup_path();

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
        event_injector: Some(Arc::new(tron::cron::impls::CronSystemEventInjector::new(
            services.event_store.clone(),
        )) as _),
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

/// Build the RPC context that holds all shared state for RPC handlers.
fn build_rpc_context(
    services: ServiceState,
    settings_path: PathBuf,
    origin: String,
    cron: &CronState,
    worktree_coordinator: Option<Arc<tron::worktree::WorktreeCoordinator>>,
    mcp_router: Arc<tokio::sync::RwLock<tron::mcp::router::McpRouter>>,
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
        mcp_router: Some(mcp_router),
        display_stream_registry: None,
        process_manager: Some(services.process_manager.clone()),
        job_manager: Some(services.job_manager.clone()),
        output_buffer_registry: Some(services.output_buffer_registry.clone()),
        hook_abort_tracker: services.hook_abort_tracker.clone(),
        // Provisional defaults; `TronServer::new` overwrites both with the
        // actual `ServerConfig::port` and the canonical onboarded marker path
        // so handlers see the live values from the start of the first request.
        ws_port: 0,
        onboarded_marker_path: tron::server::onboarding::onboarded_marker_path(),
        // User-mode updater wiring (Plan §H.2). Production uses the live
        // GitHub Releases fetcher; `main_tests.rs` and `tests/integration.rs`
        // construct their own `RpcContext` directly and leave this `None`,
        // which short-circuits `system.checkForUpdates` + skips the
        // scheduler arm below. The state path is stable regardless so the
        // `system.getUpdateStatus` handler can still render defaults.
        release_fetcher: Some(Arc::new(tron::server::updater::HttpReleaseFetcher::new())),
        updater_state_path: tron::core::paths::updater_state_path(),
    }
}

/// TTL for idle session cache eviction. Sessions idle beyond this are
/// dropped from the in-memory cache by the background eviction task.
const IDLE_SESSION_CACHE_TTL: std::time::Duration = std::time::Duration::from_secs(3600);

/// Spawn background maintenance tasks (sandbox cleanup, session eviction).
///
/// INVARIANT: ordinary startup must not touch macOS TCC permissions. The
/// Mac onboarding wrapper owns that UX after the install heartbeat, and a
/// daemon-side startup probe can surface permission prompts while the user is
/// still on the install step.
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
}

#[tokio::main]
async fn main() -> Result<()> {
    let args = Cli::parse();

    // CLI subcommands short-circuit before touching the database, the
    // logging subsystem, or the network. They do their own minimal
    // filesystem work (e.g. atomic writes under `~/.tron/system/`) and
    // exit. This keeps `tron auth rotate` safe to invoke while the
    // server is running — the daemon's own `init_*` calls stay
    // confined to the long-running process.
    if let Some(ref cmd) = args.command {
        return run_subcommand(cmd);
    }

    // Phase 1: Pre-database filesystem operations
    init_directories();
    let bearer_token_path = tron::server::onboarding::bearer_token_path();
    let _bearer_token = ensure_bearer_token_at(&bearer_token_path)?;

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
    let mcp = init_mcp(&settings, &settings_path).await;
    let mcp_router = mcp.router.clone();
    let mcp_router_for_shutdown = mcp_router.clone();
    let services = init_services(event_store, &settings, &origin, push_service, mcp).await?;

    // Phase 4: Cron, worktree, RPC context
    let cron = init_cron(&services, &origin);
    let worktree_coordinator = init_worktree(&services, &settings);
    let session_manager_for_startup = services.session_manager.clone();
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
    let bind_host_label = args.host.clone();
    let config = ServerConfig {
        host: args.host,
        port: args.port,
        ..ServerConfig::default()
    };
    let metrics_handle = tron::server::metrics::install_recorder();
    let server = TronServer::new(config, registry, rpc_context, metrics_handle);

    // Register MCP shutdown as an ordered phase hook. Replaces the earlier
    // standalone `ctrl_c` watcher in `init_mcp`, which raced with main's
    // shutdown path (both could call `router.shutdown_all()` concurrently).
    server.shutdown().register_phase_hook(
        tron::server::shutdown::ShutdownPhase::Mcp,
        "mcp",
        move || async move {
            mcp_router_for_shutdown.write().await.shutdown_all().await;
        },
    );

    // Event bridge: orchestrator events -> WebSocket clients
    let bridge = EventBridge::new(
        orchestrator_for_bridge.subscribe(),
        server.broadcast().clone(),
        server.shutdown().token(),
        orchestrator_for_bridge.turn_accumulators().clone(),
    );
    let bridge_handle = tokio::spawn(bridge.run());

    // Wire cron broadcaster and shutdown forwarding
    cron.scheduler
        .set_broadcaster(Arc::new(tron::cron::impls::CronEventBroadcaster::new(
            server.broadcast().clone(),
        )));
    {
        let cron_cancel = cron.cancel.clone();
        let shutdown_token = server.shutdown().token();
        #[allow(clippy::let_underscore_future)]
        let _ = tokio::spawn(async move {
            shutdown_token.cancelled().await;
            cron_cancel.cancel();
        });
    }

    // Phase 6: Background tasks and bind
    spawn_background_tasks(&session_manager_for_startup, &server);
    let (cron_sched_handle, cron_watcher_handle) = cron.scheduler.clone().start();

    // User-mode auto-update scheduler (Plan §H.2, Phase 5.5). Spawned
    // unconditionally; the task checks `server.update.enabled` on every
    // iteration so a settings flip takes effect without restart. When
    // the fetcher is `None` (embedded / test paths) the scheduler
    // silently no-ops because `perform_tick` bails on `enabled = false`
    // and tests never set enabled.
    let updater_scheduler_handle =
        if let Some(fetcher) = server.rpc_context().release_fetcher.as_ref().cloned() {
            let deps = tron::server::updater::SchedulerDeps {
                fetcher,
                broadcast: server.broadcast().clone(),
                state_path: server.rpc_context().updater_state_path.clone(),
                pause_path: tron::server::updater::pause_sentinel_path(),
                current_version: env!("CARGO_PKG_VERSION").to_string(),
            };
            Some(tron::server::updater::scheduler::spawn(
                deps,
                server.shutdown().token(),
            ))
        } else {
            None
        };

    let (addr, server_handle) = server.listen().await.context("Failed to bind server")?;
    tracing::info!(
        "{}",
        format_listening_log(&addr, &bind_host_label, method_count)
    );

    // Wait for shutdown signal
    tokio::signal::ctrl_c()
        .await
        .context("Failed to listen for ctrl-c")?;

    tracing::info!("Shutting down...");
    let mut shutdown_handles: Vec<tokio::task::JoinHandle<()>> = vec![
        server_handle,
        bridge_handle,
        cron_sched_handle,
        cron_watcher_handle,
    ];
    if let Some(h) = updater_scheduler_handle {
        shutdown_handles.push(h);
    }
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
