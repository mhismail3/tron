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
            .create_session(model, workspace_path, title, None)
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
    pub async fn end_session(&self, session_id: &str) -> Result<(), RuntimeError> {
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
            #[allow(clippy::cast_possible_wrap)]
            limit: filter.limit.map(|l| l as i64),
            #[allow(clippy::cast_possible_wrap)]
            offset: filter.offset.map(|o| o as i64),
            user_only: if filter.user_only { Some(true) } else { None },
        };
        self.event_store
            .list_sessions(&opts)
            .map_err(|e| RuntimeError::Persistence(e.to_string()))
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
#[path = "session_manager/tests.rs"]
mod tests;
