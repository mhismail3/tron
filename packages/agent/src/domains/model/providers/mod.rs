//! # Provider boundary
//!
//! Model provider trait and shared streaming utilities.
//!
//! This module defines the [`Provider`] trait that model backends implement,
//! plus shared infrastructure used across providers. Provider-native
//! function-call and tool-call wire details stay inside provider modules and
//! `domains::model::protocol`; the rest of Tron consumes canonical
//! capability invocation drafts, results, and history. Provider modules must
//! reject malformed or non-object capability arguments at the stream boundary
//! instead of projecting them as empty canonical invocations.
//!
//! - [`provider`] — Core [`Provider`] trait, [`ProviderStreamOptions`], [`ProviderError`]
//! - [`crate::domains::model::routing::models`] — Model registry, ID constants, provider detection, capability queries
//! - [`sse`] — Shared SSE line parser for HTTP streaming responses
//! - [`retry`] — Stream retry with exponential backoff + jitter
//! - [`crate::domains::model::protocol::capability_parsing`] — Fail-closed JSON parsing for provider capability invocation arguments
//! - [`context_composition`] — Context part ordering and stable/volatile grouping
//! - [`crate::domains::model::protocol::id_remapping`] — Capability invocation ID format conversion between providers
//! - [`stream_common`] — Shared [`stream_common::StreamAccumulator`] for delta processing
//!
//! # Architecture
//!
//! Each provider module (`providers::anthropic`, `providers::openai`,
//! `providers::google`, and peers) implements the [`Provider`] trait. Shared
//! utilities eliminate duplication while keeping provider-specific wire
//! protocol handling physically isolated.
//!
//! ## Module Position
//!
//! Depends on: model contracts and provider-protocol conversion helpers.
//! Depended on by: the capability-native agent runner.

#![deny(unsafe_code)]

pub mod anthropic;
#[path = "shared/context_composition.rs"]
pub mod context_composition;
#[path = "shared/error_parsing.rs"]
pub mod error_parsing;
pub mod factory;
pub mod google;
#[path = "shared/health.rs"]
pub mod health;
pub mod kimi;
pub mod minimax;
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

pub use crate::domains::model::protocol::remap_invocation_id;
pub use crate::domains::model::protocol::{
    CapabilityArgumentParseError, CapabilityCallContext, IdFormat, build_invocation_id_mapping,
    capability_parsing, id_remapping, is_valid_capability_call_arguments,
    parse_capability_call_arguments,
};
pub use context_composition::{
    GroupedContextParts, compose_context_parts, compose_context_parts_grouped,
};
pub use health::ProviderHealthTracker;
pub use provider::{
    AnthropicEffortLevel, Provider, ProviderError, ProviderFactory, ProviderResult,
    ProviderStreamOptions, ReasoningEffort, StreamEventStream,
};
pub use retry::{StreamFactory, StreamRetryConfig, with_provider_retry};
pub use sse::{SseParserOptions, parse_sse_lines};
pub use stream_common::StreamAccumulator;
