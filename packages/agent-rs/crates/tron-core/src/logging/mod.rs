//! Structured logging with `tracing` and optional `SQLite` transport.
//!
//! This module provides:
//! - [`LogLevel`] enum with numeric values matching the TypeScript logging system
//! - [`LogEntry`] for reading stored logs from `SQLite`
//! - [`LogStore`] for querying persisted logs with filters and full-text search
//! - [`init_subscriber`] for setting up the `tracing` subscriber
//!
//! # Architecture
//!
//! Uses the `tracing` ecosystem for structured logging. Log context (session ID,
//! component, trace ID) is propagated via tracing spans rather than
//! `AsyncLocalStorage` (the TypeScript approach).
//!
//! The `SQLite` transport is implemented as a tracing [`Layer`] that batches
//! log writes for efficiency. Warn/error/fatal levels flush immediately.
//!
//! [`Layer`]: tracing_subscriber::Layer

pub mod store;
pub mod test_utils;
pub mod transport;
pub mod types;

pub use store::LogStore;
pub use test_utils::{CapturedLogs, capture_logs};
pub use transport::{SqliteTransport, TransportConfig, TransportHandle};
pub use types::{LogEntry, LogLevel, LogQueryOptions};

/// Initialize the global tracing subscriber with stderr output only.
///
/// Call once at application startup. Subsequent calls are no-ops.
/// The subscriber writes human-readable output to stderr.
///
/// # Arguments
///
/// * `level` - Minimum log level to display. Defaults to `"warn"`.
pub fn init_subscriber(level: &str) {
    use tracing_subscriber::EnvFilter;

    let filter = EnvFilter::try_from_default_env().unwrap_or_else(|_| EnvFilter::new(level));

    let subscriber = tracing_subscriber::fmt()
        .with_env_filter(filter)
        .with_target(true)
        .with_writer(std::io::stderr)
        .compact();

    // set_global_default is a no-op if already set
    let _ = subscriber.try_init();
}

/// Initialize the global tracing subscriber with stderr output AND `SQLite` persistence.
///
/// Composes a `fmt` layer (stderr) with [`SqliteTransport`] (database) on a
/// shared [`tracing_subscriber::Registry`]. Call once at application startup.
///
/// Returns a [`TransportHandle`] for manual flushing and shutdown cleanup.
///
/// # Arguments
///
/// * `level` - Minimum log level to display/persist.
/// * `conn` - A [`rusqlite::Connection`] with the `logs` table already created.
pub fn init_subscriber_with_sqlite(level: &str, conn: rusqlite::Connection) -> TransportHandle {
    use tracing_subscriber::EnvFilter;
    use tracing_subscriber::layer::SubscriberExt;
    use tracing_subscriber::util::SubscriberInitExt;

    let filter = EnvFilter::try_from_default_env().unwrap_or_else(|_| EnvFilter::new(level));

    let fmt_layer = tracing_subscriber::fmt::layer()
        .with_target(true)
        .with_writer(std::io::stderr)
        .compact();

    let transport = SqliteTransport::new(conn, TransportConfig::default());
    let handle = transport.handle();

    let _ = tracing_subscriber::registry()
        .with(filter)
        .with(fmt_layer)
        .with(transport)
        .try_init();

    handle
}

/// Spawn a periodic flush task for the log transport.
///
/// Flushes pending log entries to `SQLite` at the configured interval (default 1s).
/// Returns a [`tokio::task::JoinHandle`] — abort it on shutdown after a final
/// [`TransportHandle::flush`].
pub fn spawn_flush_task(handle: TransportHandle) -> tokio::task::JoinHandle<()> {
    let interval_ms = TransportConfig::default().flush_interval_ms;
    tokio::spawn(async move {
        let mut interval = tokio::time::interval(std::time::Duration::from_millis(interval_ms));
        loop {
            let _ = interval.tick().await;
            handle.flush();
        }
    })
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn re_exports_work() {
        let _level = LogLevel::Info;
        let _opts = LogQueryOptions::default();
    }

    #[test]
    fn init_subscriber_does_not_panic() {
        // Multiple calls should be safe (no-op after first)
        init_subscriber("warn");
        init_subscriber("debug");
    }
}
