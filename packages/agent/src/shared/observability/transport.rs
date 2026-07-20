//! `SQLite` write transport for `tracing` events.
//!
//! [`SqliteTransport`] implements [`tracing_subscriber::Layer`] to capture log
//! events and write them to the `logs` table in batched transactions.
//!
//! # Batching Strategy
//!
//! - Events are accumulated in an internal buffer.
//! - **Immediate flush attempt** for warn, error, or fatal (`level_num` >= 40).
//! - **Threshold flush attempt** at `batch_size` (default 100).
//! - **Periodic retry** via a Tokio interval task (default 1 second).
//! - All flushes write the entire batch in one `SQLite` transaction; a failed
//!   transaction retains every entry for a later attempt.
//!
//! # Span Context
//!
//! Context fields (`session_id`, `workspace_id`, `component`, `trace_id`,
//! `parent_trace_id`, `depth`) are propagated via tracing span fields.
//! The transport walks the span stack for each event to collect context.

use std::sync::{Arc, Mutex};

use rusqlite::Connection;
use tracing::Subscriber;
use tracing::field::{Field, Visit};
use tracing_subscriber::Layer;
use tracing_subscriber::layer::Context;
use tracing_subscriber::registry::LookupSpan;

use crate::shared::foundation::redaction::redact_sensitive_content;

use super::types::LogLevel;

/// Configuration for the `SQLite` transport.
#[derive(Clone, Debug)]
pub(super) struct TransportConfig {
    /// Minimum level to persist (numeric). Default: 30 (info).
    pub(super) min_level: i32,
    /// Number of entries before batch flush. Default: 100.
    pub(super) batch_size: usize,
    /// Flush interval in milliseconds. Default: 1000.
    pub(super) flush_interval_ms: u64,
    /// Maximum time a diagnostic write waits on another SQLite writer.
    /// Pending entries remain queued for a later flush after this timeout.
    pub(super) busy_timeout_ms: u64,
}

impl Default for TransportConfig {
    fn default() -> Self {
        Self {
            min_level: LogLevel::Info.as_num(),
            batch_size: 100,
            flush_interval_ms: 1000,
            busy_timeout_ms: 50,
        }
    }
}

/// A pending log entry awaiting batch flush.
#[derive(Clone, Debug)]
struct PendingEntry {
    timestamp: String,
    level: String,
    level_num: i32,
    component: String,
    message: String,
    session_id: Option<String>,
    workspace_id: Option<String>,
    event_id: Option<String>,
    turn: Option<i64>,
    trace_id: Option<String>,
    parent_trace_id: Option<String>,
    depth: Option<i32>,
    data: Option<String>,
    error_message: Option<String>,
    error_stack: Option<String>,
}

/// Inner state shared between the layer and the flush task.
struct TransportInner {
    batch: Vec<PendingEntry>,
    conn: Connection,
}

/// `SQLite` write transport for the `tracing` subscriber.
///
/// Captures log events, batches them, and writes to the `logs` table in
/// transactions. Use [`SqliteTransport::new`] to create, then register as a
/// `tracing_subscriber::Layer`.
pub(super) struct SqliteTransport {
    inner: Arc<Mutex<TransportInner>>,
    config: TransportConfig,
}

impl SqliteTransport {
    /// Create a new transport with the given connection and config.
    ///
    /// The connection must have the `logs` table already created
    /// (via events migrations).
    pub(super) fn new(conn: Connection, config: TransportConfig) -> rusqlite::Result<Self> {
        conn.busy_timeout(std::time::Duration::from_millis(config.busy_timeout_ms))?;
        Ok(Self {
            inner: Arc::new(Mutex::new(TransportInner {
                batch: Vec::with_capacity(config.batch_size),
                conn,
            })),
            config,
        })
    }

    /// Get a handle for manual flushing and shutdown.
    pub(super) fn handle(&self) -> TransportHandle {
        TransportHandle {
            inner: Arc::clone(&self.inner),
        }
    }

    /// Flush the current batch to `SQLite`.
    fn flush_batch(inner: &Mutex<TransportInner>) -> bool {
        let mut guard = match inner.lock() {
            Ok(g) => g,
            Err(poisoned) => poisoned.into_inner(),
        };

        if guard.batch.is_empty() {
            return true;
        }

        flush_locked(&mut guard)
    }
}

/// Handle for flushing/shutdown from outside the layer.
#[derive(Clone)]
pub(crate) struct TransportHandle {
    inner: Arc<Mutex<TransportInner>>,
}

impl TransportHandle {
    /// Flush any pending log entries to `SQLite`.
    pub(crate) fn flush(&self) -> bool {
        SqliteTransport::flush_batch(&self.inner)
    }

    /// Retry the complete pending batch until it commits or the shutdown
    /// deadline expires. Runtime flushing stays non-blocking beyond the short
    /// connection timeout; only final shutdown uses this bounded drain.
    pub(crate) fn flush_until_empty(&self, deadline: std::time::Duration) -> bool {
        let started = std::time::Instant::now();
        loop {
            if self.flush() {
                return true;
            }
            let elapsed = started.elapsed();
            if elapsed >= deadline {
                return false;
            }
            std::thread::sleep(
                std::time::Duration::from_millis(25).min(deadline.saturating_sub(elapsed)),
            );
        }
    }

    /// Number of entries still awaiting a durable commit.
    pub(crate) fn pending_count(&self) -> usize {
        match self.inner.lock() {
            Ok(guard) => guard.batch.len(),
            Err(poisoned) => poisoned.into_inner().batch.len(),
        }
    }
}

/// Span context fields collected during event processing.
#[derive(Default)]
struct SpanContext {
    session_id: Option<String>,
    workspace_id: Option<String>,
    component: Option<String>,
    trace_id: Option<String>,
    parent_trace_id: Option<String>,
    depth: Option<i32>,
    event_id: Option<String>,
    turn: Option<i64>,
}

/// Visitor that extracts known fields from span attributes.
struct SpanFieldVisitor<'a> {
    ctx: &'a mut SpanContext,
}

impl Visit for SpanFieldVisitor<'_> {
    fn record_str(&mut self, field: &Field, value: &str) {
        match field.name() {
            "session_id" => self.ctx.session_id = Some(value.to_string()),
            "workspace_id" => self.ctx.workspace_id = Some(value.to_string()),
            "component" => self.ctx.component = Some(value.to_string()),
            "trace_id" => self.ctx.trace_id = Some(value.to_string()),
            "parent_trace_id" => self.ctx.parent_trace_id = Some(value.to_string()),
            "event_id" => self.ctx.event_id = Some(value.to_string()),
            _ => {}
        }
    }

    fn record_i64(&mut self, field: &Field, value: i64) {
        match field.name() {
            "depth" => self.ctx.depth = i32::try_from(value).ok(),
            "turn" => self.ctx.turn = Some(value),
            _ => {}
        }
    }

    fn record_debug(&mut self, _field: &Field, _value: &dyn std::fmt::Debug) {}
}

/// Visitor that extracts fields from a tracing event.
struct EventFieldVisitor {
    message: Option<String>,
    error_message: Option<String>,
    error_stack: Option<String>,
    data: serde_json::Map<String, serde_json::Value>,
}

impl EventFieldVisitor {
    fn new() -> Self {
        Self {
            message: None,
            error_message: None,
            error_stack: None,
            data: serde_json::Map::new(),
        }
    }
}

impl Visit for EventFieldVisitor {
    fn record_str(&mut self, field: &Field, value: &str) {
        let redacted = redact_log_text(value);
        match field.name() {
            "message" => self.message = Some(redacted),
            "error.message" | "error_message" => {
                self.error_message = Some(redacted);
            }
            "error.stack" | "error_stack" => self.error_stack = Some(redacted),
            name => {
                let _ = self
                    .data
                    .insert(name.to_string(), serde_json::Value::String(redacted));
            }
        }
    }

    fn record_i64(&mut self, field: &Field, value: i64) {
        let _ = self.data.insert(
            field.name().to_string(),
            serde_json::Value::Number(value.into()),
        );
    }

    fn record_bool(&mut self, field: &Field, value: bool) {
        let _ = self
            .data
            .insert(field.name().to_string(), serde_json::Value::Bool(value));
    }

    fn record_f64(&mut self, field: &Field, value: f64) {
        if let Some(n) = serde_json::Number::from_f64(value) {
            let _ = self
                .data
                .insert(field.name().to_string(), serde_json::Value::Number(n));
        }
    }

    fn record_debug(&mut self, field: &Field, value: &dyn std::fmt::Debug) {
        let redacted = redact_log_text(&format!("{value:?}"));
        if field.name() == "message" {
            self.message = Some(redacted);
        } else {
            let _ = self.data.insert(
                field.name().to_string(),
                serde_json::Value::String(redacted),
            );
        }
    }
}

impl<S> Layer<S> for SqliteTransport
where
    S: Subscriber + for<'a> LookupSpan<'a>,
{
    fn on_event(&self, event: &tracing::Event<'_>, ctx: Context<'_, S>) {
        let level = LogLevel::from_tracing(event.metadata().level());
        let level_num = level.as_num();

        if level_num < self.config.min_level {
            return;
        }

        // Collect span context
        let mut span_ctx = SpanContext::default();
        if let Some(scope) = ctx.event_scope(event) {
            for span in scope {
                let extensions = span.extensions();
                if let Some(fields) = extensions.get::<SpanContext>() {
                    if span_ctx.session_id.is_none() {
                        span_ctx.session_id.clone_from(&fields.session_id);
                    }
                    if span_ctx.workspace_id.is_none() {
                        span_ctx.workspace_id.clone_from(&fields.workspace_id);
                    }
                    if span_ctx.component.is_none() {
                        span_ctx.component.clone_from(&fields.component);
                    }
                    if span_ctx.trace_id.is_none() {
                        span_ctx.trace_id.clone_from(&fields.trace_id);
                    }
                    if span_ctx.parent_trace_id.is_none() {
                        span_ctx.parent_trace_id.clone_from(&fields.parent_trace_id);
                    }
                    if span_ctx.depth.is_none() {
                        span_ctx.depth = fields.depth;
                    }
                    if span_ctx.event_id.is_none() {
                        span_ctx.event_id.clone_from(&fields.event_id);
                    }
                    if span_ctx.turn.is_none() {
                        span_ctx.turn = fields.turn;
                    }
                }
            }
        }

        // Extract event fields
        let mut visitor = EventFieldVisitor::new();
        event.record(&mut visitor);

        let component = span_ctx
            .component
            .unwrap_or_else(|| event.metadata().target().to_string());

        let data_json = if visitor.data.is_empty() {
            None
        } else {
            serde_json::to_string(&visitor.data).ok()
        };

        let entry = PendingEntry {
            timestamp: chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Millis, true),
            level: level.to_string(),
            level_num,
            component,
            message: visitor.message.unwrap_or_default(),
            session_id: span_ctx.session_id,
            workspace_id: span_ctx.workspace_id,
            event_id: span_ctx.event_id,
            turn: span_ctx.turn,
            trace_id: span_ctx.trace_id,
            parent_trace_id: span_ctx.parent_trace_id,
            depth: span_ctx.depth,
            data: data_json,
            error_message: visitor.error_message,
            error_stack: visitor.error_stack,
        };

        let should_flush = level_num >= LogLevel::Warn.as_num();

        {
            let mut guard = match self.inner.lock() {
                Ok(g) => g,
                Err(poisoned) => poisoned.into_inner(),
            };
            guard.batch.push(entry);

            if should_flush || guard.batch.len() >= self.config.batch_size {
                flush_locked(&mut guard);
            }
        }
    }

    fn on_new_span(
        &self,
        attrs: &tracing::span::Attributes<'_>,
        id: &tracing::span::Id,
        ctx: Context<'_, S>,
    ) {
        let Some(span) = ctx.span(id) else { return };
        let mut span_ctx = SpanContext::default();
        attrs.record(&mut SpanFieldVisitor { ctx: &mut span_ctx });
        span.extensions_mut().insert(span_ctx);
    }
}

/// Attempt one atomic diagnostic flush. A failed transaction leaves the batch
/// in memory so the periodic task or next threshold flush can retry it. Because
/// `write_batch` commits all entries in one transaction, clearing only after a
/// successful commit cannot duplicate a partially written batch.
fn flush_locked(inner: &mut TransportInner) -> bool {
    let entry_count = inner.batch.len();
    if entry_count == 0 {
        return true;
    }
    match write_batch(&inner.conn, &inner.batch) {
        Ok(()) => {
            inner.batch.clear();
            true
        }
        Err(error) => {
            eprintln!(
                "[tron-logging] write_batch failed ({entry_count} entries retained for retry): {error}"
            );
            false
        }
    }
}

/// Write a batch of entries to `SQLite` in a single transaction.
fn write_batch(conn: &Connection, entries: &[PendingEntry]) -> Result<(), rusqlite::Error> {
    if entries.is_empty() {
        return Ok(());
    }

    let tx = conn.unchecked_transaction()?;

    {
        let mut stmt = tx.prepare_cached(
            "INSERT INTO logs (timestamp, level, level_num, component, message, \
             session_id, workspace_id, event_id, turn, trace_id, \
             parent_trace_id, depth, data, error_message, error_stack) \
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15)",
        )?;

        for entry in entries {
            let entry = redacted_entry(entry);
            let data = compact_log_data(&tx, &entry);
            let _ = stmt.execute(rusqlite::params![
                entry.timestamp,
                entry.level,
                entry.level_num,
                entry.component,
                entry.message,
                entry.session_id,
                entry.workspace_id,
                entry.event_id,
                entry.turn,
                entry.trace_id,
                entry.parent_trace_id,
                entry.depth.unwrap_or(0),
                data,
                entry.error_message,
                entry.error_stack,
            ])?;
        }
    }

    tx.commit()?;
    Ok(())
}

fn redacted_entry(entry: &PendingEntry) -> PendingEntry {
    PendingEntry {
        timestamp: entry.timestamp.clone(),
        level: entry.level.clone(),
        level_num: entry.level_num,
        component: entry.component.clone(),
        message: redact_log_text(&entry.message),
        session_id: entry.session_id.clone(),
        workspace_id: entry.workspace_id.clone(),
        event_id: entry.event_id.clone(),
        turn: entry.turn,
        trace_id: entry.trace_id.clone(),
        parent_trace_id: entry.parent_trace_id.clone(),
        depth: entry.depth,
        data: entry.data.as_deref().map(redact_log_text),
        error_message: entry.error_message.as_deref().map(redact_log_text),
        error_stack: entry.error_stack.as_deref().map(redact_log_text),
    }
}

fn redact_log_text(text: &str) -> String {
    redact_sensitive_content(text)
}

fn compact_log_data(conn: &Connection, entry: &PendingEntry) -> Option<String> {
    let data = entry.data.as_deref()?;
    let retention_class =
        if entry.level.eq_ignore_ascii_case("trace") || entry.level.eq_ignore_ascii_case("debug") {
            "diagnostic_verbose"
        } else {
            "diagnostic_normal"
        };
    let expires_at = (retention_class == "diagnostic_verbose").then(|| {
        (chrono::Utc::now()
            + chrono::Duration::days(
                i64::try_from(crate::shared::storage::DIAGNOSTIC_RETENTION_DAYS).unwrap(),
            ))
        .to_rfc3339()
    });
    crate::shared::storage::store_json_bytes(
        conn,
        data.as_bytes(),
        &crate::shared::storage::StorePayloadOptions::new(
            "log_entry",
            format!("log_entry_{}", uuid::Uuid::now_v7()),
            "data",
            retention_class,
        )
        .with_scope(
            entry.trace_id.clone(),
            entry.session_id.clone(),
            entry.workspace_id.clone(),
        )
        .with_expires_at(expires_at)
        .with_redaction_level("structured-log"),
    )
    .ok()
    .or_else(|| {
        serde_json::to_string(&serde_json::json!({
            "payloadPreview": data.chars().take(512).collect::<String>(),
            "payloadSizeBytes": data.len(),
            "payloadBlobUnavailable": true,
        }))
        .ok()
    })
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests;
