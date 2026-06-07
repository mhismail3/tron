//! Primitive context assembly, compaction, and stateful prompt framing.
//!
//! ## Submodules
//!
//! | Module | Purpose |
//! |--------|---------|
//! | `context_manager` | Entry point — owns context lifecycle, compaction triggers, and manager dependency projections |
//! | `context_snapshot_builder` | Builds context snapshots (stable + volatile breakdown) via `SnapshotDeps` |
//! | `compaction_engine` | Executes compaction: summarize older eligible messages, trim context |
//! | `summarizer` | Summarizer trait and recovery implementations |
//! | `message_store` | In-memory message buffer with compaction boundary tracking |
//! | `loader` | Retired rule-loader source owned by PET-5/PET-10 session artifact cleanup |
//! | `local_policy` | Retired profile policy source owned by PET-6/PET-10 cleanup |
//! | `rules_discovery` | Retired path-scoped rule discovery source owned by PET-5/PET-10 cleanup |
//! | `rules_index` | Retired rule index source owned by PET-5/PET-10 cleanup |
//! | `soul` | Static seed instruction for the primitive loop |
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
//! The model-facing prompt begins with the static soul seed and the compact
//! agent-owned state projection loaded through engine state primitives.
//! Compaction uses a multi-signal trigger (token threshold, progress signals,
//! turn count recovery signal) to decide when to compact context, but a trigger
//! only commits when an older message window can be summarized and the result
//! reduces the durable context.

pub mod compaction_engine;
pub mod compaction_trigger;
pub mod constants;
pub mod context_manager;
pub mod context_snapshot_builder;
pub mod instruction_prompts;
pub mod loader;
pub mod local_policy;
pub mod message_store;
pub mod path_extractor;
pub mod rules_discovery;
pub mod rules_index;
pub mod soul;
pub mod summarizer;
pub mod token_estimator;
pub mod types;
