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
//! | [`cache_pruning`]      | Remove stale historical tool-result cache markers on a cold request before current boundaries are applied |
//! | [`message_sanitizer`]  | Drop empty assistant messages and normalise internal tool-result ordering before provider conversion |
//! | [`types`]              | [`AnthropicAuth`] (ApiKey / Oauth / ClaudeAgentSdk), [`AnthropicConfig`], [`AnthropicProviderSettings`] |
//!
//! ## Invariants
//!
//! - Tron emits at most three ordered cache breakpoints: the final fixed tool
//!   and final stable system block use `1h`, and the last durable conversation
//!   block uses `5m`. Request-local reference context follows all three without
//!   a marker. Cold-cache pruning still removes old tool-result bulk before
//!   those boundaries are rebuilt.
//! - Provider-wire tool blocks use Anthropic's canonical `tool_use` and
//!   `tool_result` shape; internal messages keep Tron tool-invocation names.
//! - v1beta (ApiKey) rejects unknown fields; v1internal (OAuth / SDK)
//!   tolerates them. Request builders branch on auth type.
//! - The picker orders Claude Fable 5, Opus 4.8, and Sonnet 5 ahead of older
//!   generations while retaining dated/short aliases only for resolution.
//!   Fable always uses adaptive thinking; Sonnet 5 defaults to adaptive
//!   thinking but honors an explicit disable request.

pub mod cache_pruning;
pub mod message_converter;
pub mod message_sanitizer;
pub mod provider;
pub mod stream_handler;
pub mod types;
