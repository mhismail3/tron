//! Prompt Library JSON-RPC transport bindings.
//!
//! Eight methods split across two groups:
//!
//! ## History (auto-captured, deduped)
//! - `promptHistory.list`   — engine bridge generic trigger
//! - `promptHistory.delete` — engine bridge generic trigger
//! - `promptHistory.clear`  — engine bridge generic trigger
//!
//! ## Snippets (user-authored)
//! - `promptSnippet.list`   — engine bridge generic trigger
//! - `promptSnippet.get`    — engine bridge generic trigger
//! - `promptSnippet.create` — engine bridge generic trigger
//! - `promptSnippet.update` — engine bridge generic trigger
//! - `promptSnippet.delete` — engine bridge generic trigger
//!
//! The prompt-library RPC group was the first fully collapsed group in the
//! engine migration: every public method is marker-registered in
//! `handlers::mod` and dispatched through a `json_rpc` trigger into canonical
//! `prompt_library::*` functions. `crate::prompt_library::store` remains the
//! single source of truth for SQL + validation.

#[cfg(test)]
#[path = "prompt_library_tests.rs"]
mod tests;
