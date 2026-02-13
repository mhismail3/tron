//! # tron-skills
//!
//! Skill loader, registry, and context injector.
//!
//! Skills are SKILL.md files with YAML frontmatter + markdown body.
//! The registry discovers skills from `~/.tron/skills/` and project-local paths,
//! and the injector handles per-session context injection.

#![deny(unsafe_code)]
