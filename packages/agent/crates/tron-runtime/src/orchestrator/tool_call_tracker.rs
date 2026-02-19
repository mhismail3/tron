//! Tool-call tracker — manages pending tool results via oneshot channels.

use std::collections::HashMap;

use serde_json::Value;
use tokio::sync::oneshot;

/// Tracks pending tool calls and routes results back to the agent loop.
pub struct ToolCallTracker {
    pending: HashMap<String, oneshot::Sender<Value>>,
}

impl ToolCallTracker {
    /// Create an empty tracker.
    pub fn new() -> Self {
        Self {
            pending: HashMap::new(),
        }
    }

    /// Register a tool call, returning a receiver that will deliver the result.
    pub fn register(&mut self, tool_call_id: &str) -> oneshot::Receiver<Value> {
        let (tx, rx) = oneshot::channel();
        let _ = self.pending.insert(tool_call_id.to_string(), tx);
        rx
    }

    /// Resolve a pending tool call with a result value.
    /// Returns `true` if the tool call was found and resolved, `false` otherwise.
    pub fn resolve(&mut self, tool_call_id: &str, value: Value) -> bool {
        if let Some(tx) = self.pending.remove(tool_call_id) {
            tx.send(value).is_ok()
        } else {
            false
        }
    }

    /// Check if a tool call is pending.
    pub fn has_pending(&self, tool_call_id: &str) -> bool {
        self.pending.contains_key(tool_call_id)
    }

    /// Number of pending tool calls.
    pub fn pending_count(&self) -> usize {
        self.pending.len()
    }

    /// Cancel all pending tool calls (drops senders, receivers will get errors).
    pub fn cancel_all(&mut self) {
        self.pending.clear();
    }
}

impl Default for ToolCallTracker {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn new_is_empty() {
        let tracker = ToolCallTracker::new();
        assert_eq!(tracker.pending_count(), 0);
    }

    #[tokio::test]
    async fn register_returns_receiver() {
        let mut tracker = ToolCallTracker::new();
        let _rx = tracker.register("tc_1");
        assert!(tracker.has_pending("tc_1"));
        assert_eq!(tracker.pending_count(), 1);
    }

    #[tokio::test]
    async fn resolve_sends_value() {
        let mut tracker = ToolCallTracker::new();
        let rx = tracker.register("tc_1");

        let resolved = tracker.resolve("tc_1", json!({"output": "done"}));
        assert!(resolved);

        let result = rx.await.unwrap();
        assert_eq!(result["output"], "done");
    }

    #[test]
    fn resolve_nonexistent_returns_false() {
        let mut tracker = ToolCallTracker::new();
        assert!(!tracker.resolve("unknown", json!(null)));
    }

    #[tokio::test]
    async fn has_pending_false_after_resolve() {
        let mut tracker = ToolCallTracker::new();
        let _rx = tracker.register("tc_1");
        assert!(tracker.has_pending("tc_1"));

        let _ = tracker.resolve("tc_1", json!(null));
        assert!(!tracker.has_pending("tc_1"));
    }

    #[test]
    fn has_pending_false_unknown() {
        let tracker = ToolCallTracker::new();
        assert!(!tracker.has_pending("nope"));
    }

    #[tokio::test]
    async fn cancel_all_drops_senders() {
        let mut tracker = ToolCallTracker::new();
        let rx1 = tracker.register("tc_1");
        let rx2 = tracker.register("tc_2");

        tracker.cancel_all();
        assert_eq!(tracker.pending_count(), 0);

        // Receivers should error since senders were dropped
        assert!(rx1.await.is_err());
        assert!(rx2.await.is_err());
    }

    #[tokio::test]
    async fn multiple_pending() {
        let mut tracker = ToolCallTracker::new();
        let rx1 = tracker.register("tc_1");
        let rx2 = tracker.register("tc_2");
        let rx3 = tracker.register("tc_3");
        assert_eq!(tracker.pending_count(), 3);

        let _ = tracker.resolve("tc_2", json!("two"));
        assert_eq!(tracker.pending_count(), 2);

        let _ = tracker.resolve("tc_1", json!("one"));
        let _ = tracker.resolve("tc_3", json!("three"));
        assert_eq!(tracker.pending_count(), 0);

        assert_eq!(rx1.await.unwrap(), json!("one"));
        assert_eq!(rx2.await.unwrap(), json!("two"));
        assert_eq!(rx3.await.unwrap(), json!("three"));
    }

    #[tokio::test]
    async fn resolve_only_once() {
        let mut tracker = ToolCallTracker::new();
        let rx = tracker.register("tc_1");

        assert!(tracker.resolve("tc_1", json!("first")));
        assert!(!tracker.resolve("tc_1", json!("second")));

        assert_eq!(rx.await.unwrap(), json!("first"));
    }

    #[tokio::test]
    async fn register_same_id_replaces() {
        let mut tracker = ToolCallTracker::new();
        let rx1 = tracker.register("tc_1");
        let rx2 = tracker.register("tc_1"); // replaces

        assert_eq!(tracker.pending_count(), 1);

        // Old receiver should error (sender was replaced/dropped)
        assert!(rx1.await.is_err());

        // New receiver should work
        let _ = tracker.resolve("tc_1", json!("result"));
        assert_eq!(rx2.await.unwrap(), json!("result"));
    }
}
