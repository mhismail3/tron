use rusqlite::Connection;
use tron_events::sqlite::contention::{self, RetryError};

use super::{TaskError, TaskService};

enum ImmediateTxnError {
    Begin(rusqlite::Error),
    Task(TaskError),
}

impl ImmediateTxnError {
    fn into_task_error(self, operation: &'static str, attempts: u32) -> TaskError {
        match self {
            Self::Begin(error) => {
                if contention::is_rusqlite_busy(&error) {
                    TaskError::Busy {
                        operation,
                        attempts,
                    }
                } else {
                    TaskError::Database(error)
                }
            }
            Self::Task(error) => match error {
                TaskError::Database(database_error)
                    if contention::is_rusqlite_busy(&database_error) =>
                {
                    TaskError::Busy {
                        operation,
                        attempts,
                    }
                }
                other => other,
            },
        }
    }

    fn is_busy(&self) -> bool {
        match self {
            Self::Begin(error) | Self::Task(TaskError::Database(error)) => {
                contention::is_rusqlite_busy(error)
            }
            Self::Task(TaskError::Busy { .. }) => true,
            Self::Task(_) => false,
        }
    }
}

impl TaskService {
    /// Run a closure inside a `BEGIN IMMEDIATE` transaction with retry on
    /// `SQLITE_BUSY`. Unlike `BEGIN DEFERRED`, `IMMEDIATE` acquires the write
    /// lock upfront so contention is detected at `BEGIN` rather than mid-txn.
    pub(super) fn with_immediate_txn<T>(
        conn: &Connection,
        f: impl FnMut(&Connection) -> Result<T, TaskError>,
    ) -> Result<T, TaskError> {
        Self::with_immediate_txn_policy(conn, contention::BusyRetryPolicy::sqlite_write(), f)
    }

    pub(super) fn with_immediate_txn_policy<T>(
        conn: &Connection,
        policy: contention::BusyRetryPolicy,
        mut f: impl FnMut(&Connection) -> Result<T, TaskError>,
    ) -> Result<T, TaskError> {
        const OPERATION: &str = "task batch transaction";

        match contention::retry_on_busy(
            OPERATION,
            policy,
            || {
                conn.execute_batch("BEGIN IMMEDIATE")
                    .map_err(ImmediateTxnError::Begin)?;

                match f(conn) {
                    Ok(value) => {
                        if let Err(error) = conn.execute_batch("COMMIT") {
                            let _ = conn.execute_batch("ROLLBACK");
                            return Err(ImmediateTxnError::Begin(error));
                        }
                        Ok(value)
                    }
                    Err(error) => {
                        let _ = conn.execute_batch("ROLLBACK");
                        Err(ImmediateTxnError::Task(error))
                    }
                }
            },
            ImmediateTxnError::is_busy,
        ) {
            Ok(value) => Ok(value),
            Err(RetryError::Inner(error)) => Err(error.into_task_error(OPERATION, 0)),
            Err(RetryError::BusyTimeout(timeout)) => Err(timeout
                .last_error
                .into_task_error(OPERATION, timeout.attempts)),
        }
    }
}
