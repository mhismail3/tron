//! Anthropic/Claude LLM provider implementation.
//!
//! Follows the composition pattern shared across all providers:
//! `provider` (entry point) uses `message_converter` (context → API format),
//! `stream_handler` (SSE → `StreamEvent`), and `types` (config/auth).
//! Also includes `cache_pruning` and `message_sanitizer` (Anthropic-specific).

pub mod cache_pruning;
pub mod message_converter;
pub mod message_sanitizer;
pub mod provider;
pub mod stream_handler;
pub mod types;

pub use provider::AnthropicProvider;
pub use types::{AnthropicAuth, AnthropicConfig, AnthropicProviderSettings};
