//! # skills
//!
//! Skill loader, registry, and context injector.
//!
//! Skills are `SKILL.md` files with optional YAML frontmatter + markdown body.
//! The system discovers skills from `~/.tron/skills/` (global) and project-local
//! `.claude/skills/` or `.tron/skills/` directories.
//!
//! ## Module Overview
//!
//! - [`parser`] — Parse SKILL.md files (YAML frontmatter + markdown body)
//! - [`loader`] — Filesystem discovery and scanning
//! - [`registry`] — In-memory skill cache with source precedence
//! - [`injector`] — `@reference` extraction and `<skills>` XML context building
//! - [`tracker`] — Per-session skill tracking with event-sourced reconstruction
//! - [`denials`] — Convert frontmatter tool restrictions to denial config
//!
//! ## Usage
//!
//! ```rust,no_run
//! use crate::skills::registry::SkillRegistry;
//! use crate::skills::injector::process_prompt_for_skills;
//!
//! let mut registry = SkillRegistry::new();
//! registry.initialize("/path/to/project");
//!
//! let result = process_prompt_for_skills("Use @browser tool", &registry);
//! println!("Cleaned: {}", result.cleaned_prompt);
//! println!("Context: {}", result.skill_context);
//! ```
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
