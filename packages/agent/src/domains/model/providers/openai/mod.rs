//! # providers/openai — OpenAI / GPT provider
//!
//! Responses API client for OpenAI models. OAuth credentials use the
//! ChatGPT/Codex backend; API keys use the OpenAI Platform `/v1/responses`
//! endpoint. The same model ID can therefore have different metadata depending
//! on the active auth path, and the registry stores those profiles separately.
//!
//! ## Submodules
//!
//! | Module                | Content |
//! |-----------------------|---------|
//! | [`provider`]          | [`OpenAIProvider`] — implements the shared `Provider` trait ([`crate::domains::model::providers::shared::provider`]); stream, retry, tool invocation parsing |
//! | [`message_converter`] | `Vec<Message>` → Responses `input` items and direct typed-tool schema conversion |
//! | [`stream_handler`]    | OpenAI SSE → `StreamEvent` ([`crate::shared::protocol::events`]); handles output deltas, tool invocations, and terminal events |
//! | [`types`]             | [`OpenAIAuth`], [`OpenAIConfig`], [`ApiEndpoint`], endpoint-aware model profiles, and Responses wire DTOs split by owned surface |
//!
//! ## Invariants
//!
//! - API-key credentials never route to `chatgpt.com/backend-api/codex`; they
//!   use Platform metadata and `/v1/responses`. OAuth credentials never use
//!   Platform metadata because ChatGPT subscription tokens are scoped to the
//!   Codex backend.
//! - Context-window, max-output, reasoning, and verbosity defaults are selected
//!   from the active auth-path profile. The shared model-only registry is only
//!   a conservative default for call sites without credential context.
//! - GPT-5.6 Sol, Terra, and Luna expose the provider's common 1.05M Platform
//!   context, 128K output ceiling, and `max` reasoning effort. The ChatGPT
//!   Codex path retains a conservative 272K default while advertising the
//!   larger opt-in ceiling.
//! - `model.list` surfaces streaming-capable models for the active auth path.
//!   Provider-retired OpenAI models stay visible with replacement metadata, but
//!   `model.switch` rejects them so new runs do not select unavailable IDs.
//!   Non-streaming Pro/preview records stay hidden and are rejected before a
//!   request is sent.
//! - Primitive context is compiled into the Responses `instructions` field.
//!   The `input` array carries conversation items and tool results only;
//!   it must not receive synthetic developer/user messages for the agent seed,
//!   environment, or tool-use guidance.
//! - Tool invocations arrive as streaming deltas over multiple SSE events.
//!   [`stream_handler`] accumulates them until the closing `finish_reason`
//!   before emitting a single `StreamEvent::ToolInvocationDraft` — the orchestrator
//!   never sees a partial tool invocation.
//! - Responses terminal events are exhaustive at the provider boundary:
//!   `response.completed` and `response.incomplete` finalize canonical output,
//!   while `response.failed` and top-level `error` preserve provider code/type
//!   and message as typed provider failures across both flat and nested error
//!   envelopes. A trailing terminal frame is processed even when the connection
//!   closes without a final newline.
//! - The converter normalises tool results into Responses input items so the
//!   provider can resume multi-turn tool loops without leaking provider-specific
//!   payload details into the runtime.

pub mod message_converter;
pub mod provider;
pub mod stream_handler;
pub mod types;
