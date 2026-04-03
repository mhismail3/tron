//! # skills
//!
//! Skill loader, registry, and context injector.
//!
//! Skills are `SKILL.md` files with optional YAML frontmatter + markdown body.
//! The system discovers skills from three locations:
//!
//! - **Global**: `~/.tron/skills/`
//! - **Project (root)**: `{working_dir}/.claude/skills/` and `.tron/skills/`
//! - **Project (nested)**: `{working_dir}/**/.claude/skills/` and `**/.tron/skills/`
//!
//! Nested discovery walks the project tree recursively, skipping excluded
//! directories (`node_modules`, `.git`, etc.) and hidden directories. Root-level
//! project skills shadow nested skills with the same name; project skills shadow
//! global skills.
//!
//! ## Module Overview
//!
//! - [`parser`] — Parse SKILL.md files (YAML frontmatter + markdown body)
//! - [`loader`] — Recursive filesystem discovery and scanning
//! - [`registry`] — In-memory skill cache with source precedence and staleness detection
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
//! // Discovers skills at all nesting levels within the project
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
