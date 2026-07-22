//! Minimal Tron Home filesystem initialization.
//!
//! Runtime state has two directory roots: `internal/` and `workspace/`.
//! Protected provider/transport credentials and sparse user settings live at
//! `~/.tron/auth.json` and `~/.tron/settings.toml`; both files are created only
//! by explicit credential or settings mutations.

use std::fs;
use std::io;
use std::path::{Path, PathBuf};

use super::paths::dirs;

/// Ensure a specific Tron Home is structurally complete.
pub fn ensure_tron_home_at(home: &Path) -> io::Result<()> {
    for directory in required_directories(home) {
        fs::create_dir_all(&directory)?;
        set_private_directory_permissions(&directory)?;
    }
    Ok(())
}

/// Restrict a durable Tron file to its owning user.
pub fn set_private_file_permissions(path: &Path) -> io::Result<()> {
    set_private_permissions(path, 0o600)
}

/// Restrict a durable Tron directory to its owning user.
pub fn set_private_directory_permissions(path: &Path) -> io::Result<()> {
    set_private_permissions(path, 0o700)
}

#[cfg(unix)]
fn set_private_permissions(path: &Path, mode: u32) -> io::Result<()> {
    use std::os::unix::fs::PermissionsExt as _;
    fs::set_permissions(path, fs::Permissions::from_mode(mode))
}

#[cfg(not(unix))]
fn set_private_permissions(_path: &Path, _mode: u32) -> io::Result<()> {
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
        assert!(!home.join("auth.json").exists());
        assert!(!home.join("profiles").exists());
        assert!(!home.join("workspace/projects").exists());
        assert!(!home.join("workspace/reports").exists());
        assert!(!home.join("workspace/renders").exists());
        assert!(!home.join("workspace/scratch").exists());
        assert!(!home.join("workspace/screenshots").exists());
        assert!(!home.join("workspace/labs").exists());
        assert!(!home.join("workspace/archive").exists());
        assert!(!home.join("workspace/knowledge").exists());
        assert!(!home.join("settings.toml").exists());
    }

    #[test]
    fn initialization_never_overwrites_auth_or_settings() {
        let root = tempfile::tempdir().unwrap();
        let home = root.path().join(".tron");
        ensure_tron_home_at(&home).unwrap();
        fs::write(home.join("auth.json"), "{\"token\":\"kept\"}").unwrap();
        fs::write(
            home.join("settings.toml"),
            "[context.compactor]\ntriggerTokenThreshold = 0.6\n",
        )
        .unwrap();

        ensure_tron_home_at(&home).unwrap();
        assert_eq!(
            fs::read_to_string(home.join("auth.json")).unwrap(),
            "{\"token\":\"kept\"}"
        );
        assert_eq!(
            fs::read_to_string(home.join("settings.toml")).unwrap(),
            "[context.compactor]\ntriggerTokenThreshold = 0.6\n"
        );
    }

    #[cfg(unix)]
    #[test]
    fn initialization_enforces_owner_only_directory_permissions() {
        use std::os::unix::fs::PermissionsExt as _;

        let root = tempfile::tempdir().unwrap();
        let home = root.path().join(".tron");
        ensure_tron_home_at(&home).unwrap();

        for directory in required_directories(&home) {
            let mode = fs::metadata(directory).unwrap().permissions().mode() & 0o777;
            assert_eq!(mode, 0o700);
        }
    }
}
