//! Token state manager for session-level tracking.
//!
//! [`TokenStateManager`] maintains the complete token state for a session:
//! accumulated totals, context window tracking, and full audit history.

use tron_core::messages::ProviderType;

use super::normalization::normalize_tokens;
use super::types::{AccumulatedTokens, TokenMeta, TokenRecord, TokenSource, TokenState};

/// Session-level token state manager.
///
/// Records per-turn usage, maintains accumulated totals, and tracks
/// context window utilization. State can be persisted and restored
/// for session resumption.
pub struct TokenStateManager {
    state: TokenState,
}

/// Configuration for [`TokenStateManager`].
#[derive(Clone, Copy)]
pub struct TokenStateManagerConfig {
    /// Maximum context window size for the model (default: 200,000).
    pub context_limit: u64,
}

impl Default for TokenStateManagerConfig {
    fn default() -> Self {
        Self {
            context_limit: 200_000,
        }
    }
}

impl TokenStateManager {
    /// Create a new state manager with the given configuration.
    #[must_use]
    pub fn new(config: TokenStateManagerConfig) -> Self {
        Self {
            state: TokenState::new(config.context_limit),
        }
    }

    /// Record a turn's token usage.
    ///
    /// Normalizes the source data, updates accumulated totals and context
    /// window tracking, and returns the immutable [`TokenRecord`].
    pub fn record_turn(&mut self, source: TokenSource, meta: TokenMeta, cost: f64) -> TokenRecord {
        let previous_baseline = self.state.context_window.current_size;
        let record = normalize_tokens(source, previous_baseline, meta);

        // Update accumulated totals
        let acc = &mut self.state.accumulated;
        acc.input_tokens += record.source.raw_input_tokens;
        acc.output_tokens += record.source.raw_output_tokens;
        acc.cache_read_tokens += record.source.raw_cache_read_tokens;
        acc.cache_creation_tokens += record.source.raw_cache_creation_tokens;
        acc.cache_creation_5m_tokens += record.source.raw_cache_creation_5m_tokens;
        acc.cache_creation_1h_tokens += record.source.raw_cache_creation_1h_tokens;
        acc.cost += cost;

        // Update context window
        self.state.context_window.current_size = record.computed.context_window_tokens;
        self.state.context_window.recalculate();

        // Store in history
        self.state.current = Some(record.clone());
        self.state.history.push(record.clone());

        record
    }

    /// Get the current token state (read-only).
    #[must_use]
    pub fn state(&self) -> &TokenState {
        &self.state
    }

    /// Handle a provider change (resets context window baseline).
    ///
    /// Preserves accumulated tokens and history but resets the context
    /// window current size to 0 so the next turn starts fresh deltas.
    pub fn on_provider_change(&mut self, _new_provider: ProviderType) {
        self.state.context_window.current_size = 0;
        self.state.context_window.recalculate();
    }

    /// Update the context window limit (e.g., after model switch).
    pub fn set_context_limit(&mut self, limit: u64) {
        self.state.context_window.max_size = limit;
        self.state.context_window.recalculate();
    }

    /// Restore state from a previous session.
    ///
    /// Used for session resumption. Restores full history and accumulated
    /// totals, with the context window derived from the latest record.
    pub fn restore_state(
        &mut self,
        history: Vec<TokenRecord>,
        accumulated: Option<AccumulatedTokens>,
    ) {
        if let Some(last) = history.last() {
            self.state.current = Some(last.clone());
            self.state.context_window.current_size = last.computed.context_window_tokens;
            self.state.context_window.recalculate();
        }

        if let Some(acc) = accumulated {
            self.state.accumulated = acc;
        }

        self.state.history = history;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    fn make_manager() -> TokenStateManager {
        TokenStateManager::new(TokenStateManagerConfig {
            context_limit: 200_000,
        })
    }

    fn anthropic_source(input: u64, output: u64, cache_read: u64) -> TokenSource {
        TokenSource {
            provider: ProviderType::Anthropic,
            timestamp: "2024-01-15T12:00:00Z".to_string(),
            raw_input_tokens: input,
            raw_output_tokens: output,
            raw_cache_read_tokens: cache_read,
            raw_cache_creation_tokens: 0,
            raw_cache_creation_5m_tokens: 0,
            raw_cache_creation_1h_tokens: 0,
        }
    }

    fn make_meta(turn: u64) -> TokenMeta {
        TokenMeta {
            turn,
            session_id: "sess_test".to_string(),
            extracted_at: "2024-01-15T12:00:00Z".to_string(),
            normalized_at: String::new(),
        }
    }

    #[test]
    fn initial_state_is_empty() {
        let mgr = make_manager();
        let state = mgr.state();
        assert!(state.current.is_none());
        assert!(state.history.is_empty());
        assert_eq!(state.accumulated.input_tokens, 0);
        assert_eq!(state.context_window.max_size, 200_000);
        assert_eq!(state.context_window.current_size, 0);
    }

    #[test]
    fn record_first_turn() {
        let mut mgr = make_manager();
        let source = anthropic_source(604, 100, 8266);
        let record = mgr.record_turn(source, make_meta(1), 0.05);

        assert_eq!(record.computed.context_window_tokens, 604 + 8266);
        // Anthropic: new_input_tokens = raw_input_tokens only (non-cached)
        assert_eq!(record.computed.new_input_tokens, 604);
        assert_eq!(record.computed.previous_context_baseline, 0);

        let state = mgr.state();
        assert!(state.current.is_some());
        assert_eq!(state.history.len(), 1);
        assert_eq!(state.accumulated.input_tokens, 604);
        assert_eq!(state.accumulated.output_tokens, 100);
        assert_eq!(state.accumulated.cache_read_tokens, 8266);
        assert!((state.accumulated.cost - 0.05).abs() < f64::EPSILON);
        assert_eq!(state.context_window.current_size, 8870);
    }

    #[test]
    fn record_second_turn_delta() {
        let mut mgr = make_manager();
        let _ = mgr.record_turn(anthropic_source(604, 100, 8266), make_meta(1), 0.05);

        let source2 = anthropic_source(700, 150, 8266);
        let record2 = mgr.record_turn(source2, make_meta(2), 0.03);

        assert_eq!(record2.computed.context_window_tokens, 700 + 8266);
        assert_eq!(record2.computed.previous_context_baseline, 8870);
        // Anthropic: new_input_tokens = raw_input_tokens only (non-cached)
        assert_eq!(record2.computed.new_input_tokens, 700);

        let state = mgr.state();
        assert_eq!(state.history.len(), 2);
        assert_eq!(state.accumulated.input_tokens, 604 + 700);
        assert_eq!(state.accumulated.output_tokens, 100 + 150);
        assert!((state.accumulated.cost - 0.08).abs() < f64::EPSILON);
    }

    #[test]
    fn provider_change_resets_baseline() {
        let mut mgr = make_manager();
        let _ = mgr.record_turn(anthropic_source(604, 100, 8266), make_meta(1), 0.05);
        assert_eq!(mgr.state().context_window.current_size, 8870);

        mgr.on_provider_change(ProviderType::Google);
        assert_eq!(mgr.state().context_window.current_size, 0);

        // Accumulated totals preserved
        assert_eq!(mgr.state().accumulated.input_tokens, 604);
        assert_eq!(mgr.state().history.len(), 1);
    }

    #[test]
    fn set_context_limit() {
        let mut mgr = make_manager();
        let _ = mgr.record_turn(anthropic_source(50_000, 100, 50_000), make_meta(1), 0.10);

        mgr.set_context_limit(100_000);
        let state = mgr.state();
        assert_eq!(state.context_window.max_size, 100_000);
        assert_eq!(state.context_window.current_size, 100_000);
        assert_eq!(state.context_window.tokens_remaining, 0);
        assert!((state.context_window.percent_used - 100.0).abs() < 0.01);
    }

    #[test]
    fn restore_state() {
        let mut mgr = make_manager();
        let record1 = mgr.record_turn(anthropic_source(100, 50, 0), make_meta(1), 0.01);
        let record2 = mgr.record_turn(anthropic_source(200, 75, 0), make_meta(2), 0.02);

        let saved_history = mgr.state().history.clone();
        let saved_accumulated = mgr.state().accumulated.clone();

        // Create new manager and restore
        let mut mgr2 = make_manager();
        mgr2.restore_state(saved_history, Some(saved_accumulated));

        let state = mgr2.state();
        assert_eq!(state.history.len(), 2);
        assert_eq!(state.accumulated.input_tokens, 300);
        assert_eq!(state.accumulated.output_tokens, 125);
        assert!((state.accumulated.cost - 0.03).abs() < f64::EPSILON);
        assert_eq!(
            state.context_window.current_size,
            record2.computed.context_window_tokens
        );
        assert!(state.current.is_some());

        // First record should still be accessible
        assert_eq!(
            state.history[0].source.raw_input_tokens,
            record1.source.raw_input_tokens
        );
    }

    #[test]
    fn restore_empty_history() {
        let mut mgr = make_manager();
        mgr.restore_state(Vec::new(), None);
        assert!(mgr.state().current.is_none());
        assert!(mgr.state().history.is_empty());
    }

    #[test]
    fn default_config() {
        let config = TokenStateManagerConfig::default();
        assert_eq!(config.context_limit, 200_000);
    }

    #[test]
    fn context_window_percentage_tracks() {
        let mut mgr = make_manager();
        let _ = mgr.record_turn(anthropic_source(50_000, 100, 0), make_meta(1), 0.0);
        assert!((mgr.state().context_window.percent_used - 25.0).abs() < 0.01);

        let _ = mgr.record_turn(anthropic_source(100_000, 100, 0), make_meta(2), 0.0);
        assert!((mgr.state().context_window.percent_used - 50.0).abs() < 0.01);
    }

    #[test]
    fn cache_creation_accumulated() {
        let mut mgr = make_manager();
        let mut source = anthropic_source(100, 50, 0);
        source.raw_cache_creation_tokens = 500;
        source.raw_cache_creation_5m_tokens = 300;
        source.raw_cache_creation_1h_tokens = 200;
        let _ = mgr.record_turn(source, make_meta(1), 0.01);

        assert_eq!(mgr.state().accumulated.cache_creation_tokens, 500);
        assert_eq!(mgr.state().accumulated.cache_creation_5m_tokens, 300);
        assert_eq!(mgr.state().accumulated.cache_creation_1h_tokens, 200);
    }
}
