//! Session manager — session lifecycle facade and projection-cache owner.
//!
//! Durable session truth lives in the session event store. This module owns the
//! reconstructable in-process cache, idle eviction timestamps, and prompt-run
//! eviction pins. The orchestrator run registry remains the authority for run
//! activity and same-session concurrency.

use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant};

use crate::domains::session::event_store::EventStore;
use crate::domains::session::event_store::identity::SessionCreationIdentity;
use dashmap::DashMap;
use dashmap::mapref::entry::Entry;
use parking_lot::Mutex;
use tracing::{debug, info, instrument};

use crate::domains::agent::r#loop::errors::RuntimeError;
use crate::domains::agent::r#loop::orchestrator::session_reconstructor::{
    self, ReconstructedState,
};

/// Cached reconstructed state with access tracking for idle eviction.
struct CachedSession {
    /// Immutable projection rebuilt from durable session events.
    state: Arc<ReconstructedState>,
    /// Last time this session was accessed (for TTL eviction).
    last_accessed: Mutex<Instant>,
    /// Whether an active prompt has pinned this projection against idle eviction.
    eviction_pinned: AtomicBool,
}

impl CachedSession {
    fn new(state: Arc<ReconstructedState>, eviction_pinned: bool) -> Self {
        Self {
            state,
            last_accessed: Mutex::new(Instant::now()),
            eviction_pinned: AtomicBool::new(eviction_pinned),
        }
    }

    fn access(&self, pin_for_prompt: bool) -> Arc<ReconstructedState> {
        *self.last_accessed.lock() = Instant::now();
        if pin_for_prompt {
            self.eviction_pinned.store(true, Ordering::Release);
        }
        self.state.clone()
    }
}

/// Session manager.
pub struct SessionManager {
    event_store: Arc<EventStore>,
    cached_sessions: DashMap<String, CachedSession>,
}

impl SessionManager {
    /// Create a new session manager.
    pub fn new(event_store: Arc<EventStore>) -> Self {
        Self {
            event_store,
            cached_sessions: DashMap::new(),
        }
    }

    /// Create a new session.
    #[instrument(skip(self), fields(model, working_dir = workspace_path))]
    pub(crate) fn create_session(
        &self,
        model: &str,
        workspace_path: &str,
        title: Option<&str>,
    ) -> Result<String, RuntimeError> {
        let result = self
            .event_store
            .create_session(model, workspace_path, title, None)
            .map_err(|error| RuntimeError::Persistence(error.to_string()))?;
        let session_id = result.session.id;
        self.cache_created_session(&session_id, model, workspace_path);
        debug!(session_id, "session created");
        Ok(session_id)
    }

    /// Create an ordinary session with a preallocated durable identity.
    ///
    /// Source-control placement uses the future session ID to derive a unique
    /// branch and worktree path before the database transaction commits. The
    /// same identity must therefore reach durable creation unchanged.
    pub(crate) fn create_session_with_identity(
        &self,
        model: &str,
        workspace_path: &str,
        title: Option<&str>,
        identity: SessionCreationIdentity,
    ) -> Result<String, RuntimeError> {
        let result = self
            .event_store
            .create_session_with_identity(model, workspace_path, title, None, identity)
            .map_err(|error| RuntimeError::Persistence(error.to_string()))?;
        let session_id = result.session.id;
        self.cache_created_session(&session_id, model, workspace_path);
        debug!(session_id, "session created with preallocated identity");
        Ok(session_id)
    }

    /// Create a durable model session owned by one worker invocation.
    #[cfg(test)]
    pub(in crate::domains) fn create_worker_session(
        &self,
        model: &str,
        workspace_path: &str,
        title: Option<&str>,
    ) -> Result<String, RuntimeError> {
        let result = self
            .event_store
            .create_worker_session(model, workspace_path, title, None)
            .map_err(|error| RuntimeError::Persistence(error.to_string()))?;
        let session_id = result.session.id;
        self.cache_created_session(&session_id, model, workspace_path);
        debug!(session_id, "worker session created");
        Ok(session_id)
    }

    /// Create the hidden durable transcript for one reusable agent.
    #[cfg(test)]
    pub(in crate::domains) fn create_agent_session(
        &self,
        model: &str,
        workspace_path: &str,
        title: Option<&str>,
    ) -> Result<String, RuntimeError> {
        let result = self
            .event_store
            .create_agent_session(model, workspace_path, title, None)
            .map_err(|error| RuntimeError::Persistence(error.to_string()))?;
        let session_id = result.session.id;
        self.cache_created_session(&session_id, model, workspace_path);
        debug!(session_id, "nested agent session created");
        Ok(session_id)
    }

    /// Create a hidden reusable-agent transcript with preallocated identity.
    pub(in crate::domains) fn create_agent_session_with_identity(
        &self,
        model: &str,
        workspace_path: &str,
        title: Option<&str>,
        identity: SessionCreationIdentity,
    ) -> Result<String, RuntimeError> {
        let result = self
            .event_store
            .create_agent_session_with_identity(model, workspace_path, title, None, identity)
            .map_err(|error| RuntimeError::Persistence(error.to_string()))?;
        let session_id = result.session.id;
        self.cache_created_session(&session_id, model, workspace_path);
        debug!(
            session_id,
            "nested agent session created with preallocated identity"
        );
        Ok(session_id)
    }

    /// Reveal the same nested-agent transcript in the ordinary task index.
    pub(in crate::domains) fn promote_agent_session(
        &self,
        session_id: &str,
    ) -> Result<(), RuntimeError> {
        let _ = self
            .event_store
            .promote_agent_session(session_id)
            .map_err(|error| RuntimeError::Persistence(error.to_string()))?;
        Ok(())
    }

    fn cache_created_session(&self, session_id: &str, model: &str, workspace_path: &str) {
        let state = Arc::new(ReconstructedState {
            model: model.to_owned(),
            working_directory: Some(workspace_path.to_owned()),
            ..Default::default()
        });

        let _ = self
            .cached_sessions
            .insert(session_id.to_owned(), CachedSession::new(state, false));
    }

    /// Resume an existing session by reconstructing from persisted events.
    #[instrument(skip(self), fields(session_id))]
    pub(in crate::domains) fn resume_session(
        &self,
        session_id: &str,
    ) -> Result<Arc<ReconstructedState>, RuntimeError> {
        self.resume_session_inner(session_id, false)
    }

    /// Resume a session for a prompt and make its cache entry non-evictable
    /// before returning the reconstructed state.
    pub(in crate::domains::agent) fn resume_session_for_prompt(
        &self,
        session_id: &str,
    ) -> Result<Arc<ReconstructedState>, RuntimeError> {
        self.resume_session_inner(session_id, true)
    }

    fn resume_session_inner(
        &self,
        session_id: &str,
        pin_for_prompt: bool,
    ) -> Result<Arc<ReconstructedState>, RuntimeError> {
        // Check if already active
        if let Some(existing) = self.cached_sessions.get(session_id) {
            return Ok(existing.access(pin_for_prompt));
        }

        // Reconstruct from events
        let state = Arc::new(session_reconstructor::reconstruct(
            &self.event_store,
            session_id,
        )?);

        let cached = CachedSession::new(state.clone(), pin_for_prompt);
        match self.cached_sessions.entry(session_id.to_owned()) {
            Entry::Occupied(existing) => Ok(existing.get().access(pin_for_prompt)),
            Entry::Vacant(entry) => {
                let _ = entry.insert(cached);
                debug!(session_id, "session resumed");
                Ok(state)
            }
        }
    }

    /// Archive a session.
    pub(in crate::domains) fn archive_session(&self, session_id: &str) -> Result<(), RuntimeError> {
        let _ = self.cached_sessions.remove(session_id);
        let _ = self
            .event_store
            .end_session(session_id)
            .map_err(|e| RuntimeError::Persistence(e.to_string()))?;
        Ok(())
    }

    /// Delete a session.
    pub(in crate::domains) fn delete_session(&self, session_id: &str) -> Result<(), RuntimeError> {
        let _ = self.cached_sessions.remove(session_id);
        let _ = self
            .event_store
            .delete_session(session_id)
            .map_err(|e| RuntimeError::Persistence(e.to_string()))?;
        Ok(())
    }

    /// Drop reconstructed runtime projections without changing durable session
    /// lifecycle. Every retained session remains resumable after restart.
    pub(super) fn clear_cache_for_shutdown(&self) {
        self.cached_sessions.clear();
    }

    /// Check whether a reconstructed session projection is cached.
    pub(in crate::domains) fn is_cached(&self, session_id: &str) -> bool {
        self.cached_sessions.contains_key(session_id)
    }

    /// Number of reconstructed session projections currently cached.
    pub(in crate::domains::agent) fn cached_count(&self) -> usize {
        self.cached_sessions.len()
    }

    /// Invalidate cached session state, forcing re-reconstruction on next `resume_session`.
    pub(in crate::domains) fn invalidate_session(&self, session_id: &str) {
        let _ = self.cached_sessions.remove(session_id);
    }

    // ── Cache eviction ────────────────────────────────────────────────

    /// Evict idle sessions from the in-memory cache.
    ///
    /// Cache entries pinned by an active prompt are never evicted.
    /// Evicted sessions are seamlessly reconstructed via `resume_session()`.
    /// Returns the number of sessions evicted.
    pub(crate) fn evict_idle_sessions(&self, ttl: Duration) -> usize {
        let now = Instant::now();
        let mut evicted = 0usize;
        self.cached_sessions.retain(|session_id, cached| {
            if cached.eviction_pinned.load(Ordering::Relaxed) {
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
}

#[cfg(test)]
mod tests;
