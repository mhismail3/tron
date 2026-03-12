use std::collections::HashMap;

use uuid::Uuid;

use crate::errors::{EventStoreError, Result};
use crate::sqlite::repositories::branch::BranchRepo;
use crate::sqlite::repositories::event::EventRepo;
use crate::sqlite::repositories::session::{
    CreateSessionOptions, IncrementCounters, ListSessionsOptions, MessagePreview, SessionRepo,
};
use crate::sqlite::repositories::workspace::WorkspaceRepo;
use crate::sqlite::row_types::SessionRow;
use crate::types::EventType;
use crate::types::base::SessionEvent;

use super::{CreateSessionResult, EventStore, ForkOptions, ForkResult};

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
    ) -> Result<CreateSessionResult> {
        self.with_global_write_lock(|| {
            let conn = self.conn()?;
            let tx = conn.unchecked_transaction()?;

            let ws = WorkspaceRepo::get_or_create(&tx, workspace_path, None)?;
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
                    source: None,
                },
            )?;

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

            let _ = SessionRepo::update_root(&tx, &session.id, &event.id)?;
            let _ = SessionRepo::update_head(&tx, &session.id, &event.id)?;
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
            let root_event = EventRepo::get_by_id(&conn, &event.id)?
                .ok_or(EventStoreError::EventNotFound(event.id))?;

            tracing::debug!(session_id = %updated_session.id, "session created");

            Ok(CreateSessionResult {
                session: updated_session,
                root_event,
            })
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

    /// Find the active chat session (`source = 'chat'`, not ended).
    pub fn find_chat_session(&self) -> Result<Option<SessionRow>> {
        let conn = self.conn()?;
        SessionRepo::find_chat_session(&conn)
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
