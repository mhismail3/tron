//! # tron-hooks
//!
//! Hook engine, registry, and background tracker.
//!
//! Hook types: `PreToolUse` (blocking), `PostToolUse` (background), `SessionStart`,
//! `SessionEnd`, `Stop`, `SubagentStop`, `UserPromptSubmit`, `PreCompact`.
//!
//! Includes builtin hooks: memory-ledger, post-tool-use, pre-compact.

#![deny(unsafe_code)]
