//! Startup archive/reset handling for retired or incompatible database files.

use std::fs;
use std::path::Path;

use anyhow::{Context, Result};
use chrono::Utc;
use rusqlite::{Connection, OpenFlags, OptionalExtension, params};

use super::{
    ARCHIVE_DIR, ArchiveReport, ArchivedDatabaseFile, CURRENT_STORAGE_GENERATION,
    RETIRED_DATABASE_FILES, STORAGE_GENERATION_KEY, UNIFIED_DB_FILENAME,
};

/// Move retired active DB files into a timestamped archive folder.
///
/// No migrated data is read from these files. This is a one-way startup cleanup
/// so the runtime has exactly one active database path.
pub fn archive_retired_database_files(active_db_path: &Path) -> Result<ArchiveReport> {
    let Some(database_dir) = active_db_path.parent() else {
        anyhow::bail!(
            "cannot archive retired database files for path without parent: {}",
            active_db_path.display()
        );
    };

    let mut candidates = Vec::new();
    for filename in RETIRED_DATABASE_FILES {
        let path = database_dir.join(filename);
        if path.exists() {
            candidates.push((filename.to_string(), path));
        }
    }

    if candidates.is_empty() {
        return Ok(ArchiveReport {
            archive_dir: None,
            files: Vec::new(),
        });
    }

    let archive_dir = database_dir.join(ARCHIVE_DIR).join(format!(
        "unified-{}",
        Utc::now().format("%Y%m%dT%H%M%S%.3fZ")
    ));
    fs::create_dir_all(&archive_dir)
        .with_context(|| format!("failed to create archive dir {}", archive_dir.display()))?;

    let mut archived = Vec::new();
    for (filename, source) in candidates {
        let meta = fs::metadata(&source)
            .with_context(|| format!("failed to inspect retired DB file {}", source.display()))?;
        let destination = archive_dir.join(&filename);
        fs::rename(&source, &destination).with_context(|| {
            format!(
                "failed to archive retired DB file {} to {}",
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

    Ok(ArchiveReport {
        archive_dir: Some(archive_dir),
        files: archived,
    })
}

/// Prepare the active DB path for the current storage generation.
///
/// If `tron.sqlite` already exists without the current generation marker, the
/// DB and WAL/SHM sidecars are archived before the caller opens a fresh file.
/// Retired pre-unified DB files are archived in the same pass.
pub fn prepare_active_database(active_db_path: &Path) -> Result<ArchiveReport> {
    let mut report = archive_incompatible_active_database(active_db_path)?;
    let retired = archive_retired_database_files(active_db_path)?;
    if report.archive_dir.is_none() {
        report.archive_dir = retired.archive_dir;
    }
    report.files.extend(retired.files);
    Ok(report)
}

/// Archive the active DB when its generation marker does not match the current
/// Current modular-engine storage generation.
pub fn archive_incompatible_active_database(active_db_path: &Path) -> Result<ArchiveReport> {
    if !active_db_path.exists() {
        return Ok(ArchiveReport {
            archive_dir: None,
            files: Vec::new(),
        });
    }
    let generation = active_database_generation(active_db_path).unwrap_or(None);
    if generation.as_deref() == Some(CURRENT_STORAGE_GENERATION) {
        return Ok(ArchiveReport {
            archive_dir: None,
            files: Vec::new(),
        });
    }
    let wal_filename = format!("{UNIFIED_DB_FILENAME}-wal");
    let shm_filename = format!("{UNIFIED_DB_FILENAME}-shm");
    let archive_name = format!(
        "{}-{}",
        CURRENT_STORAGE_GENERATION,
        Utc::now().format("%Y%m%dT%H%M%S%.3fZ")
    );
    archive_named_files(
        active_db_path,
        &[UNIFIED_DB_FILENAME, &wal_filename, &shm_filename],
        &archive_name,
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
        .unwrap_or(0);
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
    let archive_dir = database_dir.join(ARCHIVE_DIR).join(archive_name);
    fs::create_dir_all(&archive_dir)
        .with_context(|| format!("failed to create archive dir {}", archive_dir.display()))?;
    let mut archived = Vec::new();
    for (filename, source) in candidates {
        let meta = fs::metadata(&source)
            .with_context(|| format!("failed to inspect DB file {}", source.display()))?;
        let destination = archive_dir.join(&filename);
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
    Ok(ArchiveReport {
        archive_dir: Some(archive_dir),
        files: archived,
    })
}
