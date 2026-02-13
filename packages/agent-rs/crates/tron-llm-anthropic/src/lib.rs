//! # tron-llm-anthropic
//!
//! Anthropic/Claude LLM provider implementation.
//!
//! Implements the [`Provider`](tron_llm::Provider) trait from `tron-llm` for the
//! Anthropic Messages API:
//!
//! - [`types`] — Configuration, model registry, and SSE event structures
//! - [`message_converter`] — Convert Context messages to Anthropic API format
//! - [`stream_handler`] — SSE event state machine → unified [`StreamEvent`](tron_core::events::StreamEvent)s
//! - [`cache_pruning`] — Cache cold detection and tool result pruning for re-caching
//! - [`provider`] — `AnthropicProvider` implementing the `Provider` trait
//!
//! # Authentication
//!
//! Supports API key (`x-api-key` header) and OAuth (`Authorization: Bearer`).
//! OAuth connections require a system prompt prefix and use multi-block system
//! prompts with cache breakpoints for efficient prompt caching.
//!
//! # Prompt Caching
//!
//! Four cache breakpoints (OAuth only):
//! 1. Last tool definition → 1h TTL
//! 2. Last stable system prompt block → 1h TTL
//! 3. Last volatile system prompt block → 5m TTL (default ephemeral)
//! 4. Last user message content block → 5m TTL (default ephemeral)

#![deny(unsafe_code)]

pub mod cache_pruning;
pub mod message_converter;
pub mod provider;
pub mod stream_handler;
pub mod types;

pub use provider::AnthropicProvider;
pub use types::{AnthropicAuth, AnthropicConfig, AnthropicProviderSettings};
