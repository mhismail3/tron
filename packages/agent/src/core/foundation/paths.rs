//! Canonical home directory, path resolution, and directory layout constants.
//!
//! All call sites that need `$HOME`, `~/.tron`, or any subdirectory under
//! `~/.tron` should use the functions and constants in this module. This
//! centralizes every directory and file name so the profile-first Tron Home has
//! one enforceable path contract.

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
    /// Complete agent execution specs: prompts, settings, providers, auth refs.
    pub const PROFILES: &str = "profiles";
    /// Durable continuity about the user, Tron, preferences, and summaries.
    pub const MEMORY: &str = "memory";
    /// Active work, generated artifacts, plans, reports, and experiments.
    pub const WORKSPACE: &str = "workspace";
    /// Installed skills directory.
    pub const SKILLS: &str = "skills";

    // ── Under internal/ ──

    /// SQLite databases.
    pub const DB: &str = "database";
    /// Ephemeral runtime lock files. Ordinary startup may create this directory.
    pub const RUN: &str = "run";
    /// Streaming journals for crash recovery of partial LLM output.
    pub const JOURNALS: &str = "journals";
    /// Transcription sidecar: Python venv, worker script, HuggingFace model cache.
    pub const TRANSCRIPTION: &str = "transcription";

    // ── Under memory/ ──

    /// Auto-generated session summaries.
    pub const SESSIONS: &str = "sessions";
    /// Rules and core memories (SYSTEM.md, CLAUDE.md, user preferences).
    pub const RULES: &str = "rules";

    // ── Under workspace/ ──

    /// Incoming captures that need later routing.
    pub const INBOX: &str = "inbox";
    /// Active project spaces.
    pub const PROJECTS: &str = "projects";
    /// Analysis, research, and investigation reports.
    pub const REPORTS: &str = "reports";
    /// Automation definitions and user-facing job workspaces.
    pub const AUTOMATIONS: &str = "automations";
    /// Plans written during planning workflows.
    pub const PLANS: &str = "plans";
    /// Generated render/export/screenshot artifacts.
    pub const ARTIFACTS: &str = "artifacts";
    /// Rendered pages displayed in the app.
    pub const RENDERS: &str = "renders";
    /// Exported documents/assets.
    pub const EXPORTS: &str = "exports";
    /// Throwaway output and intermediate results.
    pub const SCRATCH: &str = "scratch";
    /// Saved screenshots from computer-use tool.
    pub const SCREENSHOTS: &str = "screenshots";
    /// Experimental semi-long-lived spaces before promotion.
    pub const LABS: &str = "labs";
    /// Retired work material.
    pub const ARCHIVE: &str = "archive";
    /// Voice notes storage.
    pub const VOICE_NOTES: &str = "voice-notes";
    /// Workspace-local curated wiki/research experiment.
    pub const KNOWLEDGE: &str = "knowledge";
    /// Workspace-local skill-owned credential vault.
    pub const VAULT: &str = "vault";

    // ── Under profiles/<name>/ ──

    /// Prompt files referenced by a profile.
    pub const PROMPTS: &str = "prompts";
    /// Hook behavior/prompt files referenced by a profile.
    pub const HOOKS: &str = "hooks";
    /// Provider presentation files referenced by a profile.
    pub const PROVIDERS: &str = "providers";
    /// Tool policy/presentation files referenced by a profile.
    pub const TOOLS: &str = "tools";
    /// Context compiler policy files referenced by a profile.
    pub const CONTEXT: &str = "context";
    /// Relative agent dir for rules discovery: `.tron/memory/rules`.
    ///
    /// This is a composed constant used in `rules_discovery.rs` where a
    /// `const &str` is required. A test verifies it stays in sync with
    /// [`MEMORY`] and [`RULES`].
    pub const TRON_RULES_RELATIVE: &str = ".tron/memory/rules";
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
    /// the first successful WS authentication from any iOS device. The
    /// `system.getInfo` RPC reports `paired: true` once it exists.
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
    /// Runtime bearer token consumed by the managed Codex App Server child.
    ///
    /// Stored under `internal/run/` because it is regenerated and consumed only
    /// by the local Tron daemon + iOS clients authenticated to that daemon.
    pub const CODEX_APP_SERVER_TOKEN: &str = "codex-app-server-token";
    /// Canonical cron job definitions.
    pub const AUTOMATIONS_JSON: &str = "automations.json";
    /// Profile prompt file name used by project-local prompt overrides.
    pub const SYSTEM_MD: &str = "SYSTEM.md";
    /// Container runtime configuration override.
    pub const CONTAINERS_JSON: &str = "containers.json";
    /// Canonical user-memory root file.
    ///
    /// Auto-injected into every session's context. Lightweight by design:
    /// basic user identity (name, email) + pointers to detail files under
    /// `rules/`. See [`memory_file()`] for the resolved path.
    pub const MEMORY_MD: &str = "MEMORY.md";
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

/// `~/.tron/memory/`
pub fn memory_dir() -> PathBuf {
    tron_home().join(dirs::MEMORY)
}

/// `~/.tron/workspace/`
pub fn workspace_dir() -> PathBuf {
    tron_home().join(dirs::WORKSPACE)
}

/// `~/.tron/skills/`
pub fn skills_dir() -> PathBuf {
    tron_home().join(dirs::SKILLS)
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

// ── Transcription sidecar ──────────────────────────────────────────────
//
// The transcription sidecar is a Python venv + parakeet-mlx worker that
// lives entirely under one directory, with a HuggingFace model cache
// inside it. The Mac wizard or contributor tooling seeds worker.py and
// requirements.txt before enabling it; runtime-generated venv/model data
// stays here. All references to these paths across the Rust agent, the
// Python worker, and `scripts/tron` should go through the helpers below.

/// `~/.tron/internal/transcription/` — parent dir for venv, worker, model cache.
pub fn transcription_dir() -> PathBuf {
    internal_dir().join(dirs::TRANSCRIPTION)
}

/// `~/.tron/internal/transcription/venv/`
pub fn transcription_venv_dir() -> PathBuf {
    transcription_dir().join("venv")
}

/// `~/.tron/internal/transcription/worker.py`
pub fn transcription_worker_script() -> PathBuf {
    transcription_dir().join("worker.py")
}

/// `~/.tron/internal/transcription/requirements.txt`
pub fn transcription_requirements_path() -> PathBuf {
    transcription_dir().join("requirements.txt")
}

/// `~/.tron/internal/transcription/models/hf/` — `HuggingFace` model cache (`HF_HOME`).
pub fn transcription_hf_cache_dir() -> PathBuf {
    transcription_dir().join("models").join("hf")
}

// ── Workspace subdirectory helpers ─────────────────────────────────────

/// `~/.tron/workspace/reports/`
pub fn reports_dir() -> PathBuf {
    workspace_dir().join(dirs::REPORTS)
}

/// `~/.tron/workspace/automations/`
pub fn automations_dir() -> PathBuf {
    workspace_dir().join(dirs::AUTOMATIONS)
}

/// `~/.tron/workspace/scratch/`
pub fn scratch_dir() -> PathBuf {
    workspace_dir().join(dirs::SCRATCH)
}

/// `~/.tron/workspace/artifacts/`
pub fn artifacts_dir() -> PathBuf {
    workspace_dir().join(dirs::ARTIFACTS)
}

/// `~/.tron/workspace/artifacts/renders/`
pub fn renders_dir() -> PathBuf {
    artifacts_dir().join(dirs::RENDERS)
}

/// `~/.tron/workspace/artifacts/screenshots/`
pub fn screenshots_dir() -> PathBuf {
    artifacts_dir().join(dirs::SCREENSHOTS)
}

/// `~/.tron/workspace/artifacts/exports/`
pub fn exports_dir() -> PathBuf {
    artifacts_dir().join(dirs::EXPORTS)
}

/// `~/.tron/workspace/plans/`
pub fn plans_dir() -> PathBuf {
    workspace_dir().join(dirs::PLANS)
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

/// `~/.tron/memory/rules/`
///
/// Global rules (SYSTEM.md, CLAUDE.md) and core memories (user preferences,
/// agent identity) live here.
pub fn rules_dir() -> PathBuf {
    memory_dir().join(dirs::RULES)
}

// ── Voice notes ──────────────────────────────────────────────────────

/// `~/.tron/workspace/inbox/voice-notes/`
pub fn voice_notes_dir() -> PathBuf {
    inbox_dir().join(dirs::VOICE_NOTES)
}

// ── Memory subdirectory helpers ───────────────────────────────────────

/// `~/.tron/memory/sessions/`
pub fn memory_sessions_dir() -> PathBuf {
    memory_dir().join(dirs::SESSIONS)
}

/// `~/.tron/memory/MEMORY.md`
///
/// Canonical user-memory root file (auto-loaded into every session).
pub fn memory_file() -> PathBuf {
    memory_dir().join(files::MEMORY_MD)
}

/// Same as [`memory_dir`] but rooted at a caller-supplied home (test-only ergonomic).
///
/// Used by [`crate::runtime::memory`] tests to point fingerprint scans at a
/// tempdir without manipulating `$HOME` (the workspace lints `unsafe_code = "deny"`).
pub fn memory_dir_for_home(home: &str) -> PathBuf {
    PathBuf::from(home).join(".tron").join(dirs::MEMORY)
}

/// Same as [`memory_file`] but rooted at a caller-supplied home (test-only ergonomic).
pub fn memory_file_for_home(home: &str) -> PathBuf {
    memory_dir_for_home(home).join(files::MEMORY_MD)
}

/// Same as [`memory_rules_dir`] but rooted at a caller-supplied home (test-only ergonomic).
pub fn memory_rules_dir_for_home(home: &str) -> PathBuf {
    memory_dir_for_home(home).join(dirs::RULES)
}

/// `~/.tron/memory/rules/`
pub fn memory_rules_dir() -> PathBuf {
    rules_dir()
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

/// `~/.tron/internal/run/codex-app-server-token` — bearer token for the
/// server-managed `codex app-server` child process.
pub fn codex_app_server_token_path() -> PathBuf {
    run_dir().join(files::CODEX_APP_SERVER_TOKEN)
}

/// `~/.tron/internal/run/auto-update.pause` — pause sentinel for the auto-updater.
///
/// Presence causes `server::updater` to skip any further install action
/// without mutating settings. `tron self-update pause / resume` toggle
/// the file.
pub fn auto_update_pause_path() -> PathBuf {
    run_dir().join(files::AUTO_UPDATE_PAUSE)
}

/// `~/.tron/workspace/automations/automations.json`
pub fn automations_path() -> PathBuf {
    automations_dir().join(files::AUTOMATIONS_JSON)
}

/// `~/.tron/workspace/automations/automations.json.bak`
pub fn automations_backup_path() -> PathBuf {
    automations_dir().join("automations.json.bak")
}

/// `~/.tron/profiles/user/prompts/core.md`
pub fn global_system_prompt_path() -> PathBuf {
    profiles_dir()
        .join(crate::core::profile::USER_PROFILE)
        .join(dirs::PROMPTS)
        .join("core.md")
}

/// `~/.tron/profiles/user/profile.toml`
pub fn user_profile_path() -> PathBuf {
    profiles_dir()
        .join(crate::core::profile::USER_PROFILE)
        .join(files::PROFILE_TOML)
}

/// `~/.tron/profiles/user/containers.json`
pub fn containers_path() -> PathBuf {
    profiles_dir()
        .join(crate::core::profile::USER_PROFILE)
        .join(files::CONTAINERS_JSON)
}

/// `~/.tron/profiles/default/`
pub fn default_profile_dir() -> PathBuf {
    profiles_dir().join(crate::core::profile::DEFAULT_PROFILE)
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

    /// Regression guard: `Cargo.toml` `repository` URL must not contain a
    /// short personal GitHub handle (the dev-machine username) in the
    /// `/<handle>/` path segment. An older draft pointed at a stale handle
    /// that would 404 for any user trying to follow the link from
    /// crates.io / docs.rs / IDE pop-ups.
    ///
    /// Needle constructed from parts so this test doesn't self-match.
    #[test]
    fn cargo_pkg_repository_has_no_personal_handle() {
        let repo = env!("CARGO_PKG_REPOSITORY");
        let needle = format!("/{}/", "moose");
        assert!(
            !repo.contains(&needle),
            "Cargo.toml `repository` field points at a personal handle: {repo}"
        );
    }

    /// Regression guard: `import/parser.rs` doc-comments must not embed
    /// example paths from the developer's home directory. An earlier doc
    /// comment used a literal Claude-Code-encoded form of the developer's
    /// project tree as its "example"; that leaks the developer's directory
    /// layout into a public-facing comment that ships in `cargo doc`.
    ///
    /// Both forms are checked: the raw filesystem prefix and the encoded
    /// form that Claude Code generates (slashes replaced with hyphens).
    /// Needles constructed from parts so this test doesn't self-match.
    #[test]
    fn import_parser_doc_comments_have_no_personal_path_examples() {
        let src = include_str!("../../import/parser.rs");
        let raw_needle = format!("/Users/{}", "moose");
        let encoded_needle = format!("-Users-{}-", "moose");
        assert!(
            !src.contains(&raw_needle),
            "import/parser.rs contains a hardcoded user path: {raw_needle}"
        );
        assert!(
            !src.contains(&encoded_needle),
            "import/parser.rs doc-comment example references the developer's \
             home directory in encoded form: {encoded_needle}"
        );
    }

    /// Regression guard: managed skill bundles (every `packages/agent/skills/*`
    /// with a `.managed` sentinel) must contain no hardcoded personal-info
    /// literals. Needles are constructed from parts so this test file itself
    /// doesn't contain them.
    #[test]
    fn managed_skills_contain_no_personal_info_literals() {
        let needles = [
            format!("{}{}{}", "M", "oh", "sin"),
            format!("{}{}{}", "Is", "ma", "il"),
            format!("{}{}{}", "is", "ma", "il"),
            format!("{}{}{}", "mh", "is", "mail"),
        ];
        let skills_dir = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("skills");
        let Ok(entries) = std::fs::read_dir(&skills_dir) else {
            // No skills dir in this checkout — nothing to guard.
            return;
        };
        for entry in entries.flatten() {
            let dir = entry.path();
            if !dir.is_dir() {
                continue;
            }
            // Only scan managed skills (sentinel present).
            if !dir.join(".managed").exists() {
                continue;
            }
            // Recursively scan every .md file under the managed skill.
            scan_md_for_needles(&dir, &needles);
        }
    }

    fn scan_md_for_needles(dir: &std::path::Path, needles: &[String]) {
        let Ok(entries) = std::fs::read_dir(dir) else {
            return;
        };
        for entry in entries.flatten() {
            let path = entry.path();
            if path.is_dir() {
                scan_md_for_needles(&path, needles);
                continue;
            }
            if path.extension().and_then(|e| e.to_str()) != Some("md") {
                continue;
            }
            let Ok(content) = std::fs::read_to_string(&path) else {
                continue;
            };
            for needle in needles {
                assert!(
                    !content.contains(needle.as_str()),
                    "{}: contains personal-info literal `{needle}` — route through MEMORY.md / rules/",
                    path.display()
                );
            }
        }
    }

    /// Regression guard: no hardcoded personal info leaks into embedded system
    /// prompts or critical skill/memory source files. Banned needles are
    /// constructed from parts so this test file itself doesn't contain them.
    ///
    /// User info belongs in `~/.tron/memory/MEMORY.md` (auto-loaded
    /// into every session's context). Hardcoded names/emails/handles are a
    /// correctness bug — they assume one user and ship that assumption in the
    /// binary. See [`crate::runtime::memory`] for the canonical load path.
    #[test]
    fn workspace_has_no_personal_info_literals() {
        let needles = [
            format!("{}{}{}", "M", "oh", "sin"),
            format!("{}{}{}", "Is", "ma", "il"),
            format!("{}{}{}", "is", "ma", "il"),
            format!("{}{}{}", "mh", "is", "mail"),
        ];
        let manifest_dir = std::path::Path::new(env!("CARGO_MANIFEST_DIR"));
        let offenders: Vec<(&str, String)> = vec![
            ("paths.rs", include_str!("paths.rs").to_owned()),
            (
                "defaults/profiles/default/prompts/core.md",
                std::fs::read_to_string(
                    manifest_dir.join("defaults/profiles/default/prompts/core.md"),
                )
                .unwrap(),
            ),
            (
                "defaults/profiles/default/prompts/chat.md",
                std::fs::read_to_string(
                    manifest_dir.join("defaults/profiles/default/prompts/chat.md"),
                )
                .unwrap(),
            ),
            (
                "defaults/profiles/default/prompts/local.md",
                std::fs::read_to_string(
                    manifest_dir.join("defaults/profiles/default/prompts/local.md"),
                )
                .unwrap(),
            ),
            (
                "runtime/memory/registry.rs",
                include_str!("../../runtime/memory/registry.rs").to_owned(),
            ),
            (
                "runtime/memory/mod.rs",
                include_str!("../../runtime/memory/mod.rs").to_owned(),
            ),
            (
                "skills/discovery/loader.rs",
                include_str!("../../skills/discovery/loader.rs").to_owned(),
            ),
            (
                "skills/discovery/registry.rs",
                include_str!("../../skills/discovery/registry.rs").to_owned(),
            ),
        ];
        for (name, src) in &offenders {
            for needle in &needles {
                assert!(
                    !src.contains(needle.as_str()),
                    "{name}: contains personal-info literal `{needle}` — route through MEMORY.md instead"
                );
            }
        }
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
    fn tron_home_supports_explicit_developer_roots() {
        assert_eq!(
            resolve_tron_home("/Users/dev", Some("/tmp/tron-data"), None),
            PathBuf::from("/tmp/tron-data")
        );
        assert_eq!(
            resolve_tron_home("/Users/dev", None, Some(".tron-dev")),
            PathBuf::from("/Users/dev/.tron-dev")
        );
    }

    #[test]
    fn tron_home_name_rejects_nested_paths() {
        assert!(!valid_home_relative_name("../other"));
        assert!(!valid_home_relative_name("nested/path"));
        assert!(!valid_home_relative_name("."));
        assert!(valid_home_relative_name(".tron-dev"));
    }

    #[test]
    fn tron_home_returns_pathbuf() {
        let result = tron_home();
        assert!(result.to_string_lossy().ends_with(".tron"));
    }

    // ── Top-level dirs ─────────────────────────────────────────────

    #[test]
    fn internal_dir_under_tron_home() {
        let p = internal_dir();
        assert!(p.ends_with(format!(".tron/{}", dirs::INTERNAL)));
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
    fn profiles_dir_under_tron_home() {
        let p = profiles_dir();
        assert!(p.ends_with(format!(".tron/{}", dirs::PROFILES)));
    }

    #[test]
    fn memory_dir_under_tron_home() {
        let p = memory_dir();
        assert!(p.ends_with(format!(".tron/{}", dirs::MEMORY)));
    }

    // ── Workspace subdirs ──────────────────────────────────────────

    #[test]
    fn rules_dir_chains_correctly() {
        let p = rules_dir();
        assert!(p.ends_with(format!("{}/{}", dirs::MEMORY, dirs::RULES)));
    }

    #[test]
    fn scratch_dir_chains_correctly() {
        let p = scratch_dir();
        assert!(p.ends_with(format!("{}/{}", dirs::WORKSPACE, dirs::SCRATCH)));
    }

    #[test]
    fn automations_dir_chains_correctly() {
        let p = automations_dir();
        assert!(p.ends_with(format!("{}/{}", dirs::WORKSPACE, dirs::AUTOMATIONS)));
    }

    #[test]
    fn screenshots_dir_chains_correctly() {
        let p = screenshots_dir();
        assert!(p.ends_with(format!(
            "{}/{}/{}",
            dirs::WORKSPACE,
            dirs::ARTIFACTS,
            dirs::SCREENSHOTS
        )));
    }

    // ── Composite file paths ───────────────────────────────────────

    #[test]
    fn global_system_prompt_path_correct() {
        let p = global_system_prompt_path();
        assert!(p.ends_with(format!("{}/user/{}/core.md", dirs::PROFILES, dirs::PROMPTS)));
    }

    #[test]
    fn automations_path_correct() {
        let p = automations_path();
        assert!(p.ends_with(format!(
            "{}/{}/{}",
            dirs::WORKSPACE,
            dirs::AUTOMATIONS,
            files::AUTOMATIONS_JSON
        )));
    }

    #[test]
    fn automations_backup_path_correct() {
        let p = automations_backup_path();
        assert!(p.ends_with(format!(
            "{}/{}/automations.json.bak",
            dirs::WORKSPACE,
            dirs::AUTOMATIONS
        )));
    }

    #[test]
    fn settings_path_correct() {
        let p = settings_path();
        assert!(p.ends_with(format!("{}/user/{}", dirs::PROFILES, files::PROFILE_TOML)));
    }

    #[test]
    fn tron_binary_path_correct() {
        let p = tron_binary_path();
        assert!(
            p.file_name().is_some(),
            "current executable path should resolve to a concrete file name"
        );
    }

    #[test]
    fn run_dir_under_internal() {
        let p = run_dir();
        assert!(p.ends_with(format!("{}/{}", dirs::INTERNAL, dirs::RUN)));
    }

    #[test]
    fn run_dir_for_home_uses_same_canonical_segments() {
        let home = std::path::Path::new("/tmp/tron-home");
        assert_eq!(
            run_dir_for_home(home),
            home.join(dirs::INTERNAL).join(dirs::RUN)
        );
        assert_eq!(
            auth_lock_path_for_home(home),
            home.join(dirs::INTERNAL).join(dirs::RUN).join("auth.lock")
        );
    }

    #[test]
    fn runtime_locks_under_run_dir() {
        assert!(auth_lock_path().ends_with(format!("{}/{}/auth.lock", dirs::INTERNAL, dirs::RUN)));
        assert!(mac_wrapper_lock_path().ends_with(format!(
            "{}/{}/.mac-wrapper.com.tron.mac.lock",
            dirs::INTERNAL,
            dirs::RUN
        )));
        assert!(
            mac_wrapper_lock_path_for("com.tron.mac.dev").ends_with(format!(
                "{}/{}/.mac-wrapper.com.tron.mac.dev.lock",
                dirs::INTERNAL,
                dirs::RUN
            ))
        );
    }

    #[test]
    fn journals_dir_under_db() {
        let p = journals_dir();
        assert!(p.ends_with(format!(
            "{}/{}/{}",
            dirs::INTERNAL,
            dirs::DB,
            dirs::JOURNALS
        )));
    }

    #[test]
    fn containers_path_correct() {
        let p = containers_path();
        assert!(p.ends_with(format!(
            "{}/user/{}",
            dirs::PROFILES,
            files::CONTAINERS_JSON
        )));
    }

    #[test]
    fn updater_state_path_lives_under_internal_dir() {
        let p = updater_state_path();
        let s = p.to_string_lossy();
        assert!(s.ends_with("/run/updater-state.json"), "got: {s}");
        assert!(
            s.contains("/.tron/internal/run/"),
            "must live under ~/.tron/internal/run/, got: {s}"
        );
    }

    #[test]
    fn auto_update_pause_path_lives_under_internal_run() {
        let p = auto_update_pause_path();
        let s = p.to_string_lossy();
        assert!(
            s.ends_with("/.tron/internal/run/auto-update.pause"),
            "got: {s}"
        );
        assert!(
            s.contains("/.tron/internal/run/"),
            "auto-update.pause must live under ~/.tron/internal/run/, got: {s}"
        );
    }

    // ── Transcription sidecar ──────────────────────────────────────

    #[test]
    fn transcription_dir_under_internal() {
        let p = transcription_dir();
        assert!(p.ends_with(format!("{}/{}", dirs::INTERNAL, dirs::TRANSCRIPTION)));
    }

    #[test]
    fn transcription_venv_dir_correct() {
        let p = transcription_venv_dir();
        assert!(p.ends_with(format!("{}/{}/venv", dirs::INTERNAL, dirs::TRANSCRIPTION)));
    }

    #[test]
    fn transcription_worker_script_correct() {
        let p = transcription_worker_script();
        assert!(p.ends_with(format!(
            "{}/{}/worker.py",
            dirs::INTERNAL,
            dirs::TRANSCRIPTION
        )));
    }

    #[test]
    fn transcription_requirements_path_correct() {
        let p = transcription_requirements_path();
        assert!(p.ends_with(format!(
            "{}/{}/requirements.txt",
            dirs::INTERNAL,
            dirs::TRANSCRIPTION
        )));
    }

    #[test]
    fn transcription_hf_cache_dir_correct() {
        let p = transcription_hf_cache_dir();
        assert!(p.ends_with(format!(
            "{}/{}/models/hf",
            dirs::INTERNAL,
            dirs::TRANSCRIPTION
        )));
    }

    // ── Memory subdirs ──────────────────────────────────────────────

    #[test]
    fn memory_sessions_dir_chains_correctly() {
        let p = memory_sessions_dir();
        assert!(p.ends_with(format!("{}/{}", dirs::MEMORY, dirs::SESSIONS)));
    }

    #[test]
    fn memory_rules_dir_chains_correctly() {
        let p = memory_rules_dir();
        assert!(p.ends_with(format!("{}/{}", dirs::MEMORY, dirs::RULES)));
    }

    // ── Consistency guards ─────────────────────────────────────────

    #[test]
    fn tron_rules_relative_matches_constants() {
        let expected = format!(".tron/{}/{}", dirs::MEMORY, dirs::RULES);
        assert_eq!(
            dirs::TRON_RULES_RELATIVE,
            expected,
            "TRON_RULES_RELATIVE is out of sync with MEMORY/RULES constants"
        );
    }
}
