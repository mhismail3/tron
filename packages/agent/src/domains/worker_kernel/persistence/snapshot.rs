use std::fs;
use std::io;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use walkdir::WalkDir;

use crate::shared::foundation::paths::{dirs, files as path_files};

const SNAPSHOT_FORMAT_V1: &str = "tron.worker_state_snapshot.v1";
const SNAPSHOT_FORMAT: &str = "tron.worker_state_snapshot.v2";

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct SnapshotManifest {
    format: String,
    schema_version: u32,
    source_home: String,
    #[serde(alias = "sourceProfile")]
    source_label: String,
    #[serde(default)]
    source_inventory_sha256: String,
    created_at: String,
    files: Vec<SnapshotFile>,
    restore: Vec<String>,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct SnapshotFile {
    relative_path: String,
    sha256: String,
    bytes: u64,
    #[serde(default = "default_snapshot_file_kind")]
    kind: String,
}

fn default_snapshot_file_kind() -> String {
    "file".to_owned()
}

pub(super) fn ensure_pre_worker_snapshot(
    home: &Path,
    source_label: &str,
    source_inventory_sha256: &str,
) -> io::Result<Option<PathBuf>> {
    let snapshots = home.join(dirs::INTERNAL).join(dirs::SNAPSHOTS);
    fs::create_dir_all(&snapshots)?;
    let marker = snapshots.join("worker-first-v2.complete.json");
    if let Ok(bytes) = fs::read(&marker)
        && let Ok(value) = serde_json::from_slice::<serde_json::Value>(&bytes)
        && value["sourceInventorySha256"] == source_inventory_sha256
        && let Some(snapshot) = value["snapshot"].as_str()
    {
        verify_snapshot(Path::new(snapshot))?;
        return Ok(None);
    }

    let created_at = chrono::Utc::now();
    let name = format!(
        "worker-first-v2-{}-{}",
        created_at.format("%Y%m%dT%H%M%SZ"),
        uuid::Uuid::now_v7()
    );
    let staging = snapshots.join(format!(".{name}.staging"));
    let destination = snapshots.join(&name);
    fs::create_dir_all(&staging)?;

    let mut files = Vec::new();
    snapshot_tree(home, &home.join(dirs::PROFILES), &staging, &mut files)?;
    snapshot_tree(
        home,
        &home.join(path_files::SETTINGS_TOML),
        &staging,
        &mut files,
    )?;
    snapshot_tree(
        home,
        &home.join(dirs::WORKSPACE).join(dirs::WORKERS),
        &staging,
        &mut files,
    )?;
    snapshot_database(home, &staging, &mut files)?;

    let manifest = SnapshotManifest {
        format: SNAPSHOT_FORMAT.to_owned(),
        schema_version: 2,
        source_home: home.display().to_string(),
        source_label: source_label.to_owned(),
        source_inventory_sha256: source_inventory_sha256.to_owned(),
        created_at: created_at.to_rfc3339(),
        files,
        restore: vec![
            "Stop Tron before restoring state.".to_owned(),
            "Copy snapshot settings.toml, profiles/, workspace/workers/, and internal/database/tron.sqlite back under the recorded sourceHome.".to_owned(),
            "Remove internal/database/workers.sqlite so indexes rebuild from worker bundles.".to_owned(),
        ],
    };
    fs::write(
        staging.join("manifest.json"),
        serde_json::to_vec_pretty(&manifest).map_err(io::Error::other)?,
    )?;
    fs::rename(&staging, &destination)?;
    verify_snapshot(&destination)?;
    fs::write(
        &marker,
        serde_json::to_vec_pretty(&serde_json::json!({
            "format": SNAPSHOT_FORMAT,
            "snapshot": destination.display().to_string(),
            "createdAt": created_at.to_rfc3339(),
            "sourceInventorySha256": source_inventory_sha256,
        }))
        .map_err(io::Error::other)?,
    )?;
    Ok(Some(destination))
}

pub(super) fn list_snapshots(home: &Path) -> io::Result<Vec<PathBuf>> {
    let root = home.join(dirs::INTERNAL).join(dirs::SNAPSHOTS);
    if !root.is_dir() {
        return Ok(Vec::new());
    }
    let mut snapshots = fs::read_dir(root)?
        .filter_map(Result::ok)
        .map(|entry| entry.path())
        .filter(|path| path.is_dir() && path.join("manifest.json").is_file())
        .collect::<Vec<_>>();
    snapshots.sort();
    Ok(snapshots)
}

pub(super) fn verify_snapshot(snapshot: &Path) -> io::Result<()> {
    let manifest: SnapshotManifest =
        serde_json::from_slice(&fs::read(snapshot.join("manifest.json"))?)
            .map_err(io::Error::other)?;
    if !matches!(
        (manifest.format.as_str(), manifest.schema_version),
        (SNAPSHOT_FORMAT_V1, 1) | (SNAPSHOT_FORMAT, 2)
    ) {
        return Err(io::Error::other("unsupported worker state snapshot format"));
    }
    for file in &manifest.files {
        if !matches!(file.kind.as_str(), "file" | "symlink") {
            return Err(io::Error::other(format!(
                "snapshot entry has unsupported kind '{}' for {}",
                file.kind, file.relative_path
            )));
        }
        let relative = safe_snapshot_relative(&file.relative_path)?;
        let path = snapshot.join(relative);
        let bytes = fs::read(&path)?;
        if bytes.len() as u64 != file.bytes || hex::encode(Sha256::digest(&bytes)) != file.sha256 {
            return Err(io::Error::other(format!(
                "snapshot checksum mismatch for {}",
                file.relative_path
            )));
        }
        if file.kind == "symlink" {
            let target = String::from_utf8(bytes).map_err(|error| {
                io::Error::other(format!(
                    "snapshot symlink target is invalid for {}: {error}",
                    file.relative_path
                ))
            })?;
            if target.is_empty() || target.contains('\0') {
                return Err(io::Error::other(format!(
                    "snapshot symlink target is invalid for {}",
                    file.relative_path
                )));
            }
        }
    }
    Ok(())
}

/// Restore a verified snapshot while first moving the current worker state and
/// worker index into a timestamped recovery directory beside the snapshot.
/// This is intended for the offline CLI; callers must stop Tron first.
pub(super) fn restore_snapshot(snapshot: &Path, home: &Path) -> io::Result<PathBuf> {
    verify_snapshot(snapshot)?;
    let manifest: SnapshotManifest =
        serde_json::from_slice(&fs::read(snapshot.join("manifest.json"))?)
            .map_err(io::Error::other)?;
    let expected_home = PathBuf::from(&manifest.source_home);
    if expected_home != home {
        return Err(io::Error::other(format!(
            "snapshot belongs to {}, not {}",
            expected_home.display(),
            home.display()
        )));
    }
    let recovery = home
        .join(dirs::INTERNAL)
        .join(dirs::SNAPSHOTS)
        .join(format!(
            "pre-restore-{}",
            chrono::Utc::now().format("%Y%m%dT%H%M%SZ")
        ));
    fs::create_dir_all(&recovery)?;
    for relative in [
        PathBuf::from(path_files::SETTINGS_TOML),
        PathBuf::from(dirs::PROFILES),
        PathBuf::from(dirs::WORKSPACE).join(dirs::WORKERS),
        PathBuf::from(dirs::INTERNAL)
            .join(dirs::DB)
            .join("tron.sqlite"),
        PathBuf::from(dirs::INTERNAL)
            .join(dirs::DB)
            .join("tron.sqlite-wal"),
        PathBuf::from(dirs::INTERNAL)
            .join(dirs::DB)
            .join("tron.sqlite-shm"),
        PathBuf::from(dirs::INTERNAL)
            .join(dirs::DB)
            .join("workers.sqlite"),
        PathBuf::from(dirs::INTERNAL)
            .join(dirs::DB)
            .join("workers.sqlite-wal"),
        PathBuf::from(dirs::INTERNAL)
            .join(dirs::DB)
            .join("workers.sqlite-shm"),
    ] {
        let source = home.join(&relative);
        if source.exists() {
            let target = recovery.join(&relative);
            if let Some(parent) = target.parent() {
                fs::create_dir_all(parent)?;
            }
            fs::rename(source, target)?;
        }
    }
    for file in manifest.files {
        let relative = safe_snapshot_relative(&file.relative_path)?;
        let source = snapshot.join(&relative);
        let target = home.join(&relative);
        if let Some(parent) = target.parent() {
            fs::create_dir_all(parent)?;
        }
        let temporary = target.with_extension(format!("restore-{}", uuid::Uuid::now_v7()));
        if file.kind == "symlink" {
            let link_target = String::from_utf8(fs::read(source)?).map_err(io::Error::other)?;
            create_symlink(Path::new(&link_target), &temporary)?;
        } else {
            fs::copy(source, &temporary)?;
        }
        fs::rename(temporary, target)?;
    }
    let worker_index = home
        .join(dirs::INTERNAL)
        .join(dirs::DB)
        .join("workers.sqlite");
    if worker_index.exists() {
        fs::remove_file(worker_index)?;
    }
    Ok(recovery)
}

fn safe_snapshot_relative(value: &str) -> io::Result<PathBuf> {
    let path = PathBuf::from(value);
    if path.is_absolute()
        || path.components().any(|component| {
            matches!(
                component,
                std::path::Component::ParentDir
                    | std::path::Component::RootDir
                    | std::path::Component::Prefix(_)
            )
        })
    {
        return Err(io::Error::other(format!(
            "snapshot path escapes its root: {value}"
        )));
    }
    Ok(path)
}

fn snapshot_database(
    home: &Path,
    destination: &Path,
    files: &mut Vec<SnapshotFile>,
) -> io::Result<()> {
    let source = home.join(dirs::INTERNAL).join(dirs::DB).join("tron.sqlite");
    if !source.exists() {
        return Ok(());
    }
    let target = destination
        .join(dirs::INTERNAL)
        .join(dirs::DB)
        .join("tron.sqlite");
    let Some(parent) = target.parent() else {
        return Err(io::Error::other("snapshot database target has no parent"));
    };
    fs::create_dir_all(parent)?;
    let connection = rusqlite::Connection::open(&source).map_err(io::Error::other)?;
    let escaped = target.display().to_string().replace('\'', "''");
    connection
        .execute_batch(&format!("VACUUM INTO '{escaped}'"))
        .map_err(io::Error::other)?;
    record_file(home, destination, &target, "file", files)
}

fn snapshot_tree(
    source_root: &Path,
    source: &Path,
    destination: &Path,
    files: &mut Vec<SnapshotFile>,
) -> io::Result<()> {
    if !source.exists() {
        return Ok(());
    }
    for entry in WalkDir::new(source).follow_links(false) {
        let entry = entry.map_err(io::Error::other)?;
        let relative = entry
            .path()
            .strip_prefix(source_root)
            .map_err(io::Error::other)?;
        let target = destination.join(relative);
        if entry.file_type().is_file() {
            if let Some(parent) = target.parent() {
                fs::create_dir_all(parent)?;
            }
            fs::copy(entry.path(), &target)?;
            record_file(source_root, destination, &target, "file", files)?;
        } else if entry.file_type().is_symlink() {
            if let Some(parent) = target.parent() {
                fs::create_dir_all(parent)?;
            }
            let link_target = fs::read_link(entry.path())?;
            let link_target = link_target.to_str().ok_or_else(|| {
                io::Error::other(format!(
                    "snapshot symlink target is not UTF-8: {}",
                    entry.path().display()
                ))
            })?;
            fs::write(&target, link_target.as_bytes())?;
            record_file(source_root, destination, &target, "symlink", files)?;
        }
    }
    Ok(())
}

fn record_file(
    source_root: &Path,
    snapshot_root: &Path,
    target: &Path,
    kind: &str,
    files: &mut Vec<SnapshotFile>,
) -> io::Result<()> {
    let bytes = fs::read(target)?;
    let relative = target
        .strip_prefix(snapshot_root)
        .map_err(io::Error::other)?;
    let _ = source_root;
    files.push(SnapshotFile {
        relative_path: relative.display().to_string(),
        sha256: hex::encode(Sha256::digest(&bytes)),
        bytes: bytes.len() as u64,
        kind: kind.to_owned(),
    });
    Ok(())
}

#[cfg(unix)]
fn create_symlink(target: &Path, link: &Path) -> io::Result<()> {
    std::os::unix::fs::symlink(target, link)
}

#[cfg(not(unix))]
fn create_symlink(_target: &Path, link: &Path) -> io::Result<()> {
    Err(io::Error::other(format!(
        "snapshot symlink restoration is unsupported on this platform: {}",
        link.display()
    )))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn snapshot_verifies_and_restores_worker_state() {
        let source = tempfile::tempdir().unwrap();
        let home = source.path();
        fs::create_dir_all(home.join("profiles/user")).unwrap();
        fs::create_dir_all(home.join("workspace/workers/old")).unwrap();
        fs::write(home.join("profiles/user/profile.toml"), "[settings]\n").unwrap();
        fs::write(home.join("workspace/workers/old/state"), "before").unwrap();
        #[cfg(unix)]
        std::os::unix::fs::symlink("state", home.join("workspace/workers/old/current-state"))
            .unwrap();
        let snapshot = ensure_pre_worker_snapshot(home, "test-profile", "database-sha")
            .unwrap()
            .unwrap();
        verify_snapshot(&snapshot).unwrap();
        let manifest: SnapshotManifest =
            serde_json::from_slice(&fs::read(snapshot.join("manifest.json")).unwrap()).unwrap();
        assert_eq!(manifest.format, SNAPSHOT_FORMAT);
        assert_eq!(manifest.schema_version, 2);
        assert_eq!(manifest.source_inventory_sha256, "database-sha");
        assert_eq!(manifest.source_label, "test-profile");
        assert_eq!(manifest.source_home, home.display().to_string());
        assert!(!manifest.files.is_empty());
        assert!(
            manifest
                .restore
                .iter()
                .any(|step| step.contains("workers.sqlite"))
        );
        #[cfg(unix)]
        assert!(manifest.files.iter().any(|file| {
            file.relative_path.ends_with("current-state") && file.kind == "symlink"
        }));

        fs::write(home.join("workspace/workers/old/state"), "after").unwrap();
        let recovery = restore_snapshot(&snapshot, home).unwrap();
        assert_eq!(
            fs::read_to_string(home.join("workspace/workers/old/state")).unwrap(),
            "before"
        );
        #[cfg(unix)]
        {
            let link = home.join("workspace/workers/old/current-state");
            assert!(
                fs::symlink_metadata(&link)
                    .unwrap()
                    .file_type()
                    .is_symlink()
            );
            assert_eq!(fs::read_link(link).unwrap(), PathBuf::from("state"));
        }
        assert_eq!(
            fs::read_to_string(recovery.join("workspace/workers/old/state")).unwrap(),
            "after"
        );
    }

    #[test]
    fn snapshot_checksum_corruption_fails_before_restore() {
        let source = tempfile::tempdir().unwrap();
        let home = source.path();
        fs::create_dir_all(home.join("profiles/user")).unwrap();
        fs::write(home.join("profiles/user/profile.toml"), "[settings]\n").unwrap();
        let snapshot = ensure_pre_worker_snapshot(home, "checksum-profile", "database-sha")
            .unwrap()
            .unwrap();
        fs::write(snapshot.join("profiles/user/profile.toml"), "corrupt").unwrap();

        assert!(
            verify_snapshot(&snapshot)
                .unwrap_err()
                .to_string()
                .contains("checksum")
        );
        assert!(restore_snapshot(&snapshot, home).is_err());
    }

    #[test]
    fn legacy_settings_migration_restores_the_exact_pre_migration_state() {
        let source = tempfile::tempdir().unwrap();
        let home = source.path();
        fs::create_dir_all(home.join("profiles/user")).unwrap();
        fs::create_dir_all(home.join("workspace/workers/legacy")).unwrap();
        fs::write(home.join("profiles/auth.json"), "{\"token\":\"kept\"}").unwrap();
        fs::write(home.join("profiles/active.toml"), "active = \"normal\"\n").unwrap();
        fs::write(
            home.join("profiles/user/profile.toml"),
            "[settings]\nautonomousWorkers = true\n[settings.server.transcription]\nmodel = \"retired\"\n",
        )
        .unwrap();
        fs::write(home.join("workspace/workers/legacy/state"), "before").unwrap();

        let retirement = crate::domains::settings::LegacyProfileRetirement::plan(home)
            .unwrap()
            .unwrap();
        let snapshot =
            ensure_pre_worker_snapshot(home, retirement.source_label(), retirement.fingerprint())
                .unwrap()
                .unwrap();
        retirement.apply().unwrap();

        assert!(home.join("settings.toml").is_file());
        assert!(!home.join("profiles/user").exists());
        assert_eq!(
            fs::read_to_string(home.join("workspace/workers/legacy/state")).unwrap(),
            "before"
        );

        restore_snapshot(&snapshot, home).unwrap();

        assert!(!home.join("settings.toml").exists());
        assert_eq!(
            fs::read_to_string(home.join("profiles/user/profile.toml")).unwrap(),
            "[settings]\nautonomousWorkers = true\n[settings.server.transcription]\nmodel = \"retired\"\n"
        );
        assert_eq!(
            fs::read_to_string(home.join("profiles/auth.json")).unwrap(),
            "{\"token\":\"kept\"}"
        );
        assert_eq!(
            fs::read_to_string(home.join("workspace/workers/legacy/state")).unwrap(),
            "before"
        );
    }
}
