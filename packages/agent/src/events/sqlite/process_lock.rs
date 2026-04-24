//! OS-level exclusive lock on the event-store database file.
//!
//! A single Tron installation must not be driven by two processes at once.
//! The in-process `with_session_write_lock` serializes writers within a single
//! daemon, but two daemons (e.g. a stray `tron dev` alongside the launchd
//! service) can both connect to the same `~/.tron/system/database/log.db`,
//! each believing it is the sole writer. SQLite's own locking serializes the
//! individual writes but does NOT prevent both processes from independently
//! allocating the same `(session_id, sequence)` and racing on the UNIQUE
//! constraint — the loser silently fails with no retry.
//!
//! This module takes an OS-level `flock(2)` on a sidecar lock file in the
//! same directory as the DB. Startup fails if the lock is already held,
//! naming the PID that owns it so the user can inspect and kill the stray.
//!
//! INVARIANT: Every production startup path acquires this lock before
//! opening the event-store connection pool. The returned [`DatabaseLock`]
//! guard must outlive the pool; dropping it releases the OS lock.

use std::fs::{File, OpenOptions};
use std::io::{Read, Write};
use std::path::{Path, PathBuf};

use thiserror::Error;

/// RAII guard holding an exclusive OS-level lock on a database file.
///
/// The lock is released when the guard is dropped (the kernel releases the
/// `flock(2)` when the file descriptor closes).
#[derive(Debug)]
pub struct DatabaseLock {
    /// Held to keep the flock alive via its file descriptor.
    _file: File,
    /// Path to the lock file (sibling of the DB), retained for diagnostics.
    pub lock_path: PathBuf,
}

/// Errors from [`acquire_database_lock`].
#[derive(Debug, Error)]
pub enum LockError {
    /// Opening or writing the lock file failed.
    #[error("failed to prepare database lock file at {path}: {source}")]
    Io {
        /// Intended lock-file path.
        path: PathBuf,
        /// Underlying I/O error.
        #[source]
        source: std::io::Error,
    },

    /// Another process already holds the lock.
    #[error(
        "database {db_path} is already in use by process {holder_pid}. \
         Stop the other Tron instance (or check for a stray `tron dev`) and retry."
    )]
    AlreadyLocked {
        /// Database the user asked to open.
        db_path: PathBuf,
        /// PID written into the lock file by the current holder.
        /// Zero if the file was unreadable (unexpected but not fatal to the error message).
        holder_pid: u32,
    },
}

/// Acquire an exclusive non-blocking lock on `db_path`.
///
/// The lock file is `<db_path>.lock` in the same directory, created with mode
/// 0o600. On success the caller's PID is written to the lock file for
/// diagnostics. On collision, the returned error carries the PID of the
/// existing holder.
pub fn acquire_database_lock(db_path: &Path) -> Result<DatabaseLock, LockError> {
    let lock_path = lock_path_for(db_path);

    if let Some(parent) = lock_path.parent() {
        std::fs::create_dir_all(parent).map_err(|e| LockError::Io {
            path: lock_path.clone(),
            source: e,
        })?;
    }

    let mut open_opts = OpenOptions::new();
    let _ = open_opts
        .create(true)
        .read(true)
        .write(true)
        .truncate(false);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt as _;
        let _ = open_opts.mode(0o600);
    }
    let mut file = open_opts.open(&lock_path).map_err(|e| LockError::Io {
        path: lock_path.clone(),
        source: e,
    })?;

    if !try_flock_exclusive(&file) {
        let holder_pid = read_holder_pid(&lock_path).unwrap_or(0);
        return Err(LockError::AlreadyLocked {
            db_path: db_path.to_path_buf(),
            holder_pid,
        });
    }

    file.set_len(0).map_err(|e| LockError::Io {
        path: lock_path.clone(),
        source: e,
    })?;
    writeln!(file, "{}", std::process::id()).map_err(|e| LockError::Io {
        path: lock_path.clone(),
        source: e,
    })?;
    file.sync_all().map_err(|e| LockError::Io {
        path: lock_path.clone(),
        source: e,
    })?;

    Ok(DatabaseLock {
        _file: file,
        lock_path,
    })
}

/// Derive the lock-file path for a given DB path: `<db>.lock`, co-located.
fn lock_path_for(db_path: &Path) -> PathBuf {
    let mut p = db_path.to_path_buf();
    let new_name = match p.file_name() {
        Some(name) => {
            let mut s = name.to_os_string();
            s.push(".lock");
            s
        }
        None => "db.lock".into(),
    };
    p.set_file_name(new_name);
    p
}

/// Try to take a non-blocking exclusive flock. Returns true on success.
#[cfg(unix)]
#[allow(unsafe_code)]
fn try_flock_exclusive(file: &File) -> bool {
    use std::os::unix::io::AsRawFd;
    let ret = unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) };
    ret == 0
}

#[cfg(not(unix))]
fn try_flock_exclusive(_file: &File) -> bool {
    // Windows/other: no flock equivalent used here; callers should guard
    // on unix in production. For now, treat as acquired (single-process
    // development on Windows not officially supported for this invariant).
    true
}

/// Read the PID currently recorded in the lock file. Returns None if the
/// file can't be read or doesn't contain a valid integer.
fn read_holder_pid(lock_path: &Path) -> Option<u32> {
    let mut f = File::open(lock_path).ok()?;
    let mut buf = String::new();
    let _ = f.read_to_string(&mut buf).ok()?;
    buf.trim().parse::<u32>().ok()
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::TempDir;

    fn db_path(dir: &TempDir) -> PathBuf {
        dir.path().join("log.db")
    }

    #[test]
    fn lock_path_derives_from_db_filename() {
        let p = lock_path_for(Path::new("/a/b/log.db"));
        assert_eq!(p, PathBuf::from("/a/b/log.db.lock"));
    }

    #[test]
    fn lock_path_for_extensionless_db() {
        let p = lock_path_for(Path::new("/tmp/mydb"));
        assert_eq!(p, PathBuf::from("/tmp/mydb.lock"));
    }

    #[test]
    fn first_acquire_succeeds() {
        let dir = TempDir::new().unwrap();
        let _lock = acquire_database_lock(&db_path(&dir)).unwrap();
    }

    #[test]
    fn second_acquire_fails_with_holder_pid() {
        let dir = TempDir::new().unwrap();
        let db = db_path(&dir);

        let _lock1 = acquire_database_lock(&db).unwrap();
        let err = acquire_database_lock(&db).unwrap_err();

        match err {
            LockError::AlreadyLocked {
                holder_pid,
                db_path,
            } => {
                assert_eq!(holder_pid, std::process::id());
                assert_eq!(db_path, db);
            }
            other => panic!("expected AlreadyLocked, got {other:?}"),
        }
    }

    #[test]
    fn drop_releases_lock() {
        let dir = TempDir::new().unwrap();
        let db = db_path(&dir);

        {
            let _lock = acquire_database_lock(&db).unwrap();
        }
        let _lock2 = acquire_database_lock(&db).unwrap();
    }

    #[test]
    #[cfg(unix)]
    fn lock_file_mode_is_0600() {
        use std::os::unix::fs::PermissionsExt;
        let dir = TempDir::new().unwrap();
        let db = db_path(&dir);
        let lock = acquire_database_lock(&db).unwrap();

        let mode = std::fs::metadata(&lock.lock_path)
            .unwrap()
            .permissions()
            .mode()
            & 0o777;
        assert_eq!(mode, 0o600);
    }

    #[test]
    fn stale_lockfile_is_acquirable_when_holder_dead() {
        // A previous process crashed, leaving the lockfile on disk. The
        // kernel released the flock when its fd closed, so the next acquire
        // must succeed. The stale PID in the file is irrelevant — flock
        // is tracked by the kernel, not by file contents.
        let dir = TempDir::new().unwrap();
        let db = db_path(&dir);
        let lock_path = lock_path_for(&db);

        std::fs::create_dir_all(lock_path.parent().unwrap()).unwrap();
        std::fs::write(&lock_path, "99999\n").unwrap();

        let lock = acquire_database_lock(&db).unwrap();
        // Current holder's PID is now recorded, overwriting the stale value.
        let recorded = read_holder_pid(&lock.lock_path).unwrap();
        assert_eq!(recorded, std::process::id());
    }

    #[test]
    fn lock_file_contains_current_pid_after_acquire() {
        let dir = TempDir::new().unwrap();
        let lock = acquire_database_lock(&db_path(&dir)).unwrap();
        let recorded = read_holder_pid(&lock.lock_path).unwrap();
        assert_eq!(recorded, std::process::id());
    }

    #[test]
    fn missing_parent_directory_is_created() {
        // If the DB path's parent doesn't exist yet, acquire_database_lock
        // must create it (it's called before the pool opens the DB file,
        // which would also need the dir to exist).
        let dir = TempDir::new().unwrap();
        let nested = dir.path().join("a").join("b").join("c");
        let db = nested.join("log.db");
        // Don't create the nested dirs — let acquire_database_lock do it.
        let _lock = acquire_database_lock(&db).unwrap();
        assert!(nested.exists());
    }

    #[test]
    fn error_message_names_holder_pid_and_db_path() {
        let dir = TempDir::new().unwrap();
        let db = db_path(&dir);
        let _lock1 = acquire_database_lock(&db).unwrap();
        let err = acquire_database_lock(&db).unwrap_err();
        let msg = err.to_string();
        assert!(
            msg.contains(&std::process::id().to_string()),
            "error should name holder pid, got: {msg}"
        );
        assert!(
            msg.contains(&db.display().to_string()),
            "error should name db path, got: {msg}"
        );
    }

    #[test]
    fn third_acquire_after_release_succeeds() {
        let dir = TempDir::new().unwrap();
        let db = db_path(&dir);

        let lock1 = acquire_database_lock(&db).unwrap();
        assert!(acquire_database_lock(&db).is_err());
        drop(lock1);
        let _lock2 = acquire_database_lock(&db).unwrap();
    }
}
