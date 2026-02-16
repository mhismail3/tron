//! Chrome binary discovery on macOS.

use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};

/// Known Chrome binary locations on macOS, in search priority order.
const KNOWN_PATHS: &[&str] = &[
    "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
    "/Applications/Chromium.app/Contents/MacOS/Chromium",
    "/Applications/Google Chrome Canary.app/Contents/MacOS/Google Chrome Canary",
    "/opt/homebrew/bin/chromium",
    "/usr/local/bin/chromium",
];

/// Find a Chrome or Chromium binary on the system.
///
/// Search order:
/// 1. `CHROME_PATH` environment variable
/// 2. System application paths (Chrome, Chromium, Chrome Canary)
/// 3. Homebrew paths
///
/// Returns `None` if no valid executable is found.
pub fn find_chrome() -> Option<PathBuf> {
    // 1. Environment variable override
    if let Ok(env_path) = std::env::var("CHROME_PATH") {
        let path = PathBuf::from(&env_path);
        if is_executable(&path) {
            return Some(path);
        }
        tracing::debug!(path = %env_path, "CHROME_PATH set but not executable, falling through");
    }

    // 2. Known system paths
    for candidate in KNOWN_PATHS {
        let path = PathBuf::from(candidate);
        if is_executable(&path) {
            tracing::debug!(path = %candidate, "found Chrome binary");
            return Some(path);
        }
    }

    None
}

/// Return the ordered list of candidate paths (excluding env var).
pub fn search_paths() -> Vec<PathBuf> {
    KNOWN_PATHS.iter().map(PathBuf::from).collect()
}

/// Check if a path exists and is executable.
fn is_executable(path: &Path) -> bool {
    path.is_file()
        && path
            .metadata()
            .map(|m| m.permissions().mode() & 0o111 != 0)
            .unwrap_or(false)
}

#[cfg(test)]
#[allow(unsafe_code)]
mod tests {
    use super::*;

    /// SAFETY: env var mutation is inherently racy in multi-threaded tests.
    /// These tests always restore the previous value.
    fn set_env(key: &str, val: &str) {
        unsafe { std::env::set_var(key, val) };
    }

    fn remove_env(key: &str) {
        unsafe { std::env::remove_var(key) };
    }

    fn restore_env(key: &str, prev: Option<String>) {
        match prev {
            Some(v) => set_env(key, &v),
            None => remove_env(key),
        }
    }

    #[test]
    fn find_chrome_respects_env_var() {
        let dir = tempfile::tempdir().unwrap();
        let fake_chrome = dir.path().join("chrome-test");
        std::fs::write(&fake_chrome, "#!/bin/sh\n").unwrap();
        std::fs::set_permissions(&fake_chrome, std::fs::Permissions::from_mode(0o755)).unwrap();

        let key = "CHROME_PATH";
        let prev = std::env::var(key).ok();
        set_env(key, fake_chrome.to_str().unwrap());

        let result = find_chrome();
        assert_eq!(result, Some(fake_chrome));

        restore_env(key, prev);
    }

    #[test]
    fn find_chrome_env_var_nonexistent_falls_through() {
        let key = "CHROME_PATH";
        let prev = std::env::var(key).ok();
        set_env(key, "/nonexistent/path/to/chrome");

        let result = find_chrome();
        if let Some(ref path) = result {
            assert_ne!(path.to_str().unwrap(), "/nonexistent/path/to/chrome");
        }

        restore_env(key, prev);
    }

    #[test]
    fn find_chrome_env_var_not_executable_falls_through() {
        let dir = tempfile::tempdir().unwrap();
        let not_exec = dir.path().join("not-exec");
        std::fs::write(&not_exec, "not a binary").unwrap();
        std::fs::set_permissions(&not_exec, std::fs::Permissions::from_mode(0o644)).unwrap();

        let key = "CHROME_PATH";
        let prev = std::env::var(key).ok();
        set_env(key, not_exec.to_str().unwrap());

        let result = find_chrome();
        if let Some(ref path) = result {
            assert_ne!(*path, not_exec);
        }

        restore_env(key, prev);
    }

    #[test]
    fn search_order_is_deterministic() {
        let paths = search_paths();
        assert_eq!(paths.len(), 5);
        assert_eq!(
            paths[0],
            PathBuf::from("/Applications/Google Chrome.app/Contents/MacOS/Google Chrome")
        );
        assert_eq!(
            paths[1],
            PathBuf::from("/Applications/Chromium.app/Contents/MacOS/Chromium")
        );
        assert_eq!(
            paths[2],
            PathBuf::from(
                "/Applications/Google Chrome Canary.app/Contents/MacOS/Google Chrome Canary"
            )
        );
        assert_eq!(paths[3], PathBuf::from("/opt/homebrew/bin/chromium"));
        assert_eq!(paths[4], PathBuf::from("/usr/local/bin/chromium"));
    }

    #[test]
    fn all_search_paths_are_absolute() {
        for path in search_paths() {
            assert!(path.is_absolute(), "path should be absolute: {}", path.display());
        }
    }

    #[test]
    fn is_executable_checks_existence() {
        assert!(!is_executable(Path::new("/nonexistent/binary")));
    }

    #[test]
    fn is_executable_rejects_non_executable() {
        let dir = tempfile::tempdir().unwrap();
        let file = dir.path().join("plain.txt");
        std::fs::write(&file, "hello").unwrap();
        std::fs::set_permissions(&file, std::fs::Permissions::from_mode(0o644)).unwrap();
        assert!(!is_executable(&file));
    }

    #[test]
    fn is_executable_accepts_executable() {
        let dir = tempfile::tempdir().unwrap();
        let file = dir.path().join("run.sh");
        std::fs::write(&file, "#!/bin/sh\n").unwrap();
        std::fs::set_permissions(&file, std::fs::Permissions::from_mode(0o755)).unwrap();
        assert!(is_executable(&file));
    }

    #[test]
    #[cfg(target_os = "macos")]
    fn find_chrome_real_system() {
        let chrome_path = PathBuf::from(
            "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
        );
        if chrome_path.exists() {
            let key = "CHROME_PATH";
            let prev = std::env::var(key).ok();
            remove_env(key);

            let result = find_chrome();
            assert!(result.is_some(), "Chrome is installed but find_chrome() returned None");
            assert!(is_executable(result.as_ref().unwrap()));

            restore_env(key, prev);
        }
    }
}
