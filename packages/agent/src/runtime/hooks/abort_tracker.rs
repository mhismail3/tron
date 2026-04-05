//! Abort tracker for fire-and-forget hook subsessions.
//!
//! Tracks [`AbortHandle`]s keyed by `"{session_id}:{hook_id}"` so that
//! when a new subsession starts for the same key, the previous one is
//! cancelled. Prevents stale results from slow subsessions overwriting
//! current ones (e.g., prompt suggestions from turn N arriving after
//! turn N+1's suggestions).

use std::collections::HashMap;
use std::sync::Mutex;

use tokio::task::AbortHandle;

/// Tracks abort handles for fire-and-forget hook subsessions.
///
/// Thread-safe via [`std::sync::Mutex`] (never held across await points).
/// Keys are `"{session_id}:{hook_id}"` strings.
pub struct HookAbortTracker {
    handles: Mutex<HashMap<String, AbortHandle>>,
}

impl HookAbortTracker {
    /// Create a new empty tracker.
    pub fn new() -> Self {
        Self {
            handles: Mutex::new(HashMap::new()),
        }
    }

    /// Abort the previous subsession for `key` (if any) and register `handle`
    /// as the new active subsession.
    ///
    /// Returns `true` if a previous subsession was aborted.
    pub fn replace(&self, key: &str, handle: AbortHandle) -> bool {
        let mut map = self.handles.lock().expect("abort tracker lock poisoned");
        let aborted = if let Some(prev) = map.remove(key) {
            prev.abort();
            true
        } else {
            false
        };
        let _ = map.insert(key.to_owned(), handle);
        aborted
    }
}

impl Default for HookAbortTracker {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Helper: create a no-op tokio task and return its AbortHandle.
    fn spawn_dummy() -> AbortHandle {
        tokio::spawn(std::future::pending::<()>()).abort_handle()
    }

    #[tokio::test]
    async fn test_replace_first_returns_false() {
        let tracker = HookAbortTracker::new();
        let handle = spawn_dummy();
        assert!(!tracker.replace("s1:suggest-prompts", handle));
    }

    #[tokio::test]
    async fn test_replace_second_returns_true_and_aborts() {
        let tracker = HookAbortTracker::new();
        let h1 = spawn_dummy();
        let h2 = spawn_dummy();

        assert!(!tracker.replace("s1:suggest-prompts", h1));
        // Second replace should abort h1 and return true
        assert!(tracker.replace("s1:suggest-prompts", h2));
    }

    #[tokio::test]
    async fn test_independent_keys_dont_interfere() {
        let tracker = HookAbortTracker::new();
        let h1 = spawn_dummy();
        let h2 = spawn_dummy();
        let h3 = spawn_dummy();

        tracker.replace("s1:suggest-prompts", h1);
        tracker.replace("s1:title-gen", h2);

        // Replacing suggest-prompts should NOT abort title-gen
        assert!(tracker.replace("s1:suggest-prompts", h3));

        // title-gen entry should still be present (replace returns true)
        let h4 = spawn_dummy();
        assert!(tracker.replace("s1:title-gen", h4));
    }

    #[tokio::test]
    async fn test_different_sessions_dont_interfere() {
        let tracker = HookAbortTracker::new();
        let h1 = spawn_dummy();
        let h2 = spawn_dummy();

        tracker.replace("s1:suggest-prompts", h1);

        // Different session key — should not abort s1's handle
        assert!(!tracker.replace("s2:suggest-prompts", h2));
    }
}
