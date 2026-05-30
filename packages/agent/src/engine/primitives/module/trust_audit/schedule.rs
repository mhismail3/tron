//! Trust-audit schedule parsing and due-bucket calculation.

use chrono::{Datelike, TimeZone, Timelike};
use serde_json::{Value, json};

use super::*;

const DEFAULT_RETENTION_REVIEW_DAYS: u64 = 90;

#[derive(Clone)]
pub(super) struct TrustAuditSchedule {
    pub(super) resource_id: String,
    pub(super) version_id: String,
    pub(super) lifecycle: String,
    pub(super) status: String,
    created_at: DateTime<Utc>,
    pub(super) selectors: Vec<String>,
    pub(super) scope_token: String,
    pub(super) cadence: String,
    pub(super) timezone_name: String,
    timezone: chrono_tz::Tz,
    pub(super) hour: u32,
    pub(super) minute: u32,
    pub(super) day_of_week: Option<u32>,
    pub(super) expires_at: DateTime<Utc>,
    pub(super) retention_review_after_days: u64,
}

impl TrustAuditSchedule {
    pub(super) fn from_inspection(inspection: &EngineResourceInspection) -> Result<Self> {
        let version_id = inspection
            .resource
            .current_version_id
            .clone()
            .ok_or_else(|| {
                EngineError::PolicyViolation(format!(
                    "trust audit schedule {} has no current version",
                    inspection.resource.resource_id
                ))
            })?;
        let payload = version_payload(inspection, &version_id)?;
        Self::from_payload(
            &inspection.resource.resource_id,
            &version_id,
            &inspection.resource.lifecycle,
            inspection.resource.created_at,
            &payload,
        )
    }

    pub(super) fn from_payload(
        resource_id: &str,
        version_id: &str,
        lifecycle: &str,
        created_at: DateTime<Utc>,
        payload: &Value,
    ) -> Result<Self> {
        let metadata = trust_decision_metadata(payload, "module_trust_audit_schedule")?;
        let cadence = required_map_str(metadata, "cadence")?.to_owned();
        if !matches!(cadence.as_str(), "daily" | "weekly") {
            return Err(EngineError::PolicyViolation(format!(
                "unsupported trust audit cadence {cadence}"
            )));
        }
        let timezone_name = required_map_str(metadata, "timezone")?.to_owned();
        let timezone = timezone_name.parse::<chrono_tz::Tz>().map_err(|_| {
            EngineError::PolicyViolation(format!("unsupported schedule timezone {timezone_name}"))
        })?;
        let (hour, minute) =
            parse_trust_audit_wall_clock_time(required_map_str(metadata, "wallClockTime")?)?;
        let day_of_week = if cadence == "weekly" {
            Some(trust_audit_day_of_week_number(required_map_str(
                metadata,
                "dayOfWeek",
            )?)?)
        } else {
            None
        };
        let retention_review_after_days = metadata
            .get("retentionPolicy")
            .map(|value| trust_audit_retention_review_days(Some(value)))
            .transpose()?
            .unwrap_or(DEFAULT_RETENTION_REVIEW_DAYS);
        Ok(Self {
            resource_id: resource_id.to_owned(),
            version_id: version_id.to_owned(),
            lifecycle: lifecycle.to_owned(),
            status: payload
                .get("status")
                .and_then(Value::as_str)
                .unwrap_or("unknown")
                .to_owned(),
            created_at,
            selectors: string_array_from(metadata.get("selectors"), "selectors")?,
            scope_token: required_map_str(metadata, "scopeToken")?.to_owned(),
            cadence,
            timezone_name,
            timezone,
            hour,
            minute,
            day_of_week,
            expires_at: parse_datetime(required_map_str(metadata, "expiresAt")?)?,
            retention_review_after_days,
        })
    }

    pub(super) fn current_due_bucket(&self, now: DateTime<Utc>) -> Option<String> {
        if self.lifecycle == "archived" || self.status != "active" || self.expires_at <= now {
            return None;
        }
        let local_now = now.with_timezone(&self.timezone);
        if local_now.hour() < self.hour
            || (local_now.hour() == self.hour && local_now.minute() < self.minute)
        {
            return None;
        }
        if self.cadence == "weekly"
            && self.day_of_week != Some(local_now.weekday().number_from_monday())
        {
            return None;
        }
        Some(self.bucket_for_local(local_now))
    }

    pub(super) fn missed_buckets(&self, now: DateTime<Utc>, limit: usize) -> Vec<String> {
        let Some(current) = self.current_due_bucket(now) else {
            return Vec::new();
        };
        let created_local = self.created_at.with_timezone(&self.timezone);
        let now_local = now.with_timezone(&self.timezone);
        let mut date = created_local.date_naive();
        let end_date = now_local.date_naive();
        let mut buckets = Vec::new();
        while date <= end_date {
            if let Some(candidate) = self
                .timezone
                .with_ymd_and_hms(
                    date.year(),
                    date.month(),
                    date.day(),
                    self.hour,
                    self.minute,
                    0,
                )
                .single()
            {
                let candidate_utc = candidate.with_timezone(&Utc);
                if candidate_utc > self.created_at
                    && candidate_utc < now
                    && (self.cadence == "daily"
                        || self.day_of_week == Some(candidate.weekday().number_from_monday()))
                {
                    let bucket = self.bucket_for_local(candidate);
                    if bucket != current {
                        buckets.push(bucket);
                    }
                }
            }
            date += ChronoDuration::days(1);
        }
        let keep_from = buckets.len().saturating_sub(limit);
        buckets.into_iter().skip(keep_from).collect()
    }

    fn bucket_for_local(&self, local: DateTime<chrono_tz::Tz>) -> String {
        match self.cadence.as_str() {
            "daily" => format!(
                "{}T{:02}:{:02}:{}",
                local.date_naive(),
                self.hour,
                self.minute,
                self.timezone_name
            ),
            "weekly" => format!(
                "{}-W{:02}-{}T{:02}:{:02}:{}",
                local.iso_week().year(),
                local.iso_week().week(),
                local.weekday().number_from_monday(),
                self.hour,
                self.minute,
                self.timezone_name
            ),
            _ => String::new(),
        }
    }
}

pub(in crate::engine) fn trust_audit_current_due_bucket(
    resource_id: &str,
    version_id: &str,
    lifecycle: &str,
    created_at: DateTime<Utc>,
    payload: &Value,
    now: DateTime<Utc>,
) -> Result<Option<String>> {
    Ok(
        TrustAuditSchedule::from_payload(resource_id, version_id, lifecycle, created_at, payload)?
            .current_due_bucket(now),
    )
}

pub(in crate::engine) fn trust_audit_schedule_resource_id(
    scope_token: &str,
    schedule_id: &str,
) -> String {
    format!("decision:module-trust-audit:{scope_token}:{schedule_id}")
}

pub(super) fn validate_schedule_token(label: &str, value: &str) -> Result<()> {
    if value.trim().is_empty()
        || value.len() > 64
        || !value
            .chars()
            .all(|ch| ch.is_ascii_alphanumeric() || matches!(ch, '_' | '-' | '.'))
    {
        return Err(EngineError::PolicyViolation(format!(
            "invalid {label} {value:?}"
        )));
    }
    Ok(())
}

pub(super) fn parse_trust_audit_wall_clock_time(value: &str) -> Result<(u32, u32)> {
    let Some((hour, minute)) = value.split_once(':') else {
        return Err(EngineError::PolicyViolation(
            "wallClockTime must use HH:MM".to_owned(),
        ));
    };
    let hour = hour.parse::<u32>().map_err(|_| {
        EngineError::PolicyViolation("wallClockTime hour must be numeric".to_owned())
    })?;
    let minute = minute.parse::<u32>().map_err(|_| {
        EngineError::PolicyViolation("wallClockTime minute must be numeric".to_owned())
    })?;
    if hour > 23 || minute > 59 {
        return Err(EngineError::PolicyViolation(
            "wallClockTime must be a valid 24-hour time".to_owned(),
        ));
    }
    Ok((hour, minute))
}

pub(super) fn trust_audit_day_of_week_number(value: &str) -> Result<u32> {
    match value {
        "monday" | "mon" | "1" => Ok(1),
        "tuesday" | "tue" | "2" => Ok(2),
        "wednesday" | "wed" | "3" => Ok(3),
        "thursday" | "thu" | "4" => Ok(4),
        "friday" | "fri" | "5" => Ok(5),
        "saturday" | "sat" | "6" => Ok(6),
        "sunday" | "sun" | "7" => Ok(7),
        other => Err(EngineError::PolicyViolation(format!(
            "unsupported dayOfWeek {other}"
        ))),
    }
}

pub(super) fn trust_audit_retention_policy(value: Option<&Value>) -> Result<Value> {
    Ok(json!({
        "reviewAfterDays": trust_audit_retention_review_days(value)?,
    }))
}

fn trust_audit_retention_review_days(value: Option<&Value>) -> Result<u64> {
    let Some(value) = value else {
        return Ok(DEFAULT_RETENTION_REVIEW_DAYS);
    };
    let object = value.as_object().ok_or_else(|| {
        EngineError::PolicyViolation("retentionPolicy must be an object".to_owned())
    })?;
    let review_after_days = object
        .get("reviewAfterDays")
        .and_then(Value::as_u64)
        .unwrap_or(DEFAULT_RETENTION_REVIEW_DAYS);
    if review_after_days > 3650 {
        return Err(EngineError::PolicyViolation(
            "retentionPolicy.reviewAfterDays is too large".to_owned(),
        ));
    }
    Ok(review_after_days)
}
