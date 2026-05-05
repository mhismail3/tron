//! Context assembly, compaction, rules, and profile-backed instruction prompts.
//!
//! ## Submodules
//!
//! | Module | Purpose |
//! |--------|---------|
//! | `context_manager` | Entry point — owns context lifecycle, compaction triggers |
//! | `context_snapshot_builder` | Builds context snapshots (stable + volatile breakdown) via `SnapshotDeps` |
//! | `compaction_engine` | Executes compaction: summarize old messages, trim context |
//! | `llm_summarizer` | Subagent-based summarization for compaction |
//! | `summarizer` | Summarizer trait and fallback implementations |
//! | `message_store` | In-memory message buffer with compaction boundary tracking |
//! | `loader` | Loads context parts (rules, skills) from disk/DB |
//! | `local_policy` | Profile-backed local-model policy adapter: provider ids, tool allow-list, rules truncation |
//! | `rules_discovery` | Finds `.claude/rules/` files in project directories |
//! | `rules_index` | Path-indexed rule lookup for context assembly |
//! | `rules_tracker` | Tracks which rules are active per session |
//! | `instruction_prompts` | Project/global prompt overlay loading; normal profile prompts arrive through `ProfileRuntime` plans |
//! | `token_estimator` | Token counting and context budget calculations |
//! | `path_extractor` | Extracts workspace paths from session context |
//! | `constants` | Token limits, compaction thresholds |
//! | `types` | Shared types for context subsystem |
//!
//! ## Entry Point
//!
//! [`context_manager::ContextManager`] — created per session, manages the full
//! context lifecycle from loading through compaction.
//!
//! ## Key Invariant
//!
//! All normal prompt text is resolved before `ContextManager` construction by
//! `ProfileRuntime` session/process plans. Context state consumes that snapshot;
//! it does not resolve active profile files or fall back to embedded behavior.
//! Compaction uses a multi-signal trigger (token threshold, progress signals,
//! turn count fallback) to decide when to compact context.

pub mod compaction_engine;
pub mod compaction_trigger;
pub mod constants;
pub mod context_manager;
pub mod context_snapshot_builder;
pub mod instruction_prompts;
pub mod llm_summarizer;
pub mod loader;
pub mod local_policy;
pub mod message_store;
pub mod path_extractor;
pub mod rules_discovery;
pub mod rules_index;
pub mod rules_tracker;
pub mod summarizer;
pub mod token_estimator;
pub mod types;
