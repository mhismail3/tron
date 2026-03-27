//! Shared constants for the skills system.

/// Maximum allowed file size for SKILL.md files (100 KB).
pub const MAX_SKILL_FILE_SIZE: u64 = 100 * 1024;

/// Expected filename for skill definitions.
pub const SKILL_MD_FILENAME: &str = "SKILL.md";

/// Global skills directory name (relative to home).
pub const GLOBAL_SKILLS_DIR: &str = ".tron/skills";

/// Project skills directory names (relative to project root).
pub const PROJECT_SKILLS_DIRS: &[&str] = &[".claude/skills", ".tron/skills"];
