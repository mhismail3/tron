//! # skills
//!
//! Skill loader, registry, context injector, and session-scoped state tracker.
//!
//! Skills are `SKILL.md` files with optional YAML frontmatter + markdown body.
//! The system discovers skills from three locations:
//!
//! - **Global**: `~/.tron/skills/`
//! - **Project (root)**: `{working_dir}/.claude/skills/` and `.tron/skills/`
//! - **Project (nested)**: `{working_dir}/**/.claude/skills/` and `**/.tron/skills/`
//!
//! ## Session semantics
//!
//! Skills are server-owned, session-scoped, and event-sourced. They persist
//! across turns (re-injected into the system prompt every turn) until explicit
//! deactivation or compaction. Managed via `skill.activate` / `skill.deactivate` RPCs.
//!
//! ## Module Overview
//!
//! - [`parser`] — Parse SKILL.md files (YAML frontmatter + markdown body)
//! - [`loader`] — Recursive filesystem discovery and scanning
//! - [`registry`] — In-memory skill cache with source precedence and staleness detection
//! - [`injector`] — `@reference` extraction and `<skills>` XML context building
//! - [`tracker`] — Per-session skill tracking with event-sourced reconstruction.
//!   Tracks active skills and deactivation notices.
//! - [`denials`] — Convert frontmatter tool restrictions to denial config
//!
//! ## State Model
//!
//! Skill state is event-sourced via `skill.activated` / `skill.deactivated` events.
//! [`tracker::SkillTracker::from_events`] reconstructs the current state on session resume.
//!
//! ## Module Position
//!
//! Standalone (no tron module dependencies).
//! Depended on by: runtime, server.

#![deny(unsafe_code)]

#[path = "model/constants.rs"]
pub mod constants;
#[path = "model/denials.rs"]
pub mod denials;
pub mod errors;
#[path = "runtime/injector.rs"]
pub mod injector;
#[path = "discovery/loader.rs"]
pub mod loader;
#[path = "discovery/parser.rs"]
pub mod parser;
#[path = "discovery/registry.rs"]
pub mod registry;
#[path = "runtime/tracker.rs"]
pub mod tracker;
#[path = "model/types.rs"]
pub mod types;
