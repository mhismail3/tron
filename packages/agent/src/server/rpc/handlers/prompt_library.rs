//! Prompt Library RPC handlers.
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
//! The prompt-library RPC group is the first fully collapsed group in the
//! engine migration: every public method is marker-registered in
//! `handlers::mod` and executed by `rpc::<method>` functions owned by the
//! engine bridge. `crate::prompt_library::store` remains the single source of
//! truth for SQL + validation.

#[cfg(test)]
#[path = "prompt_library_tests.rs"]
mod tests;
