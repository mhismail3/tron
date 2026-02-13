//! # tron-agent
//!
//! Tron agent server binary — wires together all crates and starts the
//! HTTP/WebSocket server.

#![deny(unsafe_code)]

use std::path::PathBuf;
use std::sync::Arc;

use anyhow::{Context, Result};
use clap::Parser;
use parking_lot::RwLock;
use tron_events::{ConnectionConfig, EventStore};
use tron_rpc::context::RpcContext;
use tron_rpc::registry::MethodRegistry;
use tron_runtime::orchestrator::orchestrator::Orchestrator;
use tron_runtime::orchestrator::session_manager::SessionManager;
use tron_server::config::ServerConfig;
use tron_server::server::TronServer;
use tron_server::websocket::event_bridge::EventBridge;
use tron_skills::registry::SkillRegistry;

/// Tron agent server.
#[derive(Parser, Debug)]
#[command(name = "tron-agent", about = "Tron agent server")]
struct Cli {
    /// Host to bind.
    #[arg(long, default_value = "127.0.0.1")]
    host: String,

    /// Port to bind (0 for auto-assign).
    #[arg(long, default_value = "9847")]
    port: u16,

    /// Path to the event database.
    #[arg(long)]
    db_path: Option<PathBuf>,

    /// Path to the task database.
    #[arg(long)]
    task_db_path: Option<PathBuf>,

    /// Maximum concurrent sessions.
    #[arg(long, default_value = "10")]
    max_sessions: usize,
}

impl Cli {
    fn default_db_path() -> PathBuf {
        let home = std::env::var("HOME").unwrap_or_else(|_| "/tmp".to_string());
        PathBuf::from(home)
            .join(".tron")
            .join("database")
            .join("prod.db")
    }

    fn default_task_db_path() -> PathBuf {
        let home = std::env::var("HOME").unwrap_or_else(|_| "/tmp".to_string());
        PathBuf::from(home)
            .join(".tron")
            .join("database")
            .join("tasks.db")
    }
}

fn ensure_parent_dir(path: &std::path::Path) -> Result<()> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)
            .with_context(|| format!("Failed to create directory: {}", parent.display()))?;
    }
    Ok(())
}

#[tokio::main]
async fn main() -> Result<()> {
    let args = Cli::parse();

    // Initialize logging
    tron_logging::init_subscriber("info");

    // Load settings
    let settings_path = tron_settings::loader::settings_path();

    // Event database
    let db_path = args.db_path.unwrap_or_else(Cli::default_db_path);
    ensure_parent_dir(&db_path)?;
    let db_str = db_path.to_string_lossy();
    let pool = tron_events::new_file(&db_str, &ConnectionConfig::default())
        .context("Failed to open event database")?;
    {
        let conn = pool.get().context("Failed to get DB connection")?;
        let _ = tron_events::run_migrations(&conn).context("Failed to run event migrations")?;
    }
    let event_store = Arc::new(EventStore::new(pool));

    // Task database (separate SQLite file)
    let task_db_path = args.task_db_path.unwrap_or_else(Cli::default_task_db_path);
    ensure_parent_dir(&task_db_path)?;
    let task_db_str = task_db_path.to_string_lossy();
    let task_pool = tron_events::new_file(&task_db_str, &ConnectionConfig::default())
        .context("Failed to open task database")?;
    {
        let conn = task_pool.get().context("Failed to get task DB connection")?;
        tron_tasks::migrations::run_migrations(&conn)
            .context("Failed to run task migrations")?;
    }

    // Core services
    let session_manager = Arc::new(SessionManager::new(event_store.clone()));
    let orchestrator = Arc::new(Orchestrator::new(
        session_manager.clone(),
        args.max_sessions,
    ));
    let skill_registry = Arc::new(RwLock::new(SkillRegistry::new()));

    // RPC context
    let rpc_context = RpcContext {
        orchestrator: orchestrator.clone(),
        session_manager,
        event_store,
        skill_registry,
        task_pool: Some(task_pool),
        settings_path,
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

    // Event bridge: orchestrator events → WebSocket clients
    let bridge = EventBridge::new(orchestrator.subscribe(), server.broadcast().clone());
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

    tracing::info!("Shutdown complete");
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use clap::Parser;

    #[test]
    fn cli_default_host() {
        let cli = Cli::parse_from(["tron-agent"]);
        assert_eq!(cli.host, "127.0.0.1");
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
    fn cli_task_db_path() {
        let cli = Cli::parse_from(["tron-agent", "--task-db-path", "/tmp/tasks.db"]);
        assert_eq!(cli.task_db_path, Some(PathBuf::from("/tmp/tasks.db")));
    }

    #[test]
    fn cli_max_sessions() {
        let cli = Cli::parse_from(["tron-agent", "--max-sessions", "20"]);
        assert_eq!(cli.max_sessions, 20);
    }

    #[test]
    fn default_db_path_under_tron_dir() {
        let path = Cli::default_db_path();
        assert!(path.to_string_lossy().contains(".tron"));
        assert!(path.to_string_lossy().ends_with("prod.db"));
    }

    #[test]
    fn default_task_db_path_under_tron_dir() {
        let path = Cli::default_task_db_path();
        assert!(path.to_string_lossy().contains(".tron"));
        assert!(path.to_string_lossy().ends_with("tasks.db"));
    }

    #[test]
    fn ensure_parent_dir_creates_nested() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("a").join("b").join("test.db");
        ensure_parent_dir(&path).unwrap();
        assert!(path.parent().unwrap().exists());
    }

    #[tokio::test]
    async fn server_boots_and_responds() {
        let dir = tempfile::tempdir().unwrap();
        let db_path = dir.path().join("events.db");
        let task_db_path = dir.path().join("tasks.db");
        let settings_path = dir.path().join("settings.json");

        // Event DB
        let db_str = db_path.to_string_lossy();
        let pool = tron_events::new_file(&db_str, &ConnectionConfig::default()).unwrap();
        {
            let conn = pool.get().unwrap();
            let _ = tron_events::run_migrations(&conn).unwrap();
        }
        let event_store = Arc::new(EventStore::new(pool));

        // Task DB
        let task_db_str = task_db_path.to_string_lossy();
        let task_pool =
            tron_events::new_file(&task_db_str, &ConnectionConfig::default()).unwrap();
        {
            let conn = task_pool.get().unwrap();
            tron_tasks::migrations::run_migrations(&conn).unwrap();
        }

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
        };

        let mut registry = MethodRegistry::new();
        tron_rpc::handlers::register_all(&mut registry);

        let config = ServerConfig::default();
        let server = TronServer::new(config, registry, rpc_context);

        let bridge = EventBridge::new(orchestrator.subscribe(), server.broadcast().clone());
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
