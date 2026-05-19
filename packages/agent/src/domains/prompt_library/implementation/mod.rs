//! Prompt Library — resource-backed history and snippets helpers.
//!
//! Prompt library durability lives in the engine resource substrate:
//! - **History** is stored as `artifact:prompt-history:{hash}` resources,
//!   deduplicated by normalized-text hash.
//! - **Snippets** are stored as `artifact:prompt-snippet:{id}` resources.
//! - Both resource families are system-scoped library state so generated
//!   management can run outside a chat session.
//!
//! # Submodules
//!
//! | Module      | Purpose                                                   |
//! |-------------|-----------------------------------------------------------|
//! | [`normalize`] | Text normalization + SHA-256 hashing for dedup.          |
//! | [`types`]     | Public data types returned to engine clients.               |
//!
//! # Invariants
//!
//! - Prompt history ids are the SHA-256 hex of the NFC-normalized,
//!   whitespace-trimmed, LF-normalized input.
//! - List/get/delete capabilities read resource truth only; retired
//!   prompt-library tables are not runtime readers.
//! - Capture is interactive-only: cron- and subagent-dispatched prompts are
//!   never recorded (the prompt payload's `source: "cron"` param gates this).

pub mod normalize;
pub mod types;
