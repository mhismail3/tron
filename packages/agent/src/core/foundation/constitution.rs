//! Profile-first Tron Home layout, recovery, migration, and context block types.
//!
//! Normal runtime code reads the five constitutional roots only:
//! `internal/`, `skills/`, `profiles/`, `memory/`, and `workspace/`.
//! Historical paths are known only to the one-way migrator in this module.

use std::env;
use std::fs;
use std::io;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

use super::paths::{self, dirs, files};
use super::profile::{DEFAULT_PROFILE, USER_PROFILE};

const LEGACY_DEFAULT_PROFILE: &str = "master-default";

/// Diagnostic-only prompt used when a non-managed user profile is unreadable.
pub const EMERGENCY_REPAIR_PROMPT: &str = "Tron profile instructions are missing or unreadable. Explain that ~/.tron/profiles/ must be repaired, avoid pretending the requested custom profile is available, and help the user restore or switch profiles.";

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

/// Summary of seeding, repair, and migration work.
#[derive(Debug, Default)]
pub struct SeedReport {
    /// Created paths.
    pub seeded: Vec<PathBuf>,
    /// Repaired managed default paths.
    pub repaired: Vec<PathBuf>,
    /// Historical paths moved into the five-root layout.
    pub migrated: Vec<(PathBuf, PathBuf)>,
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
    managed_default!("profiles/default/prompts/core.md", DefaultKind::Text, true),
    managed_default!("profiles/default/prompts/chat.md", DefaultKind::Text, true),
    managed_default!("profiles/default/prompts/local.md", DefaultKind::Text, true),
    managed_default!(
        "profiles/default/prompts/git-workflow.md",
        DefaultKind::Text,
        true
    ),
    managed_default!(
        "profiles/default/summarizers/compaction.md",
        DefaultKind::Text,
        true
    ),
    managed_default!(
        "profiles/default/summarizers/memory-retain.md",
        DefaultKind::Text,
        true
    ),
    managed_default!(
        "profiles/default/subagents/conflict-resolver.md",
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
    managed_default!(
        "profiles/default/settings/defaults.json",
        DefaultKind::Json,
        true
    ),
];

/// Ensure the current Tron Home is migrated, recovered, and structurally complete.
pub fn ensure_tron_home() -> io::Result<SeedReport> {
    ensure_tron_home_at(&paths::tron_home())
}

/// Ensure a specific Tron Home is migrated, recovered, and structurally complete.
pub fn ensure_tron_home_at(home: &Path) -> io::Result<SeedReport> {
    let mut report = SeedReport {
        migrated: migrate_legacy_home(home)?,
        ..SeedReport::default()
    };

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
        home.join(dirs::PROFILES)
            .join(DEFAULT_PROFILE)
            .join(dirs::PROMPTS),
        home.join(dirs::PROFILES)
            .join(DEFAULT_PROFILE)
            .join(dirs::SUMMARIZERS),
        home.join(dirs::PROFILES)
            .join(DEFAULT_PROFILE)
            .join(dirs::SUBAGENTS),
        home.join(dirs::PROFILES)
            .join(DEFAULT_PROFILE)
            .join(dirs::PROVIDERS),
        home.join(dirs::PROFILES)
            .join(DEFAULT_PROFILE)
            .join(dirs::CONTEXT),
        home.join(dirs::PROFILES)
            .join(DEFAULT_PROFILE)
            .join(dirs::TOOLS),
        home.join(dirs::PROFILES)
            .join(DEFAULT_PROFILE)
            .join(dirs::SETTINGS),
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
        home.join(dirs::WORKSPACE).join(dirs::ARTIFACTS),
        home.join(dirs::WORKSPACE)
            .join(dirs::ARTIFACTS)
            .join(dirs::RENDERS),
        home.join(dirs::WORKSPACE)
            .join(dirs::ARTIFACTS)
            .join(dirs::SCREENSHOTS),
        home.join(dirs::WORKSPACE)
            .join(dirs::ARTIFACTS)
            .join(dirs::EXPORTS),
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
                    .is_some_and(|active| !active.trim().is_empty());
            }
            if path.file_name().and_then(|name| name.to_str()) == Some(files::PROFILE_TOML)
                && path
                    .parent()
                    .and_then(Path::file_name)
                    .and_then(|name| name.to_str())
                    == Some(DEFAULT_PROFILE)
            {
                return value
                    .get("name")
                    .and_then(toml::Value::as_str)
                    .is_some_and(|name| name == DEFAULT_PROFILE);
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

/// Resolve a bundled profile default file by path relative to
/// `packages/agent/defaults` or the app-bundled `Resources/Constitution`.
#[must_use]
pub fn bundled_default_file(relative_path: impl AsRef<Path>) -> Option<PathBuf> {
    let path = bundled_defaults_dir()?.join(relative_path);
    path.is_file().then_some(path)
}

fn bundled_defaults_dir() -> Option<PathBuf> {
    if let Ok(value) = env::var("TRON_CONSTITUTION_DEFAULTS_DIR") {
        let path = PathBuf::from(value);
        if path.join(dirs::PROFILES).is_dir() {
            return Some(path);
        }
    }

    let manifest_defaults = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("defaults");
    if manifest_defaults.join(dirs::PROFILES).is_dir() {
        return Some(manifest_defaults);
    }

    if let Ok(exe) = env::current_exe() {
        for ancestor in exe.ancestors() {
            for relative in [
                Path::new("Resources").join("Constitution"),
                PathBuf::from("Constitution"),
                PathBuf::from("defaults"),
            ] {
                let candidate = ancestor.join(relative);
                if candidate.join(dirs::PROFILES).is_dir() {
                    return Some(candidate);
                }
            }
        }
    }

    None
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

// MIGRATION-ONLY: this is the only place normal code is allowed to know about
// pre-profile-first Tron Home paths. Once a migrated install has been live
// verified, delete this function and tighten the path guard test from
// "migration-only allowlist" to "zero old-path references".
fn migrate_legacy_home(home: &Path) -> io::Result<Vec<(PathBuf, PathBuf)>> {
    let mut migrated = Vec::new();

    migrate_legacy_default_profile_name(home, &mut migrated)?;

    let old_system = home.join("system");
    move_path(
        &old_system.join("database"),
        &home.join(dirs::INTERNAL).join(dirs::DB),
        &mut migrated,
    )?;
    move_path(
        &old_system.join("run"),
        &home.join(dirs::INTERNAL).join(dirs::RUN),
        &mut migrated,
    )?;
    move_path(
        &old_system.join("transcription"),
        &home.join(dirs::INTERNAL).join(dirs::TRANSCRIPTION),
        &mut migrated,
    )?;
    remove_generated_transcription_artifacts(&home.join(dirs::INTERNAL).join(dirs::TRANSCRIPTION))?;
    move_path(
        &old_system.join("settings.json"),
        &home
            .join(dirs::PROFILES)
            .join(USER_PROFILE)
            .join(files::SETTINGS_JSON),
        &mut migrated,
    )?;
    move_path(
        &old_system.join("containers.json"),
        &home
            .join(dirs::PROFILES)
            .join(USER_PROFILE)
            .join(files::CONTAINERS_JSON),
        &mut migrated,
    )?;
    move_path(
        &old_system.join("auth.json"),
        &home.join(dirs::PROFILES).join(files::AUTH_JSON),
        &mut migrated,
    )?;

    let old_instructions = home.join("instructions");
    move_path(
        &old_instructions.join("profiles").join(USER_PROFILE),
        &home.join(dirs::PROFILES).join(USER_PROFILE),
        &mut migrated,
    )?;
    move_path(
        &old_instructions.join("defaults"),
        &home
            .join(dirs::WORKSPACE)
            .join(dirs::ARCHIVE)
            .join("profile-migration")
            .join("instructions-defaults"),
        &mut migrated,
    )?;

    let old_settings = home.join("settings");
    move_path(
        &old_settings.join("settings.json"),
        &home
            .join(dirs::PROFILES)
            .join(USER_PROFILE)
            .join(files::SETTINGS_JSON),
        &mut migrated,
    )?;
    move_path(
        &old_settings.join("containers.json"),
        &home
            .join(dirs::PROFILES)
            .join(USER_PROFILE)
            .join(files::CONTAINERS_JSON),
        &mut migrated,
    )?;
    move_path(
        &old_settings.join("defaults.json"),
        &home
            .join(dirs::WORKSPACE)
            .join(dirs::ARCHIVE)
            .join("profile-migration")
            .join("settings-defaults.json"),
        &mut migrated,
    )?;

    move_path(
        &home.join("knowledge"),
        &home.join(dirs::WORKSPACE).join(dirs::KNOWLEDGE),
        &mut migrated,
    )?;

    let old_vault = home.join("vault");
    move_path(
        &old_vault.join(files::AUTH_JSON),
        &home.join(dirs::PROFILES).join(files::AUTH_JSON),
        &mut migrated,
    )?;
    move_path(
        &old_vault,
        &home.join(dirs::WORKSPACE).join(dirs::VAULT),
        &mut migrated,
    )?;

    let old_workspace = home.join(dirs::WORKSPACE);
    move_path(
        &old_workspace.join("memory"),
        &home.join(dirs::MEMORY),
        &mut migrated,
    )?;
    move_path(
        &old_workspace.join("knowledge"),
        &home.join(dirs::WORKSPACE).join(dirs::KNOWLEDGE),
        &mut migrated,
    )?;
    move_path(
        &old_workspace.join("vault"),
        &home.join(dirs::WORKSPACE).join(dirs::VAULT),
        &mut migrated,
    )?;
    move_path(
        &old_workspace.join("renders"),
        &home
            .join(dirs::WORKSPACE)
            .join(dirs::ARTIFACTS)
            .join(dirs::RENDERS),
        &mut migrated,
    )?;
    move_path(
        &old_workspace.join("screenshots"),
        &home
            .join(dirs::WORKSPACE)
            .join(dirs::ARTIFACTS)
            .join(dirs::SCREENSHOTS),
        &mut migrated,
    )?;
    move_path(
        &old_workspace.join("voice notes"),
        &home
            .join(dirs::WORKSPACE)
            .join(dirs::INBOX)
            .join(dirs::VOICE_NOTES),
        &mut migrated,
    )?;

    remove_empty_dir(&old_system)?;
    remove_empty_dir(&old_instructions)?;
    remove_empty_dir(&old_settings)?;
    remove_empty_dir(&home.join("user"))?;
    Ok(migrated)
}

fn migrate_legacy_default_profile_name(
    home: &Path,
    migrated: &mut Vec<(PathBuf, PathBuf)>,
) -> io::Result<()> {
    let profiles_dir = home.join(dirs::PROFILES);
    let old_default_dir = profiles_dir.join(LEGACY_DEFAULT_PROFILE);
    let default_dir = profiles_dir.join(DEFAULT_PROFILE);

    if old_default_dir.exists() {
        if default_dir.exists() {
            remove_path_recursively(&old_default_dir)?;
            migrated.push((old_default_dir, default_dir));
        } else {
            move_path(&old_default_dir, &default_dir, migrated)?;
        }
    }

    rewrite_legacy_active_profile(&profiles_dir.join(files::ACTIVE_TOML), migrated)?;
    rewrite_profile_docs_for_default_rename(&profiles_dir, migrated)
}

fn rewrite_legacy_active_profile(
    active_path: &Path,
    migrated: &mut Vec<(PathBuf, PathBuf)>,
) -> io::Result<()> {
    let Ok(content) = fs::read_to_string(active_path) else {
        return Ok(());
    };
    let Ok(mut value) = toml::from_str::<toml::Value>(&content) else {
        return Ok(());
    };
    let Some(table) = value.as_table_mut() else {
        return Ok(());
    };
    let Some(active) = table.get("active").and_then(toml::Value::as_str) else {
        return Ok(());
    };
    if active != LEGACY_DEFAULT_PROFILE {
        return Ok(());
    }

    table.insert(
        "active".to_string(),
        toml::Value::String(DEFAULT_PROFILE.to_string()),
    );
    write_toml_value(active_path, &value)?;
    migrated.push((active_path.to_path_buf(), active_path.to_path_buf()));
    Ok(())
}

fn rewrite_profile_docs_for_default_rename(
    profiles_dir: &Path,
    migrated: &mut Vec<(PathBuf, PathBuf)>,
) -> io::Result<()> {
    if !profiles_dir.is_dir() {
        return Ok(());
    }

    for entry in fs::read_dir(profiles_dir)? {
        let entry = entry?;
        if !entry.file_type()?.is_dir() {
            continue;
        }
        let profile_name = entry.file_name().to_string_lossy().into_owned();
        let profile_path = entry.path().join(files::PROFILE_TOML);
        rewrite_legacy_profile_doc(&profile_path, &profile_name, migrated)?;
    }
    Ok(())
}

fn rewrite_legacy_profile_doc(
    profile_path: &Path,
    profile_dir_name: &str,
    migrated: &mut Vec<(PathBuf, PathBuf)>,
) -> io::Result<()> {
    let Ok(content) = fs::read_to_string(profile_path) else {
        return Ok(());
    };
    let Ok(mut value) = toml::from_str::<toml::Value>(&content) else {
        return Ok(());
    };
    let Some(table) = value.as_table_mut() else {
        return Ok(());
    };

    let mut changed = false;
    if profile_dir_name == DEFAULT_PROFILE
        && table.get("name").and_then(toml::Value::as_str) == Some(LEGACY_DEFAULT_PROFILE)
    {
        table.insert(
            "name".to_string(),
            toml::Value::String(DEFAULT_PROFILE.to_string()),
        );
        changed = true;
    }

    if let Some(inherits) = table
        .get_mut("inherits")
        .and_then(toml::Value::as_array_mut)
    {
        for inherited in inherits {
            if inherited.as_str() == Some(LEGACY_DEFAULT_PROFILE) {
                *inherited = toml::Value::String(DEFAULT_PROFILE.to_string());
                changed = true;
            }
        }
    }

    if changed {
        write_toml_value(profile_path, &value)?;
        migrated.push((profile_path.to_path_buf(), profile_path.to_path_buf()));
    }
    Ok(())
}

fn write_toml_value(path: &Path, value: &toml::Value) -> io::Result<()> {
    let content = toml::to_string_pretty(value).map_err(|error| {
        io::Error::new(
            io::ErrorKind::InvalidData,
            format!("failed to serialize {}: {error}", path.display()),
        )
    })?;
    fs::write(path, content)
}

fn remove_generated_transcription_artifacts(transcription_dir: &Path) -> io::Result<()> {
    // Python virtualenvs are not safely relocatable; after moving the
    // transcription home, recreate generated runtime pieces at their new path.
    for relative in ["venv", "models/hf/xet/logs"] {
        let path = transcription_dir.join(relative);
        if path.is_dir() {
            fs::remove_dir_all(path)?;
        } else if path.is_file() {
            fs::remove_file(path)?;
        }
    }
    Ok(())
}

fn move_path(from: &Path, to: &Path, migrated: &mut Vec<(PathBuf, PathBuf)>) -> io::Result<()> {
    if from == to {
        return Ok(());
    }
    if !from.exists() {
        return Ok(());
    }
    if let Some(parent) = to.parent() {
        fs::create_dir_all(parent)?;
    }
    if to.exists() {
        merge_path(from, to, migrated)?;
        return Ok(());
    }
    fs::rename(from, to)?;
    migrated.push((from.to_path_buf(), to.to_path_buf()));
    Ok(())
}

fn merge_path(from: &Path, to: &Path, migrated: &mut Vec<(PathBuf, PathBuf)>) -> io::Result<()> {
    if from.is_file() {
        let quarantine = quarantine_path_for(to);
        fs::rename(from, &quarantine)?;
        migrated.push((from.to_path_buf(), quarantine));
        return Ok(());
    }

    for entry in fs::read_dir(from)? {
        let entry = entry?;
        let child_from = entry.path();
        let child_to = to.join(entry.file_name());
        move_path(&child_from, &child_to, migrated)?;
    }
    remove_empty_dir(from)
}

fn quarantine_path_for(path: &Path) -> PathBuf {
    let mut candidate = path.with_extension("legacy-unmigrated");
    let mut counter = 1;
    while candidate.exists() {
        candidate = path.with_extension(format!("legacy-unmigrated-{counter}"));
        counter += 1;
    }
    candidate
}

fn remove_empty_dir(path: &Path) -> io::Result<()> {
    if path.is_dir() && fs::read_dir(path)?.next().is_none() {
        fs::remove_dir(path)?;
    }
    Ok(())
}

fn remove_path_recursively(path: &Path) -> io::Result<()> {
    if path.is_dir() {
        fs::remove_dir_all(path)
    } else if path.is_file() {
        fs::remove_file(path)
    } else {
        Ok(())
    }
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
                .join(dirs::SETTINGS)
                .join(files::DEFAULTS_JSON)
                .exists()
        );
        assert!(home.join(dirs::WORKSPACE).join(dirs::KNOWLEDGE).exists());
        assert!(home.join(dirs::WORKSPACE).join(dirs::VAULT).exists());
        assert!(!home.join("instructions").exists());
        assert!(!home.join("settings").exists());
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

    #[test]
    fn legacy_layout_moves_to_profile_first_layout() {
        let dir = tempfile::tempdir().unwrap();
        let home = dir.path().join(".tron");
        fs::create_dir_all(home.join("system/database")).unwrap();
        fs::create_dir_all(home.join("workspace/memory/rules")).unwrap();
        fs::create_dir_all(home.join("system/transcription/venv")).unwrap();
        fs::create_dir_all(home.join("system/transcription/models/hf/xet/logs")).unwrap();
        fs::write(home.join("system/settings.json"), "{}").unwrap();
        fs::write(home.join("system/transcription/worker.py"), "worker").unwrap();
        fs::write(home.join("system/transcription/venv/pyvenv.cfg"), "venv").unwrap();
        fs::write(
            home.join("system/transcription/models/hf/xet/logs/old.log"),
            "log",
        )
        .unwrap();
        fs::write(home.join("workspace/memory/MEMORY.md"), "memory").unwrap();
        fs::create_dir_all(home.join("knowledge")).unwrap();
        fs::write(home.join("knowledge/page.md"), "knowledge").unwrap();

        let report = ensure_tron_home_at(&home).unwrap();

        assert!(!report.migrated.is_empty());
        assert!(home.join("internal/database").exists());
        assert!(home.join("profiles/user/settings.json").exists());
        assert!(home.join("memory/MEMORY.md").exists());
        assert!(home.join("internal/transcription/worker.py").exists());
        assert!(!home.join("internal/transcription/venv").exists());
        assert!(
            !home
                .join("internal/transcription/models/hf/xet/logs")
                .exists()
        );
        assert!(home.join("workspace/knowledge/page.md").exists());
        assert!(!home.join("system").exists());
        assert!(!home.join("knowledge").exists());
    }

    #[test]
    fn legacy_default_profile_name_migrates_to_default() {
        let dir = tempfile::tempdir().unwrap();
        let home = dir.path().join(".tron");
        fs::create_dir_all(home.join("profiles").join(LEGACY_DEFAULT_PROFILE)).unwrap();
        fs::create_dir_all(home.join("profiles/user")).unwrap();
        fs::write(
            home.join("profiles").join(files::ACTIVE_TOML),
            format!("active = \"{LEGACY_DEFAULT_PROFILE}\"\n"),
        )
        .unwrap();
        fs::write(
            home.join("profiles")
                .join(LEGACY_DEFAULT_PROFILE)
                .join(files::PROFILE_TOML),
            format!(
                "version = \"1\"\nname = \"{LEGACY_DEFAULT_PROFILE}\"\nmanaged = true\ninherits = []\nauthProfile = \"default\"\n"
            ),
        )
        .unwrap();
        fs::write(
            home.join("profiles/user").join(files::PROFILE_TOML),
            format!(
                "version = \"1\"\nname = \"user\"\nmanaged = false\ninherits = [\"{LEGACY_DEFAULT_PROFILE}\"]\nauthProfile = \"default\"\n"
            ),
        )
        .unwrap();

        ensure_tron_home_at(&home).unwrap();

        assert!(!home.join("profiles").join(LEGACY_DEFAULT_PROFILE).exists());
        assert!(home.join("profiles").join(DEFAULT_PROFILE).exists());
        let active = fs::read_to_string(home.join("profiles").join(files::ACTIVE_TOML)).unwrap();
        assert!(active.contains("active = \"default\""));
        let default_profile = fs::read_to_string(
            home.join("profiles")
                .join(DEFAULT_PROFILE)
                .join(files::PROFILE_TOML),
        )
        .unwrap();
        assert!(default_profile.contains("name = \"default\""));
        let user_profile =
            fs::read_to_string(home.join("profiles/user").join(files::PROFILE_TOML)).unwrap();
        assert!(user_profile.contains("inherits = [\"default\"]"));
    }

    #[test]
    fn duplicate_legacy_default_profile_is_removed_when_default_exists() {
        let dir = tempfile::tempdir().unwrap();
        let home = dir.path().join(".tron");
        fs::create_dir_all(home.join("profiles").join(DEFAULT_PROFILE)).unwrap();
        fs::create_dir_all(home.join("profiles").join(LEGACY_DEFAULT_PROFILE)).unwrap();
        fs::write(
            home.join("profiles")
                .join(DEFAULT_PROFILE)
                .join(files::PROFILE_TOML),
            "version = \"1\"\nname = \"default\"\nmanaged = true\ninherits = []\nauthProfile = \"default\"\n",
        )
        .unwrap();
        fs::write(
            home.join("profiles")
                .join(LEGACY_DEFAULT_PROFILE)
                .join(files::PROFILE_TOML),
            "version = \"1\"\nname = \"master-default\"\nmanaged = true\ninherits = []\nauthProfile = \"default\"\n",
        )
        .unwrap();

        ensure_tron_home_at(&home).unwrap();

        assert!(home.join("profiles").join(DEFAULT_PROFILE).exists());
        assert!(!home.join("profiles").join(LEGACY_DEFAULT_PROFILE).exists());
        assert!(!home.join("workspace/archive/profile-migration").exists());
    }
}
