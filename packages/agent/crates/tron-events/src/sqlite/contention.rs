//! Shared `SQLite` write-contention policy.
//!
//! This module provides the single retry/backoff implementation used by both
//! the event store and task services. Callers decide which errors are
//! retryable; this helper owns the timing and timeout policy.

use std::time::{Duration, Instant};

use metrics::{counter, histogram};

/// Keep `SQLite`'s built-in `busy_timeout` short so contention is surfaced
/// back to the shared retry loop quickly. Longer engine-level waits block a
/// thread inside `SQLite` and undermine the application-level deadline.
pub const SQLITE_BUSY_TIMEOUT: Duration = Duration::from_millis(50);

/// Retry policy for blocking `SQLite` write contention.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct BusyRetryPolicy {
    /// Total time budget for retrying a busy/locked operation.
    pub deadline: Duration,
    /// Linear backoff step per retry.
    pub backoff_step: Duration,
    /// Maximum backoff between attempts.
    pub max_backoff: Duration,
    /// Random jitter applied symmetrically around the computed delay.
    pub jitter_percent: u32,
}

impl BusyRetryPolicy {
    /// Default write policy shared by storage services.
    #[must_use]
    pub fn sqlite_write() -> Self {
        Self {
            deadline: Duration::from_secs(5),
            backoff_step: Duration::from_millis(10),
            max_backoff: Duration::from_millis(500),
            jitter_percent: 25,
        }
    }

    /// Connection-level `busy_timeout` used for pooled `SQLite` connections.
    #[must_use]
    pub fn sqlite_busy_timeout_ms() -> u32 {
        u32::try_from(SQLITE_BUSY_TIMEOUT.as_millis()).unwrap_or(u32::MAX)
    }

    #[must_use]
    fn base_delay(self, attempt: u32) -> Duration {
        let step_ms = self.backoff_step.as_millis().min(u128::from(u64::MAX));
        let max_ms = self.max_backoff.as_millis().min(u128::from(u64::MAX));
        let delay_ms = step_ms.saturating_mul(u128::from(attempt)).min(max_ms);
        let delay_ms = u64::try_from(delay_ms).unwrap_or(u64::MAX);
        Duration::from_millis(delay_ms)
    }

    #[must_use]
    fn jittered_delay(self, attempt: u32) -> Duration {
        let base = self.base_delay(attempt);
        if base.is_zero() || self.jitter_percent == 0 {
            return base;
        }

        let base_ms = base.as_millis().min(u128::from(u64::MAX)) as u64;
        let jitter_range = base_ms.saturating_mul(u64::from(self.jitter_percent)) / 100;
        if jitter_range == 0 {
            return base;
        }

        let span = jitter_range.saturating_mul(2).saturating_add(1);
        let offset = rand::random::<u64>() % span;
        let delay_ms = base_ms
            .saturating_sub(jitter_range)
            .saturating_add(offset)
            .min(self.max_backoff.as_millis().min(u128::from(u64::MAX)) as u64);
        Duration::from_millis(delay_ms)
    }
}

/// Busy timeout information returned when an operation never becomes writable.
#[derive(Debug)]
pub struct BusyTimeout<E> {
    /// Number of busy/locked failures observed before timing out.
    pub attempts: u32,
    /// Last busy/locked error returned by the operation.
    pub last_error: E,
}

/// Result of applying the shared busy-retry policy.
#[derive(Debug)]
pub enum RetryError<E> {
    /// The operation failed with a non-retryable error.
    Inner(E),
    /// The operation remained busy/locked until the deadline expired.
    BusyTimeout(BusyTimeout<E>),
}

/// Retry an operation while it returns retryable busy/locked errors.
pub fn retry_on_busy<T, E, F, IsBusy>(
    operation_name: &'static str,
    policy: BusyRetryPolicy,
    mut operation: F,
    is_busy: IsBusy,
) -> std::result::Result<T, RetryError<E>>
where
    F: FnMut() -> std::result::Result<T, E>,
    IsBusy: Fn(&E) -> bool,
{
    let started_at = Instant::now();
    let mut attempts = 0u32;

    loop {
        match operation() {
            Ok(value) => {
                record_retry_outcome(operation_name, attempts, started_at.elapsed(), "success");
                return Ok(value);
            }
            Err(error) if is_busy(&error) => {
                attempts = attempts.saturating_add(1);
                counter!("sqlite_busy_retries_total", "operation" => operation_name.to_owned())
                    .increment(1);
                if started_at.elapsed() >= policy.deadline {
                    counter!(
                        "sqlite_busy_timeouts_total",
                        "operation" => operation_name.to_owned()
                    )
                    .increment(1);
                    record_retry_outcome(operation_name, attempts, started_at.elapsed(), "timeout");
                    return Err(RetryError::BusyTimeout(BusyTimeout {
                        attempts,
                        last_error: error,
                    }));
                }

                std::thread::sleep(policy.jittered_delay(attempts));
            }
            Err(error) => {
                record_retry_outcome(operation_name, attempts, started_at.elapsed(), "error");
                return Err(RetryError::Inner(error));
            }
        }
    }
}

fn record_retry_outcome(
    operation_name: &'static str,
    attempts: u32,
    duration: Duration,
    outcome: &'static str,
) {
    histogram!(
        "sqlite_busy_attempts",
        "operation" => operation_name.to_owned(),
        "outcome" => outcome.to_owned()
    )
    .record(f64::from(attempts));
    histogram!(
        "sqlite_busy_duration_seconds",
        "operation" => operation_name.to_owned(),
        "outcome" => outcome.to_owned()
    )
    .record(duration.as_secs_f64());
}

/// Whether a `rusqlite` error is `BUSY` or `LOCKED`.
#[must_use]
pub fn is_rusqlite_busy(err: &rusqlite::Error) -> bool {
    matches!(
        err,
        rusqlite::Error::SqliteFailure(
            rusqlite::ffi::Error {
                code: rusqlite::ffi::ErrorCode::DatabaseBusy,
                ..
            } | rusqlite::ffi::Error {
                code: rusqlite::ffi::ErrorCode::DatabaseLocked,
                ..
            },
            _
        )
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[derive(Clone, Debug, PartialEq, Eq)]
    struct MockError {
        busy: bool,
        label: &'static str,
    }

    #[test]
    fn retry_on_busy_eventually_succeeds() {
        let mut attempts = 0u32;
        let policy = BusyRetryPolicy {
            deadline: Duration::from_secs(1),
            backoff_step: Duration::ZERO,
            max_backoff: Duration::ZERO,
            jitter_percent: 0,
        };

        let result = retry_on_busy(
            "test_retry_success",
            policy,
            || {
                attempts += 1;
                if attempts < 4 {
                    Err(MockError {
                        busy: true,
                        label: "busy",
                    })
                } else {
                    Ok("ok")
                }
            },
            |error: &MockError| error.busy,
        )
        .unwrap();

        assert_eq!(result, "ok");
        assert_eq!(attempts, 4);
    }

    #[test]
    fn retry_on_busy_stops_on_nonbusy_error() {
        let policy = BusyRetryPolicy {
            deadline: Duration::from_secs(1),
            backoff_step: Duration::ZERO,
            max_backoff: Duration::ZERO,
            jitter_percent: 0,
        };

        let result = retry_on_busy(
            "test_retry_error",
            policy,
            || {
                Err::<(), _>(MockError {
                    busy: false,
                    label: "fatal",
                })
            },
            |error: &MockError| error.busy,
        );

        match result {
            Err(RetryError::Inner(error)) => assert_eq!(error.label, "fatal"),
            other => panic!("expected nonbusy error, got {other:?}"),
        }
    }

    #[test]
    fn retry_on_busy_times_out() {
        let policy = BusyRetryPolicy {
            deadline: Duration::ZERO,
            backoff_step: Duration::ZERO,
            max_backoff: Duration::ZERO,
            jitter_percent: 0,
        };

        let result = retry_on_busy(
            "test_retry_timeout",
            policy,
            || {
                Err::<(), _>(MockError {
                    busy: true,
                    label: "busy",
                })
            },
            |error: &MockError| error.busy,
        );

        match result {
            Err(RetryError::BusyTimeout(timeout)) => {
                assert_eq!(timeout.attempts, 1);
                assert_eq!(timeout.last_error.label, "busy");
            }
            other => panic!("expected busy timeout, got {other:?}"),
        }
    }

    #[test]
    fn detects_rusqlite_busy_and_locked() {
        let busy = rusqlite::Error::SqliteFailure(
            rusqlite::ffi::Error {
                code: rusqlite::ffi::ErrorCode::DatabaseBusy,
                extended_code: rusqlite::ffi::ErrorCode::DatabaseBusy as i32,
            },
            None,
        );
        let locked = rusqlite::Error::SqliteFailure(
            rusqlite::ffi::Error {
                code: rusqlite::ffi::ErrorCode::DatabaseLocked,
                extended_code: rusqlite::ffi::ErrorCode::DatabaseLocked as i32,
            },
            None,
        );
        let other = rusqlite::Error::QueryReturnedNoRows;

        assert!(is_rusqlite_busy(&busy));
        assert!(is_rusqlite_busy(&locked));
        assert!(!is_rusqlite_busy(&other));
    }
}
