//! # providers/google — Google / Gemini provider
//!
//! Generative-Language API client for Gemini models. Follows the
//! composition pattern every provider shares: a `provider` entry point
//! that orchestrates a `message_converter` (internal context → API
//! request) and a `stream_handler` (SSE → `StreamEvent`), with `types`
//! holding the auth + config structs.
//!
//! ## Submodules
//!
//! | Module                | Content |
//! |-----------------------|---------|
//! | [`provider`]          | [`GoogleProvider`] — implements the shared `Provider` trait ([`crate::domains::model::providers::provider`]); stream orchestration, retry, and tool translation |
//! | [`message_converter`] | `Vec<Message>` → Gemini `contents` array; handles capability invocations, capability results, and multimodal parts |
//! | [`stream_handler`]    | Gemini SSE `v1beta/{model}:streamGenerateContent` → `StreamEvent` sequence ([`crate::shared::events`]) |
//! | [`types`]             | [`GoogleAuth`] (API key), [`GoogleConfig`] (model + generation parameters) |
//!
//! ## Re-exports
//!
//! - [`GoogleProvider`] — the Google provider payload behind the shared
//!   provider enum
//! - [`GoogleAuth`], [`GoogleConfig`] — consumed by [`crate::domains::model::providers::auth`]
//!
//! ## Invariants
//!
//! - The v1beta API is strict about unknown fields; the converter
//!   serialises only the documented schema. Adding a request feature
//!   requires editing both converter and the Gemini API docs reference.
//! - Streaming errors map to `ProviderError`
//!   ([`crate::domains::model::providers::provider`]) before reaching the orchestrator;
//!   provider-specific wire errors never leak past [`stream_handler`].

pub mod message_converter;
pub mod provider;
pub mod stream_handler;
pub mod types;

pub use provider::GoogleProvider;
pub use types::{GoogleAuth, GoogleConfig};
