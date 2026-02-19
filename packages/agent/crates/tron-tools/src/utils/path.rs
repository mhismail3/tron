//! Path resolution utilities.
//!
//! Resolves relative paths against a working directory and expands `~` to the
//! user's home directory.

use std::path::{Path, PathBuf};

/// Resolve a file path against a working directory.
///
/// - Absolute paths are returned unchanged.
/// - Relative paths are joined with `working_directory`.
pub fn resolve_path(file_path: &str, working_directory: &str) -> PathBuf {
    let path = Path::new(file_path);
    if path.is_absolute() {
        path.to_path_buf()
    } else {
        Path::new(working_directory).join(path)
    }
}

/// Expand `~` prefix to the user's home directory.
///
/// Only expands a leading `~/` or a bare `~`. Does not expand `~user` forms.
pub fn expand_home(path: &str) -> String {
    if path == "~" || path.starts_with("~/") {
        if let Some(home) = home_dir() {
            return path.replacen('~', &home, 1);
        }
    }
    path.to_owned()
}

fn home_dir() -> Option<String> {
    std::env::var("HOME").ok().or_else(dirs_fallback)
}

#[cfg(unix)]
fn dirs_fallback() -> Option<String> {
    None
}

#[cfg(not(unix))]
fn dirs_fallback() -> Option<String> {
    std::env::var("USERPROFILE").ok()
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
    fn expand_home_tilde() {
        // This test depends on HOME being set, which it is in CI and dev
        let result = expand_home("~/foo");
        assert!(!result.starts_with('~'));
        assert!(result.ends_with("/foo"));
    }

    #[test]
    fn expand_home_absolute_unchanged() {
        let result = expand_home("/absolute/path");
        assert_eq!(result, "/absolute/path");
    }
}
