//! Shared constants for the skills system.

/// Maximum allowed file size for SKILL.md files (100 KB).
pub const MAX_SKILL_FILE_SIZE: u64 = 100 * 1024;

/// Expected filename for skill definitions.
pub const SKILL_MD_FILENAME: &str = "SKILL.md";

/// Global skills directory name (relative to home).
pub const GLOBAL_SKILLS_DIR: &str = ".tron/skills";

/// Skills subdirectory names to look for inside agent dirs.
pub const PROJECT_SKILLS_SUBDIRS: &[&str] = &[".claude/skills", ".tron/skills"];

/// Directories excluded from recursive skill scanning.
/// Mirrors `rules_discovery::DEFAULT_EXCLUDE_DIRS` for consistency.
pub const SKILL_SCAN_EXCLUDE_DIRS: &[&str] = &[
    "node_modules",
    ".git",
    ".hg",
    ".svn",
    "dist",
    "build",
    "out",
    ".next",
    ".nuxt",
    "coverage",
    ".nyc_output",
    "__pycache__",
];

/// Maximum directory depth for recursive skill scanning.
pub const SKILL_SCAN_MAX_DEPTH: u32 = 10;
