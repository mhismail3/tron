//! # tron-tokens
//!
//! Token counting, normalization, and cost calculation for LLM usage.
//!
//! This crate handles the full per-turn token tracking pipeline:
//!
//! 1. **Extraction** — Pull raw token values from provider API responses
//!    (Anthropic, `OpenAI`, Google each report differently).
//! 2. **Normalization** — Compute context window size (provider-aware)
//!    and per-turn deltas.
//! 3. **Cost calculation** — Model pricing tables with per-TTL cache
//!    awareness.
//! 4. **State management** — Session-level accumulated totals, context
//!    window tracking, and full audit history.
//!
//! # Key Types
//!
//! - [`TokenSource`] — Raw values from provider API response (immutable)
//! - [`TokenRecord`] — Complete per-turn record (source + computed + meta)
//! - [`TokenStateManager`] — Session-level state with history
//! - [`PricingTier`] — Model pricing configuration
//!
//! # Usage
//!
//! ```
//! use tron_tokens::state::{TokenStateManager, TokenStateManagerConfig};
//! use tron_tokens::types::{TokenSource, TokenMeta};
//! use tron_core::messages::ProviderType;
//!
//! let mut mgr = TokenStateManager::new(TokenStateManagerConfig::default());
//!
//! let source = TokenSource {
//!     provider: ProviderType::Anthropic,
//!     timestamp: "2024-01-15T12:00:00Z".to_string(),
//!     raw_input_tokens: 604,
//!     raw_output_tokens: 100,
//!     raw_cache_read_tokens: 8266,
//!     raw_cache_creation_tokens: 0,
//!     raw_cache_creation_5m_tokens: 0,
//!     raw_cache_creation_1h_tokens: 0,
//! };
//!
//! let meta = TokenMeta {
//!     turn: 1,
//!     session_id: "sess_123".to_string(),
//!     extracted_at: "2024-01-15T12:00:00Z".to_string(),
//!     normalized_at: String::new(),
//! };
//!
//! let record = mgr.record_turn(source, meta, 0.05);
//! assert_eq!(record.computed.context_window_tokens, 604 + 8266);
//! ```

#![deny(unsafe_code)]

pub mod errors;
pub mod extraction;
pub mod normalization;
pub mod pricing;
pub mod state;
pub mod types;

pub use errors::{Result, TokenError};
pub use pricing::{calculate_cost, detect_provider, format_cost, format_tokens, get_context_limit, get_pricing_tier};
pub use types::{
    AccumulatedTokens, CalculationMethod, ComputedTokens, ContextWindowState, PricingTier,
    TokenMeta, TokenRecord, TokenSource, TokenState,
};
