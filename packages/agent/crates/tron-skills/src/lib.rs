//! # tron-skills
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
//! use tron_skills::registry::SkillRegistry;
//! use tron_skills::injector::process_prompt_for_skills;
//!
//! let mut registry = SkillRegistry::new();
//! registry.initialize("/path/to/project");
//!
//! let result = process_prompt_for_skills("Use @browser tool", &registry);
//! println!("Cleaned: {}", result.cleaned_prompt);
//! println!("Context: {}", result.skill_context);
//! ```
//!
//! ## Crate Position
//!
//! Standalone (no tron crate dependencies).
//! Depended on by: tron-runtime, tron-server.

#![deny(unsafe_code)]

pub mod constants;
pub mod denials;
pub mod errors;
pub mod injector;
pub mod loader;
pub mod parser;
pub mod registry;
pub mod tracker;
pub mod types;
