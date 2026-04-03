//! Filesystem skill scanner.
//!
//! Discovers skills by scanning directories for folders containing `SKILL.md`.
//! Walks the project tree recursively to find `.claude/skills/` and `.tron/skills/`
//! directories at any depth. Also supports global skills from `~/.tron/skills/`.

use std::collections::HashSet;
use std::path::{Path, PathBuf};

use tracing::{debug, warn};

use crate::skills::constants::{
    GLOBAL_SKILLS_DIR, MAX_SKILL_FILE_SIZE, PROJECT_SKILLS_SUBDIRS, SKILL_MD_FILENAME,
    SKILL_SCAN_EXCLUDE_DIRS, SKILL_SCAN_MAX_DEPTH,
};
use crate::skills::parser::parse_skill_md;
use crate::skills::types::{SkillMetadata, SkillScanError, SkillScanResult, SkillSource};

// =============================================================================
// Directory discovery
// =============================================================================

/// A discovered project skills directory with its scope.
#[derive(Debug, Clone)]
pub struct ProjectSkillsDir {
    /// Absolute path to the skills directory.
    pub path: PathBuf,
    /// Relative scope from project root. Empty string = root.
    pub scope_dir: String,
}

/// Get the global skills directory path (`~/.tron/skills`).
pub fn global_skills_dir() -> PathBuf {
    let home = crate::core::paths::home_dir();
    PathBuf::from(home).join(GLOBAL_SKILLS_DIR)
}

/// Walk the project tree to find all `.claude/skills/` and `.tron/skills/` directories.
///
/// Returns directories ordered root-first (root-level before nested).
/// Skips excluded dirs (`node_modules`, `.git`, etc.) and hidden dirs.
/// Deduplicates on case-insensitive filesystems via `canonicalize`.
pub fn discover_project_skills_dirs(working_dir: &str) -> Vec<ProjectSkillsDir> {
    let root = PathBuf::from(working_dir);
    if !root.is_dir() {
        return Vec::new();
    }

    let mut results = Vec::new();
    let mut seen = HashSet::new();
    walk_for_skills_dirs(&root, &root, 0, &mut results, &mut seen);
    results
}

/// Recursive walker that discovers skills directories at each level.
fn walk_for_skills_dirs(
    dir: &Path,
    root: &Path,
    depth: u32,
    results: &mut Vec<ProjectSkillsDir>,
    seen: &mut HashSet<PathBuf>,
) {
    if depth > SKILL_SCAN_MAX_DEPTH {
        return;
    }

    // Compute scope_dir: relative path from root to current dir
    let scope_dir = if dir == root {
        String::new()
    } else {
        dir.strip_prefix(root)
            .unwrap_or(dir)
            .components()
            .map(|c| c.as_os_str().to_string_lossy().to_string())
            .collect::<Vec<_>>()
            .join("/")
    };

    // Check for skills subdirectories at this level
    for subdir in PROJECT_SKILLS_SUBDIRS {
        let skills_path = dir.join(subdir);
        if skills_path.is_dir() {
            // Deduplicate on case-insensitive filesystems
            if let Ok(canonical) = std::fs::canonicalize(&skills_path) {
                if !seen.insert(canonical) {
                    continue;
                }
            }
            results.push(ProjectSkillsDir {
                path: skills_path,
                scope_dir: scope_dir.clone(),
            });
        }
    }

    // Recurse into child directories
    if depth >= SKILL_SCAN_MAX_DEPTH {
        return;
    }

    let Ok(entries) = std::fs::read_dir(dir) else {
        return;
    };

    for entry in entries.flatten() {
        let Ok(ft) = entry.file_type() else {
            continue;
        };
        if !ft.is_dir() {
            continue;
        }
        let name = entry.file_name();
        let name_str = name.to_string_lossy();

        // Skip hidden directories
        if name_str.starts_with('.') {
            continue;
        }
        // Skip excluded directories
        if SKILL_SCAN_EXCLUDE_DIRS.contains(&name_str.as_ref()) {
            continue;
        }

        walk_for_skills_dirs(&entry.path(), root, depth + 1, results, seen);
    }
}

/// Scan a single directory for skill folders.
///
/// Non-existent directories return empty results (not errors).
/// Each subdirectory containing a `SKILL.md` file is loaded as a skill.
pub fn scan_directory(dir: &Path, source: SkillSource, scope_dir: &str) -> SkillScanResult {
    let mut result = SkillScanResult::default();

    if !dir.exists() || !dir.is_dir() {
        return result;
    }

    let entries = match std::fs::read_dir(dir) {
        Ok(entries) => entries,
        Err(e) => {
            warn!(dir = %dir.display(), error = %e, "Failed to read skills directory");
            return result;
        }
    };

    for entry in entries {
        let Ok(entry) = entry else {
            continue;
        };

        let path = entry.path();
        if !path.is_dir() {
            continue;
        }

        let skill_md_path = path.join(SKILL_MD_FILENAME);
        if !skill_md_path.exists() {
            continue;
        }

        let name = match path.file_name().and_then(|n| n.to_str()) {
            Some(n) => n.to_string(),
            None => continue,
        };

        if !is_valid_skill_name(&name) {
            result.errors.push(SkillScanError {
                path: path.display().to_string(),
                message: format!("Invalid skill name '{name}': must be 1-64 alphanumeric, dash, or underscore chars, starting with alphanumeric"),
                recoverable: true,
            });
            continue;
        }

        match load_skill(&path, &skill_md_path, &name, source, scope_dir) {
            Ok(skill) => {
                debug!(name = %name, source = %source, "Loaded skill");
                result.skills.push(skill);
            }
            Err(error) => {
                result.errors.push(error);
            }
        }
    }

    result
}

/// Scan both global and project skill directories.
///
/// Returns `(global_result, project_result)`. Project skills take precedence
/// when names conflict (handled by the registry, not here).
pub fn scan_all(working_dir: &str) -> (SkillScanResult, SkillScanResult) {
    let global_dir = global_skills_dir();
    let global_result = scan_directory(&global_dir, SkillSource::Global, "");

    let mut project_result = SkillScanResult::default();
    for psd in discover_project_skills_dirs(working_dir) {
        let scan = scan_directory(&psd.path, SkillSource::Project, &psd.scope_dir);
        project_result.skills.extend(scan.skills);
        project_result.errors.extend(scan.errors);
    }

    (global_result, project_result)
}

/// Load a single skill from its directory.
fn load_skill(
    skill_path: &Path,
    skill_md_path: &Path,
    name: &str,
    source: SkillSource,
    scope_dir: &str,
) -> Result<SkillMetadata, SkillScanError> {
    let path_str = skill_path.to_string_lossy().into_owned();

    // Check file size
    let metadata = std::fs::metadata(skill_md_path).map_err(|e| SkillScanError {
        path: path_str.clone(),
        message: format!("Failed to read metadata: {e}"),
        recoverable: true,
    })?;

    let size = metadata.len();
    if size > MAX_SKILL_FILE_SIZE {
        return Err(SkillScanError {
            path: path_str,
            message: format!("File too large: {size} bytes (max {MAX_SKILL_FILE_SIZE} bytes)"),
            recoverable: true,
        });
    }

    // Read file content
    let content = std::fs::read_to_string(skill_md_path).map_err(|e| SkillScanError {
        path: path_str.clone(),
        message: format!("Failed to read file: {e}"),
        recoverable: true,
    })?;

    // Parse SKILL.md
    let parsed = parse_skill_md(&content);

    // List additional files
    let additional_files = list_additional_files(skill_path);

    // Get last modified time
    let last_modified = metadata
        .modified()
        .ok()
        .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
        .map_or(0, |d| u64::try_from(d.as_millis()).unwrap_or(u64::MAX));

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

    Ok(SkillMetadata {
        name: name.to_string(),
        display_name,
        description,
        content: parsed.content,
        frontmatter: parsed.frontmatter,
        source,
        scope_dir: scope_dir.to_string(),
        path: path_str,
        skill_md_path: skill_md_path.to_string_lossy().into_owned(),
        additional_files,
        last_modified,
    })
}

/// Validate a skill directory name.
///
/// Must be 1-64 chars, alphanumeric/dash/underscore, starting with alphanumeric.
fn is_valid_skill_name(name: &str) -> bool {
    !name.is_empty()
        && name.len() <= 64
        && name
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')
        && name.as_bytes()[0].is_ascii_alphanumeric()
}

/// List additional files in a skill directory (everything except `SKILL.md`).
fn list_additional_files(skill_path: &Path) -> Vec<String> {
    let mut files = Vec::new();
    if let Ok(entries) = std::fs::read_dir(skill_path) {
        for entry in entries.flatten() {
            if let Some(name) = entry.file_name().to_str()
                && name != SKILL_MD_FILENAME
                && entry.path().is_file()
            {
                files.push(name.to_string());
            }
        }
    }
    files.sort();
    files
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use tempfile::TempDir;

    fn create_skill(dir: &Path, name: &str, content: &str) {
        let skill_dir = dir.join(name);
        fs::create_dir_all(&skill_dir).unwrap();
        fs::write(skill_dir.join(SKILL_MD_FILENAME), content).unwrap();
    }

    #[test]
    fn test_scan_empty_directory() {
        let tmp = TempDir::new().unwrap();
        let result = scan_directory(tmp.path(), SkillSource::Global, "");
        assert!(result.skills.is_empty());
        assert!(result.errors.is_empty());
    }

    #[test]
    fn test_scan_nonexistent_directory() {
        let result = scan_directory(Path::new("/nonexistent/path"), SkillSource::Global, "");
        assert!(result.skills.is_empty());
        assert!(result.errors.is_empty());
    }

    #[test]
    fn test_scan_finds_skills() {
        let tmp = TempDir::new().unwrap();
        create_skill(
            tmp.path(),
            "browser",
            "---\nname: Browser\n---\nBrowse the web.",
        );
        create_skill(tmp.path(), "git", "---\nname: Git\n---\nGit operations.");

        let result = scan_directory(tmp.path(), SkillSource::Project, "");
        assert_eq!(result.skills.len(), 2);
        assert!(result.errors.is_empty());

        let names: Vec<&str> = result.skills.iter().map(|s| s.name.as_str()).collect();
        assert!(names.contains(&"browser"));
        assert!(names.contains(&"git"));
    }

    #[test]
    fn test_scan_skips_non_directory() {
        let tmp = TempDir::new().unwrap();
        fs::write(tmp.path().join("not-a-dir.txt"), "hello").unwrap();

        let result = scan_directory(tmp.path(), SkillSource::Global, "");
        assert!(result.skills.is_empty());
    }

    #[test]
    fn test_scan_skips_directory_without_skill_md() {
        let tmp = TempDir::new().unwrap();
        let no_skill = tmp.path().join("no-skill");
        fs::create_dir_all(&no_skill).unwrap();
        fs::write(no_skill.join("README.md"), "Not a skill").unwrap();

        let result = scan_directory(tmp.path(), SkillSource::Global, "");
        assert!(result.skills.is_empty());
    }

    #[test]
    fn test_file_too_large_error() {
        let tmp = TempDir::new().unwrap();
        let skill_dir = tmp.path().join("large-skill");
        fs::create_dir_all(&skill_dir).unwrap();

        // Write a file larger than MAX_SKILL_FILE_SIZE
        let content = "x".repeat(MAX_SKILL_FILE_SIZE as usize + 1);
        fs::write(skill_dir.join(SKILL_MD_FILENAME), &content).unwrap();

        let result = scan_directory(tmp.path(), SkillSource::Global, "");
        assert!(result.skills.is_empty());
        assert_eq!(result.errors.len(), 1);
        assert!(result.errors[0].recoverable);
        assert!(result.errors[0].message.contains("too large"));
    }

    #[test]
    fn test_additional_files_listed() {
        let tmp = TempDir::new().unwrap();
        let skill_dir = tmp.path().join("my-skill");
        fs::create_dir_all(&skill_dir).unwrap();
        fs::write(
            skill_dir.join(SKILL_MD_FILENAME),
            "---\nname: Test\n---\nBody",
        )
        .unwrap();
        fs::write(skill_dir.join("helper.sh"), "#!/bin/bash").unwrap();
        fs::write(skill_dir.join("config.json"), "{}").unwrap();

        let result = scan_directory(tmp.path(), SkillSource::Global, "");
        assert_eq!(result.skills.len(), 1);
        let skill = &result.skills[0];
        assert!(skill.additional_files.contains(&"helper.sh".to_string()));
        assert!(skill.additional_files.contains(&"config.json".to_string()));
        assert!(
            !skill
                .additional_files
                .contains(&SKILL_MD_FILENAME.to_string())
        );
    }

    #[test]
    fn test_skill_metadata_populated() {
        let tmp = TempDir::new().unwrap();
        create_skill(
            tmp.path(),
            "browser",
            "---\nname: Browser Tool\ndescription: Browse websites\ntags: [web, browser]\n---\n# Browser\n\nUse this to browse.",
        );

        let result = scan_directory(tmp.path(), SkillSource::Project, "");
        assert_eq!(result.skills.len(), 1);

        let skill = &result.skills[0];
        assert_eq!(skill.name, "browser");
        assert_eq!(skill.display_name, "Browser Tool");
        assert_eq!(skill.description, "Browse websites");
        assert_eq!(skill.source, SkillSource::Project);
        assert!(skill.content.contains("Use this to browse."));
        assert!(skill.last_modified > 0);
    }

    #[test]
    fn test_display_name_fallback_to_folder_name() {
        let tmp = TempDir::new().unwrap();
        create_skill(tmp.path(), "my-tool", "---\ndescription: A tool\n---\nBody");

        let result = scan_directory(tmp.path(), SkillSource::Global, "");
        assert_eq!(result.skills[0].display_name, "my-tool");
    }

    // --- discover_project_skills_dirs ---

    #[test]
    fn discover_finds_root_skills_dirs() {
        let tmp = TempDir::new().unwrap();
        fs::create_dir_all(tmp.path().join(".claude/skills")).unwrap();
        fs::create_dir_all(tmp.path().join(".tron/skills")).unwrap();

        let dirs = discover_project_skills_dirs(tmp.path().to_str().unwrap());
        assert_eq!(dirs.len(), 2);
        assert!(dirs.iter().all(|d| d.scope_dir.is_empty()));
    }

    #[test]
    fn discover_finds_nested_skills_dirs() {
        let tmp = TempDir::new().unwrap();
        fs::create_dir_all(tmp.path().join("packages/foo/.claude/skills")).unwrap();

        let dirs = discover_project_skills_dirs(tmp.path().to_str().unwrap());
        assert_eq!(dirs.len(), 1);
        assert_eq!(dirs[0].scope_dir, "packages/foo");
        assert!(dirs[0].path.ends_with("packages/foo/.claude/skills"));
    }

    #[test]
    fn discover_finds_deeply_nested() {
        let tmp = TempDir::new().unwrap();
        fs::create_dir_all(tmp.path().join("packages/foo/bar/.tron/skills")).unwrap();

        let dirs = discover_project_skills_dirs(tmp.path().to_str().unwrap());
        assert_eq!(dirs.len(), 1);
        assert_eq!(dirs[0].scope_dir, "packages/foo/bar");
    }

    #[test]
    fn discover_skips_node_modules() {
        let tmp = TempDir::new().unwrap();
        fs::create_dir_all(tmp.path().join("node_modules/pkg/.claude/skills")).unwrap();
        fs::create_dir_all(tmp.path().join("src/.claude/skills")).unwrap();

        let dirs = discover_project_skills_dirs(tmp.path().to_str().unwrap());
        assert_eq!(dirs.len(), 1);
        assert_eq!(dirs[0].scope_dir, "src");
    }

    #[test]
    fn discover_skips_hidden_dirs() {
        let tmp = TempDir::new().unwrap();
        fs::create_dir_all(tmp.path().join(".hidden/.claude/skills")).unwrap();
        fs::create_dir_all(tmp.path().join("visible/.claude/skills")).unwrap();

        let dirs = discover_project_skills_dirs(tmp.path().to_str().unwrap());
        assert_eq!(dirs.len(), 1);
        assert_eq!(dirs[0].scope_dir, "visible");
    }

    #[test]
    fn discover_skips_all_excluded_dirs() {
        let tmp = TempDir::new().unwrap();
        for excluded in SKILL_SCAN_EXCLUDE_DIRS {
            fs::create_dir_all(tmp.path().join(format!("{excluded}/.claude/skills"))).unwrap();
        }
        // Add one valid dir
        fs::create_dir_all(tmp.path().join("src/.claude/skills")).unwrap();

        let dirs = discover_project_skills_dirs(tmp.path().to_str().unwrap());
        assert_eq!(dirs.len(), 1);
        assert_eq!(dirs[0].scope_dir, "src");
    }

    #[test]
    fn discover_respects_max_depth() {
        let tmp = TempDir::new().unwrap();
        // Create a path deeper than SKILL_SCAN_MAX_DEPTH
        let mut deep = tmp.path().to_path_buf();
        for i in 0..=SKILL_SCAN_MAX_DEPTH + 1 {
            deep = deep.join(format!("d{i}"));
        }
        fs::create_dir_all(deep.join(".claude/skills")).unwrap();

        // Also create a shallow one
        fs::create_dir_all(tmp.path().join("shallow/.claude/skills")).unwrap();

        let dirs = discover_project_skills_dirs(tmp.path().to_str().unwrap());
        assert_eq!(dirs.len(), 1);
        assert_eq!(dirs[0].scope_dir, "shallow");
    }

    #[test]
    fn discover_returns_root_first() {
        let tmp = TempDir::new().unwrap();
        fs::create_dir_all(tmp.path().join(".claude/skills")).unwrap();
        fs::create_dir_all(tmp.path().join("packages/foo/.claude/skills")).unwrap();

        let dirs = discover_project_skills_dirs(tmp.path().to_str().unwrap());
        assert_eq!(dirs.len(), 2);
        // Root-level should come first
        assert!(dirs[0].scope_dir.is_empty());
        assert_eq!(dirs[1].scope_dir, "packages/foo");
    }

    #[test]
    fn discover_nonexistent_working_dir() {
        let dirs = discover_project_skills_dirs("/nonexistent/path/that/does/not/exist");
        assert!(dirs.is_empty());
    }

    #[test]
    fn discover_empty_dir() {
        let tmp = TempDir::new().unwrap();
        let dirs = discover_project_skills_dirs(tmp.path().to_str().unwrap());
        assert!(dirs.is_empty());
    }

    #[test]
    fn discover_multiple_packages() {
        let tmp = TempDir::new().unwrap();
        fs::create_dir_all(tmp.path().join("packages/foo/.claude/skills")).unwrap();
        fs::create_dir_all(tmp.path().join("packages/bar/.tron/skills")).unwrap();

        let dirs = discover_project_skills_dirs(tmp.path().to_str().unwrap());
        assert_eq!(dirs.len(), 2);
        let scopes: Vec<&str> = dirs.iter().map(|d| d.scope_dir.as_str()).collect();
        assert!(scopes.contains(&"packages/foo"));
        assert!(scopes.contains(&"packages/bar"));
    }

    #[test]
    fn discover_claude_dir_without_skills_subdir_ignored() {
        let tmp = TempDir::new().unwrap();
        // .claude/ exists but no skills/ inside
        fs::create_dir_all(tmp.path().join("packages/foo/.claude/rules")).unwrap();

        let dirs = discover_project_skills_dirs(tmp.path().to_str().unwrap());
        assert!(dirs.is_empty());
    }

    #[test]
    fn discover_scope_dir_correct_for_root() {
        let tmp = TempDir::new().unwrap();
        fs::create_dir_all(tmp.path().join(".claude/skills")).unwrap();

        let dirs = discover_project_skills_dirs(tmp.path().to_str().unwrap());
        assert_eq!(dirs.len(), 1);
        assert_eq!(dirs[0].scope_dir, "");
    }

    // --- scan_all with nested discovery ---

    #[test]
    fn scan_all_discovers_nested_skills() {
        let tmp = TempDir::new().unwrap();
        let skills_dir = tmp.path().join("packages/foo/.claude/skills");
        fs::create_dir_all(&skills_dir).unwrap();
        create_skill(&skills_dir, "deploy", "---\nname: Deploy\n---\nDeploy things.");

        let (_global, project) = scan_all(tmp.path().to_str().unwrap());
        assert_eq!(project.skills.len(), 1);
        assert_eq!(project.skills[0].name, "deploy");
        assert_eq!(project.skills[0].scope_dir, "packages/foo");
    }

    #[test]
    fn scan_all_root_and_nested_together() {
        let tmp = TempDir::new().unwrap();
        let root_skills = tmp.path().join(".claude/skills");
        fs::create_dir_all(&root_skills).unwrap();
        create_skill(&root_skills, "browser", "---\nname: Browser\n---\nBrowse.");

        let nested_skills = tmp.path().join("packages/ios/.tron/skills");
        fs::create_dir_all(&nested_skills).unwrap();
        create_skill(&nested_skills, "device", "---\nname: Device\n---\nDevice.");

        let (_global, project) = scan_all(tmp.path().to_str().unwrap());
        assert_eq!(project.skills.len(), 2);
        let names: Vec<&str> = project.skills.iter().map(|s| s.name.as_str()).collect();
        assert!(names.contains(&"browser"));
        assert!(names.contains(&"device"));
    }

    #[test]
    fn scope_dir_set_on_loaded_skill() {
        let tmp = TempDir::new().unwrap();
        let skills_dir = tmp.path().join("packages/bar/.claude/skills");
        fs::create_dir_all(&skills_dir).unwrap();
        create_skill(&skills_dir, "test", "---\nname: Test\n---\nTest.");

        let result = scan_directory(&skills_dir, SkillSource::Project, "packages/bar");
        assert_eq!(result.skills.len(), 1);
        assert_eq!(result.skills[0].scope_dir, "packages/bar");
    }

    #[test]
    fn valid_skill_names() {
        assert!(is_valid_skill_name("my-skill"));
        assert!(is_valid_skill_name("skill_v2"));
        assert!(is_valid_skill_name("MySkill123"));
        assert!(is_valid_skill_name("a"));
    }

    #[test]
    fn invalid_skill_names() {
        assert!(!is_valid_skill_name("../escape"));
        assert!(!is_valid_skill_name("has space"));
        assert!(!is_valid_skill_name(".hidden"));
        assert!(!is_valid_skill_name("has/slash"));
        assert!(!is_valid_skill_name("-starts-dash"));
        assert!(!is_valid_skill_name("_starts-underscore"));
    }

    #[test]
    fn empty_skill_name() {
        assert!(!is_valid_skill_name(""));
    }

    #[test]
    fn scan_rejects_invalid_skill_name() {
        let tmp = tempfile::TempDir::new().unwrap();
        let bad_dir = tmp.path().join("..escape");
        std::fs::create_dir_all(&bad_dir).unwrap();
        std::fs::write(bad_dir.join("SKILL.md"), "# Test\nTest skill").unwrap();

        let result = scan_directory(tmp.path(), SkillSource::Global, "");
        assert!(result.skills.is_empty());
        assert_eq!(result.errors.len(), 1);
        assert!(result.errors[0].message.contains("Invalid skill name"));
    }
}
