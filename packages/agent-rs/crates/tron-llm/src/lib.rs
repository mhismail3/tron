//! # tron-llm
//!
//! LLM provider trait and shared streaming utilities.
//!
//! Defines the `Provider` trait that all LLM backends implement:
//! - Shared SSE parser (handles Anthropic / `OpenAI` / Google format differences)
//! - Stream retry with exponential backoff + jitter
//! - Tool call JSON parsing from incremental deltas
//! - ID remapping utilities
//! - Model registry: `model_id -> ModelInfo { context_window, max_output, pricing, capabilities }`
//! - Provider factory: `create_provider(config) -> Box<dyn Provider>`

#![deny(unsafe_code)]
