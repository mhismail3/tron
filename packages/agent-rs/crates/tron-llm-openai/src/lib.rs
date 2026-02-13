//! # tron-llm-openai
//!
//! `OpenAI` LLM provider implementation.
//!
//! Implements the [`Provider`](tron_llm::Provider) trait from `tron-llm` for the
//! `OpenAI` Responses API (Codex endpoint):
//!
//! - [`types`] — Configuration, model registry, and SSE event structures
//! - [`message_converter`] — Convert Context messages to Responses API format
//! - [`stream_handler`] — SSE event state machine → unified [`StreamEvent`](tron_core::events::StreamEvent)s
//! - [`provider`] — `OpenAIProvider` implementing the `Provider` trait
//!
//! # Authentication
//!
//! OAuth only — the Codex endpoint requires OAuth Bearer tokens.
//!
//! # Reasoning
//!
//! Supports reasoning effort levels (low/medium/high/xhigh/max) via the
//! `reasoning` field with `summary: "detailed"` to surface thinking as
//! reasoning summary text deltas.

#![deny(unsafe_code)]

pub mod message_converter;
pub mod provider;
pub mod stream_handler;
pub mod types;

pub use provider::OpenAIProvider;
pub use types::{OpenAIAuth, OpenAIConfig};
