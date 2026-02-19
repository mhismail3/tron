//! `OpenAI` LLM provider implementation.
//!
//! Follows the composition pattern shared across all providers:
//! `provider` (entry point), `message_converter`, `stream_handler`, `types`.

pub mod message_converter;
pub mod provider;
pub mod stream_handler;
pub mod types;

pub use provider::OpenAIProvider;
pub use types::{OpenAIAuth, OpenAIConfig};
