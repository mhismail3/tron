//! Ollama provider — local LLM inference via Ollama's native `/api/chat` endpoint.
//!
//! Ollama runs locally and requires no authentication. Models: Gemma 4 family
//! (E4B validation, 26B MoE production). Supports thinking, capability invocationing, and vision.
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
//! - [`types`] — Config, model registry, availability checking
//! - [`message_converter`] — Tron messages → Ollama native `/api/chat` format
//! - [`stream_handler`] — NDJSON chunk parsing → unified `StreamEvent`s ([`crate::shared::events`])
//! - [`provider`] — `OllamaProvider` implementing the shared `Provider` trait ([`crate::domains::model::providers::provider`])

pub mod message_converter;
pub mod provider;
pub mod stream_handler;
pub mod types;
