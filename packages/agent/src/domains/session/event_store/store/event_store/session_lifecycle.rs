use std::collections::HashMap;

use crate::domains::session::event_store::SessionRow;
use crate::domains::session::event_store::errors::{EventStoreError, Result};
use crate::domains::session::event_store::identity::{
    EventIdentity, SessionCreationIdentity, SessionForkIdentity,
};
use crate::domains::session::event_store::sqlite::repositories::event::EventRepo;
use crate::domains::session::event_store::sqlite::repositories::session::{
    CreateSessionOptions, IncrementCounters, ListSessionsOptions, MessagePreview, SessionRepo,
};
use crate::domains::session::event_store::sqlite::repositories::workspace::WorkspaceRepo;
use crate::domains::session::event_store::sqlite::row_types::AGENT_SESSION_TAG;
#[cfg(test)]
use crate::domains::session::event_store::sqlite::row_types::WORKER_SESSION_TAG;
use crate::domains::session::event_store::types::EventType;
use crate::domains::session::event_store::types::base::SessionEvent;
use crate::shared::protocol::events::ActivitySummaryLine;

use super::event_log::append_event_in_tx_with_identity;
use super::{AppendOptions, CreateSessionResult, EventStore, ForkOptions, ForkResult};

/// Options for creating a session inside an already-open transaction.
pub(super) struct CreateSessionInTxOptions<'a> {
    pub model: &'a str,
    pub workspace_path: &'a str,
    pub title: Option<&'a str>,
    pub provider: Option<&'a str>,
    pub tags: Option<&'a [String]>,
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
            tags: opts.tags,
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
                    tags: None,
                },
            )?;

            tx.commit()?;
            tracing::debug!(session_id = %result.session.id, "session created");
            Ok(result)
        })
    }

    /// Create a model session owned by one worker invocation.
    ///
    /// Worker sessions share the normal event/reconstruction machinery, but a
    /// reserved durable tag keeps them out of ordinary user-session listings.
    #[cfg(test)]
    pub(crate) fn create_worker_session(
        &self,
        model: &str,
        workspace_path: &str,
        title: Option<&str>,
        provider: Option<&str>,
    ) -> Result<CreateSessionResult> {
        let tags = vec![WORKER_SESSION_TAG.to_owned()];
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
                    tags: Some(&tags),
                },
            )?;
            tx.commit()?;
            tracing::debug!(session_id = %result.session.id, "worker session created");
            Ok(result)
        })
    }

    /// Create the hidden durable transcript for one reusable agent instance.
    #[cfg(test)]
    pub(crate) fn create_agent_session(
        &self,
        model: &str,
        workspace_path: &str,
        title: Option<&str>,
        provider: Option<&str>,
    ) -> Result<CreateSessionResult> {
        self.create_agent_session_with_identity(
            model,
            workspace_path,
            title,
            provider,
            SessionCreationIdentity::generate_current(),
        )
    }

    /// Create a hidden reusable-agent transcript with preallocated identities.
    ///
    /// Cross-store outbox import uses this operation so replay after a crash
    /// observes the same session and root event instead of creating a second
    /// child transcript.
    pub(crate) fn create_agent_session_with_identity(
        &self,
        model: &str,
        workspace_path: &str,
        title: Option<&str>,
        provider: Option<&str>,
        identity: SessionCreationIdentity,
    ) -> Result<CreateSessionResult> {
        let tags = vec![AGENT_SESSION_TAG.to_owned()];
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
                    tags: Some(&tags),
                },
                identity.clone(),
            )?;
            tx.commit()?;
            tracing::debug!(session_id = %result.session.id, "agent session created");
            Ok(result)
        })
    }

    /// Reveal one quiescent nested-agent transcript as an ordinary user task.
    ///
    /// Agent lifecycle ownership and quiescence are validated by the Worker
    /// Kernel before this EventStore-only visibility mutation. Immutable
    /// lineage remains in agent coordination storage; session fork ancestry is
    /// deliberately untouched. A same-database receipt makes replay after a
    /// cross-store outbox crash return the already promoted transcript instead
    /// of mistaking it for an arbitrary ordinary session.
    pub(crate) fn promote_agent_session(&self, session_id: &str) -> Result<SessionRow> {
        self.with_global_write_lock(|| {
            let mut conn = self.conn()?;
            let tx = conn.transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;
            let session = SessionRepo::get_by_id(&tx, session_id)?
                .ok_or_else(|| EventStoreError::SessionNotFound(session_id.to_owned()))?;
            let mut tags = serde_json::from_str::<Vec<String>>(&session.tags).map_err(|error| {
                EventStoreError::InvalidOperation(format!(
                    "session '{session_id}' has invalid tags: {error}"
                ))
            })?;
            let already_promoted = tx.query_row(
                "SELECT EXISTS(SELECT 1 FROM agent_session_promotions WHERE session_id=?1)",
                [session_id],
                |row| row.get::<_, bool>(0),
            )?;
            let nested = tags.iter().any(|tag| tag == AGENT_SESSION_TAG);
            if already_promoted && !nested {
                tx.commit()?;
                return SessionRepo::get_by_id(&conn, session_id)?
                    .ok_or_else(|| EventStoreError::SessionNotFound(session_id.to_owned()));
            }
            if already_promoted || !nested {
                return Err(EventStoreError::InvalidOperation(format!(
                    "session '{session_id}' is not a nested agent transcript"
                )));
            }
            tags.retain(|tag| tag != AGENT_SESSION_TAG);
            let tags_json = serde_json::to_string(&tags).map_err(|error| {
                EventStoreError::InvalidOperation(format!(
                    "serialize promoted session tags: {error}"
                ))
            })?;
            tx.execute(
                "UPDATE sessions SET tags=?2,last_activity_at=?3 WHERE id=?1",
                rusqlite::params![session_id, tags_json, chrono::Utc::now().to_rfc3339()],
            )?;
            tx.execute(
                "INSERT INTO agent_session_promotions(session_id,promoted_at) VALUES (?1,?2)",
                rusqlite::params![session_id, chrono::Utc::now().to_rfc3339()],
            )?;
            tx.commit()?;
            SessionRepo::get_by_id(&conn, session_id)?
                .ok_or_else(|| EventStoreError::SessionNotFound(session_id.to_owned()))
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
                    tags: None,
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
            let source_tags =
                serde_json::from_str::<Vec<String>>(&source_session.tags).unwrap_or_default();
            let session = SessionRepo::create_with_identity(
                &tx,
                &CreateSessionOptions {
                    workspace_id: &source_session.workspace_id,
                    model,
                    working_directory: &source_session.working_directory,
                    title: opts.title,
                    tags: Some(&source_tags),
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

    /// Update the latest model and append its durable timeline event atomically.
    ///
    /// A no-op switch writes nothing, which keeps retries idempotent and avoids
    /// duplicate system notices during reconstruction. The returned prior
    /// model is read under the same session lock, so concurrent clients cannot
    /// receive a stale transition description.
    pub fn update_latest_model(&self, session_id: &str, model: &str) -> Result<(String, bool)> {
        self.with_session_write_lock(session_id, || {
            let mut conn = self.conn()?;
            let tx = conn.transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;
            let session = SessionRepo::get_by_id(&tx, session_id)?
                .ok_or_else(|| EventStoreError::SessionNotFound(session_id.to_owned()))?;
            if session.latest_model == model {
                return Ok((session.latest_model, false));
            }

            let previous_model = session.latest_model.clone();
            let changed = SessionRepo::update_latest_model(&tx, session_id, model)?;
            let _ = append_event_in_tx_with_identity(
                &tx,
                &session,
                &AppendOptions {
                    session_id,
                    event_type: EventType::SessionModelChanged,
                    payload: serde_json::json!({
                        "previousModel": previous_model,
                        "newModel": model,
                    }),
                    parent_id: None,
                    sequence: None,
                },
                EventIdentity::generate_current(),
            )?;
            tx.commit()?;
            Ok((previous_model, changed))
        })
    }

    /// Persist the effective reasoning level and return its previous value.
    ///
    /// Reasoning is event-owned rather than another mutable session column:
    /// the latest indexed event reconstructs current state while the full log
    /// preserves the visible audit trail. The read/compare/append sequence is
    /// serialized and transactional so retries cannot create duplicate rows.
    /// The expected model is checked under that same lock, preventing a level
    /// validated for one model from being committed after another client
    /// switches the session.
    pub fn update_reasoning_level(
        &self,
        session_id: &str,
        expected_model: &str,
        level: &str,
    ) -> Result<(Option<String>, bool)> {
        self.with_session_write_lock(session_id, || {
            let mut conn = self.conn()?;
            let tx = conn.transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;
            let session = SessionRepo::get_by_id(&tx, session_id)?
                .ok_or_else(|| EventStoreError::SessionNotFound(session_id.to_owned()))?;
            if session.latest_model != expected_model {
                return Err(EventStoreError::InvalidOperation(format!(
                    "session model changed from '{expected_model}' to '{}' while selecting reasoning",
                    session.latest_model
                )));
            }
            let previous = EventRepo::get_latest_by_type(
                &tx,
                session_id,
                EventType::SessionReasoningChanged.as_str(),
            )?
            .map(|row| {
                crate::shared::storage::resolve_stored_json_value(&tx, &row.payload).map_err(
                    |error| {
                        EventStoreError::Internal(format!(
                            "resolve reasoning selection {}: {error:#}",
                            row.id
                        ))
                    },
                )
            })
            .transpose()?
            .and_then(|payload| {
                payload
                    .get("newLevel")
                    .and_then(serde_json::Value::as_str)
                    .map(str::to_owned)
            });

            if previous.as_deref() == Some(level) {
                return Ok((previous, false));
            }

            let _ = append_event_in_tx_with_identity(
                &tx,
                &session,
                &AppendOptions {
                    session_id,
                    event_type: EventType::SessionReasoningChanged,
                    payload: serde_json::json!({
                        "previousLevel": previous,
                        "newLevel": level,
                    }),
                    parent_id: None,
                    sequence: None,
                },
                EventIdentity::generate_current(),
            )?;
            tx.commit()?;
            Ok((previous, true))
        })
    }

    /// Update session title.
    pub fn update_session_title(&self, session_id: &str, title: Option<&str>) -> Result<bool> {
        self.with_session_write_lock(session_id, || {
            let conn = self.conn()?;
            SessionRepo::update_title(&conn, session_id, title)
        })
    }

    /// Set a title only if no explicit title exists at commit time.
    pub fn set_session_title_if_untitled(&self, session_id: &str, title: &str) -> Result<bool> {
        self.with_session_write_lock(session_id, || {
            let conn = self.conn()?;
            SessionRepo::set_title_if_untitled(&conn, session_id, title)
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

    /// Get message previews for a list of sessions.
    ///
    /// Returns the last user prompt and last assistant response per session.
    pub(crate) fn get_session_message_previews(
        &self,
        session_ids: &[&str],
    ) -> Result<HashMap<String, MessagePreview>> {
        let conn = self.conn()?;
        SessionRepo::get_message_previews(&conn, session_ids)
    }

    /// Get activity summary lines for a single session list item.
    pub(crate) fn get_session_activity_summaries(
        &self,
        session_id: &str,
    ) -> Result<Vec<ActivitySummaryLine>> {
        let conn = self.conn()?;
        SessionRepo::get_activity_summaries(&conn, session_id)
    }

    /// Get activity summaries for multiple sessions (batch).
    pub(crate) fn get_session_activity_summaries_batch(
        &self,
        session_ids: &[&str],
    ) -> Result<HashMap<String, Vec<ActivitySummaryLine>>> {
        let conn = self.conn()?;
        SessionRepo::get_activity_summaries_batch(&conn, session_ids)
    }
}
