//! Canonical home directory and path resolution utilities.
//!
//! All call sites that need `$HOME` or `~/.tron` should use these functions
//! to ensure consistent fallback behavior when `$HOME` is unset.

use std::path::PathBuf;

/// Fallback when `$HOME` is not set.
///
/// Uses a fixed path under the owner's tron workspace so that files
/// created by a headless/launchd process still land somewhere sensible
/// rather than polluting `/tmp`.
const FALLBACK_HOME: &str = "/Users/moose/.tron/system";

/// Get the user's home directory, falling back to [`FALLBACK_HOME`] if `$HOME` is unset.
pub fn home_dir() -> String {
    std::env::var("HOME").unwrap_or_else(|_| FALLBACK_HOME.to_string())
}

/// Get the `~/.tron` directory path.
pub fn tron_home() -> PathBuf {
    PathBuf::from(home_dir()).join(".tron")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn home_dir_returns_env_var() {
        // HOME is always set in test environments
        let home = std::env::var("HOME").unwrap();
        assert_eq!(home_dir(), home);
    }

    #[test]
    fn tron_home_appends_dot_tron() {
        let home = home_dir();
        assert_eq!(tron_home(), PathBuf::from(home).join(".tron"));
    }

    #[test]
    fn tron_home_returns_pathbuf() {
        let result = tron_home();
        // Verify it's a PathBuf (compile-time check) and ends with .tron
        assert!(result.to_string_lossy().ends_with(".tron"));
    }
}
