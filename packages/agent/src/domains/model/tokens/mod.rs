//! Token counting, normalization, and cost calculation for LLM usage.
//!
//! This module is the canonical token-accounting boundary for provider usage:
//! providers preserve raw provider fields, normalization converts those fields
//! into server-owned context-window and billable buckets, and pricing returns
//! either exact component costs or an explicit unavailable state. Downstream
//! event payloads, session counters, DB denormalized columns, and iOS DTOs
//! consume the typed [`TokenRecord`] rather than recomputing provider-specific
//! semantics locally. Reasoning/thought token counts are metadata-only audit
//! facts; they do not imply raw hidden reasoning content is stored or displayed.
//!
//! INVARIANT: token accounting is server-authoritative. A missing provider,
//! unknown model price, absent turn number, or partial provider usage must not
//! be silently coerced into a plausible cost or provider default.

pub mod errors;
pub mod normalization;
pub mod pricing;
pub mod types;
