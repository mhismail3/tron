use std::path::{Path, PathBuf};

/// A loaded rules file with its metadata.
#[derive(Clone, Debug)]
pub struct RulesFile {
    pub path: PathBuf,
    pub content: String,
    pub scope: RulesScope,
}

/// Where the rules file applies.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum RulesScope {
    /// Applies to the entire project (root-level CLAUDE.md, AGENTS.md).
    Global,
    /// Applies to a specific directory subtree.
    Directory(PathBuf),
}

/// Names that are recognized as rules files.
/// Only use uppercase variants — macOS HFS+ is case-insensitive,
/// so "CLAUDE.md" already matches "claude.md".
const RULES_FILENAMES: &[&str] = &["CLAUDE.md", "AGENTS.md"];

/// Directories that may contain rules files.
const RULES_DIRS: &[&str] = &[".claude", ".tron", ".agent"];

/// Directories to skip during traversal.
const SKIP_DIRS: &[&str] = &[
    "node_modules",
    ".git",
    "target",
    "dist",
    "build",
    ".next",
    "__pycache__",
    "vendor",
];

/// Maximum directory depth for rules discovery.
const MAX_DEPTH: usize = 10;

/// Discover and load all rules files for a project.
pub fn load_rules(project_root: &Path) -> Vec<RulesFile> {
    let mut rules = Vec::new();

    // 1. Check root-level standalone files
    for filename in RULES_FILENAMES {
        let path = project_root.join(filename);
        if let Some(rf) = try_load(&path, RulesScope::Global) {
            rules.push(rf);
        }
    }

    // 2. Check root-level .claude/, .tron/, .agent/ dirs
    for dir in RULES_DIRS {
        let dir_path = project_root.join(dir);
        for filename in RULES_FILENAMES {
            let path = dir_path.join(filename);
            if let Some(rf) = try_load(&path, RulesScope::Global) {
                rules.push(rf);
            }
        }
    }

    // 3. Walk subdirectories for scoped rules
    walk_directory(project_root, project_root, 0, &mut rules);

    rules
}

/// Load dynamic rules from .claude/rules/*.md and .tron/rules/*.md.
pub fn load_dynamic_rules(project_root: &Path) -> Vec<RulesFile> {
    let mut rules = Vec::new();
    let search_dirs = [
        project_root.join(".claude").join("rules"),
        project_root.join(".tron").join("rules"),
    ];

    for dir in &search_dirs {
        if !dir.is_dir() {
            continue;
        }
        if let Ok(entries) = std::fs::read_dir(dir) {
            for entry in entries.flatten() {
                let path = entry.path();
                if path.extension().is_some_and(|e| e == "md") {
                    // Scope is derived from the filename (convention: filename matches path pattern)
                    if let Some(rf) = try_load(&path, RulesScope::Global) {
                        rules.push(rf);
                    }
                }
            }
        }
    }

    rules
}

/// Format rules files into a system prompt section.
pub fn format_rules(rules: &[RulesFile]) -> Option<String> {
    if rules.is_empty() {
        return None;
    }

    let mut parts = vec!["# Project Rules\n".to_string()];
    for rule in rules {
        let scope_label = match &rule.scope {
            RulesScope::Global => "global".to_string(),
            RulesScope::Directory(p) => format!("scoped: {}", p.display()),
        };
        parts.push(format!(
            "## {} ({})\n\n{}",
            rule.path.file_name().unwrap_or_default().to_string_lossy(),
            scope_label,
            rule.content,
        ));
    }

    Some(parts.join("\n\n"))
}

fn try_load(path: &Path, scope: RulesScope) -> Option<RulesFile> {
    let content = std::fs::read_to_string(path).ok()?;
    if content.trim().is_empty() {
        return None;
    }
    Some(RulesFile {
        path: path.to_path_buf(),
        content,
        scope,
    })
}

fn walk_directory(
    root: &Path,
    dir: &Path,
    depth: usize,
    rules: &mut Vec<RulesFile>,
) {
    if depth >= MAX_DEPTH {
        return;
    }

    let entries = match std::fs::read_dir(dir) {
        Ok(e) => e,
        Err(_) => return,
    };

    for entry in entries.flatten() {
        let path = entry.path();
        if !path.is_dir() {
            continue;
        }

        let name = match path.file_name().and_then(|n| n.to_str()) {
            Some(n) => n.to_string(),
            None => continue,
        };

        if SKIP_DIRS.contains(&name.as_str()) {
            continue;
        }

        // Skip the root-level special dirs (already handled above)
        if depth == 0 && RULES_DIRS.contains(&name.as_str()) {
            continue;
        }

        let scope = RulesScope::Directory(
            path.strip_prefix(root).unwrap_or(&path).to_path_buf(),
        );

        // Check for rules files in this subdirectory
        for filename in RULES_FILENAMES {
            let file_path = path.join(filename);
            if let Some(rf) = try_load(&file_path, scope.clone()) {
                rules.push(rf);
            }
        }

        // Check for rules in .claude/, .tron/, .agent/ subdirs
        for rules_dir in RULES_DIRS {
            let sub_dir = path.join(rules_dir);
            for filename in RULES_FILENAMES {
                let file_path = sub_dir.join(filename);
                if let Some(rf) = try_load(&file_path, scope.clone()) {
                    rules.push(rf);
                }
            }
        }

        // Recurse
        walk_directory(root, &path, depth + 1, rules);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    fn temp_dir() -> PathBuf {
        let dir = std::env::temp_dir().join(format!("tron_rules_test_{}", uuid::Uuid::now_v7()));
        fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn load_root_claude_md() {
        let dir = temp_dir();
        fs::write(dir.join("CLAUDE.md"), "# Rules\nUse Rust.").unwrap();

        let rules = load_rules(&dir);
        assert_eq!(rules.len(), 1);
        assert_eq!(rules[0].scope, RulesScope::Global);
        assert!(rules[0].content.contains("Use Rust"));

        fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn load_dot_claude_dir() {
        let dir = temp_dir();
        let claude_dir = dir.join(".claude");
        fs::create_dir_all(&claude_dir).unwrap();
        fs::write(claude_dir.join("CLAUDE.md"), "# .claude rules").unwrap();

        let rules = load_rules(&dir);
        assert_eq!(rules.len(), 1);
        assert!(rules[0].content.contains(".claude rules"));

        fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn load_scoped_rules() {
        let dir = temp_dir();
        let sub = dir.join("packages").join("agent");
        fs::create_dir_all(&sub).unwrap();
        fs::write(sub.join("CLAUDE.md"), "# Agent rules").unwrap();

        let rules = load_rules(&dir);
        assert_eq!(rules.len(), 1);
        assert_eq!(
            rules[0].scope,
            RulesScope::Directory(PathBuf::from("packages/agent"))
        );

        fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn skip_node_modules() {
        let dir = temp_dir();
        let nm = dir.join("node_modules").join("pkg");
        fs::create_dir_all(&nm).unwrap();
        fs::write(nm.join("CLAUDE.md"), "# should be skipped").unwrap();

        let rules = load_rules(&dir);
        assert!(rules.is_empty());

        fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn empty_files_skipped() {
        let dir = temp_dir();
        fs::write(dir.join("CLAUDE.md"), "").unwrap();
        fs::write(dir.join("AGENTS.md"), "   \n  ").unwrap();

        let rules = load_rules(&dir);
        assert!(rules.is_empty());

        fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn format_rules_output() {
        let rules = vec![RulesFile {
            path: PathBuf::from("/project/CLAUDE.md"),
            content: "Use Rust.".into(),
            scope: RulesScope::Global,
        }];
        let formatted = format_rules(&rules).unwrap();
        assert!(formatted.contains("# Project Rules"));
        assert!(formatted.contains("CLAUDE.md"));
        assert!(formatted.contains("global"));
        assert!(formatted.contains("Use Rust."));
    }

    #[test]
    fn format_empty_rules_returns_none() {
        assert!(format_rules(&[]).is_none());
    }

    #[test]
    fn load_dynamic_rules() {
        let dir = temp_dir();
        let rules_dir = dir.join(".claude").join("rules");
        fs::create_dir_all(&rules_dir).unwrap();
        fs::write(rules_dir.join("testing.md"), "Always write tests.").unwrap();
        fs::write(rules_dir.join("naming.md"), "Use snake_case.").unwrap();

        let rules = super::load_dynamic_rules(&dir);
        assert_eq!(rules.len(), 2);

        fs::remove_dir_all(&dir).ok();
    }
}
