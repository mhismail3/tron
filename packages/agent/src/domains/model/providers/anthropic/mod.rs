//! # providers/anthropic — Anthropic / Claude provider
//!
//! Messages-API client with prompt-cache support and interleaved
//! thinking. Two auth paths: API key (v1beta public surface, strict
//! field validation) and Claude Console OAuth / Claude Agent SDK
//! credentials (v1internal surface, more lenient).
//!
//! ## Submodules
//!
//! | Module                 | Content |
//! |------------------------|---------|
//! | [`provider`]           | [`AnthropicProvider`] — implements the shared `Provider` trait ([`crate::domains::model::providers::shared::provider`]); stream orchestration, retry, caching |
//! | [`message_converter`]  | `Vec<Message>` → `messages`+`system` blocks; Anthropic `tool_use` / `tool_result` provider blocks, thinking blocks, content-block ordering |
//! | [`stream_handler`]     | Anthropic SSE (`message_start`, `content_block_*`, `message_delta`, `message_stop`) → `StreamEvent` ([`crate::shared::protocol::events`]) |
//! | [`cache_pruning`]      | Remove the oldest `cache_control` marker(s) when the 4-breakpoint cap is hit; preserves the system prompt marker |
//! | [`message_sanitizer`]  | Drop empty assistant messages and normalise internal capability-result ordering before provider conversion |
//! | [`types`]              | [`AnthropicAuth`] (ApiKey / Oauth / ClaudeAgentSdk), [`AnthropicConfig`], [`AnthropicProviderSettings`] |
//!
//! ## Invariants
//!
//! - Cache breakpoints are capped at 4 per request
//!   (Anthropic API limit); [`cache_pruning`] strips the oldest when the
//!   cap would be exceeded. The system-prompt marker is permanent.
//! - Provider-wire tool blocks use Anthropic's canonical `tool_use` and
//!   `tool_result` shape; internal messages keep Tron capability-invocation names.
//! - v1beta (ApiKey) rejects unknown fields; v1internal (OAuth / SDK)
//!   tolerates them. Request builders branch on auth type.

pub mod cache_pruning;
pub mod message_converter;
pub mod message_sanitizer;
pub mod provider;
pub mod stream_handler;
pub mod types;
