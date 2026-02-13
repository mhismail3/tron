//! # tron-context
//!
//! Context assembly, compaction, rules, and system prompts.
//!
//! - **Context manager**: Assembles full context from system prompt + rules + skills + messages + memory
//! - **Compaction engine**: Summarizes old messages, preserves recent N turns, emits compact events
//! - **Rules tracker**: Discovers rules files, tracks path-scoped activation
//! - **System prompts**: Core prompt templates with token budgeting

#![deny(unsafe_code)]
