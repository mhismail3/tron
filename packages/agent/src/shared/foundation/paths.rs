//! Canonical home directory, path resolution, and directory layout constants.
//!
//! All call sites that need `$HOME`, `~/.tron`, or any subdirectory under
//! `~/.tron` should use the functions and constants in this module. This
//! centralizes every directory and file name so the primitive Tron Home has one
//! enforceable path contract.

use std::path::{Path, PathBuf};

/// Absolute data-root override used only by explicit developer/test launch modes.
pub const TRON_DATA_DIR_ENV: &str = "TRON_DATA_DIR";
/// Home-relative data-root override used by the Mac isolated install scheme.
pub const TRON_HOME_NAME_ENV: &str = "TRON_HOME_NAME";
/// Production Mac wrapper bundle identifier.
pub const MAC_RELEASE_BUNDLE_ID: &str = "com.tron.mac";

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
    /// Profile settings and auth refs.
    pub const PROFILES: &str = "profiles";
    /// Active work, generated artifacts, plans, reports, and experiments.
    pub const WORKSPACE: &str = "workspace";

    // ── Under internal/ ──

    /// SQLite databases.
    pub const DB: &str = "database";
    /// Ephemeral runtime lock files. Ordinary startup may create this directory.
    pub const RUN: &str = "run";
    /// Streaming journals for crash recovery of partial LLM output.
    pub const JOURNALS: &str = "journals";
    // ── Under workspace/ ──

    /// Incoming captures that need later routing.
    pub const INBOX: &str = "inbox";
    /// Active project spaces.
    pub const PROJECTS: &str = "projects";
    /// Analysis, research, and investigation reports.
    pub const REPORTS: &str = "reports";
    /// Rendered pages displayed in the app.
    pub const RENDERS: &str = "renders";
    /// Throwaway output and intermediate results.
    pub const SCRATCH: &str = "scratch";
    /// Saved screenshots from the computer-use capability.
    pub const SCREENSHOTS: &str = "screenshots";
    /// Experimental semi-long-lived spaces before promotion.
    pub const LABS: &str = "labs";
    /// Retired work material.
    pub const ARCHIVE: &str = "archive";
    /// Workspace-local curated wiki/research experiment.
    pub const KNOWLEDGE: &str = "knowledge";
    /// Workspace-local skill-owned credential vault.
    pub const VAULT: &str = "vault";
}

/// Well-known file names under `~/.tron/`.
pub mod files {
    /// Protected built-in authentication credentials (API keys, tokens).
    pub const AUTH_JSON: &str = "auth.json";
    /// Readable credential registry.
    pub const AUTH_TOML: &str = "auth.toml";
    /// Profile execution spec.
    pub const PROFILE_TOML: &str = "profile.toml";
    /// Active profile pointer.
    pub const ACTIVE_TOML: &str = "active.toml";
    /// First-run sentinel: empty marker file at `~/.tron/internal/run/.onboarded`.
    /// Touched by the Mac wizard at the end of its install flow OR on
    /// the first successful engine authentication from any iOS device. The
    /// `system.getInfo` engine capability reports `paired: true` once it exists.
    pub const ONBOARDED_MARKER: &str = ".onboarded";
    /// Persistent state for the user-mode auto-updater
    /// (`server::updater`) — lastCheckAt, lastInstalledVersion,
    /// latestAvailableVersion/latestDownloadUrl. Stored in
    /// `~/.tron/internal/run/updater-state.json`
    /// with mode `0o644` (non-secret, widely readable is fine). Atomic
    /// writes mirror the `auth.json` pattern.
    pub const UPDATER_STATE_JSON: &str = "updater-state.json";
    /// Pause sentinel honoured by both the contributor `scripts/auto-deploy`
    /// loop and the user-mode auto-updater. Presence of the file blocks
    /// any further install actions without touching settings.
    pub const AUTO_UPDATE_PAUSE: &str = "auto-update.pause";
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
         Every on-disk path descends from this value; refusing to fall back to a guessed location."
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

/// `~/.tron/profiles/`
pub fn profiles_dir() -> PathBuf {
    tron_home().join(dirs::PROFILES)
}

/// `~/.tron/workspace/`
pub fn workspace_dir() -> PathBuf {
    tron_home().join(dirs::WORKSPACE)
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

// ── Workspace subdirectory helpers ─────────────────────────────────────

/// `~/.tron/workspace/reports/`
pub fn reports_dir() -> PathBuf {
    workspace_dir().join(dirs::REPORTS)
}

/// `~/.tron/workspace/scratch/`
pub fn scratch_dir() -> PathBuf {
    workspace_dir().join(dirs::SCRATCH)
}

/// `~/.tron/workspace/renders/`
pub fn renders_dir() -> PathBuf {
    workspace_dir().join(dirs::RENDERS)
}

/// `~/.tron/workspace/screenshots/`
pub fn screenshots_dir() -> PathBuf {
    workspace_dir().join(dirs::SCREENSHOTS)
}

/// `~/.tron/workspace/inbox/`
pub fn inbox_dir() -> PathBuf {
    workspace_dir().join(dirs::INBOX)
}

/// `~/.tron/workspace/projects/`
pub fn projects_dir() -> PathBuf {
    workspace_dir().join(dirs::PROJECTS)
}

/// `~/.tron/workspace/labs/`
pub fn labs_dir() -> PathBuf {
    workspace_dir().join(dirs::LABS)
}

/// `~/.tron/workspace/archive/`
pub fn archive_dir() -> PathBuf {
    workspace_dir().join(dirs::ARCHIVE)
}

/// `~/.tron/workspace/knowledge/`
pub fn knowledge_dir() -> PathBuf {
    workspace_dir().join(dirs::KNOWLEDGE)
}

/// `~/.tron/workspace/vault/`
pub fn vault_dir() -> PathBuf {
    workspace_dir().join(dirs::VAULT)
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

/// `~/.tron/profiles/user/profile.toml`
pub fn settings_path() -> PathBuf {
    user_profile_path()
}

/// Managed default profile path.
pub fn settings_defaults_path() -> PathBuf {
    default_profile_dir().join(files::PROFILE_TOML)
}

/// `~/.tron/profiles/auth.json`
pub fn auth_path() -> PathBuf {
    profiles_dir().join(files::AUTH_JSON)
}

/// `~/.tron/profiles/auth.json` — WebSocket bearer-token storage and provider auth.
///
/// The bearer token is stored as top-level `bearerToken`. Read by the WS
/// upgrade handler; written by
/// `server::onboarding::load_or_create_bearer_token` and
/// `server::onboarding::rotate_bearer_token`.
pub fn bearer_token_path() -> PathBuf {
    auth_path()
}

/// `~/.tron/internal/run/auth.lock` — auth file serialization lock.
pub fn auth_lock_path() -> PathBuf {
    auth_lock_path_for_home(&tron_home())
}

/// `<home>/internal/run/auth.lock` — auth file serialization lock.
pub fn auth_lock_path_for_home(home: &Path) -> PathBuf {
    run_dir_for_home(home).join("auth.lock")
}

/// `~/.tron/internal/run/.mac-wrapper.com.tron.mac.lock` — production Mac wrapper lock.
pub fn mac_wrapper_lock_path() -> PathBuf {
    mac_wrapper_lock_path_for(MAC_RELEASE_BUNDLE_ID)
}

/// `~/.tron/internal/run/.mac-wrapper.<bundle-id>.lock` — per-wrapper lock.
pub fn mac_wrapper_lock_path_for(bundle_identifier: &str) -> PathBuf {
    let safe_identifier: String = bundle_identifier
        .chars()
        .map(|ch| {
            if ch.is_ascii_alphanumeric() || ch == '.' || ch == '-' {
                ch
            } else {
                '-'
            }
        })
        .collect();
    run_dir().join(format!(".mac-wrapper.{safe_identifier}.lock"))
}

/// `~/.tron/internal/run/.onboarded` — first-run sentinel marker.
///
/// See [`files::ONBOARDED_MARKER`] for purpose. Existence-checked by
/// `system.getInfo` to populate the `paired` field; created by the Mac
/// wizard or `server::onboarding::mark_onboarded`.
pub fn onboarded_marker_path() -> PathBuf {
    run_dir().join(files::ONBOARDED_MARKER)
}

/// `~/.tron/internal/run/updater-state.json` — auto-updater persistent state.
///
/// See [`files::UPDATER_STATE_JSON`] for purpose. Read/written by
/// `server::updater`. Mode `0o644` (no secrets); atomic writes.
pub fn updater_state_path() -> PathBuf {
    run_dir().join(files::UPDATER_STATE_JSON)
}

/// `~/.tron/internal/run/auto-update.pause` — pause sentinel for the auto-updater.
///
/// Presence causes `server::updater` to skip any further install action
/// without mutating settings. `tron self-update pause / resume` toggle
/// the file.
pub fn auto_update_pause_path() -> PathBuf {
    run_dir().join(files::AUTO_UPDATE_PAUSE)
}

/// `~/.tron/profiles/user/profile.toml`
pub fn user_profile_path() -> PathBuf {
    profiles_dir()
        .join(crate::shared::profile::USER_PROFILE)
        .join(files::PROFILE_TOML)
}

/// `~/.tron/profiles/default/`
pub fn default_profile_dir() -> PathBuf {
    profiles_dir().join(crate::shared::profile::DEFAULT_PROFILE)
}

/// `~/.tron/profiles/active.toml`
pub fn active_profile_path() -> PathBuf {
    profiles_dir().join(files::ACTIVE_TOML)
}

/// `~/.tron/profiles/auth.toml`
pub fn auth_registry_path() -> PathBuf {
    profiles_dir().join(files::AUTH_TOML)
}

// ── Tests ──────────────────────────────────────────────────────────────

#[cfg(test)]
#[path = "paths/tests.rs"]
mod tests;
