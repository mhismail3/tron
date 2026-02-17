//! Context assembly, compaction, rules, and system prompts.

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
