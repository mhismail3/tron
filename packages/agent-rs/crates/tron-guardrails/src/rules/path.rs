//! Path rule: protects filesystem paths with glob patterns.
//!
//! Supports:
//! - Protected path matching (glob patterns)
//! - Path traversal detection (`..` sequences)
//! - Hidden directory creation blocking
//! - Bash command path extraction (detects writes to protected paths)

use std::path::{Path, PathBuf};

use regex::Regex;

use crate::types::{EvaluationContext, RuleEvaluationResult};

use super::RuleBase;

/// A rule that protects filesystem paths.
#[derive(Debug)]
pub struct PathRule {
    /// Common rule fields.
    pub base: RuleBase,
    /// Which arguments contain paths to check (e.g., `file_path`, `command`).
    pub path_arguments: Vec<String>,
    /// Protected path patterns (absolute paths, may use `**` suffix).
    pub protected_paths: Vec<String>,
    /// Block path traversal (`..` sequences).
    pub block_traversal: bool,
    /// Block hidden paths (starting with `.`).
    pub block_hidden: bool,
}

impl PathRule {
    /// Evaluate this path rule against the context.
    pub fn evaluate(&self, ctx: &EvaluationContext) -> RuleEvaluationResult {
        let homedir = home_dir();

        for arg_name in &self.path_arguments {
            let Some(serde_json::Value::String(value)) =
                ctx.tool_arguments.get(arg_name.as_str())
            else {
                continue;
            };

            // For bash commands, extract paths from the command string
            if arg_name == "command" {
                if self.check_bash_command_for_paths(value, &homedir) {
                    return RuleEvaluationResult::triggered(
                        &self.base.id,
                        self.base.severity,
                        format!("{}: Command would modify protected path", self.base.name),
                    )
                    .with_details(serde_json::json!({
                        "command": tron_core::text::truncate_str(value, 200)
                    }));
                }
                // For bash, also check hidden mkdir
                if self.block_hidden && has_hidden_mkdir(value) {
                    return RuleEvaluationResult::triggered(
                        &self.base.id,
                        self.base.severity,
                        format!("{}: Hidden paths not allowed", self.base.name),
                    )
                    .with_details(serde_json::json!({ "command": tron_core::text::truncate_str(value, 200) }));
                }
                continue;
            }

            // Check path traversal
            if self.block_traversal && value.contains("..") {
                return RuleEvaluationResult::triggered(
                    &self.base.id,
                    self.base.severity,
                    format!("{}: Path traversal not allowed", self.base.name),
                )
                .with_details(serde_json::json!({ "path": value }));
            }

            // Check hidden paths
            if self.block_hidden {
                if let Some(basename) = Path::new(value).file_name().and_then(|n| n.to_str()) {
                    if basename.starts_with('.') {
                        return RuleEvaluationResult::triggered(
                            &self.base.id,
                            self.base.severity,
                            format!("{}: Hidden paths not allowed", self.base.name),
                        )
                        .with_details(serde_json::json!({ "path": value }));
                    }
                }
            }

            // Check protected paths
            let absolute_value = to_absolute_path(value, &homedir);

            for protected_path in &self.protected_paths {
                let expanded = expand_home(protected_path, &homedir);
                if is_path_within(&absolute_value, &expanded) {
                    return RuleEvaluationResult::triggered(
                        &self.base.id,
                        self.base.severity,
                        format!("{}: Cannot modify protected path", self.base.name),
                    )
                    .with_details(serde_json::json!({
                        "path": value,
                        "protectedPath": protected_path,
                    }));
                }
            }
        }

        RuleEvaluationResult::not_triggered(&self.base.id)
    }

    /// Check if a bash command would write to protected paths.
    fn check_bash_command_for_paths(&self, command: &str, homedir: &str) -> bool {
        // Regex patterns for common write operations that capture target paths
        let write_patterns: &[&str] = &[
            r">>\s*([^\s;|&]+)",
            r">\s*([^\s;|&]+)",
            r"tee\s+(?:-a\s+)?([^\s;|&]+)",
            r"(?:cp|mv)\s+[^\s]+\s+([^\s;|&]+)",
            r"rm\s+(?:-rf?\s+)?([^\s;|&]+)",
        ];

        for protected_path in &self.protected_paths {
            let expanded_protected = expand_home(protected_path, homedir)
                .trim_end_matches("**")
                .to_string();
            let normalized_protected = normalize_path(&expanded_protected);

            for pattern_str in write_patterns {
                let Ok(pattern) = Regex::new(pattern_str) else {
                    continue;
                };
                for caps in pattern.captures_iter(command) {
                    let Some(target_path) = caps.get(1).map(|m| m.as_str()) else {
                        continue;
                    };

                    // Expand ~ in the target path
                    let expanded_target = if target_path.starts_with('~') {
                        target_path.replacen('~', homedir, 1)
                    } else {
                        target_path.to_string()
                    };

                    let normalized_target = if Path::new(&expanded_target).is_absolute() {
                        normalize_path(&expanded_target)
                    } else {
                        expanded_target.clone()
                    };

                    // Check if target is within protected path
                    if normalized_target.starts_with(&normalized_protected) {
                        return true;
                    }

                    // Also check for literal .tron references
                    if target_path.contains(".tron") || expanded_target.contains(".tron") {
                        return true;
                    }
                }
            }
        }

        false
    }
}

/// Check if a bash command contains `mkdir` targeting a hidden directory.
fn has_hidden_mkdir(command: &str) -> bool {
    let Ok(pattern) = Regex::new(r"mkdir\s+(?:-p\s+)?(\S+)") else {
        return false;
    };
    for caps in pattern.captures_iter(command) {
        if let Some(dir) = caps.get(1).map(|m| m.as_str()) {
            // Check if the last component starts with .
            if let Some(basename) = Path::new(dir).file_name().and_then(|n| n.to_str()) {
                if basename.starts_with('.') {
                    return true;
                }
            }
        }
    }
    false
}

/// Check if `test_path` is within `protected_path`.
///
/// Handles `**` glob suffixes by stripping them before comparison.
fn is_path_within(test_path: &str, protected_path: &str) -> bool {
    let effective = protected_path.trim_end_matches("**");
    let effective = effective.trim_end_matches('/');

    let normalized = normalize_path(test_path);
    let normalized_protected = normalize_path(effective);

    normalized == normalized_protected
        || normalized.starts_with(&format!("{normalized_protected}/"))
}

/// Expand `~` to the home directory.
fn expand_home(path: &str, homedir: &str) -> String {
    if path.starts_with('~') {
        path.replacen('~', homedir, 1)
    } else {
        path.to_string()
    }
}

/// Convert a path to absolute, expanding `~`.
fn to_absolute_path(path: &str, homedir: &str) -> String {
    let expanded = expand_home(path, homedir);
    if Path::new(&expanded).is_absolute() {
        normalize_path(&expanded)
    } else {
        // Relative paths: resolve against CWD
        let cwd = std::env::current_dir()
            .map(|p| p.to_string_lossy().into_owned())
            .unwrap_or_default();
        normalize_path(&format!("{cwd}/{expanded}"))
    }
}

/// Normalize a path by resolving `.` and `..` components.
fn normalize_path(path: &str) -> String {
    use std::path::Component;
    let mut parts: Vec<&std::ffi::OsStr> = Vec::new();
    for component in Path::new(path).components() {
        match component {
            Component::ParentDir => {
                let _ = parts.pop();
            }
            Component::CurDir => {}
            Component::RootDir => {
                parts.clear();
                parts.push(component.as_os_str());
            }
            _ => {
                parts.push(component.as_os_str());
            }
        }
    }
    if parts.is_empty() {
        return "/".to_string();
    }
    let p: PathBuf = parts.into_iter().collect();
    p.to_string_lossy().into_owned()
}

/// Get the home directory.
fn home_dir() -> String {
    std::env::var("HOME").unwrap_or_else(|_| "/root".to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_is_path_within_exact() {
        assert!(is_path_within("/Users/test/.tron/app", "/Users/test/.tron/app"));
    }

    #[test]
    fn test_is_path_within_child() {
        assert!(is_path_within(
            "/Users/test/.tron/app/server.js",
            "/Users/test/.tron/app"
        ));
    }

    #[test]
    fn test_is_path_within_glob() {
        assert!(is_path_within(
            "/Users/test/.tron/app/server.js",
            "/Users/test/.tron/app/**"
        ));
    }

    #[test]
    fn test_is_path_not_within() {
        assert!(!is_path_within(
            "/Users/test/projects/foo.js",
            "/Users/test/.tron/app"
        ));
    }

    #[test]
    fn test_is_path_partial_prefix_not_within() {
        assert!(!is_path_within(
            "/Users/test/.tron/apps/other",
            "/Users/test/.tron/app"
        ));
    }

    #[test]
    fn test_has_hidden_mkdir() {
        assert!(has_hidden_mkdir("mkdir .hidden"));
        assert!(has_hidden_mkdir("mkdir -p /tmp/.secret"));
        assert!(!has_hidden_mkdir("mkdir visible"));
        assert!(!has_hidden_mkdir("ls -la"));
    }

    #[test]
    fn test_expand_home() {
        assert_eq!(expand_home("~/foo", "/home/user"), "/home/user/foo");
        assert_eq!(expand_home("/abs/path", "/home/user"), "/abs/path");
    }

    #[test]
    fn test_normalize_path() {
        assert_eq!(normalize_path("/foo/bar/../baz"), "/foo/baz");
        assert_eq!(normalize_path("/foo/./bar"), "/foo/bar");
    }
}
