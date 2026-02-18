//! Event creation utilities.
//!
//! [`EventFactory`] is scoped to a `session_id` and `workspace_id`, providing
//! convenient methods for building [`SessionEvent`] structs with auto-generated
//! IDs and timestamps.
//!
//! [`EventChainBuilder`] wraps an [`EventStore`](crate::store::EventStore) and
//! auto-threads `parent_id` across sequential appends — callers never need to
//! track the current head manually.

use serde_json::Value;
use uuid::Uuid;

use crate::types::EventType;
use crate::types::base::SessionEvent;

/// Scoped event factory — creates [`SessionEvent`] structs for a single session.
///
/// All events share the same `session_id` and `workspace_id`. IDs and timestamps
/// are auto-generated.
pub struct EventFactory {
    session_id: String,
    workspace_id: String,
}

impl EventFactory {
    /// Create a factory scoped to a session and workspace.
    pub fn new(session_id: impl Into<String>, workspace_id: impl Into<String>) -> Self {
        Self {
            session_id: session_id.into(),
            workspace_id: workspace_id.into(),
        }
    }

    /// Session ID this factory is scoped to.
    pub fn session_id(&self) -> &str {
        &self.session_id
    }

    /// Workspace ID this factory is scoped to.
    pub fn workspace_id(&self) -> &str {
        &self.workspace_id
    }

    /// Generate a new event ID.
    pub fn generate_event_id() -> String {
        format!("evt_{}", Uuid::now_v7())
    }

    /// Create a `session.start` event (root of a new session).
    pub fn create_session_start(&self, model: &str, working_directory: &str) -> SessionEvent {
        SessionEvent {
            id: Self::generate_event_id(),
            parent_id: None,
            session_id: self.session_id.clone(),
            workspace_id: self.workspace_id.clone(),
            timestamp: chrono::Utc::now().to_rfc3339(),
            event_type: EventType::SessionStart,
            sequence: 0,
            checksum: None,
            payload: serde_json::json!({
                "workingDirectory": working_directory,
                "model": model,
            }),
        }
    }

    /// Create a `session.fork` event (root of a forked session).
    pub fn create_session_fork(
        &self,
        parent_id: &str,
        source_session_id: &str,
        source_event_id: &str,
    ) -> SessionEvent {
        SessionEvent {
            id: Self::generate_event_id(),
            parent_id: Some(parent_id.to_string()),
            session_id: self.session_id.clone(),
            workspace_id: self.workspace_id.clone(),
            timestamp: chrono::Utc::now().to_rfc3339(),
            event_type: EventType::SessionFork,
            sequence: 0,
            checksum: None,
            payload: serde_json::json!({
                "sourceSessionId": source_session_id,
                "sourceEventId": source_event_id,
            }),
        }
    }

    /// Create a generic event with any type.
    pub fn create_event(
        &self,
        event_type: EventType,
        parent_id: Option<&str>,
        sequence: i64,
        payload: Value,
    ) -> SessionEvent {
        SessionEvent {
            id: Self::generate_event_id(),
            parent_id: parent_id.map(String::from),
            session_id: self.session_id.clone(),
            workspace_id: self.workspace_id.clone(),
            timestamp: chrono::Utc::now().to_rfc3339(),
            event_type,
            sequence,
            checksum: None,
            payload,
        }
    }
}

/// Chains sequential events with automatic `parent_id` threading.
///
/// Tracks the current head event ID. Each call to [`append`](Self::append)
/// creates a new event whose `parent_id` is the previous head, then advances
/// the head to the newly created event.
///
/// Uses the [`EventStore`](crate::store::EventStore) for persistence.
pub struct EventChainBuilder {
    store: crate::store::EventStore,
    session_id: String,
    head: String,
}

impl EventChainBuilder {
    /// Create a chain builder starting from the given head event.
    pub fn new(
        store: crate::store::EventStore,
        session_id: impl Into<String>,
        initial_head: impl Into<String>,
    ) -> Self {
        Self {
            store,
            session_id: session_id.into(),
            head: initial_head.into(),
        }
    }

    /// Current head event ID.
    pub fn head_event_id(&self) -> &str {
        &self.head
    }

    /// Append an event chained from the current head, then advance the head.
    pub fn append(
        &mut self,
        event_type: EventType,
        payload: Value,
    ) -> crate::errors::Result<crate::sqlite::row_types::EventRow> {
        let event = self.store.append(&crate::store::AppendOptions {
            session_id: &self.session_id,
            event_type,
            payload,
            parent_id: Some(&self.head),
        })?;
        self.head.clone_from(&event.id);
        Ok(event)
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

#[cfg(test)]
#[allow(unused_results)]
mod tests {
    use super::*;

    // ── EventFactory ──────────────────────────────────────────────────

    #[test]
    fn factory_scoped_fields() {
        let factory = EventFactory::new("sess_1", "ws_1");
        assert_eq!(factory.session_id(), "sess_1");
        assert_eq!(factory.workspace_id(), "ws_1");
    }

    #[test]
    fn generate_event_id_format() {
        let id = EventFactory::generate_event_id();
        assert!(id.starts_with("evt_"));
        assert!(id.len() > 4);
    }

    #[test]
    fn generate_event_id_unique() {
        let ids: Vec<String> = (0..100)
            .map(|_| EventFactory::generate_event_id())
            .collect();
        let unique: std::collections::HashSet<&String> = ids.iter().collect();
        assert_eq!(unique.len(), 100);
    }

    #[test]
    fn create_session_start() {
        let factory = EventFactory::new("sess_1", "ws_1");
        let event = factory.create_session_start("claude-opus-4-6", "/tmp/project");

        assert!(event.id.starts_with("evt_"));
        assert!(event.parent_id.is_none());
        assert_eq!(event.session_id, "sess_1");
        assert_eq!(event.workspace_id, "ws_1");
        assert_eq!(event.event_type, EventType::SessionStart);
        assert_eq!(event.sequence, 0);
        assert_eq!(event.payload["model"], "claude-opus-4-6");
        assert_eq!(event.payload["workingDirectory"], "/tmp/project");
    }

    #[test]
    fn create_session_fork() {
        let factory = EventFactory::new("sess_forked", "ws_1");
        let event = factory.create_session_fork("evt_parent", "sess_source", "evt_source");

        assert!(event.id.starts_with("evt_"));
        assert_eq!(event.parent_id.as_deref(), Some("evt_parent"));
        assert_eq!(event.session_id, "sess_forked");
        assert_eq!(event.event_type, EventType::SessionFork);
        assert_eq!(event.sequence, 0);
        assert_eq!(event.payload["sourceSessionId"], "sess_source");
        assert_eq!(event.payload["sourceEventId"], "evt_source");
    }

    #[test]
    fn create_generic_event() {
        let factory = EventFactory::new("sess_1", "ws_1");
        let event = factory.create_event(
            EventType::MessageUser,
            Some("evt_parent"),
            5,
            serde_json::json!({"content": "Hello"}),
        );

        assert!(event.id.starts_with("evt_"));
        assert_eq!(event.parent_id.as_deref(), Some("evt_parent"));
        assert_eq!(event.event_type, EventType::MessageUser);
        assert_eq!(event.sequence, 5);
        assert_eq!(event.payload["content"], "Hello");
    }

    #[test]
    fn create_event_no_parent() {
        let factory = EventFactory::new("sess_1", "ws_1");
        let event = factory.create_event(EventType::ContextCleared, None, 3, serde_json::json!({}));

        assert!(event.parent_id.is_none());
    }

    // ── EventChainBuilder ─────────────────────────────────────────────

    #[test]
    fn chain_builder_auto_threads() {
        use crate::sqlite::connection::{self, ConnectionConfig};
        use crate::sqlite::migrations::run_migrations;

        let pool = connection::new_in_memory(&ConnectionConfig::default()).unwrap();
        {
            let conn = pool.get().unwrap();
            run_migrations(&conn).unwrap();
        }
        let store = crate::store::EventStore::new(pool.clone());

        let cr = store
            .create_session("claude-opus-4-6", "/tmp/project", None)
            .unwrap();

        let store2 = crate::store::EventStore::new(pool);
        let mut chain = EventChainBuilder::new(store2, &cr.session.id, &cr.root_event.id);

        assert_eq!(chain.head_event_id(), cr.root_event.id);

        let evt1 = chain
            .append(
                EventType::MessageUser,
                serde_json::json!({"content": "Hello"}),
            )
            .unwrap();
        assert_eq!(evt1.parent_id.as_deref(), Some(cr.root_event.id.as_str()));
        assert_eq!(chain.head_event_id(), evt1.id);

        let evt2 = chain
            .append(
                EventType::MessageAssistant,
                serde_json::json!({"content": "World"}),
            )
            .unwrap();
        assert_eq!(evt2.parent_id.as_deref(), Some(evt1.id.as_str()));
        assert_eq!(chain.head_event_id(), evt2.id);

        let evt3 = chain
            .append(EventType::ToolCall, serde_json::json!({"toolName": "Bash"}))
            .unwrap();
        assert_eq!(evt3.parent_id.as_deref(), Some(evt2.id.as_str()));

        // Verify linear chain via ancestors
        let ancestors = store.get_ancestors(&evt3.id).unwrap();
        assert_eq!(ancestors.len(), 4); // root → evt1 → evt2 → evt3
    }
}
