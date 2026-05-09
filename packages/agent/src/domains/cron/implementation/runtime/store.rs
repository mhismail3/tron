//! `SQLite` repository for cron jobs and runs.
//!
//! Handles CRUD operations, runtime state management, and garbage collection.
//! All operations use the shared `log.db` connection pool.

use crate::domains::session::event_store::ConnectionPool;
use chrono::{DateTime, Utc};
use rusqlite::params;

use crate::domains::cron::errors::CronError;
use crate::domains::cron::types::{CronJob, CronRun, DeliveryOutcome, JobRuntimeState, RunStatus};

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

    // upsert: row count is always 1 (insert or updated row) — no stale-id semantics.
    let _ = conn.execute(
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

/// List all jobs from the database for config-file corruption recovery.
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
        .filter_map(|r| match r {
            Ok(job) => Some(job),
            Err(e) => {
                tracing::error!(error = %e, "skipping corrupt job in SQLite recovery source");
                None
            }
        })
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
///
/// Returns `CronError::NotFound` if `job_id` does not exist.
pub fn update_next_run_at(
    pool: &ConnectionPool,
    job_id: &str,
    next: Option<DateTime<Utc>>,
) -> Result<(), CronError> {
    let conn = pool.get()?;
    let rows = conn.execute(
        "UPDATE cron_jobs SET next_run_at = ?1 WHERE id = ?2",
        params![next.map(|t| t.to_rfc3339()), job_id],
    )?;
    if rows == 0 {
        return Err(CronError::NotFound(job_id.to_string()));
    }
    Ok(())
}

/// Update `last_run_at` for a job.
///
/// Returns `CronError::NotFound` if `job_id` does not exist.
pub fn update_last_run_at(
    pool: &ConnectionPool,
    job_id: &str,
    last: DateTime<Utc>,
) -> Result<(), CronError> {
    let conn = pool.get()?;
    let rows = conn.execute(
        "UPDATE cron_jobs SET last_run_at = ?1 WHERE id = ?2",
        params![last.to_rfc3339(), job_id],
    )?;
    if rows == 0 {
        return Err(CronError::NotFound(job_id.to_string()));
    }
    Ok(())
}

/// Set `running_since` to mark a job as currently executing.
///
/// Returns `CronError::NotFound` if `job_id` does not exist.
pub fn set_running_since(
    pool: &ConnectionPool,
    job_id: &str,
    since: DateTime<Utc>,
) -> Result<(), CronError> {
    let conn = pool.get()?;
    let rows = conn.execute(
        "UPDATE cron_jobs SET running_since = ?1 WHERE id = ?2",
        params![since.to_rfc3339(), job_id],
    )?;
    if rows == 0 {
        return Err(CronError::NotFound(job_id.to_string()));
    }
    Ok(())
}

/// Clear `running_since` when execution finishes.
///
/// Returns `CronError::NotFound` if `job_id` does not exist.
pub fn clear_running_since(pool: &ConnectionPool, job_id: &str) -> Result<(), CronError> {
    let conn = pool.get()?;
    let rows = conn.execute(
        "UPDATE cron_jobs SET running_since = NULL WHERE id = ?1",
        params![job_id],
    )?;
    if rows == 0 {
        return Err(CronError::NotFound(job_id.to_string()));
    }
    Ok(())
}

/// Increment consecutive failures and return the new count.
///
/// Returns `CronError::NotFound` if `job_id` does not exist.
pub fn increment_consecutive_failures(
    pool: &ConnectionPool,
    job_id: &str,
) -> Result<u32, CronError> {
    let conn = pool.get()?;
    let rows = conn.execute(
        "UPDATE cron_jobs SET consecutive_failures = consecutive_failures + 1 WHERE id = ?1",
        params![job_id],
    )?;
    if rows == 0 {
        return Err(CronError::NotFound(job_id.to_string()));
    }
    let count: u32 = conn.query_row(
        "SELECT consecutive_failures FROM cron_jobs WHERE id = ?1",
        params![job_id],
        |row| row.get(0),
    )?;
    Ok(count)
}

/// Reset consecutive failures to zero.
///
/// Returns `CronError::NotFound` if `job_id` does not exist.
pub fn reset_consecutive_failures(pool: &ConnectionPool, job_id: &str) -> Result<(), CronError> {
    let conn = pool.get()?;
    let rows = conn.execute(
        "UPDATE cron_jobs SET consecutive_failures = 0 WHERE id = ?1",
        params![job_id],
    )?;
    if rows == 0 {
        return Err(CronError::NotFound(job_id.to_string()));
    }
    Ok(())
}

/// Disable a job.
///
/// Returns `CronError::NotFound` if `job_id` does not exist.
pub fn disable_job(pool: &ConnectionPool, job_id: &str) -> Result<(), CronError> {
    let conn = pool.get()?;
    let rows = conn.execute(
        "UPDATE cron_jobs SET enabled = 0 WHERE id = ?1",
        params![job_id],
    )?;
    if rows == 0 {
        return Err(CronError::NotFound(job_id.to_string()));
    }
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
    // INSERT: row count is always 1 (unique PK violation becomes an Err, not 0 rows).
    let _ = conn.execute(
        "INSERT INTO cron_runs (id, job_id, job_name, status, started_at)
         VALUES (?1, ?2, ?3, 'running', ?4)",
        params![run_id, job_id, job_name, started_at.to_rfc3339()],
    )?;
    Ok(())
}

/// Complete a run record with the final status.
///
/// Returns `CronError::NotFound` if `run.id` does not exist (e.g. GC raced with completion).
pub fn complete_run(pool: &ConnectionPool, run: &CronRun) -> Result<(), CronError> {
    let conn = pool.get()?;
    let rows = conn.execute(
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
    if rows == 0 {
        return Err(CronError::NotFound(run.id.clone()));
    }
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
        .filter_map(|r| match r {
            Ok(run) => Some(run),
            Err(e) => {
                tracing::error!(error = %e, "skipping corrupt run record");
                None
            }
        })
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
///
/// Returns `CronError::NotFound` if `run_id` does not exist (e.g. GC raced with delivery).
pub fn update_delivery_status(
    pool: &ConnectionPool,
    run_id: &str,
    status: &DeliveryOutcome,
) -> Result<(), CronError> {
    let conn = pool.get()?;
    let rows = conn.execute(
        "UPDATE cron_runs SET delivery_status = ?1 WHERE id = ?2",
        params![status.as_str(), run_id],
    )?;
    if rows == 0 {
        return Err(CronError::NotFound(run_id.to_string()));
    }
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
            match r {
                Ok((id, since_str, timeout)) => {
                    match DateTime::parse_from_rfc3339(&since_str) {
                        Ok(since) => Some((id, since.to_utc(), timeout)),
                        Err(e) => {
                            tracing::error!(job_id = %id, error = %e, "corrupt running_since timestamp, skipping stuck detection");
                            None
                        }
                    }
                }
                Err(e) => {
                    tracing::error!(error = %e, "failed to read stuck job candidate row");
                    None
                }
            }
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
            let _ = delete_job(pool, id)?;
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

    let schedule = serde_json::from_str(&schedule_json).map_err(|e| {
        rusqlite::Error::FromSqlConversionFailure(
            4,
            rusqlite::types::Type::Text,
            format!("corrupt schedule_json for job {id}: {e}").into(),
        )
    })?;
    let payload = serde_json::from_str(&payload_json).map_err(|e| {
        rusqlite::Error::FromSqlConversionFailure(
            5,
            rusqlite::types::Type::Text,
            format!("corrupt payload_json for job {id}: {e}").into(),
        )
    })?;
    let delivery = serde_json::from_str(&delivery_json).map_err(|e| {
        rusqlite::Error::FromSqlConversionFailure(
            6,
            rusqlite::types::Type::Text,
            format!("corrupt delivery_json for job {id}: {e}").into(),
        )
    })?;
    let tags = serde_json::from_str(&tags_json).map_err(|e| {
        rusqlite::Error::FromSqlConversionFailure(
            12,
            rusqlite::types::Type::Text,
            format!("corrupt tags_json for job {id}: {e}").into(),
        )
    })?;
    let tool_restrictions = tool_restrictions_json
        .map(|s| serde_json::from_str(&s))
        .transpose()
        .map_err(|e| {
            rusqlite::Error::FromSqlConversionFailure(
                16,
                rusqlite::types::Type::Text,
                format!("corrupt tool_restrictions_json for job {id}: {e}").into(),
            )
        })?;
    let created_at = DateTime::parse_from_rfc3339(&created_str)
        .map(|t| t.to_utc())
        .map_err(|e| {
            rusqlite::Error::FromSqlConversionFailure(
                14,
                rusqlite::types::Type::Text,
                format!("corrupt created_at for job {id}: {e}").into(),
            )
        })?;
    let updated_at = DateTime::parse_from_rfc3339(&updated_str)
        .map(|t| t.to_utc())
        .map_err(|e| {
            rusqlite::Error::FromSqlConversionFailure(
                15,
                rusqlite::types::Type::Text,
                format!("corrupt updated_at for job {id}: {e}").into(),
            )
        })?;

    Ok(CronJob {
        name: row.get(1)?,
        description: row.get(2)?,
        enabled: row.get(3)?,
        schedule,
        payload,
        delivery,
        overlap_policy: crate::domains::cron::types::OverlapPolicy::from_sql(&overlap_str),
        misfire_policy: crate::domains::cron::types::MisfirePolicy::from_sql(&misfire_str),
        max_retries: row.get(9)?,
        auto_disable_after: row.get(10)?,
        stuck_timeout_secs: row.get(11)?,
        tags,
        tool_restrictions,
        workspace_id: row.get(13)?,
        created_at,
        updated_at,
        id,
    })
}

fn row_to_run(row: &rusqlite::Row<'_>) -> rusqlite::Result<CronRun> {
    let id: String = row.get(0)?;
    let status_str: String = row.get(3)?;
    let started_str: String = row.get(4)?;
    let completed_str: Option<String> = row.get(5)?;

    let status = RunStatus::parse(&status_str).ok_or_else(|| {
        rusqlite::Error::FromSqlConversionFailure(
            3,
            rusqlite::types::Type::Text,
            format!("unknown RunStatus '{status_str}' for run {id}").into(),
        )
    })?;
    let started_at = DateTime::parse_from_rfc3339(&started_str)
        .map(|t| t.to_utc())
        .map_err(|e| {
            rusqlite::Error::FromSqlConversionFailure(
                4,
                rusqlite::types::Type::Text,
                format!("corrupt started_at for run {id}: {e}").into(),
            )
        })?;
    let completed_at = completed_str
        .map(|s| {
            DateTime::parse_from_rfc3339(&s)
                .map(|t| t.to_utc())
                .map_err(|e| {
                    rusqlite::Error::FromSqlConversionFailure(
                        5,
                        rusqlite::types::Type::Text,
                        format!("corrupt completed_at for run {id}: {e}").into(),
                    )
                })
        })
        .transpose()?;

    Ok(CronRun {
        job_id: row.get(1)?,
        job_name: row.get(2)?,
        status,
        started_at,
        completed_at,
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
    s.and_then(|s| {
        DateTime::parse_from_rfc3339(&s)
            .map(|t| t.to_utc())
            .map_err(
                |e| tracing::warn!(error = %e, value = %s, "corrupt datetime in runtime state"),
            )
            .ok()
    })
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
#[path = "store_tests.rs"]
mod tests;
