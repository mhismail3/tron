//! Test utilities for capturing and asserting on tracing events.
//!
//! Provides a [`TestSubscriber`] that captures tracing events in memory
//! for assertions in tests.

use std::sync::{Arc, Mutex};

use tracing::level_filters::LevelFilter;
use tracing::{Event, Level, Subscriber};
use tracing_subscriber::Layer;
use tracing_subscriber::layer::{Context, SubscriberExt};
use tracing_subscriber::registry::LookupSpan;
use tracing_subscriber::util::SubscriberInitExt;

/// A captured tracing event for assertion.
#[derive(Clone, Debug)]
pub struct CapturedEvent {
    /// The log level.
    pub level: Level,
    /// The target module.
    pub target: String,
    /// The formatted message.
    pub message: String,
    /// Field key-value pairs.
    pub fields: Vec<(String, String)>,
}

/// A captured span for assertion.
#[derive(Clone, Debug)]
pub struct CapturedSpan {
    /// The span name.
    pub name: String,
    /// The target module.
    pub target: String,
}

/// Thread-safe store for captured events and spans.
#[derive(Clone, Default)]
pub struct CapturedLogs {
    events: Arc<Mutex<Vec<CapturedEvent>>>,
    spans: Arc<Mutex<Vec<CapturedSpan>>>,
}

impl CapturedLogs {
    /// Get all captured events.
    pub fn events(&self) -> Vec<CapturedEvent> {
        self.events.lock().unwrap().clone()
    }

    /// Get all captured spans.
    pub fn spans(&self) -> Vec<CapturedSpan> {
        self.spans.lock().unwrap().clone()
    }

    /// Check if any event contains the given message substring.
    pub fn has_message(&self, message_contains: &str) -> bool {
        self.events
            .lock()
            .unwrap()
            .iter()
            .any(|e| e.message.contains(message_contains))
    }

    /// Check if any event at the given level contains the message substring.
    pub fn has_event(&self, level: Level, message_contains: &str) -> bool {
        self.events
            .lock()
            .unwrap()
            .iter()
            .any(|e| e.level == level && e.message.contains(message_contains))
    }

    /// Check if a span with the given name was entered.
    pub fn has_span(&self, name: &str) -> bool {
        self.spans.lock().unwrap().iter().any(|s| s.name == name)
    }

    /// Count events at a specific level.
    pub fn count_at_level(&self, level: Level) -> usize {
        self.events
            .lock()
            .unwrap()
            .iter()
            .filter(|e| e.level == level)
            .count()
    }

    /// Events filtered by target module prefix.
    pub fn events_for_target(&self, target_prefix: &str) -> Vec<CapturedEvent> {
        self.events
            .lock()
            .unwrap()
            .iter()
            .filter(|e| e.target.starts_with(target_prefix))
            .cloned()
            .collect()
    }

    /// Clear all captured logs.
    pub fn clear(&self) {
        self.events.lock().unwrap().clear();
        self.spans.lock().unwrap().clear();
    }
}

/// A tracing layer that captures events and spans for testing.
struct CaptureLayer {
    logs: CapturedLogs,
}

/// Visitor that extracts the message and fields from an event.
struct FieldVisitor {
    message: String,
    fields: Vec<(String, String)>,
}

impl tracing::field::Visit for FieldVisitor {
    fn record_debug(&mut self, field: &tracing::field::Field, value: &dyn std::fmt::Debug) {
        let val = format!("{value:?}");
        if field.name() == "message" {
            self.message = val;
        } else {
            self.fields.push((field.name().to_owned(), val));
        }
    }

    fn record_str(&mut self, field: &tracing::field::Field, value: &str) {
        if field.name() == "message" {
            value.clone_into(&mut self.message);
        } else {
            self.fields
                .push((field.name().to_owned(), value.to_owned()));
        }
    }

    fn record_u64(&mut self, field: &tracing::field::Field, value: u64) {
        self.fields
            .push((field.name().to_owned(), value.to_string()));
    }

    fn record_i64(&mut self, field: &tracing::field::Field, value: i64) {
        self.fields
            .push((field.name().to_owned(), value.to_string()));
    }

    fn record_bool(&mut self, field: &tracing::field::Field, value: bool) {
        self.fields
            .push((field.name().to_owned(), value.to_string()));
    }
}

impl<S> Layer<S> for CaptureLayer
where
    S: Subscriber + for<'a> LookupSpan<'a>,
{
    fn on_event(&self, event: &Event<'_>, _ctx: Context<'_, S>) {
        let metadata = event.metadata();
        let mut visitor = FieldVisitor {
            message: String::new(),
            fields: Vec::new(),
        };
        event.record(&mut visitor);

        self.logs.events.lock().unwrap().push(CapturedEvent {
            level: *metadata.level(),
            target: metadata.target().to_owned(),
            message: visitor.message,
            fields: visitor.fields,
        });
    }

    fn on_new_span(
        &self,
        _attrs: &tracing::span::Attributes<'_>,
        _id: &tracing::span::Id,
        ctx: Context<'_, S>,
    ) {
        if let Some(span) = ctx.lookup_current() {
            self.logs.spans.lock().unwrap().push(CapturedSpan {
                name: span.name().to_owned(),
                target: span.metadata().target().to_owned(),
            });
        }
    }
}

/// Install a test subscriber that captures all events and returns a handle
/// to the captured logs.
///
/// Uses `set_default` so it only applies to the current thread. Safe to use
/// in parallel tests.
///
/// Returns `(CapturedLogs, DefaultGuard)` — the guard must be kept alive
/// for the duration of the test.
pub fn capture_logs() -> (CapturedLogs, tracing::subscriber::DefaultGuard) {
    let logs = CapturedLogs::default();
    let layer = CaptureLayer { logs: logs.clone() };

    let subscriber = tracing_subscriber::registry()
        .with(layer)
        .with(LevelFilter::TRACE);

    let guard = subscriber.set_default();
    (logs, guard)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn capture_info_event() {
        let (logs, _guard) = capture_logs();
        tracing::info!("hello world");
        assert!(logs.has_event(Level::INFO, "hello world"));
    }

    #[test]
    fn capture_warn_event() {
        let (logs, _guard) = capture_logs();
        tracing::warn!("something went wrong");
        assert!(logs.has_event(Level::WARN, "something went wrong"));
    }

    #[test]
    fn capture_error_event() {
        let (logs, _guard) = capture_logs();
        tracing::error!("critical failure");
        assert!(logs.has_event(Level::ERROR, "critical failure"));
    }

    #[test]
    fn capture_debug_event() {
        let (logs, _guard) = capture_logs();
        tracing::debug!("debug info");
        assert!(logs.has_event(Level::DEBUG, "debug info"));
    }

    #[test]
    fn filter_by_level() {
        let (logs, _guard) = capture_logs();
        tracing::info!("info");
        tracing::warn!("warn");
        tracing::error!("error");

        assert_eq!(logs.count_at_level(Level::INFO), 1);
        assert_eq!(logs.count_at_level(Level::WARN), 1);
        assert_eq!(logs.count_at_level(Level::ERROR), 1);
    }

    #[test]
    fn filter_by_target() {
        let (logs, _guard) = capture_logs();
        tracing::info!(target: "tron_runtime::agent", "agent event");
        tracing::info!(target: "tron_server::ws", "ws event");

        let agent_events = logs.events_for_target("tron_runtime");
        assert_eq!(agent_events.len(), 1);
        assert!(agent_events[0].message.contains("agent event"));
    }

    #[test]
    fn has_message_search() {
        let (logs, _guard) = capture_logs();
        tracing::info!("session abc123 started");
        assert!(logs.has_message("abc123"));
        assert!(!logs.has_message("xyz789"));
    }

    #[test]
    fn clear_logs() {
        let (logs, _guard) = capture_logs();
        tracing::info!("event 1");
        assert_eq!(logs.events().len(), 1);

        logs.clear();
        assert!(logs.events().is_empty());
    }

    #[test]
    fn concurrent_capture_thread_safe() {
        let logs = CapturedLogs::default();

        let logs_a = logs.clone();
        let logs_b = logs.clone();

        let h1 = std::thread::spawn(move || {
            for _ in 0..100 {
                let _ = logs_a.events();
            }
        });
        let h2 = std::thread::spawn(move || {
            for _ in 0..100 {
                let _ = logs_b.events();
            }
        });

        h1.join().unwrap();
        h2.join().unwrap();
    }

    #[test]
    fn event_fields_captured() {
        let (logs, _guard) = capture_logs();
        tracing::info!(session_id = "s1", turn = 3, "turn started");

        let events = logs.events();
        assert_eq!(events.len(), 1);
        assert!(events[0].message.contains("turn started"));
        assert!(
            events[0]
                .fields
                .iter()
                .any(|(k, v)| k == "session_id" && v == "s1")
        );
        assert!(
            events[0]
                .fields
                .iter()
                .any(|(k, v)| k == "turn" && v == "3")
        );
    }
}
