#![allow(unused_results)]
//! `SQLite` repository for cron jobs and runs.
//!
//! Handles CRUD operations, runtime state management, and garbage collection.
//! All operations use the shared `tron.db` connection pool.

use chrono::{DateTime, Utc};
use rusqlite::params;
use crate::events::ConnectionPool;

use crate::cron::errors::CronError;
use crate::cron::types::{CronJob, CronRun, DeliveryOutcome, JobRuntimeState, RunStatus};

/// Insert or update a job definition in `SQLite` (from config file sync).
pub fn upsert_job(pool: &ConnectionPool, job: &CronJob) -> Result<(), CronError> {
    let conn = pool.get()?;
    let schedule_json = serde_json::to_string(&job.schedule)?;
    let payload_json = serde_json::to_string(&job.payload)?;
    let delivery_json = serde_json::to_string(&job.delivery)?;
    let tags_json = serde_json::to_string(&job.tags)?;
    let tool_restrictions_json = job
        .tool_restrictions
        .as_ref()
        .map(serde_json::to_string)
        .transpose()?;
    let overlap = job.overlap_policy.as_sql();
    let misfire = job.misfire_policy.as_sql();

    conn.execute(
        "INSERT INTO cron_jobs (
            id, name, description, enabled, schedule_json, payload_json,
            delivery_json, overlap_policy, misfire_policy, max_retries,
            auto_disable_after, stuck_timeout_secs, tags, tool_restrictions_json,
            workspace_id, created_at, updated_at
        ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16, ?17)
        ON CONFLICT(id) DO UPDATE SET
            name = excluded.name,
            description = excluded.description,
            enabled = excluded.enabled,
            schedule_json = excluded.schedule_json,
            payload_json = excluded.payload_json,
            delivery_json = excluded.delivery_json,
            overlap_policy = excluded.overlap_policy,
            misfire_policy = excluded.misfire_policy,
            max_retries = excluded.max_retries,
            auto_disable_after = excluded.auto_disable_after,
            stuck_timeout_secs = excluded.stuck_timeout_secs,
            tags = excluded.tags,
            tool_restrictions_json = excluded.tool_restrictions_json,
            workspace_id = excluded.workspace_id,
            updated_at = excluded.updated_at",
        params![
            job.id,
            job.name,
            job.description,
            job.enabled,
            schedule_json,
            payload_json,
            delivery_json,
            overlap,
            misfire,
            job.max_retries,
            job.auto_disable_after,
            job.stuck_timeout_secs,
            tags_json,
            tool_restrictions_json,
            job.workspace_id,
            job.created_at.to_rfc3339(),
            job.updated_at.to_rfc3339(),
        ],
    )?;
    Ok(())
}

/// Get a job by ID.
pub fn get_job(pool: &ConnectionPool, job_id: &str) -> Result<Option<CronJob>, CronError> {
    let conn = pool.get()?;
    let mut stmt = conn.prepare(
        "SELECT id, name, description, enabled, schedule_json, payload_json,
                delivery_json, overlap_policy, misfire_policy, max_retries,
                auto_disable_after, stuck_timeout_secs, tags, workspace_id,
                created_at, updated_at, tool_restrictions_json
         FROM cron_jobs WHERE id = ?1",
    )?;
    let result = stmt.query_row(params![job_id], row_to_job);
    match result {
        Ok(job) => Ok(Some(job)),
        Err(rusqlite::Error::QueryReturnedNoRows) => Ok(None),
        Err(e) => Err(e.into()),
    }
}

/// List all job IDs in the database.
pub fn list_job_ids(pool: &ConnectionPool) -> Result<Vec<String>, CronError> {
    let conn = pool.get()?;
    let mut stmt = conn.prepare("SELECT id FROM cron_jobs")?;
    let ids = stmt
        .query_map([], |row| row.get(0))?
        .filter_map(Result::ok)
        .collect();
    Ok(ids)
}

/// List all jobs from the database (for `SQLite` fallback when config is corrupt).
pub fn list_all_jobs(pool: &ConnectionPool) -> Result<Vec<CronJob>, CronError> {
    let conn = pool.get()?;
    let mut stmt = conn.prepare(
        "SELECT id, name, description, enabled, schedule_json, payload_json,
                delivery_json, overlap_policy, misfire_policy, max_retries,
                auto_disable_after, stuck_timeout_secs, tags, workspace_id,
                created_at, updated_at, tool_restrictions_json
         FROM cron_jobs",
    )?;
    let jobs = stmt
        .query_map([], row_to_job)?
        .filter_map(Result::ok)
        .collect();
    Ok(jobs)
}

/// Delete a job by ID.
pub fn delete_job(pool: &ConnectionPool, job_id: &str) -> Result<bool, CronError> {
    let conn = pool.get()?;
    let affected = conn.execute("DELETE FROM cron_jobs WHERE id = ?1", params![job_id])?;
    Ok(affected > 0)
}

/// Check if a job name already exists (excluding the given `job_id`).
pub fn name_exists(
    pool: &ConnectionPool,
    name: &str,
    exclude_id: Option<&str>,
) -> Result<bool, CronError> {
    let conn = pool.get()?;
    let exists: bool = match exclude_id {
        Some(id) => conn.query_row(
            "SELECT EXISTS(SELECT 1 FROM cron_jobs WHERE name = ?1 AND id != ?2)",
            params![name, id],
            |row| row.get(0),
        )?,
        None => conn.query_row(
            "SELECT EXISTS(SELECT 1 FROM cron_jobs WHERE name = ?1)",
            params![name],
            |row| row.get(0),
        )?,
    };
    Ok(exists)
}

// ── Runtime state ──

/// Get runtime state for a job.
pub fn get_runtime_state(
    pool: &ConnectionPool,
    job_id: &str,
) -> Result<Option<JobRuntimeState>, CronError> {
    let conn = pool.get()?;
    let mut stmt = conn.prepare(
        "SELECT id, next_run_at, last_run_at, consecutive_failures, running_since
         FROM cron_jobs WHERE id = ?1",
    )?;
    let result = stmt.query_row(params![job_id], |row| {
        Ok(JobRuntimeState {
            job_id: row.get(0)?,
            next_run_at: parse_optional_datetime(row.get::<_, Option<String>>(1)?),
            last_run_at: parse_optional_datetime(row.get::<_, Option<String>>(2)?),
            consecutive_failures: row.get(3)?,
            running_since: parse_optional_datetime(row.get::<_, Option<String>>(4)?),
        })
    });
    match result {
        Ok(state) => Ok(Some(state)),
        Err(rusqlite::Error::QueryReturnedNoRows) => Ok(None),
        Err(e) => Err(e.into()),
    }
}

/// Update `next_run_at` for a job.
pub fn update_next_run_at(
    pool: &ConnectionPool,
    job_id: &str,
    next: Option<DateTime<Utc>>,
) -> Result<(), CronError> {
    let conn = pool.get()?;
    conn.execute(
        "UPDATE cron_jobs SET next_run_at = ?1 WHERE id = ?2",
        params![next.map(|t| t.to_rfc3339()), job_id],
    )?;
    Ok(())
}

/// Update `last_run_at` for a job.
pub fn update_last_run_at(
    pool: &ConnectionPool,
    job_id: &str,
    last: DateTime<Utc>,
) -> Result<(), CronError> {
    let conn = pool.get()?;
    conn.execute(
        "UPDATE cron_jobs SET last_run_at = ?1 WHERE id = ?2",
        params![last.to_rfc3339(), job_id],
    )?;
    Ok(())
}

/// Set `running_since` to mark a job as currently executing.
pub fn set_running_since(
    pool: &ConnectionPool,
    job_id: &str,
    since: DateTime<Utc>,
) -> Result<(), CronError> {
    let conn = pool.get()?;
    conn.execute(
        "UPDATE cron_jobs SET running_since = ?1 WHERE id = ?2",
        params![since.to_rfc3339(), job_id],
    )?;
    Ok(())
}

/// Clear `running_since` when execution finishes.
pub fn clear_running_since(pool: &ConnectionPool, job_id: &str) -> Result<(), CronError> {
    let conn = pool.get()?;
    conn.execute(
        "UPDATE cron_jobs SET running_since = NULL WHERE id = ?1",
        params![job_id],
    )?;
    Ok(())
}

/// Increment consecutive failures and return the new count.
pub fn increment_consecutive_failures(
    pool: &ConnectionPool,
    job_id: &str,
) -> Result<u32, CronError> {
    let conn = pool.get()?;
    conn.execute(
        "UPDATE cron_jobs SET consecutive_failures = consecutive_failures + 1 WHERE id = ?1",
        params![job_id],
    )?;
    let count: u32 = conn.query_row(
        "SELECT consecutive_failures FROM cron_jobs WHERE id = ?1",
        params![job_id],
        |row| row.get(0),
    )?;
    Ok(count)
}

/// Reset consecutive failures to zero.
pub fn reset_consecutive_failures(pool: &ConnectionPool, job_id: &str) -> Result<(), CronError> {
    let conn = pool.get()?;
    conn.execute(
        "UPDATE cron_jobs SET consecutive_failures = 0 WHERE id = ?1",
        params![job_id],
    )?;
    Ok(())
}

/// Disable a job.
pub fn disable_job(pool: &ConnectionPool, job_id: &str) -> Result<(), CronError> {
    let conn = pool.get()?;
    conn.execute(
        "UPDATE cron_jobs SET enabled = 0 WHERE id = ?1",
        params![job_id],
    )?;
    Ok(())
}

/// Check if a job is enabled.
pub fn is_job_enabled(pool: &ConnectionPool, job_id: &str) -> Result<bool, CronError> {
    let conn = pool.get()?;
    let enabled: bool = conn.query_row(
        "SELECT enabled FROM cron_jobs WHERE id = ?1",
        params![job_id],
        |row| row.get(0),
    )?;
    Ok(enabled)
}

// ── Runs ──

/// Insert a new run record.
pub fn insert_run(
    pool: &ConnectionPool,
    run_id: &str,
    job_id: &str,
    job_name: &str,
    started_at: DateTime<Utc>,
) -> Result<(), CronError> {
    let conn = pool.get()?;
    conn.execute(
        "INSERT INTO cron_runs (id, job_id, job_name, status, started_at)
         VALUES (?1, ?2, ?3, 'running', ?4)",
        params![run_id, job_id, job_name, started_at.to_rfc3339()],
    )?;
    Ok(())
}

/// Complete a run record with the final status.
pub fn complete_run(pool: &ConnectionPool, run: &CronRun) -> Result<(), CronError> {
    let conn = pool.get()?;
    conn.execute(
        "UPDATE cron_runs SET
            status = ?1, completed_at = ?2, duration_ms = ?3,
            output = ?4, output_truncated = ?5, error = ?6,
            exit_code = ?7, attempt = ?8, session_id = ?9
         WHERE id = ?10",
        params![
            run.status.as_str(),
            run.completed_at.map(|t| t.to_rfc3339()),
            run.duration_ms,
            run.output,
            run.output_truncated,
            run.error,
            run.exit_code,
            run.attempt,
            run.session_id,
            run.id,
        ],
    )?;
    Ok(())
}

/// Get paginated runs for a job.
pub fn get_runs(
    pool: &ConnectionPool,
    job_id: Option<&str>,
    status: Option<&str>,
    limit: u32,
    offset: u32,
) -> Result<(Vec<CronRun>, u32), CronError> {
    let conn = pool.get()?;

    let (where_clause, count_params, query_params) =
        build_run_filters(job_id, status, limit, offset);

    let total: u32 = conn.query_row(
        &format!("SELECT COUNT(*) FROM cron_runs{where_clause}"),
        rusqlite::params_from_iter(count_params.iter()),
        |row| row.get(0),
    )?;

    let mut stmt = conn.prepare(&format!(
        "SELECT id, job_id, job_name, status, started_at, completed_at,
                duration_ms, output, output_truncated, error, exit_code,
                attempt, session_id, delivery_status
         FROM cron_runs{where_clause}
         ORDER BY started_at DESC
         LIMIT ?{} OFFSET ?{}",
        query_params.len() - 1,
        query_params.len(),
    ))?;

    let runs = stmt
        .query_map(rusqlite::params_from_iter(query_params.iter()), row_to_run)?
        .filter_map(Result::ok)
        .collect();

    Ok((runs, total))
}

/// Count running runs for a job (for overlap check).
pub fn count_running_runs(pool: &ConnectionPool, job_id: &str) -> Result<u32, CronError> {
    let conn = pool.get()?;
    let count: u32 = conn.query_row(
        "SELECT COUNT(*) FROM cron_runs WHERE job_id = ?1 AND status = 'running'",
        params![job_id],
        |row| row.get(0),
    )?;
    Ok(count)
}

/// Update delivery status on a run.
pub fn update_delivery_status(
    pool: &ConnectionPool,
    run_id: &str,
    status: &DeliveryOutcome,
) -> Result<(), CronError> {
    let conn = pool.get()?;
    conn.execute(
        "UPDATE cron_runs SET delivery_status = ?1 WHERE id = ?2",
        params![status.as_str(), run_id],
    )?;
    Ok(())
}

/// Get all jobs with a `running_since` value (for stuck detection).
pub fn get_stuck_candidates(
    pool: &ConnectionPool,
) -> Result<Vec<(String, DateTime<Utc>, u64)>, CronError> {
    let conn = pool.get()?;
    let mut stmt = conn.prepare(
        "SELECT id, running_since, stuck_timeout_secs FROM cron_jobs WHERE running_since IS NOT NULL",
    )?;
    let results = stmt
        .query_map([], |row| {
            let id: String = row.get(0)?;
            let since_str: String = row.get(1)?;
            let timeout: u64 = row.get(2)?;
            Ok((id, since_str, timeout))
        })?
        .filter_map(|r| {
            let (id, since_str, timeout) = r.ok()?;
            let since = DateTime::parse_from_rfc3339(&since_str).ok()?.to_utc();
            Some((id, since, timeout))
        })
        .collect();
    Ok(results)
}

/// Complete all orphaned `running` runs (bulk cleanup on startup).
///
/// On startup, nothing is actually running — any `running` record is
/// orphaned from a previous server instance.
pub fn complete_orphaned_runs(
    pool: &ConnectionPool,
    completed_at: DateTime<Utc>,
    error: &str,
) -> Result<u32, CronError> {
    let conn = pool.get()?;
    let affected = conn.execute(
        "UPDATE cron_runs SET status = 'failed', completed_at = ?1, error = ?2 WHERE status = 'running'",
        params![completed_at.to_rfc3339(), error],
    )?;
    Ok(affected as u32)
}

/// Complete stuck `running` runs for a specific job.
///
/// Used by the stuck detector to update the original run record(s)
/// instead of creating a duplicate.
pub fn complete_stuck_runs(
    pool: &ConnectionPool,
    job_id: &str,
    completed_at: DateTime<Utc>,
    error: &str,
) -> Result<u32, CronError> {
    let conn = pool.get()?;
    let affected = conn.execute(
        "UPDATE cron_runs SET status = 'timed_out', completed_at = ?1, error = ?2 WHERE job_id = ?3 AND status = 'running'",
        params![completed_at.to_rfc3339(), error, job_id],
    )?;
    Ok(affected as u32)
}

// ── Garbage collection ──

/// Delete old runs (older than `cutoff`), keeping at least `min_per_job` per job.
pub fn gc_old_runs(
    pool: &ConnectionPool,
    cutoff: DateTime<Utc>,
    min_per_job: u32,
) -> Result<u32, CronError> {
    let conn = pool.get()?;
    let cutoff_str = cutoff.to_rfc3339();

    // Delete runs older than cutoff that aren't in the most recent N per job
    let deleted = conn.execute(
        &format!(
            "DELETE FROM cron_runs WHERE created_at < ?1
             AND id NOT IN (
                 SELECT id FROM (
                     SELECT id, job_id,
                            ROW_NUMBER() OVER (PARTITION BY job_id ORDER BY created_at DESC) as rn
                     FROM cron_runs
                 ) WHERE rn <= {min_per_job}
             )"
        ),
        params![cutoff_str],
    )?;
    Ok(deleted as u32)
}

// ── Sync helpers ──

/// Sync config file jobs into `SQLite`. Returns (added, updated, removed) counts.
pub fn sync_from_config(
    pool: &ConnectionPool,
    jobs: &[CronJob],
) -> Result<(u32, u32, u32), CronError> {
    let existing_ids = list_job_ids(pool)?;
    let config_ids: std::collections::HashSet<&str> = jobs.iter().map(|j| j.id.as_str()).collect();

    let mut added = 0u32;
    let mut updated = 0u32;
    let mut removed = 0u32;

    // Upsert all jobs from config
    for job in jobs {
        if existing_ids.contains(&job.id) {
            updated += 1;
        } else {
            added += 1;
        }
        upsert_job(pool, job)?;
    }

    // Remove jobs in DB but not in config
    for id in &existing_ids {
        if !config_ids.contains(id.as_str()) {
            delete_job(pool, id)?;
            removed += 1;
        }
    }

    Ok((added, updated, removed))
}

// ── Internal helpers ──

fn row_to_job(row: &rusqlite::Row<'_>) -> rusqlite::Result<CronJob> {
    let id: String = row.get(0)?;
    let schedule_json: String = row.get(4)?;
    let payload_json: String = row.get(5)?;
    let delivery_json: String = row.get(6)?;
    let overlap_str: String = row.get(7)?;
    let misfire_str: String = row.get(8)?;
    let tags_json: String = row.get(12)?;
    let created_str: String = row.get(14)?;
    let updated_str: String = row.get(15)?;
    let tool_restrictions_json: Option<String> = row.get(16)?;

    Ok(CronJob {
        name: row.get(1)?,
        description: row.get(2)?,
        enabled: row.get(3)?,
        schedule: serde_json::from_str(&schedule_json).unwrap_or_else(|e| {
            tracing::warn!(error = %e, job_id = %id, "corrupt schedule_json in DB, using default");
            crate::cron::types::Schedule::Every { interval_secs: 60, anchor: None }
        }),
        payload: serde_json::from_str(&payload_json).unwrap_or_else(|e| {
            tracing::warn!(error = %e, job_id = %id, "corrupt payload_json in DB, using default");
            crate::cron::types::Payload::ShellCommand { command: "true".into(), working_directory: None, timeout_secs: 300 }
        }),
        delivery: serde_json::from_str(&delivery_json).unwrap_or_else(|e| {
            tracing::warn!(error = %e, job_id = %id, "corrupt delivery_json in DB, using default");
            Vec::new()
        }),
        overlap_policy: crate::cron::types::OverlapPolicy::from_sql(&overlap_str),
        misfire_policy: crate::cron::types::MisfirePolicy::from_sql(&misfire_str),
        max_retries: row.get(9)?,
        auto_disable_after: row.get(10)?,
        stuck_timeout_secs: row.get(11)?,
        tags: serde_json::from_str(&tags_json).unwrap_or_else(|e| {
            tracing::warn!(error = %e, job_id = %id, "corrupt tags_json in DB, using default");
            Vec::new()
        }),
        tool_restrictions: tool_restrictions_json.and_then(|s| {
            serde_json::from_str(&s).unwrap_or_else(|e| {
                tracing::warn!(error = %e, job_id = %id, "corrupt tool_restrictions_json in DB, ignoring");
                None
            })
        }),
        workspace_id: row.get(13)?,
        created_at: DateTime::parse_from_rfc3339(&created_str).map_or_else(
            |e| {
                tracing::warn!(error = %e, job_id = %id, "corrupt created_at in DB, using now");
                Utc::now()
            },
            |t| t.to_utc(),
        ),
        updated_at: DateTime::parse_from_rfc3339(&updated_str).map_or_else(
            |e| {
                tracing::warn!(error = %e, job_id = %id, "corrupt updated_at in DB, using now");
                Utc::now()
            },
            |t| t.to_utc(),
        ),
        id,
    })
}

fn row_to_run(row: &rusqlite::Row<'_>) -> rusqlite::Result<CronRun> {
    let id: String = row.get(0)?;
    let status_str: String = row.get(3)?;
    let started_str: String = row.get(4)?;
    let completed_str: Option<String> = row.get(5)?;

    Ok(CronRun {
        job_id: row.get(1)?,
        job_name: row.get(2)?,
        status: RunStatus::parse(&status_str).unwrap_or_else(|| {
            tracing::warn!(status = %status_str, run_id = %id, "unknown RunStatus in DB");
            RunStatus::Failed
        }),
        started_at: DateTime::parse_from_rfc3339(&started_str).map_or_else(
            |e| {
                tracing::warn!(error = %e, run_id = %id, "corrupt started_at in DB, using now");
                Utc::now()
            },
            |t| t.to_utc(),
        ),
        completed_at: completed_str
            .and_then(|s| DateTime::parse_from_rfc3339(&s).ok().map(|t| t.to_utc())),
        duration_ms: row.get(6)?,
        output: row.get(7)?,
        output_truncated: row.get(8)?,
        error: row.get(9)?,
        exit_code: row.get(10)?,
        attempt: row.get(11)?,
        session_id: row.get(12)?,
        delivery_status: row
            .get::<_, Option<String>>(13)?
            .map(|s| DeliveryOutcome::from_sql(&s)),
        id,
    })
}

fn parse_optional_datetime(s: Option<String>) -> Option<DateTime<Utc>> {
    s.and_then(|s| DateTime::parse_from_rfc3339(&s).ok().map(|t| t.to_utc()))
}

fn build_run_filters(
    job_id: Option<&str>,
    status: Option<&str>,
    limit: u32,
    offset: u32,
) -> (String, Vec<String>, Vec<String>) {
    let mut conditions = Vec::new();
    let mut count_params = Vec::new();

    if let Some(jid) = job_id {
        conditions.push(format!(" job_id = ?{}", count_params.len() + 1));
        count_params.push(jid.to_string());
    }
    if let Some(st) = status {
        conditions.push(format!(" status = ?{}", count_params.len() + 1));
        count_params.push(st.to_string());
    }

    let where_clause = if conditions.is_empty() {
        String::new()
    } else {
        format!(" WHERE{}", conditions.join(" AND"))
    };

    let mut query_params = count_params.clone();
    query_params.push(limit.to_string());
    query_params.push(offset.to_string());

    (where_clause, count_params, query_params)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::cron::migrations;
    use crate::cron::types::*;

    fn setup_pool() -> ConnectionPool {
        let pool = crate::events::new_in_memory(&crate::events::ConnectionConfig::default()).unwrap();
        {
            let conn = pool.get().unwrap();
            conn.execute_batch("PRAGMA foreign_keys = ON;").unwrap();
            migrations::run_migrations(&conn).unwrap();
        }
        pool
    }

    fn make_job(id: &str, name: &str) -> CronJob {
        CronJob {
            id: id.into(),
            name: name.into(),
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
            tags: vec!["test".into()],
            tool_restrictions: None,
            workspace_id: None,
            created_at: Utc::now(),
            updated_at: Utc::now(),
        }
    }

    #[test]
    fn insert_and_get_job() {
        let pool = setup_pool();
        let job = make_job("cron_1", "Test Job");
        upsert_job(&pool, &job).unwrap();

        let loaded = get_job(&pool, "cron_1").unwrap().unwrap();
        assert_eq!(loaded.id, "cron_1");
        assert_eq!(loaded.name, "Test Job");
        assert!(loaded.enabled);
    }

    #[test]
    fn get_nonexistent_job() {
        let pool = setup_pool();
        assert!(get_job(&pool, "nope").unwrap().is_none());
    }

    #[test]
    fn update_job_definition() {
        let pool = setup_pool();
        let mut job = make_job("cron_1", "Original");
        upsert_job(&pool, &job).unwrap();

        job.name = "Updated".into();
        job.max_retries = 3;
        upsert_job(&pool, &job).unwrap();

        let loaded = get_job(&pool, "cron_1").unwrap().unwrap();
        assert_eq!(loaded.name, "Updated");
        assert_eq!(loaded.max_retries, 3);
    }

    #[test]
    fn update_runtime_state() {
        let pool = setup_pool();
        let job = make_job("cron_1", "Test");
        upsert_job(&pool, &job).unwrap();

        let now = Utc::now();
        update_next_run_at(&pool, "cron_1", Some(now)).unwrap();
        update_last_run_at(&pool, "cron_1", now).unwrap();

        let state = get_runtime_state(&pool, "cron_1").unwrap().unwrap();
        assert!(state.next_run_at.is_some());
        assert!(state.last_run_at.is_some());
        assert_eq!(state.consecutive_failures, 0);
    }

    #[test]
    fn delete_job_preserves_runs() {
        let pool = setup_pool();
        let job = make_job("cron_1", "Test");
        upsert_job(&pool, &job).unwrap();

        insert_run(&pool, "run_1", "cron_1", "Test", Utc::now()).unwrap();
        delete_job(&pool, "cron_1").unwrap();

        // Run should still exist with NULL job_id
        let (runs, total) = get_runs(&pool, None, None, 10, 0).unwrap();
        assert_eq!(total, 1);
        assert!(runs[0].job_id.is_none());
        assert_eq!(runs[0].job_name, "Test");
    }

    #[test]
    fn insert_and_complete_run() {
        let pool = setup_pool();
        let job = make_job("cron_1", "Test");
        upsert_job(&pool, &job).unwrap();

        let now = Utc::now();
        insert_run(&pool, "run_1", "cron_1", "Test", now).unwrap();

        let run = CronRun {
            id: "run_1".into(),
            job_id: Some("cron_1".into()),
            job_name: "Test".into(),
            status: RunStatus::Completed,
            started_at: now,
            completed_at: Some(Utc::now()),
            duration_ms: Some(1500),
            output: Some("hello".into()),
            output_truncated: false,
            error: None,
            exit_code: Some(0),
            attempt: 0,
            session_id: None,
            delivery_status: None,
        };
        complete_run(&pool, &run).unwrap();

        let (runs, _) = get_runs(&pool, Some("cron_1"), None, 10, 0).unwrap();
        assert_eq!(runs.len(), 1);
        assert_eq!(runs[0].status, RunStatus::Completed);
        assert_eq!(runs[0].output.as_deref(), Some("hello"));
    }

    #[test]
    fn get_runs_paginated() {
        let pool = setup_pool();
        let job = make_job("cron_1", "Test");
        upsert_job(&pool, &job).unwrap();

        for i in 0..5 {
            insert_run(&pool, &format!("run_{i}"), "cron_1", "Test", Utc::now()).unwrap();
        }

        let (runs, total) = get_runs(&pool, Some("cron_1"), None, 2, 0).unwrap();
        assert_eq!(total, 5);
        assert_eq!(runs.len(), 2);

        let (runs2, _) = get_runs(&pool, Some("cron_1"), None, 2, 2).unwrap();
        assert_eq!(runs2.len(), 2);
    }

    #[test]
    fn count_running_runs_test() {
        let pool = setup_pool();
        let job = make_job("cron_1", "Test");
        upsert_job(&pool, &job).unwrap();

        insert_run(&pool, "run_1", "cron_1", "Test", Utc::now()).unwrap();
        assert_eq!(count_running_runs(&pool, "cron_1").unwrap(), 1);

        let run = CronRun {
            id: "run_1".into(),
            job_id: Some("cron_1".into()),
            job_name: "Test".into(),
            status: RunStatus::Completed,
            started_at: Utc::now(),
            completed_at: Some(Utc::now()),
            duration_ms: None,
            output: None,
            output_truncated: false,
            error: None,
            exit_code: None,
            attempt: 0,
            session_id: None,
            delivery_status: None,
        };
        complete_run(&pool, &run).unwrap();
        assert_eq!(count_running_runs(&pool, "cron_1").unwrap(), 0);
    }

    #[test]
    fn consecutive_failures_increment_and_reset() {
        let pool = setup_pool();
        let job = make_job("cron_1", "Test");
        upsert_job(&pool, &job).unwrap();

        assert_eq!(increment_consecutive_failures(&pool, "cron_1").unwrap(), 1);
        assert_eq!(increment_consecutive_failures(&pool, "cron_1").unwrap(), 2);
        assert_eq!(increment_consecutive_failures(&pool, "cron_1").unwrap(), 3);

        reset_consecutive_failures(&pool, "cron_1").unwrap();
        let state = get_runtime_state(&pool, "cron_1").unwrap().unwrap();
        assert_eq!(state.consecutive_failures, 0);
    }

    #[test]
    fn name_exists_check() {
        let pool = setup_pool();
        let job = make_job("cron_1", "Daily");
        upsert_job(&pool, &job).unwrap();

        assert!(name_exists(&pool, "Daily", None).unwrap());
        assert!(!name_exists(&pool, "Daily", Some("cron_1")).unwrap());
        assert!(!name_exists(&pool, "Other", None).unwrap());
    }

    #[test]
    fn gc_deletes_old_runs() {
        let pool = setup_pool();
        let job = make_job("cron_1", "Test");
        upsert_job(&pool, &job).unwrap();

        // Insert runs with explicit old timestamps
        let conn = pool.get().unwrap();
        for i in 0..5 {
            conn.execute(
                "INSERT INTO cron_runs (id, job_id, job_name, status, started_at, created_at)
                 VALUES (?1, 'cron_1', 'Test', 'completed', ?2, ?2)",
                params![format!("old_{i}"), "2025-01-01T00:00:00+00:00",],
            )
            .unwrap();
        }
        drop(conn);

        // Insert 2 recent runs
        insert_run(&pool, "new_1", "cron_1", "Test", Utc::now()).unwrap();
        insert_run(&pool, "new_2", "cron_1", "Test", Utc::now()).unwrap();

        let cutoff = Utc::now() - chrono::Duration::days(1);
        let deleted = gc_old_runs(&pool, cutoff, 100).unwrap();
        // All 5 old runs should be kept (min 100 per job)
        assert_eq!(deleted, 0);

        let deleted = gc_old_runs(&pool, cutoff, 2).unwrap();
        // Should delete 5 old runs (keeping 2 most recent)
        assert_eq!(deleted, 5);
    }

    #[test]
    fn sync_from_config_adds_new_jobs() {
        let pool = setup_pool();
        let jobs = vec![make_job("cron_1", "Job 1"), make_job("cron_2", "Job 2")];
        let (added, updated, removed) = sync_from_config(&pool, &jobs).unwrap();
        assert_eq!(added, 2);
        assert_eq!(updated, 0);
        assert_eq!(removed, 0);
    }

    #[test]
    fn sync_from_config_updates_changed_jobs() {
        let pool = setup_pool();
        let jobs = vec![make_job("cron_1", "Job 1")];
        sync_from_config(&pool, &jobs).unwrap();

        let mut updated_jobs = vec![make_job("cron_1", "Updated Job 1")];
        updated_jobs[0].max_retries = 5;
        let (added, updated, removed) = sync_from_config(&pool, &updated_jobs).unwrap();
        assert_eq!(added, 0);
        assert_eq!(updated, 1);
        assert_eq!(removed, 0);

        let loaded = get_job(&pool, "cron_1").unwrap().unwrap();
        assert_eq!(loaded.name, "Updated Job 1");
        assert_eq!(loaded.max_retries, 5);
    }

    #[test]
    fn sync_from_config_removes_deleted_jobs() {
        let pool = setup_pool();
        let jobs = vec![make_job("cron_1", "Job 1"), make_job("cron_2", "Job 2")];
        sync_from_config(&pool, &jobs).unwrap();

        // Sync with only job 1
        let (_, _, removed) = sync_from_config(&pool, &jobs[..1]).unwrap();
        assert_eq!(removed, 1);
        assert!(get_job(&pool, "cron_2").unwrap().is_none());
    }

    #[test]
    fn complete_orphaned_runs_updates_all() {
        let pool = setup_pool();
        let job_a = make_job("cron_a", "Job A");
        let job_b = make_job("cron_b", "Job B");
        upsert_job(&pool, &job_a).unwrap();
        upsert_job(&pool, &job_b).unwrap();

        insert_run(&pool, "run_1", "cron_a", "Job A", Utc::now()).unwrap();
        insert_run(&pool, "run_2", "cron_a", "Job A", Utc::now()).unwrap();
        insert_run(&pool, "run_3", "cron_b", "Job B", Utc::now()).unwrap();

        let now = Utc::now();
        let updated = complete_orphaned_runs(&pool, now, "server restarted").unwrap();
        assert_eq!(updated, 3);

        let (runs, _) = get_runs(&pool, None, Some("running"), 10, 0).unwrap();
        assert_eq!(runs.len(), 0);

        let (runs, _) = get_runs(&pool, None, Some("failed"), 10, 0).unwrap();
        assert_eq!(runs.len(), 3);
        for r in &runs {
            assert_eq!(r.error.as_deref(), Some("server restarted"));
            assert!(r.completed_at.is_some());
        }
    }

    #[test]
    fn complete_orphaned_runs_ignores_non_running() {
        let pool = setup_pool();
        let job = make_job("cron_1", "Test");
        upsert_job(&pool, &job).unwrap();

        // One running
        insert_run(&pool, "run_1", "cron_1", "Test", Utc::now()).unwrap();
        // One completed
        insert_run(&pool, "run_2", "cron_1", "Test", Utc::now()).unwrap();
        complete_run(
            &pool,
            &CronRun {
                id: "run_2".into(),
                job_id: Some("cron_1".into()),
                job_name: "Test".into(),
                status: RunStatus::Completed,
                started_at: Utc::now(),
                completed_at: Some(Utc::now()),
                duration_ms: None,
                output: None,
                output_truncated: false,
                error: None,
                exit_code: Some(0),
                attempt: 0,
                session_id: None,
                delivery_status: None,
            },
        )
        .unwrap();
        // One failed
        insert_run(&pool, "run_3", "cron_1", "Test", Utc::now()).unwrap();
        complete_run(
            &pool,
            &CronRun {
                id: "run_3".into(),
                job_id: Some("cron_1".into()),
                job_name: "Test".into(),
                status: RunStatus::Failed,
                started_at: Utc::now(),
                completed_at: Some(Utc::now()),
                duration_ms: None,
                output: None,
                output_truncated: false,
                error: Some("boom".into()),
                exit_code: Some(1),
                attempt: 0,
                session_id: None,
                delivery_status: None,
            },
        )
        .unwrap();

        let updated = complete_orphaned_runs(&pool, Utc::now(), "server restarted").unwrap();
        assert_eq!(updated, 1);
    }

    #[test]
    fn complete_orphaned_runs_empty() {
        let pool = setup_pool();
        let updated = complete_orphaned_runs(&pool, Utc::now(), "server restarted").unwrap();
        assert_eq!(updated, 0);
    }

    #[test]
    fn complete_stuck_runs_targets_job() {
        let pool = setup_pool();
        let job_a = make_job("cron_a", "Job A");
        let job_b = make_job("cron_b", "Job B");
        upsert_job(&pool, &job_a).unwrap();
        upsert_job(&pool, &job_b).unwrap();

        insert_run(&pool, "run_a", "cron_a", "Job A", Utc::now()).unwrap();
        insert_run(&pool, "run_b", "cron_b", "Job B", Utc::now()).unwrap();

        let updated = complete_stuck_runs(&pool, "cron_a", Utc::now(), "stuck").unwrap();
        assert_eq!(updated, 1);

        // Job A's run is timed_out
        assert_eq!(count_running_runs(&pool, "cron_a").unwrap(), 0);
        // Job B's run still running
        assert_eq!(count_running_runs(&pool, "cron_b").unwrap(), 1);
    }

    #[test]
    fn complete_stuck_runs_sets_timed_out() {
        let pool = setup_pool();
        let job = make_job("cron_1", "Test");
        upsert_job(&pool, &job).unwrap();

        insert_run(&pool, "run_1", "cron_1", "Test", Utc::now()).unwrap();
        let now = Utc::now();
        complete_stuck_runs(&pool, "cron_1", now, "stuck timeout").unwrap();

        let (runs, _) = get_runs(&pool, Some("cron_1"), Some("timed_out"), 10, 0).unwrap();
        assert_eq!(runs.len(), 1);
        assert_eq!(runs[0].status, RunStatus::TimedOut);
        assert!(runs[0].completed_at.is_some());
        assert_eq!(runs[0].error.as_deref(), Some("stuck timeout"));
    }

    #[test]
    fn complete_stuck_runs_no_match() {
        let pool = setup_pool();
        let job = make_job("cron_1", "Test");
        upsert_job(&pool, &job).unwrap();

        let updated = complete_stuck_runs(&pool, "cron_1", Utc::now(), "stuck").unwrap();
        assert_eq!(updated, 0);
    }

    // ── Tool restrictions persistence ───────────────────────────────

    #[test]
    fn upsert_job_with_tool_restrictions() {
        let pool = setup_pool();
        let mut job = make_job("cron_tr", "Restricted");
        job.tool_restrictions = Some(crate::cron::types::ToolRestrictions {
            allowed_tools: None,
            denied_tools: Some(vec!["Bash".into(), "Write".into()]),
        });
        upsert_job(&pool, &job).unwrap();

        let loaded = get_job(&pool, "cron_tr").unwrap().unwrap();
        assert!(loaded.tool_restrictions.is_some());
        let tr = loaded.tool_restrictions.unwrap();
        assert_eq!(
            tr.denied_tools,
            Some(vec!["Bash".to_string(), "Write".to_string()])
        );
        assert!(tr.allowed_tools.is_none());
    }

    #[test]
    fn upsert_job_without_tool_restrictions_backward_compat() {
        let pool = setup_pool();
        let job = make_job("cron_no_tr", "No Restrictions");
        upsert_job(&pool, &job).unwrap();

        let loaded = get_job(&pool, "cron_no_tr").unwrap().unwrap();
        assert!(loaded.tool_restrictions.is_none());
    }

    #[test]
    fn upsert_job_null_tool_restrictions() {
        let pool = setup_pool();
        let mut job = make_job("cron_null_tr", "Null TR");
        job.tool_restrictions = None;
        upsert_job(&pool, &job).unwrap();

        let loaded = get_job(&pool, "cron_null_tr").unwrap().unwrap();
        assert!(loaded.tool_restrictions.is_none());
    }

    #[test]
    fn sync_preserves_runtime_state() {
        let pool = setup_pool();
        let jobs = vec![make_job("cron_1", "Job 1")];
        sync_from_config(&pool, &jobs).unwrap();

        // Set some runtime state
        let now = Utc::now();
        update_next_run_at(&pool, "cron_1", Some(now)).unwrap();
        update_last_run_at(&pool, "cron_1", now).unwrap();
        let _ = increment_consecutive_failures(&pool, "cron_1").unwrap();

        // Re-sync with the same job
        sync_from_config(&pool, &jobs).unwrap();

        // Runtime state preserved
        let state = get_runtime_state(&pool, "cron_1").unwrap().unwrap();
        assert!(state.next_run_at.is_some());
        assert!(state.last_run_at.is_some());
        assert_eq!(state.consecutive_failures, 1);
    }
}
