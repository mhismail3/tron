//! High-level transactional `EventStore` API.
//!
//! Composes all repository operations into atomic, session-centric methods.
//! Every write method runs inside a single `SQLite` transaction — callers
//! never observe partial state.

use serde_json::Value;
use uuid::Uuid;

use crate::errors::{EventStoreError, Result};
use crate::sqlite::connection::{ConnectionPool, PooledConnection};
use crate::sqlite::repositories::blob::BlobRepo;
use crate::sqlite::repositories::branch::BranchRepo;
use crate::sqlite::repositories::event::{EventRepo, ListEventsOptions, TokenUsageSummary};
use crate::sqlite::repositories::search::{SearchOptions, SearchRepo};
use crate::sqlite::repositories::session::{
    CreateSessionOptions, IncrementCounters, ListSessionsOptions, SessionRepo,
};
use crate::sqlite::repositories::workspace::WorkspaceRepo;
use crate::sqlite::row_types::{BlobRow, EventRow, SessionRow, WorkspaceRow};
use crate::types::base::SessionEvent;
use crate::types::state::SearchResult;
use crate::types::EventType;

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
pub struct EventStore {
    pool: ConnectionPool,
}

impl EventStore {
    /// Create a new `EventStore` with the given connection pool.
    pub fn new(pool: ConnectionPool) -> Self {
        Self { pool }
    }

    /// Get a connection from the pool.
    fn conn(&self) -> Result<PooledConnection> {
        Ok(self.pool.get()?)
    }

    // ─────────────────────────────────────────────────────────────────────
    // Session lifecycle
    // ─────────────────────────────────────────────────────────────────────

    /// Create a new session with a root `session.start` event.
    ///
    /// Atomic: workspace creation (get-or-create), session insertion, root event
    /// insertion, head/root pointer updates, and counter increments all happen
    /// in a single transaction.
    pub fn create_session(
        &self,
        model: &str,
        workspace_path: &str,
        title: Option<&str>,
    ) -> Result<CreateSessionResult> {
        let conn = self.conn()?;
        let tx = conn.unchecked_transaction()?;

        // 1. Get or create workspace
        let ws = WorkspaceRepo::get_or_create(&tx, workspace_path, None)?;

        // 2. Create session
        let session = SessionRepo::create(
            &tx,
            &CreateSessionOptions {
                workspace_id: &ws.id,
                model,
                working_directory: workspace_path,
                title,
                tags: None,
                parent_session_id: None,
                fork_from_event_id: None,
                spawning_session_id: None,
                spawn_type: None,
                spawn_task: None,
            },
        )?;

        // 3. Create root session.start event
        let event_id = format!("evt_{}", Uuid::now_v7());
        let now = chrono::Utc::now().to_rfc3339();
        let payload = serde_json::json!({
            "workingDirectory": workspace_path,
            "model": model,
        });
        let event = SessionEvent {
            id: event_id,
            session_id: session.id.clone(),
            parent_id: None,
            workspace_id: ws.id.clone(),
            timestamp: now,
            event_type: EventType::SessionStart,
            sequence: 0,
            checksum: None,
            payload,
        };
        EventRepo::insert(&tx, &event)?;

        // 4. Update session root and head
        let _ = SessionRepo::update_root(&tx, &session.id, &event.id)?;
        let _ = SessionRepo::update_head(&tx, &session.id, &event.id)?;

        // 5. Increment event count
        let _ = SessionRepo::increment_counters(
            &tx,
            &session.id,
            &IncrementCounters {
                event_count: Some(1),
                ..Default::default()
            },
        )?;

        tx.commit()?;

        // Re-fetch session to get updated head/root/counters
        let updated_session = SessionRepo::get_by_id(&conn, &session.id)?
            .ok_or(EventStoreError::SessionNotFound(session.id))?;

        // Re-read the event row to get denormalized fields
        let root_event = EventRepo::get_by_id(&conn, &event.id)?
            .ok_or(EventStoreError::EventNotFound(event.id))?;

        Ok(CreateSessionResult {
            session: updated_session,
            root_event,
        })
    }

    /// Append an event to a session.
    ///
    /// Atomic: sequence generation, event insertion, head update, and counter
    /// increments all happen in a single transaction.
    pub fn append(&self, opts: &AppendOptions<'_>) -> Result<EventRow> {
        let conn = self.conn()?;
        let tx = conn.unchecked_transaction()?;

        // 1. Fetch session (must exist)
        let session = SessionRepo::get_by_id(&tx, opts.session_id)?
            .ok_or_else(|| EventStoreError::SessionNotFound(opts.session_id.to_string()))?;

        // 2. Resolve parent
        let parent_id = match opts.parent_id {
            Some(pid) => Some(pid.to_string()),
            None => session.head_event_id.clone(),
        };

        // 3. Get next sequence
        let sequence = EventRepo::get_next_sequence(&tx, opts.session_id)?;

        // 4. Build event (depth is computed by EventRepo::insert)
        let event_id = format!("evt_{}", Uuid::now_v7());
        let now = chrono::Utc::now().to_rfc3339();

        let event = SessionEvent {
            id: event_id,
            session_id: opts.session_id.to_string(),
            parent_id,
            workspace_id: session.workspace_id.clone(),
            timestamp: now,
            event_type: opts.event_type,
            sequence,
            checksum: None,
            payload: opts.payload.clone(),
        };

        // 6. Insert (repo extracts denormalized fields from payload)
        EventRepo::insert(&tx, &event)?;

        // 7. Update session head
        let _ = SessionRepo::update_head(&tx, opts.session_id, &event.id)?;

        // 8. Build counter increments
        let mut counters = IncrementCounters {
            event_count: Some(1),
            ..Default::default()
        };

        // Message count
        if matches!(
            opts.event_type,
            EventType::MessageUser | EventType::MessageAssistant
        ) {
            counters.message_count = Some(1);
        }

        // Token usage from payload
        if let Some(tu) = opts.payload.get("tokenUsage") {
            counters.input_tokens = tu.get("inputTokens").and_then(Value::as_i64);
            counters.output_tokens = tu.get("outputTokens").and_then(Value::as_i64);
            counters.cache_read_tokens = tu.get("cacheReadInputTokens").and_then(Value::as_i64);
            counters.cache_creation_tokens =
                tu.get("cacheCreationInputTokens").and_then(Value::as_i64);
        }

        // Cost from payload
        if let Some(cost) = opts.payload.get("cost").and_then(Value::as_f64) {
            counters.cost = Some(cost);
        }

        let _ = SessionRepo::increment_counters(&tx, opts.session_id, &counters)?;

        tx.commit()?;

        // Re-read the event to get denormalized fields set by insert
        let inserted = EventRepo::get_by_id(&conn, &event.id)?
            .ok_or(EventStoreError::EventNotFound(event.id))?;
        Ok(inserted)
    }

    /// Fork a session from a specific event.
    ///
    /// Creates a new session whose root `session.fork` event has its `parent_id`
    /// pointing into the source session's event tree. Ancestor walks from the
    /// fork event traverse back through the shared history.
    pub fn fork(
        &self,
        from_event_id: &str,
        opts: &ForkOptions<'_>,
    ) -> Result<ForkResult> {
        let conn = self.conn()?;
        let tx = conn.unchecked_transaction()?;

        // 1. Fetch source event
        let source_event = EventRepo::get_by_id(&tx, from_event_id)?
            .ok_or_else(|| EventStoreError::EventNotFound(from_event_id.to_string()))?;

        // 2. Fetch source session
        let source_session = SessionRepo::get_by_id(&tx, &source_event.session_id)?
            .ok_or_else(|| EventStoreError::SessionNotFound(source_event.session_id.clone()))?;

        // 3. Create forked session
        let model = opts.model.unwrap_or(&source_session.latest_model);
        let session = SessionRepo::create(
            &tx,
            &CreateSessionOptions {
                workspace_id: &source_session.workspace_id,
                model,
                working_directory: &source_session.working_directory,
                title: opts.title,
                tags: None,
                parent_session_id: Some(&source_session.id),
                fork_from_event_id: Some(from_event_id),
                spawning_session_id: None,
                spawn_type: None,
                spawn_task: None,
            },
        )?;

        // 4. Create fork event (parentId points into source tree)
        let event_id = format!("evt_{}", Uuid::now_v7());
        let now = chrono::Utc::now().to_rfc3339();
        let payload = serde_json::json!({
            "sourceSessionId": source_session.id,
            "sourceEventId": from_event_id,
        });

        let fork_event = SessionEvent {
            id: event_id,
            session_id: session.id.clone(),
            parent_id: Some(from_event_id.to_string()),
            workspace_id: source_session.workspace_id.clone(),
            timestamp: now,
            event_type: EventType::SessionFork,
            sequence: 0,
            checksum: None,
            payload,
        };
        EventRepo::insert(&tx, &fork_event)?;

        // 5. Set root and head
        let _ = SessionRepo::update_root(&tx, &session.id, &fork_event.id)?;
        let _ = SessionRepo::update_head(&tx, &session.id, &fork_event.id)?;

        // 6. Increment event count
        let _ = SessionRepo::increment_counters(
            &tx,
            &session.id,
            &IncrementCounters {
                event_count: Some(1),
                ..Default::default()
            },
        )?;

        tx.commit()?;

        let updated_session = SessionRepo::get_by_id(&conn, &session.id)?
            .ok_or(EventStoreError::SessionNotFound(session.id))?;

        let fork_event_row = EventRepo::get_by_id(&conn, &fork_event.id)?
            .ok_or(EventStoreError::EventNotFound(fork_event.id))?;

        Ok(ForkResult {
            session: updated_session,
            fork_event: fork_event_row,
        })
    }

    /// Delete a message by appending a `message.deleted` event.
    ///
    /// The target event must be a message event (`message.user`, `message.assistant`,
    /// or `tool.result`). The original event is never modified — deletion is recorded
    /// as a new event and applied during message reconstruction.
    pub fn delete_message(
        &self,
        session_id: &str,
        target_event_id: &str,
        reason: Option<&str>,
    ) -> Result<EventRow> {
        // Validate target exists and is a message type
        let conn = self.conn()?;
        let target = EventRepo::get_by_id(&conn, target_event_id)?
            .ok_or_else(|| EventStoreError::EventNotFound(target_event_id.to_string()))?;

        let target_type: EventType = target
            .event_type
            .parse()
            .map_err(|_| EventStoreError::InvalidOperation("Unknown event type".to_string()))?;

        if !matches!(
            target_type,
            EventType::MessageUser | EventType::MessageAssistant | EventType::ToolResult
        ) {
            return Err(EventStoreError::InvalidOperation(format!(
                "Cannot delete event of type '{}' — only message and tool result events can be deleted",
                target.event_type
            )));
        }

        // Append message.deleted event
        self.append(&AppendOptions {
            session_id,
            event_type: EventType::MessageDeleted,
            payload: serde_json::json!({
                "targetEventId": target_event_id,
                "targetType": target.event_type,
                "reason": reason.unwrap_or("user_request"),
            }),
            parent_id: None,
        })
    }

    // ─────────────────────────────────────────────────────────────────────
    // Event retrieval
    // ─────────────────────────────────────────────────────────────────────

    /// Get a single event by ID.
    pub fn get_event(&self, event_id: &str) -> Result<Option<EventRow>> {
        let conn = self.conn()?;
        EventRepo::get_by_id(&conn, event_id)
    }

    /// Get all events for a session, ordered by sequence.
    pub fn get_events_by_session(
        &self,
        session_id: &str,
        opts: &ListEventsOptions,
    ) -> Result<Vec<EventRow>> {
        let conn = self.conn()?;
        EventRepo::get_by_session(&conn, session_id, opts)
    }

    /// Get ancestor chain from root to the given event (inclusive).
    pub fn get_ancestors(&self, event_id: &str) -> Result<Vec<EventRow>> {
        let conn = self.conn()?;
        EventRepo::get_ancestors(&conn, event_id)
    }

    /// Get direct children of an event.
    pub fn get_children(&self, event_id: &str) -> Result<Vec<EventRow>> {
        let conn = self.conn()?;
        EventRepo::get_children(&conn, event_id)
    }

    /// Get all descendants of an event (recursive).
    pub fn get_descendants(&self, event_id: &str) -> Result<Vec<EventRow>> {
        let conn = self.conn()?;
        EventRepo::get_descendants(&conn, event_id)
    }

    /// Get events inserted after a specific sequence number.
    pub fn get_events_since(
        &self,
        session_id: &str,
        after_sequence: i64,
    ) -> Result<Vec<EventRow>> {
        let conn = self.conn()?;
        EventRepo::get_since(&conn, session_id, after_sequence)
    }

    /// Get token usage summary for a session.
    pub fn get_token_usage_summary(&self, session_id: &str) -> Result<TokenUsageSummary> {
        let conn = self.conn()?;
        EventRepo::get_token_usage_summary(&conn, session_id)
    }

    // ─────────────────────────────────────────────────────────────────────
    // Session management
    // ─────────────────────────────────────────────────────────────────────

    /// Get session by ID.
    pub fn get_session(&self, session_id: &str) -> Result<Option<SessionRow>> {
        let conn = self.conn()?;
        SessionRepo::get_by_id(&conn, session_id)
    }

    /// List sessions with filtering.
    pub fn list_sessions(&self, opts: &ListSessionsOptions<'_>) -> Result<Vec<SessionRow>> {
        let conn = self.conn()?;
        SessionRepo::list(&conn, opts)
    }

    /// Mark a session as ended.
    pub fn end_session(&self, session_id: &str) -> Result<bool> {
        let conn = self.conn()?;
        SessionRepo::mark_ended(&conn, session_id)
    }

    /// Reactivate an ended session.
    pub fn clear_session_ended(&self, session_id: &str) -> Result<bool> {
        let conn = self.conn()?;
        SessionRepo::clear_ended(&conn, session_id)
    }

    /// Update the latest model for a session.
    pub fn update_latest_model(&self, session_id: &str, model: &str) -> Result<bool> {
        let conn = self.conn()?;
        SessionRepo::update_latest_model(&conn, session_id, model)
    }

    /// Update session title.
    pub fn update_session_title(&self, session_id: &str, title: Option<&str>) -> Result<bool> {
        let conn = self.conn()?;
        SessionRepo::update_title(&conn, session_id, title)
    }

    /// Delete a session and all its events.
    pub fn delete_session(&self, session_id: &str) -> Result<bool> {
        let conn = self.conn()?;
        let tx = conn.unchecked_transaction()?;

        // Delete events first (foreign key constraint)
        let _ = EventRepo::delete_by_session(&tx, session_id)?;
        let _ = BranchRepo::delete_by_session(&tx, session_id)?;
        let deleted = SessionRepo::delete(&tx, session_id)?;

        tx.commit()?;
        Ok(deleted)
    }

    /// List subagent sessions for a parent.
    pub fn list_subagents(&self, spawning_session_id: &str) -> Result<Vec<SessionRow>> {
        let conn = self.conn()?;
        SessionRepo::list_subagents(&conn, spawning_session_id)
    }

    /// Update session spawn info (links child to parent session).
    pub fn update_spawn_info(
        &self,
        session_id: &str,
        spawning_session_id: &str,
        spawn_type: &str,
        spawn_task: &str,
    ) -> Result<bool> {
        let conn = self.conn()?;
        let changed = conn.execute(
            "UPDATE sessions SET spawning_session_id = ?1, spawn_type = ?2, spawn_task = ?3 WHERE id = ?4",
            rusqlite::params![spawning_session_id, spawn_type, spawn_task, session_id],
        )?;
        Ok(changed > 0)
    }

    // ─────────────────────────────────────────────────────────────────────
    // Workspace management
    // ─────────────────────────────────────────────────────────────────────

    /// Get workspace by path.
    pub fn get_workspace_by_path(&self, path: &str) -> Result<Option<WorkspaceRow>> {
        let conn = self.conn()?;
        WorkspaceRepo::get_by_path(&conn, path)
    }

    /// Get or create workspace by path.
    pub fn get_or_create_workspace(
        &self,
        path: &str,
        name: Option<&str>,
    ) -> Result<WorkspaceRow> {
        let conn = self.conn()?;
        WorkspaceRepo::get_or_create(&conn, path, name)
    }

    /// List all workspaces.
    pub fn list_workspaces(&self) -> Result<Vec<WorkspaceRow>> {
        let conn = self.conn()?;
        WorkspaceRepo::list(&conn)
    }

    // ─────────────────────────────────────────────────────────────────────
    // Blob storage
    // ─────────────────────────────────────────────────────────────────────

    /// Store blob content (SHA-256 deduplicated).
    pub fn store_blob(&self, content: &[u8], mime_type: &str) -> Result<String> {
        let conn = self.conn()?;
        BlobRepo::store(&conn, content, mime_type)
    }

    /// Get blob content by ID.
    pub fn get_blob_content(&self, blob_id: &str) -> Result<Option<Vec<u8>>> {
        let conn = self.conn()?;
        BlobRepo::get_content(&conn, blob_id)
    }

    /// Get full blob metadata.
    pub fn get_blob(&self, blob_id: &str) -> Result<Option<BlobRow>> {
        let conn = self.conn()?;
        BlobRepo::get_by_id(&conn, blob_id)
    }

    // ─────────────────────────────────────────────────────────────────────
    // Search
    // ─────────────────────────────────────────────────────────────────────

    /// Full-text search across all events.
    pub fn search(&self, query: &str, opts: &SearchOptions<'_>) -> Result<Vec<SearchResult>> {
        let conn = self.conn()?;
        SearchRepo::search(&conn, query, opts)
    }

    /// Search within a specific session.
    pub fn search_in_session(
        &self,
        session_id: &str,
        query: &str,
        limit: Option<i64>,
    ) -> Result<Vec<SearchResult>> {
        let conn = self.conn()?;
        SearchRepo::search_in_session(&conn, session_id, query, limit)
    }

    // ─────────────────────────────────────────────────────────────────────
    // Branch management (delegated)
    // ─────────────────────────────────────────────────────────────────────

    /// Get branches for a session.
    pub fn get_branches(
        &self,
        session_id: &str,
    ) -> Result<Vec<crate::sqlite::row_types::BranchRow>> {
        let conn = self.conn()?;
        BranchRepo::get_by_session(&conn, session_id)
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
            .create_session("claude-opus-4-6", "/tmp/project", Some("Test"))
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
    fn create_session_creates_workspace() {
        let store = setup();
        store
            .create_session("claude-opus-4-6", "/tmp/project", None)
            .unwrap();

        let ws = store.get_workspace_by_path("/tmp/project").unwrap();
        assert!(ws.is_some());
    }

    #[test]
    fn create_session_reuses_workspace() {
        let store = setup();
        let r1 = store
            .create_session("claude-opus-4-6", "/tmp/project", None)
            .unwrap();
        let r2 = store
            .create_session("claude-opus-4-6", "/tmp/project", None)
            .unwrap();

        assert_eq!(r1.session.workspace_id, r2.session.workspace_id);
        assert_ne!(r1.session.id, r2.session.id);
    }

    #[test]
    fn create_session_root_event_has_correct_fields() {
        let store = setup();
        let result = store
            .create_session("claude-opus-4-6", "/tmp/project", None)
            .unwrap();

        assert!(result.root_event.parent_id.is_none());
        assert_eq!(result.root_event.sequence, 0);
        assert_eq!(result.root_event.depth, 0);
        assert_eq!(result.root_event.event_type, "session.start");
        assert_eq!(
            result.root_event.session_id,
            result.session.id
        );
    }

    // ── Event appending ───────────────────────────────────────────────

    #[test]
    fn append_basic() {
        let store = setup();
        let cr = store
            .create_session("claude-opus-4-6", "/tmp/project", None)
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
        assert_eq!(
            event.parent_id.as_deref(),
            Some(cr.root_event.id.as_str())
        );
    }

    #[test]
    fn append_chains_from_head() {
        let store = setup();
        let cr = store
            .create_session("claude-opus-4-6", "/tmp/project", None)
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
            .create_session("claude-opus-4-6", "/tmp/project", None)
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
            .create_session("claude-opus-4-6", "/tmp/project", None)
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
                        "cacheReadInputTokens": 10,
                    }
                }),
                parent_id: None,
            })
            .unwrap();

        let session = store.get_session(&cr.session.id).unwrap().unwrap();
        assert_eq!(session.event_count, 3); // root + 2 appended
        assert_eq!(session.message_count, 2);
        assert_eq!(session.total_input_tokens, 100);
        assert_eq!(session.total_output_tokens, 50);
        assert_eq!(session.total_cache_read_tokens, 10);
    }

    #[test]
    fn append_with_explicit_parent() {
        let store = setup();
        let cr = store
            .create_session("claude-opus-4-6", "/tmp/project", None)
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

        assert_eq!(
            evt2.parent_id.as_deref(),
            Some(cr.root_event.id.as_str())
        );
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
            .create_session("claude-opus-4-6", "/tmp/project", None)
            .unwrap();

        let event = store.get_event(&cr.root_event.id).unwrap();
        assert!(event.is_some());
        assert_eq!(event.unwrap().event_type, "session.start");
    }

    #[test]
    fn get_events_by_session() {
        let store = setup();
        let cr = store
            .create_session("claude-opus-4-6", "/tmp/project", None)
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
            .create_session("claude-opus-4-6", "/tmp/project", None)
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
            .create_session("claude-opus-4-6", "/tmp/project", None)
            .unwrap();

        let user_msg = store
            .append(&AppendOptions {
                session_id: &cr.session.id,
                event_type: EventType::MessageUser,
                payload: serde_json::json!({"content": "Hello"}),
                parent_id: None,
            })
            .unwrap();

        let fork = store
            .fork(&user_msg.id, &ForkOptions::default())
            .unwrap();

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
            .create_session("claude-opus-4-6", "/tmp/project", None)
            .unwrap();

        let user_msg = store
            .append(&AppendOptions {
                session_id: &cr.session.id,
                event_type: EventType::MessageUser,
                payload: serde_json::json!({"content": "Hello"}),
                parent_id: None,
            })
            .unwrap();

        let fork = store
            .fork(&user_msg.id, &ForkOptions::default())
            .unwrap();

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
            .create_session("claude-opus-4-6", "/tmp/project", None)
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
            .create_session("claude-opus-4-6", "/tmp/project", None)
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
            .create_session("claude-opus-4-6", "/tmp/project", None)
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
            .create_session("claude-opus-4-6", "/tmp/project", None)
            .unwrap();

        let session = store.get_session(&cr.session.id).unwrap();
        assert!(session.is_some());
    }

    #[test]
    fn list_sessions() {
        let store = setup();
        store
            .create_session("claude-opus-4-6", "/tmp/project", None)
            .unwrap();
        store
            .create_session("claude-opus-4-6", "/tmp/project", None)
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
            .create_session("claude-opus-4-6", "/tmp/project", None)
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
            .create_session("claude-opus-4-6", "/tmp/project", None)
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
            .create_session("claude-opus-4-6", "/tmp/project", None)
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
            .create_session("claude-opus-4-6", "/tmp/project", None)
            .unwrap();

        store
            .append(&AppendOptions {
                session_id: &cr.session.id,
                event_type: EventType::MessageUser,
                payload: serde_json::json!({"content": "rust programming"}),
                parent_id: None,
            })
            .unwrap();

        let results = store
            .search("rust", &SearchOptions::default())
            .unwrap();
        assert_eq!(results.len(), 1);
    }

    #[test]
    fn search_in_session() {
        let store = setup();
        let cr1 = store
            .create_session("claude-opus-4-6", "/tmp/project", None)
            .unwrap();
        let cr2 = store
            .create_session("claude-opus-4-6", "/tmp/project", None)
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
        let ws2 = store
            .get_or_create_workspace("/tmp/project", None)
            .unwrap();
        assert_eq!(ws1.id, ws2.id);
    }

    #[test]
    fn list_workspaces() {
        let store = setup();
        store
            .create_session("claude-opus-4-6", "/tmp/a", None)
            .unwrap();
        store
            .create_session("claude-opus-4-6", "/tmp/b", None)
            .unwrap();

        let workspaces = store.list_workspaces().unwrap();
        assert_eq!(workspaces.len(), 2);
    }

    // ── Complex scenarios ─────────────────────────────────────────────

    #[test]
    fn agentic_loop() {
        let store = setup();
        let cr = store
            .create_session("claude-opus-4-6", "/tmp/project", None)
            .unwrap();

        // Turn 1: user → assistant(tool_use) → tool.result → assistant(end_turn)
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
                    "content": [{"type": "tool_use", "id": "tool_1", "name": "Bash", "input": {"command": "ls"}}],
                    "turn": 1,
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

        let session = store.get_session(&cr.session.id).unwrap().unwrap();
        assert_eq!(session.event_count, 5); // root + 4
        assert_eq!(session.message_count, 3); // 1 user + 2 assistant
        assert_eq!(session.total_input_tokens, 500);
        assert_eq!(session.total_output_tokens, 50);

        let events = store
            .get_events_by_session(&cr.session.id, &ListEventsOptions::default())
            .unwrap();
        assert_eq!(events.len(), 5);
        for i in 0..5 {
            assert_eq!(events[i].sequence, i as i64);
        }
    }

    #[test]
    fn fork_then_diverge() {
        let store = setup();
        let cr = store
            .create_session("claude-opus-4-6", "/tmp/project", None)
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
        let fork = store
            .fork(&user_msg.id, &ForkOptions::default())
            .unwrap();

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
}
