use std::path::PathBuf;
use std::sync::Arc;

use clap::Parser;
use tokio::sync::broadcast;
use tron_core::events::AgentEvent;
use tron_engine::hooks::HookEngine;
use tron_server::AgentOrchestrator;
use tron_store::Database;
use tron_store::workspaces::WorkspaceRepo;
use tron_telemetry::TelemetryConfig;

#[derive(Parser)]
#[command(name = "tron-rs", about = "Tron Rust server")]
struct Args {
    /// Port to listen on.
    #[arg(long, default_value_t = 9091)]
    port: u16,

    /// Log level (trace, debug, info, warn, error).
    #[arg(long, default_value = "info")]
    log_level: String,

    /// Path to the SQLite database file. Defaults to ~/.tron/database/rs.db.
    #[arg(long)]
    db_path: Option<PathBuf>,

    /// Working directory for the default workspace. Defaults to current directory.
    #[arg(long)]
    working_directory: Option<PathBuf>,
}

#[tokio::main]
async fn main() {
    let args = Args::parse();

    // Initialize telemetry (logging + metrics)
    let telemetry_config = TelemetryConfig::default();
    let telemetry_guard = tron_telemetry::init_telemetry(telemetry_config);
    let telemetry = Arc::new(telemetry_guard);

    tracing::info!(port = args.port, log_level = %args.log_level, "Starting Tron Rust server");

    // Database path
    let db_path = match args.db_path {
        Some(p) => p,
        None => {
            let db_dir = dirs_home().join(".tron").join("database");
            std::fs::create_dir_all(&db_dir).expect("Failed to create database directory");
            db_dir.join("rs.db")
        }
    };

    let db = Database::open(&db_path).expect("Failed to open database");
    tracing::info!(path = %db_path.display(), "Database opened");

    // Working directory for the default workspace
    let cwd = args
        .working_directory
        .unwrap_or_else(|| std::env::current_dir().unwrap_or_else(|_| PathBuf::from("/tmp")));

    // Get or create default workspace
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

    // Resolve LLM provider
    let auth_path = dirs_home().join(".tron").join("mods").join("anthropic-oauth.json");
    let provider: Arc<dyn tron_core::provider::LlmProvider> =
        match tron_llm::auth::resolve_anthropic_auth(&auth_path) {
            Some(auth) => {
                tracing::info!("Anthropic auth resolved");
                let anthropic = tron_llm::AnthropicProvider::new(auth, None);
                Arc::new(tron_llm::ReliableProvider::with_defaults(anthropic))
            }
            None => {
                tracing::warn!(
                    "No Anthropic auth found — agent prompts will fail with auth error"
                );
                Arc::new(tron_llm::NoAuthProvider)
            }
        };

    // Build orchestrator
    let hook_engine = Arc::new(HookEngine::new());
    let orchestrator = Arc::new(tron_server::EngineOrchestrator::new(
        provider,
        db.clone(),
        event_tx.clone(),
        hook_engine,
    ));

    // Start server
    let config = tron_server::ServerConfig {
        port: args.port,
        ..Default::default()
    };
    let handle = tron_server::start_with_telemetry(
        config,
        db,
        workspace.id,
        event_tx,
        Some(telemetry),
        Some(orchestrator.clone()),
    )
    .await
    .expect("Failed to start server");

    tracing::info!(port = handle.port, "Tron server ready");

    // Wait for shutdown signal (SIGTERM or SIGINT/Ctrl+C)
    wait_for_shutdown_signal().await;

    tracing::info!("Shutdown signal received");

    // Phase 1: Cancel all active agent runs
    let cancelled = orchestrator.abort_all();
    if cancelled > 0 {
        tracing::info!(cancelled = cancelled, "Cancelled active agent runs");
    }

    // Phase 2: Stop accepting new connections
    handle.shutdown();

    // Phase 3: Wait for in-flight work to complete (with timeout)
    if tokio::time::timeout(std::time::Duration::from_secs(10), handle.drain())
        .await
        .is_err()
    {
        tracing::warn!("Server drain timed out after 10s");
    }

    tracing::info!("Shutdown complete");
    // TelemetryGuard dropped here → flushes logs + metrics
}

async fn wait_for_shutdown_signal() {
    #[cfg(unix)]
    {
        use tokio::signal::unix::{signal, SignalKind};
        let mut sigterm =
            signal(SignalKind::terminate()).expect("Failed to install SIGTERM handler");
        tokio::select! {
            _ = tokio::signal::ctrl_c() => {},
            _ = sigterm.recv() => {},
        }
    }

    #[cfg(not(unix))]
    {
        tokio::signal::ctrl_c()
            .await
            .expect("Failed to listen for ctrl+c");
    }
}

fn dirs_home() -> PathBuf {
    std::env::var("HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|_| PathBuf::from("/tmp"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cli_parses_port_argument() {
        let args = Args::parse_from(["tron-rs", "--port", "8080"]);
        assert_eq!(args.port, 8080);
    }

    #[test]
    fn cli_default_values() {
        let args = Args::parse_from(["tron-rs"]);
        assert_eq!(args.port, 9091);
        assert_eq!(args.log_level, "info");
        assert!(args.db_path.is_none());
        assert!(args.working_directory.is_none());
    }

    #[test]
    fn cli_parses_db_path() {
        let args = Args::parse_from(["tron-rs", "--db-path", "/tmp/test.db"]);
        assert_eq!(args.db_path, Some(PathBuf::from("/tmp/test.db")));
    }

    #[test]
    fn cli_parses_working_directory() {
        let args = Args::parse_from(["tron-rs", "--working-directory", "/home/user/project"]);
        assert_eq!(
            args.working_directory,
            Some(PathBuf::from("/home/user/project"))
        );
    }
}
