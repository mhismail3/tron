//! High-level transactional `EventStore` API.
//!
//! Composes all repository operations into atomic, session-centric methods.
//! Every write method runs inside a single `SQLite` transaction — callers
//! never observe partial state.

use serde_json::Value;

use std::collections::HashMap;
use std::sync::{Mutex, Weak};

use crate::sqlite::connection::ConnectionPool;
use crate::sqlite::row_types::{EventRow, SessionRow};
use crate::types::EventType;

mod auxiliary;
mod event_log;
mod locking;
mod session_lifecycle;
mod state;

pub use self::state::event_rows_to_session_events;

/// Result of creating a new session.
#[derive(Debug)]
pub struct CreateSessionResult {
    /// The created session.
    pub session: SessionRow,
    /// The root `session.start` event.
    pub root_event: EventRow,
}

/// Result of forking a session.
#[derive(Debug)]
pub struct ForkResult {
    /// The newly created (forked) session.
    pub session: SessionRow,
    /// The root `session.fork` event.
    pub fork_event: EventRow,
}

/// Options for appending an event.
pub struct AppendOptions<'a> {
    /// Session to append to.
    pub session_id: &'a str,
    /// Event type.
    pub event_type: EventType,
    /// Event payload (JSON).
    pub payload: Value,
    /// Explicit parent. If `None`, chains from session head.
    pub parent_id: Option<&'a str>,
}

/// Options for forking a session.
#[derive(Default)]
pub struct ForkOptions<'a> {
    /// Optional model override for the fork.
    pub model: Option<&'a str>,
    /// Optional title for the forked session.
    pub title: Option<&'a str>,
}

/// High-level `EventStore` wrapping a connection pool and all repositories.
///
/// All write methods are transactional — they run inside `SAVEPOINT`/`RELEASE`
/// blocks so callers never see partial state.
///
/// INVARIANT: session writes are serialized per-session via in-process mutex
/// locks (`with_session_write_lock`). Global mutations use a separate global
/// lock. `SQLite` `UNIQUE(session_id, sequence)` enforces ordering at the DB level.
pub struct EventStore {
    pool: ConnectionPool,
    global_write_lock: Mutex<()>,
    session_write_locks: Mutex<HashMap<String, Weak<Mutex<()>>>>,
}

impl EventStore {
    /// Create a new `EventStore` with the given connection pool.
    pub fn new(pool: ConnectionPool) -> Self {
        Self {
            pool,
            global_write_lock: Mutex::new(()),
            session_write_locks: Mutex::new(HashMap::new()),
        }
    }
    /// Get the raw connection pool (for advanced/custom queries).
    pub fn pool(&self) -> &ConnectionPool {
        &self.pool
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

#[cfg(test)]
#[allow(unused_results)]
mod tests {
    use super::*;
    use crate::sqlite::connection::{self, ConnectionConfig};
    use crate::sqlite::migrations::run_migrations;
    use crate::sqlite::repositories::event::ListEventsOptions;
    use crate::sqlite::repositories::search::SearchOptions;
    use crate::sqlite::repositories::session::ListSessionsOptions;

    fn setup() -> EventStore {
        let pool = connection::new_in_memory(&ConnectionConfig::default()).unwrap();
        {
            let conn = pool.get().unwrap();
            run_migrations(&conn).unwrap();
        }
        EventStore::new(pool)
    }

    // ── Session creation ──────────────────────────────────────────────

    #[test]
    fn create_session_basic() {
        let store = setup();
        let result = store
            .create_session("claude-opus-4-6", "/tmp/project", Some("Test"), None, None)
            .unwrap();

        assert!(result.session.id.starts_with("sess_"));
        assert!(result.root_event.id.starts_with("evt_"));
        assert_eq!(result.session.latest_model, "claude-opus-4-6");
        assert_eq!(result.session.title.as_deref(), Some("Test"));
        assert_eq!(result.session.event_count, 1);
        assert_eq!(
            result.session.head_event_id.as_deref(),
            Some(result.root_event.id.as_str())
        );
        assert_eq!(
            result.session.root_event_id.as_deref(),
            Some(result.root_event.id.as_str())
        );
    }

    #[test]
    fn create_session_with_explicit_provider() {
        let store = setup();
        let result = store
            .create_session(
                "claude-opus-4-6",
                "/tmp/project",
                None,
                Some("openai"),
                None,
            )
            .unwrap();

        let payload_str: String = result.root_event.payload;
        let payload: serde_json::Value = serde_json::from_str(&payload_str).unwrap();
        assert_eq!(
            payload["provider"].as_str(),
            Some("openai"),
            "explicit provider should override model-prefix heuristic"
        );
    }

    #[test]
    fn create_session_creates_workspace() {
        let store = setup();
        store
            .create_session("claude-opus-4-6", "/tmp/project", None, None, None)
            .unwrap();

        let ws = store.get_workspace_by_path("/tmp/project").unwrap();
        assert!(ws.is_some());
    }

    #[test]
    fn create_session_reuses_workspace() {
        let store = setup();
        let r1 = store
            .create_session("claude-opus-4-6", "/tmp/project", None, None, None)
            .unwrap();
        let r2 = store
            .create_session("claude-opus-4-6", "/tmp/project", None, None, None)
            .unwrap();

        assert_eq!(r1.session.workspace_id, r2.session.workspace_id);
        assert_ne!(r1.session.id, r2.session.id);
    }

    #[test]
    fn create_session_root_event_has_correct_fields() {
        let store = setup();
        let result = store
            .create_session("claude-opus-4-6", "/tmp/project", None, None, None)
            .unwrap();

        assert!(result.root_event.parent_id.is_none());
        assert_eq!(result.root_event.sequence, 0);
        assert_eq!(result.root_event.depth, 0);
        assert_eq!(result.root_event.event_type, "session.start");
        assert_eq!(result.root_event.session_id, result.session.id);
    }

    // ── Event appending ───────────────────────────────────────────────

    #[test]
    fn append_basic() {
        let store = setup();
        let cr = store
            .create_session("claude-opus-4-6", "/tmp/project", None, None, None)
            .unwrap();

        let event = store
            .append(&AppendOptions {
                session_id: &cr.session.id,
                event_type: EventType::MessageUser,
                payload: serde_json::json!({"content": "Hello"}),
                parent_id: None,
            })
            .unwrap();

        assert!(event.id.starts_with("evt_"));
        assert_eq!(event.session_id, cr.session.id);
        assert_eq!(event.event_type, "message.user");
        assert_eq!(event.sequence, 1);
        assert_eq!(event.depth, 1);
        assert_eq!(event.parent_id.as_deref(), Some(cr.root_event.id.as_str()));
    }

    #[test]
    fn append_chains_from_head() {
        let store = setup();
        let cr = store
            .create_session("claude-opus-4-6", "/tmp/project", None, None, None)
            .unwrap();

        let evt1 = store
            .append(&AppendOptions {
                session_id: &cr.session.id,
                event_type: EventType::MessageUser,
                payload: serde_json::json!({"content": "Hello"}),
                parent_id: None,
            })
            .unwrap();

        let evt2 = store
            .append(&AppendOptions {
                session_id: &cr.session.id,
                event_type: EventType::MessageAssistant,
                payload: serde_json::json!({"content": "Hi there!"}),
                parent_id: None,
            })
            .unwrap();

        assert_eq!(evt2.parent_id.as_deref(), Some(evt1.id.as_str()));
        assert_eq!(evt2.sequence, 2);
    }

    #[test]
    fn append_updates_session_head() {
        let store = setup();
        let cr = store
            .create_session("claude-opus-4-6", "/tmp/project", None, None, None)
            .unwrap();

        let event = store
            .append(&AppendOptions {
                session_id: &cr.session.id,
                event_type: EventType::MessageUser,
                payload: serde_json::json!({"content": "Hello"}),
                parent_id: None,
            })
            .unwrap();

        let session = store.get_session(&cr.session.id).unwrap().unwrap();
        assert_eq!(session.head_event_id.as_deref(), Some(event.id.as_str()));
    }

    #[test]
    fn append_increments_counters() {
        let store = setup();
        let cr = store
            .create_session("claude-opus-4-6", "/tmp/project", None, None, None)
            .unwrap();

        store
            .append(&AppendOptions {
                session_id: &cr.session.id,
                event_type: EventType::MessageUser,
                payload: serde_json::json!({"content": "Hello"}),
                parent_id: None,
            })
            .unwrap();

        store
            .append(&AppendOptions {
                session_id: &cr.session.id,
                event_type: EventType::MessageAssistant,
                payload: serde_json::json!({
                    "content": "Response",
                    "tokenUsage": {
                        "inputTokens": 100,
                        "outputTokens": 50,
                        "cacheReadTokens": 10,
                    }
                }),
                parent_id: None,
            })
            .unwrap();

        // Token counters only count from stream.turn_end, not message.assistant
        store
            .append(&AppendOptions {
                session_id: &cr.session.id,
                event_type: EventType::StreamTurnEnd,
                payload: serde_json::json!({
                    "tokenUsage": {
                        "inputTokens": 100,
                        "outputTokens": 50,
                        "cacheReadTokens": 10,
                    }
                }),
                parent_id: None,
            })
            .unwrap();

        let session = store.get_session(&cr.session.id).unwrap().unwrap();
        assert_eq!(session.event_count, 4); // root + user + assistant + turn_end
        assert_eq!(session.message_count, 2);
        assert_eq!(session.total_input_tokens, 100);
        assert_eq!(session.total_output_tokens, 50);
        assert_eq!(session.total_cache_read_tokens, 10);
    }

    #[test]
    fn last_turn_input_tokens_prefers_context_window_tokens() {
        let store = setup();
        let cr = store
            .create_session("claude-opus-4-6", "/tmp/project", None, None, None)
            .unwrap();

        // Append assistant message with BOTH tokenUsage.inputTokens AND
        // tokenRecord.computed.contextWindowTokens. The latter should win
        // because it includes cache reads for Anthropic (accurate context fill).
        store
            .append(&AppendOptions {
                session_id: &cr.session.id,
                event_type: EventType::MessageAssistant,
                payload: serde_json::json!({
                    "content": "Hello",
                    "tokenUsage": {
                        "inputTokens": 1000,
                        "outputTokens": 200,
                    },
                    "tokenRecord": {
                        "computed": {
                            "contextWindowTokens": 5000,
                            "newInputTokens": 1000,
                        }
                    }
                }),
                parent_id: None,
            })
            .unwrap();

        let session = store.get_session(&cr.session.id).unwrap().unwrap();
        // Should be 5000 (contextWindowTokens), NOT 1000 (inputTokens)
        assert_eq!(session.last_turn_input_tokens, 5000);
    }

    #[test]
    fn last_turn_input_tokens_falls_back_to_input_tokens() {
        let store = setup();
        let cr = store
            .create_session("claude-opus-4-6", "/tmp/project", None, None, None)
            .unwrap();

        // No tokenRecord — should fall back to tokenUsage.inputTokens
        store
            .append(&AppendOptions {
                session_id: &cr.session.id,
                event_type: EventType::MessageAssistant,
                payload: serde_json::json!({
                    "content": "Hello",
                    "tokenUsage": {
                        "inputTokens": 800,
                        "outputTokens": 100,
                    }
                }),
                parent_id: None,
            })
            .unwrap();

        let session = store.get_session(&cr.session.id).unwrap().unwrap();
        assert_eq!(session.last_turn_input_tokens, 800);
    }

    #[test]
    fn last_turn_input_tokens_not_set_for_user_messages() {
        let store = setup();
        let cr = store
            .create_session("claude-opus-4-6", "/tmp/project", None, None, None)
            .unwrap();

        // User messages should NOT update last_turn_input_tokens even if
        // they somehow have tokenUsage (guard: event_type == MessageAssistant)
        store
            .append(&AppendOptions {
                session_id: &cr.session.id,
                event_type: EventType::MessageUser,
                payload: serde_json::json!({
                    "content": "Hello",
                    "tokenUsage": {
                        "inputTokens": 999,
                        "outputTokens": 0,
                    }
                }),
                parent_id: None,
            })
            .unwrap();

        let session = store.get_session(&cr.session.id).unwrap().unwrap();
        assert_eq!(session.last_turn_input_tokens, 0); // unchanged from default
    }

    // ── Token double-counting prevention ────────────────────────────

    #[test]
    fn token_counters_only_from_stream_turn_end() {
        let store = setup();
        let cr = store
            .create_session("claude-opus-4-6", "/tmp/project", None, None, None)
            .unwrap();

        // message.assistant with tokenUsage should NOT increment token counters
        store
            .append(&AppendOptions {
                session_id: &cr.session.id,
                event_type: EventType::MessageAssistant,
                payload: serde_json::json!({
                    "content": "Response",
                    "tokenUsage": {
                        "inputTokens": 100,
                        "outputTokens": 50,
                        "cacheReadTokens": 10,
                        "cacheCreationTokens": 5,
                    }
                }),
                parent_id: None,
            })
            .unwrap();

        let session = store.get_session(&cr.session.id).unwrap().unwrap();
        assert_eq!(
            session.total_input_tokens, 0,
            "message.assistant should not count tokens"
        );
        assert_eq!(session.total_output_tokens, 0);
        assert_eq!(session.total_cache_read_tokens, 0);
        assert_eq!(session.total_cache_creation_tokens, 0);
        // But message_count and turn_count should still increment
        assert_eq!(session.message_count, 1);
        assert_eq!(session.turn_count, 1);

        // stream.turn_end with same tokenUsage SHOULD increment
        store
            .append(&AppendOptions {
                session_id: &cr.session.id,
                event_type: EventType::StreamTurnEnd,
                payload: serde_json::json!({
                    "tokenUsage": {
                        "inputTokens": 100,
                        "outputTokens": 50,
                        "cacheReadTokens": 10,
                        "cacheCreationTokens": 5,
                    }
                }),
                parent_id: None,
            })
            .unwrap();

        let session = store.get_session(&cr.session.id).unwrap().unwrap();
        assert_eq!(session.total_input_tokens, 100);
        assert_eq!(session.total_output_tokens, 50);
        assert_eq!(session.total_cache_read_tokens, 10);
        assert_eq!(session.total_cache_creation_tokens, 5);
        // turn_end should not affect message/turn counts
        assert_eq!(session.message_count, 1);
        assert_eq!(session.turn_count, 1);
    }

    #[test]
    fn cost_only_from_stream_turn_end() {
        let store = setup();
        let cr = store
            .create_session("claude-opus-4-6", "/tmp/project", None, None, None)
            .unwrap();

        // message.assistant with cost should NOT increment cost
        store
            .append(&AppendOptions {
                session_id: &cr.session.id,
                event_type: EventType::MessageAssistant,
                payload: serde_json::json!({
                    "content": "Response",
                    "cost": 0.005,
                }),
                parent_id: None,
            })
            .unwrap();

        let session = store.get_session(&cr.session.id).unwrap().unwrap();
        assert!(
            session.total_cost < f64::EPSILON,
            "message.assistant should not count cost"
        );

        // stream.turn_end with cost SHOULD increment
        store
            .append(&AppendOptions {
                session_id: &cr.session.id,
                event_type: EventType::StreamTurnEnd,
                payload: serde_json::json!({
                    "cost": 0.005,
                }),
                parent_id: None,
            })
            .unwrap();

        let session = store.get_session(&cr.session.id).unwrap().unwrap();
        assert!((session.total_cost - 0.005).abs() < f64::EPSILON);
    }

    #[test]
    fn no_double_counting_with_both_events() {
        let store = setup();
        let cr = store
            .create_session("claude-opus-4-6", "/tmp/project", None, None, None)
            .unwrap();

        // Simulate a real turn: message.assistant then stream.turn_end with identical tokens
        let token_usage = serde_json::json!({
            "inputTokens": 500,
            "outputTokens": 100,
            "cacheReadTokens": 12000,
            "cacheCreationTokens": 200,
        });

        store
            .append(&AppendOptions {
                session_id: &cr.session.id,
                event_type: EventType::MessageAssistant,
                payload: serde_json::json!({
                    "content": "Response",
                    "tokenUsage": token_usage,
                    "cost": 0.01,
                }),
                parent_id: None,
            })
            .unwrap();

        store
            .append(&AppendOptions {
                session_id: &cr.session.id,
                event_type: EventType::StreamTurnEnd,
                payload: serde_json::json!({
                    "tokenUsage": token_usage,
                    "cost": 0.01,
                }),
                parent_id: None,
            })
            .unwrap();

        let session = store.get_session(&cr.session.id).unwrap().unwrap();
        // Tokens should be counted exactly once (from stream.turn_end only)
        assert_eq!(session.total_input_tokens, 500);
        assert_eq!(session.total_output_tokens, 100);
        assert_eq!(session.total_cache_read_tokens, 12000);
        assert_eq!(session.total_cache_creation_tokens, 200);
        assert!((session.total_cost - 0.01).abs() < f64::EPSILON);
    }

    #[test]
    fn stream_turn_end_without_token_usage_no_counter_change() {
        let store = setup();
        let cr = store
            .create_session("claude-opus-4-6", "/tmp/project", None, None, None)
            .unwrap();

        // stream.turn_end with no tokenUsage (e.g. tool-only turn)
        store
            .append(&AppendOptions {
                session_id: &cr.session.id,
                event_type: EventType::StreamTurnEnd,
                payload: serde_json::json!({}),
                parent_id: None,
            })
            .unwrap();

        let session = store.get_session(&cr.session.id).unwrap().unwrap();
        assert_eq!(session.total_input_tokens, 0);
        assert_eq!(session.total_output_tokens, 0);
        assert_eq!(session.total_cache_read_tokens, 0);
        assert_eq!(session.total_cache_creation_tokens, 0);
        assert!(session.total_cost < f64::EPSILON);
    }

    #[test]
    fn events_without_token_usage_dont_affect_counters() {
        let store = setup();
        let cr = store
            .create_session("claude-opus-4-6", "/tmp/project", None, None, None)
            .unwrap();

        store
            .append(&AppendOptions {
                session_id: &cr.session.id,
                event_type: EventType::MessageUser,
                payload: serde_json::json!({"content": "Hello"}),
                parent_id: None,
            })
            .unwrap();

        store
            .append(&AppendOptions {
                session_id: &cr.session.id,
                event_type: EventType::ToolResult,
                payload: serde_json::json!({"toolCallId": "t1", "content": "ok"}),
                parent_id: None,
            })
            .unwrap();

        let session = store.get_session(&cr.session.id).unwrap().unwrap();
        assert_eq!(session.total_input_tokens, 0);
        assert_eq!(session.total_output_tokens, 0);
    }

    #[test]
    fn last_turn_input_tokens_still_set_on_message_assistant() {
        let store = setup();
        let cr = store
            .create_session("claude-opus-4-6", "/tmp/project", None, None, None)
            .unwrap();

        // Even though token counters don't increment from message.assistant,
        // last_turn_input_tokens (SET semantics) should still be set
        store
            .append(&AppendOptions {
                session_id: &cr.session.id,
                event_type: EventType::MessageAssistant,
                payload: serde_json::json!({
                    "content": "Response",
                    "tokenUsage": {"inputTokens": 500, "outputTokens": 100},
                    "tokenRecord": {
                        "computed": {"contextWindowTokens": 12000}
                    }
                }),
                parent_id: None,
            })
            .unwrap();

        let session = store.get_session(&cr.session.id).unwrap().unwrap();
        assert_eq!(session.last_turn_input_tokens, 12000);
        // But token totals should be zero (not counted from message.assistant)
        assert_eq!(session.total_input_tokens, 0);
        assert_eq!(session.total_output_tokens, 0);
    }

    #[test]
    fn multi_turn_no_double_counting() {
        let store = setup();
        let cr = store
            .create_session("claude-opus-4-6", "/tmp/project", None, None, None)
            .unwrap();

        // Turn 1
        store
            .append(&AppendOptions {
                session_id: &cr.session.id,
                event_type: EventType::MessageUser,
                payload: serde_json::json!({"content": "Hello"}),
                parent_id: None,
            })
            .unwrap();
        store
            .append(&AppendOptions {
                session_id: &cr.session.id,
                event_type: EventType::MessageAssistant,
                payload: serde_json::json!({
                    "content": "Hi",
                    "tokenUsage": {"inputTokens": 100, "outputTokens": 20},
                    "cost": 0.001,
                }),
                parent_id: None,
            })
            .unwrap();
        store
            .append(&AppendOptions {
                session_id: &cr.session.id,
                event_type: EventType::StreamTurnEnd,
                payload: serde_json::json!({
                    "tokenUsage": {"inputTokens": 100, "outputTokens": 20},
                    "cost": 0.001,
                }),
                parent_id: None,
            })
            .unwrap();

        // Turn 2
        store
            .append(&AppendOptions {
                session_id: &cr.session.id,
                event_type: EventType::MessageUser,
                payload: serde_json::json!({"content": "More"}),
                parent_id: None,
            })
            .unwrap();
        store
            .append(&AppendOptions {
                session_id: &cr.session.id,
                event_type: EventType::MessageAssistant,
                payload: serde_json::json!({
                    "content": "Sure",
                    "tokenUsage": {"inputTokens": 200, "outputTokens": 30},
                    "cost": 0.002,
                }),
                parent_id: None,
            })
            .unwrap();
        store
            .append(&AppendOptions {
                session_id: &cr.session.id,
                event_type: EventType::StreamTurnEnd,
                payload: serde_json::json!({
                    "tokenUsage": {"inputTokens": 200, "outputTokens": 30},
                    "cost": 0.002,
                }),
                parent_id: None,
            })
            .unwrap();

        let session = store.get_session(&cr.session.id).unwrap().unwrap();
        // Should be sum of turn_end events only, not doubled
        assert_eq!(session.total_input_tokens, 300);
        assert_eq!(session.total_output_tokens, 50);
        assert!((session.total_cost - 0.003).abs() < f64::EPSILON);
        assert_eq!(session.turn_count, 2);
        assert_eq!(session.message_count, 4); // 2 user + 2 assistant
    }

    #[test]
    fn append_with_explicit_parent() {
        let store = setup();
        let cr = store
            .create_session("claude-opus-4-6", "/tmp/project", None, None, None)
            .unwrap();

        // Append with explicit parent = root event (not head)
        let evt1 = store
            .append(&AppendOptions {
                session_id: &cr.session.id,
                event_type: EventType::MessageUser,
                payload: serde_json::json!({"content": "First"}),
                parent_id: None,
            })
            .unwrap();

        // Branch from root, not from evt1
        let evt2 = store
            .append(&AppendOptions {
                session_id: &cr.session.id,
                event_type: EventType::MessageUser,
                payload: serde_json::json!({"content": "Branch from root"}),
                parent_id: Some(&cr.root_event.id),
            })
            .unwrap();

        assert_eq!(evt2.parent_id.as_deref(), Some(cr.root_event.id.as_str()));
        assert_ne!(evt1.id, evt2.id);
    }

    #[test]
    fn append_to_nonexistent_session_fails() {
        let store = setup();
        let result = store.append(&AppendOptions {
            session_id: "sess_nonexistent",
            event_type: EventType::MessageUser,
            payload: serde_json::json!({"content": "Hello"}),
            parent_id: None,
        });
        assert!(result.is_err());
    }

    // ── Event retrieval ───────────────────────────────────────────────

    #[test]
    fn get_event() {
        let store = setup();
        let cr = store
            .create_session("claude-opus-4-6", "/tmp/project", None, None, None)
            .unwrap();

        let event = store.get_event(&cr.root_event.id).unwrap();
        assert!(event.is_some());
        assert_eq!(event.unwrap().event_type, "session.start");
    }

    #[test]
    fn get_events_by_session() {
        let store = setup();
        let cr = store
            .create_session("claude-opus-4-6", "/tmp/project", None, None, None)
            .unwrap();

        store
            .append(&AppendOptions {
                session_id: &cr.session.id,
                event_type: EventType::MessageUser,
                payload: serde_json::json!({"content": "Hello"}),
                parent_id: None,
            })
            .unwrap();

        let events = store
            .get_events_by_session(&cr.session.id, &ListEventsOptions::default())
            .unwrap();
        assert_eq!(events.len(), 2); // root + user message
        assert_eq!(events[0].sequence, 0);
        assert_eq!(events[1].sequence, 1);
    }

    #[test]
    fn get_ancestors() {
        let store = setup();
        let cr = store
            .create_session("claude-opus-4-6", "/tmp/project", None, None, None)
            .unwrap();

        let evt1 = store
            .append(&AppendOptions {
                session_id: &cr.session.id,
                event_type: EventType::MessageUser,
                payload: serde_json::json!({"content": "Hello"}),
                parent_id: None,
            })
            .unwrap();

        let evt2 = store
            .append(&AppendOptions {
                session_id: &cr.session.id,
                event_type: EventType::MessageAssistant,
                payload: serde_json::json!({"content": "Hi"}),
                parent_id: None,
            })
            .unwrap();

        let ancestors = store.get_ancestors(&evt2.id).unwrap();
        assert_eq!(ancestors.len(), 3); // root → evt1 → evt2
        assert_eq!(ancestors[0].id, cr.root_event.id);
        assert_eq!(ancestors[1].id, evt1.id);
        assert_eq!(ancestors[2].id, evt2.id);
    }

    // ── Fork ──────────────────────────────────────────────────────────

    #[test]
    fn fork_basic() {
        let store = setup();
        let cr = store
            .create_session("claude-opus-4-6", "/tmp/project", None, None, None)
            .unwrap();

        let user_msg = store
            .append(&AppendOptions {
                session_id: &cr.session.id,
                event_type: EventType::MessageUser,
                payload: serde_json::json!({"content": "Hello"}),
                parent_id: None,
            })
            .unwrap();

        let fork = store.fork(&user_msg.id, &ForkOptions::default()).unwrap();

        assert!(fork.session.id.starts_with("sess_"));
        assert_ne!(fork.session.id, cr.session.id);
        assert_eq!(
            fork.session.parent_session_id.as_deref(),
            Some(cr.session.id.as_str())
        );
        assert_eq!(
            fork.session.fork_from_event_id.as_deref(),
            Some(user_msg.id.as_str())
        );
        assert_eq!(fork.fork_event.event_type, "session.fork");
        assert_eq!(
            fork.fork_event.parent_id.as_deref(),
            Some(user_msg.id.as_str())
        );
        assert_eq!(fork.session.event_count, 1);
    }

    #[test]
    fn fork_ancestors_cross_sessions() {
        let store = setup();
        let cr = store
            .create_session("claude-opus-4-6", "/tmp/project", None, None, None)
            .unwrap();

        let user_msg = store
            .append(&AppendOptions {
                session_id: &cr.session.id,
                event_type: EventType::MessageUser,
                payload: serde_json::json!({"content": "Hello"}),
                parent_id: None,
            })
            .unwrap();

        let fork = store.fork(&user_msg.id, &ForkOptions::default()).unwrap();

        // Ancestor walk from fork event traverses back through source session
        let ancestors = store.get_ancestors(&fork.fork_event.id).unwrap();
        assert_eq!(ancestors.len(), 3); // source root → user msg → fork event
        assert_eq!(ancestors[0].id, cr.root_event.id);
        assert_eq!(ancestors[1].id, user_msg.id);
        assert_eq!(ancestors[2].id, fork.fork_event.id);
    }

    #[test]
    fn fork_with_model_override() {
        let store = setup();
        let cr = store
            .create_session("claude-opus-4-6", "/tmp/project", None, None, None)
            .unwrap();

        let fork = store
            .fork(
                &cr.root_event.id,
                &ForkOptions {
                    model: Some("claude-sonnet-4-5"),
                    title: Some("Forked"),
                },
            )
            .unwrap();

        assert_eq!(fork.session.latest_model, "claude-sonnet-4-5");
        assert_eq!(fork.session.title.as_deref(), Some("Forked"));
    }

    #[test]
    fn fork_nonexistent_event_fails() {
        let store = setup();
        let result = store.fork("evt_nonexistent", &ForkOptions::default());
        assert!(result.is_err());
    }

    // ── Message deletion ──────────────────────────────────────────────

    #[test]
    fn delete_message_basic() {
        let store = setup();
        let cr = store
            .create_session("claude-opus-4-6", "/tmp/project", None, None, None)
            .unwrap();

        let user_msg = store
            .append(&AppendOptions {
                session_id: &cr.session.id,
                event_type: EventType::MessageUser,
                payload: serde_json::json!({"content": "Delete me"}),
                parent_id: None,
            })
            .unwrap();

        let delete_event = store
            .delete_message(&cr.session.id, &user_msg.id, None)
            .unwrap();

        assert_eq!(delete_event.event_type, "message.deleted");
        let payload: Value = serde_json::from_str(&delete_event.payload).unwrap();
        assert_eq!(payload["targetEventId"], user_msg.id);
    }

    #[test]
    fn delete_non_message_fails() {
        let store = setup();
        let cr = store
            .create_session("claude-opus-4-6", "/tmp/project", None, None, None)
            .unwrap();

        // Try to delete the root session.start event
        let result = store.delete_message(&cr.session.id, &cr.root_event.id, None);
        assert!(result.is_err());
    }

    // ── Session management ────────────────────────────────────────────

    #[test]
    fn get_session() {
        let store = setup();
        let cr = store
            .create_session("claude-opus-4-6", "/tmp/project", None, None, None)
            .unwrap();

        let session = store.get_session(&cr.session.id).unwrap();
        assert!(session.is_some());
    }

    #[test]
    fn list_sessions() {
        let store = setup();
        store
            .create_session("claude-opus-4-6", "/tmp/project", None, None, None)
            .unwrap();
        store
            .create_session("claude-opus-4-6", "/tmp/project", None, None, None)
            .unwrap();

        let sessions = store
            .list_sessions(&ListSessionsOptions::default())
            .unwrap();
        assert_eq!(sessions.len(), 2);
    }

    #[test]
    fn end_and_reactivate_session() {
        let store = setup();
        let cr = store
            .create_session("claude-opus-4-6", "/tmp/project", None, None, None)
            .unwrap();

        store.end_session(&cr.session.id).unwrap();
        let session = store.get_session(&cr.session.id).unwrap().unwrap();
        assert!(session.ended_at.is_some());

        store.clear_session_ended(&cr.session.id).unwrap();
        let session = store.get_session(&cr.session.id).unwrap().unwrap();
        assert!(session.ended_at.is_none());
    }

    #[test]
    fn update_session_title() {
        let store = setup();
        let cr = store
            .create_session("claude-opus-4-6", "/tmp/project", None, None, None)
            .unwrap();

        store
            .update_session_title(&cr.session.id, Some("New Title"))
            .unwrap();
        let session = store.get_session(&cr.session.id).unwrap().unwrap();
        assert_eq!(session.title.as_deref(), Some("New Title"));
    }

    #[test]
    fn delete_session_cascade() {
        let store = setup();
        let cr = store
            .create_session("claude-opus-4-6", "/tmp/project", None, None, None)
            .unwrap();

        store
            .append(&AppendOptions {
                session_id: &cr.session.id,
                event_type: EventType::MessageUser,
                payload: serde_json::json!({"content": "Hello"}),
                parent_id: None,
            })
            .unwrap();

        assert!(store.delete_session(&cr.session.id).unwrap());
        assert!(store.get_session(&cr.session.id).unwrap().is_none());

        let events = store
            .get_events_by_session(&cr.session.id, &ListEventsOptions::default())
            .unwrap();
        assert!(events.is_empty());
    }

    // ── Source tracking ────────────────────────────────────────────────

    #[test]
    fn update_source_sets_source() {
        let store = setup();
        let cr = store
            .create_session(
                "claude-opus-4-6",
                "/tmp/project",
                Some("Cron: test"),
                None,
                None,
            )
            .unwrap();

        let updated = store.update_source(&cr.session.id, "cron").unwrap();
        assert!(updated);

        let session = store.get_session(&cr.session.id).unwrap().unwrap();
        assert_eq!(session.source.as_deref(), Some("cron"));
    }

    #[test]
    fn update_source_nonexistent_session() {
        let store = setup();
        let updated = store.update_source("sess_nonexistent", "cron").unwrap();
        assert!(!updated);
    }

    #[test]
    fn update_source_is_idempotent() {
        let store = setup();
        let cr = store
            .create_session("claude-opus-4-6", "/tmp/project", None, None, None)
            .unwrap();

        store.update_source(&cr.session.id, "cron").unwrap();
        let updated = store.update_source(&cr.session.id, "cron").unwrap();
        assert!(updated);

        let session = store.get_session(&cr.session.id).unwrap().unwrap();
        assert_eq!(session.source.as_deref(), Some("cron"));
    }

    #[test]
    fn update_spawn_info_links_subagent_and_lists_it() {
        let store = setup();
        let parent = store
            .create_session(
                "claude-opus-4-6",
                "/tmp/project",
                Some("Parent"),
                None,
                None,
            )
            .unwrap();
        let child = store
            .create_session("claude-opus-4-6", "/tmp/project", Some("Child"), None, None)
            .unwrap();

        let updated = store
            .update_spawn_info(
                &child.session.id,
                &parent.session.id,
                "query",
                "summarize history",
            )
            .unwrap();
        assert!(updated);

        let child_session = store.get_session(&child.session.id).unwrap().unwrap();
        assert_eq!(
            child_session.spawning_session_id.as_deref(),
            Some(parent.session.id.as_str())
        );
        assert_eq!(child_session.spawn_type.as_deref(), Some("query"));
        assert_eq!(
            child_session.spawn_task.as_deref(),
            Some("summarize history")
        );

        let subagents = store.list_subagents(&parent.session.id).unwrap();
        assert_eq!(subagents.len(), 1);
        assert_eq!(subagents[0].id, child.session.id);
    }

    #[test]
    fn update_spawn_info_nonexistent_session_returns_false() {
        let store = setup();
        let updated = store
            .update_spawn_info(
                "sess_nonexistent",
                "sess_parent",
                "query",
                "summarize history",
            )
            .unwrap();
        assert!(!updated);
    }

    #[test]
    fn was_session_interrupted_tracks_incomplete_turns() {
        let store = setup();
        let cr = store
            .create_session("claude-opus-4-6", "/tmp/project", None, None, None)
            .unwrap();

        assert!(!store.was_session_interrupted(&cr.session.id).unwrap());

        store
            .append(&AppendOptions {
                session_id: &cr.session.id,
                event_type: EventType::MessageAssistant,
                payload: serde_json::json!({
                    "content": [{"type": "text", "text": "Partial response"}],
                    "turn": 1,
                }),
                parent_id: None,
            })
            .unwrap();

        assert!(store.was_session_interrupted(&cr.session.id).unwrap());

        store
            .append(&AppendOptions {
                session_id: &cr.session.id,
                event_type: EventType::StreamTurnEnd,
                payload: serde_json::json!({
                    "turn": 1,
                    "tokenUsage": {"inputTokens": 10, "outputTokens": 5},
                }),
                parent_id: None,
            })
            .unwrap();

        assert!(!store.was_session_interrupted(&cr.session.id).unwrap());
    }

    // ── Blob storage ──────────────────────────────────────────────────

    #[test]
    fn blob_storage() {
        let store = setup();
        let blob_id = store.store_blob(b"hello world", "text/plain").unwrap();

        let content = store.get_blob_content(&blob_id).unwrap().unwrap();
        assert_eq!(content, b"hello world");

        let blob = store.get_blob(&blob_id).unwrap().unwrap();
        assert_eq!(blob.mime_type, "text/plain");
        assert_eq!(blob.size_original, 11);
    }

    // ── Search ────────────────────────────────────────────────────────

    #[test]
    fn search_events() {
        let store = setup();
        let cr = store
            .create_session("claude-opus-4-6", "/tmp/project", None, None, None)
            .unwrap();

        store
            .append(&AppendOptions {
                session_id: &cr.session.id,
                event_type: EventType::MessageUser,
                payload: serde_json::json!({"content": "rust programming"}),
                parent_id: None,
            })
            .unwrap();

        let results = store.search("rust", &SearchOptions::default()).unwrap();
        assert_eq!(results.len(), 1);
    }

    #[test]
    fn search_in_session() {
        let store = setup();
        let cr1 = store
            .create_session("claude-opus-4-6", "/tmp/project", None, None, None)
            .unwrap();
        let cr2 = store
            .create_session("claude-opus-4-6", "/tmp/project", None, None, None)
            .unwrap();

        store
            .append(&AppendOptions {
                session_id: &cr1.session.id,
                event_type: EventType::MessageUser,
                payload: serde_json::json!({"content": "hello world"}),
                parent_id: None,
            })
            .unwrap();
        store
            .append(&AppendOptions {
                session_id: &cr2.session.id,
                event_type: EventType::MessageUser,
                payload: serde_json::json!({"content": "hello cosmos"}),
                parent_id: None,
            })
            .unwrap();

        let results = store
            .search_in_session(&cr1.session.id, "hello", None)
            .unwrap();
        assert_eq!(results.len(), 1);
        assert_eq!(results[0].session_id, cr1.session.id);
    }

    // ── Workspace ─────────────────────────────────────────────────────

    #[test]
    fn workspace_get_or_create() {
        let store = setup();
        let ws1 = store
            .get_or_create_workspace("/tmp/project", Some("Project"))
            .unwrap();
        let ws2 = store.get_or_create_workspace("/tmp/project", None).unwrap();
        assert_eq!(ws1.id, ws2.id);
    }

    #[test]
    fn list_workspaces() {
        let store = setup();
        store
            .create_session("claude-opus-4-6", "/tmp/a", None, None, None)
            .unwrap();
        store
            .create_session("claude-opus-4-6", "/tmp/b", None, None, None)
            .unwrap();

        let workspaces = store.list_workspaces().unwrap();
        assert_eq!(workspaces.len(), 2);
    }

    // ── Complex scenarios ─────────────────────────────────────────────

    #[test]
    fn agentic_loop() {
        let store = setup();
        let cr = store
            .create_session("claude-opus-4-6", "/tmp/project", None, None, None)
            .unwrap();

        // Turn 1: user → assistant(tool_use) → turn_end → tool.result → assistant(end_turn) → turn_end
        store
            .append(&AppendOptions {
                session_id: &cr.session.id,
                event_type: EventType::MessageUser,
                payload: serde_json::json!({"content": "List files", "turn": 1}),
                parent_id: None,
            })
            .unwrap();

        store
            .append(&AppendOptions {
                session_id: &cr.session.id,
                event_type: EventType::MessageAssistant,
                payload: serde_json::json!({
                    "content": [{"type": "tool_use", "id": "tool_1", "name": "Bash", "arguments": {"command": "ls"}}],
                    "turn": 1,
                    "tokenUsage": {"inputTokens": 200, "outputTokens": 30}
                }),
                parent_id: None,
            })
            .unwrap();

        store
            .append(&AppendOptions {
                session_id: &cr.session.id,
                event_type: EventType::StreamTurnEnd,
                payload: serde_json::json!({
                    "tokenUsage": {"inputTokens": 200, "outputTokens": 30}
                }),
                parent_id: None,
            })
            .unwrap();

        store
            .append(&AppendOptions {
                session_id: &cr.session.id,
                event_type: EventType::ToolResult,
                payload: serde_json::json!({
                    "toolCallId": "tool_1",
                    "content": "file1.txt\nfile2.txt",
                    "turn": 1
                }),
                parent_id: None,
            })
            .unwrap();

        store
            .append(&AppendOptions {
                session_id: &cr.session.id,
                event_type: EventType::MessageAssistant,
                payload: serde_json::json!({
                    "content": [{"type": "text", "text": "I found 2 files."}],
                    "turn": 1,
                    "stopReason": "end_turn",
                    "tokenUsage": {"inputTokens": 300, "outputTokens": 20}
                }),
                parent_id: None,
            })
            .unwrap();

        store
            .append(&AppendOptions {
                session_id: &cr.session.id,
                event_type: EventType::StreamTurnEnd,
                payload: serde_json::json!({
                    "tokenUsage": {"inputTokens": 300, "outputTokens": 20}
                }),
                parent_id: None,
            })
            .unwrap();

        let session = store.get_session(&cr.session.id).unwrap().unwrap();
        assert_eq!(session.event_count, 7); // root + 6
        assert_eq!(session.message_count, 3); // 1 user + 2 assistant
        assert_eq!(session.total_input_tokens, 500);
        assert_eq!(session.total_output_tokens, 50);

        let events = store
            .get_events_by_session(&cr.session.id, &ListEventsOptions::default())
            .unwrap();
        assert_eq!(events.len(), 7);
        for (i, event) in events.iter().enumerate() {
            assert_eq!(event.sequence, i as i64);
        }
    }

    #[test]
    fn fork_then_diverge() {
        let store = setup();
        let cr = store
            .create_session("claude-opus-4-6", "/tmp/project", None, None, None)
            .unwrap();

        let user_msg = store
            .append(&AppendOptions {
                session_id: &cr.session.id,
                event_type: EventType::MessageUser,
                payload: serde_json::json!({"content": "Hello"}),
                parent_id: None,
            })
            .unwrap();

        let assistant_msg = store
            .append(&AppendOptions {
                session_id: &cr.session.id,
                event_type: EventType::MessageAssistant,
                payload: serde_json::json!({"content": "World"}),
                parent_id: None,
            })
            .unwrap();

        // Fork from user message (before assistant response)
        let fork = store.fork(&user_msg.id, &ForkOptions::default()).unwrap();

        // Add different continuation in fork
        let fork_response = store
            .append(&AppendOptions {
                session_id: &fork.session.id,
                event_type: EventType::MessageAssistant,
                payload: serde_json::json!({"content": "Alternative response"}),
                parent_id: None,
            })
            .unwrap();

        // Original session unchanged
        let orig_events = store
            .get_events_by_session(&cr.session.id, &ListEventsOptions::default())
            .unwrap();
        assert_eq!(orig_events.len(), 3); // root + user + assistant

        // Fork has: source root → user msg → fork event → fork response
        let fork_ancestors = store.get_ancestors(&fork_response.id).unwrap();
        assert_eq!(fork_ancestors.len(), 4);
        assert_eq!(fork_ancestors[0].id, cr.root_event.id);
        assert_eq!(fork_ancestors[1].id, user_msg.id);
        assert_eq!(fork_ancestors[2].id, fork.fork_event.id);
        assert_eq!(fork_ancestors[3].id, fork_response.id);

        // Original assistant response NOT in fork ancestors
        assert!(fork_ancestors.iter().all(|e| e.id != assistant_msg.id));
    }

    // ── Batch session queries ─────────────────────────────────────────

    #[test]
    fn get_sessions_by_ids_basic() {
        let store = setup();
        let cr1 = store
            .create_session("claude-opus-4-6", "/tmp/a", Some("A"), None, None)
            .unwrap();
        let cr2 = store
            .create_session("claude-opus-4-6", "/tmp/b", Some("B"), None, None)
            .unwrap();
        store
            .create_session("claude-opus-4-6", "/tmp/c", Some("C"), None, None)
            .unwrap();

        let ids = [cr1.session.id.as_str(), cr2.session.id.as_str()];
        let result = store.get_sessions_by_ids(&ids).unwrap();
        assert_eq!(result.len(), 2);
        assert!(result.contains_key(&cr1.session.id));
        assert!(result.contains_key(&cr2.session.id));
    }

    #[test]
    fn get_sessions_by_ids_empty() {
        let store = setup();
        let result = store.get_sessions_by_ids(&[]).unwrap();
        assert!(result.is_empty());
    }

    #[test]
    fn get_sessions_by_ids_missing_omitted() {
        let store = setup();
        let cr = store
            .create_session("claude-opus-4-6", "/tmp/a", None, None, None)
            .unwrap();

        let ids = [cr.session.id.as_str(), "sess_nonexistent"];
        let result = store.get_sessions_by_ids(&ids).unwrap();
        assert_eq!(result.len(), 1);
        assert!(result.contains_key(&cr.session.id));
    }

    #[test]
    fn get_session_message_previews_basic() {
        let store = setup();
        let cr = store
            .create_session("claude-opus-4-6", "/tmp/a", None, None, None)
            .unwrap();

        store
            .append(&AppendOptions {
                session_id: &cr.session.id,
                event_type: EventType::MessageUser,
                payload: serde_json::json!({"content": "What is Rust?"}),
                parent_id: None,
            })
            .unwrap();
        store
            .append(&AppendOptions {
                session_id: &cr.session.id,
                event_type: EventType::MessageAssistant,
                payload: serde_json::json!({"content": "A systems language."}),
                parent_id: None,
            })
            .unwrap();

        let ids = [cr.session.id.as_str()];
        let previews = store.get_session_message_previews(&ids).unwrap();
        let preview = &previews[&cr.session.id];
        assert_eq!(preview.last_user_prompt.as_deref(), Some("What is Rust?"));
        assert_eq!(
            preview.last_assistant_response.as_deref(),
            Some("A systems language.")
        );
    }

    // ── Batch event queries ───────────────────────────────────────────

    #[test]
    fn get_events_by_ids_basic() {
        let store = setup();
        let cr = store
            .create_session("claude-opus-4-6", "/tmp/a", None, None, None)
            .unwrap();
        let evt = store
            .append(&AppendOptions {
                session_id: &cr.session.id,
                event_type: EventType::MessageUser,
                payload: serde_json::json!({"content": "Hello"}),
                parent_id: None,
            })
            .unwrap();

        let ids = [cr.root_event.id.as_str(), evt.id.as_str()];
        let result = store.get_events_by_ids(&ids).unwrap();
        assert_eq!(result.len(), 2);
        assert!(result.contains_key(&cr.root_event.id));
        assert!(result.contains_key(&evt.id));
    }

    #[test]
    fn get_events_by_type_basic() {
        let store = setup();
        let cr = store
            .create_session("claude-opus-4-6", "/tmp/a", None, None, None)
            .unwrap();
        store
            .append(&AppendOptions {
                session_id: &cr.session.id,
                event_type: EventType::MessageUser,
                payload: serde_json::json!({"content": "Hello"}),
                parent_id: None,
            })
            .unwrap();
        store
            .append(&AppendOptions {
                session_id: &cr.session.id,
                event_type: EventType::MessageAssistant,
                payload: serde_json::json!({"content": "Hi"}),
                parent_id: None,
            })
            .unwrap();

        let result = store
            .get_events_by_type(&cr.session.id, &["message.user"], None)
            .unwrap();
        assert_eq!(result.len(), 1);
        assert_eq!(result[0].event_type, "message.user");
    }

    #[test]
    fn get_events_by_workspace_and_types_cross_session() {
        let store = setup();
        let cr1 = store
            .create_session("claude-opus-4-6", "/tmp/proj", None, None, None)
            .unwrap();
        let cr2 = store
            .create_session("claude-opus-4-6", "/tmp/proj", None, None, None)
            .unwrap();

        store
            .append(&AppendOptions {
                session_id: &cr1.session.id,
                event_type: EventType::MessageUser,
                payload: serde_json::json!({"content": "A"}),
                parent_id: None,
            })
            .unwrap();
        store
            .append(&AppendOptions {
                session_id: &cr2.session.id,
                event_type: EventType::MessageUser,
                payload: serde_json::json!({"content": "B"}),
                parent_id: None,
            })
            .unwrap();

        let result = store
            .get_events_by_workspace_and_types(
                &cr1.session.workspace_id,
                &["message.user"],
                None,
                None,
            )
            .unwrap();
        assert_eq!(result.len(), 2);
    }

    #[test]
    fn count_events_basic() {
        let store = setup();
        let cr = store
            .create_session("claude-opus-4-6", "/tmp/a", None, None, None)
            .unwrap();
        store
            .append(&AppendOptions {
                session_id: &cr.session.id,
                event_type: EventType::MessageUser,
                payload: serde_json::json!({"content": "Hello"}),
                parent_id: None,
            })
            .unwrap();

        let count = store.count_events(&cr.session.id).unwrap();
        assert_eq!(count, 2); // root + user message
    }

    // ── State projection ──────────────────────────────────────────────

    #[test]
    fn get_messages_at_head_basic() {
        let store = setup();
        let cr = store
            .create_session("claude-opus-4-6", "/tmp/project", None, None, None)
            .unwrap();
        store
            .append(&AppendOptions {
                session_id: &cr.session.id,
                event_type: EventType::MessageUser,
                payload: serde_json::json!({"content": "Hello"}),
                parent_id: None,
            })
            .unwrap();
        store
            .append(&AppendOptions {
                session_id: &cr.session.id,
                event_type: EventType::MessageAssistant,
                payload: serde_json::json!({
                    "content": [{"type": "text", "text": "Hi there"}],
                    "turn": 1,
                }),
                parent_id: None,
            })
            .unwrap();

        let result = store.get_messages_at_head(&cr.session.id).unwrap();
        assert_eq!(result.messages_with_event_ids.len(), 2);
        assert_eq!(result.messages_with_event_ids[0].message.role, "user");
        assert_eq!(result.messages_with_event_ids[1].message.role, "assistant");
        assert_eq!(result.turn_count, 1);
    }

    #[test]
    fn get_messages_at_specific_event() {
        let store = setup();
        let cr = store
            .create_session("claude-opus-4-6", "/tmp/project", None, None, None)
            .unwrap();
        let user_evt = store
            .append(&AppendOptions {
                session_id: &cr.session.id,
                event_type: EventType::MessageUser,
                payload: serde_json::json!({"content": "Hello"}),
                parent_id: None,
            })
            .unwrap();
        store
            .append(&AppendOptions {
                session_id: &cr.session.id,
                event_type: EventType::MessageAssistant,
                payload: serde_json::json!({
                    "content": [{"type": "text", "text": "Hi"}],
                    "turn": 1,
                }),
                parent_id: None,
            })
            .unwrap();

        // Reconstruct at user message event (before assistant response)
        let result = store.get_messages_at(&user_evt.id).unwrap();
        assert_eq!(result.messages_with_event_ids.len(), 1);
        assert_eq!(result.messages_with_event_ids[0].message.role, "user");
    }

    #[test]
    fn get_messages_at_nonexistent_fails() {
        let store = setup();
        let result = store.get_messages_at("evt_nonexistent");
        assert!(result.is_err());
    }

    #[test]
    fn get_state_at_head_basic() {
        let store = setup();
        let cr = store
            .create_session("claude-opus-4-6", "/tmp/project", None, None, None)
            .unwrap();
        store
            .append(&AppendOptions {
                session_id: &cr.session.id,
                event_type: EventType::MessageUser,
                payload: serde_json::json!({"content": "Hello"}),
                parent_id: None,
            })
            .unwrap();
        store
            .append(&AppendOptions {
                session_id: &cr.session.id,
                event_type: EventType::MessageAssistant,
                payload: serde_json::json!({
                    "content": [{"type": "text", "text": "Hi"}],
                    "turn": 1,
                    "tokenUsage": {"inputTokens": 100, "outputTokens": 50}
                }),
                parent_id: None,
            })
            .unwrap();
        store
            .append(&AppendOptions {
                session_id: &cr.session.id,
                event_type: EventType::StreamTurnEnd,
                payload: serde_json::json!({
                    "tokenUsage": {"inputTokens": 100, "outputTokens": 50}
                }),
                parent_id: None,
            })
            .unwrap();

        let state = store.get_state_at_head(&cr.session.id).unwrap();
        assert_eq!(state.session_id, cr.session.id);
        assert_eq!(state.model, "claude-opus-4-6");
        assert_eq!(state.working_directory, "/tmp/project");
        assert_eq!(state.messages_with_event_ids.len(), 2);
        assert_eq!(state.turn_count, 1);
        assert_eq!(state.token_usage.input_tokens, 100);
        assert_eq!(state.token_usage.output_tokens, 50);
        assert!(state.is_ended.is_none()); // session is active
    }

    #[test]
    fn get_state_at_head_ended_session() {
        let store = setup();
        let cr = store
            .create_session("claude-opus-4-6", "/tmp/project", None, None, None)
            .unwrap();
        store.end_session(&cr.session.id).unwrap();

        let state = store.get_state_at_head(&cr.session.id).unwrap();
        assert_eq!(state.is_ended, Some(true));
    }

    #[test]
    fn get_state_at_specific_event() {
        let store = setup();
        let cr = store
            .create_session("claude-opus-4-6", "/tmp/project", None, None, None)
            .unwrap();
        let user_evt = store
            .append(&AppendOptions {
                session_id: &cr.session.id,
                event_type: EventType::MessageUser,
                payload: serde_json::json!({"content": "Hello"}),
                parent_id: None,
            })
            .unwrap();
        store
            .append(&AppendOptions {
                session_id: &cr.session.id,
                event_type: EventType::MessageAssistant,
                payload: serde_json::json!({
                    "content": [{"type": "text", "text": "Hi"}],
                    "turn": 1,
                }),
                parent_id: None,
            })
            .unwrap();

        let state = store.get_state_at(&cr.session.id, &user_evt.id).unwrap();
        assert_eq!(state.head_event_id, user_evt.id);
        assert_eq!(state.messages_with_event_ids.len(), 1);
        assert_eq!(state.messages_with_event_ids[0].message.role, "user");
    }

    #[test]
    fn get_state_at_head_nonexistent_session_fails() {
        let store = setup();
        let result = store.get_state_at_head("sess_nonexistent");
        assert!(result.is_err());
    }

    #[test]
    fn get_state_at_head_with_agentic_loop() {
        let store = setup();
        let cr = store
            .create_session("claude-opus-4-6", "/tmp/project", None, None, None)
            .unwrap();

        store
            .append(&AppendOptions {
                session_id: &cr.session.id,
                event_type: EventType::MessageUser,
                payload: serde_json::json!({"content": "Use a tool"}),
                parent_id: None,
            })
            .unwrap();
        store
            .append(&AppendOptions {
                session_id: &cr.session.id,
                event_type: EventType::MessageAssistant,
                payload: serde_json::json!({
                    "content": [{"type": "tool_use", "id": "c1", "name": "Bash", "arguments": {}}],
                    "turn": 1,
                }),
                parent_id: None,
            })
            .unwrap();
        store
            .append(&AppendOptions {
                session_id: &cr.session.id,
                event_type: EventType::ToolResult,
                payload: serde_json::json!({"toolCallId": "c1", "content": "output", "isError": false}),
                parent_id: None,
            })
            .unwrap();
        store
            .append(&AppendOptions {
                session_id: &cr.session.id,
                event_type: EventType::MessageAssistant,
                payload: serde_json::json!({
                    "content": [{"type": "text", "text": "Done"}],
                    "turn": 2,
                }),
                parent_id: None,
            })
            .unwrap();

        let state = store.get_state_at_head(&cr.session.id).unwrap();
        // user, assistant, toolResult, assistant
        assert_eq!(state.messages_with_event_ids.len(), 4);
        assert_eq!(state.messages_with_event_ids[0].message.role, "user");
        assert_eq!(state.messages_with_event_ids[1].message.role, "assistant");
        assert_eq!(state.messages_with_event_ids[2].message.role, "toolResult");
        assert_eq!(state.messages_with_event_ids[3].message.role, "assistant");
    }

    #[test]
    fn get_state_at_head_with_compaction() {
        let store = setup();
        let cr = store
            .create_session("claude-opus-4-6", "/tmp/project", None, None, None)
            .unwrap();

        store
            .append(&AppendOptions {
                session_id: &cr.session.id,
                event_type: EventType::MessageUser,
                payload: serde_json::json!({"content": "Old message"}),
                parent_id: None,
            })
            .unwrap();
        store
            .append(&AppendOptions {
                session_id: &cr.session.id,
                event_type: EventType::CompactSummary,
                payload: serde_json::json!({"summary": "User said hello"}),
                parent_id: None,
            })
            .unwrap();
        store
            .append(&AppendOptions {
                session_id: &cr.session.id,
                event_type: EventType::MessageUser,
                payload: serde_json::json!({"content": "New message"}),
                parent_id: None,
            })
            .unwrap();

        let state = store.get_state_at_head(&cr.session.id).unwrap();
        // synthetic user (summary), synthetic assistant (ack), new user
        assert_eq!(state.messages_with_event_ids.len(), 3);
        assert!(
            state.messages_with_event_ids[0]
                .message
                .content
                .as_str()
                .unwrap()
                .contains("Context from earlier")
        );
        assert_eq!(
            state.messages_with_event_ids[2].message.content,
            "New message"
        );
    }

    // ── Helpers ───────────────────────────────────────────────────────

    #[test]
    fn event_rows_to_session_events_converts_correctly() {
        let row = EventRow {
            id: "evt_1".to_string(),
            session_id: "sess_1".to_string(),
            parent_id: None,
            sequence: 0,
            depth: 0,
            event_type: "session.start".to_string(),
            timestamp: "2025-01-01T00:00:00Z".to_string(),
            payload: r#"{"model":"claude-opus-4-6"}"#.to_string(),
            content_blob_id: None,
            workspace_id: "ws_1".to_string(),
            role: None,
            tool_name: None,
            tool_call_id: None,
            turn: None,
            input_tokens: None,
            output_tokens: None,
            cache_read_tokens: None,
            cache_creation_tokens: None,
            checksum: None,
            model: None,
            latency_ms: None,
            stop_reason: None,
            has_thinking: None,
            provider_type: None,
            cost: None,
        };

        let events = super::event_rows_to_session_events(&[row]);
        assert_eq!(events.len(), 1);
        assert_eq!(events[0].id, "evt_1");
        assert_eq!(events[0].event_type, EventType::SessionStart);
        assert_eq!(events[0].payload["model"], "claude-opus-4-6");
    }

    #[test]
    fn event_rows_to_session_events_handles_invalid_json() {
        let row = EventRow {
            id: "evt_1".to_string(),
            session_id: "sess_1".to_string(),
            parent_id: None,
            sequence: 0,
            depth: 0,
            event_type: "message.user".to_string(),
            timestamp: "2025-01-01T00:00:00Z".to_string(),
            payload: "not-json".to_string(),
            content_blob_id: None,
            workspace_id: "ws_1".to_string(),
            role: None,
            tool_name: None,
            tool_call_id: None,
            turn: None,
            input_tokens: None,
            output_tokens: None,
            cache_read_tokens: None,
            cache_creation_tokens: None,
            checksum: None,
            model: None,
            latency_ms: None,
            stop_reason: None,
            has_thinking: None,
            provider_type: None,
            cost: None,
        };

        let events = super::event_rows_to_session_events(&[row]);
        assert_eq!(events.len(), 1);
        assert!(events[0].payload.is_null());
    }

    // ── Concurrency (write serialization) ───────────────────────────

    fn setup_file_backed() -> (EventStore, tempfile::TempDir) {
        let dir = tempfile::tempdir().unwrap();
        let db_path = dir.path().join("test.db");
        let pool =
            connection::new_file(db_path.to_str().unwrap(), &ConnectionConfig::default()).unwrap();
        {
            let conn = pool.get().unwrap();
            run_migrations(&conn).unwrap();
        }
        (EventStore::new(pool), dir)
    }

    #[test]
    fn concurrent_appends_produce_unique_sequences() {
        use std::sync::Arc;

        let (store, _dir) = setup_file_backed();
        let store = Arc::new(store);

        let cr = store
            .create_session("claude-opus-4-6", "/tmp/project", None, None, None)
            .unwrap();
        let session_id = cr.session.id.clone();

        let threads: Vec<_> = (0..20)
            .map(|_| {
                let store = Arc::clone(&store);
                let sid = session_id.clone();
                std::thread::spawn(move || {
                    let mut ids = Vec::new();
                    for _ in 0..10 {
                        let event = store
                            .append(&AppendOptions {
                                session_id: &sid,
                                event_type: EventType::MessageUser,
                                payload: serde_json::json!({"content": "concurrent"}),
                                parent_id: None,
                            })
                            .unwrap();
                        ids.push((event.id, event.sequence));
                    }
                    ids
                })
            })
            .collect();

        let mut all_sequences = std::collections::HashSet::new();
        for handle in threads {
            let ids = handle.join().unwrap();
            for (_id, seq) in ids {
                assert!(all_sequences.insert(seq), "duplicate sequence: {seq}");
            }
        }

        // root (seq 0) + 200 appended events = 201 unique sequences
        assert_eq!(all_sequences.len(), 200);
    }

    #[test]
    fn concurrent_appends_to_different_sessions() {
        use std::sync::Arc;

        let (store, _dir) = setup_file_backed();
        let store = Arc::new(store);

        let threads: Vec<_> = (0..10)
            .map(|i| {
                let store = Arc::clone(&store);
                std::thread::spawn(move || {
                    let cr = store
                        .create_session(
                            "claude-opus-4-6",
                            &format!("/tmp/project-{i}"),
                            None,
                            None,
                            None,
                        )
                        .unwrap();
                    for _ in 0..5 {
                        store
                            .append(&AppendOptions {
                                session_id: &cr.session.id,
                                event_type: EventType::MessageUser,
                                payload: serde_json::json!({"content": "msg"}),
                                parent_id: None,
                            })
                            .unwrap();
                    }
                    cr.session.id
                })
            })
            .collect();

        for handle in threads {
            let sid = handle.join().unwrap();
            let count = store.count_events(&sid).unwrap();
            assert_eq!(count, 6); // 1 root + 5 appended
        }
    }

    #[test]
    fn concurrent_reads_during_writes() {
        use std::sync::Arc;
        use std::sync::atomic::{AtomicBool, Ordering};

        let (store, _dir) = setup_file_backed();
        let store = Arc::new(store);

        let cr = store
            .create_session("claude-opus-4-6", "/tmp/project", None, None, None)
            .unwrap();
        let session_id = cr.session.id.clone();

        let done = Arc::new(AtomicBool::new(false));

        // Writer thread: append 50 events
        let writer_store = Arc::clone(&store);
        let writer_sid = session_id.clone();
        let writer_done = Arc::clone(&done);
        let writer = std::thread::spawn(move || {
            for _ in 0..50 {
                writer_store
                    .append(&AppendOptions {
                        session_id: &writer_sid,
                        event_type: EventType::MessageUser,
                        payload: serde_json::json!({"content": "write"}),
                        parent_id: None,
                    })
                    .unwrap();
            }
            writer_done.store(true, Ordering::SeqCst);
        });

        // Reader threads: query continuously until writer is done
        let readers: Vec<_> = (0..4)
            .map(|_| {
                let store = Arc::clone(&store);
                let sid = session_id.clone();
                let done = Arc::clone(&done);
                std::thread::spawn(move || {
                    let mut read_count = 0u64;
                    while !done.load(Ordering::SeqCst) {
                        let events = store
                            .get_events_by_session(&sid, &ListEventsOptions::default())
                            .unwrap();
                        // Events should always be ordered by sequence
                        for pair in events.windows(2) {
                            assert!(pair[0].sequence < pair[1].sequence, "events not ordered");
                        }
                        read_count += 1;
                    }
                    read_count
                })
            })
            .collect();

        writer.join().unwrap();
        for handle in readers {
            let reads = handle.join().unwrap();
            assert!(reads > 0, "reader should have performed at least one read");
        }

        // Final check: all 51 events present (root + 50)
        let final_count = store.count_events(&session_id).unwrap();
        assert_eq!(final_count, 51);
    }

    // ── Worktree queries ─────────────────────────────────────────────

    #[test]
    fn get_active_worktree_none() {
        let store = setup();
        let session = store
            .create_session("model", "/tmp", Some("test"), None, None)
            .unwrap();
        let result = store.get_active_worktree(&session.session.id).unwrap();
        assert!(result.is_none());
    }

    #[test]
    fn get_active_worktree_acquired() {
        let store = setup();
        let session = store
            .create_session("model", "/tmp", Some("test"), None, None)
            .unwrap();
        let sid = &session.session.id;

        store
            .append(&AppendOptions {
                session_id: sid,
                event_type: EventType::WorktreeAcquired,
                payload: serde_json::json!({
                    "path": "/repo/.worktrees/session/abc",
                    "branch": "session/abc",
                    "baseCommit": "deadbeef",
                    "isolated": true
                }),
                parent_id: None,
            })
            .unwrap();

        let result = store.get_active_worktree(sid).unwrap();
        assert!(result.is_some());
    }

    #[test]
    fn get_active_worktree_released() {
        let store = setup();
        let session = store
            .create_session("model", "/tmp", Some("test"), None, None)
            .unwrap();
        let sid = &session.session.id;

        store
            .append(&AppendOptions {
                session_id: sid,
                event_type: EventType::WorktreeAcquired,
                payload: serde_json::json!({
                    "path": "/repo/.worktrees/session/abc",
                    "branch": "session/abc",
                    "baseCommit": "deadbeef",
                    "isolated": true
                }),
                parent_id: None,
            })
            .unwrap();

        store
            .append(&AppendOptions {
                session_id: sid,
                event_type: EventType::WorktreeReleased,
                payload: serde_json::json!({
                    "deleted": true,
                    "branchPreserved": true
                }),
                parent_id: None,
            })
            .unwrap();

        let result = store.get_active_worktree(sid).unwrap();
        assert!(result.is_none());
    }

    #[test]
    fn get_active_worktree_reacquired() {
        let store = setup();
        let session = store
            .create_session("model", "/tmp", Some("test"), None, None)
            .unwrap();
        let sid = &session.session.id;

        // Acquired
        store
            .append(&AppendOptions {
                session_id: sid,
                event_type: EventType::WorktreeAcquired,
                payload: serde_json::json!({
                    "path": "/first", "branch": "b1", "baseCommit": "aaa", "isolated": true
                }),
                parent_id: None,
            })
            .unwrap();

        // Released
        store
            .append(&AppendOptions {
                session_id: sid,
                event_type: EventType::WorktreeReleased,
                payload: serde_json::json!({ "deleted": true, "branchPreserved": true }),
                parent_id: None,
            })
            .unwrap();

        // Re-acquired
        store
            .append(&AppendOptions {
                session_id: sid,
                event_type: EventType::WorktreeAcquired,
                payload: serde_json::json!({
                    "path": "/second", "branch": "b2", "baseCommit": "bbb", "isolated": true
                }),
                parent_id: None,
            })
            .unwrap();

        let result = store.get_active_worktree(sid).unwrap();
        assert!(result.is_some());
        let event = result.unwrap();
        let payload: serde_json::Value = serde_json::from_str(&event.payload).unwrap();
        assert_eq!(payload["path"], "/second");
    }
}
