//! High-level transactional `EventStore` API.
//!
//! Composes all repository operations into atomic, session-centric methods.
//! Every write method runs inside a single `SQLite` transaction — callers
//! never observe partial state.

use rusqlite::OptionalExtension;
use serde_json::Value;
use tracing::{debug, instrument};
use uuid::Uuid;

use std::collections::HashMap;
use std::sync::{Arc, Mutex, MutexGuard, Weak};
use std::time::Duration;

use crate::errors::{EventStoreError, Result};
use crate::reconstruct::{ReconstructionResult, reconstruct_from_events};
use crate::sqlite::connection::{ConnectionPool, PooledConnection};
use crate::sqlite::repositories::blob::BlobRepo;
use crate::sqlite::repositories::branch::BranchRepo;
use crate::sqlite::repositories::device_token::{DeviceTokenRepo, RegisterTokenResult};
use crate::sqlite::repositories::event::{EventRepo, ListEventsOptions, TokenUsageSummary};
use crate::sqlite::repositories::search::{SearchOptions, SearchRepo};
use crate::sqlite::repositories::session::{
    CreateSessionOptions, IncrementCounters, ListSessionsOptions, MessagePreview, SessionRepo,
};
use crate::sqlite::repositories::workspace::WorkspaceRepo;
use crate::sqlite::row_types::{BlobRow, DeviceTokenRow, EventRow, SessionRow, WorkspaceRow};
use crate::types::EventType;
use crate::types::base::SessionEvent;
use crate::types::state::{SearchResult, SessionState};

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
/// lock. SQLite `UNIQUE(session_id, sequence)` enforces ordering at the DB level.
pub struct EventStore {
    pool: ConnectionPool,
    global_write_lock: Mutex<()>,
    session_write_locks: Mutex<HashMap<String, Weak<Mutex<()>>>>,
}

impl EventStore {
    const SQLITE_BUSY_MAX_RETRIES: u32 = 32;
    /// Create a new `EventStore` with the given connection pool.
    pub fn new(pool: ConnectionPool) -> Self {
        Self {
            pool,
            global_write_lock: Mutex::new(()),
            session_write_locks: Mutex::new(HashMap::new()),
        }
    }

    fn lock_global_write(&self) -> Result<MutexGuard<'_, ()>> {
        self.global_write_lock
            .lock()
            .map_err(|_| EventStoreError::Internal("global write lock poisoned".into()))
    }

    fn acquire_session_write_lock(&self, session_id: &str) -> Result<Arc<Mutex<()>>> {
        let mut locks = self
            .session_write_locks
            .lock()
            .map_err(|_| EventStoreError::Internal("session lock map poisoned".into()))?;

        // Opportunistically prune dead weak refs when the map grows.
        if locks.len() > 128 {
            locks.retain(|_, weak| weak.strong_count() > 0);
        }

        if let Some(existing) = locks.get(session_id).and_then(Weak::upgrade) {
            return Ok(existing);
        }

        let lock = Arc::new(Mutex::new(()));
        let _ = locks.insert(session_id.to_string(), Arc::downgrade(&lock));
        Ok(lock)
    }

    fn with_session_write_lock<T>(
        &self,
        session_id: &str,
        f: impl FnMut() -> Result<T>,
    ) -> Result<T> {
        let session_lock = self.acquire_session_write_lock(session_id)?;
        let _guard = session_lock
            .lock()
            .map_err(|_| EventStoreError::Internal("session write lock poisoned".into()))?;
        self.retry_on_sqlite_busy(f)
    }

    fn with_global_write_lock<T>(&self, f: impl FnMut() -> Result<T>) -> Result<T> {
        let _guard = self.lock_global_write()?;
        self.retry_on_sqlite_busy(f)
    }

    /// Retry an operation on `SQLite` BUSY/LOCKED with linear backoff + jitter.
    ///
    /// Backoff: base = min(attempts * 10, 500) ms, jitter ±25% to prevent
    /// thundering herd when multiple writers contend on the same database.
    #[allow(clippy::unused_self)]
    fn retry_on_sqlite_busy<T>(&self, mut f: impl FnMut() -> Result<T>) -> Result<T> {
        let mut attempts = 0;

        loop {
            match f() {
                Ok(value) => return Ok(value),
                Err(err)
                    if Self::is_sqlite_busy_or_locked(&err)
                        && attempts < Self::SQLITE_BUSY_MAX_RETRIES =>
                {
                    attempts += 1;
                    let base_ms = u64::from(attempts).saturating_mul(10).min(500);
                    let jitter_range = base_ms / 4;
                    let jitter = if jitter_range > 0 {
                        rand::random::<u64>() % (jitter_range * 2 + 1)
                    } else {
                        0
                    };
                    let backoff_ms = base_ms.saturating_sub(jitter_range) + jitter;
                    std::thread::sleep(Duration::from_millis(backoff_ms));
                }
                Err(err) => return Err(err),
            }
        }
    }

    fn is_sqlite_busy_or_locked(err: &EventStoreError) -> bool {
        match err {
            EventStoreError::Sqlite(rusqlite::Error::SqliteFailure(code, _)) => {
                matches!(
                    code.code,
                    rusqlite::ErrorCode::DatabaseBusy | rusqlite::ErrorCode::DatabaseLocked
                )
            }
            _ => false,
        }
    }

    fn remove_session_write_lock(&self, session_id: &str) -> Result<()> {
        let mut locks = self
            .session_write_locks
            .lock()
            .map_err(|_| EventStoreError::Internal("session lock map poisoned".into()))?;
        let _ = locks.remove(session_id);
        Ok(())
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
    #[instrument(skip(self), fields(model, workspace_path))]
    pub fn create_session(
        &self,
        model: &str,
        workspace_path: &str,
        title: Option<&str>,
        provider: Option<&str>,
        origin: Option<&str>,
    ) -> Result<CreateSessionResult> {
        self.with_global_write_lock(|| {
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
                    origin,
                },
            )?;

            // 3. Create root session.start event
            let event_id = format!("evt_{}", Uuid::now_v7());
            let now = chrono::Utc::now().to_rfc3339();
            let provider = provider.unwrap_or_else(|| {
                if model.starts_with("claude-") {
                    "anthropic"
                } else if model.starts_with("gpt-")
                    || model.starts_with("o1-")
                    || model.starts_with("o3-")
                {
                    "openai"
                } else if model.starts_with("gemini-") {
                    "google"
                } else {
                    "anthropic"
                }
            });
            let payload = serde_json::json!({
                "workingDirectory": workspace_path,
                "model": model,
                "provider": provider,
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

            debug!(session_id = %updated_session.id, "session created");

            Ok(CreateSessionResult {
                session: updated_session,
                root_event,
            })
        })
    }

    /// Append an event to a session.
    ///
    /// Atomic: sequence generation, event insertion, head update, and counter
    /// increments all happen in a single transaction.
    #[instrument(skip(self, opts), fields(session_id = opts.session_id, event_type = %opts.event_type))]
    pub fn append(&self, opts: &AppendOptions<'_>) -> Result<EventRow> {
        self.with_session_write_lock(opts.session_id, || self.append_inner(opts))
    }

    /// Inner append without acquiring the write lock.
    /// Called by `append` (which holds the lock) and by `delete_message`
    /// (which acquires the lock once at its own level).
    fn append_inner(&self, opts: &AppendOptions<'_>) -> Result<EventRow> {
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

        // Turn count: increment on each assistant message (one assistant message = one turn)
        if opts.event_type == EventType::MessageAssistant {
            counters.turn_count = Some(1);
        }

        // Token usage from payload
        if let Some(tu) = opts.payload.get("tokenUsage") {
            counters.input_tokens = tu.get("inputTokens").and_then(Value::as_i64);
            counters.output_tokens = tu.get("outputTokens").and_then(Value::as_i64);
            counters.cache_read_tokens = tu.get("cacheReadTokens").and_then(Value::as_i64);
            counters.cache_creation_tokens = tu.get("cacheCreationTokens").and_then(Value::as_i64);

            // Last turn context window: prefer tokenRecord.computed.contextWindowTokens
            // (includes cache reads for Anthropic), fall back to raw inputTokens
            if opts.event_type == EventType::MessageAssistant {
                counters.last_turn_input_tokens = opts
                    .payload
                    .get("tokenRecord")
                    .and_then(|r| r.get("computed"))
                    .and_then(|c| c.get("contextWindowTokens"))
                    .and_then(Value::as_i64)
                    .or_else(|| tu.get("inputTokens").and_then(Value::as_i64));
            }
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
    #[instrument(skip(self, opts), fields(from_event_id))]
    pub fn fork(&self, from_event_id: &str, opts: &ForkOptions<'_>) -> Result<ForkResult> {
        self.with_global_write_lock(|| {
            let conn = self.conn()?;
            let tx = conn.unchecked_transaction()?;

            // 1. Fetch source event
            let source_event = EventRepo::get_by_id(&tx, from_event_id)?
                .ok_or_else(|| EventStoreError::EventNotFound(from_event_id.to_string()))?;

            // 2. Fetch source session
            let source_session = SessionRepo::get_by_id(&tx, &source_event.session_id)?
                .ok_or_else(|| EventStoreError::SessionNotFound(source_event.session_id.clone()))?;

            // 3. Create forked session (inherits origin from source)
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
                    origin: source_session.origin.as_deref(),
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

            debug!(
                new_session_id = %updated_session.id,
                source_session_id = %source_session.id,
                "session forked"
            );

            Ok(ForkResult {
                session: updated_session,
                fork_event: fork_event_row,
            })
        })
    }

    /// Delete a message by appending a `message.deleted` event.
    ///
    /// The target event must be a message event (`message.user`, `message.assistant`,
    /// or `tool.result`). The original event is never modified — deletion is recorded
    /// as a new event and applied during message reconstruction.
    #[instrument(skip(self), fields(session_id, target_event_id))]
    pub fn delete_message(
        &self,
        session_id: &str,
        target_event_id: &str,
        reason: Option<&str>,
    ) -> Result<EventRow> {
        self.with_session_write_lock(session_id, || {
            // Validate target exists and is a message type
            let conn = self.conn()?;
            let target = EventRepo::get_by_id(&conn, target_event_id)?
                .ok_or_else(|| EventStoreError::EventNotFound(target_event_id.to_string()))?;

            let target_type: EventType =
                target
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

            // Append message.deleted event (uses append_inner to avoid re-acquiring lock)
            self.append_inner(&AppendOptions {
                session_id,
                event_type: EventType::MessageDeleted,
                payload: serde_json::json!({
                    "targetEventId": target_event_id,
                    "targetType": target.event_type,
                    "reason": reason.unwrap_or("user_request"),
                }),
                parent_id: None,
            })
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
    pub fn get_events_since(&self, session_id: &str, after_sequence: i64) -> Result<Vec<EventRow>> {
        let conn = self.conn()?;
        EventRepo::get_since(&conn, session_id, after_sequence)
    }

    /// Get token usage summary for a session.
    pub fn get_token_usage_summary(&self, session_id: &str) -> Result<TokenUsageSummary> {
        let conn = self.conn()?;
        EventRepo::get_token_usage_summary(&conn, session_id)
    }

    /// Batch-fetch events by IDs.
    ///
    /// Returns a map of `event_id → EventRow`. IDs that don't match any event
    /// are silently omitted.
    pub fn get_events_by_ids(&self, event_ids: &[&str]) -> Result<HashMap<String, EventRow>> {
        let conn = self.conn()?;
        EventRepo::get_by_ids(&conn, event_ids)
    }

    /// Get events of specific types within a session.
    pub fn get_events_by_type(
        &self,
        session_id: &str,
        types: &[&str],
        limit: Option<i64>,
    ) -> Result<Vec<EventRow>> {
        let conn = self.conn()?;
        EventRepo::get_by_types(&conn, session_id, types, limit)
    }

    /// Get events by workspace and types (cross-session query).
    pub fn get_events_by_workspace_and_types(
        &self,
        workspace_id: &str,
        types: &[&str],
        limit: Option<i64>,
        offset: Option<i64>,
    ) -> Result<Vec<EventRow>> {
        let conn = self.conn()?;
        EventRepo::get_by_workspace_and_types(&conn, workspace_id, types, limit, offset)
    }

    /// Count events by workspace and types.
    pub fn count_events_by_workspace_and_types(
        &self,
        workspace_id: &str,
        types: &[&str],
    ) -> Result<i64> {
        let conn = self.conn()?;
        EventRepo::count_by_workspace_and_types(&conn, workspace_id, types)
    }

    /// Count total events in a session.
    pub fn count_events(&self, session_id: &str) -> Result<i64> {
        let conn = self.conn()?;
        EventRepo::count_by_session(&conn, session_id)
    }

    /// Check if a session was interrupted (last turn didn't complete).
    ///
    /// A session is considered interrupted if the last `message.assistant` event
    /// has a higher sequence than the last `stream.turn_end` event, meaning the
    /// turn started but never finished.
    pub fn was_session_interrupted(&self, session_id: &str) -> Result<bool> {
        let conn = self.conn()?;
        let last_assistant_seq: Option<i64> = conn
            .query_row(
                "SELECT MAX(sequence) FROM events WHERE session_id = ?1 AND type = 'message.assistant'",
                rusqlite::params![session_id],
                |row| row.get(0),
            )
            .optional()?
            .flatten();
        let last_turn_end_seq: Option<i64> = conn
            .query_row(
                "SELECT MAX(sequence) FROM events WHERE session_id = ?1 AND type = 'stream.turn_end'",
                rusqlite::params![session_id],
                |row| row.get(0),
            )
            .optional()?
            .flatten();

        match (last_assistant_seq, last_turn_end_seq) {
            // No assistant messages → not interrupted
            (None, _) => Ok(false),
            // Assistant message but no turn_end → interrupted
            (Some(_), None) => Ok(true),
            // Both exist → interrupted if assistant is after turn_end
            (Some(a), Some(t)) => Ok(a > t),
        }
    }

    // ─────────────────────────────────────────────────────────────────────
    // State projection (message reconstruction)
    // ─────────────────────────────────────────────────────────────────────

    /// Reconstruct messages at the session head.
    ///
    /// Walks ancestors from root to head event, converts to `SessionEvent`s,
    /// and runs the two-pass reconstruction algorithm.
    pub fn get_messages_at_head(&self, session_id: &str) -> Result<ReconstructionResult> {
        let conn = self.conn()?;
        let session = SessionRepo::get_by_id(&conn, session_id)?
            .ok_or_else(|| EventStoreError::SessionNotFound(session_id.to_string()))?;
        let head_id = session
            .head_event_id
            .as_deref()
            .ok_or_else(|| EventStoreError::InvalidOperation("Session has no head event".into()))?;
        let ancestors = EventRepo::get_ancestors(&conn, head_id)?;
        let events = rows_to_session_events(&ancestors);
        Ok(reconstruct_from_events(&events))
    }

    /// Reconstruct messages at a specific event.
    ///
    /// Walks ancestors from root to the given event, converts to `SessionEvent`s,
    /// and runs the two-pass reconstruction algorithm.
    pub fn get_messages_at(&self, event_id: &str) -> Result<ReconstructionResult> {
        let conn = self.conn()?;
        let ancestors = EventRepo::get_ancestors(&conn, event_id)?;
        if ancestors.is_empty() {
            return Err(EventStoreError::EventNotFound(event_id.to_string()));
        }
        let events = rows_to_session_events(&ancestors);
        Ok(reconstruct_from_events(&events))
    }

    /// Build full session state at the head event.
    ///
    /// Combines session metadata with reconstructed messages.
    pub fn get_state_at_head(&self, session_id: &str) -> Result<SessionState> {
        let conn = self.conn()?;
        let session = SessionRepo::get_by_id(&conn, session_id)?
            .ok_or_else(|| EventStoreError::SessionNotFound(session_id.to_string()))?;
        let head_id = session
            .head_event_id
            .as_deref()
            .ok_or_else(|| EventStoreError::InvalidOperation("Session has no head event".into()))?;
        let ancestors = EventRepo::get_ancestors(&conn, head_id)?;
        let events = rows_to_session_events(&ancestors);
        let reconstruction = reconstruct_from_events(&events);
        Ok(build_session_state(&session, head_id, reconstruction))
    }

    /// Build full session state at a specific event.
    pub fn get_state_at(&self, session_id: &str, event_id: &str) -> Result<SessionState> {
        let conn = self.conn()?;
        let session = SessionRepo::get_by_id(&conn, session_id)?
            .ok_or_else(|| EventStoreError::SessionNotFound(session_id.to_string()))?;
        let ancestors = EventRepo::get_ancestors(&conn, event_id)?;
        if ancestors.is_empty() {
            return Err(EventStoreError::EventNotFound(event_id.to_string()));
        }
        let events = rows_to_session_events(&ancestors);
        let reconstruction = reconstruct_from_events(&events);
        Ok(build_session_state(&session, event_id, reconstruction))
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
        self.with_session_write_lock(session_id, || {
            let conn = self.conn()?;
            SessionRepo::mark_ended(&conn, session_id)
        })
    }

    /// Reactivate an ended session.
    pub fn clear_session_ended(&self, session_id: &str) -> Result<bool> {
        self.with_session_write_lock(session_id, || {
            let conn = self.conn()?;
            SessionRepo::clear_ended(&conn, session_id)
        })
    }

    /// Update the latest model for a session.
    pub fn update_latest_model(&self, session_id: &str, model: &str) -> Result<bool> {
        self.with_session_write_lock(session_id, || {
            let conn = self.conn()?;
            SessionRepo::update_latest_model(&conn, session_id, model)
        })
    }

    /// Update session title.
    pub fn update_session_title(&self, session_id: &str, title: Option<&str>) -> Result<bool> {
        self.with_session_write_lock(session_id, || {
            let conn = self.conn()?;
            SessionRepo::update_title(&conn, session_id, title)
        })
    }

    /// Delete a session and all its events.
    #[instrument(skip(self), fields(session_id))]
    pub fn delete_session(&self, session_id: &str) -> Result<bool> {
        let deleted = self.with_session_write_lock(session_id, || {
            let conn = self.conn()?;
            let tx = conn.unchecked_transaction()?;

            // Delete events first (foreign key constraint)
            let _ = EventRepo::delete_by_session(&tx, session_id)?;
            let _ = BranchRepo::delete_by_session(&tx, session_id)?;
            let deleted = SessionRepo::delete(&tx, session_id)?;

            tx.commit()?;
            Ok(deleted)
        })?;

        if deleted {
            self.remove_session_write_lock(session_id)?;
        }
        Ok(deleted)
    }

    /// List subagent sessions for a parent.
    pub fn list_subagents(&self, spawning_session_id: &str) -> Result<Vec<SessionRow>> {
        let conn = self.conn()?;
        SessionRepo::list_subagents(&conn, spawning_session_id)
    }

    /// Batch-fetch sessions by IDs.
    ///
    /// Returns a map of `session_id → SessionRow`. IDs not found are omitted.
    pub fn get_sessions_by_ids(&self, session_ids: &[&str]) -> Result<HashMap<String, SessionRow>> {
        let conn = self.conn()?;
        SessionRepo::get_by_ids(&conn, session_ids)
    }

    /// Get message previews for a list of sessions.
    ///
    /// Returns the last user prompt and last assistant response per session.
    pub fn get_session_message_previews(
        &self,
        session_ids: &[&str],
    ) -> Result<HashMap<String, MessagePreview>> {
        let conn = self.conn()?;
        SessionRepo::get_message_previews(&conn, session_ids)
    }

    /// Update session spawn info (links child to parent session).
    pub fn update_spawn_info(
        &self,
        session_id: &str,
        spawning_session_id: &str,
        spawn_type: &str,
        spawn_task: &str,
    ) -> Result<bool> {
        self.with_session_write_lock(session_id, || {
            let conn = self.conn()?;
            let changed = conn.execute(
                "UPDATE sessions SET spawning_session_id = ?1, spawn_type = ?2, spawn_task = ?3 WHERE id = ?4",
                rusqlite::params![spawning_session_id, spawn_type, spawn_task, session_id],
            )?;
            Ok(changed > 0)
        })
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
    pub fn get_or_create_workspace(&self, path: &str, name: Option<&str>) -> Result<WorkspaceRow> {
        self.with_global_write_lock(|| {
            let conn = self.conn()?;
            WorkspaceRepo::get_or_create(&conn, path, name)
        })
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
        self.with_global_write_lock(|| {
            let conn = self.conn()?;
            BlobRepo::store(&conn, content, mime_type)
        })
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

    // ─────────────────────────────────────────────────────────────────────
    // Device tokens
    // ─────────────────────────────────────────────────────────────────────

    /// Register or update a device token. Returns `{id, created}`.
    pub fn register_device_token(
        &self,
        device_token: &str,
        session_id: Option<&str>,
        workspace_id: Option<&str>,
        environment: &str,
    ) -> Result<RegisterTokenResult> {
        self.with_global_write_lock(|| {
            let conn = self.conn()?;
            DeviceTokenRepo::register(&conn, device_token, session_id, workspace_id, environment)
        })
    }

    /// Unregister (deactivate) a device token.
    pub fn unregister_device_token(&self, device_token: &str) -> Result<bool> {
        self.with_global_write_lock(|| {
            let conn = self.conn()?;
            DeviceTokenRepo::unregister(&conn, device_token)
        })
    }

    /// Get all active device tokens.
    pub fn get_all_active_device_tokens(&self) -> Result<Vec<DeviceTokenRow>> {
        let conn = self.conn()?;
        DeviceTokenRepo::get_all_active(&conn)
    }

    /// Mark a device token as invalid (e.g., after APNS 410 response).
    pub fn mark_device_token_invalid(&self, device_token: &str) -> Result<bool> {
        self.with_global_write_lock(|| {
            let conn = self.conn()?;
            DeviceTokenRepo::mark_invalid(&conn, device_token)
        })
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Helpers
// ─────────────────────────────────────────────────────────────────────────────

/// Convert `EventRow`s to `SessionEvent`s for reconstruction.
///
/// Each `EventRow.payload` is a JSON string; this parses it into `serde_json::Value`.
/// Invalid JSON falls back to `Value::Null`.
fn rows_to_session_events(rows: &[EventRow]) -> Vec<SessionEvent> {
    rows.iter()
        .map(|row| SessionEvent {
            id: row.id.clone(),
            parent_id: row.parent_id.clone(),
            session_id: row.session_id.clone(),
            workspace_id: row.workspace_id.clone(),
            timestamp: row.timestamp.clone(),
            event_type: row.event_type.parse().unwrap_or(EventType::SessionStart),
            sequence: row.sequence,
            checksum: row.checksum.clone(),
            payload: serde_json::from_str(&row.payload).unwrap_or_else(|e| {
                tracing::warn!(event_id = %row.id, error = %e, "corrupt event payload, defaulting to null");
                Value::Null
            }),
        })
        .collect()
}

/// Build `SessionState` from a `SessionRow` and `ReconstructionResult`.
fn build_session_state(
    session: &SessionRow,
    head_event_id: &str,
    reconstruction: ReconstructionResult,
) -> SessionState {
    use crate::types::payloads::TokenUsage;

    SessionState {
        session_id: session.id.clone(),
        workspace_id: session.workspace_id.clone(),
        head_event_id: head_event_id.to_string(),
        model: session.latest_model.clone(),
        working_directory: session.working_directory.clone(),
        messages_with_event_ids: reconstruction.messages_with_event_ids,
        token_usage: TokenUsage {
            input_tokens: session.total_input_tokens,
            output_tokens: session.total_output_tokens,
            cache_read_tokens: Some(session.total_cache_read_tokens),
            cache_creation_tokens: Some(session.total_cache_creation_tokens),
            ..Default::default()
        },
        turn_count: reconstruction.turn_count,
        provider: None,
        system_prompt: reconstruction.system_prompt,
        reasoning_level: reconstruction.reasoning_level,
        metadata: None,
        is_ended: session.ended_at.as_ref().map(|_| true),
        branch: None,
        timestamp: Some(session.last_activity_at.clone()),
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
            .create_session("claude-opus-4-6", "/tmp/project", None, Some("openai"), None)
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

        let session = store.get_session(&cr.session.id).unwrap().unwrap();
        assert_eq!(session.event_count, 3); // root + 2 appended
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
    fn rows_to_session_events_converts_correctly() {
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

        let events = super::rows_to_session_events(&[row]);
        assert_eq!(events.len(), 1);
        assert_eq!(events[0].id, "evt_1");
        assert_eq!(events[0].event_type, EventType::SessionStart);
        assert_eq!(events[0].payload["model"], "claude-opus-4-6");
    }

    #[test]
    fn rows_to_session_events_handles_invalid_json() {
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

        let events = super::rows_to_session_events(&[row]);
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
                        .create_session("claude-opus-4-6", &format!("/tmp/project-{i}"), None, None, None)
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
}
