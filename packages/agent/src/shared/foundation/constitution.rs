//! Profile-first Tron Home layout, recovery, and context block types.
//!
//! Normal runtime code reads the five constitutional roots only:
//! `internal/`, `skills/`, `profiles/`, `memory/`, and `workspace/`.
//! Managed defaults are repaired from the compiled bundle when they are
//! missing, malformed, or stale relative to the current strict profile schema.

use std::fs;
use std::io;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

use super::paths::{self, dirs, files};
use super::profile::{CHAT_PROFILE, DEFAULT_PROFILE, LOCAL_PROFILE, NORMAL_PROFILE, USER_PROFILE};

/// Stable top-level homes in the profile-first Tron Home.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum TronHome {
    /// Complete agent execution specs.
    Profiles,
    /// Reusable plug-in capabilities.
    Skills,
    /// Durable world/user/environment continuity.
    Memory,
    /// Active substrate: projects, artifacts, experiments, knowledge, vault.
    Workspace,
    /// Tron-owned runtime machinery.
    Internal,
}

/// Provider-independent cache stability class for a context block.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum ContextCacheClass {
    /// Rarely changing default/profile blocks.
    Foundation,
    /// Active profile and user behavior overlays.
    Profile,
    /// Project rules, memory snapshot, skill index, and environment.
    Session,
    /// Dynamic rules, active skill bodies, job results, and latest turn.
    Turn,
    /// Secrets, vault values, and unsafe/volatile material.
    None,
}

/// Context sensitivity class.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum ContextSensitivity {
    /// Safe to display and audit directly.
    Public,
    /// Personal but non-secret material.
    Private,
    /// Secret material that must never enter model context raw.
    Secret,
}

/// Provider surface used for a context block after compilation.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum ProviderSurface {
    /// System/developer instruction surface.
    Instructions,
    /// User/message surface.
    Message,
    /// Tool schema or tool-description surface.
    Tool,
    /// Excluded from provider payload.
    Excluded,
}

/// Typed context unit compiled before provider adaptation.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ContextBlock {
    /// Stable identifier for audit and replay.
    pub id: String,
    /// Human-friendly label.
    pub name: String,
    /// Source home.
    pub home: TronHome,
    /// Filesystem source, when applicable.
    pub source_path: Option<String>,
    /// Content-addressed DB blob, when applicable.
    pub source_blob_id: Option<String>,
    /// SHA-256 hash of rendered text.
    pub hash: String,
    /// Estimated tokens for budgeting/audit.
    pub token_estimate: u64,
    /// Sensitivity class.
    pub sensitivity: ContextSensitivity,
    /// Why this block was included or excluded.
    pub inclusion_reason: String,
    /// Canonical ordering slot.
    pub precedence: u32,
    /// Abstract cache class before provider mapping.
    pub cache_class: ContextCacheClass,
    /// Provider payload surface.
    pub provider_surface: ProviderSurface,
    /// Lifecycle hint.
    pub lifecycle: String,
    /// Audit record ids associated with this block.
    pub audit_ids: Vec<String>,
    /// Rendered text.
    pub text: String,
}

/// Summary of seeding and repair work.
#[derive(Debug, Default)]
pub struct SeedReport {
    /// Created paths.
    pub seeded: Vec<PathBuf>,
    /// Repaired managed default paths.
    pub repaired: Vec<PathBuf>,
}

#[derive(Clone, Copy)]
enum DefaultKind {
    Text,
    Toml,
    Json,
}

struct ManagedDefault {
    relative_path: &'static str,
    content: &'static str,
    kind: DefaultKind,
    repair_if_invalid: bool,
}

macro_rules! managed_default {
    ($path:literal, $kind:expr, $repair_if_invalid:expr) => {
        ManagedDefault {
            relative_path: $path,
            content: include_str!(concat!("../../../defaults/", $path)),
            kind: $kind,
            repair_if_invalid: $repair_if_invalid,
        }
    };
}

const MANAGED_DEFAULTS: &[ManagedDefault] = &[
    managed_default!("profiles/active.toml", DefaultKind::Toml, true),
    managed_default!("profiles/auth.toml", DefaultKind::Toml, false),
    managed_default!("profiles/auth.json", DefaultKind::Json, false),
    managed_default!("profiles/default/profile.toml", DefaultKind::Toml, true),
    managed_default!("profiles/normal/profile.toml", DefaultKind::Toml, true),
    managed_default!("profiles/chat/profile.toml", DefaultKind::Toml, true),
    managed_default!("profiles/local/profile.toml", DefaultKind::Toml, true),
    managed_default!("profiles/user/profile.toml", DefaultKind::Toml, false),
    managed_default!("profiles/default/prompts/core.md", DefaultKind::Text, true),
    managed_default!("profiles/default/prompts/chat.md", DefaultKind::Text, true),
    managed_default!("profiles/default/prompts/local.md", DefaultKind::Text, true),
    managed_default!(
        "profiles/default/prompts/git-workflow.md",
        DefaultKind::Text,
        true
    ),
    managed_default!(
        "profiles/default/prompts/processes/compaction.md",
        DefaultKind::Text,
        true
    ),
    managed_default!(
        "profiles/default/prompts/processes/memory-retain.md",
        DefaultKind::Text,
        true
    ),
    managed_default!(
        "profiles/default/prompts/processes/conflict-resolver.md",
        DefaultKind::Text,
        true
    ),
    managed_default!(
        "profiles/default/prompts/processes/web-fetch-summarizer.md",
        DefaultKind::Text,
        true
    ),
    managed_default!(
        "profiles/default/providers/openai/codex-instructions.md",
        DefaultKind::Text,
        true
    ),
    managed_default!(
        "profiles/default/context/context-blocks.toml",
        DefaultKind::Toml,
        true
    ),
    managed_default!(
        "profiles/default/tools/presentation.toml",
        DefaultKind::Toml,
        true
    ),
];

/// Ensure the current Tron Home is recovered and structurally complete.
pub fn ensure_tron_home() -> io::Result<SeedReport> {
    ensure_tron_home_at(&paths::tron_home())
}

/// Ensure a specific Tron Home is recovered and structurally complete.
pub fn ensure_tron_home_at(home: &Path) -> io::Result<SeedReport> {
    let mut report = SeedReport::default();

    for dir in profile_first_dirs(home) {
        create_dir(&dir, &mut report)?;
    }

    recover_managed_defaults(home, &mut report)?;
    validate_active_profile(home)?;
    Ok(report)
}

fn profile_first_dirs(home: &Path) -> Vec<PathBuf> {
    vec![
        home.join(dirs::INTERNAL),
        home.join(dirs::INTERNAL).join(dirs::DB),
        home.join(dirs::INTERNAL).join(dirs::RUN),
        home.join(dirs::INTERNAL)
            .join(dirs::DB)
            .join(dirs::JOURNALS),
        home.join(dirs::INTERNAL).join(dirs::TRANSCRIPTION),
        home.join(dirs::SKILLS),
        home.join(dirs::PROFILES),
        home.join(dirs::PROFILES).join(DEFAULT_PROFILE),
        home.join(dirs::PROFILES).join(NORMAL_PROFILE),
        home.join(dirs::PROFILES).join(CHAT_PROFILE),
        home.join(dirs::PROFILES).join(LOCAL_PROFILE),
        home.join(dirs::PROFILES)
            .join(DEFAULT_PROFILE)
            .join(dirs::PROMPTS),
        home.join(dirs::PROFILES)
            .join(DEFAULT_PROFILE)
            .join(dirs::PROMPTS)
            .join("processes"),
        home.join(dirs::PROFILES)
            .join(DEFAULT_PROFILE)
            .join(dirs::PROVIDERS),
        home.join(dirs::PROFILES)
            .join(DEFAULT_PROFILE)
            .join(dirs::CONTEXT),
        home.join(dirs::PROFILES)
            .join(DEFAULT_PROFILE)
            .join(dirs::TOOLS),
        home.join(dirs::PROFILES).join(USER_PROFILE),
        home.join(dirs::PROFILES)
            .join(USER_PROFILE)
            .join(dirs::PROMPTS),
        home.join(dirs::MEMORY),
        home.join(dirs::MEMORY).join(dirs::SESSIONS),
        home.join(dirs::MEMORY).join(dirs::RULES),
        home.join(dirs::WORKSPACE),
        home.join(dirs::WORKSPACE).join(dirs::INBOX),
        home.join(dirs::WORKSPACE)
            .join(dirs::INBOX)
            .join(dirs::VOICE_NOTES),
        home.join(dirs::WORKSPACE).join(dirs::PROJECTS),
        home.join(dirs::WORKSPACE).join(dirs::AUTOMATIONS),
        home.join(dirs::WORKSPACE).join(dirs::PLANS),
        home.join(dirs::WORKSPACE).join(dirs::REPORTS),
        home.join(dirs::WORKSPACE).join(dirs::RENDERS),
        home.join(dirs::WORKSPACE).join(dirs::SCREENSHOTS),
        home.join(dirs::WORKSPACE).join(dirs::SCRATCH),
        home.join(dirs::WORKSPACE).join(dirs::LABS),
        home.join(dirs::WORKSPACE).join(dirs::ARCHIVE),
        home.join(dirs::WORKSPACE).join(dirs::KNOWLEDGE),
        home.join(dirs::WORKSPACE).join(dirs::VAULT),
    ]
}

fn create_dir(path: &Path, report: &mut SeedReport) -> io::Result<()> {
    if !path.exists() {
        fs::create_dir_all(path)?;
        report.seeded.push(path.to_path_buf());
    }
    Ok(())
}

fn recover_managed_defaults(home: &Path, report: &mut SeedReport) -> io::Result<()> {
    for default in MANAGED_DEFAULTS {
        let path = home.join(default.relative_path);
        let existed_before = path.exists();
        let should_write = if existed_before {
            default.repair_if_invalid && !managed_default_valid(&path, default.kind)
        } else {
            true
        };

        if should_write {
            write_managed_default(&path, default.content)?;
            if existed_before {
                report.repaired.push(path);
            } else {
                report.seeded.push(path);
            }
        }
    }
    Ok(())
}

fn write_managed_default(path: &Path, content: &str) -> io::Result<()> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }
    fs::write(path, content)
}

fn managed_default_valid(path: &Path, kind: DefaultKind) -> bool {
    let Ok(content) = fs::read_to_string(path) else {
        return false;
    };
    if content.trim().is_empty() {
        return false;
    }
    match kind {
        DefaultKind::Text => true,
        DefaultKind::Toml => {
            let Ok(value) = toml::from_str::<toml::Value>(&content) else {
                return false;
            };
            if path.file_name().and_then(|name| name.to_str()) == Some(files::ACTIVE_TOML) {
                return value
                    .get("active")
                    .and_then(toml::Value::as_str)
                    .is_some_and(|active| !active.trim().is_empty() && active != DEFAULT_PROFILE);
            }
            if path.file_name().and_then(|name| name.to_str()) == Some(files::PROFILE_TOML)
                && let Some(profile_name) = path
                    .parent()
                    .and_then(Path::file_name)
                    .and_then(|name| name.to_str())
                && [DEFAULT_PROFILE, NORMAL_PROFILE, CHAT_PROFILE, LOCAL_PROFILE]
                    .contains(&profile_name)
            {
                if toml::from_str::<super::profile::ProfileDocument>(&content).is_err() {
                    return false;
                }
                return value
                    .get("name")
                    .and_then(toml::Value::as_str)
                    .is_some_and(|name| name == profile_name)
                    && value
                        .get("version")
                        .and_then(toml::Value::as_str)
                        .is_some_and(|version| version == super::profile::CURRENT_PROFILE_VERSION);
            }
            true
        }
        DefaultKind::Json => serde_json::from_str::<serde_json::Value>(&content).is_ok(),
    }
}

fn validate_active_profile(home: &Path) -> io::Result<()> {
    let active =
        super::profile::active_profile_name_at(home).unwrap_or_else(|| DEFAULT_PROFILE.to_string());
    let path = home
        .join(dirs::PROFILES)
        .join(&active)
        .join(files::PROFILE_TOML);
    if !path.exists() {
        return Err(io::Error::new(
            io::ErrorKind::NotFound,
            format!("active profile `{active}` is missing {}", path.display()),
        ));
    }
    super::profile::resolve_profile_at(home, &active).map(|_| ())
}

/// Create a context block from rendered text and constitutional metadata.
#[must_use]
pub fn context_block_for_text(
    id: impl Into<String>,
    name: impl Into<String>,
    home: TronHome,
    text: impl Into<String>,
    cache_class: ContextCacheClass,
    precedence: u32,
) -> ContextBlock {
    let text = text.into();
    ContextBlock {
        id: id.into(),
        name: name.into(),
        home,
        source_path: None,
        source_blob_id: None,
        hash: sha256_hex(text.as_bytes()),
        token_estimate: estimate_tokens(&text),
        sensitivity: ContextSensitivity::Public,
        inclusion_reason: "compiled by profile context policy".into(),
        precedence,
        cache_class,
        provider_surface: ProviderSurface::Instructions,
        lifecycle: "runtime".into(),
        audit_ids: Vec::new(),
        text,
    }
}

/// Read the active profile name.
#[must_use]
pub fn active_profile_name() -> Option<String> {
    super::profile::active_profile_name()
}

/// Hash bytes with SHA-256 as lower-case hex.
#[must_use]
pub fn sha256_hex(bytes: &[u8]) -> String {
    let digest = Sha256::digest(bytes);
    hex::encode(digest)
}

fn estimate_tokens(text: &str) -> u64 {
    (text.len() as u64).div_ceil(4)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn context_block_hashes_rendered_text() {
        let block = context_block_for_text(
            "core",
            "Core prompt",
            TronHome::Profiles,
            "hello",
            ContextCacheClass::Foundation,
            10,
        );
        assert_eq!(block.hash, sha256_hex(b"hello"));
        assert_eq!(block.cache_class, ContextCacheClass::Foundation);
        assert_eq!(block.precedence, 10);
    }

    #[test]
    fn seeding_creates_profile_first_layout() {
        let dir = tempfile::tempdir().unwrap();
        let home = dir.path().join(".tron");
        let report = ensure_tron_home_at(&home).unwrap();

        assert!(!report.seeded.is_empty());
        assert!(home.join(dirs::INTERNAL).exists());
        assert!(home.join(dirs::SKILLS).exists());
        assert!(home.join(dirs::PROFILES).exists());
        assert!(home.join(dirs::MEMORY).exists());
        assert!(home.join(dirs::WORKSPACE).exists());
        let mut top_level: Vec<String> = fs::read_dir(&home)
            .unwrap()
            .map(|entry| entry.unwrap().file_name().to_string_lossy().into_owned())
            .collect();
        top_level.sort();
        assert_eq!(
            top_level,
            vec![
                dirs::INTERNAL.to_string(),
                dirs::MEMORY.to_string(),
                dirs::PROFILES.to_string(),
                dirs::SKILLS.to_string(),
                dirs::WORKSPACE.to_string(),
            ],
            "fresh Tron Home should expose exactly the five root primitives"
        );
        assert!(
            home.join(dirs::PROFILES)
                .join(DEFAULT_PROFILE)
                .join(files::PROFILE_TOML)
                .exists()
        );
        assert!(
            home.join(dirs::PROFILES)
                .join(DEFAULT_PROFILE)
                .join(dirs::PROMPTS)
                .join("core.md")
                .exists()
        );
        assert!(
            home.join(dirs::PROFILES)
                .join(DEFAULT_PROFILE)
                .join(dirs::PROMPTS)
                .join("processes")
                .join("compaction.md")
                .exists()
        );
        assert!(
            !home
                .join(dirs::PROFILES)
                .join(DEFAULT_PROFILE)
                .join("summarizers")
                .exists()
        );
        assert!(
            !home
                .join(dirs::PROFILES)
                .join(DEFAULT_PROFILE)
                .join("subagents")
                .exists()
        );
        assert!(
            home.join(dirs::PROFILES)
                .join(USER_PROFILE)
                .join(files::PROFILE_TOML)
                .exists()
        );
        assert!(home.join(dirs::WORKSPACE).join(dirs::KNOWLEDGE).exists());
        assert!(home.join(dirs::WORKSPACE).join(dirs::VAULT).exists());
        assert!(home.join(dirs::WORKSPACE).join(dirs::RENDERS).exists());
        assert!(home.join(dirs::WORKSPACE).join(dirs::SCREENSHOTS).exists());
        assert!(!home.join(dirs::WORKSPACE).join("artifacts").exists());
        assert!(!home.join(dirs::WORKSPACE).join("exports").exists());
        assert!(!home.join("instructions").exists());
        assert!(!home.join("settings").exists());
    }

    #[test]
    fn seeding_repairs_schema_stale_managed_profile() {
        let dir = tempfile::tempdir().unwrap();
        let home = dir.path().join(".tron");
        ensure_tron_home_at(&home).unwrap();

        let default_profile = home
            .join(dirs::PROFILES)
            .join(DEFAULT_PROFILE)
            .join(files::PROFILE_TOML);
        let stale = fs::read_to_string(&default_profile).unwrap().replace(
            "reasoning = \"medium\"\naudit = true",
            "reasoning = \"medium\"\nremovedProcessMode = \"keyword\"\naudit = true",
        );
        fs::write(&default_profile, stale).unwrap();

        let report = ensure_tron_home_at(&home).unwrap();
        assert!(
            report.repaired.contains(&default_profile),
            "schema-stale managed profile should be repaired from bundled defaults"
        );
        let repaired = fs::read_to_string(&default_profile).unwrap();
        assert!(!repaired.contains("removedProcessMode ="));
        crate::shared::profile::resolve_profile_at(&home, NORMAL_PROFILE).unwrap();
    }

    #[test]
    fn seeding_creates_empty_auth_json_sentinel() {
        let dir = tempfile::tempdir().unwrap();
        let home = dir.path().join(".tron");

        ensure_tron_home_at(&home).unwrap();

        let auth_path = home.join(dirs::PROFILES).join(files::AUTH_JSON);
        let raw = fs::read_to_string(&auth_path).unwrap();
        let parsed: serde_json::Value = serde_json::from_str(&raw).unwrap();
        assert!(
            parsed.as_object().is_some_and(serde_json::Map::is_empty),
            "fresh Constitution seed must leave auth.json as the pristine install sentinel"
        );
    }

    #[test]
    fn managed_default_is_repaired_when_corrupt() {
        let dir = tempfile::tempdir().unwrap();
        let home = dir.path().join(".tron");
        ensure_tron_home_at(&home).unwrap();

        let profile = home
            .join(dirs::PROFILES)
            .join(DEFAULT_PROFILE)
            .join(files::PROFILE_TOML);
        fs::write(&profile, "{broken").unwrap();

        let report = ensure_tron_home_at(&home).unwrap();

        assert!(report.repaired.iter().any(|path| path == &profile));
        assert!(toml::from_str::<toml::Value>(&fs::read_to_string(profile).unwrap()).is_ok());
    }

    #[test]
    fn missing_custom_active_profile_fails_clearly() {
        let dir = tempfile::tempdir().unwrap();
        let home = dir.path().join(".tron");
        ensure_tron_home_at(&home).unwrap();
        fs::write(
            home.join(dirs::PROFILES).join(files::ACTIVE_TOML),
            "active = \"custom\"\n",
        )
        .unwrap();

        let error = ensure_tron_home_at(&home).unwrap_err();

        assert!(
            error
                .to_string()
                .contains("active profile `custom` is missing")
        );
    }
}
