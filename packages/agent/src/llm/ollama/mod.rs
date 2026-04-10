//! Ollama provider — local LLM inference via Ollama's OpenAI-compatible API.
//!
//! Ollama runs locally and requires no authentication. This provider follows
//! the same OpenAI chat completions format as the Kimi provider.
//!
//! ## Submodules
//!
//! - [`types`] — Config, model registry, model info
//! - [`message_converter`] — Tron messages → OpenAI chat completions format
//! - [`stream_handler`] — SSE chunk parsing → unified [`StreamEvent`]s
//! - [`provider`] — [`OllamaProvider`] implementing the [`Provider`] trait

pub mod message_converter;
pub mod provider;
pub mod stream_handler;
pub mod types;
