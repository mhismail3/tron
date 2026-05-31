//! Filesystem skill scanner.
//!
//! Discovers skills by scanning directories for folders containing `SKILL.md`.
//! Covers two scopes × every service folder in [`SKILL_SERVICE_DIRS`]:
//!   * Global:  `~/.tron/skills/`, `~/.claude/skills/` (and any future service).
//!   * Project: `{working_dir}/**/.tron/skills/`, `{working_dir}/**/.claude/skills/`.
//!
//! Project skills shadow globals with the same name; within a single scope,
//! earlier services in [`SKILL_SERVICE_DIRS`] shadow later ones.
//!
//! [`SKILL_SERVICE_DIRS`]: crate::domains::skills::constants::SKILL_SERVICE_DIRS

use std::collections::HashSet;
use std::path::{Path, PathBuf};

use tracing::{debug, warn};

use crate::domains::skills::constants::{
    MAX_SKILL_FILE_SIZE, SKILL_MD_FILENAME, SKILL_RELATIVE_SUBDIRS, SKILL_SCAN_EXCLUDE_DIRS,
    SKILL_SCAN_MAX_DEPTH, SKILL_SERVICE_DIRS,
};
use crate::domains::skills::parser::parse_skill_md;
use crate::domains::skills::types::{SkillMetadata, SkillScanError, SkillScanResult, SkillSource};

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
    /// Service folder name that hosted this dir — one of
    /// [`crate::domains::skills::constants::SKILL_SERVICE_DIRS`].
    pub service: String,
}

/// Get every global skills directory path (`~/.tron/skills`, `~/.claude/skills`, …).
///
/// Order follows [`SKILL_RELATIVE_SUBDIRS`], which is in turn derived from
/// [`SKILL_SERVICE_DIRS`]: earlier entries take precedence on name collision.
///
/// [`SKILL_RELATIVE_SUBDIRS`]: crate::domains::skills::constants::SKILL_RELATIVE_SUBDIRS
/// [`SKILL_SERVICE_DIRS`]: crate::domains::skills::constants::SKILL_SERVICE_DIRS
pub fn global_skills_dirs() -> Vec<PathBuf> {
    global_skills_dirs_for_home(&crate::shared::paths::home_dir())
}

/// Same as [`global_skills_dirs`] but scoped to a caller-supplied home path.
///
/// Used by the registry's fingerprinter and by tests that need to point at a
/// temp dir without manipulating `$HOME`.
pub fn global_skills_dirs_for_home(home: &str) -> Vec<PathBuf> {
    SKILL_RELATIVE_SUBDIRS
        .iter()
        .map(|rel| PathBuf::from(home).join(rel))
        .collect()
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

    // Check for skills subdirectories at this level. Iterate in lockstep with
    // SKILL_SERVICE_DIRS so we can tag each discovered directory with its service
    // ("tron" for `.tron/skills`, "claude" for `.claude/skills`, …).
    for (subdir, service) in SKILL_RELATIVE_SUBDIRS.iter().zip(SKILL_SERVICE_DIRS.iter()) {
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
                service: (*service).to_string(),
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
/// `service` is the service-folder label (`"tron"`, `"claude"`, …) that the
/// directory belongs to; it is recorded on each discovered skill for UI tagging.
pub fn scan_directory(
    dir: &Path,
    source: SkillSource,
    service: &str,
    scope_dir: &str,
) -> SkillScanResult {
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

        match load_skill(&path, &skill_md_path, &name, source, service, scope_dir) {
            Ok(skill) => {
                debug!(name = %name, source = %source, service = %service, "Loaded skill");
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
/// when names conflict with globals (handled by the registry, not here).
/// Within each scope, same-name skills across services are deduped: the first
/// service in [`SKILL_SERVICE_DIRS`] wins.
///
/// [`SKILL_SERVICE_DIRS`]: crate::domains::skills::constants::SKILL_SERVICE_DIRS
pub fn scan_all(working_dir: &str) -> (SkillScanResult, SkillScanResult) {
    scan_all_for_home(&crate::shared::paths::home_dir(), working_dir)
}

/// Same as [`scan_all`] but scoped to a caller-supplied home path.
///
/// Used by tests that need to point global discovery at a temp dir without
/// manipulating `$HOME` (the workspace lints `unsafe_code = "deny"`).
pub fn scan_all_for_home(home: &str, working_dir: &str) -> (SkillScanResult, SkillScanResult) {
    // Globals: scan each service dir; dedupe by skill name across services.
    // First service wins (SKILL_RELATIVE_SUBDIRS order). The service name is
    // recorded on each skill via SkillMetadata.service for UI tagging.
    let mut global_result = SkillScanResult::default();
    let mut seen_global_names: HashSet<String> = HashSet::new();
    for (dir, service) in global_skills_dirs_for_home(home)
        .into_iter()
        .zip(SKILL_SERVICE_DIRS.iter())
    {
        let scan = scan_directory(&dir, SkillSource::Global, service, "");
        for skill in scan.skills {
            if seen_global_names.insert(skill.name.clone()) {
                global_result.skills.push(skill);
            }
        }
        global_result.errors.extend(scan.errors);
    }

    // Projects: dedupe by (scope_dir, skill_name) so that two services inside
    // the same scope produce at most one skill per name. Cross-scope shadowing
    // is handled downstream by SkillRegistry::initialize.
    let mut project_result = SkillScanResult::default();
    let mut seen_project_scope_names: HashSet<(String, String)> = HashSet::new();
    for psd in discover_project_skills_dirs(working_dir) {
        let scan = scan_directory(
            &psd.path,
            SkillSource::Project,
            &psd.service,
            &psd.scope_dir,
        );
        for skill in scan.skills {
            if seen_project_scope_names.insert((psd.scope_dir.clone(), skill.name.clone())) {
                project_result.skills.push(skill);
            }
        }
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
    service: &str,
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

    // Parse SKILL.md. Parser-side bounds (defense in depth) guard against
    // crafted manifests that bypass this loader's file-size check.
    let parsed = parse_skill_md(&content).map_err(|e| SkillScanError {
        path: path_str.clone(),
        message: format!("Failed to parse SKILL.md: {e}"),
        recoverable: true,
    })?;

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
        service: service.to_string(),
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
#[path = "loader/tests.rs"]
mod tests;
