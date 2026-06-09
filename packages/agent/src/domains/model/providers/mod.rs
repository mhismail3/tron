//! # Provider boundary
//!
//! Model provider trait and shared streaming utilities.
//!
//! This module defines the [`shared::provider::Provider`] trait that model backends implement,
//! plus shared infrastructure used across providers. Provider-native
//! function-call and tool-call wire details stay inside provider modules and
//! `domains::model::protocol`; the rest of Tron consumes canonical
//! capability invocation drafts, results, and history. Provider modules must
//! reject malformed or non-object capability arguments at the stream boundary
//! instead of projecting them as empty canonical invocations.
//!
//! - [`shared::provider`] — Core [`shared::provider::Provider`] trait, [`shared::provider::ProviderStreamOptions`], [`shared::provider::ProviderError`]
//! - [`crate::domains::model::routing::models`] — Model registry, ID constants, provider detection, capability queries
//! - [`shared::sse`] — Shared SSE line parser for HTTP streaming responses
//! - [`shared::retry`] — Stream retry with exponential backoff + jitter
//! - [`crate::domains::model::protocol::capability_parsing`] — Fail-closed JSON parsing for provider capability invocation arguments
//! - [`shared::context_composition`] — Context part ordering and stable/volatile grouping
//! - [`crate::domains::model::protocol::id_remapping`] — Capability invocation ID format conversion between providers
//! - [`shared::stream_common`] — Shared [`shared::stream_common::StreamAccumulator`] for delta processing
//!
//! ## Submodules
//!
//! | Module | Purpose |
//! |--------|---------|
//! | [`shared`] | Provider-neutral traits, retry, SSE, context composition, stream helpers, and health tracking |
//! | [`factory`] | Default provider factory and settings/auth capture |
//! | [`anthropic`], [`google`], [`kimi`], [`minimax`], [`ollama`], [`openai`] | Provider-specific wire protocol implementations |
//! | [`tokens`] | Provider-neutral usage normalization and pricing helpers |
//!
//! ## Entry Points
//!
//! - [`shared::provider::Provider`] is the trait every backend implements.
//! - [`factory::DefaultProviderFactory`] creates providers from server settings
//!   and auth state.
//! - Protocol helpers from [`crate::domains::model::protocol`] are re-exported
//!   here for provider-local conversion code.
//!
//! ## Dependency Direction
//!
//! Each provider module (`providers::anthropic`, `providers::openai`,
//! `providers::google`, and peers) implements the [`shared::provider::Provider`] trait. Shared
//! utilities eliminate duplication while keeping provider-specific wire
//! protocol handling physically isolated.
//!
//! Depends on: model contracts, provider-protocol conversion helpers, active
//! settings, and provider auth state.
//! Depended on by: the agent loop, runtime bootstrap, and model routing.
//!
//! ## Invariants
//!
//! - Shared provider infrastructure stays under [`shared`]; this root exposes
//!   only the canonical provider protocol helpers used by provider modules.
//! - Provider-native wire formats are converted before they reach canonical
//!   capability history.
//! - Malformed provider capability arguments fail closed at the stream boundary.
//!
//! ## Test Ownership
//!
//! Provider behavior tests live beside each provider module. Shared helper tests
//! live under [`shared`], and factory selection tests live in [`factory`].

#![deny(unsafe_code)]

pub mod anthropic;
pub mod factory;
pub mod google;
pub mod kimi;
pub mod minimax;
pub mod ollama;
pub mod openai;
pub mod shared;

pub use crate::domains::model::protocol::remap_invocation_id;
pub use crate::domains::model::protocol::{
    CapabilityArgumentParseError, CapabilityCallContext, IdFormat, build_invocation_id_mapping,
    id_remapping, parse_capability_call_arguments,
};
