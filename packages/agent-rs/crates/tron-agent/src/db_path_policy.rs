//! Production database path policy.
//!
//! Production startup is intentionally strict: the server may only open the
//! canonical `beta-rs.db` path under `~/.tron/database`.

use std::path::{Path, PathBuf};

use anyhow::{Context, Result};

/// The only database filename allowed in production startup.
pub const PRODUCTION_DB_FILENAME: &str = "beta-rs.db";

/// Default production database directory for a given home directory.
#[must_use]
pub fn production_db_dir_from_home(home: &Path) -> PathBuf {
    home.join(".tron").join("database")
}

/// Default production database path for a given home directory.
#[must_use]
pub fn default_production_db_path_for_home(home: &Path) -> PathBuf {
    production_db_dir_from_home(home).join(PRODUCTION_DB_FILENAME)
}

/// Default production database path from `$HOME`.
#[must_use]
pub fn default_production_db_path() -> PathBuf {
    let home = std::env::var("HOME").unwrap_or_else(|_| "/tmp".to_string());
    default_production_db_path_for_home(&PathBuf::from(home))
}

/// Resolve and validate the production database path using `$HOME`.
///
/// Returns the canonical allowed path (`~/.tron/database/beta-rs.db`) when valid.
pub fn resolve_production_db_path(cli_db_path: Option<PathBuf>) -> Result<PathBuf> {
    let home = std::env::var("HOME").unwrap_or_else(|_| "/tmp".to_string());
    resolve_production_db_path_for_home(cli_db_path, &PathBuf::from(home))
}

/// Resolve and validate the production database path for a specific home dir.
///
/// This is split out for deterministic testing without mutating process env.
pub fn resolve_production_db_path_for_home(
    cli_db_path: Option<PathBuf>,
    home: &Path,
) -> Result<PathBuf> {
    let requested = cli_db_path.unwrap_or_else(|| default_production_db_path_for_home(home));
    validate_production_db_path_for_home(&requested, home)?;

    let expected_dir = production_db_dir_from_home(home);
    std::fs::create_dir_all(&expected_dir).with_context(|| {
        format!(
            "Failed to create production DB directory: {}",
            expected_dir.display()
        )
    })?;
    let canonical_expected_dir = expected_dir.canonicalize().with_context(|| {
        format!(
            "Failed to canonicalize production DB directory: {}",
            expected_dir.display()
        )
    })?;
    Ok(canonical_expected_dir.join(PRODUCTION_DB_FILENAME))
}

/// Validate that a requested DB path matches the production policy.
///
/// Rules:
/// - filename must be exactly `beta-rs.db`
/// - parent directory must resolve exactly to `~/.tron/database`
/// - symlink DB files are rejected
pub fn validate_production_db_path_for_home(db_path: &Path, home: &Path) -> Result<()> {
    let filename_ok = db_path
        .file_name()
        .and_then(std::ffi::OsStr::to_str)
        .is_some_and(|f| f == PRODUCTION_DB_FILENAME);
    if !filename_ok {
        anyhow::bail!(
            "Invalid db path '{}': production server only allows '{}'",
            db_path.display(),
            PRODUCTION_DB_FILENAME
        );
    }

    let expected_dir = production_db_dir_from_home(home);
    std::fs::create_dir_all(&expected_dir).with_context(|| {
        format!(
            "Failed to create production DB directory: {}",
            expected_dir.display()
        )
    })?;
    let expected_dir_canonical = expected_dir.canonicalize().with_context(|| {
        format!(
            "Failed to canonicalize production DB directory: {}",
            expected_dir.display()
        )
    })?;

    let Some(parent) = db_path.parent() else {
        anyhow::bail!(
            "Invalid db path '{}': missing parent directory",
            db_path.display()
        );
    };

    if !parent.exists() {
        anyhow::bail!(
            "Invalid db path '{}': parent directory '{}' does not exist",
            db_path.display(),
            parent.display()
        );
    }

    let parent_canonical = parent.canonicalize().with_context(|| {
        format!(
            "Failed to canonicalize db parent directory: {}",
            parent.display()
        )
    })?;
    if parent_canonical != expected_dir_canonical {
        anyhow::bail!(
            "Invalid db path '{}': production server only allows DBs under '{}'",
            db_path.display(),
            expected_dir_canonical.display()
        );
    }

    if let Ok(meta) = std::fs::symlink_metadata(db_path)
        && meta.file_type().is_symlink()
    {
        anyhow::bail!(
            "Invalid db path '{}': symlink DB files are not allowed",
            db_path.display()
        );
    }

    Ok(())
}
