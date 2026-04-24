use std::collections::HashMap;

use serde_json::Value;
use uuid::Uuid;

use crate::events::errors::{EventStoreError, Result};
use crate::events::sqlite::repositories::branch::BranchRepo;
use crate::events::sqlite::repositories::event::{EventRepo, ListEventsOptions};
use crate::events::sqlite::repositories::session::{
    ActivitySummaryLine, CreateSessionOptions, IncrementCounters, ListSessionsOptions,
    MessagePreview, SessionRepo,
};
use crate::events::sqlite::repositories::workspace::WorkspaceRepo;
use crate::events::sqlite::row_types::SessionRow;
use crate::events::types::EventType;
use crate::events::types::base::SessionEvent;

use super::event_log::append_event_in_tx;
use super::{AppendOptions, CreateSessionResult, EventStore, ForkOptions, ForkResult};

/// Options for creating a session inside an already-open transaction.
pub(super) struct CreateSessionInTxOptions<'a> {
    pub model: &'a str,
    pub workspace_path: &'a str,
    pub title: Option<&'a str>,
    pub provider: Option<&'a str>,
    pub origin: Option<&'a str>,
    pub source: Option<&'a str>,
    pub use_worktree: Option<bool>,
}

/// Core session-creation primitive: workspace get-or-create, sessions row
/// insert, root `session.start` event, root/head pointer updates, and counter
/// increments — all inside the caller's transaction. The caller commits.
///
/// Shared by [`EventStore::create_session_with_worktree_override`] (one tx
/// per session) and [`EventStore::import_atomic`] (many appends under one tx).
pub(super) fn create_session_in_tx(
    tx: &rusqlite::Transaction<'_>,
    opts: &CreateSessionInTxOptions<'_>,
) -> Result<CreateSessionResult> {
    let ws = WorkspaceRepo::get_or_create(tx, opts.workspace_path, None)?;
    let session = SessionRepo::create(
        tx,
        &CreateSessionOptions {
            workspace_id: &ws.id,
            model: opts.model,
            working_directory: opts.workspace_path,
            title: opts.title,
            tags: None,
            parent_session_id: None,
            fork_from_event_id: None,
            spawning_session_id: None,
            spawn_type: None,
            spawn_task: None,
            origin: opts.origin,
            source: opts.source,
            use_worktree: opts.use_worktree,
        },
    )?;

    let provider = opts.provider.unwrap_or_else(|| {
        crate::llm::models::registry::detect_provider_from_model(opts.model).map_or_else(
            || {
                if opts.model.starts_with("claude-") {
                    "anthropic"
                } else if opts.model.starts_with("gpt-")
                    || opts.model.starts_with("o1-")
                    || opts.model.starts_with("o3-")
                {
                    "openai"
                } else if opts.model.starts_with("gemini-") {
                    "google"
                } else {
                    "anthropic"
                }
            },
            |p| p.as_str(),
        )
    });

    let event_id = format!("evt_{}", Uuid::now_v7());
    let now = chrono::Utc::now().to_rfc3339();
    let payload = serde_json::json!({
        "workingDirectory": opts.workspace_path,
        "model": opts.model,
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
    EventRepo::insert(tx, &event)?;

    let _ = SessionRepo::update_root(tx, &session.id, &event.id)?;
    let _ = SessionRepo::update_head(tx, &session.id, &event.id)?;
    let _ = SessionRepo::increment_counters(
        tx,
        &session.id,
        &IncrementCounters {
            event_count: Some(1),
            ..Default::default()
        },
    )?;

    let updated_session = SessionRepo::get_by_id(tx, &session.id)?
        .ok_or_else(|| EventStoreError::SessionNotFound(session.id.clone()))?;
    let root_event = EventRepo::get_by_id(tx, &event.id)?
        .ok_or_else(|| EventStoreError::EventNotFound(event.id.clone()))?;

    Ok(CreateSessionResult {
        session: updated_session,
        root_event,
    })
}

/// A single event to append during an atomic import.
pub struct ImportEventSpec<'a> {
    /// Canonical event type to persist.
    pub event_type: EventType,
    /// Event payload (caller retains ownership; the import borrows it).
    pub payload: &'a Value,
}

/// Options for [`EventStore::import_atomic`].
pub struct ImportAtomicOptions<'a> {
    /// Primary model for the imported session.
    pub model: &'a str,
    /// Workspace path associated with the session.
    pub workspace_path: &'a str,
    /// Optional initial title (extracted from the source, e.g. a custom title line).
    pub title: Option<&'a str>,
    /// Optional `origin` tag (e.g. "ios").
    pub origin: Option<&'a str>,
    /// Optional `source` tag identifying the importer (e.g. "import").
    pub source: Option<&'a str>,
    /// Pre-transformed events to append after the root `session.start` event,
    /// in order. Each receives a monotonically increasing sequence starting at 1.
    pub events: &'a [ImportEventSpec<'a>],
    /// Dedup tag value. Written as a `metadata.tag` event with
    /// `{ "action": "add", "tag": <value> }`. If another session in the store
    /// already carries this tag, the import is aborted with
    /// [`EventStoreError::DuplicateImport`] — checked INSIDE the transaction
    /// so concurrent imports of the same source file race to a single winner.
    pub dedup_tag: &'a str,
    /// Additional user-supplied tags, each written as its own `metadata.tag` event.
    pub extra_tags: &'a [String],
}

/// Result of a successful [`EventStore::import_atomic`] call.
pub struct ImportAtomicResult {
    /// Fully-populated session row after the import transaction commits.
    pub session: SessionRow,
    /// Total number of events written (session.start + imported events + dedup tag + extra tags).
    pub event_count: i64,
}

/// Scan the event log for a `metadata.tag` event carrying the given tag with
/// `action = "add"`, returning the owning session ID if any.
///
/// Accepts any type that derefs to `&rusqlite::Connection`, so callers can
/// run it inside a transaction (for atomic import dedup) or against a bare
/// connection (for read-only previews). Import atomicity is enforced by
/// calling this INSIDE the transaction that does the write.
fn find_session_id_with_tag_in_conn(
    conn: &rusqlite::Connection,
    tag: &str,
) -> Result<Option<String>> {
    let sessions = SessionRepo::list(conn, &ListSessionsOptions::default())?;
    let opts = ListEventsOptions::default();

    for session in sessions {
        let events = EventRepo::get_by_session(conn, &session.id, &opts)?;
        for event in &events {
            if event.event_type == "metadata.tag"
                && let Ok(payload) = serde_json::from_str::<Value>(&event.payload)
                && payload.get("tag").and_then(Value::as_str) == Some(tag)
                && payload.get("action").and_then(Value::as_str) == Some("add")
            {
                return Ok(Some(session.id));
            }
        }
    }

    Ok(None)
}

impl EventStore {
    /// Create a new session with a root `session.start` event.
    ///
    /// Atomic: workspace creation (get-or-create), session insertion, root event
    /// insertion, head/root pointer updates, and counter increments all happen
    /// in a single transaction.
    #[tracing::instrument(skip(self), fields(model, workspace_path))]
    pub fn create_session(
        &self,
        model: &str,
        workspace_path: &str,
        title: Option<&str>,
        provider: Option<&str>,
        origin: Option<&str>,
        source: Option<&str>,
    ) -> Result<CreateSessionResult> {
        self.create_session_with_worktree_override(
            model,
            workspace_path,
            title,
            provider,
            origin,
            source,
            None,
        )
    }

    /// Return the ID of any session holding the given metadata tag
    /// (`metadata.tag` event with `{"action": "add", "tag": <tag>}`), or `None`.
    ///
    /// Acquires no write lock — intended for read-only previews (e.g. the
    /// import UI asking "would this source be a duplicate?"). The authoritative
    /// dedup check runs inside [`EventStore::import_atomic`], so a Yes from this
    /// method is advisory; a No does not guarantee the subsequent import will
    /// succeed if another caller wins the race.
    pub fn find_session_id_with_metadata_tag(&self, tag: &str) -> Result<Option<String>> {
        let conn = self.conn()?;
        find_session_id_with_tag_in_conn(&conn, tag)
    }

    /// Atomically create a session, append an initial batch of pre-transformed
    /// events, and record a dedup tag — all inside a single transaction.
    ///
    /// Either every write commits or none do: there is no observable window in
    /// which a session exists without its dedup tag. Concurrent imports of the
    /// same source file (same `dedup_tag`) serialize on `with_global_write_lock`
    /// and every loser receives [`EventStoreError::DuplicateImport`] carrying
    /// the ID of the session that won.
    ///
    /// INVARIANT: the dedup tag is scanned for INSIDE the transaction, so the
    /// check-then-write is atomic. Callers must not rely on any external
    /// "already imported?" probe before this call.
    #[tracing::instrument(skip(self, opts), fields(dedup_tag = %opts.dedup_tag))]
    pub fn import_atomic(&self, opts: &ImportAtomicOptions<'_>) -> Result<ImportAtomicResult> {
        self.with_global_write_lock(|| {
            let conn = self.conn()?;
            let tx = conn.unchecked_transaction()?;

            if let Some(existing) = find_session_id_with_tag_in_conn(&tx, opts.dedup_tag)? {
                return Err(EventStoreError::DuplicateImport {
                    existing_session_id: existing,
                });
            }

            let created = create_session_in_tx(
                &tx,
                &CreateSessionInTxOptions {
                    model: opts.model,
                    workspace_path: opts.workspace_path,
                    title: opts.title,
                    provider: None,
                    origin: opts.origin,
                    source: opts.source,
                    use_worktree: None,
                },
            )?;

            let mut session_mut = created.session.clone();
            let mut next_sequence: i64 = 1;
            let mut written: i64 = 1; // session.start already

            for spec in opts.events {
                let event = append_event_in_tx(
                    &tx,
                    &session_mut,
                    &AppendOptions {
                        session_id: &session_mut.id,
                        event_type: spec.event_type,
                        payload: spec.payload.clone(),
                        parent_id: None,
                        sequence: Some(next_sequence),
                    },
                )?;
                session_mut.head_event_id = Some(event.id);
                next_sequence += 1;
                written += 1;
            }

            let dedup_payload = serde_json::json!({ "action": "add", "tag": opts.dedup_tag });
            let event = append_event_in_tx(
                &tx,
                &session_mut,
                &AppendOptions {
                    session_id: &session_mut.id,
                    event_type: EventType::MetadataTag,
                    payload: dedup_payload,
                    parent_id: None,
                    sequence: Some(next_sequence),
                },
            )?;
            session_mut.head_event_id = Some(event.id);
            next_sequence += 1;
            written += 1;

            for tag in opts.extra_tags {
                let payload = serde_json::json!({ "action": "add", "tag": tag });
                let event = append_event_in_tx(
                    &tx,
                    &session_mut,
                    &AppendOptions {
                        session_id: &session_mut.id,
                        event_type: EventType::MetadataTag,
                        payload,
                        parent_id: None,
                        sequence: Some(next_sequence),
                    },
                )?;
                session_mut.head_event_id = Some(event.id);
                next_sequence += 1;
                written += 1;
            }

            tx.commit()?;

            let final_session = SessionRepo::get_by_id(&conn, &session_mut.id)?
                .ok_or(EventStoreError::SessionNotFound(session_mut.id))?;

            tracing::debug!(
                session_id = %final_session.id,
                event_count = written,
                "atomic import committed"
            );

            Ok(ImportAtomicResult {
                session: final_session,
                event_count: written,
            })
        })
    }

    /// Like [`create_session`] but accepts a per-session worktree override
    /// (`None` = defer to global isolation mode).
    pub fn create_session_with_worktree_override(
        &self,
        model: &str,
        workspace_path: &str,
        title: Option<&str>,
        provider: Option<&str>,
        origin: Option<&str>,
        source: Option<&str>,
        use_worktree: Option<bool>,
    ) -> Result<CreateSessionResult> {
        self.with_global_write_lock(|| {
            let conn = self.conn()?;
            let tx = conn.unchecked_transaction()?;

            let result = create_session_in_tx(
                &tx,
                &CreateSessionInTxOptions {
                    model,
                    workspace_path,
                    title,
                    provider,
                    origin,
                    source,
                    use_worktree,
                },
            )?;

            tx.commit()?;
            tracing::debug!(session_id = %result.session.id, "session created");
            Ok(result)
        })
    }

    /// Fork a session from a specific event.
    ///
    /// Creates a new session whose root `session.fork` event has its `parent_id`
    /// pointing into the source session's event tree. Ancestor walks from the
    /// fork event traverse back through the shared history.
    #[tracing::instrument(skip(self, opts), fields(from_event_id))]
    pub fn fork(&self, from_event_id: &str, opts: &ForkOptions<'_>) -> Result<ForkResult> {
        self.with_global_write_lock(|| {
            let conn = self.conn()?;
            let tx = conn.unchecked_transaction()?;

            let source_event = EventRepo::get_by_id(&tx, from_event_id)?
                .ok_or_else(|| EventStoreError::EventNotFound(from_event_id.to_string()))?;
            let source_session = SessionRepo::get_by_id(&tx, &source_event.session_id)?
                .ok_or_else(|| EventStoreError::SessionNotFound(source_event.session_id.clone()))?;

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
                    source: None,
                    use_worktree: None,
                },
            )?;

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

            let _ = SessionRepo::update_root(&tx, &session.id, &fork_event.id)?;
            let _ = SessionRepo::update_head(&tx, &session.id, &fork_event.id)?;
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

            tracing::debug!(
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
    #[tracing::instrument(skip(self), fields(session_id))]
    pub fn delete_session(&self, session_id: &str) -> Result<bool> {
        let deleted = self.with_session_write_lock(session_id, || {
            let conn = self.conn()?;
            let tx = conn.unchecked_transaction()?;

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

    /// Get activity summary lines for a single session's dashboard card.
    pub fn get_session_activity_summaries(
        &self,
        session_id: &str,
    ) -> Result<Vec<ActivitySummaryLine>> {
        let conn = self.conn()?;
        SessionRepo::get_activity_summaries(&conn, session_id)
    }

    /// Get activity summaries for multiple sessions (batch).
    pub fn get_session_activity_summaries_batch(
        &self,
        session_ids: &[&str],
    ) -> Result<HashMap<String, Vec<ActivitySummaryLine>>> {
        let conn = self.conn()?;
        let mut result = HashMap::new();
        for &sid in session_ids {
            let _ = result.insert(
                sid.to_string(),
                SessionRepo::get_activity_summaries(&conn, sid)?,
            );
        }
        Ok(result)
    }

    /// Update session source (e.g. `"cron"` for scheduled sessions).
    pub fn update_source(&self, session_id: &str, source: &str) -> Result<bool> {
        self.with_session_write_lock(session_id, || {
            let conn = self.conn()?;
            SessionRepo::update_source(&conn, session_id, source)
        })
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
            SessionRepo::update_spawn_info(
                &conn,
                session_id,
                spawning_session_id,
                spawn_type,
                spawn_task,
            )
        })
    }
}
