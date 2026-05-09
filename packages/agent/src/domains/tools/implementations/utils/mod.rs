//! # tools/utils — shared tool helpers
//!
//! Utilities used by multiple tool implementations. Kept separate from
//! [`crate::domains::tools::implementations::traits`] so that adding a new helper does not churn
//! the trait surface.
//!
//! ## Submodules
//!
//! | Module          | Content |
//! |-----------------|---------|
//! | [`diff`]        | Unified-diff formatter for `Edit`/`Write` results (line-level, context-aware) |
//! | [`fs_errors`]   | Convert `std::io::Error` into user-actionable tool result strings |
//! | [`path`]        | Path normalisation, home expansion, working-directory resolution |
//! | [`schema`]      | `ToolSchemaBuilder` — fluent JSON-Schema construction for tool `definition()` |
//! | [`truncation`]  | Cap tool output to a configured byte/line budget; preserves suffix so stack traces survive |
//! | [`validation`]  | Typed parameter extraction — `validate_required_string`, `get_optional_u64`, etc. |
//!
//! ## Invariants
//!
//! - [`validation`] returns a `TronToolResult` on failure rather than a
//!   panic or `Result::Err` — each helper is a drop-in replacement that
//!   hands the user-facing message back through the normal tool path.
//! - `path::normalise` is purely lexical; symlink resolution is
//!   deliberately not done here (see the L14 INVARIANT on
//!   [`crate::domains::agent::runner::guardrails::rules::path`]).

pub mod diff;
pub mod fs_errors;
pub mod path;
pub mod schema;
pub mod truncation;
pub mod validation;
