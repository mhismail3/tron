//! # skills
//!
//! Skill loader, registry, context injector, and session-scoped state tracker.
//!
//! Skills are `SKILL.md` files with optional YAML frontmatter + markdown body.
//! The system discovers skills across two scopes × every service folder in
//! [`constants::SKILL_SERVICE_DIRS`] (currently `tron` and `claude`):
//!
//! - **Global**: `~/.tron/skills/`, `~/.claude/skills/`
//! - **Project (root)**: `{working_dir}/.tron/skills/`, `{working_dir}/.claude/skills/`
//! - **Project (nested)**: `{working_dir}/**/.tron/skills/`, `{working_dir}/**/.claude/skills/`
//!
//! Project skills shadow globals with the same name. Within a single scope,
//! earlier services in `SKILL_SERVICE_DIRS` shadow later ones (`.tron` wins
//! over `.claude`).
//!
//! ## Session semantics
//!
//! Skills are server-owned, session-scoped, and event-sourced. They persist
//! across turns (re-injected into the system prompt every turn) until explicit
//! deactivation or compaction. Managed via `skill.activate` / `skill.deactivate` capability calls.
//!
//! ## Module Overview
//!
//! - [`parser`] — Parse SKILL.md files (YAML frontmatter + markdown body)
//! - [`loader`] — Recursive filesystem discovery and scanning
//! - [`registry`] — In-memory skill cache with source precedence and staleness detection
//! - [`injector`] — `@reference` extraction and `<skills>` XML context building
//! - [`tracker`] — Per-session skill tracking with event-sourced reconstruction.
//!   Tracks active skills and deactivation notices.
//! - [`denials`] — Convert frontmatter capability restrictions to denial config
//!
//! ## State Model
//!
//! Skill state is event-sourced via `skill.activated` / `skill.deactivated` events.
//! [`tracker::SkillTracker::from_events_with_policy`] reconstructs the current state on session resume.
//!
//! ## Module Position
//!
//! Standalone (no tron module dependencies).
//! Depended on by: the agent runner, skill domain handlers, and context assembly.

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
