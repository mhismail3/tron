//! Session manager — create, resume, end, fork, archive, list sessions.

use std::sync::Arc;

use dashmap::DashMap;
use serde_json::json;
use tron_events::{AppendOptions, EventStore, EventType};

use tracing::{debug, instrument};

use crate::errors::RuntimeError;
use crate::orchestrator::session_context::SessionContext;
use crate::orchestrator::session_reconstructor::{self, ReconstructedState};

/// Result of a session fork operation.
pub struct ForkSessionResult {
    /// The new forked session ID.
    pub new_session_id: String,
    /// The root event in the new session (the fork event).
    pub root_event_id: String,
    /// The event ID from which the fork was created.
    pub forked_from_event_id: String,
}

/// Active session wrapper.
pub struct ActiveSession {
    /// Session context with persister and state.
    pub context: SessionContext,
    /// Reconstructed state (messages, model, etc.).
    pub state: ReconstructedState,
}

/// Filter for listing sessions.
#[derive(Clone, Debug, Default)]
pub struct SessionFilter {
    /// Filter by workspace path.
    pub workspace_path: Option<String>,
    /// Include archived sessions.
    pub include_archived: bool,
    /// Maximum number of results.
    pub limit: Option<usize>,
}

/// Session manager.
pub struct SessionManager {
    event_store: Arc<EventStore>,
    active_sessions: DashMap<String, Arc<ActiveSession>>,
    plan_mode: DashMap<String, bool>,
}

impl SessionManager {
    /// Create a new session manager.
    pub fn new(event_store: Arc<EventStore>) -> Self {
        Self {
            event_store,
            active_sessions: DashMap::new(),
            plan_mode: DashMap::new(),
        }
    }

    /// Create a new session.
    #[instrument(skip(self), fields(model, working_dir = workspace_path))]
    pub fn create_session(
        &self,
        model: &str,
        workspace_path: &str,
        title: Option<&str>,
    ) -> Result<String, RuntimeError> {
        let result = self
            .event_store
            .create_session(model, workspace_path, title)
            .map_err(|e| RuntimeError::Persistence(e.to_string()))?;

        let session_id = result.session.id.clone();

        let state = ReconstructedState {
            model: model.to_owned(),
            working_directory: Some(workspace_path.to_owned()),
            ..Default::default()
        };

        let ctx = SessionContext::new(session_id.clone(), self.event_store.clone());
        let active = Arc::new(ActiveSession {
            context: ctx,
            state,
        });

        let _ = self.active_sessions.insert(session_id.clone(), active);
        debug!(session_id, "session created");
        Ok(session_id)
    }

    /// Resume an existing session (reconstruct from events).
    #[instrument(skip(self), fields(session_id))]
    pub fn resume_session(&self, session_id: &str) -> Result<Arc<ActiveSession>, RuntimeError> {
        // Check if already active
        if let Some(existing) = self.active_sessions.get(session_id) {
            return Ok(existing.clone());
        }

        // Reconstruct from events
        let state = session_reconstructor::reconstruct(&self.event_store, session_id)?;

        let ctx = SessionContext::new(session_id.to_owned(), self.event_store.clone());
        let active = Arc::new(ActiveSession {
            context: ctx,
            state,
        });

        let _ = self.active_sessions
            .insert(session_id.to_owned(), active.clone());
        debug!(session_id, "session resumed");
        Ok(active)
    }

    /// End a session (flush events, persist session.end, remove from active map).
    pub async fn end_session(&self, session_id: &str) -> Result<(), RuntimeError> {
        if let Some((_, active)) = self.active_sessions.remove(session_id) {
            active.context.persister.flush().await?;
        }
        // Persist session.end event before marking the session as ended
        let _ = self
            .event_store
            .append(&AppendOptions {
                session_id,
                event_type: EventType::SessionEnd,
                payload: json!({"reason": "completed"}),
                parent_id: None,
            })
            .map_err(|e| RuntimeError::Persistence(e.to_string()))?;
        let _ = self
            .event_store
            .end_session(session_id)
            .map_err(|e| RuntimeError::Persistence(e.to_string()))?;
        Ok(())
    }

    /// Result of forking a session.
    pub fn fork_session(
        &self,
        session_id: &str,
        model: Option<&str>,
        title: Option<&str>,
    ) -> Result<ForkSessionResult, RuntimeError> {
        // Get the session's head event ID for forking
        let session = self
            .event_store
            .get_session(session_id)
            .map_err(|e| RuntimeError::Persistence(e.to_string()))?
            .ok_or_else(|| RuntimeError::SessionNotFound(session_id.to_owned()))?;

        let head_event_id = session
            .head_event_id
            .as_deref()
            .ok_or_else(|| RuntimeError::Persistence("Session has no head event".into()))?;

        let forked_from_event_id = head_event_id.to_owned();

        let result = self
            .event_store
            .fork(head_event_id, &tron_events::ForkOptions { model, title })
            .map_err(|e| RuntimeError::Persistence(e.to_string()))?;

        Ok(ForkSessionResult {
            new_session_id: result.session.id,
            root_event_id: result.fork_event.id,
            forked_from_event_id,
        })
    }

    /// Archive a session.
    pub fn archive_session(&self, session_id: &str) -> Result<(), RuntimeError> {
        let _ = self.active_sessions.remove(session_id);
        let _ = self
            .event_store
            .end_session(session_id)
            .map_err(|e| RuntimeError::Persistence(e.to_string()))?;
        Ok(())
    }

    /// Unarchive a session.
    pub fn unarchive_session(&self, session_id: &str) -> Result<(), RuntimeError> {
        let _ = self
            .event_store
            .clear_session_ended(session_id)
            .map_err(|e| RuntimeError::Persistence(e.to_string()))?;
        Ok(())
    }

    /// Delete a session.
    pub fn delete_session(&self, session_id: &str) -> Result<(), RuntimeError> {
        let _ = self.active_sessions.remove(session_id);
        let _ = self
            .event_store
            .delete_session(session_id)
            .map_err(|e| RuntimeError::Persistence(e.to_string()))?;
        Ok(())
    }

    /// Get session info.
    pub fn get_session(
        &self,
        session_id: &str,
    ) -> Result<Option<tron_events::sqlite::row_types::SessionRow>, RuntimeError> {
        self.event_store
            .get_session(session_id)
            .map_err(|e| RuntimeError::Persistence(e.to_string()))
    }

    /// List sessions.
    pub fn list_sessions(
        &self,
        filter: &SessionFilter,
    ) -> Result<Vec<tron_events::sqlite::row_types::SessionRow>, RuntimeError> {
        use tron_events::sqlite::repositories::session::ListSessionsOptions;
        let opts = ListSessionsOptions {
            workspace_id: None,
            ended: if filter.include_archived { None } else { Some(false) },
            exclude_subagents: None,
            #[allow(clippy::cast_possible_wrap)]
            limit: filter.limit.map(|l| l as i64),
            offset: None,
        };
        self.event_store
            .list_sessions(&opts)
            .map_err(|e| RuntimeError::Persistence(e.to_string()))
    }

    /// Create a session for a subagent (linked to parent via spawning_session_id).
    #[instrument(skip(self), fields(model, working_dir = workspace_path, parent = spawning_session_id))]
    pub fn create_session_for_subagent(
        &self,
        model: &str,
        workspace_path: &str,
        title: Option<&str>,
        spawning_session_id: &str,
        spawn_type: &str,
        spawn_task: &str,
    ) -> Result<String, RuntimeError> {
        let session_id = self.create_session(model, workspace_path, title)?;

        let _ = self.event_store
            .update_spawn_info(&session_id, spawning_session_id, spawn_type, spawn_task)
            .map_err(|e| RuntimeError::Persistence(e.to_string()))?;

        debug!(session_id, spawning_session_id, "subagent session created");
        Ok(session_id)
    }

    /// Check if a session is active.
    pub fn is_active(&self, session_id: &str) -> bool {
        self.active_sessions.contains_key(session_id)
    }

    /// Number of active sessions.
    pub fn active_count(&self) -> usize {
        self.active_sessions.len()
    }

    /// Invalidate cached session state, forcing re-reconstruction on next `resume_session`.
    pub fn invalidate_session(&self, session_id: &str) {
        let _ = self.active_sessions.remove(session_id);
    }

    /// Get the event store.
    pub fn event_store(&self) -> &Arc<EventStore> {
        &self.event_store
    }

    // ── Plan mode ──────────────────────────────────────────────────────

    /// Set plan mode for a session.
    pub fn set_plan_mode(&self, session_id: &str, enabled: bool) {
        let _ = self.plan_mode.insert(session_id.to_owned(), enabled);
    }

    /// Check if a session is in plan mode.
    pub fn is_plan_mode(&self, session_id: &str) -> bool {
        self.plan_mode
            .get(session_id)
            .is_some_and(|v| *v)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn make_manager() -> SessionManager {
        let pool = tron_events::new_in_memory(&tron_events::ConnectionConfig::default()).unwrap();
        {
            let conn = pool.get().unwrap();
            tron_events::run_migrations(&conn).unwrap();
        }
        SessionManager::new(Arc::new(EventStore::new(pool)))
    }

    #[tokio::test]
    async fn create_session() {
        let mgr = make_manager();
        let sid = mgr.create_session("test-model", "/tmp", Some("test")).unwrap();
        assert!(!sid.is_empty());
        assert!(mgr.is_active(&sid));
        assert_eq!(mgr.active_count(), 1);
    }

    #[tokio::test]
    async fn resume_session() {
        let mgr = make_manager();
        let sid = mgr.create_session("test-model", "/tmp", Some("test")).unwrap();

        // Drop from active
        mgr.active_sessions.remove(&sid);
        assert!(!mgr.is_active(&sid));

        // Resume should reconstruct
        let active = mgr.resume_session(&sid).unwrap();
        assert_eq!(active.state.model, "test-model");
        assert!(mgr.is_active(&sid));
    }

    #[tokio::test]
    async fn resume_already_active() {
        let mgr = make_manager();
        let sid = mgr.create_session("test-model", "/tmp", Some("test")).unwrap();

        // Resume when already active should return existing
        let active = mgr.resume_session(&sid).unwrap();
        assert_eq!(active.state.model, "test-model");
        assert_eq!(mgr.active_count(), 1);
    }

    #[tokio::test]
    async fn end_session() {
        let mgr = make_manager();
        let sid = mgr.create_session("test-model", "/tmp", Some("test")).unwrap();

        mgr.end_session(&sid).await.unwrap();
        assert!(!mgr.is_active(&sid));
    }

    #[tokio::test]
    async fn fork_session() {
        let mgr = make_manager();
        let sid = mgr.create_session("test-model", "/tmp", Some("test")).unwrap();

        let result = mgr.fork_session(&sid, None, Some("forked")).unwrap();
        assert!(!result.new_session_id.is_empty());
        assert_ne!(result.new_session_id, sid);
        assert!(!result.root_event_id.is_empty());
        assert!(!result.forked_from_event_id.is_empty());
    }

    #[tokio::test]
    async fn archive_and_unarchive() {
        let mgr = make_manager();
        let sid = mgr.create_session("test-model", "/tmp", Some("test")).unwrap();

        mgr.archive_session(&sid).unwrap();
        assert!(!mgr.is_active(&sid));

        mgr.unarchive_session(&sid).unwrap();
        // Unarchive makes it available but doesn't add to active map
        assert!(!mgr.is_active(&sid));
    }

    #[tokio::test]
    async fn delete_session() {
        let mgr = make_manager();
        let sid = mgr.create_session("test-model", "/tmp", Some("test")).unwrap();

        mgr.delete_session(&sid).unwrap();
        assert!(!mgr.is_active(&sid));
    }

    #[tokio::test]
    async fn list_sessions() {
        let mgr = make_manager();
        let _ = mgr.create_session("model-a", "/tmp/a", Some("s1")).unwrap();
        let _ = mgr.create_session("model-b", "/tmp/b", Some("s2")).unwrap();

        let sessions = mgr.list_sessions(&SessionFilter::default()).unwrap();
        assert_eq!(sessions.len(), 2);
    }

    #[tokio::test]
    async fn get_session() {
        let mgr = make_manager();
        let sid = mgr.create_session("test-model", "/tmp", Some("test")).unwrap();

        let session = mgr.get_session(&sid).unwrap();
        assert!(session.is_some());
    }

    #[tokio::test]
    async fn session_not_found() {
        let mgr = make_manager();
        let result = mgr.resume_session("nonexistent");
        assert!(result.is_err());
    }
}
