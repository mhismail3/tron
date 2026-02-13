//! # tron-tools
//!
//! Tool trait and all tool implementations for the Tron agent.
//!
//! Defines the `TronTool` trait that every tool implements, and provides:
//! - **Filesystem**: read, write, edit, glob, grep
//! - **System**: bash (with timeout, output truncation, dangerous pattern detection)
//! - **Browser**: navigate, click, screenshot, evaluate (via CDP)
//! - **Subagent**: spawn, query, wait-for child agent sessions
//! - **UI**: ask-user-question, notify, render-app-ui
//! - **Web**: fetch, search
//! - **Communication**: inter-agent messaging

#![deny(unsafe_code)]
