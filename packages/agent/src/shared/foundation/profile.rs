//! Primitive profile loading.
//!
//! Profiles are now retained only for boot-time configuration: inheritance,
//! auth profile selection, and effective server settings. Model prompts,
//! process plans, policy packs, and context manifests are
//! not profile primitives on the teardown branch.

use std::collections::{BTreeSet, HashMap};
use std::fs;
use std::io;
use std::ops::Deref;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};
use toml::Value;

use super::paths::{self, dirs, files};
use crate::domains::settings::types::TronSettings;

/// Managed profile that defines complete default Tron behavior.
pub const DEFAULT_PROFILE: &str = "default";
/// Standard user-facing profile for normal project/workspace sessions.
pub const NORMAL_PROFILE: &str = "normal";
/// Standard user-facing profile for quick chat sessions.
pub const CHAT_PROFILE: &str = "chat";
/// Standard user-facing profile for local-provider sessions.
pub const LOCAL_PROFILE: &str = "local";
/// Default user overlay profile.
pub const USER_PROFILE: &str = "user";
/// Default credential profile name.
pub const DEFAULT_AUTH_PROFILE: &str = "default";
/// Current profile schema version.
pub const CURRENT_PROFILE_VERSION: &str = "3";

/// Parsed primitive profile document.
#[derive(Clone, Debug, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default, deny_unknown_fields)]
pub struct ProfileDocument {
    /// Schema version.
    pub version: String,
    /// Profile name.
    pub name: String,
    /// Whether this profile is managed/restorable by Tron.
    pub managed: bool,
    /// User-facing profile category (`base`, `normal`, `chat`, `local`, `custom`).
    pub profile_class: Option<String>,
    /// Parent profiles, resolved in order.
    pub inherits: Vec<String>,
    /// Credential profile selected from `profiles/auth.toml`.
    pub auth_profile: String,
    /// Profile-owned effective settings.
    pub settings: TronSettings,
    /// Auth registry/store refs.
    pub auth: AuthSpec,
}

/// Prompt, provider, or context manifest file compiled into the runtime spec.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct CompiledProfileFile {
    /// Profile-relative reference from TOML.
    pub relative_ref: String,
    /// Absolute source path used for audit/reload.
    pub source_path: PathBuf,
    /// SHA-256 content hash.
    pub hash: String,
    /// Loaded UTF-8 content.
    pub content: String,
}

/// Effective agent execution spec after inheritance, settings overlay, and auth
/// registry loading.
#[derive(Clone, Debug)]
pub struct AgentExecutionSpec {
    /// Merged raw profile document.
    document: ProfileDocument,
    /// Readable auth registry used to resolve authProfile.
    pub auth_registry: Option<CompiledProfileFile>,
    /// All source files that affect this compiled spec.
    pub source_files: Vec<PathBuf>,
}

impl Deref for AgentExecutionSpec {
    type Target = ProfileDocument;

    fn deref(&self) -> &Self::Target {
        &self.document
    }
}

/// Auth registry/store refs owned by profiles.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default, deny_unknown_fields)]
pub struct AuthSpec {
    /// Readable auth registry under `profiles/`.
    pub registry: String,
    /// Protected raw auth store under `profiles/`.
    pub raw_store: String,
}

/// Readable auth registry stored at `profiles/auth.toml`.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default, deny_unknown_fields)]
pub struct AuthRegistry {
    /// Schema version.
    pub version: String,
    /// Default credential profile name.
    pub default: String,
    /// Declared credential profiles.
    pub profiles: HashMap<String, AuthProfileSpec>,
}

/// One credential profile entry in [`AuthRegistry`].
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default, deny_unknown_fields)]
pub struct AuthProfileSpec {
    /// Human-readable description.
    pub description: String,
    /// Backing raw auth store, normally `auth.json`.
    pub store: String,
}

/// Resolved effective execution profile.
#[derive(Clone, Debug)]
pub struct ResolvedProfile {
    /// Active profile name.
    pub name: String,
    /// Active profile root directory.
    pub active_dir: PathBuf,
    /// Merged profile document.
    pub spec: AgentExecutionSpec,
    /// Merged raw TOML, useful for audit hashes and future settings migration.
    pub raw: Value,
    /// Profiles applied from oldest ancestor to active profile.
    pub profile_chain: Vec<String>,
    /// SHA-256 hash of the resolved raw profile document.
    pub spec_hash: String,
}

impl AgentExecutionSpec {
    fn from_document_uncompiled(document: ProfileDocument) -> Self {
        Self {
            document,
            auth_registry: None,
            source_files: Vec::new(),
        }
    }

    /// Borrow the merged raw profile document.
    #[must_use]
    pub fn document(&self) -> &ProfileDocument {
        &self.document
    }

    /// Borrow the profile-owned effective settings.
    #[must_use]
    pub fn settings(&self) -> &TronSettings {
        &self.document.settings
    }
}

/// Parse the compiled managed default profile.
#[must_use]
pub fn bundled_default_execution_spec() -> AgentExecutionSpec {
    let document: ProfileDocument = toml::from_str(include_str!(
        "../../../defaults/profiles/default/profile.toml"
    ))
    .expect("bundled default profile.toml must be a valid ProfileDocument");
    AgentExecutionSpec::from_document_uncompiled(document)
}

/// Read the active profile name from `profiles/active.toml`.
#[must_use]
pub fn active_profile_name() -> Option<String> {
    active_profile_name_at(&paths::tron_home())
}

/// Read the active profile name from a specific Tron home.
#[must_use]
pub fn active_profile_name_at(home: &Path) -> Option<String> {
    let content = fs::read_to_string(home.join(dirs::PROFILES).join(files::ACTIVE_TOML)).ok()?;
    parse_active_profile(&content)
}

fn parse_active_profile(content: &str) -> Option<String> {
    let value: Value = toml::from_str(content).ok()?;
    value
        .get("active")
        .and_then(Value::as_str)
        .filter(|value| !value.trim().is_empty())
        .map(str::to_owned)
}

/// Resolve the active profile under a specific Tron home.
pub fn resolve_active_profile_at(home: &Path) -> io::Result<ResolvedProfile> {
    let name = active_profile_name_at(home).ok_or_else(|| {
        io::Error::new(
            io::ErrorKind::NotFound,
            format!(
                "missing active profile pointer: {}",
                home.join(dirs::PROFILES).join(files::ACTIVE_TOML).display()
            ),
        )
    })?;
    resolve_profile_at(home, &name)
}

/// Resolve a relative file reference through one profile's inheritance chain.
pub fn resolve_profile_file_at(home: &Path, name: &str, rel: &str) -> io::Result<PathBuf> {
    for profile in profile_file_candidate_profiles(home, name)? {
        let path = home.join(dirs::PROFILES).join(profile).join(rel);
        if path.is_file() {
            return Ok(path);
        }
    }
    Err(io::Error::new(
        io::ErrorKind::NotFound,
        format!("profile `{name}` does not provide file `{rel}`"),
    ))
}

/// Resolve a named profile with inheritance.
pub fn resolve_profile_at(home: &Path, name: &str) -> io::Result<ResolvedProfile> {
    resolve_profile_at_with_user_overlay(home, name, true)
}

/// Resolve a named profile without the global user settings overlay.
pub fn resolve_profile_base_at(home: &Path, name: &str) -> io::Result<ResolvedProfile> {
    resolve_profile_at_with_user_overlay(home, name, false)
}

fn resolve_profile_at_with_user_overlay(
    home: &Path,
    name: &str,
    include_user_overlay: bool,
) -> io::Result<ResolvedProfile> {
    let mut seen = BTreeSet::new();
    let mut raw = resolve_profile_value(home, name, &mut seen)?;
    if include_user_overlay {
        apply_user_profile_overlay(home, name, &mut raw)?;
    }
    let document: ProfileDocument = raw.clone().try_into().map_err(|error| {
        io::Error::new(
            io::ErrorKind::InvalidData,
            format!("invalid profile `{name}`: {error}"),
        )
    })?;
    validate_profile(home, name, &document)?;
    let candidate_profiles = profile_file_candidate_profiles(home, name)?;
    let spec = compile_agent_execution_spec(home, name, document, &candidate_profiles)?;
    let profile_chain = candidate_profiles.into_iter().rev().collect::<Vec<_>>();
    let raw_string = toml::to_string(&raw).unwrap_or_default();
    let spec_hash = agent_execution_spec_hash(&raw_string, &spec);
    Ok(ResolvedProfile {
        name: name.to_string(),
        active_dir: home.join(dirs::PROFILES).join(name),
        spec,
        raw,
        profile_chain,
        spec_hash,
    })
}

fn resolve_profile_value(
    home: &Path,
    name: &str,
    seen: &mut BTreeSet<String>,
) -> io::Result<Value> {
    if !seen.insert(name.to_string()) {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            format!("profile inheritance cycle at `{name}`"),
        ));
    }

    let path = home
        .join(dirs::PROFILES)
        .join(name)
        .join(files::PROFILE_TOML);
    let content = fs::read_to_string(&path)?;
    let value: Value = toml::from_str(&content).map_err(|error| {
        io::Error::new(
            io::ErrorKind::InvalidData,
            format!("invalid TOML in {}: {error}", path.display()),
        )
    })?;

    let inherits = value
        .get("inherits")
        .and_then(Value::as_array)
        .map(|items| {
            items
                .iter()
                .filter_map(Value::as_str)
                .map(str::to_owned)
                .collect::<Vec<_>>()
        })
        .unwrap_or_default();

    let mut merged = Value::Table(Default::default());
    for parent in inherits {
        let parent_value = resolve_profile_value(home, &parent, seen)?;
        deep_merge_toml(&mut merged, parent_value);
    }
    deep_merge_toml(&mut merged, value);
    seen.remove(name);
    Ok(merged)
}

fn deep_merge_toml(base: &mut Value, overlay: Value) {
    match (base, overlay) {
        (Value::Table(base_table), Value::Table(overlay_table)) => {
            for (key, value) in overlay_table {
                match base_table.get_mut(&key) {
                    Some(existing) => deep_merge_toml(existing, value),
                    None => {
                        base_table.insert(key, value);
                    }
                }
            }
        }
        (base_value, overlay_value) => {
            *base_value = overlay_value;
        }
    }
}

fn apply_user_profile_overlay(home: &Path, active_name: &str, raw: &mut Value) -> io::Result<()> {
    if active_name == USER_PROFILE {
        return Ok(());
    }
    let path = home
        .join(dirs::PROFILES)
        .join(USER_PROFILE)
        .join(files::PROFILE_TOML);
    let Ok(content) = fs::read_to_string(&path) else {
        return Ok(());
    };
    let overlay: Value = toml::from_str(&content).map_err(|error| {
        io::Error::new(
            io::ErrorKind::InvalidData,
            format!("invalid TOML in {}: {error}", path.display()),
        )
    })?;
    let Some(settings_overlay) = overlay.get("settings").cloned() else {
        return Ok(());
    };
    let Some(raw_table) = raw.as_table_mut() else {
        return Ok(());
    };
    match raw_table.get_mut("settings") {
        Some(settings) => deep_merge_toml(settings, settings_overlay),
        None => {
            raw_table.insert("settings".to_string(), settings_overlay);
        }
    }
    Ok(())
}

#[path = "profile/compilation.rs"]
mod compilation;
#[path = "profile/validation.rs"]
mod validation;

use compilation::{agent_execution_spec_hash, compile_agent_execution_spec};
use validation::{profile_file_candidate_profiles, validate_profile};

#[cfg(test)]
#[path = "profile/tests.rs"]
mod tests;
