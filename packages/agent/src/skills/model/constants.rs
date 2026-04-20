//! Shared constants for the skills system.

/// Maximum allowed file size for SKILL.md files (100 KB).
pub const MAX_SKILL_FILE_SIZE: u64 = 100 * 1024;

/// Expected filename for skill definitions.
pub const SKILL_MD_FILENAME: &str = "SKILL.md";

/// Service-folder names hosting a `skills/` subdirectory.
///
/// Order = precedence: earlier entries win on same-name collision, both for
/// globals and for same-scope project discovery. Extensible: add `"codex"`
/// here when Codex support lands.
pub const SKILL_SERVICE_DIRS: &[&str] = &["tron", "claude"];

/// Skill subdirectory paths relative to any scope root (`$HOME` for globals,
/// project root for locals).
///
/// Derived from [`SKILL_SERVICE_DIRS`] as `[".{svc}/skills" for svc in SERVICES]`;
/// the derivation is test-locked in this module's test block.
pub const SKILL_RELATIVE_SUBDIRS: &[&str] = &[".tron/skills", ".claude/skills"];

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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn skill_relative_subdirs_derived_from_services() {
        let expected: Vec<String> = SKILL_SERVICE_DIRS
            .iter()
            .map(|s| format!(".{s}/skills"))
            .collect();
        let actual: Vec<String> = SKILL_RELATIVE_SUBDIRS.iter().map(|s| (*s).to_string()).collect();
        assert_eq!(actual, expected);
    }

    #[test]
    fn skill_service_dirs_tron_precedes_claude() {
        assert_eq!(SKILL_SERVICE_DIRS, &["tron", "claude"]);
    }
}
