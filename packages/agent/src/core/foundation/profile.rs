//! Profile-first execution spec loading.
//!
//! Profiles are the normal control plane for model-facing behavior and harness
//! settings. The managed `default` profile is restorable; user profiles
//! inherit from it and are never silently overwritten.

use std::collections::{BTreeSet, HashMap};
use std::fs;
use std::io;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};
use toml::Value;

use super::paths::{self, dirs, files};

/// Managed profile that defines complete default Tron behavior.
pub const DEFAULT_PROFILE: &str = "default";
/// Default user overlay profile.
pub const USER_PROFILE: &str = "user";
/// Default credential profile name.
pub const DEFAULT_AUTH_PROFILE: &str = "default";

/// Parsed profile document.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct ProfileSpec {
    /// Schema version.
    pub version: String,
    /// Profile name.
    pub name: String,
    /// Whether this profile is managed/restorable by Tron.
    pub managed: bool,
    /// Parent profiles, resolved in order.
    pub inherits: Vec<String>,
    /// Credential profile selected from `profiles/auth.toml`.
    pub auth_profile: String,
    /// Prompt file references.
    pub prompts: HashMap<String, String>,
    /// Summarizer prompt file references.
    pub summarizers: HashMap<String, String>,
    /// Subagent prompt file references.
    pub subagents: HashMap<String, String>,
    /// Provider-specific prompt/config references.
    pub providers: HashMap<String, HashMap<String, String>>,
    /// Context policy references.
    pub context: HashMap<String, String>,
    /// Tool policy references.
    pub tools: HashMap<String, String>,
    /// Settings file references.
    pub settings: HashMap<String, String>,
}

/// Effective agent execution spec after profile inheritance is resolved.
pub type AgentExecutionSpec = ProfileSpec;

/// Readable auth registry stored at `profiles/auth.toml`.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
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
#[serde(rename_all = "camelCase", default)]
pub struct AuthProfileSpec {
    /// Human-readable description.
    pub description: String,
    /// Backing raw auth store, normally `auth.json`.
    pub store: String,
}

/// Resolved effective execution profile.
#[derive(Clone, Debug, PartialEq)]
pub struct ResolvedProfile {
    /// Active profile name.
    pub name: String,
    /// Active profile root directory.
    pub active_dir: PathBuf,
    /// Merged profile document.
    pub spec: AgentExecutionSpec,
    /// Merged raw TOML, useful for audit hashes and future settings migration.
    pub raw: Value,
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

/// Resolve the active profile or the managed default if no active
/// pointer exists yet.
pub fn resolve_active_profile() -> io::Result<ResolvedProfile> {
    resolve_active_profile_at(&paths::tron_home())
}

/// Resolve the active profile under a specific Tron home.
pub fn resolve_active_profile_at(home: &Path) -> io::Result<ResolvedProfile> {
    let name = active_profile_name_at(home).unwrap_or_else(|| DEFAULT_PROFILE.to_string());
    resolve_profile_at(home, &name)
}

/// Resolve a relative file reference through the active profile inheritance chain.
pub fn resolve_active_file_at(home: &Path, rel: &str) -> io::Result<PathBuf> {
    let name = active_profile_name_at(home).unwrap_or_else(|| DEFAULT_PROFILE.to_string());
    resolve_profile_file_at(home, &name, rel)
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
    let mut seen = BTreeSet::new();
    let raw = resolve_profile_value(home, name, &mut seen)?;
    let spec: AgentExecutionSpec = raw.clone().try_into().map_err(|error| {
        io::Error::new(
            io::ErrorKind::InvalidData,
            format!("invalid profile `{name}`: {error}"),
        )
    })?;
    validate_profile(home, name, &spec)?;
    Ok(ResolvedProfile {
        name: name.to_string(),
        active_dir: home.join(dirs::PROFILES).join(name),
        spec,
        raw,
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

fn validate_profile(home: &Path, name: &str, spec: &ProfileSpec) -> io::Result<()> {
    if spec.auth_profile.trim().is_empty() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            format!("profile `{name}` must select authProfile"),
        ));
    }
    validate_auth_profile(home, &spec.auth_profile)?;

    let candidate_profiles = profile_file_candidate_profiles(home, name)?;
    for (label, rel) in spec
        .prompts
        .iter()
        .chain(spec.summarizers.iter())
        .chain(spec.subagents.iter())
        .chain(spec.context.iter())
        .chain(spec.tools.iter())
        .chain(spec.settings.iter())
    {
        validate_profile_file_ref(home, name, &candidate_profiles, label, rel)?;
    }

    for (provider, refs) in &spec.providers {
        for (label, rel) in refs {
            validate_profile_file_ref(
                home,
                name,
                &candidate_profiles,
                &format!("providers.{provider}.{label}"),
                rel,
            )?;
        }
    }
    Ok(())
}

fn profile_file_candidate_profiles(home: &Path, name: &str) -> io::Result<Vec<String>> {
    let mut candidates = Vec::new();
    let mut seen = BTreeSet::new();
    collect_profile_file_candidates(home, name, &mut seen, &mut candidates)?;
    if !seen.contains(DEFAULT_PROFILE) {
        candidates.push(DEFAULT_PROFILE.to_string());
    }
    Ok(candidates)
}

fn collect_profile_file_candidates(
    home: &Path,
    name: &str,
    seen: &mut BTreeSet<String>,
    candidates: &mut Vec<String>,
) -> io::Result<()> {
    if !seen.insert(name.to_string()) {
        return Ok(());
    }
    candidates.push(name.to_string());
    let path = home
        .join(dirs::PROFILES)
        .join(name)
        .join(files::PROFILE_TOML);
    let Ok(content) = fs::read_to_string(&path) else {
        return Ok(());
    };
    let value: Value = toml::from_str(&content).map_err(|error| {
        io::Error::new(
            io::ErrorKind::InvalidData,
            format!("invalid TOML in {}: {error}", path.display()),
        )
    })?;
    let inherits = value
        .get("inherits")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(Value::as_str)
        .map(str::to_owned)
        .collect::<Vec<_>>();
    for parent in inherits {
        collect_profile_file_candidates(home, &parent, seen, candidates)?;
    }
    Ok(())
}

fn validate_profile_file_ref(
    home: &Path,
    name: &str,
    candidate_profiles: &[String],
    label: &str,
    rel: &str,
) -> io::Result<()> {
    if candidate_profiles
        .iter()
        .any(|profile| home.join(dirs::PROFILES).join(profile).join(rel).is_file())
    {
        return Ok(());
    }
    let profile_path = home.join(dirs::PROFILES).join(name).join(rel);
    Err(io::Error::new(
        io::ErrorKind::InvalidData,
        format!(
            "profile `{name}` references missing {label} file: {}",
            profile_path.display()
        ),
    ))
}

fn validate_auth_profile(home: &Path, auth_profile: &str) -> io::Result<()> {
    let path = home.join(dirs::PROFILES).join(files::AUTH_TOML);
    let content = fs::read_to_string(&path)?;
    let registry: AuthRegistry = toml::from_str(&content).map_err(|error| {
        io::Error::new(
            io::ErrorKind::InvalidData,
            format!("invalid auth registry {}: {error}", path.display()),
        )
    })?;
    if registry.profiles.contains_key(auth_profile) {
        Ok(())
    } else {
        Err(io::Error::new(
            io::ErrorKind::InvalidData,
            format!("auth profile `{auth_profile}` is not declared in profiles/auth.toml"),
        ))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn write(path: &Path, content: &str) {
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent).unwrap();
        }
        fs::write(path, content).unwrap();
    }

    fn seed_auth(home: &Path) {
        write(
            &home.join(dirs::PROFILES).join(files::AUTH_TOML),
            r#"
version = "1"
default = "default"

[profiles.default]
store = "auth.json"
"#,
        );
    }

    #[test]
    fn active_profile_reads_toml() {
        assert_eq!(
            parse_active_profile("active = \"user\"\n").as_deref(),
            Some("user")
        );
    }

    #[test]
    fn profile_inheritance_deep_merges_tables_and_replaces_arrays() {
        let dir = tempfile::tempdir().unwrap();
        let home = dir.path().join(".tron");
        seed_auth(&home);
        write(
            &home
                .join(dirs::PROFILES)
                .join("base")
                .join(files::PROFILE_TOML),
            r#"
version = "1"
name = "base"
authProfile = "default"
inherits = []
list = ["base"]

[prompts]
core = "prompts/core.md"
chat = "prompts/chat.md"
"#,
        );
        write(
            &home
                .join(dirs::PROFILES)
                .join("child")
                .join(files::PROFILE_TOML),
            r#"
version = "1"
name = "child"
authProfile = "default"
inherits = ["base"]
list = ["child"]

[prompts]
chat = "prompts/custom-chat.md"
"#,
        );
        write(
            &home
                .join(dirs::PROFILES)
                .join("base")
                .join("prompts/core.md"),
            "core",
        );
        write(
            &home
                .join(dirs::PROFILES)
                .join("child")
                .join("prompts/custom-chat.md"),
            "chat",
        );

        let resolved = resolve_profile_at(&home, "child").unwrap();

        assert_eq!(resolved.spec.prompts["core"], "prompts/core.md");
        assert_eq!(resolved.spec.prompts["chat"], "prompts/custom-chat.md");
        assert_eq!(resolved.raw["list"].as_array().unwrap().len(), 1);
        assert_eq!(resolved.raw["list"][0].as_str(), Some("child"));
    }

    #[test]
    fn profile_cycle_is_rejected() {
        let dir = tempfile::tempdir().unwrap();
        let home = dir.path().join(".tron");
        seed_auth(&home);
        write(
            &home
                .join(dirs::PROFILES)
                .join("a")
                .join(files::PROFILE_TOML),
            r#"version = "1"
name = "a"
authProfile = "default"
inherits = ["b"]
"#,
        );
        write(
            &home
                .join(dirs::PROFILES)
                .join("b")
                .join(files::PROFILE_TOML),
            r#"version = "1"
name = "b"
authProfile = "default"
inherits = ["a"]
"#,
        );

        let error = resolve_profile_at(&home, "a").unwrap_err();
        assert!(error.to_string().contains("cycle"));
    }
}
