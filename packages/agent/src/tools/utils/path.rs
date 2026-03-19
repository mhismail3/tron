//! Path resolution utilities.
//!
//! Resolves relative paths against a working directory and expands `~` to the
//! user's home directory.

use std::path::{Path, PathBuf};

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
}
