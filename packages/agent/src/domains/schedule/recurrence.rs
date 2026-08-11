//! Bounded RFC 5545 recurrence validation and expansion.
//!
//! The `rrule` crate supplies the RFC algorithm and `chrono-tz` database. This
//! wrapper narrows its permissive iCalendar parser to Tron's scheduling
//! contract, canonicalizes inputs, rejects unsupported value forms, and places
//! a hard ceiling around every expansion.
//!
//! The RRULE value supports every standard RFC 5545 frequency and rule part:
//! `UNTIL`, `COUNT`, `INTERVAL`, `BYSECOND`, `BYMINUTE`, `BYHOUR`, `BYDAY`,
//! `BYMONTHDAY`, `BYYEARDAY`, `BYWEEKNO`, `BYMONTH`, `BYSETPOS`, and `WKST`.
//! Tron's closed contract intentionally rejects complete VCALENDAR/VEVENT
//! documents, multiple RRULEs, legacy RFC 2445 EXRULE, non-standard BYEASTER,
//! embedded VTIMEZONE definitions, DATE/PERIOD RDATE forms, floating values
//! without the separately required IANA zone, ambiguous/nonexistent local
//! instants, and leap-second `60` (Chrono represents seconds `0..=59`). Those
//! forms add parser or ambiguity surface without adding scheduling capability:
//! exclusions use EXDATE and extra instants use DATE-TIME RDATE.

use std::str::FromStr;

use chrono::{DateTime, NaiveDateTime, SecondsFormat, Utc};
use rrule::RRuleSet;
use thiserror::Error;

use super::contract::{
    MAX_CATCH_UP, MAX_EXPANSION_CANDIDATES, MAX_EXPLICIT_DATES, SchedulePolicy, ScheduleTiming,
};

const MAX_RRULE_BYTES: usize = 4_096;
const MAX_LOCAL_DATE_BYTES: usize = 19;
const MAX_TIME_ZONE_BYTES: usize = 128;
const MAX_BY_PART_VALUES: usize = 366;
const MAX_TOTAL_BY_VALUES: usize = 1_024;

/// Canonical timing plus its first future occurrence.
#[derive(Clone, Debug, PartialEq)]
pub(crate) struct ValidatedTiming {
    /// Canonical value safe to persist.
    pub(crate) timing: ScheduleTiming,
}

/// One bounded recurrence expansion over `(after, through]`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct Expansion {
    /// Due UTC instants in chronological order.
    pub(crate) due: Vec<DateTime<Utc>>,
    /// First occurrence after `through`, when one remains.
    pub(crate) next: Option<DateTime<Utc>>,
    /// Total recurrence candidates inspected, including candidates before the
    /// durable cursor.
    pub(crate) inspected: usize,
}

/// Rejected schedule timing.
#[derive(Debug, Error, PartialEq, Eq)]
pub(crate) enum RecurrenceError {
    /// A one-time instant was not offset-bearing RFC 3339.
    #[error("once.at must be an offset-bearing RFC 3339 instant: {0}")]
    InvalidOnce(String),
    /// A floating local value did not match the closed date-time form.
    #[error("{field} must use YYYY-MM-DDTHH:MM:SS without an offset: {value}")]
    InvalidLocalDateTime {
        /// Contract field.
        field: &'static str,
        /// Rejected value.
        value: String,
    },
    /// An RFC 5545/IANA parse or validation failure.
    #[error("invalid RFC 5545 recurrence: {0}")]
    InvalidRule(String),
    /// An operational bound was exceeded.
    #[error("recurrence exceeds bound: {0}")]
    BoundExceeded(String),
}

/// Validate and canonicalize a schedule timing contract.
pub(crate) fn validate_timing(timing: &ScheduleTiming) -> Result<ValidatedTiming, RecurrenceError> {
    match timing {
        ScheduleTiming::Once { at } => {
            let parsed = DateTime::parse_from_rfc3339(at)
                .map_err(|_| RecurrenceError::InvalidOnce(at.clone()))?;
            Ok(ValidatedTiming {
                timing: ScheduleTiming::Once {
                    at: utc_string(parsed.with_timezone(&Utc)),
                },
            })
        }
        ScheduleTiming::Recurring {
            start_local,
            time_zone,
            rrule,
            rdates,
            exdates,
        } => {
            validate_text_bounds(time_zone, rrule, rdates, exdates)?;
            let start_local = canonical_local("startLocal", start_local)?;
            let rdates = rdates
                .iter()
                .map(|value| canonical_local("rdates", value))
                .collect::<Result<Vec<_>, _>>()?;
            let exdates = exdates
                .iter()
                .map(|value| canonical_local("exdates", value))
                .collect::<Result<Vec<_>, _>>()?;
            let rule = normalize_rule(rrule)?;
            let set = parse_set(&start_local, time_zone, &rule, &rdates, &exdates)?;
            validate_rule_bounds(&set)?;
            Ok(ValidatedTiming {
                timing: ScheduleTiming::Recurring {
                    start_local,
                    time_zone: set.get_dt_start().timezone().name().to_owned(),
                    rrule: set.get_rrule()[0].to_string(),
                    rdates,
                    exdates,
                },
            })
        }
    }
}

/// Validate cross-field operational policy bounds.
pub(crate) fn validate_policy(policy: &SchedulePolicy) -> Result<(), RecurrenceError> {
    if policy.max_catch_up == 0 || policy.max_catch_up > MAX_CATCH_UP {
        return Err(RecurrenceError::BoundExceeded(format!(
            "policy.maxCatchUp must be between 1 and {MAX_CATCH_UP}"
        )));
    }
    Ok(())
}

/// Expand canonical timing over `(after, through]`, returning the first later
/// occurrence as a durable next-due hint.
pub(crate) fn expand_window(
    timing: &ScheduleTiming,
    after: DateTime<Utc>,
    through: DateTime<Utc>,
) -> Result<Expansion, RecurrenceError> {
    if through < after {
        return Err(RecurrenceError::InvalidRule(
            "expansion end precedes its exclusive cursor".to_owned(),
        ));
    }
    match timing {
        ScheduleTiming::Once { at } => {
            let at = DateTime::parse_from_rfc3339(at)
                .map_err(|_| RecurrenceError::InvalidOnce(at.clone()))?
                .with_timezone(&Utc);
            Ok(Expansion {
                due: (at > after && at <= through)
                    .then_some(at)
                    .into_iter()
                    .collect(),
                next: (at > through).then_some(at),
                inspected: 1,
            })
        }
        ScheduleTiming::Recurring {
            start_local,
            time_zone,
            rrule,
            rdates,
            exdates,
        } => {
            let set = parse_set(start_local, time_zone, rrule, rdates, exdates)?.limit();
            let mut due = Vec::new();
            let mut next = None;
            let mut inspected = 0_usize;
            for occurrence in &set {
                inspected += 1;
                if inspected > MAX_EXPANSION_CANDIDATES {
                    return Err(RecurrenceError::BoundExceeded(format!(
                        "more than {MAX_EXPANSION_CANDIDATES} candidates are required to reach the requested window"
                    )));
                }
                let occurrence = occurrence.with_timezone(&Utc);
                if occurrence <= after {
                    continue;
                }
                if occurrence <= through {
                    due.push(occurrence);
                    continue;
                }
                next = Some(occurrence);
                break;
            }
            Ok(Expansion {
                due,
                next,
                inspected,
            })
        }
    }
}

fn validate_text_bounds(
    time_zone: &str,
    rrule: &str,
    rdates: &[String],
    exdates: &[String],
) -> Result<(), RecurrenceError> {
    if time_zone.is_empty()
        || time_zone.len() > MAX_TIME_ZONE_BYTES
        || time_zone.contains(['\r', '\n'])
        || time_zone == "Local"
    {
        return Err(RecurrenceError::InvalidRule(
            "timeZone must be an explicit bounded IANA name".to_owned(),
        ));
    }
    if rrule.is_empty() || rrule.len() > MAX_RRULE_BYTES || rrule.contains(['\r', '\n']) {
        return Err(RecurrenceError::BoundExceeded(format!(
            "rrule must contain 1..={MAX_RRULE_BYTES} bytes and no line breaks"
        )));
    }
    if rdates.len() > MAX_EXPLICIT_DATES || exdates.len() > MAX_EXPLICIT_DATES {
        return Err(RecurrenceError::BoundExceeded(format!(
            "rdates and exdates each allow at most {MAX_EXPLICIT_DATES} values"
        )));
    }
    Ok(())
}

fn canonical_local(field: &'static str, value: &str) -> Result<String, RecurrenceError> {
    if value.len() != MAX_LOCAL_DATE_BYTES
        || value.as_bytes().get(4) != Some(&b'-')
        || value.as_bytes().get(7) != Some(&b'-')
        || value.as_bytes().get(10) != Some(&b'T')
        || value.as_bytes().get(13) != Some(&b':')
        || value.as_bytes().get(16) != Some(&b':')
    {
        return Err(RecurrenceError::InvalidLocalDateTime {
            field,
            value: value.to_owned(),
        });
    }
    let parsed = NaiveDateTime::parse_from_str(value, "%Y-%m-%dT%H:%M:%S").map_err(|_| {
        RecurrenceError::InvalidLocalDateTime {
            field,
            value: value.to_owned(),
        }
    })?;
    Ok(parsed.format("%Y-%m-%dT%H:%M:%S").to_string())
}

fn normalize_rule(value: &str) -> Result<String, RecurrenceError> {
    let rule = value.strip_prefix("RRULE:").unwrap_or(value);
    if rule.contains(':') || rule.contains(['\r', '\n']) {
        return Err(RecurrenceError::InvalidRule(
            "rrule accepts one rule value, not an iCalendar component".to_owned(),
        ));
    }
    if rule
        .split(';')
        .any(|part| part.trim_start().starts_with("BYEASTER="))
    {
        return Err(RecurrenceError::InvalidRule(
            "BYEASTER is non-standard and is not accepted".to_owned(),
        ));
    }
    Ok(rule.to_owned())
}

fn parse_set(
    start_local: &str,
    time_zone: &str,
    rrule: &str,
    rdates: &[String],
    exdates: &[String],
) -> Result<RRuleSet, RecurrenceError> {
    let local = |value: &str| value.replace(['-', ':'], "");
    let mut source = format!(
        "DTSTART;TZID={time_zone}:{}\nRRULE:{}",
        local(start_local),
        rrule.strip_prefix("RRULE:").unwrap_or(rrule)
    );
    if !rdates.is_empty() {
        source.push_str(&format!(
            "\nRDATE;TZID={time_zone}:{}",
            rdates
                .iter()
                .map(|value| local(value))
                .collect::<Vec<_>>()
                .join(",")
        ));
    }
    if !exdates.is_empty() {
        source.push_str(&format!(
            "\nEXDATE;TZID={time_zone}:{}",
            exdates
                .iter()
                .map(|value| local(value))
                .collect::<Vec<_>>()
                .join(",")
        ));
    }
    RRuleSet::from_str(&source).map_err(|error| RecurrenceError::InvalidRule(error.to_string()))
}

fn validate_rule_bounds(set: &RRuleSet) -> Result<(), RecurrenceError> {
    if set.get_rrule().len() != 1 {
        return Err(RecurrenceError::InvalidRule(
            "exactly one RRULE is required".to_owned(),
        ));
    }
    let rule = &set.get_rrule()[0];
    let lengths = [
        rule.get_by_set_pos().len(),
        rule.get_by_month().len(),
        rule.get_by_month_day().len(),
        rule.get_by_year_day().len(),
        rule.get_by_week_no().len(),
        rule.get_by_weekday().len(),
        rule.get_by_hour().len(),
        rule.get_by_minute().len(),
        rule.get_by_second().len(),
    ];
    if lengths.iter().any(|length| *length > MAX_BY_PART_VALUES) {
        return Err(RecurrenceError::BoundExceeded(format!(
            "each BY* part allows at most {MAX_BY_PART_VALUES} distinct values"
        )));
    }
    let total = lengths.into_iter().sum::<usize>();
    if total > MAX_TOTAL_BY_VALUES {
        return Err(RecurrenceError::BoundExceeded(format!(
            "all BY* parts together allow at most {MAX_TOTAL_BY_VALUES} values"
        )));
    }
    Ok(())
}

pub(crate) fn utc_string(value: DateTime<Utc>) -> String {
    value.to_rfc3339_opts(SecondsFormat::Nanos, true)
}
