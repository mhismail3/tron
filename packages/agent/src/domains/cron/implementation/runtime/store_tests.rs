use super::*;
use crate::domains::cron::types::*;

fn setup_pool() -> ConnectionPool {
    let pool = crate::domains::session::event_store::new_in_memory(
        &crate::domains::session::event_store::ConnectionConfig::default(),
    )
    .unwrap();
    {
        let conn = pool.get().unwrap();
        conn.execute_batch("PRAGMA foreign_keys = ON;").unwrap();
        crate::domains::session::event_store::run_migrations(&conn).unwrap();
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
        capability_restrictions: None,
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
        let _ = conn
            .execute(
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
fn sync_job_cache_adds_new_jobs() {
    let pool = setup_pool();
    let jobs = vec![make_job("cron_1", "Job 1"), make_job("cron_2", "Job 2")];
    let (added, updated, removed) = sync_job_cache(&pool, &jobs).unwrap();
    assert_eq!(added, 2);
    assert_eq!(updated, 0);
    assert_eq!(removed, 0);
}

#[test]
fn sync_job_cache_updates_changed_jobs() {
    let pool = setup_pool();
    let jobs = vec![make_job("cron_1", "Job 1")];
    sync_job_cache(&pool, &jobs).unwrap();

    let mut updated_jobs = vec![make_job("cron_1", "Updated Job 1")];
    updated_jobs[0].max_retries = 5;
    let (added, updated, removed) = sync_job_cache(&pool, &updated_jobs).unwrap();
    assert_eq!(added, 0);
    assert_eq!(updated, 1);
    assert_eq!(removed, 0);

    let loaded = get_job(&pool, "cron_1").unwrap().unwrap();
    assert_eq!(loaded.name, "Updated Job 1");
    assert_eq!(loaded.max_retries, 5);
}

#[test]
fn sync_job_cache_removes_deleted_jobs() {
    let pool = setup_pool();
    let jobs = vec![make_job("cron_1", "Job 1"), make_job("cron_2", "Job 2")];
    sync_job_cache(&pool, &jobs).unwrap();

    // Sync with only job 1
    let (_, _, removed) = sync_job_cache(&pool, &jobs[..1]).unwrap();
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

// ── ModelCapability restrictions persistence ───────────────────────────────

#[test]
fn upsert_job_with_capability_restrictions() {
    let pool = setup_pool();
    let mut job = make_job("cron_tr", "Restricted");
    job.capability_restrictions = Some(crate::domains::cron::types::CapabilityRestrictions {
        allowed_contracts: Some(vec![
            "filesystem::read_file".into(),
            "filesystem::search_text".into(),
        ]),
    });
    upsert_job(&pool, &job).unwrap();

    let loaded = get_job(&pool, "cron_tr").unwrap().unwrap();
    assert!(loaded.capability_restrictions.is_some());
    let tr = loaded.capability_restrictions.unwrap();
    assert_eq!(
        tr.allowed_contracts,
        Some(vec![
            "filesystem::read_file".to_string(),
            "filesystem::search_text".to_string()
        ])
    );
}

#[test]
fn upsert_job_null_capability_restrictions() {
    let pool = setup_pool();
    let mut job = make_job("cron_null_tr", "Null TR");
    job.capability_restrictions = None;
    upsert_job(&pool, &job).unwrap();

    let loaded = get_job(&pool, "cron_null_tr").unwrap().unwrap();
    assert!(loaded.capability_restrictions.is_none());
}

#[test]
fn sync_preserves_runtime_state() {
    let pool = setup_pool();
    let jobs = vec![make_job("cron_1", "Job 1")];
    sync_job_cache(&pool, &jobs).unwrap();

    // Set some runtime state
    let now = Utc::now();
    update_next_run_at(&pool, "cron_1", Some(now)).unwrap();
    update_last_run_at(&pool, "cron_1", now).unwrap();
    let _ = increment_consecutive_failures(&pool, "cron_1").unwrap();

    // Re-sync with the same job
    sync_job_cache(&pool, &jobs).unwrap();

    // Runtime state preserved
    let state = get_runtime_state(&pool, "cron_1").unwrap().unwrap();
    assert!(state.next_run_at.is_some());
    assert!(state.last_run_at.is_some());
    assert_eq!(state.consecutive_failures, 1);
}

// ── Corrupt data robustness tests ─────────────────────────────

#[test]
fn row_to_job_corrupt_schedule_returns_error() {
    let pool = setup_pool();
    let conn = pool.get().unwrap();
    let _ = conn
        .execute(
            "INSERT INTO cron_jobs (id, name, schedule_json, payload_json, created_at, updated_at)
             VALUES ('cron_bad', 'Bad', 'NOT VALID JSON', '{}', '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z')",
            [],
        )
        .unwrap();
    drop(conn);

    let result = get_job(&pool, "cron_bad");
    assert!(
        result.is_err(),
        "corrupt schedule_json should return error, not default"
    );
}

#[test]
fn row_to_job_corrupt_payload_returns_error() {
    let pool = setup_pool();
    let conn = pool.get().unwrap();
    let _ = conn
        .execute(
            "INSERT INTO cron_jobs (id, name, schedule_json, payload_json, created_at, updated_at)
             VALUES ('cron_bad2', 'Bad2', '{\"type\":\"every\",\"intervalSecs\":60}', 'CORRUPT', '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z')",
            [],
        )
        .unwrap();
    drop(conn);

    let result = get_job(&pool, "cron_bad2");
    assert!(
        result.is_err(),
        "corrupt payload_json should return error, not default"
    );
}

#[test]
fn row_to_job_corrupt_tags_returns_error() {
    let pool = setup_pool();
    let conn = pool.get().unwrap();
    let _ = conn
        .execute(
            "INSERT INTO cron_jobs (id, name, schedule_json, payload_json, tags, created_at, updated_at)
             VALUES ('cron_bad3', 'Bad3', '{\"type\":\"every\",\"intervalSecs\":60}', '{\"type\":\"shellCommand\",\"command\":\"echo\"}', 'NOT JSON', '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z')",
            [],
        )
        .unwrap();
    drop(conn);

    let result = get_job(&pool, "cron_bad3");
    assert!(
        result.is_err(),
        "corrupt tags_json should return error, not default"
    );
}

#[test]
fn row_to_job_valid_data_succeeds() {
    let pool = setup_pool();
    let job = make_job("cron_valid", "Valid Job");
    upsert_job(&pool, &job).unwrap();

    let loaded = get_job(&pool, "cron_valid").unwrap().unwrap();
    assert_eq!(loaded.name, "Valid Job");
    assert_eq!(loaded.id, "cron_valid");
}

#[test]
fn list_all_jobs_corrupt_row_logged_and_skipped() {
    // S1 invariant: bulk reads are fail-skip (log + omit), not fail-loud.
    // A valid row and a corrupt row coexist — list_all_jobs returns the
    // valid one and drops the corrupt one, rather than surfacing an Err
    // for the whole batch. (get_job, by contrast, is fail-loud — covered
    // by `row_to_job_corrupt_*_returns_error` above.)
    let pool = setup_pool();
    let good = make_job("cron_good", "Good");
    upsert_job(&pool, &good).unwrap();

    let conn = pool.get().unwrap();
    let _ = conn
        .execute(
            "INSERT INTO cron_jobs (id, name, schedule_json, payload_json, created_at, updated_at)
             VALUES ('cron_bad', 'Bad', 'NOT VALID JSON', '{}', '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z')",
            [],
        )
        .unwrap();
    drop(conn);

    let jobs = list_all_jobs(&pool).unwrap();
    let ids: Vec<_> = jobs.iter().map(|j| j.id.as_str()).collect();
    assert!(
        ids.contains(&"cron_good"),
        "fail-skip must preserve the good job: {ids:?}"
    );
    assert!(
        !ids.contains(&"cron_bad"),
        "fail-skip must drop the corrupt job: {ids:?}"
    );
}

#[test]
fn row_to_job_corrupt_created_at_returns_error() {
    let pool = setup_pool();
    let conn = pool.get().unwrap();
    let _ = conn
        .execute(
            "INSERT INTO cron_jobs (id, name, schedule_json, payload_json, created_at, updated_at)
             VALUES ('cron_bad4', 'Bad4', '{\"type\":\"every\",\"intervalSecs\":60}', '{\"type\":\"shellCommand\",\"command\":\"echo\"}', 'not-a-date', '2026-01-01T00:00:00Z')",
            [],
        )
        .unwrap();
    drop(conn);

    let result = get_job(&pool, "cron_bad4");
    assert!(
        result.is_err(),
        "corrupt created_at should return error, not default to now"
    );
}

// ── F1: Targeted UPDATE/DELETE on stale id surfaces NotFound ──────────
//
// Previously, every mutator discarded the row-count via `let _ = conn.execute(...)?`.
// A stale or deleted-between-read-and-write id would silently produce 0 affected
// rows and return `Ok(())`. Now UPDATE-by-id functions return `CronError::NotFound`.
// UPSERT (`upsert_job`) and plain INSERT (`insert_run`) still discard the count —
// their row count is always 1 by construction.

#[test]
fn upsert_doesnt_validate_row_count() {
    // Regression guard: upsert_job must accept both insert (0→1 affected) and
    // update (1→1 affected) paths. This test ensures we never accidentally
    // add row-count validation to the upsert (which would break re-sync).
    let pool = setup_pool();
    let mut job = make_job("cron_upsert", "Original");
    upsert_job(&pool, &job).unwrap(); // Insert path.

    job.name = "Updated".into();
    upsert_job(&pool, &job).unwrap(); // Update path.
    upsert_job(&pool, &job).unwrap(); // Re-update — no-op diff still OK.

    let loaded = get_job(&pool, "cron_upsert").unwrap().unwrap();
    assert_eq!(loaded.name, "Updated");
}

#[test]
fn update_next_run_at_missing_job_returns_not_found() {
    let pool = setup_pool();
    let result = update_next_run_at(&pool, "does_not_exist", Some(Utc::now()));
    match result {
        Err(CronError::NotFound(msg)) => assert!(msg.contains("does_not_exist")),
        other => panic!("expected NotFound, got {other:?}"),
    }
}

#[test]
fn update_last_run_at_missing_job_returns_not_found() {
    let pool = setup_pool();
    let result = update_last_run_at(&pool, "does_not_exist", Utc::now());
    match result {
        Err(CronError::NotFound(msg)) => assert!(msg.contains("does_not_exist")),
        other => panic!("expected NotFound, got {other:?}"),
    }
}

#[test]
fn set_running_since_missing_job_returns_not_found() {
    let pool = setup_pool();
    let result = set_running_since(&pool, "does_not_exist", Utc::now());
    match result {
        Err(CronError::NotFound(msg)) => assert!(msg.contains("does_not_exist")),
        other => panic!("expected NotFound, got {other:?}"),
    }
}

#[test]
fn clear_running_since_missing_job_returns_not_found() {
    let pool = setup_pool();
    let result = clear_running_since(&pool, "does_not_exist");
    match result {
        Err(CronError::NotFound(msg)) => assert!(msg.contains("does_not_exist")),
        other => panic!("expected NotFound, got {other:?}"),
    }
}

#[test]
fn increment_consecutive_failures_missing_job_returns_not_found() {
    let pool = setup_pool();
    let result = increment_consecutive_failures(&pool, "does_not_exist");
    match result {
        Err(CronError::NotFound(msg)) => assert!(msg.contains("does_not_exist")),
        other => panic!("expected NotFound, got {other:?}"),
    }
}

#[test]
fn reset_consecutive_failures_missing_job_returns_not_found() {
    let pool = setup_pool();
    let result = reset_consecutive_failures(&pool, "does_not_exist");
    match result {
        Err(CronError::NotFound(msg)) => assert!(msg.contains("does_not_exist")),
        other => panic!("expected NotFound, got {other:?}"),
    }
}

#[test]
fn disable_job_missing_job_returns_not_found() {
    let pool = setup_pool();
    let result = disable_job(&pool, "does_not_exist");
    match result {
        Err(CronError::NotFound(msg)) => assert!(msg.contains("does_not_exist")),
        other => panic!("expected NotFound, got {other:?}"),
    }
}

#[test]
fn complete_run_missing_run_returns_not_found() {
    let pool = setup_pool();
    let run = CronRun {
        id: "does_not_exist".into(),
        job_id: None,
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
    let result = complete_run(&pool, &run);
    match result {
        Err(CronError::NotFound(msg)) => assert!(msg.contains("does_not_exist")),
        other => panic!("expected NotFound, got {other:?}"),
    }
}

#[test]
fn update_delivery_status_missing_run_returns_not_found() {
    let pool = setup_pool();
    let result = update_delivery_status(&pool, "does_not_exist", &DeliveryOutcome::Ok);
    match result {
        Err(CronError::NotFound(msg)) => assert!(msg.contains("does_not_exist")),
        other => panic!("expected NotFound, got {other:?}"),
    }
}

#[test]
fn stale_run_id_surfaces_not_found_not_silent_success() {
    // End-to-end: a run is inserted, then cascade-deleted by job deletion is
    // disabled (cron_runs has ON DELETE SET NULL for job_id). But if a caller
    // retains a run_id after an explicit DELETE FROM cron_runs (e.g. GC race),
    // subsequent complete_run / update_delivery_status must surface NotFound.
    let pool = setup_pool();
    let job = make_job("cron_1", "Test");
    upsert_job(&pool, &job).unwrap();
    insert_run(&pool, "run_gc", "cron_1", "Test", Utc::now()).unwrap();

    // Simulate GC or manual delete of the run row.
    let conn = pool.get().unwrap();
    conn.execute("DELETE FROM cron_runs WHERE id = ?1", params!["run_gc"])
        .unwrap();
    drop(conn);

    let result = update_delivery_status(&pool, "run_gc", &DeliveryOutcome::Ok);
    assert!(
        matches!(result, Err(CronError::NotFound(_))),
        "stale run_id after GC must surface NotFound, not silent success"
    );
}

#[test]
fn upsert_after_update_no_longer_silent() {
    // Positive path for the targeted updaters: after an upsert, every setter
    // must succeed (and return Ok(_)), not fail.
    let pool = setup_pool();
    let job = make_job("cron_alive", "Alive");
    upsert_job(&pool, &job).unwrap();

    update_next_run_at(&pool, "cron_alive", Some(Utc::now())).unwrap();
    update_last_run_at(&pool, "cron_alive", Utc::now()).unwrap();
    set_running_since(&pool, "cron_alive", Utc::now()).unwrap();
    clear_running_since(&pool, "cron_alive").unwrap();
    increment_consecutive_failures(&pool, "cron_alive").unwrap();
    reset_consecutive_failures(&pool, "cron_alive").unwrap();
    disable_job(&pool, "cron_alive").unwrap();

    insert_run(&pool, "run_alive", "cron_alive", "Alive", Utc::now()).unwrap();
    let run = CronRun {
        id: "run_alive".into(),
        job_id: Some("cron_alive".into()),
        job_name: "Alive".into(),
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
    };
    complete_run(&pool, &run).unwrap();
    update_delivery_status(&pool, "run_alive", &DeliveryOutcome::Ok).unwrap();
}
