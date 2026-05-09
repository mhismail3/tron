//! User-memory loader.
//!
//! Discovers and injects the user-curated memory file at
//! `~/.tron/memory/MEMORY.md` plus a listing of detail files
//! under `~/.tron/memory/rules/*.md` into every session's context.
//!
//! Key invariants:
//! - **Per-turn refresh, fingerprint-gated.** Mirrors the skill-index pattern.
//!   `MemoryRegistry::content()` re-reads only when `MemoryFingerprint`
//!   detects an mtime change on `MEMORY.md` or any rules file.
//! - **`sessions/` is excluded** from the fingerprint. The retain system
//!   writes session journals mid-turn; including them would invalidate the
//!   cache on every turn.
//! - **Lazy bootstrap.** No install-time seeding. The agent creates
//!   `MEMORY.md` on first user-info capture; until then, the loader injects
//!   a short stub instructing the agent to bootstrap.
//! - **Symlink-transparent.** `fs::metadata` and `fs::read_to_string`
//!   follow symlinks, so a `memory/` dir that's symlinked into a dotfiles
//!   repo just works.
//! - **Detail files (`rules/*.md`) are LISTED, not loaded.** The agent
//!   reads them on demand via the standard `Read` tool.
//!
//! ## Module position
//!
//! Sibling to `runtime/context/` and `runtime/agent/`. Depends on
//! `core::paths`. Depended on by `domains::context::queries` and
//! `domains::agent::runtime` which inject the loaded
//! content into the LLM-bound `Context`.

#![deny(unsafe_code)]

pub mod registry;

pub use registry::{MemoryFingerprint, MemoryRegistry, MemoryRuleFile};
