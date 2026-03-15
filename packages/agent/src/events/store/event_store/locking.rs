use std::sync::{Arc, Mutex, MutexGuard, Weak};

use crate::events::errors::{EventStoreError, Result};
use crate::events::sqlite::connection::PooledConnection;
use crate::events::sqlite::contention::{self, RetryError};

use super::EventStore;

impl EventStore {
    pub(super) fn lock_global_write(&self) -> Result<MutexGuard<'_, ()>> {
        self.global_write_lock
            .lock()
            .map_err(|_| EventStoreError::Internal("global write lock poisoned".into()))
    }

    pub(super) fn acquire_session_write_lock(&self, session_id: &str) -> Result<Arc<Mutex<()>>> {
        let mut locks = self
            .session_write_locks
            .lock()
            .map_err(|_| EventStoreError::Internal("session lock map poisoned".into()))?;

        if locks.len() > 128 {
            locks.retain(|_, weak| weak.strong_count() > 0);
        }

        if let Some(existing) = locks.get(session_id).and_then(Weak::upgrade) {
            return Ok(existing);
        }

        let lock = Arc::new(Mutex::new(()));
        let _ = locks.insert(session_id.to_string(), Arc::downgrade(&lock));
        Ok(lock)
    }

    pub(super) fn with_session_write_lock<T>(
        &self,
        session_id: &str,
        f: impl FnMut() -> Result<T>,
    ) -> Result<T> {
        let session_lock = self.acquire_session_write_lock(session_id)?;
        let _guard = session_lock
            .lock()
            .map_err(|_| EventStoreError::Internal("session write lock poisoned".into()))?;
        self.retry_on_sqlite_busy(f)
    }

    pub(super) fn with_global_write_lock<T>(&self, f: impl FnMut() -> Result<T>) -> Result<T> {
        let _guard = self.lock_global_write()?;
        self.retry_on_sqlite_busy(f)
    }

    #[allow(clippy::unused_self)]
    pub(super) fn retry_on_sqlite_busy<T>(&self, mut f: impl FnMut() -> Result<T>) -> Result<T> {
        match contention::retry_on_busy(
            "event store write",
            contention::BusyRetryPolicy::sqlite_write(),
            &mut f,
            Self::is_sqlite_busy_or_locked,
        ) {
            Ok(value) => Ok(value),
            Err(RetryError::Inner(err)) => Err(err),
            Err(RetryError::BusyTimeout(timeout)) => Err(EventStoreError::Busy {
                operation: "event store write",
                attempts: timeout.attempts,
            }),
        }
    }

    pub(super) fn is_sqlite_busy_or_locked(err: &EventStoreError) -> bool {
        match err {
            EventStoreError::Sqlite(rusqlite::Error::SqliteFailure(code, _)) => {
                matches!(
                    code.code,
                    rusqlite::ErrorCode::DatabaseBusy | rusqlite::ErrorCode::DatabaseLocked
                )
            }
            EventStoreError::Busy { .. } => true,
            _ => false,
        }
    }

    pub(super) fn remove_session_write_lock(&self, session_id: &str) -> Result<()> {
        let mut locks = self
            .session_write_locks
            .lock()
            .map_err(|_| EventStoreError::Internal("session lock map poisoned".into()))?;
        let _ = locks.remove(session_id);
        Ok(())
    }

    pub(super) fn conn(&self) -> Result<PooledConnection> {
        Ok(self.pool.get()?)
    }
}
