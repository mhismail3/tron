//! Shared provider infrastructure.
//!
//! Provider implementations keep wire-format specifics in their own folders.
//! This module owns provider-neutral helpers: the shared [`provider`] trait,
//! SSE parsing, retry policy, health tracking, context composition, stream
//! accumulation, and stream wrapping.
//!
//! ## Submodules
//!
//! | Module | Purpose |
//! |--------|---------|
//! | [`context_composition`] | Stable/volatile context grouping and provider prompt assembly |
//! | [`error_parsing`] | Provider API error body classification |
//! | [`health`] | Provider health tracker used by routing and runtime context |
//! | [`provider`] | Core provider trait, stream options, and error types |
//! | [`retry`] | Provider stream retry with exponential backoff and jitter |
//! | [`sse`] | Shared SSE line parser |
//! | [`stream_common`] | Delta accumulator shared by streaming providers |
//! | [`stream_pipeline`] | SSE-to-event stream adapters and provider stream wrappers |
//!
//! ## Entry Points
//!
//! - [`provider::Provider`] and [`provider::ProviderFactory`] define the model
//!   backend contract consumed by the agent loop.
//! - [`retry::with_provider_retry`] wraps retryable provider streams.
//! - [`stream_pipeline`] adapts provider-native SSE streams into canonical
//!   `StreamEvent` values.
//!
//! ## Dependency Direction
//!
//! Depends on shared protocol DTOs and foundation retry settings. Depended on
//! by provider implementations, bootstrap/runtime dependencies, and the agent
//! loop. Provider-specific modules may depend on this module; this module must
//! not depend on provider-specific modules.
//!
//! ## Invariants
//!
//! - Shared helpers are provider-neutral and contain no provider-specific auth
//!   or endpoint policy.
//! - Stream wrappers preserve cancellation and retry events without altering
//!   provider-native parsing semantics.
//! - Health tracking is advisory routing state, not an authority source.
//!
//! ## Test Ownership
//!
//! Unit tests for shared helpers live in each helper file. Provider integration
//! tests exercise this module through concrete provider streams and factory
//! construction.

pub mod context_composition;
pub mod error_parsing;
pub mod health;
pub mod provider;
pub mod retry;
pub mod sse;
pub mod stream_common;
pub mod stream_pipeline;

pub use context_composition::{compose_context_parts, compose_context_parts_grouped};
pub use health::ProviderHealthTracker;
pub use retry::{StreamFactory, StreamRetryConfig, with_provider_retry};
pub use sse::SseParserOptions;
