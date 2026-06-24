//! `MiniMax` LLM provider implementation.
//!
//! Uses `MiniMax`'s Anthropic-compatible endpoint (`https://api.minimax.io/anthropic`).
//! Reuses the Anthropic message converter, stream handler, and SSE types.

pub mod provider;
pub mod types;
