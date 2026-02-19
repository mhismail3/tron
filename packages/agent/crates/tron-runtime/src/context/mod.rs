//! Context assembly, compaction, rules, and system prompts.
//!
//! ## Submodules
//!
//! | Module | Purpose |
//! |--------|---------|
//! | `context_manager` | Entry point — owns context lifecycle, compaction triggers |
//! | `context_snapshot_builder` | Builds the final context snapshot for LLM calls |
//! | `compaction_engine` | Executes compaction: summarize old messages, trim context |
//! | `llm_summarizer` | Subagent-based summarization for compaction |
//! | `summarizer` | Summarizer trait and fallback implementations |
//! | `message_store` | In-memory message buffer with compaction boundary tracking |
//! | `ledger_writer` | Writes memory.ledger events after each agent turn |
//! | `loader` | Loads context parts (rules, memory, skills) from disk/DB |
//! | `rules_discovery` | Finds `.claude/rules/` files in project directories |
//! | `rules_index` | Path-indexed rule lookup for context assembly |
//! | `rules_tracker` | Tracks which rules are active per session |
//! | `system_prompts` | System prompt template and assembly |
//! | `token_estimator` | Token counting and context budget calculations |
//! | `path_extractor` | Extracts workspace paths from session context |
//! | `constants` | Token limits, compaction thresholds |
//! | `audit` | Context assembly audit logging |
//! | `types` | Shared types for context subsystem |
//!
//! ## Entry Point
//!
//! [`context_manager::ContextManager`] — created per session, manages the full
//! context lifecycle from loading through compaction.
//!
//! ## Key Invariant
//!
//! Compaction always runs before ledger writing, ensuring `compact.boundary`
//! events precede `memory.ledger` events in the event log.

pub mod audit;
pub mod compaction_engine;
pub mod constants;
pub mod context_manager;
pub mod context_snapshot_builder;
pub mod ledger_writer;
pub mod llm_summarizer;
pub mod loader;
pub mod message_store;
pub mod path_extractor;
pub mod rules_discovery;
pub mod rules_index;
pub mod rules_tracker;
pub mod summarizer;
pub mod system_prompts;
pub mod token_estimator;
pub mod types;
