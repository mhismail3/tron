//! Profile document and context-block manifest validation.

use std::collections::BTreeSet;
use std::fs;
use std::io;
use std::path::{Path, PathBuf};

use toml::Value;

use super::super::paths::{dirs, files};
use super::{AuthRegistry, CURRENT_PROFILE_VERSION, DEFAULT_PROFILE, ProfileDocument};

pub(super) fn validate_profile(home: &Path, name: &str, spec: &ProfileDocument) -> io::Result<()> {
    if spec.version != CURRENT_PROFILE_VERSION {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            format!(
                "profile `{name}` uses schema version `{}`; expected `{CURRENT_PROFILE_VERSION}`",
                spec.version
            ),
        ));
    }
    if spec.auth_profile.trim().is_empty() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            format!("profile `{name}` must select authProfile"),
        ));
    }
    if let Some(profile_class) = spec.profile_class.as_deref() {
        validate_allowed_value(
            name,
            "profileClass",
            profile_class,
            &["base", "normal", "chat", "local", "custom"],
        )?;
    }
    let mut settings = spec.settings.clone();
    settings.validate_strict().map_err(|error| {
        io::Error::new(
            io::ErrorKind::InvalidData,
            format!("profile `{name}` has invalid settings: {error}"),
        )
    })?;
    settings.validate();
    settings.validate_strict().map_err(|error| {
        io::Error::new(
            io::ErrorKind::InvalidData,
            format!("profile `{name}` has invalid settings: {error}"),
        )
    })?;
    let _ = validate_profiles_file_ref(home, name, "auth.registry", &spec.auth.registry)?;
    let _ = validate_profiles_file_ref(home, name, "auth.rawStore", &spec.auth.raw_store)?;
    validate_auth_profile(home, name, &spec.auth.registry, &spec.auth_profile)?;
    Ok(())
}

fn validate_allowed_value(
    profile_name: &str,
    field: &str,
    value: &str,
    allowed: &[&str],
) -> io::Result<()> {
    if allowed.contains(&value) {
        return Ok(());
    }
    Err(io::Error::new(
        io::ErrorKind::InvalidData,
        format!("profile `{profile_name}` has invalid {field} `{value}`"),
    ))
}

pub(super) fn profile_file_candidate_profiles(home: &Path, name: &str) -> io::Result<Vec<String>> {
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

pub(super) fn validate_profiles_file_ref(
    home: &Path,
    name: &str,
    label: &str,
    rel: &str,
) -> io::Result<PathBuf> {
    validate_relative_ref(name, label, rel)?;
    let path = home.join(dirs::PROFILES).join(rel);
    if path.is_file() {
        Ok(path)
    } else {
        Err(io::Error::new(
            io::ErrorKind::InvalidData,
            format!(
                "profile `{name}` references missing {label} file: {}",
                path.display()
            ),
        ))
    }
}

fn validate_relative_ref(name: &str, label: &str, rel: &str) -> io::Result<()> {
    let path = Path::new(rel);
    if rel.trim().is_empty()
        || path.is_absolute()
        || path
            .components()
            .any(|component| matches!(component, std::path::Component::ParentDir))
    {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            format!("profile `{name}` has unsafe {label} file ref `{rel}`"),
        ));
    }
    Ok(())
}

pub(super) fn validate_auth_profile(
    home: &Path,
    profile_name: &str,
    registry_ref: &str,
    auth_profile: &str,
) -> io::Result<()> {
    validate_relative_ref(profile_name, "auth.registry", registry_ref)?;
    let path = home.join(dirs::PROFILES).join(registry_ref);
    let content = fs::read_to_string(&path)?;
    let registry: AuthRegistry = toml::from_str(&content).map_err(|error| {
        io::Error::new(
            io::ErrorKind::InvalidData,
            format!("invalid auth registry {}: {error}", path.display()),
        )
    })?;
    for (profile, entry) in &registry.profiles {
        validate_relative_ref(
            profile_name,
            &format!("auth profile `{profile}` store"),
            &entry.store,
        )?;
    }
    if registry.profiles.contains_key(auth_profile) {
        Ok(())
    } else {
        Err(io::Error::new(
            io::ErrorKind::InvalidData,
            format!(
                "auth profile `{auth_profile}` is not declared in {}",
                path.display()
            ),
        ))
    }
}
