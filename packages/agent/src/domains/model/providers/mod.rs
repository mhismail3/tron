//! # llm
//!
//! LLM provider trait and shared streaming utilities.
//!
//! This module defines the [`Provider`] trait that all LLM backends implement,
//! plus shared infrastructure used across providers:
//!
//! - [`provider`] — Core [`Provider`] trait, [`ProviderStreamOptions`], [`ProviderError`]
//! - [`models`] — Model registry, ID constants, provider detection, capability queries
//! - [`sse`] — Shared SSE line parser for HTTP streaming responses
//! - [`retry`] — Stream retry with exponential backoff + jitter
//! - [`capability_parsing`] — Robust JSON parsing for capability invocation arguments
//! - [`context_composition`] — Context part ordering and stable/volatile grouping
//! - [`id_remapping`] — Capability invocation ID format conversion between providers
//! - [`stream_common`] — Shared [`stream_common::StreamAccumulator`] for delta processing
//!
//! # Architecture
//!
//! Each provider module (`llm::anthropic`, `llm::openai`, `llm::google`)
//! implements the [`Provider`] trait. The shared utilities
//! here eliminate duplication while allowing provider-specific behavior.
//!
//! ## Module Position
//!
//! Depends on: core.
//! Depended on by: runtime, server.

#![deny(unsafe_code)]

pub mod anthropic;
#[path = "shared/capability_parsing.rs"]
pub mod capability_parsing;
#[path = "shared/context_composition.rs"]
pub mod context_composition;
#[path = "shared/error_parsing.rs"]
pub mod error_parsing;
pub mod factory;
pub mod google;
#[path = "shared/health.rs"]
pub mod health;
#[path = "shared/id_remapping.rs"]
pub mod id_remapping;
pub mod kimi;
pub mod minimax;
pub mod models;
pub mod ollama;
pub mod openai;
#[path = "shared/provider.rs"]
pub mod provider;
#[path = "shared/retry.rs"]
pub mod retry;
#[path = "shared/sse.rs"]
pub mod sse;
#[path = "shared/stream_common.rs"]
pub mod stream_common;
#[path = "shared/stream_pipeline.rs"]
pub mod stream_pipeline;
pub mod tokens;

pub use capability_parsing::{
    CapabilityCallContext, is_valid_capability_call_arguments, parse_capability_call_arguments,
};
pub use context_composition::{
    GroupedContextParts, compose_context_parts, compose_context_parts_grouped,
};
pub use health::ProviderHealthTracker;
pub use id_remapping::{IdFormat, build_invocation_id_mapping, remap_invocation_id};
pub use models::model_ids;
pub use models::registry::{
    all_model_ids, detect_provider_from_model, is_model_supported, model_context_window,
    model_supports_images, strip_provider_prefix,
};
pub use provider::{
    AnthropicEffortLevel, Provider, ProviderError, ProviderFactory, ProviderResult,
    ProviderStreamOptions, ReasoningEffort, StreamEventStream,
};
pub use retry::{StreamFactory, StreamRetryConfig, with_provider_retry};
pub use sse::{SseParserOptions, parse_sse_lines};
pub use stream_common::StreamAccumulator;
