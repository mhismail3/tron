//! One-time retirement of the superseded named-profile configuration plane.
//!
//! Planning is read-only and produces a stable source fingerprint. Bootstrap
//! uses that fingerprint to create and verify the full worker-first state
//! snapshot before [`LegacyProfileRetirement::apply`] publishes flat settings
//! and removes the old profile documents. Provider `auth.json` is preserved.

use std::fs;
use std::io::Write as _;
use std::path::{Path, PathBuf};

use serde::Serialize;
use serde_json::Value;
#[cfg(test)]
use serde_json::json;
use sha2::{Digest, Sha256};
use walkdir::WalkDir;

use crate::domains::settings::SettingsStore;
use crate::shared::foundation::paths::{dirs, files};

const MIGRATION_FORMAT: &str = "tron.flat_engine_settings_retirement.v1";

/// Read-only plan for retiring legacy profile state.
pub(crate) struct LegacyProfileRetirement {
    home: PathBuf,
    source_label: String,
    fingerprint: String,
    retired_entries: Vec<PathBuf>,
}

impl LegacyProfileRetirement {
    /// Plan retirement when any non-auth legacy profile state remains.
    pub(crate) fn plan(home: &Path) -> Result<Option<Self>, String> {
        let profiles = home.join(dirs::PROFILES);
        if !profiles.is_dir() {
            return Ok(None);
        }
        let mut retired_entries = fs::read_dir(&profiles)
            .map_err(|error| format!("scan legacy profiles at {}: {error}", profiles.display()))?
            .filter_map(Result::ok)
            .map(|entry| entry.path())
            .filter(|path| {
                path.file_name().and_then(|name| name.to_str()) != Some(files::AUTH_JSON)
            })
            .collect::<Vec<_>>();
        retired_entries.sort();
        if retired_entries.is_empty() {
            return Ok(None);
        }

        let source_label =
            read_legacy_active_name(&profiles).unwrap_or_else(|| "legacy-profile".into());
        let fingerprint = legacy_inventory_hash(&profiles, &retired_entries)?;
        Ok(Some(Self {
            home: home.to_path_buf(),
            source_label,
            fingerprint,
            retired_entries,
        }))
    }

    /// Label recorded in the recovery snapshot manifest.
    pub(crate) fn source_label(&self) -> &str {
        &self.source_label
    }

    /// Stable digest of all legacy entries that will be retired.
    pub(crate) fn fingerprint(&self) -> &str {
        &self.fingerprint
    }

    /// Publish the flat settings import and retire snapshotted profile files.
    pub(crate) fn apply(self) -> Result<(), String> {
        let settings_path = crate::shared::foundation::paths::settings_path_for_home(&self.home);
        let mut imported = false;
        let mut ignored_settings = Vec::new();
        let mut unconvertible = Vec::new();

        if !settings_path.exists() {
            let legacy_user = self
                .home
                .join(dirs::PROFILES)
                .join("user")
                .join("profile.toml");
            if legacy_user.is_file() {
                match import_legacy_user_settings(&legacy_user, &mut ignored_settings) {
                    Ok(Some(settings)) => {
                        match SettingsStore::new(&settings_path).replace_sparse_value(settings) {
                            Ok(()) => imported = true,
                            Err(error) => unconvertible.push(format!(
                                "profiles/user/profile.toml settings failed validation: {error}"
                            )),
                        }
                    }
                    Ok(None) => {}
                    Err(error) => unconvertible.push(error),
                }
            }
        }

        let retired_relative = self
            .retired_entries
            .iter()
            .map(|path| relative_display(&self.home, path))
            .collect::<Vec<_>>();
        write_report(
            &self.home,
            &RetirementReport {
                format: MIGRATION_FORMAT,
                retired_at: chrono::Utc::now().to_rfc3339(),
                source_label: self.source_label,
                source_inventory_sha256: self.fingerprint,
                settings_imported: imported,
                canonical_settings_preserved: settings_path.exists() && !imported,
                ignored_settings,
                unconvertible,
                retired_entries: retired_relative,
            },
        )?;

        for entry in &self.retired_entries {
            remove_exact_entry(entry)?;
        }
        Ok(())
    }
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct RetirementReport {
    format: &'static str,
    retired_at: String,
    source_label: String,
    source_inventory_sha256: String,
    settings_imported: bool,
    canonical_settings_preserved: bool,
    ignored_settings: Vec<String>,
    unconvertible: Vec<String>,
    retired_entries: Vec<String>,
}

fn read_legacy_active_name(profiles: &Path) -> Option<String> {
    let source = fs::read_to_string(profiles.join("active.toml")).ok()?;
    let value: toml::Value = toml::from_str(&source).ok()?;
    value.get("active")?.as_str().map(str::to_owned)
}

fn legacy_inventory_hash(profiles: &Path, entries: &[PathBuf]) -> Result<String, String> {
    let mut inventory = Vec::new();
    for root in entries {
        if fs::symlink_metadata(root)
            .map_err(|error| format!("inspect legacy profile {}: {error}", root.display()))?
            .file_type()
            .is_symlink()
        {
            inventory.push(root.clone());
            continue;
        }
        if root.is_dir() {
            for entry in WalkDir::new(root).follow_links(false) {
                let entry = entry.map_err(|error| error.to_string())?;
                if entry.file_type().is_file() || entry.file_type().is_symlink() {
                    inventory.push(entry.path().to_path_buf());
                }
            }
        } else {
            inventory.push(root.clone());
        }
    }
    inventory.sort();

    let mut digest = Sha256::new();
    digest.update(MIGRATION_FORMAT.as_bytes());
    digest.update(b"\0");
    for path in inventory {
        digest.update(relative_display(profiles, &path).as_bytes());
        digest.update(b"\0");
        let metadata = fs::symlink_metadata(&path)
            .map_err(|error| format!("inspect legacy profile {}: {error}", path.display()))?;
        if metadata.file_type().is_symlink() {
            digest.update(b"symlink\0");
            digest.update(
                fs::read_link(&path)
                    .map_err(|error| format!("read legacy symlink {}: {error}", path.display()))?
                    .as_os_str()
                    .as_encoded_bytes(),
            );
        } else {
            digest.update(b"file\0");
            digest.update(
                fs::read(&path)
                    .map_err(|error| format!("read legacy profile {}: {error}", path.display()))?,
            );
        }
        digest.update(b"\0");
    }
    Ok(hex::encode(digest.finalize()))
}

fn import_legacy_user_settings(
    path: &Path,
    ignored: &mut Vec<String>,
) -> Result<Option<Value>, String> {
    let source = fs::read_to_string(path)
        .map_err(|error| format!("read profiles/user/profile.toml: {error}"))?;
    let value: toml::Value = toml::from_str(&source)
        .map_err(|error| format!("profiles/user/profile.toml is invalid TOML: {error}"))?;
    let Some(settings) = value.get("settings").cloned() else {
        return Ok(None);
    };
    let settings = serde_json::to_value(settings)
        .map_err(|error| format!("convert legacy user settings: {error}"))?;
    let schema = serde_json::to_value(crate::domains::settings::TronSettings::default())
        .map_err(|error| format!("encode settings schema: {error}"))?;
    let projected = project_known_settings(&settings, &schema, "settings", ignored);
    if projected
        .as_object()
        .is_some_and(|settings| settings.is_empty())
    {
        Ok(None)
    } else {
        Ok(Some(projected))
    }
}

fn project_known_settings(
    candidate: &Value,
    schema: &Value,
    path: &str,
    ignored: &mut Vec<String>,
) -> Value {
    let (Some(candidate), Some(schema)) = (candidate.as_object(), schema.as_object()) else {
        return candidate.clone();
    };
    let mut projected = serde_json::Map::new();
    for (key, value) in candidate {
        let child_path = format!("{path}.{key}");
        if let Some(child_schema) = schema.get(key) {
            projected.insert(
                key.clone(),
                project_known_settings(value, child_schema, &child_path, ignored),
            );
        } else {
            ignored.push(child_path);
        }
    }
    Value::Object(projected)
}

fn write_report(home: &Path, report: &RetirementReport) -> Result<(), String> {
    let directory = home.join(dirs::INTERNAL).join("migrations");
    fs::create_dir_all(&directory)
        .map_err(|error| format!("create settings migration directory: {error}"))?;
    let path = directory.join("flat-settings-retirement-v1.json");
    let mut staged = tempfile::Builder::new()
        .prefix(".flat-settings-retirement.")
        .tempfile_in(&directory)
        .map_err(|error| format!("stage settings migration report: {error}"))?;
    let bytes = serde_json::to_vec_pretty(report)
        .map_err(|error| format!("encode settings migration report: {error}"))?;
    staged
        .write_all(&bytes)
        .and_then(|()| staged.as_file().sync_all())
        .map_err(|error| format!("seal settings migration report: {error}"))?;
    staged
        .persist(&path)
        .map_err(|error| format!("publish settings migration report: {}", error.error))?;
    Ok(())
}

fn remove_exact_entry(path: &Path) -> Result<(), String> {
    let metadata = fs::symlink_metadata(path)
        .map_err(|error| format!("inspect retired profile entry {}: {error}", path.display()))?;
    if metadata.is_dir() && !metadata.file_type().is_symlink() {
        fs::remove_dir_all(path)
    } else {
        fs::remove_file(path)
    }
    .map_err(|error| format!("retire profile entry {}: {error}", path.display()))
}

fn relative_display(root: &Path, path: &Path) -> String {
    path.strip_prefix(root)
        .unwrap_or(path)
        .to_string_lossy()
        .replace('\\', "/")
}

#[cfg(test)]
mod tests {
    use super::*;

    fn legacy_home() -> tempfile::TempDir {
        let root = tempfile::tempdir().unwrap();
        let profiles = root.path().join(dirs::PROFILES);
        fs::create_dir_all(profiles.join("user")).unwrap();
        fs::create_dir_all(profiles.join("default")).unwrap();
        fs::write(profiles.join(files::AUTH_JSON), "{}").unwrap();
        fs::write(profiles.join("active.toml"), "active = \"normal\"\n").unwrap();
        fs::write(profiles.join("default/profile.toml"), "version = \"3\"\n").unwrap();
        fs::write(
            profiles.join("user/profile.toml"),
            "[settings]\nautonomousWorkers = true\n[settings.server.transcription]\nmodel = \"retired\"\n",
        )
        .unwrap();
        root
    }

    #[test]
    fn imports_known_settings_reports_retired_keys_and_preserves_auth() {
        let root = legacy_home();
        let plan = LegacyProfileRetirement::plan(root.path()).unwrap().unwrap();
        assert_eq!(plan.source_label(), "normal");
        assert!(!plan.fingerprint().is_empty());
        plan.apply().unwrap();

        let settings = crate::domains::settings::load_settings_from_path(
            &crate::shared::foundation::paths::settings_path_for_home(root.path()),
        )
        .unwrap();
        assert!(settings.autonomous_workers);
        assert!(root.path().join("profiles/auth.json").is_file());
        assert!(!root.path().join("profiles/user").exists());
        assert!(!root.path().join("profiles/default").exists());
        let report: Value = serde_json::from_slice(
            &fs::read(
                root.path()
                    .join("internal/migrations/flat-settings-retirement-v1.json"),
            )
            .unwrap(),
        )
        .unwrap();
        assert_eq!(report["settingsImported"], true);
        assert_eq!(
            report["ignoredSettings"],
            json!(["settings.server.transcription"])
        );
    }

    #[test]
    fn canonical_flat_settings_win_over_legacy_overlay() {
        let root = legacy_home();
        fs::write(
            crate::shared::foundation::paths::settings_path_for_home(root.path()),
            "autonomousWorkers = false\n",
        )
        .unwrap();
        LegacyProfileRetirement::plan(root.path())
            .unwrap()
            .unwrap()
            .apply()
            .unwrap();
        let settings = crate::domains::settings::load_settings_from_path(
            &crate::shared::foundation::paths::settings_path_for_home(root.path()),
        )
        .unwrap();
        assert!(!settings.autonomous_workers);
    }
}
