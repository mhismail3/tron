//! Versioned, checksummed profile snapshots and offline restoration.
//!
//! Snapshots contain durable profile inputs and compact SQLite images. Runtime
//! locks, logs, journals, WAL/SHM sidecars, and other reconstructible process
//! state are deliberately excluded. Archive entries are regular files; source
//! symlinks are represented as checked target text and recreated only after a
//! verified archive is selected for restoration. Verification extracts the
//! archive and replays every manifest-declared length and digest before any
//! durable profile path can be replaced.

use std::fs::{self, File};
use std::io::{self, Read};
use std::path::{Component, Path, PathBuf};

use rusqlite::{Connection, OptionalExtension, params};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use walkdir::WalkDir;

use crate::shared::foundation::{home as home_fs, paths};

const SNAPSHOT_FORMAT: &str = "tron.profile_snapshot.v1";
const MANIFEST_NAME: &str = "manifest.json";
const PURGE_MANIFEST_NAME: &str = "purge-manifest.json";
const PAYLOAD_DIR: &str = "payload";

/// Verified metadata returned to CLI and migration callers.
#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct ProfileSnapshot {
    pub path: PathBuf,
    pub sha256: String,
    pub created_at: String,
    pub source_home: String,
    pub worker_schema_version: u32,
}

/// Archive evidence returned after a retired worker is safely staged for
/// permanent removal.
#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct WorkerPurgeArchive {
    pub path: PathBuf,
    pub sha256: String,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct SnapshotManifest {
    format: String,
    schema_version: u32,
    source_home: String,
    source_profile: String,
    created_at: String,
    worker_schema_version: u32,
    engine_schema_version: u32,
    files: Vec<SnapshotFile>,
    restore: Vec<String>,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct SnapshotFile {
    relative_path: String,
    sha256: String,
    bytes: u64,
    kind: SnapshotFileKind,
}

#[derive(Clone, Copy, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
enum SnapshotFileKind {
    File,
    Symlink,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct SchemaSnapshotMarker {
    target_worker_schema: u32,
    archive: PathBuf,
    archive_sha256: String,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct PurgeManifest {
    format: String,
    schema_version: u32,
    source_home: String,
    worker_id: String,
    created_at: String,
    files: Vec<SnapshotFile>,
    restore: Vec<String>,
}

/// Create an owner-only compressed snapshot of one Tron profile.
pub(crate) fn create_profile_snapshot(home: &Path) -> Result<ProfileSnapshot, String> {
    let backup_root = backup_root(home);
    fs::create_dir_all(&backup_root).map_err(display_error("create profile backup root"))?;
    home_fs::set_private_directory_permissions(&backup_root)
        .map_err(display_error("secure profile backup root"))?;

    let created = chrono::Utc::now();
    let stem = format!(
        "profile-{}-{}",
        created.format("%Y%m%dT%H%M%SZ"),
        uuid::Uuid::now_v7()
    );
    let stage = tempfile::Builder::new()
        .prefix(&format!(".{stem}-"))
        .tempdir_in(&backup_root)
        .map_err(display_error("create profile snapshot staging directory"))?;
    home_fs::set_private_directory_permissions(stage.path())
        .map_err(display_error("secure profile snapshot staging directory"))?;
    let payload = stage.path().join(PAYLOAD_DIR);
    fs::create_dir_all(&payload).map_err(display_error("create profile snapshot payload"))?;

    let mut files = Vec::new();
    for relative in durable_roots() {
        snapshot_tree(home, &home.join(relative), &payload, &mut files)?;
    }
    snapshot_database(
        home,
        &payload,
        Path::new("internal/database/tron.sqlite"),
        &mut files,
    )?;
    snapshot_database(
        home,
        &payload,
        Path::new("internal/database/workers.sqlite"),
        &mut files,
    )?;
    files.sort_by(|left, right| left.relative_path.cmp(&right.relative_path));

    let manifest = SnapshotManifest {
        format: SNAPSHOT_FORMAT.to_owned(),
        schema_version: 1,
        source_home: home.display().to_string(),
        source_profile: "profile-global".to_owned(),
        created_at: created.to_rfc3339(),
        worker_schema_version: sqlite_worker_schema_version(
            &home.join("internal/database/workers.sqlite"),
        )?,
        engine_schema_version: sqlite_user_version(&home.join("internal/database/tron.sqlite"))?,
        files,
        restore: vec![
            "Stop Tron before restoration; the offline CLI enforces the database lock.".to_owned(),
            "Run `tron state verify <archive>` before `tron state restore <archive>`.".to_owned(),
            "Restoration first moves replaced durable state into internal/backups/recoveries/."
                .to_owned(),
        ],
    };
    write_private_json(&stage.path().join(MANIFEST_NAME), &manifest)?;

    let destination = backup_root.join(format!("{stem}.tar.zst"));
    let temporary = backup_root.join(format!(".{stem}.tar.zst.tmp"));
    write_archive(stage.path(), &temporary, MANIFEST_NAME)?;
    fs::rename(&temporary, &destination).map_err(display_error("publish profile snapshot"))?;
    home_fs::set_private_file_permissions(&destination)
        .map_err(display_error("secure profile snapshot"))?;
    let snapshot = verify_profile_snapshot(&destination)?;
    Ok(snapshot)
}

/// Archive one retired worker's immutable bundles, mutable state, and complete
/// operational export before permanent removal. Any exact known credential
/// value in those sources aborts the purge before active data is changed.
pub(crate) fn create_worker_purge_archive(
    home: &Path,
    worker_id: &str,
    bundle_dir: &Path,
    state_dir: &Path,
    operational_export: &serde_json::Value,
    known_secrets: &[String],
) -> Result<WorkerPurgeArchive, String> {
    let root = backup_root(home).join("purged-workers");
    fs::create_dir_all(&root).map_err(display_error("create purged-worker archive root"))?;
    home_fs::set_private_directory_permissions(&root)
        .map_err(display_error("secure purged-worker archive root"))?;
    let created = chrono::Utc::now();
    let stem = format!(
        "{}-{}-{}",
        worker_id,
        created.format("%Y%m%dT%H%M%SZ"),
        uuid::Uuid::now_v7()
    );
    let stage = tempfile::Builder::new()
        .prefix(&format!(".{stem}-"))
        .tempdir_in(&root)
        .map_err(display_error(
            "create purged-worker archive staging directory",
        ))?;
    home_fs::set_private_directory_permissions(stage.path()).map_err(display_error(
        "secure purged-worker archive staging directory",
    ))?;
    let payload = stage.path().join(PAYLOAD_DIR);
    fs::create_dir_all(&payload).map_err(display_error("create purged-worker payload"))?;
    let mut files = Vec::new();
    snapshot_tree(home, bundle_dir, &payload, &mut files)?;
    snapshot_tree(home, state_dir, &payload, &mut files)?;
    let records_relative =
        PathBuf::from("internal/worker-purge-records").join(format!("{worker_id}.json"));
    let records_path = payload.join(&records_relative);
    if let Some(parent) = records_path.parent() {
        fs::create_dir_all(parent).map_err(display_error("create purge records directory"))?;
    }
    fs::write(
        &records_path,
        serde_json::to_vec_pretty(operational_export)
            .map_err(|error| format!("encode worker purge records: {error}"))?,
    )
    .map_err(display_error("write worker purge records"))?;
    record_file(&payload, &records_path, SnapshotFileKind::File, &mut files)?;
    files.sort_by(|left, right| left.relative_path.cmp(&right.relative_path));
    reject_known_secrets(&payload, &files, known_secrets)?;

    let manifest = PurgeManifest {
        format: "tron.worker_purge_archive.v1".to_owned(),
        schema_version: 1,
        source_home: home.display().to_string(),
        worker_id: worker_id.to_owned(),
        created_at: created.to_rfc3339(),
        files,
        restore: vec![
            "Inspect purge-manifest.json and verify every listed checksum before recovery."
                .to_owned(),
            "Restore immutable bundle and worker-state paths beneath the recorded sourceHome, then restart Tron to rebuild indexes."
                .to_owned(),
            "Operational records are an audit export and are not automatically reimported.".to_owned(),
        ],
    };
    write_private_json(&stage.path().join(PURGE_MANIFEST_NAME), &manifest)?;
    let destination = root.join(format!("{stem}.tar.zst"));
    let temporary = root.join(format!(".{stem}.tar.zst.tmp"));
    write_archive(stage.path(), &temporary, PURGE_MANIFEST_NAME)?;
    fs::rename(&temporary, &destination).map_err(display_error("publish purged-worker archive"))?;
    home_fs::set_private_file_permissions(&destination)
        .map_err(display_error("secure purged-worker archive"))?;
    verify_worker_purge_archive(&destination, worker_id)?;
    Ok(WorkerPurgeArchive {
        sha256: sha256_file(&destination)?,
        path: destination,
    })
}

/// Ensure exactly one verified snapshot exists before a worker-schema target
/// first opens this profile. Tests use `WorkerStore::open_without_snapshot`.
pub(crate) fn ensure_worker_schema_snapshot(
    home: &Path,
    target_worker_schema: u32,
) -> Result<Option<ProfileSnapshot>, String> {
    let database = home.join("internal/database/workers.sqlite");
    if !database.exists() || sqlite_worker_schema_version(&database)? >= target_worker_schema {
        return Ok(None);
    }
    let root = backup_root(home);
    fs::create_dir_all(&root).map_err(display_error("create profile backup root"))?;
    let marker_path = root.join(format!("worker-schema-v{target_worker_schema}.json"));
    if marker_path.is_file() {
        let marker: SchemaSnapshotMarker = serde_json::from_slice(
            &fs::read(&marker_path).map_err(display_error("read worker schema snapshot marker"))?,
        )
        .map_err(|error| format!("decode worker schema snapshot marker: {error}"))?;
        if marker.target_worker_schema != target_worker_schema {
            return Err(
                "worker schema snapshot marker target does not match its filename".to_owned(),
            );
        }
        let verified = verify_profile_snapshot(&marker.archive)?;
        if verified.sha256 != marker.archive_sha256 {
            return Err("worker schema snapshot marker checksum does not match archive".to_owned());
        }
        return Ok(Some(verified));
    }

    let snapshot = create_profile_snapshot(home)?;
    let marker = SchemaSnapshotMarker {
        target_worker_schema,
        archive: snapshot.path.clone(),
        archive_sha256: snapshot.sha256.clone(),
    };
    write_private_json(&marker_path, &marker)?;
    Ok(Some(snapshot))
}

/// List compressed snapshots in deterministic newest-name order.
pub(crate) fn list_profile_snapshots(home: &Path) -> Result<Vec<PathBuf>, String> {
    let root = backup_root(home);
    if !root.is_dir() {
        return Ok(Vec::new());
    }
    let mut paths = fs::read_dir(&root)
        .map_err(display_error("read profile backup root"))?
        .filter_map(Result::ok)
        .map(|entry| entry.path())
        .filter(|path| {
            path.file_name()
                .and_then(|name| name.to_str())
                .is_some_and(|name| name.starts_with("profile-") && name.ends_with(".tar.zst"))
        })
        .collect::<Vec<_>>();
    paths.sort();
    paths.reverse();
    Ok(paths)
}

/// Fully verify archive format, path safety, file lengths, and checksums.
pub(crate) fn verify_profile_snapshot(path: &Path) -> Result<ProfileSnapshot, String> {
    let extracted = extract_archive(path)?;
    let manifest = read_manifest(extracted.path())?;
    verify_extracted(extracted.path(), &manifest)?;
    Ok(ProfileSnapshot {
        path: path.to_path_buf(),
        sha256: sha256_file(path)?,
        created_at: manifest.created_at,
        source_home: manifest.source_home,
        worker_schema_version: manifest.worker_schema_version,
    })
}

/// Restore a verified snapshot after moving every replaced target into an
/// owner-only recovery directory. Callers must hold the event database lock.
pub(crate) fn restore_profile_snapshot(path: &Path, home: &Path) -> Result<PathBuf, String> {
    let extracted = extract_archive(path)?;
    let manifest = read_manifest(extracted.path())?;
    verify_extracted(extracted.path(), &manifest)?;
    if Path::new(&manifest.source_home) != home {
        return Err(format!(
            "snapshot belongs to {}, not {}",
            manifest.source_home,
            home.display()
        ));
    }

    let recovery_root = backup_root(home).join("recoveries");
    fs::create_dir_all(&recovery_root).map_err(display_error("create recovery root"))?;
    home_fs::set_private_directory_permissions(&recovery_root)
        .map_err(display_error("secure recovery root"))?;
    let recovery = recovery_root.join(format!(
        "pre-restore-{}-{}",
        chrono::Utc::now().format("%Y%m%dT%H%M%SZ"),
        uuid::Uuid::now_v7()
    ));
    fs::create_dir_all(&recovery).map_err(display_error("create recovery directory"))?;
    home_fs::set_private_directory_permissions(&recovery)
        .map_err(display_error("secure recovery directory"))?;

    let restore_result = (|| -> Result<(), String> {
        for relative in replaced_roots() {
            move_if_present(&home.join(&relative), &recovery.join(relative))?;
        }
        for suffix in [
            "tron.sqlite-wal",
            "tron.sqlite-shm",
            "workers.sqlite-wal",
            "workers.sqlite-shm",
        ] {
            let relative = PathBuf::from("internal/database").join(suffix);
            move_if_present(&home.join(&relative), &recovery.join(relative))?;
        }
        restore_manifest_files(extracted.path(), &manifest, home)
    })();

    if let Err(error) = restore_result {
        let rollback = rollback_recovery(&recovery, home);
        return Err(match rollback {
            Ok(()) => format!("profile restore failed and prior state was restored: {error}"),
            Err(rollback_error) => format!(
                "profile restore failed: {error}; automatic recovery also failed: {rollback_error}; preserved state is at {}",
                recovery.display()
            ),
        });
    }
    Ok(recovery)
}

fn durable_roots() -> &'static [&'static str] {
    &[
        "auth.json",
        "settings.toml",
        "workspace/vault",
        "workspace/workers",
        "workspace/worker-state",
    ]
}

fn replaced_roots() -> Vec<PathBuf> {
    durable_roots()
        .iter()
        .map(PathBuf::from)
        .chain([
            PathBuf::from("internal/database/tron.sqlite"),
            PathBuf::from("internal/database/workers.sqlite"),
        ])
        .collect()
}

fn backup_root(home: &Path) -> PathBuf {
    home.join(paths::dirs::INTERNAL).join(paths::dirs::BACKUPS)
}

fn snapshot_tree(
    home: &Path,
    source: &Path,
    payload: &Path,
    files: &mut Vec<SnapshotFile>,
) -> Result<(), String> {
    if !source.exists() {
        return Ok(());
    }
    for entry in WalkDir::new(source).follow_links(false) {
        let entry = entry.map_err(|error| format!("walk durable profile state: {error}"))?;
        if entry.file_type().is_dir() {
            continue;
        }
        let relative = entry
            .path()
            .strip_prefix(home)
            .map_err(|error| format!("resolve snapshot relative path: {error}"))?;
        validate_relative(relative)?;
        let target = payload.join(relative);
        if let Some(parent) = target.parent() {
            fs::create_dir_all(parent).map_err(display_error("create snapshot payload parent"))?;
        }
        let kind = if entry.file_type().is_symlink() {
            let target_path =
                fs::read_link(entry.path()).map_err(display_error("read snapshot symlink"))?;
            let target_text = target_path.to_str().ok_or_else(|| {
                format!(
                    "snapshot symlink target is not UTF-8: {}",
                    entry.path().display()
                )
            })?;
            validate_symlink_target(relative, target_text)?;
            fs::write(&target, target_text.as_bytes())
                .map_err(display_error("record snapshot symlink"))?;
            SnapshotFileKind::Symlink
        } else if entry.file_type().is_file() {
            fs::copy(entry.path(), &target).map_err(display_error("copy durable profile file"))?;
            SnapshotFileKind::File
        } else {
            return Err(format!(
                "unsupported durable profile entry: {}",
                entry.path().display()
            ));
        };
        record_file(payload, &target, kind, files)?;
    }
    Ok(())
}

fn snapshot_database(
    home: &Path,
    payload: &Path,
    relative: &Path,
    files: &mut Vec<SnapshotFile>,
) -> Result<(), String> {
    let source = home.join(relative);
    if !source.is_file() {
        return Ok(());
    }
    let target = payload.join(relative);
    if let Some(parent) = target.parent() {
        fs::create_dir_all(parent).map_err(display_error("create snapshot database directory"))?;
    }
    let connection = Connection::open(&source)
        .map_err(|error| format!("open snapshot database {}: {error}", source.display()))?;
    connection
        .busy_timeout(std::time::Duration::from_secs(10))
        .map_err(|error| format!("configure snapshot database timeout: {error}"))?;
    connection
        .execute("VACUUM INTO ?1", params![target.to_string_lossy()])
        .map_err(|error| format!("snapshot database {}: {error}", source.display()))?;
    record_file(payload, &target, SnapshotFileKind::File, files)
}

fn record_file(
    payload: &Path,
    target: &Path,
    kind: SnapshotFileKind,
    files: &mut Vec<SnapshotFile>,
) -> Result<(), String> {
    let bytes = fs::read(target).map_err(display_error("read staged snapshot file"))?;
    let relative = target
        .strip_prefix(payload)
        .map_err(|error| format!("resolve staged snapshot path: {error}"))?;
    files.push(SnapshotFile {
        relative_path: relative.to_string_lossy().into_owned(),
        sha256: hex::encode(Sha256::digest(&bytes)),
        bytes: bytes.len() as u64,
        kind,
    });
    Ok(())
}

fn write_archive(source: &Path, destination: &Path, manifest_name: &str) -> Result<(), String> {
    let output = File::create(destination).map_err(display_error("create compressed snapshot"))?;
    home_fs::set_private_file_permissions(destination)
        .map_err(display_error("secure temporary snapshot"))?;
    let encoder = zstd::Encoder::new(output, 9)
        .map_err(|error| format!("create snapshot compressor: {error}"))?;
    let mut archive = tar::Builder::new(encoder);
    archive
        .append_path_with_name(source.join(manifest_name), manifest_name)
        .map_err(|error| format!("archive snapshot manifest: {error}"))?;
    archive
        .append_dir_all(PAYLOAD_DIR, source.join(PAYLOAD_DIR))
        .map_err(|error| format!("archive snapshot payload: {error}"))?;
    let encoder = archive
        .into_inner()
        .map_err(|error| format!("finish snapshot archive: {error}"))?;
    let output = encoder
        .finish()
        .map_err(|error| format!("finish snapshot compression: {error}"))?;
    output
        .sync_all()
        .map_err(display_error("sync compressed snapshot"))
}

fn verify_worker_purge_archive(path: &Path, worker_id: &str) -> Result<(), String> {
    let extracted = extract_archive(path)?;
    let bytes = fs::read(extracted.path().join(PURGE_MANIFEST_NAME))
        .map_err(display_error("read purged-worker manifest"))?;
    let manifest: PurgeManifest = serde_json::from_slice(&bytes)
        .map_err(|error| format!("decode purged-worker manifest: {error}"))?;
    if manifest.format != "tron.worker_purge_archive.v1"
        || manifest.schema_version != 1
        || manifest.worker_id != worker_id
    {
        return Err("purged-worker archive identity or format is invalid".to_owned());
    }
    verify_declared_files(extracted.path(), &manifest.files)
}

fn extract_archive(path: &Path) -> Result<tempfile::TempDir, String> {
    let file = File::open(path).map_err(display_error("open profile snapshot"))?;
    let decoder = zstd::Decoder::new(file)
        .map_err(|error| format!("decompress profile snapshot: {error}"))?;
    let temporary =
        tempfile::tempdir().map_err(display_error("create snapshot verification directory"))?;
    let mut archive = tar::Archive::new(decoder);
    for entry in archive
        .entries()
        .map_err(|error| format!("read profile snapshot entries: {error}"))?
    {
        let mut entry = entry.map_err(|error| format!("read profile snapshot entry: {error}"))?;
        let relative = entry
            .path()
            .map_err(|error| format!("decode profile snapshot entry path: {error}"))?
            .into_owned();
        validate_relative(&relative)?;
        let kind = entry.header().entry_type();
        if !kind.is_file() && !kind.is_dir() {
            return Err(format!(
                "profile snapshot contains unsupported archive entry {}",
                relative.display()
            ));
        }
        if !entry
            .unpack_in(temporary.path())
            .map_err(|error| format!("extract profile snapshot entry: {error}"))?
        {
            return Err(format!(
                "profile snapshot entry escaped verification root: {}",
                relative.display()
            ));
        }
    }
    Ok(temporary)
}

fn read_manifest(root: &Path) -> Result<SnapshotManifest, String> {
    let bytes =
        fs::read(root.join(MANIFEST_NAME)).map_err(display_error("read snapshot manifest"))?;
    let manifest: SnapshotManifest = serde_json::from_slice(&bytes)
        .map_err(|error| format!("decode snapshot manifest: {error}"))?;
    if manifest.format != SNAPSHOT_FORMAT || manifest.schema_version != 1 {
        return Err(format!(
            "unsupported profile snapshot format {} schema {}",
            manifest.format, manifest.schema_version
        ));
    }
    Ok(manifest)
}

fn verify_extracted(root: &Path, manifest: &SnapshotManifest) -> Result<(), String> {
    verify_declared_files(root, &manifest.files)
}

fn verify_declared_files(root: &Path, files: &[SnapshotFile]) -> Result<(), String> {
    let payload = root.join(PAYLOAD_DIR);
    let mut declared = std::collections::BTreeSet::new();
    for file in files {
        let relative = PathBuf::from(&file.relative_path);
        validate_relative(&relative)?;
        if !declared.insert(relative.clone()) {
            return Err(format!("duplicate snapshot entry: {}", file.relative_path));
        }
        let bytes = fs::read(payload.join(&relative))
            .map_err(display_error("read snapshot payload during verification"))?;
        if bytes.len() as u64 != file.bytes || hex::encode(Sha256::digest(&bytes)) != file.sha256 {
            return Err(format!(
                "snapshot checksum mismatch for {}",
                file.relative_path
            ));
        }
        if file.kind == SnapshotFileKind::Symlink {
            let target = std::str::from_utf8(&bytes)
                .map_err(|error| format!("snapshot symlink target is not UTF-8: {error}"))?;
            validate_symlink_target(&relative, target)?;
        }
    }
    for entry in WalkDir::new(&payload).follow_links(false) {
        let entry = entry.map_err(|error| format!("walk extracted snapshot: {error}"))?;
        if !entry.file_type().is_file() {
            continue;
        }
        let relative = entry
            .path()
            .strip_prefix(&payload)
            .map_err(|error| format!("resolve extracted snapshot entry: {error}"))?;
        if !declared.contains(relative) {
            return Err(format!(
                "snapshot contains undeclared payload: {}",
                relative.display()
            ));
        }
    }
    Ok(())
}

fn reject_known_secrets(
    payload: &Path,
    files: &[SnapshotFile],
    known_secrets: &[String],
) -> Result<(), String> {
    let secrets = known_secrets
        .iter()
        .filter(|secret| !secret.is_empty())
        .map(String::as_bytes)
        .collect::<Vec<_>>();
    if secrets.is_empty() {
        return Ok(());
    }
    for file in files {
        let bytes = fs::read(payload.join(&file.relative_path))
            .map_err(display_error("scan purge archive source"))?;
        if secrets
            .iter()
            .any(|secret| bytes.windows(secret.len()).any(|window| window == *secret))
        {
            return Err(format!(
                "worker purge archive rejected known credential material in {}",
                file.relative_path
            ));
        }
    }
    Ok(())
}

fn restore_manifest_files(
    root: &Path,
    manifest: &SnapshotManifest,
    home: &Path,
) -> Result<(), String> {
    for file in &manifest.files {
        let relative = PathBuf::from(&file.relative_path);
        validate_relative(&relative)?;
        let source = root.join(PAYLOAD_DIR).join(&relative);
        let target = home.join(&relative);
        if let Some(parent) = target.parent() {
            fs::create_dir_all(parent).map_err(display_error("create restore target parent"))?;
            home_fs::set_private_directory_permissions(parent)
                .map_err(display_error("secure restore target parent"))?;
        }
        match file.kind {
            SnapshotFileKind::File => {
                fs::copy(&source, &target)
                    .map_err(display_error("restore durable profile file"))?;
                home_fs::set_private_file_permissions(&target)
                    .map_err(display_error("secure restored profile file"))?;
            }
            SnapshotFileKind::Symlink => {
                let target_text = fs::read_to_string(&source)
                    .map_err(display_error("read restored symlink target"))?;
                validate_symlink_target(&relative, &target_text)?;
                create_symlink(Path::new(&target_text), &target)?;
            }
        }
    }
    Ok(())
}

fn rollback_recovery(recovery: &Path, home: &Path) -> Result<(), String> {
    for relative in replaced_roots() {
        remove_if_present(&home.join(&relative))?;
        move_if_present(&recovery.join(&relative), &home.join(relative))?;
    }
    for suffix in [
        "tron.sqlite-wal",
        "tron.sqlite-shm",
        "workers.sqlite-wal",
        "workers.sqlite-shm",
    ] {
        let relative = PathBuf::from("internal/database").join(suffix);
        remove_if_present(&home.join(&relative))?;
        move_if_present(&recovery.join(&relative), &home.join(relative))?;
    }
    Ok(())
}

fn move_if_present(source: &Path, target: &Path) -> Result<(), String> {
    if !source.exists() && fs::symlink_metadata(source).is_err() {
        return Ok(());
    }
    if let Some(parent) = target.parent() {
        fs::create_dir_all(parent).map_err(display_error("create move target parent"))?;
    }
    fs::rename(source, target).map_err(display_error("move durable profile state"))
}

fn remove_if_present(path: &Path) -> Result<(), String> {
    let Ok(metadata) = fs::symlink_metadata(path) else {
        return Ok(());
    };
    if metadata.is_dir() && !metadata.file_type().is_symlink() {
        fs::remove_dir_all(path).map_err(display_error("remove partial restored directory"))
    } else {
        fs::remove_file(path).map_err(display_error("remove partial restored file"))
    }
}

fn validate_relative(path: &Path) -> Result<(), String> {
    if path.as_os_str().is_empty()
        || path.is_absolute()
        || path.components().any(|component| {
            matches!(
                component,
                Component::ParentDir | Component::RootDir | Component::Prefix(_)
            )
        })
    {
        return Err(format!(
            "snapshot path escapes profile root: {}",
            path.display()
        ));
    }
    Ok(())
}

fn validate_symlink_target(link: &Path, target: &str) -> Result<(), String> {
    if target.is_empty() || target.contains('\0') || Path::new(target).is_absolute() {
        return Err("snapshot symlink target must be a non-empty relative path".to_owned());
    }
    let mut resolved = link
        .parent()
        .unwrap_or_else(|| Path::new(""))
        .components()
        .filter_map(|component| match component {
            Component::Normal(segment) => Some(segment.to_os_string()),
            _ => None,
        })
        .collect::<Vec<_>>();
    for component in Path::new(target).components() {
        match component {
            Component::CurDir => {}
            Component::Normal(segment) => resolved.push(segment.to_os_string()),
            Component::ParentDir if resolved.pop().is_some() => {}
            Component::ParentDir | Component::RootDir | Component::Prefix(_) => {
                return Err(format!(
                    "snapshot symlink {} escapes the profile root",
                    link.display()
                ));
            }
        }
    }
    Ok(())
}

fn sqlite_worker_schema_version(path: &Path) -> Result<u32, String> {
    if !path.is_file() {
        return Ok(0);
    }
    let connection = Connection::open(path)
        .map_err(|error| format!("open worker database for schema inspection: {error}"))?;
    let exists = connection
        .query_row(
            "SELECT 1 FROM sqlite_master WHERE type='table' AND name='worker_schema'",
            [],
            |_| Ok(()),
        )
        .optional()
        .map_err(|error| format!("inspect worker schema table: {error}"))?
        .is_some();
    if !exists {
        return Ok(0);
    }
    connection
        .query_row(
            "SELECT COALESCE(MAX(version), 0) FROM worker_schema",
            [],
            |row| row.get(0),
        )
        .map_err(|error| format!("read worker schema version: {error}"))
}

fn sqlite_user_version(path: &Path) -> Result<u32, String> {
    if !path.is_file() {
        return Ok(0);
    }
    Connection::open(path)
        .and_then(|connection| connection.query_row("PRAGMA user_version", [], |row| row.get(0)))
        .map_err(|error| format!("read engine schema version: {error}"))
}

fn write_private_json(path: &Path, value: &impl Serialize) -> Result<(), String> {
    let bytes = serde_json::to_vec_pretty(value)
        .map_err(|error| format!("encode snapshot metadata: {error}"))?;
    fs::write(path, bytes).map_err(display_error("write snapshot metadata"))?;
    home_fs::set_private_file_permissions(path).map_err(display_error("secure snapshot metadata"))
}

fn sha256_file(path: &Path) -> Result<String, String> {
    let mut file = File::open(path).map_err(display_error("open snapshot for checksum"))?;
    let mut digest = Sha256::new();
    let mut buffer = [0_u8; 64 * 1024];
    loop {
        let count = file
            .read(&mut buffer)
            .map_err(display_error("read snapshot for checksum"))?;
        if count == 0 {
            break;
        }
        digest.update(&buffer[..count]);
    }
    Ok(hex::encode(digest.finalize()))
}

fn display_error(context: &'static str) -> impl FnOnce(io::Error) -> String {
    move |error| format!("{context}: {error}")
}

#[cfg(unix)]
fn create_symlink(target: &Path, link: &Path) -> Result<(), String> {
    std::os::unix::fs::symlink(target, link).map_err(display_error("restore profile symlink"))
}

#[cfg(not(unix))]
fn create_symlink(_target: &Path, link: &Path) -> Result<(), String> {
    Err(format!(
        "symlink restoration is unsupported for {}",
        link.display()
    ))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn seed_database(path: &Path, worker: bool) {
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent).unwrap();
        }
        let connection = Connection::open(path).unwrap();
        if worker {
            connection
                .execute_batch("CREATE TABLE worker_schema(version INTEGER PRIMARY KEY, applied_at TEXT NOT NULL); INSERT INTO worker_schema VALUES(3, 'now');")
                .unwrap();
        } else {
            connection.execute_batch("CREATE TABLE sessions(id TEXT PRIMARY KEY); INSERT INTO sessions VALUES('kept'); PRAGMA user_version=7;").unwrap();
        }
    }

    #[test]
    fn compressed_snapshot_verifies_and_restores_all_durable_roots() {
        let temporary = tempfile::tempdir().unwrap();
        let home = temporary.path().join(".tron");
        fs::create_dir_all(home.join("workspace/vault")).unwrap();
        fs::create_dir_all(home.join("workspace/workers/example")).unwrap();
        fs::create_dir_all(home.join("workspace/worker-state/example")).unwrap();
        fs::write(home.join("auth.json"), "{\"token\":\"kept\"}").unwrap();
        fs::write(home.join("settings.toml"), "[models]\n").unwrap();
        fs::write(home.join("workspace/vault/key"), "secret").unwrap();
        fs::write(home.join("workspace/workers/example/manifest.json"), "{}").unwrap();
        fs::write(
            home.join("workspace/worker-state/example/state.db"),
            "before",
        )
        .unwrap();
        seed_database(&home.join("internal/database/tron.sqlite"), false);
        seed_database(&home.join("internal/database/workers.sqlite"), true);

        let snapshot = create_profile_snapshot(&home).unwrap();
        assert_eq!(snapshot.worker_schema_version, 3);
        assert_eq!(snapshot.source_home, home.display().to_string());
        assert_eq!(fs::metadata(&snapshot.path).unwrap().len() > 0, true);
        verify_profile_snapshot(&snapshot.path).unwrap();

        fs::write(home.join("auth.json"), "changed").unwrap();
        fs::write(
            home.join("workspace/worker-state/example/state.db"),
            "after",
        )
        .unwrap();
        let recovery = restore_profile_snapshot(&snapshot.path, &home).unwrap();
        assert_eq!(
            fs::read_to_string(home.join("auth.json")).unwrap(),
            "{\"token\":\"kept\"}"
        );
        assert_eq!(
            fs::read_to_string(home.join("workspace/worker-state/example/state.db")).unwrap(),
            "before"
        );
        assert_eq!(
            fs::read_to_string(recovery.join("auth.json")).unwrap(),
            "changed"
        );
        assert_eq!(
            fs::read_to_string(recovery.join("workspace/worker-state/example/state.db")).unwrap(),
            "after"
        );
    }

    #[test]
    fn corruption_fails_verification_before_restore() {
        let temporary = tempfile::tempdir().unwrap();
        let home = temporary.path().join(".tron");
        fs::create_dir_all(home.join("workspace/vault")).unwrap();
        fs::write(home.join("settings.toml"), "before").unwrap();
        let snapshot = create_profile_snapshot(&home).unwrap();

        // Repack a valid archive after changing one declared payload member,
        // leaving its manifest length and digest untouched. Flipping an
        // arbitrary compressed byte is not deterministic: zstd can legally
        // ignore changes in padding or a frame region outside the payload.
        let extracted = extract_archive(&snapshot.path).unwrap();
        fs::write(
            extracted.path().join(PAYLOAD_DIR).join("settings.toml"),
            "tampered",
        )
        .unwrap();
        let corrupted = temporary.path().join("corrupted-profile.tar.zst");
        write_archive(extracted.path(), &corrupted, MANIFEST_NAME).unwrap();

        let error = verify_profile_snapshot(&corrupted).unwrap_err();
        assert!(error.contains("snapshot checksum mismatch for settings.toml"));
        assert_eq!(
            fs::read_to_string(home.join("settings.toml")).unwrap(),
            "before"
        );
    }

    #[cfg(unix)]
    #[test]
    fn snapshot_rejects_a_symlink_that_escapes_the_profile_root() {
        let temporary = tempfile::tempdir().unwrap();
        let home = temporary.path().join(".tron");
        fs::create_dir_all(home.join("workspace/vault")).unwrap();
        std::os::unix::fs::symlink(
            "../../../outside",
            home.join("workspace/vault/escaping-link"),
        )
        .unwrap();

        let error = create_profile_snapshot(&home).unwrap_err();
        assert!(error.contains("escapes the profile root"), "{error}");
        assert!(list_profile_snapshots(&home).unwrap().is_empty());
    }

    #[test]
    fn schema_snapshot_is_created_once_and_reverified() {
        let temporary = tempfile::tempdir().unwrap();
        let home = temporary.path().join(".tron");
        seed_database(&home.join("internal/database/workers.sqlite"), true);
        let first = ensure_worker_schema_snapshot(&home, 4).unwrap().unwrap();
        assert!(first.path.is_file());
        let reverified = ensure_worker_schema_snapshot(&home, 4).unwrap().unwrap();
        assert_eq!(reverified.path, first.path);
        assert_eq!(reverified.sha256, first.sha256);
        assert_eq!(list_profile_snapshots(&home).unwrap(), vec![first.path]);
    }
}
