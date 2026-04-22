//! # llm/openai — OpenAI / GPT provider
//!
//! Chat Completions-compatible client. Also serves as the base for
//! providers that speak the OpenAI wire format (MiniMax, Kimi, Ollama)
//! — those modules compose in the shared converter and stream handler.
//!
//! ## Submodules
//!
//! | Module                | Content |
//! |-----------------------|---------|
//! | [`provider`]          | [`OpenAIProvider`] — implements the shared `Provider` trait ([`crate::llm::provider`]); stream, retry, tool call parsing |
//! | [`message_converter`] | `Vec<Message>` → `{ role, content, tool_calls? }` array with role mapping and tool-result normalisation |
//! | [`stream_handler`]    | OpenAI SSE → `StreamEvent` ([`crate::core::events`]); handles `delta`, `tool_calls` deltas, and `[DONE]` sentinel |
//! | [`types`]             | [`OpenAIAuth`], [`OpenAIConfig`], [`ApiEndpoint`] (overridable for OpenAI-compatible providers) |
//!
//! ## Re-exports
//!
//! - [`OpenAIProvider`] — the OpenAI provider payload behind the shared
//!   provider enum
//! - [`ApiEndpoint`] — lets compatible providers swap the base URL
//!   while keeping the rest of the plumbing
//!
//! ## Invariants
//!
//! - Tool calls arrive as streaming deltas over multiple SSE events.
//!   [`stream_handler`] accumulates them until the closing `finish_reason`
//!   before emitting a single `StreamEvent::ToolCall` — the orchestrator
//!   never sees a partial tool call.
//! - The converter normalises `tool_result` content blocks into
//!   `role: "tool"` messages; providers that speak OpenAI-compatibly
//!   (see [`crate::llm::minimax`], [`crate::llm::kimi`]) may reuse this
//!   module's helpers as-is.

pub mod message_converter;
pub mod provider;
pub mod stream_handler;
pub mod types;

pub use provider::OpenAIProvider;
pub use types::{ApiEndpoint, OpenAIAuth, OpenAIConfig};
