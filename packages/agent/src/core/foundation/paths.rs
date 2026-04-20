//! Canonical home directory, path resolution, and directory layout constants.
//!
//! All call sites that need `$HOME`, `~/.tron`, or any subdirectory under
//! `~/.tron` should use the functions and constants in this module. This
//! centralizes every directory and file name so that renames (e.g.
//! `memory/` → `workspace/`) require changing a single constant.

use std::path::PathBuf;

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
    /// Transcription sidecar: Python venv, worker script, HuggingFace model cache.
    pub const TRANSCRIPTION: &str = "transcription";

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
    /// Rules and core memories (SYSTEM.md, CLAUDE.md, user preferences).
    pub const RULES: &str = "rules";
    /// Internal agent memory (rules/core memories, session journals).
    pub const MEMORY: &str = "memory";

    // ── Under workspace/ ──

    /// Voice notes storage.
    pub const VOICE_NOTES: &str = "voice notes";

    /// Relative agent dir for rules discovery: `.tron/<WORKSPACE>/<MEMORY>/rules`.
    ///
    /// This is a composed constant used in `rules_discovery.rs` where a
    /// `const &str` is required. A test verifies it stays in sync with
    /// [`WORKSPACE`], [`MEMORY`], and [`RULES`].
    pub const TRON_RULES_RELATIVE: &str = ".tron/workspace/memory/rules";
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

// ── Transcription sidecar ──────────────────────────────────────────────
//
// The transcription sidecar is a Python venv + parakeet-mlx worker that
// lives entirely under one directory, with a HuggingFace model cache
// inside it. All references to these paths across the Rust agent, the
// Python worker, and `scripts/tron` should go through the helpers below.

/// `~/.tron/system/transcription/` — parent dir for venv, worker, model cache.
pub fn transcription_dir() -> PathBuf {
    system_dir().join(dirs::TRANSCRIPTION)
}

/// `~/.tron/system/transcription/venv/`
pub fn transcription_venv_dir() -> PathBuf {
    transcription_dir().join("venv")
}

/// `~/.tron/system/transcription/worker.py`
pub fn transcription_worker_script() -> PathBuf {
    transcription_dir().join("worker.py")
}

/// `~/.tron/system/transcription/requirements.txt`
pub fn transcription_requirements_path() -> PathBuf {
    transcription_dir().join("requirements.txt")
}

/// `~/.tron/system/transcription/models/hf/` — `HuggingFace` model cache (`HF_HOME`).
pub fn transcription_hf_cache_dir() -> PathBuf {
    transcription_dir().join("models").join("hf")
}

// ── Workspace subdirectory helpers ─────────────────────────────────────

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

/// `~/.tron/<workspace>/memory/rules/`
///
/// Global rules (SYSTEM.md, CLAUDE.md) and core memories (user preferences,
/// agent identity) live here. Formerly at `workspace/rules/`, consolidated
/// under `workspace/memory/rules/` so all persistent agent state is colocated.
pub fn rules_dir() -> PathBuf {
    memory_dir().join(dirs::RULES)
}

// ── Voice notes ──────────────────────────────────────────────────────

/// `~/.tron/workspace/voice notes/`
pub fn voice_notes_dir() -> PathBuf {
    workspace_dir().join(dirs::VOICE_NOTES)
}

// ── Memory subdirectory helpers ───────────────────────────────────────

/// `~/.tron/<workspace>/memory/`
pub fn memory_dir() -> PathBuf {
    workspace_dir().join(dirs::MEMORY)
}

/// `~/.tron/<workspace>/memory/sessions/`
pub fn memory_sessions_dir() -> PathBuf {
    memory_dir().join(dirs::SESSIONS)
}

/// `~/.tron/<workspace>/memory/rules/`
///
/// Alias for [`rules_dir()`] — both return the same path since rules
/// and core memories are colocated under `workspace/memory/rules/`.
pub fn memory_rules_dir() -> PathBuf {
    rules_dir()
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

/// `~/.tron/<workspace>/memory/rules/SYSTEM.md`
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
    fn paths_source_has_no_hardcoded_user_directory() {
        let src = include_str!("paths.rs");
        // Construct the needle from parts so this very test doesn't trigger itself.
        let needle = format!("/Users/{}", "moose");
        assert!(
            !src.contains(&needle),
            "hardcoded user path leaked back into paths.rs"
        );
    }

    /// Regression guard covering every production file this refactor touched.
    /// Extending the list is a cheap review-time change.
    #[test]
    fn skill_detection_source_has_no_hardcoded_user_directory() {
        // Construct the needle from parts so this very test doesn't self-match.
        let needle = format!("/Users/{}", "moose");
        let offenders: &[(&str, &str)] = &[
            ("paths.rs", include_str!("paths.rs")),
            (
                "skills/model/constants.rs",
                include_str!("../../skills/model/constants.rs"),
            ),
            (
                "skills/model/types.rs",
                include_str!("../../skills/model/types.rs"),
            ),
            (
                "skills/discovery/loader.rs",
                include_str!("../../skills/discovery/loader.rs"),
            ),
            (
                "skills/discovery/registry.rs",
                include_str!("../../skills/discovery/registry.rs"),
            ),
            (
                "skills/runtime/injector.rs",
                include_str!("../../skills/runtime/injector.rs"),
            ),
            ("skills/mod.rs", include_str!("../../skills/mod.rs")),
        ];
        for (name, src) in offenders {
            assert!(!src.contains(&needle), "hardcoded user path in {name}");
        }
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
    fn rules_dir_chains_correctly() {
        let p = rules_dir();
        assert!(p.ends_with(format!(
            "{}/{}/{}",
            dirs::WORKSPACE,
            dirs::MEMORY,
            dirs::RULES
        )));
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
        assert!(p.ends_with(format!(
            "{}/{}/{}/{}",
            dirs::WORKSPACE,
            dirs::MEMORY,
            dirs::RULES,
            files::SYSTEM_MD
        )));
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

    // ── Transcription sidecar ──────────────────────────────────────

    #[test]
    fn transcription_dir_under_system() {
        let p = transcription_dir();
        assert!(p.ends_with(format!("{}/{}", dirs::SYSTEM, dirs::TRANSCRIPTION)));
    }

    #[test]
    fn transcription_venv_dir_correct() {
        let p = transcription_venv_dir();
        assert!(p.ends_with(format!("{}/{}/venv", dirs::SYSTEM, dirs::TRANSCRIPTION)));
    }

    #[test]
    fn transcription_worker_script_correct() {
        let p = transcription_worker_script();
        assert!(p.ends_with(format!("{}/{}/worker.py", dirs::SYSTEM, dirs::TRANSCRIPTION)));
    }

    #[test]
    fn transcription_requirements_path_correct() {
        let p = transcription_requirements_path();
        assert!(p.ends_with(format!(
            "{}/{}/requirements.txt",
            dirs::SYSTEM,
            dirs::TRANSCRIPTION
        )));
    }

    #[test]
    fn transcription_hf_cache_dir_correct() {
        let p = transcription_hf_cache_dir();
        assert!(p.ends_with(format!(
            "{}/{}/models/hf",
            dirs::SYSTEM,
            dirs::TRANSCRIPTION
        )));
    }

    // ── Memory subdirs ──────────────────────────────────────────────

    #[test]
    fn memory_dir_under_workspace() {
        let p = memory_dir();
        assert!(p.ends_with(format!("{}/{}", dirs::WORKSPACE, dirs::MEMORY)));
    }

    #[test]
    fn memory_sessions_dir_chains_correctly() {
        let p = memory_sessions_dir();
        assert!(p.ends_with(format!(
            "{}/{}/{}",
            dirs::WORKSPACE,
            dirs::MEMORY,
            dirs::SESSIONS
        )));
    }

    #[test]
    fn memory_rules_dir_chains_correctly() {
        let p = memory_rules_dir();
        assert!(p.ends_with(format!(
            "{}/{}/{}",
            dirs::WORKSPACE,
            dirs::MEMORY,
            dirs::RULES
        )));
    }

    // ── Consistency guards ─────────────────────────────────────────

    #[test]
    fn tron_rules_relative_matches_constants() {
        let expected = format!(".tron/{}/{}/{}", dirs::WORKSPACE, dirs::MEMORY, dirs::RULES);
        assert_eq!(
            dirs::TRON_RULES_RELATIVE, expected,
            "TRON_RULES_RELATIVE is out of sync with WORKSPACE/MEMORY/RULES constants"
        );
    }
}
