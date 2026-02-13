//! # tron-llm-anthropic
//!
//! Anthropic/Claude LLM provider implementation.
//!
//! Implements the `Provider` trait from `tron-llm` for the Anthropic Messages API:
//! - Message converter (Context -> Anthropic API format)
//! - Stream handler (parse SSE: `message_start`, `content_block_delta`, `message_stop`)
//! - OAuth + API key auth, cache pruning, extended thinking
//! - System prompt prefix for OAuth connections

#![deny(unsafe_code)]
