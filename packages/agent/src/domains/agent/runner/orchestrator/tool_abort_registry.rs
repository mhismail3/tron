//! Per-call cancellation registry for cooperative abort.
//!
//! Each in-flight provider call gets its own `CancellationToken` child of the
//! turn-level cancellation token. The registry maps
//! `(session_id, tool_call_id)` to that child token so the `agent.abortTool`
//! Engine capabilities can cancel a single call without cancelling the rest of the turn.
//!
//! ## Lifecycle
//!
//! 1. `register(session_id, tool_call_id, parent)` — creates a child of the
//!    turn's cancellation token and stores it. Returns the child so the
//!    executor can pass it into capability-owned work.
//! 2. `unregister(session_id, tool_call_id)` — removes the entry once the
//!    tool completes (success, error, or cancellation). Called in a `Drop`
//!    guard in the executor so early returns cannot leak entries.
//! 3. `abort(session_id, tool_call_id)` — looked up by the engine transport.
//!    Returns `true` if a matching call was in flight; the child token is
//!    cancelled and the entry is removed.
//!
//! Parent-level turn abort (via `CancellationToken::cancel` on the turn
//! token) propagates to every child automatically; we do not have to loop
//! over the registry on turn abort.

use std::sync::Arc;

use dashmap::DashMap;
use tokio_util::sync::CancellationToken;

type Key = (String, String);

/// Per-call cancellation registry.
#[derive(Default)]
pub struct ToolAbortRegistry {
    entries: DashMap<Key, CancellationToken>,
}

impl ToolAbortRegistry {
    /// Create an empty registry.
    #[must_use]
    pub fn new() -> Self {
        Self {
            entries: DashMap::new(),
        }
    }

    /// Register a new in-flight provider call. Returns a child token derived
    /// from `parent`; capability-owned work selects on it for cooperative
    /// cancellation.
    #[must_use]
    pub fn register(
        &self,
        session_id: &str,
        tool_call_id: &str,
        parent: &CancellationToken,
    ) -> CancellationToken {
        let child = parent.child_token();
        let _ = self.entries.insert(
            (session_id.to_owned(), tool_call_id.to_owned()),
            child.clone(),
        );
        child
    }

    /// Remove an entry. Safe to call on an already-removed key.
    pub fn unregister(&self, session_id: &str, tool_call_id: &str) {
        let _ = self
            .entries
            .remove(&(session_id.to_owned(), tool_call_id.to_owned()));
    }

    /// Cancel a specific in-flight tool. Returns `true` if the tool was in
    /// the registry (the token was cancelled and the entry removed).
    pub fn abort(&self, session_id: &str, tool_call_id: &str) -> bool {
        if let Some((_, token)) = self
            .entries
            .remove(&(session_id.to_owned(), tool_call_id.to_owned()))
        {
            token.cancel();
            true
        } else {
            false
        }
    }

    /// Number of in-flight capability invocations tracked (across all sessions).
    pub fn len(&self) -> usize {
        self.entries.len()
    }

    /// True when no capability invocations are being tracked.
    pub fn is_empty(&self) -> bool {
        self.entries.is_empty()
    }
}

/// RAII guard that unregisters a tool on drop. Ensures cleanup even on
/// early returns / panics in the executor.
pub struct ToolAbortGuard {
    registry: Arc<ToolAbortRegistry>,
    session_id: String,
    tool_call_id: String,
}

impl ToolAbortGuard {
    /// Create a new guard that removes the entry on drop.
    #[must_use]
    pub fn new(registry: Arc<ToolAbortRegistry>, session_id: &str, tool_call_id: &str) -> Self {
        Self {
            registry,
            session_id: session_id.to_owned(),
            tool_call_id: tool_call_id.to_owned(),
        }
    }
}

impl Drop for ToolAbortGuard {
    fn drop(&mut self) {
        self.registry
            .unregister(&self.session_id, &self.tool_call_id);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn new_registry_is_empty() {
        let reg = ToolAbortRegistry::new();
        assert!(reg.is_empty());
        assert_eq!(reg.len(), 0);
    }

    #[test]
    fn register_inserts_entry() {
        let reg = ToolAbortRegistry::new();
        let parent = CancellationToken::new();
        let _child = reg.register("sess-1", "call_1", &parent);
        assert_eq!(reg.len(), 1);
        assert!(!reg.is_empty());
    }

    #[test]
    fn abort_cancels_child_but_not_parent() {
        let reg = ToolAbortRegistry::new();
        let parent = CancellationToken::new();
        let child = reg.register("sess-1", "call_1", &parent);

        assert!(!child.is_cancelled());
        assert!(reg.abort("sess-1", "call_1"));
        assert!(child.is_cancelled());
        assert!(
            !parent.is_cancelled(),
            "aborting a single tool must not cancel the turn"
        );
        assert!(reg.is_empty());
    }

    #[test]
    fn abort_unknown_returns_false() {
        let reg = ToolAbortRegistry::new();
        assert!(!reg.abort("sess-1", "nope"));
    }

    #[test]
    fn parent_cancel_propagates_to_child() {
        let reg = ToolAbortRegistry::new();
        let parent = CancellationToken::new();
        let child = reg.register("sess-1", "call_1", &parent);

        parent.cancel();
        assert!(
            child.is_cancelled(),
            "parent cancellation must propagate to children"
        );
    }

    #[test]
    fn unregister_removes_without_cancelling() {
        let reg = ToolAbortRegistry::new();
        let parent = CancellationToken::new();
        let child = reg.register("sess-1", "call_1", &parent);

        reg.unregister("sess-1", "call_1");
        assert!(reg.is_empty());
        assert!(
            !child.is_cancelled(),
            "unregister is a cleanup hook, not a cancel"
        );
    }

    #[test]
    fn session_scoping_keeps_sessions_independent() {
        let reg = ToolAbortRegistry::new();
        let parent_a = CancellationToken::new();
        let parent_b = CancellationToken::new();

        let child_a = reg.register("sess-A", "call_1", &parent_a);
        let child_b = reg.register("sess-B", "call_1", &parent_b);

        assert!(reg.abort("sess-A", "call_1"));
        assert!(child_a.is_cancelled());
        assert!(
            !child_b.is_cancelled(),
            "same tool_call_id in a different session must not be touched"
        );
    }

    #[test]
    fn guard_unregisters_on_drop() {
        let reg = Arc::new(ToolAbortRegistry::new());
        let parent = CancellationToken::new();
        let _child = reg.register("sess-1", "call_1", &parent);
        assert_eq!(reg.len(), 1);

        {
            let _guard = ToolAbortGuard::new(reg.clone(), "sess-1", "call_1");
        }

        assert!(reg.is_empty(), "guard drop must remove the registry entry");
    }

    #[test]
    fn abort_is_idempotent() {
        let reg = ToolAbortRegistry::new();
        let parent = CancellationToken::new();
        let _ = reg.register("sess-1", "call_1", &parent);

        assert!(reg.abort("sess-1", "call_1"));
        assert!(
            !reg.abort("sess-1", "call_1"),
            "second abort must return false"
        );
    }
}
