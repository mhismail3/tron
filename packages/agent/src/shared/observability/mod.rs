//! Structured logging with `tracing` and optional `SQLite` transport.
//!
//! This module provides:
//! - a crate-internal `LogLevel` enum with stable numeric values for persistence
//! - managed `tracing` subscriber setup for terminal and database diagnostics
//!
//! # Architecture
//!
//! Uses the `tracing` ecosystem for structured logging. Log context (session ID,
//! component, trace ID) is propagated via tracing spans rather than
//! `AsyncLocalStorage` (the TypeScript approach).
//!
//! The `SQLite` transport is implemented as a tracing [`Layer`] that batches
//! log writes for efficiency. Warn/error/fatal levels flush immediately.
//! Before persistence, server-side messages, structured data, and error fields
//! pass through the shared sensitive-content redactor. Call sites should still
//! log durable IDs, counts, statuses, and hashes instead of prompt/output/file
//! content; transport redaction is the boundary backstop, not a reason to log
//! raw content.
//! Persisted database diagnostics use a managed `info` level and managed
//! dependency filters. Optional terminal output may honor `RUST_LOG`, but
//! neither ambient environment nor settings updates can alter persisted
//! evidence filtering.
//!
//! [`Layer`]: tracing_subscriber::Layer

pub mod test_utils;
mod transport;
mod types;

pub use test_utils::{CapturedLogs, capture_logs};
pub(crate) use transport::TransportHandle;
use transport::{SqliteTransport, TransportConfig};
pub(crate) use types::LogLevel;

/// Managed default verbosity for persisted engine diagnostics.
pub const DEFAULT_DATABASE_LOG_LEVEL: &str = "info";

/// Managed per-module filters required for stable runtime diagnostics.
pub const MANAGED_MODULE_OVERRIDES: &[(&str, &str)] = &[("ort", "error")];

fn managed_database_filter_directives() -> String {
    use std::fmt::Write;

    let mut directives = DEFAULT_DATABASE_LOG_LEVEL.to_owned();
    for (module, level) in MANAGED_MODULE_OVERRIDES {
        let _ = write!(directives, ",{module}={level}");
    }
    directives
}

fn managed_database_filter() -> tracing_subscriber::EnvFilter {
    tracing_subscriber::EnvFilter::new(managed_database_filter_directives())
}

fn terminal_filter() -> tracing_subscriber::EnvFilter {
    tracing_subscriber::EnvFilter::try_from_default_env()
        .unwrap_or_else(|_| managed_database_filter())
}

#[cfg(test)]
mod policy_tests {
    use super::*;

    #[test]
    fn managed_diagnostics_preserve_runtime_defaults() {
        assert_eq!(DEFAULT_DATABASE_LOG_LEVEL, "info");
        assert_eq!(MANAGED_MODULE_OVERRIDES, &[("ort", "error")]);
        assert_eq!(managed_database_filter_directives(), "info,ort=error");
    }

    #[test]
    fn database_filter_cannot_read_terminal_environment_policy() {
        let source = include_str!("mod.rs");
        let database_filter_body = source
            .split("fn managed_database_filter()")
            .nth(1)
            .unwrap()
            .split("fn terminal_filter()")
            .next()
            .unwrap();

        assert!(!database_filter_body.contains("try_from_default_env"));
        assert!(source.contains("let database_filter = managed_database_filter();"));
        assert!(source.contains("let terminal_filter = terminal_filter();"));
    }
}

/// Initialize the global tracing subscriber with optional stderr output AND `SQLite` persistence.
///
/// Composes an optional `fmt` layer (stderr) with [`SqliteTransport`] (database)
/// on a shared [`tracing_subscriber::Registry`]. The database layer always uses
/// the managed filter; `RUST_LOG` applies only to the optional terminal layer.
/// Call once at application startup.
///
/// Returns a [`TransportHandle`] for manual flushing and shutdown cleanup.
///
/// # Arguments
///
/// * `conn` - A [`rusqlite::Connection`] with the `logs` table already created.
/// * `enable_fmt` - When `true`, also writes human-readable logs to stderr.
///   Pass `false` for background/daemon mode where only DB persistence is needed.
pub(crate) fn init_subscriber_with_sqlite(
    conn: rusqlite::Connection,
    enable_fmt: bool,
) -> TransportHandle {
    use tracing_subscriber::Layer as _;
    use tracing_subscriber::layer::SubscriberExt;
    use tracing_subscriber::util::SubscriberInitExt;

    let database_filter = managed_database_filter();

    let fmt_layer = enable_fmt.then(|| {
        let terminal_filter = terminal_filter();
        tracing_subscriber::fmt::layer()
            .with_target(true)
            .with_writer(std::io::stderr)
            .compact()
            .with_filter(terminal_filter)
    });

    let config = TransportConfig {
        min_level: LogLevel::from_str_lossy(DEFAULT_DATABASE_LOG_LEVEL).as_num(),
        ..Default::default()
    };
    let transport = SqliteTransport::new(conn, config);
    let handle = transport.handle();

    let _ = tracing_subscriber::registry()
        .with(fmt_layer)
        .with(transport.with_filter(database_filter))
        .try_init();

    handle
}

/// Spawn a periodic flush task for the log transport.
///
/// Flushes pending log entries to `SQLite` at the configured interval (default 1s).
/// Returns a [`tokio::task::JoinHandle`] — abort it on shutdown after a final
/// [`TransportHandle::flush`].
pub(crate) fn spawn_flush_task(handle: TransportHandle) -> tokio::task::JoinHandle<()> {
    let interval_ms = TransportConfig::default().flush_interval_ms;
    tokio::spawn(async move {
        let mut interval = tokio::time::interval(std::time::Duration::from_millis(interval_ms));
        loop {
            let _ = interval.tick().await;
            handle.flush();
        }
    })
}
