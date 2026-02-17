//! # tron-llm
//!
//! LLM provider trait and shared streaming utilities.
//!
//! This crate defines the [`Provider`] trait that all LLM backends implement,
//! plus shared infrastructure used across providers:
//!
//! - [`provider`] — Core [`Provider`] trait, [`ProviderStreamOptions`], [`ProviderError`]
//! - [`models`] — Model registry, ID constants, provider detection, capability queries
//! - [`sse`] — Shared SSE line parser for HTTP streaming responses
//! - [`retry`] — Stream retry with exponential backoff + jitter
//! - [`tool_parsing`] — Robust JSON parsing for tool call arguments
//! - [`context_composition`] — Context part ordering and stable/volatile grouping
//! - [`id_remapping`] — Tool call ID format conversion between providers
//! - [`stop_reason`] — Provider-specific stop reason to unified enum mapping
//!
//! # Architecture
//!
//! Each provider crate (`tron-llm-anthropic`, `tron-llm-openai`, `tron-llm-google`)
//! depends on this crate and implements the [`Provider`] trait. The shared utilities
//! here eliminate duplication while allowing provider-specific behavior.

#![deny(unsafe_code)]

pub mod context_composition;
pub mod id_remapping;
pub mod models;
pub mod provider;
pub mod retry;
pub mod sse;
pub mod stop_reason;
pub mod tool_parsing;

pub use context_composition::{
    compose_context_parts, compose_context_parts_grouped, GroupedContextParts,
};
pub use id_remapping::{
    build_tool_call_id_mapping, detect_id_format, is_anthropic_id, is_openai_id,
    remap_tool_call_id, IdFormat,
};
pub use models::model_ids;
pub use models::registry::{
    all_model_ids, detect_provider_from_model, is_model_supported, strip_provider_prefix,
};
pub use models::types::{
    calculate_cost, format_context_window, format_model_pricing, ModelCapabilities, ModelCategory,
    ModelInfo, ModelTier, ProviderType,
};
pub use provider::{
    Provider, ProviderError, ProviderFactory, ProviderResult, ProviderStreamOptions,
    StreamEventStream,
};
pub use retry::{with_provider_retry, StreamFactory, StreamRetryConfig};
pub use sse::{parse_sse_data, parse_sse_lines, SseParserOptions};
pub use stop_reason::{map_google_stop_reason, map_openai_stop_reason};
pub use tool_parsing::{is_valid_tool_call_arguments, parse_tool_call_arguments, ToolCallContext};
