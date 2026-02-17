//! Rules file discovery.
//!
//! Filesystem scanner that finds `CLAUDE.md` and `AGENTS.md` files throughout
//! the project tree. Discovers files in:
//!
//! - `.claude/`, `.tron/`, `.agent/` directories (agent dirs)
//! - Standalone `CLAUDE.md` / `AGENTS.md` in any directory (when enabled)
//!
//! Case-insensitive matching: `claude.md`, `CLAUDE.md`, `agents.md`,
//! `AGENTS.md` are all recognised.

use std::collections::HashSet;
use std::fs;
use std::path::{Path, PathBuf};
use std::time::SystemTime;

// ─────────────────────────────────────────────────────────────────────────────
// Constants
// ─────────────────────────────────────────────────────────────────────────────

/// Filenames recognised as rules files (compared lowercase).
const CONTEXT_FILENAMES: &[&str] = &["claude.md", "agents.md"];

/// Directories that may contain rules files.
const AGENT_DIRS: &[&str] = &[".claude", ".tron", ".agent"];

/// Directories excluded from scanning by default.
const DEFAULT_EXCLUDE_DIRS: &[&str] = &[
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

/// Maximum directory depth to scan.
const DEFAULT_MAX_DEPTH: u32 = 10;

// ─────────────────────────────────────────────────────────────────────────────
// Types
// ─────────────────────────────────────────────────────────────────────────────

/// A discovered rules file with metadata.
#[derive(Clone, Debug)]
pub struct DiscoveredRulesFile {
    /// Absolute path.
    pub path: PathBuf,
    /// Relative to project root (forward-slash separated).
    pub relative_path: String,
    /// File content (raw, no frontmatter stripping).
    pub content: String,
    /// Directory this rule applies to (relative). Empty string = root/global.
    pub scope_dir: String,
    /// `true` if `scope_dir` is empty (root-level).
    pub is_global: bool,
    /// `true` if not inside an agent dir (`.claude`/`.tron`/`.agent`).
    pub is_standalone: bool,
    /// File size in bytes.
    pub size_bytes: u64,
    /// Last modification time.
    pub modified_at: SystemTime,
}

/// Configuration for rules discovery.
#[derive(Clone, Debug)]
pub struct RulesDiscoveryConfig {
    /// Project root directory.
    pub project_root: PathBuf,
    /// Also discover standalone `CLAUDE.md`/`AGENTS.md` outside agent dirs.
    /// Default: `true`.
    pub discover_standalone_files: bool,
    /// Skip root-level files (context loader handles those separately).
    /// Default: `true`.
    pub exclude_root_level: bool,
    /// Maximum directory depth to scan. Default: 10.
    pub max_depth: u32,
    /// Directories to exclude from scanning.
    pub exclude_dirs: HashSet<String>,
}

impl Default for RulesDiscoveryConfig {
    fn default() -> Self {
        Self {
            project_root: PathBuf::new(),
            discover_standalone_files: true,
            exclude_root_level: true,
            max_depth: DEFAULT_MAX_DEPTH,
            exclude_dirs: DEFAULT_EXCLUDE_DIRS.iter().map(|s| (*s).to_owned()).collect(),
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Discovery
// ─────────────────────────────────────────────────────────────────────────────

/// Discover `CLAUDE.md`/`AGENTS.md` files throughout the project tree.
///
/// Walks from `config.project_root`, looking for context files in agent dirs
/// (`.claude/`, `.tron/`, `.agent/`) and optionally as standalone files.
/// Returns files classified as global or scoped based on their location.
pub fn discover_rules_files(config: &RulesDiscoveryConfig) -> Vec<DiscoveredRulesFile> {
    let mut results = Vec::new();
    let mut seen_real_paths = HashSet::new();

    scan_directory(
        &config.project_root,
        &config.project_root,
        &config.exclude_dirs,
        config.max_depth,
        0,
        &mut results,
        config.discover_standalone_files,
        config.exclude_root_level,
        &mut seen_real_paths,
    );

    results
}

#[allow(clippy::too_many_arguments)]
fn scan_directory(
    dir: &Path,
    project_root: &Path,
    exclude_dirs: &HashSet<String>,
    max_depth: u32,
    current_depth: u32,
    results: &mut Vec<DiscoveredRulesFile>,
    discover_standalone: bool,
    exclude_root_level: bool,
    seen_real_paths: &mut HashSet<PathBuf>,
) {
    if current_depth > max_depth {
        return;
    }

    let is_root = dir == project_root;

    // Check agent dirs for context files at this level
    for agent_dir in AGENT_DIRS {
        let agent_dir_path = dir.join(agent_dir);
        if let Ok(entries) = fs::read_dir(&agent_dir_path) {
            for entry in entries.flatten() {
                let Ok(ft) = entry.file_type() else {
                    continue;
                };
                if !ft.is_file() {
                    continue;
                }
                if !is_context_filename(&entry.file_name().to_string_lossy()) {
                    continue;
                }
                if is_root && exclude_root_level {
                    continue;
                }
                try_add_file(
                    &entry.path(),
                    project_root,
                    false,
                    results,
                    seen_real_paths,
                );
            }
        }
    }

    // Check for standalone context files at this level
    if discover_standalone {
        if let Ok(entries) = fs::read_dir(dir) {
            for entry in entries.flatten() {
                let Ok(ft) = entry.file_type() else {
                    continue;
                };
                if !ft.is_file() {
                    continue;
                }
                if !is_context_filename(&entry.file_name().to_string_lossy()) {
                    continue;
                }
                if is_root && exclude_root_level {
                    continue;
                }
                try_add_file(
                    &entry.path(),
                    project_root,
                    true,
                    results,
                    seen_real_paths,
                );
            }
        }
    }

    // Recurse into subdirectories
    if current_depth >= max_depth {
        return;
    }

    let Ok(entries) = fs::read_dir(dir) else {
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

        // Skip excluded and hidden directories
        if exclude_dirs.contains(name_str.as_ref()) {
            continue;
        }
        if name_str.starts_with('.') {
            continue;
        }

        scan_directory(
            &entry.path(),
            project_root,
            exclude_dirs,
            max_depth,
            current_depth + 1,
            results,
            discover_standalone,
            exclude_root_level,
            seen_real_paths,
        );
    }
}

fn is_context_filename(name: &str) -> bool {
    let lower = name.to_lowercase();
    CONTEXT_FILENAMES.contains(&lower.as_str())
}

fn try_add_file(
    file_path: &Path,
    project_root: &Path,
    is_standalone: bool,
    results: &mut Vec<DiscoveredRulesFile>,
    seen_real_paths: &mut HashSet<PathBuf>,
) {
    // Deduplicate on case-insensitive filesystem (macOS)
    let Ok(real_path) = fs::canonicalize(file_path) else {
        return;
    };
    if !seen_real_paths.insert(real_path) {
        return;
    }

    let Ok(content) = fs::read_to_string(file_path) else {
        return;
    };
    let Ok(metadata) = fs::metadata(file_path) else {
        return;
    };

    let relative = file_path
        .strip_prefix(project_root)
        .unwrap_or(file_path);
    // Always use forward slashes for relative paths
    let relative_path = relative
        .components()
        .map(|c| c.as_os_str().to_string_lossy().to_string())
        .collect::<Vec<_>>()
        .join("/");

    let scope_dir = compute_scope_dir(&relative_path, is_standalone);
    let is_global = scope_dir.is_empty();

    results.push(DiscoveredRulesFile {
        path: file_path.to_path_buf(),
        relative_path,
        content,
        scope_dir,
        is_global,
        is_standalone,
        size_bytes: metadata.len(),
        modified_at: metadata.modified().unwrap_or(SystemTime::UNIX_EPOCH),
    });
}

/// Compute the scope directory for a discovered file.
///
/// - Agent dir files: parent of the agent dir.
///   e.g. `packages/foo/.claude/CLAUDE.md` → `packages/foo`
///   e.g. `.claude/CLAUDE.md` → `""`
/// - Standalone files: parent directory.
///   e.g. `packages/foo/CLAUDE.md` → `packages/foo`
///   e.g. `CLAUDE.md` → `""`
fn compute_scope_dir(relative_path: &str, is_standalone: bool) -> String {
    if is_standalone {
        // Parent directory of the file
        match relative_path.rfind('/') {
            Some(idx) => relative_path[..idx].to_owned(),
            None => String::new(), // Root-level file
        }
    } else {
        // Agent dir file: go up two levels (past .claude/ and the filename)
        // e.g. "packages/foo/.claude/CLAUDE.md" → "packages/foo/.claude" → "packages/foo"
        let agent_dir = match relative_path.rfind('/') {
            Some(idx) => &relative_path[..idx],
            None => return String::new(),
        };
        match agent_dir.rfind('/') {
            Some(idx) => agent_dir[..idx].to_owned(),
            None => String::new(), // Root agent dir like ".claude"
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs::{self, create_dir_all};
    use tempfile::TempDir;

    fn setup() -> TempDir {
        TempDir::new().unwrap()
    }

    fn write_file(root: &Path, relative_path: &str, content: &str) {
        let full = root.join(relative_path);
        create_dir_all(full.parent().unwrap()).unwrap();
        fs::write(full, content).unwrap();
    }

    fn make_config(root: &Path) -> RulesDiscoveryConfig {
        RulesDiscoveryConfig {
            project_root: root.to_path_buf(),
            exclude_root_level: false,
            ..Default::default()
        }
    }

    fn make_config_exclude_root(root: &Path) -> RulesDiscoveryConfig {
        RulesDiscoveryConfig {
            project_root: root.to_path_buf(),
            ..Default::default()
        }
    }

    // -- Agent dir discovery --

    #[test]
    fn discovers_claude_md_at_project_root() {
        let tmp = setup();
        write_file(tmp.path(), ".claude/CLAUDE.md", "# Root rules");

        let results = discover_rules_files(&make_config(tmp.path()));
        assert_eq!(results.len(), 1);
        assert_eq!(results[0].relative_path, ".claude/CLAUDE.md");
        assert!(results[0].is_global);
        assert!(!results[0].is_standalone);
        assert_eq!(results[0].scope_dir, "");
    }

    #[test]
    fn discovers_agents_md_at_project_root() {
        let tmp = setup();
        write_file(tmp.path(), ".claude/AGENTS.md", "# Agents config");

        let results = discover_rules_files(&make_config(tmp.path()));
        assert_eq!(results.len(), 1);
        assert_eq!(results[0].relative_path, ".claude/AGENTS.md");
    }

    #[test]
    fn discovers_tron_dir_at_project_root() {
        let tmp = setup();
        write_file(tmp.path(), ".tron/CLAUDE.md", "# Tron rules");

        let results = discover_rules_files(&make_config(tmp.path()));
        assert_eq!(results.len(), 1);
        assert_eq!(results[0].relative_path, ".tron/CLAUDE.md");
    }

    #[test]
    fn discovers_agent_dir_at_project_root() {
        let tmp = setup();
        write_file(tmp.path(), ".agent/AGENTS.md", "# Agent config");

        let results = discover_rules_files(&make_config(tmp.path()));
        assert_eq!(results.len(), 1);
        assert_eq!(results[0].relative_path, ".agent/AGENTS.md");
    }

    #[test]
    fn case_insensitive_filenames() {
        let tmp = setup();
        write_file(tmp.path(), ".claude/claude.md", "# lowercase claude");
        write_file(tmp.path(), ".tron/agents.md", "# lowercase agents");

        let results = discover_rules_files(&make_config(tmp.path()));
        assert_eq!(results.len(), 2);
        let mut paths: Vec<_> = results.iter().map(|r| r.relative_path.as_str()).collect();
        paths.sort();
        assert_eq!(paths, vec![".claude/claude.md", ".tron/agents.md"]);
    }

    #[test]
    fn discovers_nested_rules_in_subdirectories() {
        let tmp = setup();
        write_file(
            tmp.path(),
            "packages/agent/.claude/CLAUDE.md",
            "# Agent rules",
        );

        let results = discover_rules_files(&make_config_exclude_root(tmp.path()));
        assert_eq!(results.len(), 1);
        assert_eq!(
            results[0].relative_path,
            "packages/agent/.claude/CLAUDE.md"
        );
        assert_eq!(results[0].scope_dir, "packages/agent");
        assert!(!results[0].is_global);
        assert!(!results[0].is_standalone);
    }

    #[test]
    fn discovers_deeply_nested_agent_dir_rules() {
        let tmp = setup();
        write_file(
            tmp.path(),
            "packages/agent/.claude/CLAUDE.md",
            "# Deep rule",
        );
        write_file(tmp.path(), "src/lib/.tron/AGENTS.md", "# Nested rule");

        let results = discover_rules_files(&make_config_exclude_root(tmp.path()));
        assert_eq!(results.len(), 2);
        let mut paths: Vec<_> = results.iter().map(|r| r.relative_path.as_str()).collect();
        paths.sort();
        assert_eq!(
            paths,
            vec![
                "packages/agent/.claude/CLAUDE.md",
                "src/lib/.tron/AGENTS.md"
            ]
        );
    }

    #[test]
    fn computes_correct_scope_dir_for_nested() {
        let tmp = setup();
        write_file(
            tmp.path(),
            "packages/foo/.claude/CLAUDE.md",
            "# Foo rules",
        );

        let results = discover_rules_files(&make_config_exclude_root(tmp.path()));
        assert_eq!(results[0].scope_dir, "packages/foo");
    }

    // -- Standalone file discovery --

    #[test]
    fn discovers_standalone_claude_md() {
        let tmp = setup();
        write_file(tmp.path(), "packages/foo/CLAUDE.md", "# Standalone");

        let config = RulesDiscoveryConfig {
            project_root: tmp.path().to_path_buf(),
            discover_standalone_files: true,
            ..Default::default()
        };
        let results = discover_rules_files(&config);
        assert_eq!(results.len(), 1);
        assert_eq!(results[0].relative_path, "packages/foo/CLAUDE.md");
        assert!(results[0].is_standalone);
        assert_eq!(results[0].scope_dir, "packages/foo");
    }

    #[test]
    fn discovers_standalone_agents_md() {
        let tmp = setup();
        write_file(tmp.path(), "packages/bar/AGENTS.md", "# Standalone agents");

        let config = RulesDiscoveryConfig {
            project_root: tmp.path().to_path_buf(),
            discover_standalone_files: true,
            ..Default::default()
        };
        let results = discover_rules_files(&config);
        assert_eq!(results.len(), 1);
        assert_eq!(results[0].relative_path, "packages/bar/AGENTS.md");
        assert!(results[0].is_standalone);
    }

    #[test]
    fn skips_standalone_when_disabled() {
        let tmp = setup();
        write_file(tmp.path(), "packages/foo/CLAUDE.md", "# Should not find");
        write_file(
            tmp.path(),
            "packages/foo/.claude/CLAUDE.md",
            "# Should find",
        );

        let config = RulesDiscoveryConfig {
            project_root: tmp.path().to_path_buf(),
            discover_standalone_files: false,
            ..Default::default()
        };
        let results = discover_rules_files(&config);
        assert_eq!(results.len(), 1);
        assert_eq!(
            results[0].relative_path,
            "packages/foo/.claude/CLAUDE.md"
        );
    }

    #[test]
    fn discovers_both_agent_dir_and_standalone() {
        let tmp = setup();
        write_file(
            tmp.path(),
            "packages/foo/.claude/CLAUDE.md",
            "# Agent dir",
        );
        write_file(tmp.path(), "packages/bar/AGENTS.md", "# Standalone");

        let results = discover_rules_files(&make_config_exclude_root(tmp.path()));
        assert_eq!(results.len(), 2);
    }

    // -- exclude_root_level --

    #[test]
    fn excludes_root_level_by_default() {
        let tmp = setup();
        write_file(tmp.path(), ".claude/CLAUDE.md", "# Root (should skip)");
        write_file(
            tmp.path(),
            "packages/foo/.claude/CLAUDE.md",
            "# Nested (should find)",
        );

        let results = discover_rules_files(&make_config_exclude_root(tmp.path()));
        assert_eq!(results.len(), 1);
        assert_eq!(
            results[0].relative_path,
            "packages/foo/.claude/CLAUDE.md"
        );
    }

    #[test]
    fn includes_root_when_not_excluded() {
        let tmp = setup();
        write_file(tmp.path(), ".claude/CLAUDE.md", "# Root");
        write_file(
            tmp.path(),
            "packages/foo/.claude/CLAUDE.md",
            "# Nested",
        );

        let results = discover_rules_files(&make_config(tmp.path()));
        assert_eq!(results.len(), 2);
    }

    #[test]
    fn excludes_root_standalone_when_excluded() {
        let tmp = setup();
        write_file(tmp.path(), "CLAUDE.md", "# Root standalone");
        write_file(tmp.path(), "packages/foo/CLAUDE.md", "# Nested standalone");

        let config = RulesDiscoveryConfig {
            project_root: tmp.path().to_path_buf(),
            discover_standalone_files: true,
            ..Default::default()
        };
        let results = discover_rules_files(&config);
        assert_eq!(results.len(), 1);
        assert_eq!(results[0].relative_path, "packages/foo/CLAUDE.md");
    }

    // -- Exclusions and edge cases --

    #[test]
    fn skips_node_modules() {
        let tmp = setup();
        write_file(
            tmp.path(),
            "node_modules/some-pkg/.claude/CLAUDE.md",
            "# Should not find",
        );
        write_file(
            tmp.path(),
            "packages/foo/.claude/CLAUDE.md",
            "# Should find",
        );

        let results = discover_rules_files(&make_config_exclude_root(tmp.path()));
        assert_eq!(results.len(), 1);
        assert_eq!(
            results[0].relative_path,
            "packages/foo/.claude/CLAUDE.md"
        );
    }

    #[test]
    fn skips_git_directory() {
        let tmp = setup();
        write_file(
            tmp.path(),
            ".git/hooks/.claude/CLAUDE.md",
            "# Should not find",
        );

        let results = discover_rules_files(&make_config_exclude_root(tmp.path()));
        assert_eq!(results.len(), 0);
    }

    #[test]
    fn does_not_discover_rules_md() {
        let tmp = setup();
        write_file(tmp.path(), ".claude/RULES.md", "# Should not find");
        write_file(tmp.path(), "packages/foo/.claude/RULES.md", "# Should not find");

        let results = discover_rules_files(&make_config(tmp.path()));
        assert_eq!(results.len(), 0);
    }

    #[test]
    fn does_not_discover_general_md_files() {
        let tmp = setup();
        write_file(tmp.path(), ".claude/README.md", "# Should not find");
        write_file(tmp.path(), ".claude/SYSTEM.md", "# Should not find");

        let results = discover_rules_files(&make_config(tmp.path()));
        assert_eq!(results.len(), 0);
    }

    #[test]
    fn returns_empty_when_no_context_files() {
        let tmp = setup();
        write_file(tmp.path(), "src/index.ts", "export {};");

        let results = discover_rules_files(&make_config_exclude_root(tmp.path()));
        assert_eq!(results.len(), 0);
    }

    #[test]
    fn respects_max_depth() {
        let tmp = setup();
        write_file(
            tmp.path(),
            "a/b/c/d/e/.claude/CLAUDE.md",
            "# Very deep",
        );
        write_file(tmp.path(), "a/.claude/CLAUDE.md", "# Shallow");

        let config = RulesDiscoveryConfig {
            project_root: tmp.path().to_path_buf(),
            max_depth: 2,
            ..Default::default()
        };
        let results = discover_rules_files(&config);
        assert_eq!(results.len(), 1);
        assert_eq!(results[0].relative_path, "a/.claude/CLAUDE.md");
    }

    #[test]
    fn populates_file_metadata_correctly() {
        let tmp = setup();
        let content = "# Rule content\n\nSome body text.";
        write_file(
            tmp.path(),
            "packages/foo/.claude/CLAUDE.md",
            content,
        );

        let results = discover_rules_files(&make_config_exclude_root(tmp.path()));
        assert_eq!(results.len(), 1);
        assert_eq!(results[0].content, content);
        assert_eq!(results[0].size_bytes, content.len() as u64);
        assert_eq!(
            results[0].path,
            tmp.path().join("packages/foo/.claude/CLAUDE.md")
        );
    }

    #[test]
    fn raw_content_no_frontmatter_stripping() {
        let tmp = setup();
        let content = "---\nkey: value\n---\n\n# Rule title\n\nRule body";
        write_file(
            tmp.path(),
            "packages/foo/.claude/CLAUDE.md",
            content,
        );

        let results = discover_rules_files(&make_config_exclude_root(tmp.path()));
        assert_eq!(results[0].content, content);
        assert!(results[0].content.contains("---"));
    }

    #[test]
    fn discovers_multiple_files_in_same_agent_dir() {
        let tmp = setup();
        write_file(
            tmp.path(),
            "packages/foo/.claude/CLAUDE.md",
            "# Claude",
        );
        write_file(
            tmp.path(),
            "packages/foo/.claude/AGENTS.md",
            "# Agents",
        );

        let results = discover_rules_files(&make_config_exclude_root(tmp.path()));
        assert_eq!(results.len(), 2);
    }

    #[test]
    fn discovers_files_across_multiple_agent_dirs() {
        let tmp = setup();
        write_file(
            tmp.path(),
            "packages/foo/.claude/CLAUDE.md",
            "# Claude",
        );
        write_file(
            tmp.path(),
            "packages/foo/.tron/AGENTS.md",
            "# Tron Agents",
        );

        let results = discover_rules_files(&make_config_exclude_root(tmp.path()));
        assert_eq!(results.len(), 2);
        assert!(results.iter().all(|r| r.scope_dir == "packages/foo"));
    }

    #[test]
    fn deduplicates_on_case_insensitive_filesystem() {
        let tmp = setup();
        write_file(tmp.path(), "packages/foo/.claude/CLAUDE.md", "# Test");

        let results = discover_rules_files(&make_config(tmp.path()));
        let unique_paths: HashSet<_> = results.iter().map(|r| &r.path).collect();
        assert_eq!(unique_paths.len(), results.len());
    }

    // -- compute_scope_dir unit tests --

    #[test]
    fn scope_dir_root_agent_dir() {
        assert_eq!(compute_scope_dir(".claude/CLAUDE.md", false), "");
    }

    #[test]
    fn scope_dir_nested_agent_dir() {
        assert_eq!(
            compute_scope_dir("packages/foo/.claude/CLAUDE.md", false),
            "packages/foo"
        );
    }

    #[test]
    fn scope_dir_deeply_nested_agent_dir() {
        assert_eq!(
            compute_scope_dir("a/b/c/.tron/AGENTS.md", false),
            "a/b/c"
        );
    }

    #[test]
    fn scope_dir_standalone_root() {
        assert_eq!(compute_scope_dir("CLAUDE.md", true), "");
    }

    #[test]
    fn scope_dir_standalone_nested() {
        assert_eq!(compute_scope_dir("packages/foo/CLAUDE.md", true), "packages/foo");
    }
}
