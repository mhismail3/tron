//! Kimi (Moonshot AI) LLM provider implementation.
//!
//! Uses Kimi's `OpenAI` chat completions-compatible endpoint (`https://api.moonshot.ai/v1`).
//! Custom message converter and stream handler for the chat completions wire format.

pub mod message_converter;
pub mod provider;
pub mod stream_handler;
pub mod types;
