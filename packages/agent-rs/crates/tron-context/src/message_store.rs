//! In-memory message storage with token caching.
//!
//! [`MessageStore`] holds the conversation messages for an active session and
//! maintains a parallel token-count cache so that context budget calculations
//! avoid redundant re-estimation.
//!
//! ## Design
//!
//! TypeScript uses a `WeakMap<Message, number>` for the token cache. Rust
//! doesn't have weak references in the same way — instead we keep a parallel
//! `Vec<u32>` that is always the same length as the message list. Index-based
//! lookup is O(1) and trivially correct since add/set/clear keep both vectors
//! in sync.

use tron_core::messages::Message;

use crate::token_estimator::estimate_message_tokens;

/// Configuration for creating a [`MessageStore`].
#[derive(Clone, Debug, Default)]
pub struct MessageStoreConfig {
    /// Initial messages to populate the store.
    pub initial_messages: Option<Vec<Message>>,
}

/// In-memory message store with per-message token caching.
///
/// Provides the conversation message list used by the context manager.
/// Token estimates are computed and cached on insertion so that repeated
/// calls to [`MessageStore::get_tokens`] are cheap.
#[derive(Clone, Debug)]
pub struct MessageStore {
    messages: Vec<Message>,
    token_cache: Vec<u32>,
}

impl MessageStore {
    /// Create a new empty message store.
    #[must_use]
    pub fn new() -> Self {
        Self {
            messages: Vec::new(),
            token_cache: Vec::new(),
        }
    }

    /// Create a message store with an initial configuration.
    #[must_use]
    pub fn with_config(config: MessageStoreConfig) -> Self {
        let mut store = Self::new();
        if let Some(messages) = config.initial_messages {
            store.set(messages);
        }
        store
    }

    /// Add a message to the store.
    ///
    /// The token estimate is computed and cached immediately.
    pub fn add(&mut self, message: Message) {
        let tokens = estimate_message_tokens(&message);
        self.messages.push(message);
        self.token_cache.push(tokens);
    }

    /// Replace all messages in the store.
    ///
    /// Token cache is rebuilt for the new messages.
    pub fn set(&mut self, messages: Vec<Message>) {
        self.token_cache = messages.iter().map(estimate_message_tokens).collect();
        self.messages = messages;
    }

    /// Get a clone of all messages.
    #[must_use]
    pub fn get(&self) -> Vec<Message> {
        self.messages.clone()
    }

    /// Get a reference to the internal message slice (no allocation).
    #[must_use]
    pub fn as_slice(&self) -> &[Message] {
        &self.messages
    }

    /// Clear all messages from the store.
    pub fn clear(&mut self) {
        self.messages.clear();
        self.token_cache.clear();
    }

    /// Get total token count for all messages.
    ///
    /// Uses cached values — O(n) addition with no re-estimation.
    #[must_use]
    pub fn get_tokens(&self) -> u32 {
        self.token_cache.iter().copied().sum()
    }

    /// Get the cached token count for a message at the given index.
    ///
    /// Returns `None` if the index is out of bounds.
    #[must_use]
    pub fn get_cached_tokens(&self, index: usize) -> Option<u32> {
        self.token_cache.get(index).copied()
    }

    /// Get current message count.
    #[must_use]
    pub fn len(&self) -> usize {
        self.messages.len()
    }

    /// Returns `true` if the store contains no messages.
    #[must_use]
    pub fn is_empty(&self) -> bool {
        self.messages.is_empty()
    }
}

impl Default for MessageStore {
    fn default() -> Self {
        Self::new()
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use tron_core::content::AssistantContent;
    use tron_core::messages::Message;

    // -- Construction --

    #[test]
    fn new_store_is_empty() {
        let store = MessageStore::new();
        assert!(store.is_empty());
        assert_eq!(store.len(), 0);
        assert!(store.get().is_empty());
        assert_eq!(store.get_tokens(), 0);
    }

    #[test]
    fn default_store_is_empty() {
        let store = MessageStore::default();
        assert!(store.is_empty());
    }

    #[test]
    fn with_config_no_initial_messages() {
        let store = MessageStore::with_config(MessageStoreConfig::default());
        assert!(store.is_empty());
    }

    #[test]
    fn with_config_initial_messages() {
        let messages = vec![Message::user("Hello"), Message::assistant("Hi there")];
        let store = MessageStore::with_config(MessageStoreConfig {
            initial_messages: Some(messages),
        });
        assert_eq!(store.len(), 2);
        assert!(store.get_tokens() > 0);
    }

    // -- add --

    #[test]
    fn add_single_message() {
        let mut store = MessageStore::new();
        let msg = Message::user("Hello, world!");
        store.add(msg.clone());

        assert_eq!(store.len(), 1);
        assert_eq!(store.get()[0], msg);
    }

    #[test]
    fn add_multiple_messages_preserves_order() {
        let mut store = MessageStore::new();
        let msg1 = Message::user("First");
        let msg2 = Message::assistant("Second");
        let msg3 = Message::user("Third");

        store.add(msg1.clone());
        store.add(msg2.clone());
        store.add(msg3.clone());

        let messages = store.get();
        assert_eq!(messages.len(), 3);
        assert_eq!(messages[0], msg1);
        assert_eq!(messages[1], msg2);
        assert_eq!(messages[2], msg3);
    }

    #[test]
    fn add_caches_token_estimate() {
        let mut store = MessageStore::new();
        let msg = Message::user("This is a test message with some content");
        store.add(msg);

        let cached = store.get_cached_tokens(0);
        assert!(cached.is_some());
        assert!(cached.unwrap() > 0);
    }

    // -- set --

    #[test]
    fn set_replaces_all_messages() {
        let mut store = MessageStore::new();
        store.add(Message::user("Original"));

        let new_messages = vec![
            Message::user("New message 1"),
            Message::assistant("New message 2"),
        ];
        store.set(new_messages);

        assert_eq!(store.len(), 2);
        assert!(store.get()[0].is_user());
        assert!(store.get()[1].is_assistant());
    }

    #[test]
    fn set_rebuilds_token_cache() {
        let mut store = MessageStore::new();
        let messages = vec![
            Message::user("First message"),
            Message::assistant("Second message"),
        ];
        store.set(messages);

        assert!(store.get_cached_tokens(0).unwrap() > 0);
        assert!(store.get_cached_tokens(1).unwrap() > 0);
    }

    #[test]
    fn set_with_empty_vec_clears_store() {
        let mut store = MessageStore::new();
        store.add(Message::user("Something"));
        store.set(Vec::new());

        assert!(store.is_empty());
        assert_eq!(store.get_tokens(), 0);
    }

    // -- get --

    #[test]
    fn get_returns_clone_not_reference() {
        let mut store = MessageStore::new();
        store.add(Message::user("Test"));

        let messages1 = store.get();
        let messages2 = store.get();
        // Both are equal in content
        assert_eq!(messages1, messages2);
    }

    #[test]
    fn as_slice_returns_reference() {
        let mut store = MessageStore::new();
        store.add(Message::user("Test"));
        assert_eq!(store.as_slice().len(), 1);
    }

    // -- clear --

    #[test]
    fn clear_removes_all_messages() {
        let mut store = MessageStore::new();
        store.add(Message::user("Message 1"));
        store.add(Message::user("Message 2"));

        store.clear();

        assert!(store.is_empty());
        assert_eq!(store.len(), 0);
        assert_eq!(store.get_tokens(), 0);
    }

    // -- get_tokens --

    #[test]
    fn get_tokens_empty_store_returns_zero() {
        let store = MessageStore::new();
        assert_eq!(store.get_tokens(), 0);
    }

    #[test]
    fn get_tokens_returns_sum_of_all_message_tokens() {
        let mut store = MessageStore::new();
        store.add(Message::user("First message"));
        store.add(Message::assistant("Second message"));

        let total = store.get_tokens();
        assert!(total > 0);
    }

    #[test]
    fn get_tokens_is_consistent() {
        let mut store = MessageStore::new();
        store.add(Message::user("Test message"));

        let tokens1 = store.get_tokens();
        let tokens2 = store.get_tokens();
        assert_eq!(tokens1, tokens2);
    }

    #[test]
    fn get_tokens_scales_with_content() {
        let mut small = MessageStore::new();
        small.add(Message::user("Hi"));

        let mut large = MessageStore::new();
        large.add(Message::user("This is a much longer message with substantially more content"));

        assert!(large.get_tokens() > small.get_tokens());
    }

    // -- get_cached_tokens --

    #[test]
    fn get_cached_tokens_out_of_bounds_returns_none() {
        let store = MessageStore::new();
        assert!(store.get_cached_tokens(0).is_none());
        assert!(store.get_cached_tokens(999).is_none());
    }

    #[test]
    fn get_cached_tokens_returns_correct_value() {
        let mut store = MessageStore::new();
        store.add(Message::user("Test"));
        let cached = store.get_cached_tokens(0);
        assert!(cached.is_some());
        assert!(cached.unwrap() > 0);
    }

    // -- len / is_empty --

    #[test]
    fn len_tracks_add_and_clear() {
        let mut store = MessageStore::new();
        assert_eq!(store.len(), 0);
        assert!(store.is_empty());

        store.add(Message::user("One"));
        assert_eq!(store.len(), 1);
        assert!(!store.is_empty());

        store.add(Message::user("Two"));
        assert_eq!(store.len(), 2);

        store.clear();
        assert_eq!(store.len(), 0);
        assert!(store.is_empty());
    }

    // -- token cache correctness --

    #[test]
    fn token_cache_stays_in_sync_after_set() {
        let mut store = MessageStore::new();
        store.add(Message::user("Original"));
        store.add(Message::user("Also original"));

        // Replace with different messages
        let new_msgs = vec![Message::user("Replacement")];
        store.set(new_msgs);

        assert_eq!(store.len(), 1);
        assert!(store.get_cached_tokens(0).is_some());
        assert!(store.get_cached_tokens(1).is_none());
    }

    #[test]
    fn assistant_message_with_tool_use_has_nonzero_tokens() {
        use serde_json::Map;
        let mut store = MessageStore::new();
        store.add(Message::Assistant {
            content: vec![AssistantContent::ToolUse {
                id: "tc-1".into(),
                name: "bash".into(),
                arguments: Map::new(),
                thought_signature: None,
            }],
            usage: None,
            cost: None,
            stop_reason: None,
            thinking: None,
        });

        assert!(store.get_tokens() > 0);
    }
}
