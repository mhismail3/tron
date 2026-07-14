//! Session manager — session lifecycle facade and projection-cache owner.
//!
//! Durable session truth lives in the session event store. This module owns the
//! reconstructable in-process cache, idle eviction timestamps, and prompt-run
//! eviction pins. The orchestrator run registry remains the authority for run
//! activity and same-session concurrency.

use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant};

use crate::domains::session::event_store::{
    AppendOptions, EventStore, EventType, ListSessionsOptions,
};
use dashmap::DashMap;
use dashmap::mapref::entry::Entry;
use parking_lot::Mutex;
use serde_json::json;

use tracing::{debug, info, instrument, warn};

use crate::domains::agent::r#loop::errors::RuntimeError;
use crate::domains::agent::r#loop::orchestrator::session_reconstructor::{
    self, ReconstructedState,
};

/// Result of a session fork operation.
pub(in crate::domains) struct ForkSessionResult {
    /// The new forked session ID.
    pub(in crate::domains) new_session_id: String,
    /// The root event in the new session (the fork event).
    pub(in crate::domains) root_event_id: String,
    /// The event ID from which the fork was created.
    pub(in crate::domains) forked_from_event_id: String,
}

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
            .map_err(|e| RuntimeError::Persistence(e.to_string()))?;

        let session_id = result.session.id.clone();

        let state = Arc::new(ReconstructedState {
            model: model.to_owned(),
            working_directory: Some(workspace_path.to_owned()),
            ..Default::default()
        });

        let _ = self
            .cached_sessions
            .insert(session_id.clone(), CachedSession::new(state, false));
        debug!(session_id, "session created");
        Ok(session_id)
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

    /// End a session (remove it from the active map, persist `session.end`).
    fn end_session(&self, session_id: &str) -> Result<(), RuntimeError> {
        let _ = self.cached_sessions.remove(session_id);

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
    pub(in crate::domains) fn fork_session(
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

    /// End every unarchived durable session while preserving cache/event cleanup.
    pub(super) fn end_unarchived_sessions_for_shutdown(&self) {
        let sessions = match self.event_store.list_sessions(&ListSessionsOptions {
            ended: Some(false),
            ..Default::default()
        }) {
            Ok(sessions) => sessions,
            Err(error) => {
                warn!(%error, "failed to list unarchived sessions during shutdown");
                return;
            }
        };

        for session in sessions {
            if let Err(error) = self.end_session(&session.id) {
                warn!(
                    session_id = %session.id,
                    error = %error,
                    "failed to end session during shutdown"
                );
            }
        }
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
