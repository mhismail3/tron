//! JSON configuration file management.
//!
//! The canonical job definitions live in `~/.tron/artifacts/automations.json`.
//! This module handles loading, saving (atomic writes), validation,
//! and file change detection.

use std::io::Write as _;
use std::path::Path;
use std::time::SystemTime;

use sha2::{Digest, Sha256};

use crate::errors::CronError;
use crate::schedule::CronExpression;
use crate::types::{CronConfig, CronJob, Payload, Schedule};

/// Load the cron config from a JSON file.
///
/// Returns `Ok(empty config)` if the file doesn't exist yet.
/// On parse failure, attempts recovery from the backup file.
pub fn load_config(path: &Path, backup_path: &Path) -> Result<CronConfig, CronError> {
    if !path.exists() {
        return Ok(CronConfig::default());
    }
    let content = std::fs::read_to_string(path)?;
    if content.trim().is_empty() {
        return Ok(CronConfig::default());
    }
    match serde_json::from_str::<CronConfig>(&content) {
        Ok(config) => Ok(config),
        Err(primary_err) => {
            // Primary file corrupt — try backup recovery
            if backup_path.exists() {
                tracing::warn!(
                    error = %primary_err,
                    "automations.json corrupt, attempting recovery from backup"
                );
                if let Ok(bak_content) = std::fs::read_to_string(backup_path) {
                    if let Ok(config) = serde_json::from_str::<CronConfig>(&bak_content) {
                        tracing::info!("recovered {} jobs from backup", config.jobs.len());
                        // Restore the primary file from backup
                        if let Err(e) = std::fs::copy(backup_path, path) {
                            tracing::warn!(error = %e, "failed to restore backup to primary");
                        }
                        return Ok(config);
                    }
                }
            }
            Err(primary_err.into())
        }
    }
}

/// Atomically write config to a JSON file.
///
/// Strategy: write .tmp → sync_all → backup existing → atomic rename.
pub fn save_config(path: &Path, backup_path: &Path, config: &CronConfig) -> Result<(), CronError> {
    // Reject symlinks
    if path.exists() {
        let meta = std::fs::symlink_metadata(path)?;
        if meta.file_type().is_symlink() {
            return Err(CronError::Config("refusing to write to symlink".into()));
        }
    }

    // Ensure parent directory exists
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)?;
    }

    let content = serde_json::to_string_pretty(config)?;

    // Write to .tmp
    let tmp = path.with_extension("json.tmp");
    let mut file = std::fs::File::create(&tmp)?;
    file.write_all(content.as_bytes())?;
    file.sync_all()?;

    // Backup existing file to deployment directory
    if path.exists() {
        if let Some(parent) = backup_path.parent() {
            std::fs::create_dir_all(parent)?;
        }
        let _ = std::fs::rename(path, backup_path);
    }

    // Atomic rename
    std::fs::rename(&tmp, path)?;
    Ok(())
}

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
            CronExpression::parse(expression)?;
            timezone
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
            if *timeout_secs > 3600 {
                return Err(CronError::Validation(
                    "shell timeout max is 3600s".into(),
                ));
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
            if *timeout_secs > 300 {
                return Err(CronError::Validation(
                    "webhook timeout max is 300s".into(),
                ));
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

/// Three-factor file change fingerprint.
///
/// Handles edge cases: NFS coarse mtime, multiple writes within one second,
/// file replaced without mtime change (some editors).
#[derive(Clone, Debug, PartialEq)]
pub struct FileFingerprint {
    /// File modification time.
    pub mtime: Option<SystemTime>,
    /// File size in bytes.
    pub size: u64,
    /// SHA-256 of the first 4KB.
    pub hash: [u8; 32],
}

impl FileFingerprint {
    /// Compute a fingerprint for the given path.
    ///
    /// Returns `None` if the file doesn't exist.
    pub fn compute(path: &Path) -> Option<Self> {
        let meta = std::fs::metadata(path).ok()?;
        let mtime = meta.modified().ok();
        let size = meta.len();

        let content = std::fs::read(path).ok()?;
        let to_hash = &content[..content.len().min(4096)];
        let hash: [u8; 32] = Sha256::digest(to_hash).into();

        Some(Self { mtime, size, hash })
    }
}

#[cfg(test)]
mod tests {
    use chrono::Utc;

    use super::*;
    use crate::types::*;

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
            prod_only: false,
            tags: vec![],
            workspace_id: None,
            created_at: Utc::now(),
            updated_at: Utc::now(),
        }
    }

    #[test]
    fn load_valid_config() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("automations.json");
        let bak = dir.path().join("automations.json.bak");
        let config = CronConfig {
            version: 1,
            jobs: vec![make_valid_job()],
        };
        save_config(&path, &bak, &config).unwrap();
        let loaded = load_config(&path, &bak).unwrap();
        assert_eq!(loaded.version, 1);
        assert_eq!(loaded.jobs.len(), 1);
    }

    #[test]
    fn load_empty_file() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("automations.json");
        let bak = dir.path().join("automations.json.bak");
        std::fs::write(&path, r#"{"version":1,"jobs":[]}"#).unwrap();
        let config = load_config(&path, &bak).unwrap();
        assert!(config.jobs.is_empty());
    }

    #[test]
    fn load_missing_file() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("nonexistent.json");
        let bak = dir.path().join("nonexistent.json.bak");
        let config = load_config(&path, &bak).unwrap();
        assert!(config.jobs.is_empty());
    }

    #[test]
    fn load_corrupt_json() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("automations.json");
        let bak = dir.path().join("automations.json.bak");
        std::fs::write(&path, "not valid json {{{").unwrap();
        assert!(load_config(&path, &bak).is_err());
    }

    #[test]
    fn load_unknown_fields_ignored() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("automations.json");
        let bak = dir.path().join("automations.json.bak");
        std::fs::write(
            &path,
            r#"{"version":1,"jobs":[],"futureField":"ignored"}"#,
        )
        .unwrap();
        let config = load_config(&path, &bak).unwrap();
        assert!(config.jobs.is_empty());
    }

    #[test]
    fn save_atomic_creates_file() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("new.json");
        let bak = dir.path().join("new.json.bak");
        assert!(!path.exists());
        save_config(&path, &bak, &CronConfig::default()).unwrap();
        assert!(path.exists());
    }

    #[test]
    fn save_atomic_preserves_on_error() {
        // If writing to tmp fails, original is preserved
        // (hard to simulate, so we test the backup mechanism instead)
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("automations.json");
        let bak = dir.path().join("automations.json.bak");

        let config1 = CronConfig {
            version: 1,
            jobs: vec![make_valid_job()],
        };
        save_config(&path, &bak, &config1).unwrap();

        let config2 = CronConfig::default();
        save_config(&path, &bak, &config2).unwrap();

        // Backup should exist
        assert!(bak.exists());
        let backup: CronConfig = serde_json::from_str(&std::fs::read_to_string(&bak).unwrap()).unwrap();
        assert_eq!(backup.jobs.len(), 1);
    }

    #[cfg(unix)]
    #[test]
    fn save_rejects_symlink() {
        use std::os::unix::fs::symlink;

        let dir = tempfile::tempdir().unwrap();
        let target = dir.path().join("real.json");
        std::fs::write(&target, "{}").unwrap();

        let link = dir.path().join("link.json");
        symlink(&target, &link).unwrap();

        let bak = dir.path().join("link.json.bak");
        let result = save_config(&link, &bak, &CronConfig::default());
        assert!(result.is_err());
        assert!(result.unwrap_err().to_string().contains("symlink"));
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
        job.name = "".into();
        assert!(validate_job(&job).is_err());
    }

    #[test]
    fn validate_job_empty_agent_prompt() {
        let mut job = make_valid_job();
        job.payload = Payload::AgentTurn {
            prompt: "".into(),
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
            session_id: "".into(),
            message: "hello".into(),
        };
        assert!(validate_job(&job).is_err());
    }

    #[test]
    fn file_fingerprint_detects_content_change() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("test.json");

        std::fs::write(&path, "content v1").unwrap();
        let fp1 = FileFingerprint::compute(&path).unwrap();

        std::fs::write(&path, "content v2").unwrap();
        let fp2 = FileFingerprint::compute(&path).unwrap();

        assert_ne!(fp1.hash, fp2.hash);
    }

    #[test]
    fn file_fingerprint_missing_file() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("missing.json");
        assert!(FileFingerprint::compute(&path).is_none());
    }

    #[test]
    fn load_corrupt_recovers_from_backup() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("automations.json");
        let bak = dir.path().join("automations.json.bak");

        // Write a valid backup
        let config = CronConfig {
            version: 1,
            jobs: vec![make_valid_job()],
        };
        let content = serde_json::to_string_pretty(&config).unwrap();
        std::fs::write(&bak, &content).unwrap();

        // Write corrupt primary
        std::fs::write(&path, "{{corrupt json!!!").unwrap();

        // Should recover from backup
        let loaded = load_config(&path, &bak).unwrap();
        assert_eq!(loaded.jobs.len(), 1);

        // Primary file should be restored
        let restored = std::fs::read_to_string(&path).unwrap();
        assert_eq!(restored, content);
    }

    #[test]
    fn load_corrupt_with_corrupt_backup_fails() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("automations.json");
        let bak = dir.path().join("automations.json.bak");

        // Both corrupt
        std::fs::write(&path, "corrupt primary").unwrap();
        std::fs::write(&bak, "corrupt backup").unwrap();

        assert!(load_config(&path, &bak).is_err());
    }

    #[test]
    fn load_corrupt_without_backup_fails() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("automations.json");
        let bak = dir.path().join("automations.json.bak");

        std::fs::write(&path, "corrupt json no backup").unwrap();

        assert!(load_config(&path, &bak).is_err());
    }
}
