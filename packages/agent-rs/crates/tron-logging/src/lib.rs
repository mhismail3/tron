//! # tron-logging
//!
//! Structured logging with `tracing` and optional `SQLite` transport.
//!
//! This crate provides:
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

#![deny(unsafe_code)]

pub mod store;
pub mod transport;
pub mod types;

pub use store::LogStore;
pub use transport::{SqliteTransport, TransportConfig, TransportHandle};
pub use types::{LogEntry, LogLevel, LogQueryOptions};

/// Initialize the global tracing subscriber with stderr output.
///
/// Call once at application startup. Subsequent calls are no-ops.
/// The subscriber writes human-readable output to stderr.
///
/// # Arguments
///
/// * `level` - Minimum log level to display. Defaults to `"warn"`.
pub fn init_subscriber(level: &str) {
    use tracing_subscriber::EnvFilter;

    let filter = EnvFilter::try_from_default_env()
        .unwrap_or_else(|_| EnvFilter::new(level));

    let subscriber = tracing_subscriber::fmt()
        .with_env_filter(filter)
        .with_target(true)
        .with_writer(std::io::stderr)
        .compact();

    // set_global_default is a no-op if already set
    let _ = subscriber.try_init();
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
