//! # tron-agent
//!
//! Tron agent server binary — wires together all crates and starts the
//! HTTP/WebSocket server.

#![deny(unsafe_code)]

mod provider_factory;
mod providers;

use std::path::PathBuf;
use std::sync::Arc;

use anyhow::{Context, Result};
use clap::Parser;
use parking_lot::RwLock;
use tron_events::{ConnectionConfig, EventStore};
use tron_llm::provider::ProviderFactory;
use tron_rpc::context::{AgentDeps, RpcContext};
use tron_rpc::registry::MethodRegistry;
use tron_runtime::orchestrator::orchestrator::Orchestrator;
use tron_runtime::orchestrator::session_manager::SessionManager;
use tron_runtime::orchestrator::subagent_manager::SubagentManager;
use tron_server::config::ServerConfig;
use tron_server::server::TronServer;
use tron_server::websocket::event_bridge::EventBridge;
use tron_skills::registry::SkillRegistry;
use tron_tools::registry::ToolRegistry;

/// Tron agent server.
#[derive(Parser, Debug)]
#[command(name = "tron-agent", about = "Tron agent server")]
struct Cli {
    /// Host to bind.
    #[arg(long, default_value = "0.0.0.0")]
    host: String,

    /// Port to bind (0 for auto-assign).
    #[arg(long, default_value = "9847")]
    port: u16,

    /// Path to the `SQLite` database (events + tasks in one file).
    #[arg(long)]
    db_path: Option<PathBuf>,

    /// Maximum concurrent sessions (overrides settings if specified).
    #[arg(long)]
    max_sessions: Option<usize>,
}

impl Cli {
    fn default_db_path() -> PathBuf {
        let home = std::env::var("HOME").unwrap_or_else(|_| "/tmp".to_string());
        PathBuf::from(home)
            .join(".tron")
            .join("database")
            .join("beta-rs.db")
    }
}

fn ensure_parent_dir(path: &std::path::Path) -> Result<()> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)
            .with_context(|| format!("Failed to create directory: {}", parent.display()))?;
    }
    Ok(())
}

/// Resolve the auth file path (`~/.tron/auth.json`).
fn auth_path() -> PathBuf {
    let home = std::env::var("HOME").unwrap_or_else(|_| "/tmp".to_string());
    PathBuf::from(home).join(".tron").join("auth.json")
}

/// Configuration for tool registry creation.
///
/// Captures shared resources (event store, task pool, API keys) so the
/// tool factory closure can create real provider implementations.
struct ToolRegistryConfig {
    event_store: Arc<tron_events::EventStore>,
    task_pool: tron_events::ConnectionPool,
    brave_api_key: Option<String>,
    browser_delegate: Option<Arc<dyn tron_tools::traits::BrowserDelegate>>,
    apns_service: Option<Arc<tron_platform::apns::ApnsService>>,
    embedding_controller: Option<Arc<tokio::sync::Mutex<tron_embeddings::EmbeddingController>>>,
}

/// Create a populated tool registry with built-in tools.
///
/// Called once per agent run to create a fresh registry. Registration matches
/// the TypeScript server:
/// - Tools with real backends use real providers
/// - BrowseTheWeb/NotifyApp: conditionally registered (only with backend)
/// - Communication tools: not registered (not in TS server)
/// - Subagent tools: NOT registered (stubs return "not available", confusing LLM)
fn create_tool_registry(config: &ToolRegistryConfig) -> ToolRegistry {
    use tron_tools::providers::{
        NoOpOpenUrlDelegate, RealFileSystem, ReqwestHttpClient, StubBrowserDelegate,
        StubNotifyDelegate, TokioProcessRunner,
    };

    let fs: Arc<dyn tron_tools::traits::FileSystemOps> = Arc::new(RealFileSystem);
    let runner: Arc<dyn tron_tools::traits::ProcessRunner> = Arc::new(TokioProcessRunner);
    let http: Arc<dyn tron_tools::traits::HttpClient> = Arc::new(ReqwestHttpClient::new());

    // Real providers backed by SQLite
    let mut store_query_builder =
        providers::SqliteEventStoreQuery::new(config.event_store.clone());
    if let Some(ref ec) = config.embedding_controller {
        store_query_builder = store_query_builder.with_embedding_controller(ec.clone());
    }
    let store_query: Arc<dyn tron_tools::traits::EventStoreQuery> =
        Arc::new(store_query_builder);
    let task_mgr: Arc<dyn tron_tools::traits::TaskManagerDelegate> = Arc::new(
        providers::SqliteTaskManagerDelegate::new(config.task_pool.clone()),
    );

    let mut registry = ToolRegistry::new();

    // Registration order matches the TypeScript server exactly:
    // 1–3: Filesystem tools
    registry.register(Arc::new(tron_tools::fs::read::ReadTool::new(fs.clone())));
    registry.register(Arc::new(tron_tools::fs::write::WriteTool::new(fs.clone())));
    registry.register(Arc::new(tron_tools::fs::edit::EditTool::new(fs.clone())));

    // 4: Bash
    registry.register(Arc::new(tron_tools::system::bash::BashTool::new(
        runner.clone(),
    )));

    // 5: Search
    registry.register(Arc::new(
        tron_tools::search::search_tool::SearchTool::new(runner),
    ));

    // 6: Find
    registry.register(Arc::new(tron_tools::fs::find::FindTool::new()));

    // 7: BrowseTheWeb (real CDP delegate if Chrome found, otherwise stub)
    let browser_delegate: Arc<dyn tron_tools::traits::BrowserDelegate> =
        config.browser_delegate.clone().unwrap_or_else(|| Arc::new(StubBrowserDelegate));
    registry.register(Arc::new(
        tron_tools::browser::browse_the_web::BrowseTheWebTool::new(browser_delegate),
    ));

    // 8: AskUserQuestion
    registry.register(Arc::new(
        tron_tools::ui::ask_user::AskUserQuestionTool::new(),
    ));

    // 9: OpenURL — fire-and-forget (iOS opens Safari via tool event)
    let open_url_delegate: Arc<dyn tron_tools::traits::NotifyDelegate> =
        Arc::new(NoOpOpenUrlDelegate);
    registry.register(Arc::new(tron_tools::browser::open_url::OpenURLTool::new(
        open_url_delegate,
    )));

    // 10: RenderAppUI
    registry.register(Arc::new(
        tron_tools::ui::render_app_ui::RenderAppUITool::new(),
    ));

    // 11: TaskManager
    registry.register(Arc::new(
        tron_tools::ui::task_manager::TaskManagerTool::new(task_mgr),
    ));

    // 12: Remember
    registry.register(Arc::new(tron_tools::system::remember::RememberTool::new(
        store_query,
    )));

    // 13: NotifyApp — real APNS when available, stub fallback
    let notify_delegate: Arc<dyn tron_tools::traits::NotifyDelegate> =
        if let Some(ref apns) = config.apns_service {
            Arc::new(providers::ApnsNotifyDelegate::new(
                apns.clone(),
                config.task_pool.clone(),
            ))
        } else {
            Arc::new(StubNotifyDelegate)
        };
    registry.register(Arc::new(tron_tools::ui::notify::NotifyAppTool::new(
        notify_delegate,
    )));

    // 14: WebFetch (always available)
    registry.register(Arc::new(tron_tools::web::web_fetch::WebFetchTool::new(
        http.clone(),
    )));

    // 15: WebSearch — conditional on Brave API key (matches TS server)
    if let Some(ref api_key) = config.brave_api_key {
        registry.register(Arc::new(tron_tools::web::web_search::WebSearchTool::new(
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

    // Database (events + tasks share one SQLite file) — set up before logging
    // so that tracing events are persisted from the start.
    let db_path = args.db_path.unwrap_or_else(Cli::default_db_path);
    ensure_parent_dir(&db_path)?;
    let db_str = db_path.to_string_lossy();
    let pool = tron_events::new_file(&db_str, &ConnectionConfig::default())
        .context("Failed to open database")?;
    {
        let conn = pool.get().context("Failed to get DB connection")?;
        let _ = tron_events::run_migrations(&conn).context("Failed to run event migrations")?;
        tron_tasks::migrations::run_migrations(&conn)
            .context("Failed to run task migrations")?;
    }

    // Load settings early (needed for log level before logging init)
    let settings_path = tron_settings::loader::settings_path();
    let settings = tron_settings::loader::load_settings_from_path(&settings_path)
        .unwrap_or_default();

    // Initialize logging with SQLite persistence (dedicated connection, separate from pool).
    // Must set WAL + busy_timeout to match pool connections — without busy_timeout,
    // concurrent writes from the pool cause immediate SQLITE_BUSY errors.
    let log_conn = rusqlite::Connection::open(&db_path)
        .context("Failed to open logging DB connection")?;
    log_conn
        .execute_batch("PRAGMA journal_mode = WAL; PRAGMA busy_timeout = 5000;")
        .context("Failed to set logging connection pragmas")?;
    let log_handle = tron_logging::init_subscriber_with_sqlite(
        settings.logging.db_log_level.as_filter_str(),
        log_conn,
    );
    let flush_task = tron_logging::spawn_flush_task(log_handle.clone());
    let task_pool = pool.clone();
    let event_store = Arc::new(EventStore::new(pool));

    // Core services
    let max_sessions = args
        .max_sessions
        .unwrap_or(settings.server.max_concurrent_sessions);
    let session_manager = Arc::new(SessionManager::new(event_store.clone()));
    let orchestrator = Arc::new(Orchestrator::new(
        session_manager.clone(),
        max_sessions,
    ));
    let skill_registry = Arc::new(RwLock::new(SkillRegistry::new()));

    // Load Brave API key for web search (matches TS server conditional registration)
    let brave_api_key = tron_auth::storage::get_service_api_keys(&auth_path(), "brave")
        .into_iter()
        .next();
    if brave_api_key.is_some() {
        tracing::info!("Brave API key loaded — WebSearch tool enabled");
    }

    // Browser service (optional — only if Chrome is found)
    let browser_service = tron_browser::chrome::find_chrome().map(|chrome_path| {
        tracing::info!(path = %chrome_path.display(), "Chrome found — browser streaming enabled");
        Arc::new(tron_browser::service::BrowserService::new(chrome_path))
    });
    if browser_service.is_none() {
        tracing::info!("Chrome not found — browser streaming disabled");
    }

    // Browser delegate for tool registry (real CDP if Chrome found)
    let browser_delegate: Option<Arc<dyn tron_tools::traits::BrowserDelegate>> =
        browser_service.as_ref().map(|svc| {
            Arc::new(tron_browser::delegate::CdpBrowserDelegate::new(svc.clone()))
                as Arc<dyn tron_tools::traits::BrowserDelegate>
        });

    // APNS service (optional — only if config exists at ~/.tron/mods/apns/)
    let apns_service: Option<Arc<tron_platform::apns::ApnsService>> =
        tron_platform::apns::load_apns_config().and_then(|apns_config| {
            match tron_platform::apns::ApnsService::new(apns_config) {
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
    if apns_service.is_none() {
        tracing::info!("No APNS config — push notifications disabled");
    }

    // Embedding controller (optional — fire-and-forget ONNX model loading)
    let embedding_controller: Option<Arc<tokio::sync::Mutex<tron_embeddings::EmbeddingController>>> = {
        let emb_settings = &settings.context.memory.embedding;
        if emb_settings.enabled {
            let emb_config = tron_embeddings::EmbeddingConfig::from_settings(emb_settings);
            let mut ctrl = tron_embeddings::EmbeddingController::new(emb_config.clone());

            // Create vector repository with a dedicated connection (VectorRepository owns a
            // raw rusqlite::Connection, not a pooled one, because it's behind parking_lot::Mutex).
            let vec_conn = rusqlite::Connection::open(&db_path)
                .expect("db connection for vectors");
            vec_conn
                .execute_batch("PRAGMA journal_mode = WAL; PRAGMA busy_timeout = 5000;")
                .expect("vector connection pragmas");
            let repo = tron_embeddings::VectorRepository::new(vec_conn, emb_config.dimensions);
            repo.ensure_table().expect("vector table creation");
            ctrl.set_vector_repo(Arc::new(parking_lot::Mutex::new(repo)));

            let ctrl_arc = Arc::new(tokio::sync::Mutex::new(ctrl));

            // Fire-and-forget: load ONNX model + backfill unembedded entries
            let service = Arc::new(tron_embeddings::ort_service::OnnxEmbeddingService::new(emb_config));
            let service_clone = Arc::clone(&service);
            let ctrl_for_init = Arc::clone(&ctrl_arc);

            drop(tokio::spawn(async move {
                if let Err(e) = service_clone.initialize().await {
                    tracing::warn!(error = %e, "embedding service init failed — semantic memory disabled");
                    return;
                }
                ctrl_for_init.lock().await.set_service(service_clone);
                tracing::info!("embedding service ready — semantic memory enabled");
            }));

            tracing::info!("embedding controller created (vector repo ready)");
            Some(ctrl_arc)
        } else {
            tracing::info!("embeddings disabled in settings");
            None
        }
    };

    // Tool registry config (shared resources for per-session tool factories)
    let tool_config = Arc::new(ToolRegistryConfig {
        event_store: event_store.clone(),
        task_pool: task_pool.clone(),
        brave_api_key,
        browser_delegate,
        apns_service,
        embedding_controller: embedding_controller.clone(),
    });

    // Agent dependencies (provider factory + tool factory)
    // The factory creates a fresh provider per request by detecting the provider
    // type from the model ID and loading auth from disk. This means model switches
    // take effect immediately — no server restart needed.
    let provider_factory: Arc<dyn ProviderFactory> =
        Arc::new(provider_factory::DefaultProviderFactory::new(&settings));

    // Verify auth is available for the default model at startup.
    let startup_auth_ok = provider_factory
        .create_for_model(&settings.server.default_model)
        .await
        .is_ok();

    let (agent_deps, shared_subagent_manager) = if startup_auth_ok {
        tracing::info!(
            provider = settings.server.default_provider.as_str(),
            model = settings.server.default_model.as_str(),
            "agent execution enabled"
        );

        // Create SubagentManager (tool_factory set below via OnceCell)
        let subagent_manager = Arc::new(SubagentManager::new(
            session_manager.clone(),
            event_store.clone(),
            orchestrator.broadcast().clone(),
            provider_factory.clone(),
            None,
            None,
        ));

        // Build tool factory that includes subagent tools + summarizer-backed WebFetch
        let config = tool_config.clone();
        let spawner: Arc<dyn tron_tools::traits::SubagentSpawner> = subagent_manager.clone();
        let sm_for_summarizer = subagent_manager.clone();
        let tool_factory: Arc<dyn Fn() -> ToolRegistry + Send + Sync> = Arc::new(move || {
            let mut registry = create_tool_registry(&config);
            registry.register(Arc::new(
                tron_tools::subagent::spawn::SpawnSubagentTool::new(spawner.clone()),
            ));
            registry.register(Arc::new(
                tron_tools::subagent::query::QueryAgentTool::new(spawner.clone()),
            ));
            registry.register(Arc::new(
                tron_tools::subagent::wait::WaitForAgentsTool::new(spawner.clone()),
            ));

            // Re-register WebFetch with LLM summarizer (overrides the basic version)
            let summarizer: Arc<dyn tron_tools::traits::ContentSummarizer> = Arc::new(
                tron_runtime::agent::compaction_handler::SubagentContentSummarizer {
                    manager: sm_for_summarizer.clone(),
                },
            );
            let http: Arc<dyn tron_tools::traits::HttpClient> =
                Arc::new(tron_tools::providers::ReqwestHttpClient::new());
            registry.register(Arc::new(
                tron_tools::web::web_fetch::WebFetchTool::new_with_summarizer(http, summarizer),
            ));

            registry
        });

        // Break circular dep: SubagentManager needs tool_factory to spawn children
        subagent_manager.set_tool_factory(tool_factory.clone());

        (
            Some(AgentDeps {
                provider_factory,
                tool_factory,
                guardrails: None,
                hooks: None,
            }),
            Some(subagent_manager) as Option<Arc<SubagentManager>>,
        )
    } else {
        tracing::warn!("no auth found — agent execution disabled (sign in via the app, or set ANTHROPIC_API_KEY / OPENAI_API_KEY / GOOGLE_API_KEY)");
        (None, None)
    };

    // Native transcription engine (load if model files are cached)
    let transcription_engine = {
        let model_dir = tron_transcription::model::default_model_dir();
        if tron_transcription::model::is_model_cached(&model_dir) {
            tracing::info!("transcription model cached — loading native engine");
            match tron_transcription::TranscriptionEngine::new(model_dir).await {
                Ok(engine) => {
                    tracing::info!("native transcription engine ready");
                    Some(engine)
                }
                Err(e) => {
                    tracing::warn!(error = %e, "failed to load transcription engine, using sidecar fallback");
                    None
                }
            }
        } else {
            tracing::info!("transcription model not cached — sidecar fallback (call transcribe.downloadModel to enable native)");
            None
        }
    };

    // RPC context
    let rpc_context = RpcContext {
        orchestrator: orchestrator.clone(),
        session_manager,
        event_store,
        skill_registry,
        task_pool: Some(task_pool),
        settings_path,
        agent_deps,
        server_start_time: std::time::Instant::now(),
        browser_service: browser_service.clone(),
        transcription_engine,
        embedding_controller,
        subagent_manager: shared_subagent_manager,
    };

    // Method registry
    let mut registry = MethodRegistry::new();
    tron_rpc::handlers::register_all(&mut registry);
    let method_count = registry.methods().len();

    // Server config
    let config = ServerConfig {
        host: args.host,
        port: args.port,
        ..ServerConfig::default()
    };

    // Build and start server
    let server = TronServer::new(config, registry, rpc_context);

    // Event bridge: orchestrator events + browser frames → WebSocket clients
    let browser_rx = browser_service.as_ref().map(|svc| svc.subscribe());
    let bridge = EventBridge::new(orchestrator.subscribe(), server.broadcast().clone(), browser_rx);
    let _bridge_handle = tokio::spawn(bridge.run());

    let (addr, handle) = server
        .listen()
        .await
        .context("Failed to bind server")?;

    tracing::info!(
        "Tron agent listening on http://{addr} ({method_count} RPC methods registered)"
    );

    // Wait for shutdown signal
    tokio::signal::ctrl_c()
        .await
        .context("Failed to listen for ctrl-c")?;

    tracing::info!("Shutting down...");
    server.shutdown().shutdown();
    let _ = handle.await;

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
    use tron_settings::TronSettings;

    #[test]
    fn cli_default_host() {
        let cli = Cli::parse_from(["tron-agent"]);
        assert_eq!(cli.host, "0.0.0.0");
    }

    #[test]
    fn cli_default_port() {
        let cli = Cli::parse_from(["tron-agent"]);
        assert_eq!(cli.port, 9847);
    }

    #[test]
    fn cli_custom_port() {
        let cli = Cli::parse_from(["tron-agent", "--port", "8080"]);
        assert_eq!(cli.port, 8080);
    }

    #[test]
    fn cli_custom_host() {
        let cli = Cli::parse_from(["tron-agent", "--host", "0.0.0.0"]);
        assert_eq!(cli.host, "0.0.0.0");
    }

    #[test]
    fn cli_db_path() {
        let cli = Cli::parse_from(["tron-agent", "--db-path", "/tmp/test.db"]);
        assert_eq!(cli.db_path, Some(PathBuf::from("/tmp/test.db")));
    }

    #[test]
    fn cli_max_sessions() {
        let cli = Cli::parse_from(["tron-agent", "--max-sessions", "20"]);
        assert_eq!(cli.max_sessions, Some(20));
    }

    #[test]
    fn cli_max_sessions_defaults_to_none() {
        let cli = Cli::parse_from(["tron-agent"]);
        assert_eq!(cli.max_sessions, None);
    }

    #[test]
    fn default_db_path_under_tron_dir() {
        let path = Cli::default_db_path();
        assert!(path.to_string_lossy().contains(".tron"));
        assert!(path.to_string_lossy().ends_with("beta-rs.db"));
    }

    #[test]
    fn ensure_parent_dir_creates_nested() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("a").join("b").join("test.db");
        ensure_parent_dir(&path).unwrap();
        assert!(path.parent().unwrap().exists());
    }

    #[tokio::test]
    async fn factory_unknown_model_returns_auth_error() {
        // DefaultProviderFactory defaults unknown models to Anthropic,
        // which returns an auth error when no credentials are available.
        let settings = TronSettings::default();
        let factory = provider_factory::DefaultProviderFactory::new(&settings)
            .with_auth_path(PathBuf::from("/tmp/tron-test-no-such-auth.json"));
        let result = factory.create_for_model("unknown-model").await;
        assert!(result.is_err());
    }

    #[tokio::test]
    async fn openai_returns_none_without_auth() {
        // With no env vars and no auth.json, OpenAI returns None
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("auth.json");
        let result = tron_auth::openai::load_server_auth(&path, None, None)
            .await
            .unwrap();
        assert!(result.is_none());
    }

    #[tokio::test]
    async fn google_returns_none_without_auth() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("auth.json");
        let result = tron_auth::google::load_server_auth(&path, None, None)
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
        let tokens = tron_auth::OAuthTokens {
            access_token: "sk-ant-oat-test".to_string(),
            refresh_token: "ref".to_string(),
            expires_at: tron_auth::now_ms() + 3_600_000,
        };
        tron_auth::storage::save_provider_oauth_tokens(&path, "anthropic", &tokens).unwrap();

        // load_server_auth should find the OAuth tokens
        let config = tron_auth::anthropic::default_config();
        let result = tron_auth::anthropic::load_server_auth(&path, &config, None, None)
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
        tron_auth::storage::save_provider_api_key(&path, "anthropic", "sk-api-key").unwrap();
        let tokens = tron_auth::OAuthTokens {
            access_token: "sk-ant-oat-primary".to_string(),
            refresh_token: "ref".to_string(),
            expires_at: tron_auth::now_ms() + 3_600_000,
        };
        tron_auth::storage::save_provider_oauth_tokens(&path, "anthropic", &tokens).unwrap();

        // OAuth takes priority
        let config = tron_auth::anthropic::default_config();
        let result = tron_auth::anthropic::load_server_auth(&path, &config, None, None)
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
        let work_tokens = tron_auth::OAuthTokens {
            access_token: "work-tok".to_string(),
            refresh_token: "ref1".to_string(),
            expires_at: tron_auth::now_ms() + 3_600_000,
        };
        let personal_tokens = tron_auth::OAuthTokens {
            access_token: "personal-tok".to_string(),
            refresh_token: "ref2".to_string(),
            expires_at: tron_auth::now_ms() + 3_600_000,
        };
        tron_auth::storage::save_account_oauth_tokens(&path, "anthropic", "work", &work_tokens)
            .unwrap();
        tron_auth::storage::save_account_oauth_tokens(
            &path,
            "anthropic",
            "personal",
            &personal_tokens,
        )
        .unwrap();

        let config = tron_auth::anthropic::default_config();

        // Select "personal" account
        let result = tron_auth::anthropic::load_server_auth(&path, &config, None, Some("personal"))
            .await
            .unwrap();
        assert_eq!(result.unwrap().token(), "personal-tok");

        // No preference → first account
        let result = tron_auth::anthropic::load_server_auth(&path, &config, None, None)
            .await
            .unwrap();
        assert_eq!(result.unwrap().token(), "work-tok");
    }

    #[tokio::test]
    async fn create_openai_with_oauth_from_file() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("auth.json");

        let tokens = tron_auth::OAuthTokens {
            access_token: "openai-oauth-tok".to_string(),
            refresh_token: "ref".to_string(),
            expires_at: tron_auth::now_ms() + 3_600_000,
        };
        tron_auth::storage::save_provider_oauth_tokens(
            &path,
            tron_auth::openai::PROVIDER_KEY,
            &tokens,
        )
        .unwrap();

        let result = tron_auth::openai::load_server_auth(&path, None, None)
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

        let gpa = tron_auth::GoogleProviderAuth {
            base: tron_auth::ProviderAuth {
                oauth: Some(tron_auth::OAuthTokens {
                    access_token: "ya29.google-tok".to_string(),
                    refresh_token: "ref".to_string(),
                    expires_at: tron_auth::now_ms() + 3_600_000,
                }),
                ..Default::default()
            },
            endpoint: Some(tron_auth::GoogleOAuthEndpoint::Antigravity),
            ..Default::default()
        };
        tron_auth::storage::save_google_provider_auth(&path, &gpa).unwrap();

        let result = tron_auth::google::load_server_auth(&path, None, None)
            .await
            .unwrap();
        let auth = result.unwrap();
        assert_eq!(auth.auth.token(), "ya29.google-tok");
        assert_eq!(
            auth.endpoint,
            Some(tron_auth::GoogleOAuthEndpoint::Antigravity)
        );
    }

    #[tokio::test]
    async fn server_auth_maps_to_anthropic_oauth_auth() {
        let server_auth = tron_auth::ServerAuth::OAuth {
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
        let server_auth = tron_auth::ServerAuth::from_api_key("sk-123");
        assert!(!server_auth.is_oauth());
        assert_eq!(server_auth.token(), "sk-123");
    }

    #[tokio::test]
    async fn server_boots_and_responds() {
        let dir = tempfile::tempdir().unwrap();
        let db_path = dir.path().join("beta-rs.db");
        let settings_path = dir.path().join("settings.json");

        // Single DB for events + tasks
        let db_str = db_path.to_string_lossy();
        let pool = tron_events::new_file(&db_str, &ConnectionConfig::default()).unwrap();
        {
            let conn = pool.get().unwrap();
            let _ = tron_events::run_migrations(&conn).unwrap();
            tron_tasks::migrations::run_migrations(&conn).unwrap();
        }
        let task_pool = pool.clone();
        let event_store = Arc::new(EventStore::new(pool));

        let session_manager = Arc::new(SessionManager::new(event_store.clone()));
        let orchestrator = Arc::new(Orchestrator::new(session_manager.clone(), 10));
        let skill_registry = Arc::new(RwLock::new(SkillRegistry::new()));

        let rpc_context = RpcContext {
            orchestrator: orchestrator.clone(),
            session_manager,
            event_store,
            skill_registry,
            task_pool: Some(task_pool),
            settings_path,
            agent_deps: None,
            server_start_time: std::time::Instant::now(),
            browser_service: None,
            transcription_engine: None,
            embedding_controller: None,
            subagent_manager: None,
        };

        let mut registry = MethodRegistry::new();
        tron_rpc::handlers::register_all(&mut registry);

        let config = ServerConfig::default();
        let server = TronServer::new(config, registry, rpc_context);

        let bridge = EventBridge::new(orchestrator.subscribe(), server.broadcast().clone(), None);
        let _bridge = tokio::spawn(bridge.run());

        let (addr, handle) = server.listen().await.unwrap();

        // Health check
        let resp = reqwest::get(format!("http://{addr}/health"))
            .await
            .unwrap();
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
        let pool = tron_events::new_file(&db_str, &ConnectionConfig::default()).unwrap();
        let conn = pool.get().unwrap();
        let _ = tron_events::run_migrations(&conn).unwrap();

        assert!(db_path.exists());
    }

    #[test]
    fn server_runs_migrations() {
        let dir = tempfile::tempdir().unwrap();
        let db_path = dir.path().join("test.db");
        let db_str = db_path.to_string_lossy();
        let pool = tron_events::new_file(&db_str, &ConnectionConfig::default()).unwrap();
        let conn = pool.get().unwrap();
        let _ = tron_events::run_migrations(&conn).unwrap();

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
        let pool = tron_events::new_file(&db_str, &ConnectionConfig::default()).unwrap();
        {
            let conn = pool.get().unwrap();
            let _ = tron_events::run_migrations(&conn).unwrap();
            tron_tasks::migrations::run_migrations(&conn).unwrap();
        }
        let event_store = Arc::new(EventStore::new(pool.clone()));
        ToolRegistryConfig {
            event_store,
            task_pool: pool,
            brave_api_key: None,
            browser_delegate: None,
            apns_service: None,
            embedding_controller: None,
        }
    }

    #[test]
    fn tool_registry_order() {
        let config = make_tool_config();
        let registry = create_tool_registry(&config);
        let names = registry.names();
        // First 8 tools must match TS server order exactly
        assert_eq!(names[0], "Read");
        assert_eq!(names[1], "Write");
        assert_eq!(names[2], "Edit");
        assert_eq!(names[3], "Bash");
        assert_eq!(names[4], "Search");
        assert_eq!(names[5], "Find");
        assert_eq!(names[6], "BrowseTheWeb");
        assert_eq!(names[7], "AskUserQuestion");
    }

    #[test]
    fn tool_registry_has_browse_the_web() {
        let config = make_tool_config();
        let registry = create_tool_registry(&config);
        assert!(registry.names().contains(&"BrowseTheWeb".to_string()));
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
        // 15 tools without Brave API key (no WebSearch), without subagent tools
        assert_eq!(registry.len(), 14, "expected 14 tools (no WebSearch without Brave key), got: {:?}", registry.names());
    }

    #[test]
    fn tool_registry_count_with_web_search() {
        let config = ToolRegistryConfig {
            brave_api_key: Some("test-key".into()),
            ..make_tool_config()
        };
        let registry = create_tool_registry(&config);
        assert_eq!(registry.len(), 15, "expected 15 tools with WebSearch, got: {:?}", registry.names());
    }

    #[test]
    fn server_registers_all_rpc_methods() {
        let mut registry = MethodRegistry::new();
        tron_rpc::handlers::register_all(&mut registry);
        // Should have a substantial number of methods registered
        assert!(registry.methods().len() >= 50);
    }

    #[tokio::test]
    async fn server_graceful_shutdown() {
        let dir = tempfile::tempdir().unwrap();
        let db_path = dir.path().join("events.db");
        let db_str = db_path.to_string_lossy();
        let pool = tron_events::new_file(&db_str, &ConnectionConfig::default()).unwrap();
        {
            let conn = pool.get().unwrap();
            let _ = tron_events::run_migrations(&conn).unwrap();
        }
        let event_store = Arc::new(EventStore::new(pool));
        let session_manager = Arc::new(SessionManager::new(event_store.clone()));
        let orchestrator = Arc::new(Orchestrator::new(session_manager.clone(), 10));

        let rpc_context = RpcContext {
            orchestrator,
            session_manager,
            event_store,
            skill_registry: Arc::new(RwLock::new(SkillRegistry::new())),
            task_pool: None,
            settings_path: dir.path().join("settings.json"),
            agent_deps: None,
            server_start_time: std::time::Instant::now(),
            browser_service: None,
            transcription_engine: None,
            embedding_controller: None,
            subagent_manager: None,
        };

        let mut registry = MethodRegistry::new();
        tron_rpc::handlers::register_all(&mut registry);

        let server = TronServer::new(ServerConfig::default(), registry, rpc_context);
        let (_, handle) = server.listen().await.unwrap();

        server.shutdown().shutdown();
        tokio::time::timeout(std::time::Duration::from_secs(5), handle)
            .await
            .expect("shutdown timed out")
            .expect("join error");
    }
}
