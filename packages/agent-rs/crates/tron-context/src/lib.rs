//! # tron-context
//!
//! Context assembly, compaction, rules, and system prompts.
//!
//! - **Context manager**: Assembles full context from system prompt + rules + skills + messages + memory
//! - **Compaction engine**: Summarizes old messages, preserves recent N turns, emits compact events
//! - **Rules tracker**: Discovers rules files, tracks path-scoped activation
//! - **System prompts**: Core prompt templates with token budgeting
//! - **Token estimator**: Char-based token estimation (chars/4 approximation)

#![deny(unsafe_code)]

pub mod audit;
pub mod compaction_engine;
pub mod constants;
pub mod context_manager;
pub mod context_snapshot_builder;
pub mod ledger_writer;
pub mod llm_summarizer;
pub mod loader;
pub mod message_store;
pub mod rules_discovery;
pub mod rules_index;
pub mod rules_tracker;
pub mod summarizer;
pub mod system_prompts;
pub mod token_estimator;
pub mod types;
