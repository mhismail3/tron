//! Builtin (second-order) skills embedded in the binary.
//!
//! Each builtin skill is compiled into the binary via `include_str!` and seeded
//! to `~/.tron/skills/_builtin/<name>/SKILL.md` on startup. Users can customize
//! the filesystem copy; customized files are detected via a SHA-256 hash header
//! and are never overwritten. `tron reset-skills` restores all builtins from
//! the embedded content.
//!
//! Precedence: project > user (global) > builtin > embedded fallback.

use std::collections::HashSet;
use std::fs;
use std::path::Path;

use sha2::{Digest, Sha256};
use tracing::{debug, warn};

use crate::skills::constants::SKILL_MD_FILENAME;
use crate::skills::parser::parse_skill_md;
use crate::skills::types::{SkillMetadata, SkillSource};

/// Subdirectory name within the global skills directory.
pub const BUILTIN_SUBDIR: &str = "_builtin";

/// All builtin skills: `(name, embedded_content)`.
pub const BUILTIN_SKILLS: &[(&str, &str)] = &[
    ("code-search", include_str!("code-search.md")),
    ("file-search", include_str!("file-search.md")),
    ("web-fetch", include_str!("web-fetch.md")),
    ("web-search", include_str!("web-search.md")),
    ("git", include_str!("git.md")),
    ("testing", include_str!("testing.md")),
    ("packages", include_str!("packages.md")),
];

/// Set of all builtin skill names (for auto-loading decisions).
pub fn builtin_names() -> HashSet<String> {
    BUILTIN_SKILLS
        .iter()
        .map(|(name, _)| (*name).to_string())
        .collect()
}

// ── Hash-based seeding (same algorithm as system_prompts) ──────────

const HASH_HEADER_PREFIX: &str = "<!-- tron-prompt-hash:";
const HASH_HEADER_SUFFIX: &str = " -->";

fn compute_hash(content: &str) -> String {
    let full = Sha256::digest(content.as_bytes());
    full[..8].iter().map(|b| format!("{b:02x}")).collect()
}

fn build_seeded_content(content: &str) -> String {
    let hash = compute_hash(content);
    format!("{HASH_HEADER_PREFIX}{hash}{HASH_HEADER_SUFFIX}\n{content}")
}

/// Check if a file's content has been customized by the user.
///
/// Returns `true` if the hash header is missing, malformed, or doesn't match.
pub fn is_user_customized(file_content: &str) -> bool {
    let Some(first_line) = file_content.lines().next() else {
        return true;
    };

    let Some(hash_value) = first_line
        .strip_prefix(HASH_HEADER_PREFIX)
        .and_then(|rest| rest.strip_suffix(HASH_HEADER_SUFFIX))
    else {
        return true;
    };

    let body = strip_hash_header(file_content);
    let actual_hash = compute_hash(body);

    hash_value != actual_hash
}

fn strip_hash_header(file_content: &str) -> &str {
    let Some(first_line) = file_content.lines().next() else {
        return file_content;
    };

    if first_line.starts_with(HASH_HEADER_PREFIX) && first_line.ends_with(HASH_HEADER_SUFFIX) {
        &file_content[first_line.len().min(file_content.len())..]
            .strip_prefix('\n')
            .unwrap_or("")
    } else {
        file_content
    }
}

// ── Seeding ────────────────────────────────────────────────────────

/// Seed all builtin skills to `{tron_home}/skills/_builtin/<name>/SKILL.md`.
///
/// For each builtin:
/// - Missing → create from embedded content with hash header
/// - Exists, pristine, content differs → overwrite with latest
/// - Exists, user-customized → leave alone
///
/// Returns the number of files written.
pub fn seed_builtin_skills(tron_home: &Path) -> usize {
    let builtin_dir = tron_home.join("skills").join(BUILTIN_SUBDIR);
    let mut written = 0;

    for (name, embedded) in BUILTIN_SKILLS {
        let skill_dir = builtin_dir.join(name);
        let skill_path = skill_dir.join(SKILL_MD_FILENAME);

        if let Ok(existing) = fs::read_to_string(&skill_path) {
            if is_user_customized(&existing) {
                debug!(name, "Builtin skill is user-customized, leaving unchanged");
                continue;
            }
            // Pristine — check if content matches current embedded
            let body = strip_hash_header(&existing);
            if body == *embedded {
                continue; // Already up to date
            }
            debug!(name, "Updating pristine builtin skill to latest version");
        }

        // Create directory and write seeded content
        if let Err(e) = fs::create_dir_all(&skill_dir) {
            warn!(name, error = %e, "Failed to create builtin skill directory");
            continue;
        }

        let content = build_seeded_content(embedded);
        match fs::write(&skill_path, &content) {
            Ok(()) => {
                debug!(name, "Seeded builtin skill");
                written += 1;
            }
            Err(e) => {
                warn!(name, error = %e, "Failed to seed builtin skill");
            }
        }
    }

    written
}

/// Reset all builtin skills to their embedded defaults.
///
/// Force-writes all `_builtin/` skills regardless of customization.
/// Returns the number of files written.
pub fn reset_builtin_skills(tron_home: &Path) -> usize {
    let builtin_dir = tron_home.join("skills").join(BUILTIN_SUBDIR);
    let mut written = 0;

    for (name, embedded) in BUILTIN_SKILLS {
        let skill_dir = builtin_dir.join(name);
        let skill_path = skill_dir.join(SKILL_MD_FILENAME);

        if let Err(e) = fs::create_dir_all(&skill_dir) {
            warn!(name, error = %e, "Failed to create builtin skill directory for reset");
            continue;
        }

        let content = build_seeded_content(embedded);
        match fs::write(&skill_path, &content) {
            Ok(()) => written += 1,
            Err(e) => warn!(name, error = %e, "Failed to reset builtin skill"),
        }
    }

    written
}

// ── Embedded fallback ──────────────────────────────────────────────

/// Parse a builtin skill from its embedded content (no filesystem).
///
/// Used as fallback when the filesystem copy is missing.
pub fn parse_embedded_skill(name: &str, content: &str) -> SkillMetadata {
    let parsed = parse_skill_md(content);
    let display_name = parsed
        .frontmatter
        .name
        .clone()
        .unwrap_or_else(|| name.to_string());
    let description = parsed
        .frontmatter
        .description
        .clone()
        .unwrap_or(parsed.description);

    SkillMetadata {
        name: name.to_string(),
        display_name,
        description,
        content: parsed.content,
        frontmatter: parsed.frontmatter,
        source: SkillSource::Builtin,
        path: String::new(),
        skill_md_path: String::new(),
        additional_files: Vec::new(),
        last_modified: 0,
    }
}

/// Get embedded fallback skills for any builtins not found on the filesystem.
///
/// Returns skills for names in `BUILTIN_SKILLS` that are NOT in `found_names`.
pub fn embedded_fallbacks(found_names: &HashSet<String>) -> Vec<SkillMetadata> {
    BUILTIN_SKILLS
        .iter()
        .filter(|(name, _)| !found_names.contains(*name))
        .map(|(name, content)| parse_embedded_skill(name, content))
        .collect()
}

#[cfg(test)]
#[allow(unused_results)]
mod tests {
    use super::*;

    #[test]
    fn test_builtin_skills_count() {
        assert_eq!(BUILTIN_SKILLS.len(), 7);
    }

    #[test]
    fn test_builtin_names() {
        let names = builtin_names();
        assert!(names.contains("code-search"));
        assert!(names.contains("file-search"));
        assert!(names.contains("web-fetch"));
        assert!(names.contains("web-search"));
        assert!(names.contains("git"));
        assert!(names.contains("testing"));
        assert!(names.contains("packages"));
        assert_eq!(names.len(), 7);
    }

    #[test]
    fn test_all_builtins_parse_successfully() {
        for (name, content) in BUILTIN_SKILLS {
            let parsed = parse_skill_md(content);
            assert!(
                parsed.frontmatter.name.is_some(),
                "Builtin '{name}' missing name in frontmatter"
            );
            assert!(
                parsed.frontmatter.description.is_some(),
                "Builtin '{name}' missing description in frontmatter"
            );
        }
    }

    #[test]
    fn test_all_builtins_have_display() {
        for (name, content) in BUILTIN_SKILLS {
            let parsed = parse_skill_md(content);
            assert!(
                parsed.frontmatter.display.is_some(),
                "Builtin '{name}' missing display metadata"
            );
            let display = parsed.frontmatter.display.unwrap();
            assert!(
                display.label.is_some(),
                "Builtin '{name}' missing display.label"
            );
            assert!(
                display.icon.is_some(),
                "Builtin '{name}' missing display.icon"
            );
            assert!(
                display.color.is_some(),
                "Builtin '{name}' missing display.color"
            );
        }
    }

    #[test]
    fn test_hash_roundtrip() {
        let content = "test content";
        let seeded = build_seeded_content(content);
        assert!(!is_user_customized(&seeded));
        assert_eq!(strip_hash_header(&seeded), content);
    }

    #[test]
    fn test_customized_detection() {
        let seeded = build_seeded_content("original");
        // Modify the body after the hash header
        let modified = seeded.replace("original", "modified");
        assert!(is_user_customized(&modified));
    }

    #[test]
    fn test_no_hash_header_is_customized() {
        assert!(is_user_customized("no header here"));
    }

    #[test]
    fn test_empty_content_is_customized() {
        assert!(is_user_customized(""));
    }

    #[test]
    fn test_seed_creates_files() {
        let dir = tempfile::tempdir().unwrap();
        let written = seed_builtin_skills(dir.path());
        assert_eq!(written, 7);

        // Verify files exist
        for (name, _) in BUILTIN_SKILLS {
            let path = dir.path().join("skills").join(BUILTIN_SUBDIR).join(name).join(SKILL_MD_FILENAME);
            assert!(path.exists(), "Missing seeded file for '{name}'");
        }
    }

    #[test]
    fn test_seed_idempotent() {
        let dir = tempfile::tempdir().unwrap();
        let first = seed_builtin_skills(dir.path());
        assert_eq!(first, 7);
        let second = seed_builtin_skills(dir.path());
        assert_eq!(second, 0); // No files written — all up to date
    }

    #[test]
    fn test_seed_preserves_customized() {
        let dir = tempfile::tempdir().unwrap();
        seed_builtin_skills(dir.path());

        // Customize one file
        let path = dir.path().join("skills").join(BUILTIN_SUBDIR).join("git").join(SKILL_MD_FILENAME);
        fs::write(&path, "my custom content").unwrap();

        // Re-seed — customized file should not be overwritten
        seed_builtin_skills(dir.path());
        let content = fs::read_to_string(&path).unwrap();
        assert_eq!(content, "my custom content");
    }

    #[test]
    fn test_seed_updates_pristine_outdated() {
        let dir = tempfile::tempdir().unwrap();
        seed_builtin_skills(dir.path());

        // Write an outdated pristine file (valid hash but different content)
        let path = dir.path().join("skills").join(BUILTIN_SUBDIR).join("git").join(SKILL_MD_FILENAME);
        let outdated = build_seeded_content("outdated content");
        fs::write(&path, &outdated).unwrap();

        // Re-seed — outdated pristine should be overwritten
        let written = seed_builtin_skills(dir.path());
        assert!(written >= 1);
        let content = fs::read_to_string(&path).unwrap();
        assert!(!content.contains("outdated content"));
    }

    #[test]
    fn test_reset_overwrites_customized() {
        let dir = tempfile::tempdir().unwrap();
        seed_builtin_skills(dir.path());

        // Customize
        let path = dir.path().join("skills").join(BUILTIN_SUBDIR).join("git").join(SKILL_MD_FILENAME);
        fs::write(&path, "custom").unwrap();

        // Reset — should overwrite
        let written = reset_builtin_skills(dir.path());
        assert_eq!(written, 7);
        let content = fs::read_to_string(&path).unwrap();
        assert!(!content.contains("custom"));
        assert!(!is_user_customized(&content));
    }

    #[test]
    fn test_parse_embedded_skill() {
        let skill = parse_embedded_skill("code-search", BUILTIN_SKILLS[0].1);
        assert_eq!(skill.name, "code-search");
        assert_eq!(skill.display_name, "Code Search");
        assert_eq!(skill.source, SkillSource::Builtin);
        assert!(skill.frontmatter.display.is_some());
    }

    #[test]
    fn test_embedded_fallbacks() {
        let found: HashSet<String> = ["code-search", "git"].iter().map(|s| s.to_string()).collect();
        let fallbacks = embedded_fallbacks(&found);
        assert_eq!(fallbacks.len(), 5); // 7 - 2 found
        let names: Vec<&str> = fallbacks.iter().map(|s| s.name.as_str()).collect();
        assert!(!names.contains(&"code-search"));
        assert!(!names.contains(&"git"));
        assert!(names.contains(&"file-search"));
        assert!(names.contains(&"web-fetch"));
    }
}
