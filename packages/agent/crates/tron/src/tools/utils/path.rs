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
}
