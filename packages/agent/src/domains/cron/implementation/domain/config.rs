//! Cron job validation.
//!
//! Schedule truth is owned by decision resources. This module validates the
//! job payloads carried by those resources; it does not load or save separate
//! cron configuration files.

use crate::domains::cron::errors::CronError;
use crate::domains::cron::schedule::CronExpression;
use crate::domains::cron::types::{CronJob, Payload, Schedule};

/// Validate a job definition.
pub fn validate_job(job: &CronJob) -> Result<(), CronError> {
    if job.name.trim().is_empty() {
        return Err(CronError::Validation("job name must be non-empty".into()));
    }

    // Validate schedule
    match &job.schedule {
        Schedule::Cron {
            expression,
            timezone,
        } => {
            let _ = CronExpression::parse(expression)?;
            let _ = timezone
                .parse::<chrono_tz::Tz>()
                .map_err(|_| CronError::InvalidTimezone(timezone.clone()))?;
        }
        Schedule::Every { interval_secs, .. } => {
            if *interval_secs < 10 {
                return Err(CronError::Validation(
                    "interval must be >= 10 seconds".into(),
                ));
            }
        }
        Schedule::OneShot { .. } => {}
    }

    // Validate payload
    match &job.payload {
        Payload::ShellCommand {
            command,
            timeout_secs,
            ..
        } => {
            if command.trim().is_empty() {
                return Err(CronError::Validation(
                    "shell command must be non-empty".into(),
                ));
            }
            if *timeout_secs == 0 {
                return Err(CronError::Validation("shell timeout must be >= 1s".into()));
            }
            if *timeout_secs > 3600 {
                return Err(CronError::Validation("shell timeout max is 3600s".into()));
            }
        }
        Payload::Webhook {
            url,
            method,
            timeout_secs,
            ..
        } => {
            if url.parse::<reqwest::Url>().is_err() {
                return Err(CronError::Validation(format!("invalid URL: {url}")));
            }
            if !["GET", "POST", "PUT", "PATCH", "DELETE"].contains(&method.as_str()) {
                return Err(CronError::Validation(format!(
                    "invalid HTTP method: {method}"
                )));
            }
            if *timeout_secs == 0 {
                return Err(CronError::Validation(
                    "webhook timeout must be >= 1s".into(),
                ));
            }
            if *timeout_secs > 300 {
                return Err(CronError::Validation("webhook timeout max is 300s".into()));
            }
        }
        Payload::SystemEvent {
            session_id,
            message,
        } => {
            if session_id.trim().is_empty() || message.trim().is_empty() {
                return Err(CronError::Validation(
                    "session_id and message required".into(),
                ));
            }
        }
        Payload::AgentTurn { prompt, .. } => {
            if prompt.trim().is_empty() {
                return Err(CronError::Validation(
                    "agent turn prompt must be non-empty".into(),
                ));
            }
        }
    }

    Ok(())
}

#[cfg(test)]
mod tests {
    use chrono::Utc;

    use super::*;
    use crate::domains::cron::types::*;

    fn make_valid_job() -> CronJob {
        CronJob {
            id: "cron_test".into(),
            name: "Test".into(),
            description: None,
            enabled: true,
            schedule: Schedule::Every {
                interval_secs: 60,
                anchor: None,
            },
            payload: Payload::ShellCommand {
                command: "echo hi".into(),
                working_directory: None,
                timeout_secs: 300,
            },
            delivery: vec![],
            overlap_policy: OverlapPolicy::default(),
            misfire_policy: MisfirePolicy::default(),
            max_retries: 0,
            auto_disable_after: 0,
            stuck_timeout_secs: 7200,
            tags: vec![],
            capability_restrictions: None,
            workspace_id: None,
            created_at: Utc::now(),
            updated_at: Utc::now(),
        }
    }

    #[test]
    fn validate_job_valid() {
        validate_job(&make_valid_job()).unwrap();
    }

    #[test]
    fn validate_job_empty_command() {
        let mut job = make_valid_job();
        job.payload = Payload::ShellCommand {
            command: "  ".into(),
            working_directory: None,
            timeout_secs: 300,
        };
        assert!(validate_job(&job).is_err());
    }

    #[test]
    fn validate_job_invalid_url() {
        let mut job = make_valid_job();
        job.payload = Payload::Webhook {
            url: "not a url".into(),
            method: "POST".into(),
            headers: None,
            body: None,
            timeout_secs: 30,
        };
        assert!(validate_job(&job).is_err());
    }

    #[test]
    fn validate_job_invalid_tz() {
        let mut job = make_valid_job();
        job.schedule = Schedule::Cron {
            expression: "0 9 * * *".into(),
            timezone: "Bad/Zone".into(),
        };
        assert!(validate_job(&job).is_err());
    }

    #[test]
    fn validate_job_short_interval() {
        let mut job = make_valid_job();
        job.schedule = Schedule::Every {
            interval_secs: 5,
            anchor: None,
        };
        assert!(validate_job(&job).is_err());
    }

    #[test]
    fn validate_job_long_shell_timeout() {
        let mut job = make_valid_job();
        job.payload = Payload::ShellCommand {
            command: "echo hi".into(),
            working_directory: None,
            timeout_secs: 4000,
        };
        assert!(validate_job(&job).is_err());
    }

    #[test]
    fn validate_job_long_webhook_timeout() {
        let mut job = make_valid_job();
        job.payload = Payload::Webhook {
            url: "https://example.com".into(),
            method: "GET".into(),
            headers: None,
            body: None,
            timeout_secs: 500,
        };
        assert!(validate_job(&job).is_err());
    }

    #[test]
    fn validate_job_invalid_http_method() {
        let mut job = make_valid_job();
        job.payload = Payload::Webhook {
            url: "https://example.com".into(),
            method: "TRACE".into(),
            headers: None,
            body: None,
            timeout_secs: 30,
        };
        assert!(validate_job(&job).is_err());
    }

    #[test]
    fn validate_job_empty_name() {
        let mut job = make_valid_job();
        job.name = String::new();
        assert!(validate_job(&job).is_err());
    }

    #[test]
    fn validate_job_empty_agent_prompt() {
        let mut job = make_valid_job();
        job.payload = Payload::AgentTurn {
            prompt: String::new(),
            model: None,
            workspace_id: None,
            system_prompt: None,
        };
        assert!(validate_job(&job).is_err());
    }

    #[test]
    fn validate_job_empty_system_event() {
        let mut job = make_valid_job();
        job.payload = Payload::SystemEvent {
            session_id: String::new(),
            message: "hello".into(),
        };
        assert!(validate_job(&job).is_err());
    }

    // ── ModelCapability restrictions validation ─────────────────────────────────

    #[test]
    fn validate_job_capability_restrictions_allowed_only() {
        let mut job = make_valid_job();
        job.capability_restrictions = Some(CapabilityRestrictions {
            allowed_contracts: Some(vec!["filesystem::read_file".into()]),
        });
        validate_job(&job).unwrap();
    }

    #[test]
    fn validate_job_capability_restrictions_none() {
        let mut job = make_valid_job();
        job.capability_restrictions = None;
        validate_job(&job).unwrap();
    }

    #[test]
    fn validate_job_capability_restrictions_empty_list() {
        let mut job = make_valid_job();
        job.capability_restrictions = Some(CapabilityRestrictions {
            allowed_contracts: Some(vec![]),
        });
        validate_job(&job).unwrap();
    }

    // ── Zero-timeout validation ─────────────────────────────────

    #[test]
    fn validation_rejects_zero_timeout_shell() {
        let mut job = make_valid_job();
        job.payload = Payload::ShellCommand {
            command: "echo hi".into(),
            working_directory: None,
            timeout_secs: 0,
        };
        let result = validate_job(&job);
        assert!(result.is_err());
        assert!(result.unwrap_err().to_string().contains("must be >= 1s"));
    }

    #[test]
    fn validation_rejects_zero_timeout_webhook() {
        let mut job = make_valid_job();
        job.payload = Payload::Webhook {
            url: "https://example.com".into(),
            method: "POST".into(),
            headers: None,
            body: None,
            timeout_secs: 0,
        };
        let result = validate_job(&job);
        assert!(result.is_err());
        assert!(result.unwrap_err().to_string().contains("must be >= 1s"));
    }

    #[test]
    fn validation_accepts_minimum_timeout() {
        let mut job = make_valid_job();
        job.payload = Payload::ShellCommand {
            command: "echo hi".into(),
            working_directory: None,
            timeout_secs: 1,
        };
        assert!(validate_job(&job).is_ok());
    }
}
