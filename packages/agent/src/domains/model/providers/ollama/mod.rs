//! Ollama provider — local LLM inference via Ollama's native `/api/chat` endpoint.
//!
//! Ollama runs locally or at a user-configured endpoint and requires no Tron
//! credential. Installed models are discovered dynamically; `/api/show`
//! evidence controls tools, thinking, vision, audio, and context metadata.
//!
//! # Why native API, not OpenAI-compatible?
//!
//! Ollama's `/v1/chat/completions` endpoint ignores `num_ctx` and reloads the model
//! at 4K context on every request, silently truncating prompts and destroying
//! thinking output. The native `/api/chat` endpoint properly supports `options.num_ctx`.
//! See `provider.rs` module docs for the full rationale.
//!
//! # Setup
//!
//! ```bash
//! brew install ollama && brew services start ollama
//! ollama pull gemma4:e4b   # ~9.6 GB download
//! ```
//!
//! See `docs/local-llm-setup.md` for detailed instructions.
//!
//! ## Submodules
//!
//! - [`types`] — Config, built-in Gemma metadata, and the live metadata cache
//! - [`discovery`] — Configured-endpoint `/api/tags` and `/api/show` discovery
//! - [`message_converter`] — Tron messages → Ollama native `/api/chat` format
//! - [`stream_handler`] — NDJSON chunk parsing → unified `StreamEvent`s ([`crate::shared::protocol::events`])
//! - [`provider`] — `OllamaProvider` implementing the shared `Provider` trait ([`crate::domains::model::providers::shared::provider`])

pub mod discovery;
pub mod message_converter;
pub mod provider;
pub mod stream_handler;
pub mod types;

#[cfg(test)]
mod live_tests;
