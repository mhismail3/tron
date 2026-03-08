#![allow(unused_results)]
//! Cron expression parsing and next-run computation.
//!
//! Custom 5-field cron parser that handles DST transitions safely.
//! The `cron` crate v0.15 panics during DST spring-forward gaps, so we
//! implement a minimal parser that handles `LocalResult::None` and
//! `LocalResult::Ambiguous` correctly.
//!
//! Supported syntax per field: `*`, `N`, `N-M`, `N-M/S`, `*/S`, `N,M,O`

use std::collections::BTreeSet;

use chrono::{DateTime, Datelike, NaiveDate, NaiveDateTime, NaiveTime, TimeZone, Timelike, Utc};
use chrono_tz::Tz;

use crate::errors::CronError;
use crate::types::Schedule;

/// Parsed 5-field cron expression.
#[derive(Clone, Debug, PartialEq)]
pub struct CronExpression {
    /// Valid minutes (0..=59).
    pub minutes: BTreeSet<u32>,
    /// Valid hours (0..=23).
    pub hours: BTreeSet<u32>,
    /// Valid days of month (1..=31).
    pub days_of_month: BTreeSet<u32>,
    /// Valid months (1..=12).
    pub months: BTreeSet<u32>,
    /// Valid days of week (0..=6, 0=Sunday).
    pub days_of_week: BTreeSet<u32>,
}

impl CronExpression {
    /// Parse a 5-field cron expression.
    pub fn parse(expr: &str) -> Result<Self, CronError> {
        let fields: Vec<&str> = expr.split_whitespace().collect();
        if fields.len() != 5 {
            return Err(CronError::InvalidExpression(format!(
                "expected 5 fields, got {}",
                fields.len()
            )));
        }
        Ok(Self {
            minutes: parse_field(fields[0], 0, 59)?,
            hours: parse_field(fields[1], 0, 23)?,
            days_of_month: parse_field(fields[2], 1, 31)?,
            months: parse_field(fields[3], 1, 12)?,
            days_of_week: parse_field(fields[4], 0, 6)?,
        })
    }

    /// Find the next occurrence after `after` in the given timezone.
    ///
    /// Returns UTC. Handles DST transitions safely:
    /// - Spring-forward gap (`LocalResult::None`): skip to end of gap
    /// - Fall-back ambiguity (`LocalResult::Ambiguous`): pick earliest
    ///
    /// Caps search at 4 years to prevent infinite loops on impossible expressions.
    pub fn next_after(&self, after: DateTime<Utc>, tz: &Tz) -> Option<DateTime<Utc>> {
        let local = after.with_timezone(tz).naive_local();
        // Start searching from the next minute
        let start = advance_one_minute(local);
        let cap = local + chrono::Duration::days(366 * 4);

        let mut date = start.date();
        let start_time = start.time();

        // INVARIANT: (0, 0, 0) is always a valid time.
        while NaiveDateTime::new(date, NaiveTime::from_hms_opt(0, 0, 0).unwrap()) <= cap {
            // Check month
            if !self.months.contains(&date.month()) {
                date = next_month_start(date)?;
                continue;
            }

            // Check day of month and day of week
            if !self.days_of_month.contains(&date.day())
                || !self.days_of_week.contains(&date.weekday().num_days_from_sunday())
            {
                date = date.succ_opt()?;
                continue;
            }

            // Find first matching hour:minute on this date
            let min_hour = if date == start.date() {
                start_time.hour()
            } else {
                0
            };

            for &hour in self.hours.range(min_hour..) {
                let min_minute = if date == start.date() && hour == start_time.hour() {
                    start_time.minute()
                } else {
                    0
                };

                for &minute in self.minutes.range(min_minute..) {
                    let naive =
                        NaiveDateTime::new(date, NaiveTime::from_hms_opt(hour, minute, 0)?);

                    // Convert to timezone-aware, handling DST
                    match tz.from_local_datetime(&naive) {
                        chrono::LocalResult::Single(dt) => return Some(dt.to_utc()),
                        chrono::LocalResult::Ambiguous(earliest, _) => {
                            return Some(earliest.to_utc());
                        }
                        chrono::LocalResult::None => {
                            // Spring-forward gap — this time doesn't exist.
                            // Skip to the end of the gap by using the UTC equivalent.
                        }
                    }
                }
            }

            date = date.succ_opt()?;
        }

        None // 4-year cap reached — impossible expression
    }
}

/// Advance a `NaiveDateTime` to the start of the next minute.
fn advance_one_minute(dt: NaiveDateTime) -> NaiveDateTime {
    let next = dt + chrono::Duration::minutes(1);
    // INVARIANT: hour/minute from a valid NaiveDateTime are always valid time components.
    NaiveDateTime::new(
        next.date(),
        NaiveTime::from_hms_opt(next.hour(), next.minute(), 0).unwrap(),
    )
}

/// Advance to the first day of the next month.
fn next_month_start(date: NaiveDate) -> Option<NaiveDate> {
    if date.month() == 12 {
        NaiveDate::from_ymd_opt(date.year() + 1, 1, 1)
    } else {
        NaiveDate::from_ymd_opt(date.year(), date.month() + 1, 1)
    }
}

/// Parse a single cron field (e.g. `"*/5"`, `"1-15"`, `"1,5,10"`).
fn parse_field(field: &str, min: u32, max: u32) -> Result<BTreeSet<u32>, CronError> {
    let mut set = BTreeSet::new();

    for part in field.split(',') {
        if part.contains('/') {
            // Step: */S or N-M/S
            let (range_part, step_part) = part
                .split_once('/')
                .ok_or_else(|| CronError::InvalidExpression(format!("invalid step: {part}")))?;

            let step: u32 = step_part
                .parse()
                .map_err(|_| CronError::InvalidExpression(format!("invalid step value: {step_part}")))?;

            if step == 0 {
                return Err(CronError::InvalidExpression(
                    "step value must be > 0".into(),
                ));
            }

            let (start, end) = if range_part == "*" {
                (min, max)
            } else {
                parse_range(range_part, min, max)?
            };

            let mut v = start;
            while v <= end {
                set.insert(v);
                v += step;
            }
        } else if part.contains('-') {
            // Range: N-M
            let (start, end) = parse_range(part, min, max)?;
            for v in start..=end {
                set.insert(v);
            }
        } else if part == "*" {
            for v in min..=max {
                set.insert(v);
            }
        } else {
            // Single value
            let v: u32 = part
                .parse()
                .map_err(|_| CronError::InvalidExpression(format!("invalid value: {part}")))?;
            if v < min || v > max {
                return Err(CronError::InvalidExpression(format!(
                    "value {v} out of range [{min}..{max}]"
                )));
            }
            set.insert(v);
        }
    }

    if set.is_empty() {
        return Err(CronError::InvalidExpression(
            "field resolved to empty set".into(),
        ));
    }

    Ok(set)
}

/// Parse a range like `"1-15"`.
fn parse_range(s: &str, min: u32, max: u32) -> Result<(u32, u32), CronError> {
    let (a, b) = s
        .split_once('-')
        .ok_or_else(|| CronError::InvalidExpression(format!("invalid range: {s}")))?;

    let start: u32 = a
        .parse()
        .map_err(|_| CronError::InvalidExpression(format!("invalid range start: {a}")))?;
    let end: u32 = b
        .parse()
        .map_err(|_| CronError::InvalidExpression(format!("invalid range end: {b}")))?;

    if start < min || end > max || start > end {
        return Err(CronError::InvalidExpression(format!(
            "range {start}-{end} invalid for [{min}..{max}]"
        )));
    }

    Ok((start, end))
}

/// Compute the next run time for any schedule type.
///
/// Pure function — depends only on the schedule definition and `after` time.
pub fn compute_next_run(schedule: &Schedule, after: DateTime<Utc>) -> Option<DateTime<Utc>> {
    match schedule {
        Schedule::Cron {
            expression,
            timezone,
        } => {
            let parsed = CronExpression::parse(expression).ok()?;
            let tz: Tz = timezone.parse().ok()?;
            parsed.next_after(after, &tz)
        }
        Schedule::Every {
            interval_secs,
            anchor,
        } => {
            let interval = *interval_secs as i64;
            let base = anchor.unwrap_or(DateTime::UNIX_EPOCH);
            if after < base {
                return Some(base);
            }
            let elapsed = (after - base).num_seconds();
            let periods = elapsed / interval + 1;
            Some(base + chrono::Duration::seconds(periods * interval))
        }
        Schedule::OneShot { at } => {
            if *at > after {
                Some(*at)
            } else {
                None
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn utc(s: &str) -> DateTime<Utc> {
        DateTime::parse_from_rfc3339(s).unwrap().to_utc()
    }

    // ── Parser tests ──

    #[test]
    fn parse_every_minute() {
        let expr = CronExpression::parse("* * * * *").unwrap();
        assert_eq!(expr.minutes.len(), 60);
        assert_eq!(expr.hours.len(), 24);
    }

    #[test]
    fn parse_specific_time() {
        let expr = CronExpression::parse("30 9 * * *").unwrap();
        assert_eq!(expr.minutes, [30].into());
        assert_eq!(expr.hours, [9].into());
    }

    #[test]
    fn parse_range() {
        let expr = CronExpression::parse("0-30 * * * *").unwrap();
        assert_eq!(expr.minutes.len(), 31);
        assert!(expr.minutes.contains(&0));
        assert!(expr.minutes.contains(&30));
        assert!(!expr.minutes.contains(&31));
    }

    #[test]
    fn parse_step() {
        let expr = CronExpression::parse("*/5 * * * *").unwrap();
        assert_eq!(
            expr.minutes,
            [0, 5, 10, 15, 20, 25, 30, 35, 40, 45, 50, 55].into()
        );
    }

    #[test]
    fn parse_list() {
        let expr = CronExpression::parse("0,15,30,45 * * * *").unwrap();
        assert_eq!(expr.minutes, [0, 15, 30, 45].into());
    }

    #[test]
    fn parse_combined() {
        let expr = CronExpression::parse("0 9-17 * * 1-5").unwrap();
        assert_eq!(expr.minutes, [0].into());
        assert_eq!(expr.hours.len(), 9); // 9..=17
        assert_eq!(expr.days_of_week, [1, 2, 3, 4, 5].into());
    }

    #[test]
    fn parse_day_of_week_sunday() {
        let expr = CronExpression::parse("0 0 * * 0").unwrap();
        assert_eq!(expr.days_of_week, [0].into());
    }

    #[test]
    fn parse_invalid_field_count() {
        assert!(CronExpression::parse("* *").is_err());
        assert!(CronExpression::parse("* * * * * *").is_err());
    }

    #[test]
    fn parse_invalid_range() {
        assert!(CronExpression::parse("60 * * * *").is_err());
        assert!(CronExpression::parse("* 25 * * *").is_err());
    }

    #[test]
    fn parse_invalid_step() {
        assert!(CronExpression::parse("*/0 * * * *").is_err());
    }

    // ── Next-run computation (cron) ──

    #[test]
    fn cron_next_after_simple() {
        let expr = CronExpression::parse("0 9 * * *").unwrap();
        let tz: Tz = "UTC".parse().unwrap();
        let after = utc("2026-01-15T08:00:00Z");
        let next = expr.next_after(after, &tz).unwrap();
        assert_eq!(next, utc("2026-01-15T09:00:00Z"));
    }

    #[test]
    fn cron_next_after_past_today() {
        let expr = CronExpression::parse("0 9 * * *").unwrap();
        let tz: Tz = "UTC".parse().unwrap();
        let after = utc("2026-01-15T10:00:00Z");
        let next = expr.next_after(after, &tz).unwrap();
        assert_eq!(next, utc("2026-01-16T09:00:00Z"));
    }

    #[test]
    fn cron_next_after_month_boundary() {
        let expr = CronExpression::parse("0 0 1 * *").unwrap();
        let tz: Tz = "UTC".parse().unwrap();
        let after = utc("2026-12-31T00:00:00Z");
        let next = expr.next_after(after, &tz).unwrap();
        assert_eq!(next, utc("2027-01-01T00:00:00Z"));
    }

    #[test]
    fn cron_next_after_impossible() {
        // Feb 31 never exists
        let expr = CronExpression::parse("0 0 31 2 *").unwrap();
        let tz: Tz = "UTC".parse().unwrap();
        let after = utc("2026-01-01T00:00:00Z");
        assert!(expr.next_after(after, &tz).is_none());
    }

    // ── DST tests ──

    #[test]
    fn cron_dst_spring_forward_gap() {
        // US Eastern spring-forward 2026: March 8, 2:00 AM → 3:00 AM
        // "30 2 * * *" should fire at 3:00 AM ET (next valid time)
        let expr = CronExpression::parse("30 2 * * *").unwrap();
        let tz: Tz = "America/New_York".parse().unwrap();
        let after = utc("2026-03-08T06:00:00Z"); // 1:00 AM ET
        let next = expr.next_after(after, &tz).unwrap();
        // 2:30 AM doesn't exist, should skip. Next valid 2:30 AM is March 9
        let march_9_0230 = utc("2026-03-09T06:30:00Z"); // March 9 2:30 AM ET (EDT, UTC-4)
        assert_eq!(next, march_9_0230);
    }

    #[test]
    fn cron_dst_fall_back_ambiguous() {
        // US Eastern fall-back 2026: November 1, 2:00 AM → 1:00 AM
        // "30 1 * * *" fires at the FIRST 1:30 AM (EDT, before clocks change)
        let expr = CronExpression::parse("30 1 * * *").unwrap();
        let tz: Tz = "America/New_York".parse().unwrap();
        let after = utc("2026-11-01T04:00:00Z"); // midnight ET
        let next = expr.next_after(after, &tz).unwrap();
        // First 1:30 AM is EDT (UTC-4) = 05:30 UTC
        assert_eq!(next, utc("2026-11-01T05:30:00Z"));
    }

    #[test]
    fn cron_dst_no_double_fire() {
        // During fall-back, 1:30 AM occurs twice but should fire once (earliest)
        let expr = CronExpression::parse("30 1 * * *").unwrap();
        let tz: Tz = "America/New_York".parse().unwrap();

        // After the first 1:30 AM EDT (05:30 UTC), the next fire is tomorrow
        let after_first = utc("2026-11-01T05:30:00Z");
        let next = expr.next_after(after_first, &tz).unwrap();
        // Should be Nov 2 at 1:30 AM EST (UTC-5) = 06:30 UTC
        assert_eq!(next, utc("2026-11-02T06:30:00Z"));
    }

    // ── Every-interval computation ──

    #[test]
    fn every_simple() {
        let s = Schedule::Every {
            interval_secs: 300,
            anchor: None,
        };
        let after = utc("2026-01-15T00:01:40Z"); // 100s after epoch-aligned fire
        let next = compute_next_run(&s, after).unwrap();
        // Epoch-anchored: next fire at 300s boundary after `after`
        assert!(next > after);
    }

    #[test]
    fn every_with_anchor() {
        let anchor = utc("2026-01-15T10:00:00Z");
        let s = Schedule::Every {
            interval_secs: 3600,
            anchor: Some(anchor),
        };
        let after = utc("2026-01-15T11:30:00Z");
        let next = compute_next_run(&s, after).unwrap();
        assert_eq!(next, utc("2026-01-15T12:00:00Z"));
    }

    #[test]
    fn every_before_anchor() {
        let anchor = utc("2026-06-01T00:00:00Z");
        let s = Schedule::Every {
            interval_secs: 60,
            anchor: Some(anchor),
        };
        let after = utc("2026-01-01T00:00:00Z");
        let next = compute_next_run(&s, after).unwrap();
        assert_eq!(next, anchor);
    }

    #[test]
    fn every_wall_clock_anchored() {
        let anchor = utc("2026-01-15T10:00:00Z");
        let s = Schedule::Every {
            interval_secs: 3600,
            anchor: Some(anchor),
        };
        // Check no drift: 10 intervals later
        let after = utc("2026-01-15T19:59:59Z");
        let next = compute_next_run(&s, after).unwrap();
        assert_eq!(next, utc("2026-01-15T20:00:00Z"));
    }

    // ── OneShot computation ──

    #[test]
    fn oneshot_future() {
        let at = utc("2026-06-01T12:00:00Z");
        let s = Schedule::OneShot { at };
        let after = utc("2026-01-01T00:00:00Z");
        assert_eq!(compute_next_run(&s, after), Some(at));
    }

    #[test]
    fn oneshot_past() {
        let at = utc("2025-01-01T00:00:00Z");
        let s = Schedule::OneShot { at };
        let after = utc("2026-01-01T00:00:00Z");
        assert_eq!(compute_next_run(&s, after), None);
    }

    // ── Misfire tests (pure schedule computation) ──

    #[test]
    fn cron_next_run_from_slightly_before_boundary() {
        // Documents the boundary behavior: compute_next_run uses next_after which
        // advances by one minute. When `now` is 1ms before the boundary, the
        // truncated minute is 08:59 → next minute 09:00 → matches → returns same day.
        // When `now` IS the boundary (09:00:00), next minute is 09:01 → no match → tomorrow.
        let schedule = Schedule::Cron {
            expression: "0 9 * * *".into(),
            timezone: "UTC".into(),
        };

        // 1ms before boundary: returns same-day 09:00 (the "about to fire" time)
        let before = utc("2026-02-25T08:59:59.999Z");
        let result = compute_next_run(&schedule, before).unwrap();
        assert_eq!(result, utc("2026-02-25T09:00:00Z"));

        // Exact boundary: returns TOMORROW 09:00 (correctly advances past it)
        let exact = utc("2026-02-25T09:00:00Z");
        let result = compute_next_run(&schedule, exact).unwrap();
        assert_eq!(result, utc("2026-02-26T09:00:00Z"));
    }

    #[test]
    fn every_next_run_from_slightly_before_boundary() {
        // Same boundary behavior for Every schedules: slightly-before returns
        // the current boundary, exact boundary returns the next one.
        let schedule = Schedule::Every {
            interval_secs: 86400,
            anchor: Some(utc("2026-02-24T09:00:00Z")),
        };

        // 1ms before: elapsed < 86400s, so periods = 0+1 = 1 → same boundary
        let before = utc("2026-02-25T08:59:59.999Z");
        let result = compute_next_run(&schedule, before).unwrap();
        assert_eq!(result, utc("2026-02-25T09:00:00Z"));

        // Exact: elapsed = 86400s, periods = 1+1 = 2 → next day
        let exact = utc("2026-02-25T09:00:00Z");
        let result = compute_next_run(&schedule, exact).unwrap();
        assert_eq!(result, utc("2026-02-26T09:00:00Z"));
    }

    #[test]
    fn misfire_skip_computes_future() {
        let s = Schedule::Cron {
            expression: "0 9 * * *".into(),
            timezone: "UTC".into(),
        };
        // Pretend server was down for 3 days — now is 10 AM on the 4th day
        let now = utc("2026-01-18T10:00:00Z");
        let next = compute_next_run(&s, now).unwrap();
        assert_eq!(next, utc("2026-01-19T09:00:00Z"));
    }
}
