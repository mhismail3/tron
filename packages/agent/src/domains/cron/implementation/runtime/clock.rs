//! Clock abstraction for testable time.
//!
//! Every component that reads the current time takes `Arc<dyn Clock>`.
//! Production uses [`SystemClock`]; tests use [`FakeClock`] for deterministic
//! scheduling without real timers.

use chrono::{DateTime, Utc};

/// Abstraction over wall-clock time.
pub trait Clock: Send + Sync {
    /// Current time in UTC.
    fn now_utc(&self) -> DateTime<Utc>;
}

/// Production clock — reads system time.
pub struct SystemClock;

impl Clock for SystemClock {
    fn now_utc(&self) -> DateTime<Utc> {
        Utc::now()
    }
}

/// Test clock — returns a controllable time.
///
/// Thread-safe: multiple scheduler threads can read; test harness advances.
#[cfg(test)]
pub struct FakeClock {
    now: parking_lot::Mutex<DateTime<Utc>>,
}

#[cfg(test)]
impl FakeClock {
    /// Create a fake clock frozen at the given time.
    pub fn new(time: DateTime<Utc>) -> Self {
        Self {
            now: parking_lot::Mutex::new(time),
        }
    }

    /// Advance the clock by the given duration.
    pub fn advance(&self, duration: chrono::Duration) {
        let mut now = self.now.lock();
        *now += duration;
    }

    /// Set the clock to an exact time.
    pub fn set(&self, time: DateTime<Utc>) {
        *self.now.lock() = time;
    }
}

#[cfg(test)]
impl Clock for FakeClock {
    fn now_utc(&self) -> DateTime<Utc> {
        *self.now.lock()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn system_clock_returns_recent_time() {
        let clock = SystemClock;
        let now = clock.now_utc();
        let diff = Utc::now() - now;
        assert!(diff.num_seconds().abs() < 2);
    }

    #[test]
    fn fake_clock_frozen() {
        let time = DateTime::parse_from_rfc3339("2026-01-15T10:00:00Z")
            .unwrap()
            .to_utc();
        let clock = FakeClock::new(time);
        assert_eq!(clock.now_utc(), time);
        assert_eq!(clock.now_utc(), time);
    }

    #[test]
    fn fake_clock_advance() {
        let time = DateTime::parse_from_rfc3339("2026-01-15T10:00:00Z")
            .unwrap()
            .to_utc();
        let clock = FakeClock::new(time);
        clock.advance(chrono::Duration::hours(1));
        let expected = DateTime::parse_from_rfc3339("2026-01-15T11:00:00Z")
            .unwrap()
            .to_utc();
        assert_eq!(clock.now_utc(), expected);
    }

    #[test]
    fn fake_clock_set() {
        let time1 = DateTime::parse_from_rfc3339("2026-01-15T10:00:00Z")
            .unwrap()
            .to_utc();
        let time2 = DateTime::parse_from_rfc3339("2026-06-01T00:00:00Z")
            .unwrap()
            .to_utc();
        let clock = FakeClock::new(time1);
        clock.set(time2);
        assert_eq!(clock.now_utc(), time2);
    }
}
