//! # tron-tokens
//!
//! Token counting, normalization, and cost calculation for LLM usage.
//!
//! - Per-provider token extraction (Anthropic / Google / `OpenAI` report differently)
//! - `TokenRecord` with source, computed, and metadata fields
//! - Cost calculation per model via pricing table
//! - Cache cost tracking with breakpoint strategy

#![deny(unsafe_code)]
