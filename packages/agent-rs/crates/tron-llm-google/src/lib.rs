//! # tron-llm-google
//!
//! Google/Gemini LLM provider implementation.
//!
//! Implements the [`Provider`](tron_llm::provider::Provider) trait for the Gemini API:
//! - Message converter (Context → Gemini format with `thoughtSignature`)
//! - Stream handler (SSE parsing, thinking/text/tool call events)
//! - Provider (OAuth with Cloud Code Assist + Antigravity endpoints, API key fallback)
//! - Safety filter handling

#![deny(unsafe_code)]

pub mod message_converter;
pub mod provider;
pub mod stream_handler;
pub mod types;

pub use provider::GoogleProvider;
pub use types::{GoogleAuth, GoogleConfig};
