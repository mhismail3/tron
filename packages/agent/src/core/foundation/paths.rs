//! Canonical home directory, path resolution, and directory layout constants.
//!
//! All call sites that need `$HOME`, `~/.tron`, or any subdirectory under
//! `~/.tron` should use the functions and constants in this module. This
//! centralizes every directory and file name so that renames (e.g.
//! `memory/` → `workspace/`) require changing a single constant.

use std::path::PathBuf;

/// Fallback when `$HOME` is not set.
///
/// Uses a fixed path under the owner's tron workspace so that files
/// created by a headless/launchd process still land somewhere sensible
/// rather than polluting `/tmp`.
const FALLBACK_HOME: &str = "/Users/moose/.tron/system";

// ── Directory segment constants ────────────────────────────────────────

/// Directory name constants for the `~/.tron/` layout.
///
/// To rename a directory, change the constant here. All path-builder
/// helpers and call sites that use these constants will pick up the change
/// automatically.
pub mod dirs {
    // ── Top-level under ~/.tron/ ──

    /// System configuration and binaries directory.
    pub const SYSTEM: &str = "system";
    /// User workspace for sessions, knowledge, reports, scratch, etc.
    pub const WORKSPACE: &str = "workspace";
    /// User-specific data (voice profiles, etc.).
    pub const USER: &str = "user";
    /// Installed skills directory.
    pub const SKILLS: &str = "skills";

    // ── Under system/ ──

    /// App bundle name (macOS TCC identifies apps by CFBundleIdentifier inside the bundle).
    pub const APP_BUNDLE: &str = "Tron.app";
    /// SQLite databases.
    pub const DB: &str = "database";
    /// Streaming journals for crash recovery of partial LLM output.
    pub const JOURNALS: &str = "journals";
    /// Deployment artifacts and rollback state.
    pub const DEPLOYMENT: &str = "deployment";
    /// Optional extension modules (APNS, etc.).
    pub const MODS: &str = "mods";

    // ── Under workspace/ ──

    /// Auto-generated session summaries.
    pub const SESSIONS: &str = "sessions";
    /// Persistent knowledge base documents.
    pub const KNOWLEDGE: &str = "knowledge";
    /// Analysis, research, and investigation reports.
    pub const REPORTS: &str = "reports";
    /// Automation job working directories and output.
    pub const CRON: &str = "automations";
    /// Throwaway output and intermediate results.
    pub const SCRATCH: &str = "scratch";
    /// Saved screenshots from computer-use tool.
    pub const SCREENSHOTS: &str = "screenshots";
    /// Global rules files (SYSTEM.md, CLAUDE.md, AGENTS.md).
    pub const RULES: &str = "rules";

    // ── Under workspace/ ──

    /// Voice notes storage.
    pub const VOICE_NOTES: &str = "voice notes";

    /// Relative agent dir for rules discovery: `.tron/<WORKSPACE>/rules`.
    ///
    /// This is a composed constant used in `rules_discovery.rs` where a
    /// `const &str` is required. A test verifies it stays in sync with
    /// [`WORKSPACE`] and [`RULES`].
    pub const TRON_RULES_RELATIVE: &str = ".tron/workspace/rules";
}

/// Well-known file names under `~/.tron/`.
pub mod files {
    /// Server settings configuration.
    pub const SETTINGS_JSON: &str = "settings.json";
    /// Authentication credentials (API keys, tokens).
    pub const AUTH_JSON: &str = "auth.json";
    /// Canonical cron job definitions.
    pub const AUTOMATIONS_JSON: &str = "automations.json";
    /// Global system prompt override.
    pub const SYSTEM_MD: &str = "SYSTEM.md";
    /// Container runtime configuration.
    pub const CONTAINERS_JSON: &str = "containers.json";
}

// ── Core path functions ────────────────────────────────────────────────

/// Get the user's home directory, falling back to [`FALLBACK_HOME`] if `$HOME` is unset.
pub fn home_dir() -> String {
    std::env::var("HOME").unwrap_or_else(|_| FALLBACK_HOME.to_string())
}

/// Get the `~/.tron` directory path.
pub fn tron_home() -> PathBuf {
    PathBuf::from(home_dir()).join(".tron")
}

// ── Top-level directory helpers ────────────────────────────────────────

/// `~/.tron/system/`
pub fn system_dir() -> PathBuf {
    tron_home().join(dirs::SYSTEM)
}

/// `~/.tron/<workspace>/`
pub fn workspace_dir() -> PathBuf {
    tron_home().join(dirs::WORKSPACE)
}

/// `~/.tron/user/`
pub fn user_dir() -> PathBuf {
    tron_home().join(dirs::USER)
}

/// `~/.tron/skills/`
pub fn skills_dir() -> PathBuf {
    tron_home().join(dirs::SKILLS)
}

// ── System subdirectory helpers ────────────────────────────────────────

/// `~/.tron/system/Tron.app/Contents/MacOS/`
pub fn bin_dir() -> PathBuf {
    system_dir()
        .join(dirs::APP_BUNDLE)
        .join("Contents")
        .join("MacOS")
}

/// `~/.tron/system/database/`
pub fn db_dir() -> PathBuf {
    system_dir().join(dirs::DB)
}

/// `~/.tron/system/database/journals/`
pub fn journals_dir() -> PathBuf {
    db_dir().join(dirs::JOURNALS)
}

/// `~/.tron/system/deployment/`
pub fn deploy_dir() -> PathBuf {
    system_dir().join(dirs::DEPLOYMENT)
}

/// `~/.tron/system/mods/`
pub fn mods_dir() -> PathBuf {
    system_dir().join(dirs::MODS)
}

// ── Workspace subdirectory helpers ─────────────────────────────────────

/// `~/.tron/<workspace>/sessions/`
pub fn sessions_dir() -> PathBuf {
    workspace_dir().join(dirs::SESSIONS)
}

/// `~/.tron/<workspace>/knowledge/`
pub fn knowledge_dir() -> PathBuf {
    workspace_dir().join(dirs::KNOWLEDGE)
}

/// `~/.tron/<workspace>/reports/`
pub fn reports_dir() -> PathBuf {
    workspace_dir().join(dirs::REPORTS)
}

/// `~/.tron/<workspace>/automations/`
pub fn cron_dir() -> PathBuf {
    workspace_dir().join(dirs::CRON)
}

/// `~/.tron/<workspace>/scratch/`
pub fn scratch_dir() -> PathBuf {
    workspace_dir().join(dirs::SCRATCH)
}

/// `~/.tron/<workspace>/screenshots/`
pub fn screenshots_dir() -> PathBuf {
    workspace_dir().join(dirs::SCREENSHOTS)
}

/// `~/.tron/<workspace>/rules/`
pub fn rules_dir() -> PathBuf {
    workspace_dir().join(dirs::RULES)
}

// ── Voice notes ──────────────────────────────────────────────────────

/// `~/.tron/workspace/voice notes/`
pub fn voice_notes_dir() -> PathBuf {
    workspace_dir().join(dirs::VOICE_NOTES)
}

// ── Composite file path helpers ────────────────────────────────────────

/// `~/.tron/system/Tron.app/Contents/MacOS/tron`
pub fn tron_binary_path() -> PathBuf {
    bin_dir().join("tron")
}

/// `~/.tron/system/settings.json`
pub fn settings_path() -> PathBuf {
    system_dir().join(files::SETTINGS_JSON)
}

/// `~/.tron/system/auth.json`
pub fn auth_path() -> PathBuf {
    system_dir().join(files::AUTH_JSON)
}

/// `~/.tron/<workspace>/automations/automations.json`
pub fn automations_path() -> PathBuf {
    cron_dir().join(files::AUTOMATIONS_JSON)
}

/// `~/.tron/<workspace>/rules/SYSTEM.md`
pub fn global_system_prompt_path() -> PathBuf {
    rules_dir().join(files::SYSTEM_MD)
}

/// `~/.tron/system/containers.json`
pub fn containers_path() -> PathBuf {
    system_dir().join(files::CONTAINERS_JSON)
}

// ── Tests ──────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn home_dir_returns_env_var() {
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
        assert!(result.to_string_lossy().ends_with(".tron"));
    }

    // ── Top-level dirs ─────────────────────────────────────────────

    #[test]
    fn system_dir_under_tron_home() {
        let p = system_dir();
        assert!(p.ends_with(format!(".tron/{}", dirs::SYSTEM)));
    }

    #[test]
    fn workspace_dir_under_tron_home() {
        let p = workspace_dir();
        assert!(p.ends_with(format!(".tron/{}", dirs::WORKSPACE)));
    }

    #[test]
    fn skills_dir_under_tron_home() {
        let p = skills_dir();
        assert!(p.ends_with(format!(".tron/{}", dirs::SKILLS)));
    }

    #[test]
    fn user_dir_under_tron_home() {
        let p = user_dir();
        assert!(p.ends_with(format!(".tron/{}", dirs::USER)));
    }

    // ── Workspace subdirs ──────────────────────────────────────────

    #[test]
    fn sessions_dir_chains_correctly() {
        let p = sessions_dir();
        assert!(p.ends_with(format!("{}/{}", dirs::WORKSPACE, dirs::SESSIONS)));
    }

    #[test]
    fn rules_dir_chains_correctly() {
        let p = rules_dir();
        assert!(p.ends_with(format!("{}/{}", dirs::WORKSPACE, dirs::RULES)));
    }

    #[test]
    fn scratch_dir_chains_correctly() {
        let p = scratch_dir();
        assert!(p.ends_with(format!("{}/{}", dirs::WORKSPACE, dirs::SCRATCH)));
    }

    #[test]
    fn cron_dir_chains_correctly() {
        let p = cron_dir();
        assert!(p.ends_with(format!("{}/{}", dirs::WORKSPACE, dirs::CRON)));
    }

    #[test]
    fn screenshots_dir_chains_correctly() {
        let p = screenshots_dir();
        assert!(p.ends_with(format!("{}/{}", dirs::WORKSPACE, dirs::SCREENSHOTS)));
    }

    // ── Composite file paths ───────────────────────────────────────

    #[test]
    fn global_system_prompt_path_correct() {
        let p = global_system_prompt_path();
        assert!(p.ends_with(format!("{}/{}/{}", dirs::WORKSPACE, dirs::RULES, files::SYSTEM_MD)));
    }

    #[test]
    fn automations_path_correct() {
        let p = automations_path();
        assert!(p.ends_with(format!("{}/{}/{}", dirs::WORKSPACE, dirs::CRON, files::AUTOMATIONS_JSON)));
    }

    #[test]
    fn settings_path_correct() {
        let p = settings_path();
        assert!(p.ends_with(format!("{}/{}", dirs::SYSTEM, files::SETTINGS_JSON)));
    }

    #[test]
    fn tron_binary_path_correct() {
        let p = tron_binary_path();
        assert!(p.ends_with(format!("{}/{}/Contents/MacOS/tron", dirs::SYSTEM, dirs::APP_BUNDLE)));
    }

    #[test]
    fn journals_dir_under_db() {
        let p = journals_dir();
        assert!(p.ends_with(format!("{}/{}/{}", dirs::SYSTEM, dirs::DB, dirs::JOURNALS)));
    }

    #[test]
    fn containers_path_correct() {
        let p = containers_path();
        assert!(p.ends_with(format!("{}/{}", dirs::SYSTEM, files::CONTAINERS_JSON)));
    }

    // ── Consistency guards ─────────────────────────────────────────

    #[test]
    fn tron_rules_relative_matches_constants() {
        let expected = format!(".tron/{}/{}", dirs::WORKSPACE, dirs::RULES);
        assert_eq!(
            dirs::TRON_RULES_RELATIVE, expected,
            "TRON_RULES_RELATIVE is out of sync with WORKSPACE/RULES constants"
        );
    }
}
