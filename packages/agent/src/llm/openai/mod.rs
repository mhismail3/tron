//! # llm/openai — OpenAI / GPT provider
//!
//! Responses API client for OpenAI models. OAuth credentials use the
//! ChatGPT/Codex backend; API keys use the OpenAI Platform `/v1/responses`
//! endpoint. The same model ID can therefore have different metadata depending
//! on the active auth path.
//!
//! ## Submodules
//!
//! | Module                | Content |
//! |-----------------------|---------|
//! | [`provider`]          | [`OpenAIProvider`] — implements the shared `Provider` trait ([`crate::llm::provider`]); stream, retry, tool call parsing |
//! | [`message_converter`] | `Vec<Message>` → Responses `input` array with role mapping and tool-result normalisation |
//! | [`stream_handler`]    | OpenAI SSE → `StreamEvent` ([`crate::core::events`]); handles output deltas, tool calls, and terminal events |
//! | [`types`]             | [`OpenAIAuth`], [`OpenAIConfig`], [`ApiEndpoint`], and endpoint-aware model profiles |
//!
//! ## Re-exports
//!
//! - [`OpenAIProvider`] — the OpenAI provider payload behind the shared
//!   provider enum
//! - [`ApiEndpoint`] — the resolved Responses endpoint (`codex` or `platform`)
//!
//! ## Invariants
//!
//! - API-key credentials never route to `chatgpt.com/backend-api/codex`; they
//!   use Platform metadata and `/v1/responses`. OAuth credentials never use
//!   Platform metadata because ChatGPT subscription tokens are scoped to the
//!   Codex backend.
//! - Context-window, max-output, reasoning, and verbosity defaults are selected
//!   from the active auth-path profile. The shared model-only registry is only
//!   a conservative fallback for call sites without credential context.
//! - Tool calls arrive as streaming deltas over multiple SSE events.
//!   [`stream_handler`] accumulates them until the closing `finish_reason`
//!   before emitting a single `StreamEvent::ToolCall` — the orchestrator
//!   never sees a partial tool call.
//! - The converter normalises tool results into Responses input items so the
//!   provider can resume multi-turn tool loops without leaking provider-specific
//!   payload details into the runtime.

pub mod message_converter;
pub mod provider;
pub mod stream_handler;
pub mod types;

pub use provider::OpenAIProvider;
pub use types::{ApiEndpoint, OpenAIAuth, OpenAIConfig};
