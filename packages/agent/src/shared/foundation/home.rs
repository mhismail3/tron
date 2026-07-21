//! Minimal Tron Home filesystem initialization.
//!
//! Runtime state has three roots: `internal/`, `profiles/`, and `workspace/`.
//! `profiles/` now contains protected `auth.json` only; named configuration
//! profiles, inheritance, active pointers, and source-owned prompt assets are
//! not initialized. Sparse user settings live directly
//! at `~/.tron/settings.toml` and are created only by an explicit mutation or
//! snapshot-first legacy migration.

use std::fs;
use std::io;
use std::path::{Path, PathBuf};

use super::paths::dirs;

/// Ensure a specific Tron Home is structurally complete.
pub fn ensure_tron_home_at(home: &Path) -> io::Result<()> {
    for directory in required_directories(home) {
        fs::create_dir_all(directory)?;
    }
    Ok(())
}

fn required_directories(home: &Path) -> Vec<PathBuf> {
    vec![
        home.join(dirs::INTERNAL),
        home.join(dirs::INTERNAL).join(dirs::DB),
        home.join(dirs::INTERNAL).join(dirs::RUN),
        home.join(dirs::INTERNAL)
            .join(dirs::DB)
            .join(dirs::JOURNALS),
        home.join(dirs::PROFILES),
        home.join(dirs::WORKSPACE),
        home.join(dirs::WORKSPACE).join(dirs::VAULT),
    ]
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn initialization_creates_only_required_roots() {
        let root = tempfile::tempdir().unwrap();
        let home = root.path().join(".tron");
        ensure_tron_home_at(&home).unwrap();

        assert!(home.join("internal/database").is_dir());
        assert!(home.join("workspace/vault").is_dir());
        assert!(!home.join("profiles/auth.json").exists());
        assert!(!home.join("workspace/projects").exists());
        assert!(!home.join("workspace/reports").exists());
        assert!(!home.join("workspace/renders").exists());
        assert!(!home.join("workspace/scratch").exists());
        assert!(!home.join("workspace/screenshots").exists());
        assert!(!home.join("workspace/labs").exists());
        assert!(!home.join("workspace/archive").exists());
        assert!(!home.join("workspace/knowledge").exists());
        assert!(!home.join("settings.toml").exists());
        assert!(!home.join("profiles/active.toml").exists());
        assert!(!home.join("profiles/default").exists());
    }

    #[test]
    fn initialization_never_overwrites_auth_or_settings() {
        let root = tempfile::tempdir().unwrap();
        let home = root.path().join(".tron");
        ensure_tron_home_at(&home).unwrap();
        fs::write(home.join("profiles/auth.json"), "{\"token\":\"kept\"}").unwrap();
        fs::write(home.join("settings.toml"), "autonomousWorkers = true\n").unwrap();

        ensure_tron_home_at(&home).unwrap();
        assert_eq!(
            fs::read_to_string(home.join("profiles/auth.json")).unwrap(),
            "{\"token\":\"kept\"}"
        );
        assert_eq!(
            fs::read_to_string(home.join("settings.toml")).unwrap(),
            "autonomousWorkers = true\n"
        );
    }
}
