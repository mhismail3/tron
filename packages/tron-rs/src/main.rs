use std::path::PathBuf;

use tokio::sync::broadcast;
use tron_core::events::AgentEvent;
use tron_store::Database;
use tron_store::workspaces::WorkspaceRepo;

#[tokio::main]
async fn main() {
    // Initialize logging
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| tracing_subscriber::EnvFilter::new("info")),
        )
        .init();

    tracing::info!("Starting Tron Rust server");

    // Database path
    let tron_dir = dirs_home().join(".tron").join("database");
    std::fs::create_dir_all(&tron_dir).expect("Failed to create database directory");
    let db_path = tron_dir.join("rs.db");

    let db = Database::open(&db_path).expect("Failed to open database");
    tracing::info!(path = %db_path.display(), "Database opened");

    // Get or create default workspace
    let cwd = std::env::current_dir().unwrap_or_else(|_| PathBuf::from("/tmp"));
    let ws_repo = WorkspaceRepo::new(db.clone());
    let workspace = ws_repo
        .get_or_create(
            cwd.to_str().unwrap_or("/tmp"),
            cwd.file_name()
                .and_then(|n| n.to_str())
                .unwrap_or("default"),
        )
        .expect("Failed to create workspace");

    // Event broadcast channel
    let (event_tx, _) = broadcast::channel::<AgentEvent>(1024);

    // Start server
    let config = tron_server::ServerConfig::default();
    let port = config.port;
    let _handle = tron_server::start(config, db, workspace.id, event_tx)
        .await
        .expect("Failed to start server");

    tracing::info!(port = port, "Tron server ready");

    // Wait for shutdown signal
    tokio::signal::ctrl_c()
        .await
        .expect("Failed to listen for ctrl+c");

    tracing::info!("Shutting down");
}

fn dirs_home() -> PathBuf {
    std::env::var("HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|_| PathBuf::from("/tmp"))
}
