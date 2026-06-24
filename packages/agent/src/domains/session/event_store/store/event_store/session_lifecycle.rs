use std::collections::HashMap;

use crate::domains::session::event_store::SessionRow;
use crate::domains::session::event_store::errors::{EventStoreError, Result};
use crate::domains::session::event_store::identity::{
    SessionCreationIdentity, SessionForkIdentity,
};
use crate::domains::session::event_store::sqlite::repositories::event::EventRepo;
use crate::domains::session::event_store::sqlite::repositories::session::{
    ActivitySummaryLine, CreateSessionOptions, IncrementCounters, ListSessionsOptions,
    MessagePreview, SessionRepo,
};
use crate::domains::session::event_store::sqlite::repositories::workspace::WorkspaceRepo;
use crate::domains::session::event_store::types::EventType;
use crate::domains::session::event_store::types::base::SessionEvent;

use super::{CreateSessionResult, EventStore, ForkOptions, ForkResult};

/// Options for creating a session inside an already-open transaction.
pub(super) struct CreateSessionInTxOptions<'a> {
    pub model: &'a str,
    pub workspace_path: &'a str,
    pub title: Option<&'a str>,
    pub provider: Option<&'a str>,
}

/// Core session-creation primitive: workspace get-or-create, sessions row
/// insert, root `session.start` event, root/head pointer updates, and counter
/// increments — all inside the caller's transaction. The caller commits.
pub(super) fn create_session_in_tx(
    tx: &rusqlite::Transaction<'_>,
    opts: &CreateSessionInTxOptions<'_>,
) -> Result<CreateSessionResult> {
    create_session_in_tx_with_identity(tx, opts, SessionCreationIdentity::generate_current())
}

pub(super) fn create_session_in_tx_with_identity(
    tx: &rusqlite::Transaction<'_>,
    opts: &CreateSessionInTxOptions<'_>,
    identity: SessionCreationIdentity,
) -> Result<CreateSessionResult> {
    let ws = WorkspaceRepo::get_or_create_with_identity(
        tx,
        opts.workspace_path,
        None,
        &identity.workspace,
    )?;
    let session = SessionRepo::create_with_identity(
        tx,
        &CreateSessionOptions {
            workspace_id: &ws.id,
            model: opts.model,
            working_directory: opts.workspace_path,
            title: opts.title,
            tags: None,
            parent_session_id: None,
            fork_from_event_id: None,
        },
        &identity.session,
    )?;

    let provider = opts.provider.unwrap_or_else(|| {
        crate::domains::model::routing::models::registry::detect_provider_from_model(opts.model)
            .map_or_else(
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

    let root_event_id = identity.root_event.id.clone();
    let root_event_timestamp = identity.root_event.timestamp.clone();
    let payload = serde_json::json!({
        "workingDirectory": opts.workspace_path,
        "model": opts.model,
        "provider": provider,
    });
    let event = SessionEvent {
        id: root_event_id,
        session_id: session.id.clone(),
        parent_id: None,
        workspace_id: ws.id.clone(),
        timestamp: root_event_timestamp.clone(),
        event_type: EventType::SessionStart,
        sequence: 0,
        checksum: None,
        payload,
    };
    EventRepo::insert(tx, &event)?;

    let _ = SessionRepo::update_root(tx, &session.id, &event.id)?;
    let _ = SessionRepo::update_head_at(tx, &session.id, &event.id, &root_event_timestamp)?;
    let _ = SessionRepo::increment_counters_at(
        tx,
        &session.id,
        &IncrementCounters {
            event_count: Some(1),
            ..Default::default()
        },
        &root_event_timestamp,
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
    ) -> Result<CreateSessionResult> {
        self.with_global_write_lock(|| {
            let mut conn = self.conn()?;
            let tx = conn.transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;

            let result = create_session_in_tx(
                &tx,
                &CreateSessionInTxOptions {
                    model,
                    workspace_path,
                    title,
                    provider,
                },
            )?;

            tx.commit()?;
            tracing::debug!(session_id = %result.session.id, "session created");
            Ok(result)
        })
    }

    /// Create a new session with explicit durable identities.
    ///
    /// Replay/import tests use this to pin workspace, session, and root event
    /// IDs/timestamps. Production callers should use [`Self::create_session`].
    #[tracing::instrument(skip(self, identity), fields(model, workspace_path))]
    pub fn create_session_with_identity(
        &self,
        model: &str,
        workspace_path: &str,
        title: Option<&str>,
        provider: Option<&str>,
        identity: SessionCreationIdentity,
    ) -> Result<CreateSessionResult> {
        self.with_global_write_lock(|| {
            let mut conn = self.conn()?;
            let tx = conn.transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;

            let result = create_session_in_tx_with_identity(
                &tx,
                &CreateSessionInTxOptions {
                    model,
                    workspace_path,
                    title,
                    provider,
                },
                identity.clone(),
            )?;

            tx.commit()?;
            tracing::debug!(session_id = %result.session.id, "session created with explicit identity");
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
        self.fork_with_identity(from_event_id, opts, SessionForkIdentity::generate_current())
    }

    /// Fork a session with explicit durable identities.
    #[tracing::instrument(skip(self, opts, identity), fields(from_event_id))]
    pub fn fork_with_identity(
        &self,
        from_event_id: &str,
        opts: &ForkOptions<'_>,
        identity: SessionForkIdentity,
    ) -> Result<ForkResult> {
        self.with_global_write_lock(|| {
            let mut conn = self.conn()?;
            let tx = conn.transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;

            let source_event = EventRepo::get_by_id(&tx, from_event_id)?
                .ok_or_else(|| EventStoreError::EventNotFound(from_event_id.to_string()))?;
            let source_session = SessionRepo::get_by_id(&tx, &source_event.session_id)?
                .ok_or_else(|| EventStoreError::SessionNotFound(source_event.session_id.clone()))?;

            let model = opts.model.unwrap_or(&source_session.latest_model);
            let session = SessionRepo::create_with_identity(
                &tx,
                &CreateSessionOptions {
                    workspace_id: &source_session.workspace_id,
                    model,
                    working_directory: &source_session.working_directory,
                    title: opts.title,
                    tags: None,
                    parent_session_id: Some(&source_session.id),
                    fork_from_event_id: Some(from_event_id),
                },
                &identity.session,
            )?;

            let fork_event_id = identity.fork_event.id.clone();
            let fork_event_timestamp = identity.fork_event.timestamp.clone();
            let payload = serde_json::json!({
                "sourceSessionId": source_session.id,
                "sourceEventId": from_event_id,
            });

            let fork_event = SessionEvent {
                id: fork_event_id,
                session_id: session.id.clone(),
                parent_id: Some(from_event_id.to_string()),
                workspace_id: source_session.workspace_id.clone(),
                timestamp: fork_event_timestamp.clone(),
                event_type: EventType::SessionFork,
                sequence: 0,
                checksum: None,
                payload,
            };
            EventRepo::insert(&tx, &fork_event)?;

            let _ = SessionRepo::update_root(&tx, &session.id, &fork_event.id)?;
            let _ = SessionRepo::update_head_at(
                &tx,
                &session.id,
                &fork_event.id,
                &fork_event_timestamp,
            )?;
            let _ = SessionRepo::increment_counters_at(
                &tx,
                &session.id,
                &IncrementCounters {
                    event_count: Some(1),
                    ..Default::default()
                },
                &fork_event_timestamp,
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

    #[cfg(test)]
    pub(crate) fn set_session_last_activity_for_test(
        &self,
        session_id: &str,
        rfc3339: &str,
    ) -> Result<bool> {
        self.with_session_write_lock(session_id, || {
            let conn = self.conn()?;
            conn.execute(
                "UPDATE sessions SET last_activity_at = ?1 WHERE id = ?2",
                rusqlite::params![rfc3339, session_id],
            )
            .map(|changed| changed > 0)
            .map_err(crate::domains::session::event_store::EventStoreError::from)
        })
    }

    /// Delete a session and all its events.
    #[tracing::instrument(skip(self), fields(session_id))]
    pub fn delete_session(&self, session_id: &str) -> Result<bool> {
        let deleted = self.with_session_write_lock(session_id, || {
            let mut conn = self.conn()?;
            let tx = conn.transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;

            let _ = EventRepo::delete_by_session(&tx, session_id)?;
            let deleted = SessionRepo::delete(&tx, session_id)?;

            tx.commit()?;
            Ok(deleted)
        })?;

        if deleted {
            self.remove_session_write_lock(session_id)?;
        }
        Ok(deleted)
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

    /// Get activity summary lines for a single session list item.
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
}
