//! Prompt Library — history and snippets persistence.
//!
//! Provides two server-persisted datasets exposed via RPC:
//! - **History** (`prompt_history` table): auto-captured log of every
//!   interactive user prompt, deduplicated by normalized-text hash. Each
//!   row tracks `first_used_at`, `last_used_at`, and `use_count`.
//! - **Snippets** (`prompt_snippets` table): user-authored named quick
//!   prompts with full CRUD.
//!
//! # Submodules
//!
//! | Module      | Purpose                                                   |
//! |-------------|-----------------------------------------------------------|
//! | [`normalize`] | Text normalization + SHA-256 hashing for dedup.          |
//! | [`types`]     | Public data types returned to RPC callers.               |
//! | [`store`]     | SQLite-backed CRUD over the shared event-store pool.     |
//!
//! # Invariants
//!
//! - `prompt_history.text_hash` is the SHA-256 hex of the NFC-normalized,
//!   whitespace-trimmed, LF-normalized input. Dedup is exact after
//!   normalization.
//! - `record_prompt` never blocks the agent's prompt dispatch path — callers
//!   invoke it from a fire-and-forget `spawn_blocking`. Write failures are
//!   logged and swallowed.
//! - Capture is interactive-only: cron- and subagent-dispatched prompts are
//!   never recorded (the handler's `source: "cron"` param gates this).

pub mod normalize;
pub mod store;
pub mod types;

#[cfg(test)]
#[path = "store_tests.rs"]
mod store_tests;
