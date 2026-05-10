//! Session manager — create, resume, end, fork, archive, list sessions.

use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant};

use crate::domains::session::event_store::{AppendOptions, EventStore, EventType};
use dashmap::DashMap;
use parking_lot::Mutex;
use serde_json::json;

use tracing::{debug, info, instrument};

use crate::domains::agent::runner::errors::RuntimeError;
use crate::domains::agent::runner::orchestrator::session_context::SessionContext;
use crate::domains::agent::runner::orchestrator::session_reconstructor::{
    self, ReconstructedState,
};

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

/// Cached session with access tracking for idle eviction.
pub struct CachedSession {
    /// The active session.
    pub session: Arc<ActiveSession>,
    /// Last time this session was accessed (for TTL eviction).
    pub last_accessed: Mutex<Instant>,
    /// Whether an agent loop is currently processing a prompt.
    /// Prevents eviction and concurrent access (Phase 6).
    pub is_processing: AtomicBool,
}

impl CachedSession {
    fn new(session: Arc<ActiveSession>) -> Self {
        Self {
            session,
            last_accessed: Mutex::new(Instant::now()),
            is_processing: AtomicBool::new(false),
        }
    }

    fn touch(&self) {
        *self.last_accessed.lock() = Instant::now();
    }
}

/// Filter for listing sessions.
#[derive(Clone, Debug, Default)]
pub struct SessionFilter {
    /// Filter by workspace path.
    pub workspace_path: Option<String>,
    /// Include archived sessions.
    pub include_archived: bool,
    /// Exclude subagent sessions (`spawning_session_id` IS NULL).
    pub exclude_subagents: bool,
    /// Show only user-created sessions (exclude cron, etc.).
    pub user_only: bool,
    /// Maximum number of results.
    pub limit: Option<usize>,
    /// Skip results.
    pub offset: Option<usize>,
}

/// Session manager.
pub struct SessionManager {
    event_store: Arc<EventStore>,
    active_sessions: DashMap<String, CachedSession>,
    plan_mode: DashMap<String, bool>,
    origin: Option<String>,
    worktree_coordinator: std::sync::OnceLock<Arc<crate::domains::worktree::WorktreeCoordinator>>,
}

impl SessionManager {
    /// Create a new session manager.
    pub fn new(event_store: Arc<EventStore>) -> Self {
        Self {
            event_store,
            active_sessions: DashMap::new(),
            plan_mode: DashMap::new(),
            origin: None,
            worktree_coordinator: std::sync::OnceLock::new(),
        }
    }

    /// Set the server origin (e.g. "localhost:9847") for all sessions created by this manager.
    #[must_use]
    pub fn with_origin(mut self, origin: String) -> Self {
        self.origin = Some(origin);
        self
    }

    /// Set the worktree coordinator for session isolation.
    ///
    /// Uses `OnceLock` so this can be called after the manager is `Arc`-wrapped.
    pub fn set_worktree_coordinator(
        &self,
        coordinator: Arc<crate::domains::worktree::WorktreeCoordinator>,
    ) {
        let _ = self.worktree_coordinator.set(coordinator);
    }

    /// Create a new session.
    #[instrument(skip(self), fields(model, working_dir = workspace_path))]
    pub fn create_session(
        &self,
        model: &str,
        workspace_path: &str,
        title: Option<&str>,
        source: Option<&str>,
    ) -> Result<String, RuntimeError> {
        self.create_session_with_profile_and_worktree_override(
            model,
            workspace_path,
            title,
            source,
            None,
            None,
        )
    }

    /// Like [`create_session`] but accepts a per-session worktree override:
    ///   * `None` defers to the global isolation mode setting (current default).
    ///   * `Some(true)` forces an isolated worktree on first prompt (when in a git repo).
    ///   * `Some(false)` forces passthrough (no worktree) regardless of global mode.
    #[instrument(skip(self), fields(model, working_dir = workspace_path))]
    pub fn create_session_with_worktree_override(
        &self,
        model: &str,
        workspace_path: &str,
        title: Option<&str>,
        source: Option<&str>,
        use_worktree: Option<bool>,
    ) -> Result<String, RuntimeError> {
        self.create_session_with_profile_and_worktree_override(
            model,
            workspace_path,
            title,
            source,
            None,
            use_worktree,
        )
    }

    /// Like [`create_session_with_worktree_override`] but records the selected
    /// execution profile for prompt/context/tool policy resolution.
    #[instrument(skip(self), fields(model, working_dir = workspace_path))]
    pub fn create_session_with_profile_and_worktree_override(
        &self,
        model: &str,
        workspace_path: &str,
        title: Option<&str>,
        source: Option<&str>,
        profile: Option<&str>,
        use_worktree: Option<bool>,
    ) -> Result<String, RuntimeError> {
        let result = self
            .event_store
            .create_session_with_worktree_override(
                model,
                workspace_path,
                title,
                None,
                self.origin.as_deref(),
                source,
                profile,
                use_worktree,
            )
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

        let _ = self
            .active_sessions
            .insert(session_id.clone(), CachedSession::new(active));
        debug!(session_id, "session created");
        Ok(session_id)
    }

    /// Resume an existing session (reconstruct from events).
    ///
    /// INVARIANT: callers must drain background hooks before calling this.
    /// The prompt handler drains via `agent_runner` pre-run step.
    #[instrument(skip(self), fields(session_id))]
    pub fn resume_session(&self, session_id: &str) -> Result<Arc<ActiveSession>, RuntimeError> {
        // Check if already active
        if let Some(existing) = self.active_sessions.get(session_id) {
            existing.touch();
            return Ok(existing.session.clone());
        }

        // Reconstruct from events
        let state = session_reconstructor::reconstruct(&self.event_store, session_id)?;

        let ctx = SessionContext::new(session_id.to_owned(), self.event_store.clone());
        let active = Arc::new(ActiveSession {
            context: ctx,
            state,
        });

        let _ = self
            .active_sessions
            .insert(session_id.to_owned(), CachedSession::new(active.clone()));
        debug!(session_id, "session resumed");
        Ok(active)
    }

    /// End a session (flush events, persist session.end, remove from active map).
    ///
    /// INVARIANT: worktree is released BEFORE `session.end` event is persisted.
    pub async fn end_session(&self, session_id: &str) -> Result<(), RuntimeError> {
        // Release worktree before ending the session
        if let Some(coord) = self.worktree_coordinator.get()
            && let Err(e) = coord.release(session_id).await
        {
            tracing::warn!(
                session_id,
                error = %e,
                "failed to release worktree during session end"
            );
        }

        if let Some((_, cached)) = self.active_sessions.remove(session_id) {
            cached.session.context.persister.flush().await?;
        }

        // Persist session.end event before marking the session as ended
        let _ = self
            .event_store
            .append(&AppendOptions {
                session_id,
                event_type: EventType::SessionEnd,
                payload: json!({"reason": "completed"}),
                parent_id: None,
                sequence: None,
            })
            .map_err(|e| RuntimeError::Persistence(e.to_string()))?;
        let _ = self
            .event_store
            .end_session(session_id)
            .map_err(|e| RuntimeError::Persistence(e.to_string()))?;
        Ok(())
    }

    /// Fork a session, optionally from a specific event (defaults to HEAD).
    pub fn fork_session(
        &self,
        session_id: &str,
        from_event_id: Option<&str>,
        model: Option<&str>,
        title: Option<&str>,
    ) -> Result<ForkSessionResult, RuntimeError> {
        let fork_event_id = if let Some(id) = from_event_id {
            id.to_owned()
        } else {
            let session = self
                .event_store
                .get_session(session_id)
                .map_err(|e| RuntimeError::Persistence(e.to_string()))?
                .ok_or_else(|| RuntimeError::SessionNotFound(session_id.to_owned()))?;
            session
                .head_event_id
                .ok_or_else(|| RuntimeError::Persistence("Session has no head event".into()))?
        };

        let result = self
            .event_store
            .fork(
                &fork_event_id,
                &crate::domains::session::event_store::ForkOptions { model, title },
            )
            .map_err(|e| RuntimeError::Persistence(e.to_string()))?;

        Ok(ForkSessionResult {
            new_session_id: result.session.id,
            root_event_id: result.fork_event.id,
            forked_from_event_id: fork_event_id,
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
    ) -> Result<
        Option<crate::domains::session::event_store::sqlite::row_types::SessionRow>,
        RuntimeError,
    > {
        self.event_store
            .get_session(session_id)
            .map_err(|e| RuntimeError::Persistence(e.to_string()))
    }

    /// List sessions.
    pub fn list_sessions(
        &self,
        filter: &SessionFilter,
    ) -> Result<
        Vec<crate::domains::session::event_store::sqlite::row_types::SessionRow>,
        RuntimeError,
    > {
        use crate::domains::session::event_store::sqlite::repositories::session::ListSessionsOptions;
        let opts = ListSessionsOptions {
            workspace_id: None,
            working_directory: filter.workspace_path.as_deref(),
            ended: if filter.include_archived {
                None
            } else {
                Some(false)
            },
            exclude_subagents: if filter.exclude_subagents {
                Some(true)
            } else {
                None
            },
            #[allow(clippy::cast_possible_wrap)]
            limit: filter.limit.map(|l| l as i64),
            #[allow(clippy::cast_possible_wrap)]
            offset: filter.offset.map(|o| o as i64),
            origin: self.origin.as_deref(),
            user_only: if filter.user_only { Some(true) } else { None },
        };
        self.event_store
            .list_sessions(&opts)
            .map_err(|e| RuntimeError::Persistence(e.to_string()))
    }

    /// Create a session for a subagent (linked to parent via `spawning_session_id`).
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
        let parent_profile = self
            .event_store
            .get_session(spawning_session_id)
            .map_err(|e| RuntimeError::Persistence(e.to_string()))?
            .map(|session| session.profile);

        let session_id = self.create_session_with_profile_and_worktree_override(
            model,
            workspace_path,
            title,
            None,
            parent_profile.as_deref(),
            None,
        )?;

        let _ = self
            .event_store
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
        self.plan_mode.get(session_id).is_some_and(|v| *v)
    }

    // ── Cache eviction ────────────────────────────────────────────────

    /// Evict idle sessions from the in-memory cache.
    ///
    /// Sessions that are currently processing a prompt are never evicted.
    /// Evicted sessions are seamlessly reconstructed via `resume_session()`.
    /// Returns the number of sessions evicted.
    pub fn evict_idle_sessions(&self, ttl: Duration) -> usize {
        let now = Instant::now();
        let mut evicted = 0usize;
        self.active_sessions.retain(|session_id, cached| {
            if cached.is_processing.load(Ordering::Relaxed) {
                return true;
            }
            let last = *cached.last_accessed.lock();
            let age = now.duration_since(last);
            if age > ttl {
                evicted += 1;
                info!(
                    session_id,
                    age_secs = age.as_secs(),
                    "evicting idle session from cache"
                );
                false
            } else {
                true
            }
        });
        evicted
    }

    /// Mark a session as currently processing (prevents eviction).
    pub fn mark_processing(&self, session_id: &str) -> bool {
        if let Some(cached) = self.active_sessions.get(session_id) {
            cached.touch();
            cached.is_processing.store(true, Ordering::Release);
            true
        } else {
            false
        }
    }

    /// Clear the processing flag for a session.
    pub fn clear_processing(&self, session_id: &str) {
        if let Some(cached) = self.active_sessions.get(session_id) {
            cached.is_processing.store(false, Ordering::Release);
            cached.touch();
        }
    }

    /// Check if a session is currently processing.
    pub fn is_processing(&self, session_id: &str) -> bool {
        self.active_sessions
            .get(session_id)
            .is_some_and(|cached| cached.is_processing.load(Ordering::Acquire))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn make_manager() -> SessionManager {
        let pool = crate::domains::session::event_store::new_in_memory(
            &crate::domains::session::event_store::ConnectionConfig::default(),
        )
        .unwrap();
        {
            let conn = pool.get().unwrap();
            let _ = crate::domains::session::event_store::run_migrations(&conn).unwrap();
        }
        SessionManager::new(Arc::new(EventStore::new(pool)))
    }

    #[tokio::test]
    async fn create_session() {
        let mgr = make_manager();
        let sid = mgr
            .create_session("test-model", "/tmp", Some("test"), None)
            .unwrap();
        assert!(!sid.is_empty());
        assert!(mgr.is_active(&sid));
        assert_eq!(mgr.active_count(), 1);
    }

    #[tokio::test]
    async fn create_subagent_session_inherits_parent_profile() {
        let mgr = make_manager();
        let parent = mgr
            .create_session_with_profile_and_worktree_override(
                "test-model",
                "/tmp",
                Some("parent"),
                None,
                Some(crate::shared::profile::CHAT_PROFILE),
                None,
            )
            .unwrap();

        let child = mgr
            .create_session_for_subagent("test-model", "/tmp", Some("child"), &parent, "task", "do")
            .unwrap();

        let child_row = mgr.event_store.get_session(&child).unwrap().unwrap();
        assert_eq!(child_row.profile, crate::shared::profile::CHAT_PROFILE);
    }

    #[tokio::test]
    async fn resume_session() {
        let mgr = make_manager();
        let sid = mgr
            .create_session("test-model", "/tmp", Some("test"), None)
            .unwrap();

        // Drop from active cache
        mgr.invalidate_session(&sid);
        assert!(!mgr.is_active(&sid));

        // Resume should reconstruct
        let active = mgr.resume_session(&sid).unwrap();
        assert_eq!(active.state.model, "test-model");
        assert!(mgr.is_active(&sid));
    }

    #[tokio::test]
    async fn resume_already_active() {
        let mgr = make_manager();
        let sid = mgr
            .create_session("test-model", "/tmp", Some("test"), None)
            .unwrap();

        // Resume when already active should return existing
        let active = mgr.resume_session(&sid).unwrap();
        assert_eq!(active.state.model, "test-model");
        assert_eq!(mgr.active_count(), 1);
    }

    #[tokio::test]
    async fn end_session() {
        let mgr = make_manager();
        let sid = mgr
            .create_session("test-model", "/tmp", Some("test"), None)
            .unwrap();

        mgr.end_session(&sid).await.unwrap();
        assert!(!mgr.is_active(&sid));
    }

    /// Anchors the wire contract that `session.end` is an actively emitted
    /// event. This test guards against any future change that accidentally
    /// stops emitting the event (e.g. refactoring `end_session` to skip
    /// the append) because the iOS display layer treats the event as current.
    #[tokio::test]
    async fn end_session_emits_session_end_event() {
        use crate::domains::session::event_store::sqlite::repositories::event::ListEventsOptions;

        let mgr = make_manager();
        let sid = mgr
            .create_session("test-model", "/tmp", Some("test"), None)
            .unwrap();

        mgr.end_session(&sid).await.unwrap();

        let events = mgr
            .event_store
            .get_events_by_session(&sid, &ListEventsOptions::default())
            .unwrap();
        let end_event = events
            .iter()
            .find(|e| e.event_type == EventType::SessionEnd.as_str())
            .expect("end_session must persist a session.end event");
        let payload: serde_json::Value = serde_json::from_str(&end_event.payload).unwrap();
        assert_eq!(
            payload.get("reason").and_then(|r| r.as_str()),
            Some("completed"),
            "session.end payload must carry reason=completed"
        );
    }

    #[tokio::test]
    async fn fork_session() {
        let mgr = make_manager();
        let sid = mgr
            .create_session("test-model", "/tmp", Some("test"), None)
            .unwrap();

        let result = mgr.fork_session(&sid, None, None, Some("forked")).unwrap();
        assert!(!result.new_session_id.is_empty());
        assert_ne!(result.new_session_id, sid);
        assert!(!result.root_event_id.is_empty());
        assert!(!result.forked_from_event_id.is_empty());
    }

    #[tokio::test]
    async fn fork_session_from_specific_event() {
        let mgr = make_manager();
        let sid = mgr
            .create_session("test-model", "/tmp", Some("test"), None)
            .unwrap();

        // Append an event so we have something besides the root to fork from
        let evt = mgr
            .event_store
            .append(&crate::domains::session::event_store::AppendOptions {
                session_id: &sid,
                event_type: crate::domains::session::event_store::EventType::MessageUser,
                payload: serde_json::json!({"text": "hello"}),
                parent_id: None,
                sequence: None,
            })
            .unwrap();

        // Append another event so HEAD is different from our target
        let _ = mgr
            .event_store
            .append(&crate::domains::session::event_store::AppendOptions {
                session_id: &sid,
                event_type: crate::domains::session::event_store::EventType::MessageAssistant,
                payload: serde_json::json!({"text": "world"}),
                parent_id: None,
                sequence: None,
            })
            .unwrap();

        let result = mgr.fork_session(&sid, Some(&evt.id), None, None).unwrap();
        assert_eq!(
            result.forked_from_event_id, evt.id,
            "should fork from the specified event, not HEAD"
        );
    }

    #[tokio::test]
    async fn fork_session_from_head_when_no_event_id() {
        let mgr = make_manager();
        let sid = mgr
            .create_session("test-model", "/tmp", Some("test"), None)
            .unwrap();

        // Get the HEAD event
        let session = mgr.event_store.get_session(&sid).unwrap().unwrap();
        let head_event_id = session.head_event_id.unwrap();

        let result = mgr.fork_session(&sid, None, None, None).unwrap();
        assert_eq!(
            result.forked_from_event_id, head_event_id,
            "fork with no event ID should fork from HEAD"
        );
    }

    #[tokio::test]
    async fn fork_session_from_nonexistent_event_fails() {
        let mgr = make_manager();
        let _sid = mgr
            .create_session("test-model", "/tmp", Some("test"), None)
            .unwrap();

        let result = mgr.fork_session(&_sid, Some("nonexistent-event-id"), None, None);
        assert!(
            result.is_err(),
            "fork from nonexistent event should return error"
        );
    }

    #[tokio::test]
    async fn archive_and_unarchive() {
        let mgr = make_manager();
        let sid = mgr
            .create_session("test-model", "/tmp", Some("test"), None)
            .unwrap();

        mgr.archive_session(&sid).unwrap();
        assert!(!mgr.is_active(&sid));

        mgr.unarchive_session(&sid).unwrap();
        // Unarchive makes it available but doesn't add to active map
        assert!(!mgr.is_active(&sid));
    }

    #[tokio::test]
    async fn delete_session() {
        let mgr = make_manager();
        let sid = mgr
            .create_session("test-model", "/tmp", Some("test"), None)
            .unwrap();

        mgr.delete_session(&sid).unwrap();
        assert!(!mgr.is_active(&sid));
    }

    #[tokio::test]
    async fn list_sessions() {
        let mgr = make_manager();
        let _ = mgr
            .create_session("model-a", "/tmp/a", Some("s1"), None)
            .unwrap();
        let _ = mgr
            .create_session("model-b", "/tmp/b", Some("s2"), None)
            .unwrap();

        let sessions = mgr.list_sessions(&SessionFilter::default()).unwrap();
        assert_eq!(sessions.len(), 2);
    }

    #[tokio::test]
    async fn list_sessions_filters_by_workspace_path_and_offset() {
        let mgr = make_manager();
        let first = mgr
            .create_session("model-a", "/tmp/a", Some("s1"), None)
            .unwrap();
        let second = mgr
            .create_session("model-b", "/tmp/b", Some("s2"), None)
            .unwrap();

        let filtered = mgr
            .list_sessions(&SessionFilter {
                workspace_path: Some("/tmp/a".to_string()),
                ..Default::default()
            })
            .unwrap();
        assert_eq!(filtered.len(), 1);
        assert_eq!(filtered[0].id, first);

        let paged = mgr
            .list_sessions(&SessionFilter {
                limit: Some(1),
                offset: Some(1),
                ..Default::default()
            })
            .unwrap();
        assert_eq!(paged.len(), 1);
        assert!(
            paged
                .iter()
                .all(|session| session.id == first || session.id == second)
        );
    }

    #[tokio::test]
    async fn get_session() {
        let mgr = make_manager();
        let sid = mgr
            .create_session("test-model", "/tmp", Some("test"), None)
            .unwrap();

        let session = mgr.get_session(&sid).unwrap();
        assert!(session.is_some());
    }

    #[tokio::test]
    async fn session_not_found() {
        let mgr = make_manager();
        let result = mgr.resume_session("nonexistent");
        assert!(result.is_err());
    }

    #[tokio::test]
    async fn create_session_with_origin() {
        let pool = crate::domains::session::event_store::new_in_memory(
            &crate::domains::session::event_store::ConnectionConfig::default(),
        )
        .unwrap();
        {
            let conn = pool.get().unwrap();
            let _ = crate::domains::session::event_store::run_migrations(&conn).unwrap();
        }
        let store = Arc::new(EventStore::new(pool));
        let mgr = SessionManager::new(store.clone()).with_origin("localhost:9847".to_string());

        let sid = mgr
            .create_session("test-model", "/tmp", Some("origin test"), None)
            .unwrap();
        let session = store.get_session(&sid).unwrap().unwrap();
        assert_eq!(session.origin.as_deref(), Some("localhost:9847"));
    }

    #[tokio::test]
    async fn create_session_without_origin() {
        let mgr = make_manager();
        let sid = mgr
            .create_session("test-model", "/tmp", Some("no origin"), None)
            .unwrap();
        let session = mgr.get_session(&sid).unwrap().unwrap();
        assert!(session.origin.is_none());
    }

    #[tokio::test]
    async fn list_sessions_user_only() {
        let pool = crate::domains::session::event_store::new_in_memory(
            &crate::domains::session::event_store::ConnectionConfig::default(),
        )
        .unwrap();
        {
            let conn = pool.get().unwrap();
            let _ = crate::domains::session::event_store::run_migrations(&conn).unwrap();
        }
        let store = Arc::new(EventStore::new(pool));
        let mgr = SessionManager::new(store.clone());

        let _ = mgr
            .create_session("test-model", "/tmp", Some("user session"), None)
            .unwrap();
        let cron_sid = mgr
            .create_session("test-model", "/tmp", Some("Cron: daily"), None)
            .unwrap();
        assert!(store.update_source(&cron_sid, "cron").unwrap());

        let filtered = mgr
            .list_sessions(&SessionFilter {
                user_only: true,
                ..Default::default()
            })
            .unwrap();
        assert_eq!(filtered.len(), 1);
        assert_ne!(filtered[0].id, cron_sid);
    }

    #[tokio::test]
    async fn list_sessions_default_shows_all() {
        let pool = crate::domains::session::event_store::new_in_memory(
            &crate::domains::session::event_store::ConnectionConfig::default(),
        )
        .unwrap();
        {
            let conn = pool.get().unwrap();
            let _ = crate::domains::session::event_store::run_migrations(&conn).unwrap();
        }
        let store = Arc::new(EventStore::new(pool));
        let mgr = SessionManager::new(store.clone());

        let _ = mgr
            .create_session("test-model", "/tmp", Some("user session"), None)
            .unwrap();
        let cron_sid = mgr
            .create_session("test-model", "/tmp", Some("Cron: daily"), None)
            .unwrap();
        assert!(store.update_source(&cron_sid, "cron").unwrap());

        let all = mgr.list_sessions(&SessionFilter::default()).unwrap();
        assert_eq!(all.len(), 2);
    }

    #[tokio::test]
    async fn user_only_excludes_cron_sessions() {
        let pool = crate::domains::session::event_store::new_in_memory(
            &crate::domains::session::event_store::ConnectionConfig::default(),
        )
        .unwrap();
        {
            let conn = pool.get().unwrap();
            let _ = crate::domains::session::event_store::run_migrations(&conn).unwrap();
        }
        let store = Arc::new(EventStore::new(pool));
        let mgr = SessionManager::new(store.clone());

        let _ = mgr
            .create_session("test-model", "/tmp", Some("user session"), None)
            .unwrap();
        let cron_id = mgr
            .create_session("test-model", "/tmp", Some("Cron: daily"), None)
            .unwrap();
        assert!(store.update_source(&cron_id, "cron").unwrap());

        let filtered = mgr
            .list_sessions(&SessionFilter {
                user_only: true,
                ..Default::default()
            })
            .unwrap();

        // Should include user session but NOT cron
        assert_eq!(filtered.len(), 1);
        let ids: Vec<&str> = filtered.iter().map(|s| s.id.as_str()).collect();
        assert!(!ids.contains(&cron_id.as_str()));
    }

    // ── Cache eviction tests ────────────────────────────────────

    #[tokio::test]
    async fn evict_idle_session() {
        let mgr = make_manager();
        let sid = mgr.create_session("m", "/tmp", Some("test"), None).unwrap();

        // Force last_accessed to the past
        if let Some(cached) = mgr.active_sessions.get(&sid) {
            *cached.last_accessed.lock() = Instant::now() - Duration::from_secs(7200);
        }

        let evicted = mgr.evict_idle_sessions(Duration::from_secs(3600));
        assert_eq!(evicted, 1);
        assert!(!mgr.is_active(&sid));
    }

    #[tokio::test]
    async fn evict_preserves_recent_session() {
        let mgr = make_manager();
        let sid = mgr.create_session("m", "/tmp", Some("test"), None).unwrap();

        let evicted = mgr.evict_idle_sessions(Duration::from_secs(3600));
        assert_eq!(evicted, 0);
        assert!(mgr.is_active(&sid));
    }

    #[tokio::test]
    async fn evict_preserves_processing_session() {
        let mgr = make_manager();
        let sid = mgr.create_session("m", "/tmp", Some("test"), None).unwrap();

        // Mark as processing and make it old
        let _ = mgr.mark_processing(&sid);
        if let Some(cached) = mgr.active_sessions.get(&sid) {
            *cached.last_accessed.lock() = Instant::now() - Duration::from_secs(7200);
        }

        let evicted = mgr.evict_idle_sessions(Duration::from_secs(3600));
        assert_eq!(evicted, 0, "processing session must not be evicted");
        assert!(mgr.is_active(&sid));
    }

    #[tokio::test]
    async fn evicted_session_reconstructs_on_resume() {
        let mgr = make_manager();
        let sid = mgr.create_session("m", "/tmp", Some("test"), None).unwrap();

        // Evict it
        if let Some(cached) = mgr.active_sessions.get(&sid) {
            *cached.last_accessed.lock() = Instant::now() - Duration::from_secs(7200);
        }
        let _ = mgr.evict_idle_sessions(Duration::from_secs(3600));
        assert!(!mgr.is_active(&sid));

        // Resume should reconstruct
        let active = mgr.resume_session(&sid).unwrap();
        assert_eq!(active.state.model, "m");
        assert!(mgr.is_active(&sid));
    }

    #[tokio::test]
    async fn evict_mixed_idle_and_active() {
        let mgr = make_manager();
        let idle = mgr.create_session("m", "/tmp", Some("idle"), None).unwrap();
        let recent = mgr
            .create_session("m", "/tmp", Some("recent"), None)
            .unwrap();

        if let Some(cached) = mgr.active_sessions.get(&idle) {
            *cached.last_accessed.lock() = Instant::now() - Duration::from_secs(7200);
        }

        let evicted = mgr.evict_idle_sessions(Duration::from_secs(3600));
        assert_eq!(evicted, 1);
        assert!(!mgr.is_active(&idle));
        assert!(mgr.is_active(&recent));
    }

    #[tokio::test]
    async fn evict_zero_ttl_evicts_all_idle() {
        let mgr = make_manager();
        let s1 = mgr.create_session("m", "/tmp", Some("s1"), None).unwrap();
        let s2 = mgr.create_session("m", "/tmp", Some("s2"), None).unwrap();

        let evicted = mgr.evict_idle_sessions(Duration::ZERO);
        assert_eq!(evicted, 2);
        assert!(!mgr.is_active(&s1));
        assert!(!mgr.is_active(&s2));
    }

    #[tokio::test]
    async fn evict_empty_map_is_noop() {
        let mgr = make_manager();
        let evicted = mgr.evict_idle_sessions(Duration::from_secs(3600));
        assert_eq!(evicted, 0);
    }

    #[tokio::test]
    async fn processing_flag_lifecycle() {
        let mgr = make_manager();
        let sid = mgr.create_session("m", "/tmp", Some("test"), None).unwrap();

        assert!(!mgr.is_processing(&sid));
        mgr.mark_processing(&sid);
        assert!(mgr.is_processing(&sid));
        mgr.clear_processing(&sid);
        assert!(!mgr.is_processing(&sid));
    }
}
