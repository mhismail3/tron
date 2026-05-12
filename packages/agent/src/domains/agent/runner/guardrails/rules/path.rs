//! Path rule: protects filesystem paths with glob patterns.
//!
//! Supports:
//! - Protected path matching (glob patterns)
//! - Path traversal detection (`..` sequences)
//! - Hidden directory creation blocking
//! - process::run command path extraction (detects writes to protected paths)

use std::path::{Path, PathBuf};

use regex::Regex;

use crate::domains::agent::runner::guardrails::types::{EvaluationContext, RuleEvaluationResult};

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
            let Some(serde_json::Value::String(value)) = ctx.tool_arguments.get(arg_name.as_str())
            else {
                continue;
            };

            // For process commands, extract paths from the command string
            if arg_name == "command" {
                if self.check_process_command_for_paths(value, &homedir) {
                    return RuleEvaluationResult::triggered(
                        &self.base.id,
                        self.base.severity,
                        format!("{}: Command would modify protected path", self.base.name),
                    )
                    .with_details(serde_json::json!({
                        "command": crate::shared::text::truncate_str(value, 200)
                    }));
                }
                // For process, also check hidden mkdir
                if self.block_hidden && has_hidden_mkdir(value) {
                    return RuleEvaluationResult::triggered(
                        &self.base.id,
                        self.base.severity,
                        format!("{}: Hidden paths not allowed", self.base.name),
                    )
                    .with_details(
                        serde_json::json!({ "command": crate::shared::text::truncate_str(value, 200) }),
                    );
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
            if self.block_hidden
                && let Some(basename) = Path::new(value).file_name().and_then(|n| n.to_str())
                && basename.starts_with('.')
            {
                return RuleEvaluationResult::triggered(
                    &self.base.id,
                    self.base.severity,
                    format!("{}: Hidden paths not allowed", self.base.name),
                )
                .with_details(serde_json::json!({ "path": value }));
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

    /// Check if a process command would write to protected paths.
    ///
    /// Hardening:
    /// - Write-operation regexes are compiled once via `std::sync::OnceLock`
    ///   instead of `Regex::new` per (protected_path × pattern) — a 5N
    ///   regex-compilation cost on every process command pre-fix where N was
    ///   the protected-paths list size.
    /// - A `MAX_COMMAND_LEN_FOR_REGEX` cap short-circuits pathological
    ///   inputs (multi-MB heredocs or pasted payloads) to "deny" before the
    ///   regex engine burns CPU on a worst-case scan. Treating oversized
    ///   process commands as protected-path writes is fail-safe: the command
    ///   is already suspicious, and the alternative (bypass) is a
    ///   hardening hole.
    fn check_process_command_for_paths(&self, command: &str, homedir: &str) -> bool {
        if command.len() > MAX_COMMAND_LEN_FOR_REGEX {
            tracing::warn!(
                command_len = command.len(),
                limit = MAX_COMMAND_LEN_FOR_REGEX,
                "process command exceeds regex budget; treating as protected-path write (fail-safe)"
            );
            return true;
        }

        let patterns = write_patterns();

        for protected_path in &self.protected_paths {
            let expanded_protected = expand_home(protected_path, homedir)
                .trim_end_matches("**")
                .to_string();
            let normalized_protected = normalize_path(&expanded_protected);

            for pattern in patterns {
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

/// Maximum process command length subjected to full regex scanning.
/// Above this, the rule fails-safe to "protected-path write detected".
/// 64 KB comfortably covers any realistic interactive command; longer
/// inputs are almost always pasted heredocs, base64 blobs, or
/// pathological inputs.
const MAX_COMMAND_LEN_FOR_REGEX: usize = 64 * 1024;

/// Return a shared, one-time-compiled slice of the write-operation regexes.
///
/// Pre-fix these were recompiled per (protected_path × pattern) on every
/// process-command evaluation, so a 100-path protected list meant 500 regex
/// compiles per command.
fn write_patterns() -> &'static [Regex] {
    use std::sync::OnceLock;
    static PATTERNS: OnceLock<Vec<Regex>> = OnceLock::new();
    PATTERNS.get_or_init(|| {
        // All patterns are compile-time constants. A failure here is a
        // developer bug — silently skipping a broken guardrail regex would
        // quietly lose a security check, so panic so tests catch it.
        [
            r">>\s*([^\s;|&]+)",
            r">\s*([^\s;|&]+)",
            r"tee\s+(?:-a\s+)?([^\s;|&]+)",
            r"(?:cp|mv)\s+[^\s]+\s+([^\s;|&]+)",
            r"rm\s+(?:-rf?\s+)?([^\s;|&]+)",
        ]
        .iter()
        .map(|p| {
            Regex::new(p).unwrap_or_else(|e| {
                panic!("guardrails write-pattern regex failed to compile: pattern={p:?} error={e}")
            })
        })
        .collect()
    })
}

/// Check if a process command contains `mkdir` targeting a hidden directory.
fn has_hidden_mkdir(command: &str) -> bool {
    let Ok(pattern) = Regex::new(r"mkdir\s+(?:-p\s+)?(\S+)") else {
        return false;
    };
    for caps in pattern.captures_iter(command) {
        if let Some(dir) = caps.get(1).map(|m| m.as_str()) {
            // Check if the last component starts with .
            if let Some(basename) = Path::new(dir).file_name().and_then(|n| n.to_str())
                && basename.starts_with('.')
            {
                return true;
            }
        }
    }
    false
}

/// Check if `test_path` is within `protected_path`.
///
/// Handles `**` glob suffixes by stripping them before comparison.
///
/// INVARIANT (L14, trusted-local): this compares **lexical paths** via
/// [`normalize_path`] — it does NOT resolve symlinks. A symlink
/// `/tmp/bypass -> /Users/me/.tron/internal` outside any protected-path
/// prefix will slip past the check even though a write through the
/// symlink ends up inside the protected path.
///
/// Under the trusted-local threat model this is acceptable: the agent
/// is running as the user, any symlink the user plants is already in
/// their own filesystem, and every realistic protected-path hit goes
/// through the string form anyway. If the threat model ever changes
/// (multi-tenant host, adversarial working directory), switch to
/// `std::fs::canonicalize` before the prefix check — guard against
/// canonicalize failure (non-existent targets) by keeping the lexical
/// recovery behavior.
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
    crate::shared::paths::home_dir()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_is_path_within_exact() {
        assert!(is_path_within(
            "/Users/test/.tron/internal",
            "/Users/test/.tron/internal"
        ));
    }

    #[test]
    fn test_is_path_within_child() {
        assert!(is_path_within(
            "/Users/test/.tron/internal/database/tron.sqlite",
            "/Users/test/.tron/internal"
        ));
    }

    #[test]
    fn test_is_path_within_glob() {
        assert!(is_path_within(
            "/Users/test/.tron/internal/database/tron.sqlite",
            "/Users/test/.tron/internal/**"
        ));
    }

    #[test]
    fn test_is_path_not_within() {
        assert!(!is_path_within(
            "/Users/test/projects/foo.js",
            "/Users/test/.tron/internal"
        ));
    }

    #[test]
    fn test_is_path_partial_prefix_not_within() {
        assert!(!is_path_within(
            "/Users/test/.tron/systems/other",
            "/Users/test/.tron/internal"
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

    // ── Regex budget ────────────────────────────────────────────────────────

    fn make_path_rule(protected: Vec<String>) -> PathRule {
        use crate::domains::agent::runner::guardrails::rules::{RuleTier, Scope};
        use crate::domains::agent::runner::guardrails::types::Severity;
        PathRule {
            base: RuleBase {
                id: "test".into(),
                name: "test".into(),
                description: "test".into(),
                severity: Severity::Block,
                scope: Scope::Global,
                tier: RuleTier::Custom,
                capabilities: Vec::new(),
                priority: 0,
                enabled: true,
                tags: Vec::new(),
            },
            path_arguments: vec!["command".into()],
            protected_paths: protected,
            block_traversal: false,
            block_hidden: false,
        }
    }

    #[test]
    fn process_command_under_limit_is_scanned_normally() {
        let rule = make_path_rule(vec!["/home/user/.tron".into()]);
        // Below cap, not in protected path → not triggered.
        assert!(!rule.check_process_command_for_paths("echo hello > /tmp/a", "/home/user"));
        // Below cap, inside protected path → triggered.
        assert!(rule.check_process_command_for_paths("echo x > /home/user/.tron/a", "/home/user"));
    }

    #[test]
    fn process_command_over_limit_fails_safe_to_triggered() {
        // A pasted multi-MB command must not be scanned character-by-
        // character against N×5 regexes. The rule fails safe to "writes
        // protected path" so the command is blocked without burning CPU.
        let rule = make_path_rule(vec!["/home/user/.tron".into()]);
        let huge = "x".repeat(MAX_COMMAND_LEN_FOR_REGEX + 1);
        assert!(rule.check_process_command_for_paths(&huge, "/home/user"));
    }

    #[test]
    fn process_command_at_exact_limit_is_still_scanned() {
        // Boundary-inclusive: a command exactly at the cap is scanned
        // normally. Only inputs STRICTLY larger than the cap fail-safe.
        let rule = make_path_rule(vec!["/home/user/.tron".into()]);
        let at_limit = "x".repeat(MAX_COMMAND_LEN_FOR_REGEX);
        // Benign content at the exact limit → not protected.
        assert!(!rule.check_process_command_for_paths(&at_limit, "/home/user"));
    }

    #[test]
    fn write_patterns_are_compiled_only_once() {
        // Regression guard: repeated calls return the same underlying slice
        // (OnceLock memoization). Previously every call to
        // check_process_command_for_paths recompiled the 5 regexes.
        let first = write_patterns().as_ptr();
        let second = write_patterns().as_ptr();
        assert_eq!(first, second, "regex vector should be the same allocation");
    }

    #[test]
    fn write_patterns_loaded_five() {
        // Pin the expected pattern count so silent additions/removals of
        // write-detection regexes surface as a test failure.
        assert_eq!(write_patterns().len(), 5);
    }
}
