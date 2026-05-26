use super::*;

fn cron_read_context() -> CausalContext {
    causal()
        .with_session_id("session-cron")
        .with_workspace_id("workspace-cron")
        .with_scope("cron.read")
}

fn cron_write_context(key: &str) -> CausalContext {
    mutating_causal(key).with_scope("cron.write")
}

async fn inspect_resource(handle: &EngineHostHandle, resource_id: &str) -> Value {
    let inspected = handle
        .invoke(host_invocation(
            "resource::inspect",
            json!({"resourceId": resource_id}),
            causal().with_scope("resource.read"),
        ))
        .await;
    assert_eq!(inspected.error, None);
    inspected.value.unwrap()["inspection"].clone()
}

fn shell_job(name: &str) -> Value {
    json!({
        "name": name,
        "enabled": true,
        "schedule": {"type": "every", "intervalSecs": 60},
        "payload": {"type": "shellCommand", "command": "printf cron-ok", "timeoutSecs": 5},
        "delivery": [{"type": "silent"}],
        "tags": ["resource-truth"],
        "workspaceId": "workspace-cron"
    })
}

fn cache_only_job() -> crate::domains::cron::CronJob {
    let now = Utc::now();
    crate::domains::cron::CronJob {
        id: "cron_cache_only".to_owned(),
        name: "Cache-only cron".to_owned(),
        description: None,
        enabled: true,
        schedule: crate::domains::cron::Schedule::Every {
            interval_secs: 60,
            anchor: None,
        },
        payload: crate::domains::cron::Payload::ShellCommand {
            command: "printf hidden".to_owned(),
            working_directory: None,
            timeout_secs: 5,
        },
        delivery: vec![crate::domains::cron::Delivery::Silent],
        overlap_policy: crate::domains::cron::OverlapPolicy::Skip,
        misfire_policy: crate::domains::cron::MisfirePolicy::Skip,
        max_retries: 0,
        auto_disable_after: 0,
        stuck_timeout_secs: 7200,
        tags: vec!["cache-only".to_owned()],
        capability_restrictions: None,
        workspace_id: Some("workspace-cron".to_owned()),
        created_at: now,
        updated_at: now,
    }
}

fn current_payload(inspection: &Value) -> Value {
    let current = inspection["resource"]["currentVersionId"].as_str().unwrap();
    inspection["versions"]
        .as_array()
        .unwrap()
        .iter()
        .find(|version| version["versionId"].as_str() == Some(current))
        .unwrap()["payload"]
        .clone()
}

#[tokio::test]
async fn cron_create_update_delete_are_decision_backed() {
    let ctx = crate::shared::server::test_support::make_test_context_with_cron_scheduler();
    let handle = ctx.engine_host.clone();

    let created = handle
        .invoke(host_invocation(
            "cron::create",
            json!({"job": shell_job("Decision-backed cron")}),
            cron_write_context("cron-resource-create"),
        ))
        .await;
    assert_eq!(created.error, None);
    let created_value = created.value.as_ref().unwrap();
    let job_id = created_value["job"]["id"].as_str().unwrap();
    let schedule_ref = created_value["resourceRefs"]
        .as_array()
        .unwrap()
        .iter()
        .find(|reference| reference["kind"] == "decision")
        .expect("cron create must return a decision resource ref");
    let resource_id = schedule_ref["resourceId"].as_str().unwrap();
    assert_eq!(
        resource_id,
        crate::domains::cron::truth::schedule_decision_id(job_id)
    );

    let inspection = inspect_resource(&handle, resource_id).await;
    let payload = current_payload(&inspection);
    assert_eq!(payload["metadata"]["decisionType"], "cron_schedule");
    assert_eq!(payload["metadata"]["enabled"], true);
    assert_eq!(payload["job"]["name"], "Decision-backed cron");

    let listed = handle
        .invoke(host_invocation(
            "cron::list",
            json!({"workspaceId": "workspace-cron"}),
            cron_read_context(),
        ))
        .await;
    assert_eq!(listed.error, None);
    assert!(
        listed.value.as_ref().unwrap()["jobs"]
            .as_array()
            .unwrap()
            .iter()
            .any(|job| job["id"] == job_id),
        "cron::list must read schedule decisions, not a hidden file"
    );

    let updated = handle
        .invoke(host_invocation(
            "cron::update",
            json!({"jobId": job_id, "name": "Decision-backed cron v2", "enabled": false}),
            cron_write_context("cron-resource-update"),
        ))
        .await;
    assert_eq!(updated.error, None);
    assert!(
        updated.value.as_ref().unwrap()["resourceRefs"]
            .as_array()
            .unwrap()
            .iter()
            .any(|reference| reference["kind"] == "decision" && reference["role"] == "updated")
    );

    let updated_inspection = inspect_resource(&handle, resource_id).await;
    let updated_payload = current_payload(&updated_inspection);
    assert_eq!(updated_payload["status"], "disabled");
    assert_eq!(updated_payload["metadata"]["enabled"], false);
    assert_eq!(updated_payload["job"]["name"], "Decision-backed cron v2");

    let deleted = handle
        .invoke(host_invocation(
            "cron::delete",
            json!({"jobId": job_id}),
            cron_write_context("cron-resource-delete"),
        ))
        .await;
    assert_eq!(deleted.error, None);
    assert_eq!(deleted.value.as_ref().unwrap()["deleted"], true);
    assert!(
        deleted.value.as_ref().unwrap()["resourceRefs"]
            .as_array()
            .unwrap()
            .iter()
            .any(|reference| reference["kind"] == "decision" && reference["role"] == "updated")
    );

    let archived = inspect_resource(&handle, resource_id).await;
    assert_eq!(archived["resource"]["lifecycle"], "archived");
}

#[tokio::test]
async fn cron_get_runs_reads_evidence_truth() {
    let ctx = crate::shared::server::test_support::make_test_context_with_cron_scheduler();
    let handle = ctx.engine_host.clone();

    let created = handle
        .invoke(host_invocation(
            "cron::create",
            json!({"job": shell_job("Evidence-backed cron")}),
            cron_write_context("cron-resource-run-create"),
        ))
        .await;
    assert_eq!(created.error, None);
    let job_value = &created.value.as_ref().unwrap()["job"];
    let job: crate::domains::cron::CronJob = serde_json::from_value(job_value.clone()).unwrap();
    let run = crate::domains::cron::CronRun {
        id: "cronrun_resource_truth".to_owned(),
        job_id: Some(job.id.clone()),
        job_name: job.name.clone(),
        status: crate::domains::cron::RunStatus::Completed,
        started_at: Utc::now(),
        completed_at: Some(Utc::now()),
        duration_ms: Some(12),
        output: Some("cron output".to_owned()),
        output_truncated: false,
        error: None,
        exit_code: Some(0),
        attempt: 0,
        session_id: None,
        delivery_status: None,
    };
    crate::domains::cron::truth::attach_run_evidence(&handle, &job, &run)
        .await
        .unwrap();

    let runs = handle
        .invoke(host_invocation(
            "cron::get_runs",
            json!({"jobId": job.id, "status": "completed"}),
            cron_read_context(),
        ))
        .await;
    assert_eq!(runs.error, None);
    let value = runs.value.as_ref().unwrap();
    assert_eq!(value["total"], 1);
    assert_eq!(value["runs"][0]["id"], "cronrun_resource_truth");
    assert_eq!(
        value["runs"][0]["evidenceResourceId"],
        crate::domains::cron::truth::run_evidence_id("cronrun_resource_truth")
    );
}

#[tokio::test]
async fn cron_runtime_lifecycle_flip_updates_decision_truth_idempotently() {
    let ctx = crate::shared::server::test_support::make_test_context_with_cron_scheduler();
    let handle = ctx.engine_host.clone();

    let created = handle
        .invoke(host_invocation(
            "cron::create",
            json!({"job": shell_job("Lifecycle-backed cron")}),
            cron_write_context("cron-resource-lifecycle-create"),
        ))
        .await;
    assert_eq!(created.error, None);
    let job_id = created.value.as_ref().unwrap()["job"]["id"]
        .as_str()
        .unwrap();
    let resource_id = crate::domains::cron::truth::schedule_decision_id(job_id);

    crate::domains::cron::truth::set_schedule_enabled(
        &handle,
        job_id,
        false,
        "test lifecycle flip",
    )
    .await
    .unwrap();
    let disabled = inspect_resource(&handle, &resource_id).await;
    let disabled_payload = current_payload(&disabled);
    let version_count = disabled["versions"].as_array().unwrap().len();
    assert_eq!(disabled_payload["status"], "disabled");
    assert_eq!(disabled_payload["job"]["enabled"], false);
    assert_eq!(
        disabled_payload["metadata"]["reason"],
        "test lifecycle flip"
    );

    crate::domains::cron::truth::set_schedule_enabled(
        &handle,
        job_id,
        false,
        "test lifecycle flip",
    )
    .await
    .unwrap();
    let replayed = inspect_resource(&handle, &resource_id).await;
    assert_eq!(
        replayed["versions"].as_array().unwrap().len(),
        version_count,
        "repeated runtime lifecycle flips must not create duplicate resource versions"
    );
}

#[tokio::test]
async fn cron_runtime_cache_rows_are_not_product_truth() {
    let ctx = crate::shared::server::test_support::make_test_context_with_cron_scheduler();
    let handle = ctx.engine_host.clone();
    let sched = ctx.cron_scheduler.as_ref().unwrap();
    let job = cache_only_job();
    crate::domains::cron::store::upsert_job(sched.pool(), &job).unwrap();
    sched.reload_job(job.clone());

    let listed = handle
        .invoke(host_invocation(
            "cron::list",
            json!({"workspaceId": "workspace-cron"}),
            cron_read_context(),
        ))
        .await;
    assert_eq!(listed.error, None);
    assert!(
        listed.value.as_ref().unwrap()["jobs"]
            .as_array()
            .unwrap()
            .iter()
            .all(|item| item["id"] != job.id),
        "cache-only cron rows must not appear in operator schedule truth"
    );

    let fetched = handle
        .invoke(host_invocation(
            "cron::get",
            json!({"jobId": job.id}),
            cron_read_context(),
        ))
        .await;
    assert!(
        fetched
            .error
            .as_ref()
            .is_some_and(|error| error.to_string().contains("Job not found")),
        "cron::get must ignore cache-only rows"
    );

    let run = handle
        .invoke(host_invocation(
            "cron::run",
            json!({"jobId": job.id}),
            cron_write_context("cron-cache-only-run"),
        ))
        .await;
    assert!(
        run.error
            .as_ref()
            .is_some_and(|error| error.to_string().contains("Job not found")),
        "cron::run must not execute cache-only rows"
    );
}

#[tokio::test]
async fn cron_run_rehydrates_runtime_cache_from_decision_truth() {
    let ctx = crate::shared::server::test_support::make_test_context_with_cron_scheduler();
    let handle = ctx.engine_host.clone();
    let sched = ctx.cron_scheduler.as_ref().unwrap();

    let created = handle
        .invoke(host_invocation(
            "cron::create",
            json!({"job": shell_job("Hydrated cron")}),
            cron_write_context("cron-hydrate-create"),
        ))
        .await;
    assert_eq!(created.error, None);
    let job_id = created.value.as_ref().unwrap()["job"]["id"]
        .as_str()
        .unwrap()
        .to_owned();
    sched.remove_job(&job_id);
    crate::domains::cron::store::delete_job(sched.pool(), &job_id).unwrap();
    assert!(sched.get_job(&job_id).is_none());
    assert!(
        crate::domains::cron::store::get_job(sched.pool(), &job_id)
            .unwrap()
            .is_none()
    );

    let run = handle
        .invoke(host_invocation(
            "cron::run",
            json!({"jobId": job_id}),
            cron_write_context("cron-hydrate-run"),
        ))
        .await;
    assert_eq!(run.error, None);
    assert_eq!(run.value.as_ref().unwrap()["triggered"], true);
    assert!(sched.get_job(&job_id).is_some());
    assert!(
        crate::domains::cron::store::get_job(sched.pool(), &job_id)
            .unwrap()
            .is_some()
    );
}

#[tokio::test]
async fn cron_run_rejects_disabled_schedule_decision() {
    let ctx = crate::shared::server::test_support::make_test_context_with_cron_scheduler();
    let handle = ctx.engine_host.clone();

    let created = handle
        .invoke(host_invocation(
            "cron::create",
            json!({"job": shell_job("Disabled cron")}),
            cron_write_context("cron-disabled-create"),
        ))
        .await;
    assert_eq!(created.error, None);
    let job_id = created.value.as_ref().unwrap()["job"]["id"]
        .as_str()
        .unwrap();

    let disabled = handle
        .invoke(host_invocation(
            "cron::update",
            json!({"jobId": job_id, "enabled": false}),
            cron_write_context("cron-disabled-update"),
        ))
        .await;
    assert_eq!(disabled.error, None);

    let run = handle
        .invoke(host_invocation(
            "cron::run",
            json!({"jobId": job_id}),
            cron_write_context("cron-disabled-run"),
        ))
        .await;
    assert!(
        run.error
            .as_ref()
            .is_some_and(|error| error.to_string().contains("CRON_JOB_DISABLED")),
        "manual cron run must fail closed when the schedule decision is disabled"
    );
}
