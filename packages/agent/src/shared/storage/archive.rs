//! Startup handling for a non-current `tron.sqlite` storage generation.

use std::fs;
use std::path::Path;

use anyhow::{Context, Result};
use chrono::Utc;
use rusqlite::{Connection, OpenFlags, OptionalExtension, params};
use serde::Serialize;

use super::{
    ARCHIVE_DIR, ArchiveReport, ArchivedDatabaseFile, CURRENT_STORAGE_GENERATION,
    STORAGE_GENERATION_KEY, UNIFIED_DB_FILENAME,
};

/// Prepare the active DB path for the current storage generation.
///
/// If `tron.sqlite` already exists without the current generation marker, the
/// DB and WAL/SHM sidecars are archived before the caller opens a fresh file.
pub fn prepare_active_database(active_db_path: &Path) -> Result<ArchiveReport> {
    archive_non_current_active_database(active_db_path)
}

/// Archive `tron.sqlite` when its generation marker does not match the current
/// storage generation.
pub fn archive_non_current_active_database(active_db_path: &Path) -> Result<ArchiveReport> {
    let wal_filename = format!("{UNIFIED_DB_FILENAME}-wal");
    let shm_filename = format!("{UNIFIED_DB_FILENAME}-shm");
    if !active_db_path.exists() {
        let archive_name = archive_name("orphaned-sidecars");
        return archive_named_files(
            active_db_path,
            &[&wal_filename, &shm_filename],
            &archive_name,
            "orphaned WAL/SHM sidecars without active tron.sqlite",
        );
    }
    let generation = active_database_generation(active_db_path).with_context(|| {
        format!(
            "failed to inspect active database generation for {}",
            active_db_path.display()
        )
    })?;
    if generation.as_deref() == Some(CURRENT_STORAGE_GENERATION) {
        return Ok(ArchiveReport {
            archive_dir: None,
            files: Vec::new(),
        });
    }
    let archive_name = archive_name("non-current");
    archive_named_files(
        active_db_path,
        &[UNIFIED_DB_FILENAME, &wal_filename, &shm_filename],
        &archive_name,
        "active tron.sqlite missing current storage_generation marker",
    )
}

fn active_database_generation(path: &Path) -> Result<Option<String>> {
    let conn = Connection::open_with_flags(path, OpenFlags::SQLITE_OPEN_READ_ONLY)
        .with_context(|| format!("failed to inspect storage generation {}", path.display()))?;
    let has_metadata: i64 = conn
        .query_row(
            "SELECT COUNT(*) FROM sqlite_master
             WHERE type = 'table' AND name = 'storage_metadata'",
            [],
            |row| row.get(0),
        )
        .context("failed to inspect storage metadata table")?;
    if has_metadata == 0 {
        return Ok(None);
    }
    conn.query_row(
        "SELECT value FROM storage_metadata WHERE key = ?1",
        params![STORAGE_GENERATION_KEY],
        |row| row.get::<_, String>(0),
    )
    .optional()
    .context("failed to read storage generation marker")
}

fn archive_named_files(
    active_db_path: &Path,
    filenames: &[&str],
    archive_name: &str,
    reason: &str,
) -> Result<ArchiveReport> {
    let Some(database_dir) = active_db_path.parent() else {
        anyhow::bail!(
            "cannot archive database files for path without parent: {}",
            active_db_path.display()
        );
    };
    let mut candidates = Vec::new();
    for filename in filenames {
        let path = database_dir.join(filename);
        if path.exists() {
            candidates.push(((*filename).to_owned(), path));
        }
    }
    if candidates.is_empty() {
        return Ok(ArchiveReport {
            archive_dir: None,
            files: Vec::new(),
        });
    }
    let archive_dir = unique_archive_dir(database_dir, archive_name)?;
    fs::create_dir_all(&archive_dir)
        .with_context(|| format!("failed to create archive dir {}", archive_dir.display()))?;
    let mut archived = Vec::new();
    for (filename, source) in candidates {
        let meta = fs::metadata(&source)
            .with_context(|| format!("failed to inspect DB file {}", source.display()))?;
        let destination = archive_dir.join(&filename);
        if destination.exists() {
            anyhow::bail!(
                "refusing to overwrite existing archive file {}",
                destination.display()
            );
        }
        fs::rename(&source, &destination).with_context(|| {
            format!(
                "failed to archive DB file {} to {}",
                source.display(),
                destination.display()
            )
        })?;
        archived.push(ArchivedDatabaseFile {
            filename,
            archived_path: destination,
            size_bytes: meta.len(),
        });
    }
    write_archive_manifest(active_db_path, &archive_dir, reason, &archived)?;
    Ok(ArchiveReport {
        archive_dir: Some(archive_dir),
        files: archived,
    })
}

fn archive_name(reason: &str) -> String {
    format!(
        "{}-{}-{}",
        CURRENT_STORAGE_GENERATION,
        reason,
        Utc::now().format("%Y%m%dT%H%M%S%.3fZ")
    )
}

fn unique_archive_dir(database_dir: &Path, archive_name: &str) -> Result<std::path::PathBuf> {
    let archive_root = database_dir.join(ARCHIVE_DIR);
    let first = archive_root.join(archive_name);
    if !first.exists() {
        return Ok(first);
    }
    for suffix in 1..1000 {
        let candidate = archive_root.join(format!("{archive_name}-{suffix:03}"));
        if !candidate.exists() {
            return Ok(candidate);
        }
    }
    anyhow::bail!("failed to allocate unique archive directory for {archive_name}")
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct ArchiveManifest<'a> {
    archived_at: String,
    current_storage_generation: &'static str,
    reason: &'a str,
    source_database_path: String,
    files: &'a [ArchivedDatabaseFile],
}

fn write_archive_manifest(
    active_db_path: &Path,
    archive_dir: &Path,
    reason: &str,
    files: &[ArchivedDatabaseFile],
) -> Result<()> {
    let manifest = ArchiveManifest {
        archived_at: Utc::now().to_rfc3339(),
        current_storage_generation: CURRENT_STORAGE_GENERATION,
        reason,
        source_database_path: active_db_path.display().to_string(),
        files,
    };
    let manifest_path = archive_dir.join("archive-manifest.json");
    let bytes =
        serde_json::to_vec_pretty(&manifest).context("failed to serialize archive manifest")?;
    fs::write(&manifest_path, bytes).with_context(|| {
        format!(
            "failed to write archive manifest {}",
            manifest_path.display()
        )
    })
}
