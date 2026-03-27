//! Path resolution utilities.
//!
//! Resolves relative paths against a working directory and expands `~` to the
//! user's home directory.

use std::path::{Component, Path, PathBuf};

use tracing::warn;

/// Resolve a file path against a working directory.
///
/// - `~` and `~/...` are expanded to the user's home directory.
/// - Absolute paths are returned unchanged.
/// - Relative paths are joined with `working_directory`.
///
/// Note: `~otheruser/...` is NOT expanded (treated as a relative path).
pub fn resolve_path(file_path: &str, working_directory: &str) -> PathBuf {
    let expanded = if file_path == "~" || file_path.starts_with("~/") {
        let home = crate::core::paths::home_dir();
        file_path.replacen('~', &home, 1)
    } else {
        file_path.to_string()
    };
    let path = Path::new(&expanded);
    if path.is_absolute() {
        path.to_path_buf()
    } else {
        Path::new(working_directory).join(path)
    }
}

/// Log a warning if the resolved path contains `..` components.
///
/// This is defense-in-depth — the `path.traversal` guardrail is the primary
/// defense. This check provides audit visibility if guardrails are ever disabled.
/// It does NOT block the operation.
///
/// Limitation: symlinks that resolve outside the working directory are not caught.
pub fn warn_path_traversal(resolved: &Path, tool_name: &str) {
    let has_traversal = resolved
        .components()
        .any(|c| matches!(c, Component::ParentDir));
    if has_traversal {
        warn!(
            tool = tool_name,
            path = %resolved.display(),
            "path traversal detected in resolved path"
        );
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn resolve_absolute_path_unchanged() {
        let result = resolve_path("/usr/bin/ls", "/home/user");
        assert_eq!(result, PathBuf::from("/usr/bin/ls"));
    }

    #[test]
    fn resolve_relative_path_joined() {
        let result = resolve_path("src/main.rs", "/home/user/project");
        assert_eq!(result, PathBuf::from("/home/user/project/src/main.rs"));
    }

    #[test]
    fn resolve_dot_to_working_directory() {
        let result = resolve_path(".", "/home/user/project");
        assert_eq!(result, PathBuf::from("/home/user/project/."));
    }

    #[test]
    fn resolve_parent_reference() {
        let result = resolve_path("../foo", "/home/user/project");
        assert_eq!(result, PathBuf::from("/home/user/project/../foo"));
    }

    #[test]
    fn resolve_tilde_slash_expands() {
        let home = crate::core::paths::home_dir();
        let result = resolve_path("~/Documents/file.txt", "/work");
        assert_eq!(result, PathBuf::from(format!("{home}/Documents/file.txt")));
    }

    #[test]
    fn resolve_bare_tilde() {
        let home = crate::core::paths::home_dir();
        let result = resolve_path("~", "/work");
        assert_eq!(result, PathBuf::from(&home));
    }

    #[test]
    fn resolve_tilde_hidden_path() {
        let home = crate::core::paths::home_dir();
        let result = resolve_path("~/.config/app", "/work");
        assert_eq!(result, PathBuf::from(format!("{home}/.config/app")));
    }

    #[test]
    fn resolve_tilde_not_at_start_unchanged() {
        let result = resolve_path("some/~/path", "/work");
        assert_eq!(result, PathBuf::from("/work/some/~/path"));
    }

    #[test]
    fn resolve_tilde_user_not_expanded() {
        // ~otheruser/file does NOT start with ~/ and is NOT bare ~
        // so it's treated as a relative path
        let result = resolve_path("~otheruser/file", "/work");
        assert_eq!(result, PathBuf::from("/work/~otheruser/file"));
    }

    #[test]
    fn resolve_tilde_double_slash() {
        let home = crate::core::paths::home_dir();
        let result = resolve_path("~//file", "/work");
        assert_eq!(result, PathBuf::from(format!("{home}//file")));
    }

    // ── warn_path_traversal tests ───────────────────────────────

    use std::sync::Once;

    static INIT_TRACING: Once = Once::new();

    fn init_tracing() {
        INIT_TRACING.call_once(|| {
            let _ = tracing_subscriber::fmt().with_test_writer().try_init();
        });
    }

    #[test]
    fn traversal_detected_with_dotdot() {
        init_tracing();
        let path = Path::new("/home/user/project/../../../etc/passwd");
        // Should not panic; logs a warning (verified by test writer)
        warn_path_traversal(path, "Read");
    }

    #[test]
    fn no_traversal_absolute_path() {
        init_tracing();
        let path = Path::new("/etc/passwd");
        warn_path_traversal(path, "Read");
        // No warning emitted — just verifying no panic
    }

    #[test]
    fn no_traversal_relative_clean() {
        init_tracing();
        let path = Path::new("./foo/bar");
        warn_path_traversal(path, "Write");
    }

    #[test]
    fn traversal_stays_within_dir() {
        init_tracing();
        // foo/../bar stays within the same directory — conservative: still warns
        let path = Path::new("foo/../bar");
        warn_path_traversal(path, "Edit");
    }

    #[test]
    fn no_traversal_home_expansion() {
        init_tracing();
        let home = crate::core::paths::home_dir();
        let path = PathBuf::from(format!("{home}/some/path"));
        warn_path_traversal(&path, "Read");
    }

    #[test]
    fn traversal_only_dotdot() {
        init_tracing();
        let path = Path::new("..");
        warn_path_traversal(path, "Read");
    }

    #[test]
    fn traversal_empty_path() {
        init_tracing();
        let path = Path::new("");
        warn_path_traversal(path, "Read");
    }

    #[test]
    fn traversal_many_segments() {
        init_tracing();
        let path = Path::new("a/../b/../c/../d/../e/../f");
        warn_path_traversal(path, "Read");
    }
}
