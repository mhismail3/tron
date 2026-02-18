//! Filesystem skill scanner.
//!
//! Discovers skills by scanning directories for folders containing `SKILL.md`.
//! Supports both global (`~/.tron/skills/`) and project-local skill directories.

use std::path::{Path, PathBuf};

use tracing::{debug, warn};

use crate::constants::{
    GLOBAL_SKILLS_DIR, MAX_SKILL_FILE_SIZE, PROJECT_SKILLS_DIRS, SKILL_MD_FILENAME,
};
use crate::parser::parse_skill_md;
use crate::types::{SkillMetadata, SkillScanError, SkillScanResult, SkillSource};

/// Get the global skills directory path (`~/.tron/skills`).
pub fn global_skills_dir() -> PathBuf {
    let home = std::env::var("HOME").unwrap_or_else(|_| "/root".to_string());
    PathBuf::from(home).join(GLOBAL_SKILLS_DIR)
}

/// Get all project skills directory paths for the given working directory.
pub fn project_skills_dirs(working_dir: &str) -> Vec<PathBuf> {
    PROJECT_SKILLS_DIRS
        .iter()
        .map(|dir| PathBuf::from(working_dir).join(dir))
        .collect()
}

/// Scan a single directory for skill folders.
///
/// Non-existent directories return empty results (not errors).
/// Each subdirectory containing a `SKILL.md` file is loaded as a skill.
pub fn scan_directory(dir: &Path, source: SkillSource) -> SkillScanResult {
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

        match load_skill(&path, &skill_md_path, &name, source) {
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
    let global_result = scan_directory(&global_dir, SkillSource::Global);

    let mut project_result = SkillScanResult::default();
    for dir in project_skills_dirs(working_dir) {
        let scan = scan_directory(&dir, SkillSource::Project);
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
        path: path_str,
        skill_md_path: skill_md_path.to_string_lossy().into_owned(),
        additional_files,
        last_modified,
    })
}

/// List additional files in a skill directory (everything except `SKILL.md`).
fn list_additional_files(skill_path: &Path) -> Vec<String> {
    let mut files = Vec::new();
    if let Ok(entries) = std::fs::read_dir(skill_path) {
        for entry in entries.flatten() {
            if let Some(name) = entry.file_name().to_str() {
                if name != SKILL_MD_FILENAME && entry.path().is_file() {
                    files.push(name.to_string());
                }
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
        let result = scan_directory(tmp.path(), SkillSource::Global);
        assert!(result.skills.is_empty());
        assert!(result.errors.is_empty());
    }

    #[test]
    fn test_scan_nonexistent_directory() {
        let result = scan_directory(Path::new("/nonexistent/path"), SkillSource::Global);
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

        let result = scan_directory(tmp.path(), SkillSource::Project);
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

        let result = scan_directory(tmp.path(), SkillSource::Global);
        assert!(result.skills.is_empty());
    }

    #[test]
    fn test_scan_skips_directory_without_skill_md() {
        let tmp = TempDir::new().unwrap();
        let no_skill = tmp.path().join("no-skill");
        fs::create_dir_all(&no_skill).unwrap();
        fs::write(no_skill.join("README.md"), "Not a skill").unwrap();

        let result = scan_directory(tmp.path(), SkillSource::Global);
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

        let result = scan_directory(tmp.path(), SkillSource::Global);
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

        let result = scan_directory(tmp.path(), SkillSource::Global);
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

        let result = scan_directory(tmp.path(), SkillSource::Project);
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

        let result = scan_directory(tmp.path(), SkillSource::Global);
        assert_eq!(result.skills[0].display_name, "my-tool");
    }

    #[test]
    fn test_project_skills_dirs() {
        let dirs = project_skills_dirs("/home/user/project");
        assert_eq!(dirs.len(), 2);
        assert!(dirs[0].to_string_lossy().ends_with(".claude/skills"));
        assert!(dirs[1].to_string_lossy().ends_with(".tron/skills"));
    }
}
