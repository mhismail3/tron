//! Canonical home directory, path resolution, and directory layout constants.
//!
//! All call sites that need `$HOME`, `~/.tron`, or any subdirectory under
//! `~/.tron` should use the functions and constants in this module. This
//! centralizes every directory and file name so the primitive Tron Home has one
//! enforceable path contract. `TRON_DATA_DIR` is an absolute developer/test
//! override; `TRON_HOME_NAME` is limited to one home-relative directory segment
//! for isolated Mac installs.

use std::path::{Path, PathBuf};

/// Absolute data-root override used only by explicit developer/test launch modes.
pub const TRON_DATA_DIR_ENV: &str = "TRON_DATA_DIR";
/// Home-relative data-root override used by the Mac isolated install scheme.
pub const TRON_HOME_NAME_ENV: &str = "TRON_HOME_NAME";
// ── Directory segment constants ────────────────────────────────────────

/// Directory name constants for the `~/.tron/` layout.
///
/// To rename a directory, change the constant here. All path-builder
/// helpers and call sites that use these constants will pick up the change
/// automatically.
pub mod dirs {
    // ── Top-level under ~/.tron/ ──

    /// Tron-owned runtime machinery: databases, locks, journals, caches.
    pub const INTERNAL: &str = "internal";
    /// Protected provider and transport credentials.
    pub const PROFILES: &str = "profiles";
    /// Active work, generated artifacts, plans, reports, and experiments.
    pub const WORKSPACE: &str = "workspace";

    // ── Under internal/ ──

    /// SQLite databases.
    pub const DB: &str = "database";
    /// Ephemeral runtime lock files. Ordinary startup may create this directory.
    pub const RUN: &str = "run";
    /// Recoverable snapshots taken before worker-kernel schema conversion.
    pub const SNAPSHOTS: &str = "snapshots";
    /// Streaming journals for crash recovery of partial LLM output.
    pub const JOURNALS: &str = "journals";
    // ── Under workspace/ ──

    /// Workspace-local credential vault.
    pub const VAULT: &str = "vault";
    /// Approved local worker packages and launchable worker bundles.
    pub const WORKERS: &str = "workers";
}

/// Well-known file names under `~/.tron/`.
pub mod files {
    /// Protected built-in authentication credentials (API keys, tokens).
    pub const AUTH_JSON: &str = "auth.json";
    /// Sparse user-owned engine settings.
    pub const SETTINGS_TOML: &str = "settings.toml";
}

// ── Core path functions ────────────────────────────────────────────────

/// Resolve the user's home directory.
///
/// Order:
/// 1. `$HOME` env var — set by the shell and by launchd's `UserName` key.
/// 2. `home::home_dir()` — uses `getpwuid_r` on Unix, the platform-canonical
///    lookup when the env var is absent (e.g. some sandboxed cron contexts).
///
/// Panics if neither resolves. Every path helper in this module descends
/// from this function, so silently falling back to a writable tempdir would
/// risk corrupting the wrong user's data on a shared host or masking a broken
/// install. Failing loudly is the only safe option.
pub fn home_dir() -> String {
    if let Ok(h) = std::env::var("HOME") {
        return h;
    }
    if let Some(h) = home::home_dir() {
        return h.to_string_lossy().into_owned();
    }
    panic!(
        "tron: cannot resolve a home directory — $HOME is unset and home::home_dir() returned None. \
         Every on-disk path descends from this value; refusing to use a guessed location."
    );
}

/// Get the Tron data directory path.
///
/// Defaults to `~/.tron`. Explicit developer/test launch modes may set
/// `TRON_DATA_DIR` to an absolute path or `TRON_HOME_NAME` to a single
/// home-relative directory name such as `.tron-dev`.
pub fn tron_home() -> PathBuf {
    resolve_tron_home(
        &home_dir(),
        std::env::var(TRON_DATA_DIR_ENV).ok().as_deref(),
        std::env::var(TRON_HOME_NAME_ENV).ok().as_deref(),
    )
}

/// Resolve a user-supplied working directory into an existing canonical path.
///
/// The session/primitive runtime accepts `~` and `~/...` as the only
/// shell-style expansion because those are the forms clients send for a user's
/// home workspace. Everything else is resolved by the filesystem.
pub fn normalize_working_directory(raw: &str) -> Result<PathBuf, String> {
    let raw = raw.trim();
    if raw.is_empty() {
        return Err("working directory must not be empty".to_owned());
    }
    let expanded = expand_home_path(raw);
    let canonical = expanded
        .canonicalize()
        .map_err(|error| format!("resolve working directory {raw:?}: {error}"))?;
    if !canonical.is_dir() {
        return Err(format!(
            "working directory is not a directory: {}",
            canonical.display()
        ));
    }
    Ok(canonical)
}

fn expand_home_path(raw: &str) -> PathBuf {
    if raw == "~" {
        return PathBuf::from(home_dir());
    }
    if let Some(rest) = raw.strip_prefix("~/") {
        return PathBuf::from(home_dir()).join(rest);
    }
    PathBuf::from(raw)
}

fn resolve_tron_home(home: &str, data_dir: Option<&str>, home_name: Option<&str>) -> PathBuf {
    if let Some(data_dir) = data_dir.filter(|value| !value.is_empty()) {
        return PathBuf::from(data_dir);
    }
    if let Some(home_name) = home_name.filter(|value| !value.is_empty()) {
        assert!(
            valid_home_relative_name(home_name),
            "{TRON_HOME_NAME_ENV} must be a single home-relative directory name"
        );
        return PathBuf::from(home).join(home_name);
    }
    PathBuf::from(home).join(".tron")
}

fn valid_home_relative_name(value: &str) -> bool {
    value != "." && value != ".." && !value.contains('/')
}

// ── Top-level directory helpers ────────────────────────────────────────

/// `~/.tron/internal/`
pub fn internal_dir() -> PathBuf {
    tron_home().join(dirs::INTERNAL)
}

/// `<home>/internal/`
pub fn internal_dir_for_home(home: &Path) -> PathBuf {
    home.join(dirs::INTERNAL)
}

// ── Internal subdirectory helpers ──────────────────────────────────────

/// `~/.tron/internal/database/`
pub fn db_dir() -> PathBuf {
    internal_dir().join(dirs::DB)
}

/// `~/.tron/internal/run/`
pub fn run_dir() -> PathBuf {
    run_dir_for_home(&tron_home())
}

/// `<home>/internal/run/`
pub fn run_dir_for_home(home: &Path) -> PathBuf {
    internal_dir_for_home(home).join(dirs::RUN)
}

/// `~/.tron/internal/database/journals/`
pub fn journals_dir() -> PathBuf {
    db_dir().join(dirs::JOURNALS)
}

// ── Composite file path helpers ────────────────────────────────────────

/// Path to the currently running Tron executable.
///
/// Production macOS installs launch the server helper from inside
/// `/Applications/Tron.app`; dev workflows may run a Cargo-built binary.
/// Use the actual executable path instead of a fixed install path so health
/// and diagnostics stay correct for both.
pub fn tron_binary_path() -> PathBuf {
    std::env::current_exe().unwrap_or_else(|_| PathBuf::from("tron"))
}

/// `~/.tron/settings.toml`
pub fn settings_path() -> PathBuf {
    settings_path_for_home(&tron_home())
}

/// `<home>/settings.toml`
pub fn settings_path_for_home(home: &Path) -> PathBuf {
    home.join(files::SETTINGS_TOML)
}

/// `~/.tron/profiles/auth.json`
pub fn auth_path() -> PathBuf {
    tron_home().join(dirs::PROFILES).join(files::AUTH_JSON)
}

/// `<home>/internal/run/auth.lock` — auth file serialization lock.
pub fn auth_lock_path_for_home(home: &Path) -> PathBuf {
    run_dir_for_home(home).join("auth.lock")
}

// ── Tests ──────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests;
