use std::path::Path;
use std::sync::Arc;
use std::time::{Duration, Instant};

use chrono::{Duration as ChronoDuration, Utc};
use serde_json::{Value, json};
use tempfile::tempdir;

use crate::app::lifecycle::shutdown::{ShutdownCoordinator, ShutdownPhase};
use crate::engine::{
    ActorId, ActorKind, AuthorityGrantId, CausalContext, CreateResource, EngineResourceScope,
    FunctionId, Invocation, InvocationResult, RUNTIME_METADATA_MODEL_PRIMITIVE_NAME,
    RUNTIME_METADATA_PROVIDER_INVOCATION_ID, RUNTIME_METADATA_PROVIDER_TYPE,
    RUNTIME_METADATA_RUN_ID, RUNTIME_METADATA_TURN, RUNTIME_METADATA_WORKING_DIRECTORY, TraceId,
    WorkerId,
};
use crate::shared::server::context::ServerRuntimeContext;
use crate::shared::server::test_support::make_test_context;

#[tokio::test]
async fn job_start_requires_network_policy_none() {
    let ctx = make_test_context();
    let root = tempdir().expect("root");
    let session_id = "jobs-network-session";
    let workspace_id = "jobs-network-workspace";
    let trace_id = TraceId::new("jobs-network-denial").unwrap();
    let actor_id = ActorId::new(format!("agent:{session_id}")).unwrap();
    let grant_id = derive_execute_grant(
        &ctx,
        &actor_id,
        trace_id.clone(),
        session_id,
        workspace_id,
        root.path(),
        "loopback",
        4,
    )
    .await;

    let error = invoke_error(
        &ctx,
        json!({
            "operation": "job_start",
            "command": "printf denied",
            "idempotencyKey": "job-network-denial"
        }),
        execute_context(
            actor_id,
            grant_id,
            trace_id,
            session_id,
            workspace_id,
            root.path(),
            Some("job-network-denial"),
        ),
    )
    .await;
    assert!(error.contains("networkPolicy none"));
}

#[tokio::test]
async fn job_start_requires_idempotency_at_execute_boundary() {
    let ctx = make_test_context();
    let root = tempdir().expect("root");
    let session_id = "jobs-idempotency-session";
    let workspace_id = "jobs-idempotency-workspace";
    let trace_id = TraceId::new("jobs-idempotency").unwrap();
    let actor_id = ActorId::new(format!("agent:{session_id}")).unwrap();
    let grant_id = derive_execute_grant(
        &ctx,
        &actor_id,
        trace_id.clone(),
        session_id,
        workspace_id,
        root.path(),
        "none",
        4,
    )
    .await;

    let error = invoke_error(
        &ctx,
        json!({
            "operation": "job_start",
            "command": "printf missing-key"
        }),
        execute_context(
            actor_id,
            grant_id,
            trace_id,
            session_id,
            workspace_id,
            root.path(),
            None,
        ),
    )
    .await;
    assert!(error.contains("requires an idempotencyKey"));
}

#[tokio::test]
async fn job_cleanup_archives_terminal_resources() {
    let ctx = make_test_context();
    let root = tempdir().expect("root");
    if !sandbox_available() {
        return;
    }
    let fixture = ExecuteFixture::new(&ctx, root.path(), "jobs-cleanup").await;
    let start = fixture
        .invoke_ok(json!({
            "operation": "job_start",
            "command": "printf cleanup",
            "timeoutMs": 5000,
            "maxOutputBytes": 1000,
            "idempotencyKey": "jobs-cleanup-start"
        }))
        .await;
    let job_resource_id = job_resource_id(&start);
    fixture.wait_for_state(&job_resource_id, "completed").await;

    let cleanup = super::service::cleanup_jobs_value(
        &ctx.engine_host,
        super::runtime::JobRuntime::default(),
        super::service::ReconcileContext {
            startup_cutoff: Utc::now(),
        },
        &cleanup_invocation(root.path(), "jobs-cleanup-direct"),
        &json!({"olderThanSeconds": 0, "limit": 10}),
    )
    .await
    .expect("cleanup");
    assert_eq!(cleanup["archivedCount"], json!(1));

    let status = fixture
        .invoke_ok(json!({
            "operation": "job_status",
            "jobResourceId": job_resource_id
        }))
        .await;
    assert_eq!(jobs_details(&status)["job"]["state"], json!("archived"));
}

#[tokio::test]
async fn stale_running_job_is_reconciled_after_restart_before_status_list_and_cleanup() {
    let ctx = make_test_context();
    let root = tempdir().expect("root");
    let fixture = ExecuteFixture::new(&ctx, root.path(), "jobs-stale-restart").await;
    let job_resource_id = "job_process:jobs-stale-restart-orphan";
    create_stale_running_job_resource(&ctx, &fixture, job_resource_id).await;

    let status = fixture
        .invoke_ok(json!({
            "operation": "job_status",
            "jobResourceId": job_resource_id
        }))
        .await;
    let status_job = &jobs_details(&status)["job"];
    assert_eq!(status_job["state"], json!("failed"));
    assert_eq!(status_job["terminal"]["exitCode"], Value::Null);
    assert_eq!(status_job["terminal"]["cancelled"], json!(false));
    assert!(
        status_job["terminal"]["error"]
            .as_str()
            .unwrap()
            .contains("ownership unknown after jobs domain restart")
    );
    assert_eq!(status_job["output"], Value::Null);

    let running = fixture
        .invoke_ok(json!({
            "operation": "job_list",
            "state": "running"
        }))
        .await;
    assert!(
        jobs_details(&running)["jobs"]
            .as_array()
            .unwrap()
            .iter()
            .all(|job| job["jobResourceId"] != json!(job_resource_id))
    );

    let failed = fixture
        .invoke_ok(json!({
            "operation": "job_list",
            "state": "failed"
        }))
        .await;
    assert!(
        jobs_details(&failed)["jobs"]
            .as_array()
            .unwrap()
            .iter()
            .any(|job| job["jobResourceId"] == json!(job_resource_id))
    );

    let inspection = ctx
        .engine_host
        .inspect_resource(job_resource_id)
        .await
        .expect("inspect")
        .expect("stale job resource");
    assert_eq!(inspection.resource.lifecycle, "failed");
    assert!(
        inspection
            .events
            .iter()
            .any(|event| event.payload["versionId"] == status_job["jobVersionId"])
    );

    let cleanup = super::service::cleanup_jobs_value(
        &ctx.engine_host,
        super::runtime::JobRuntime::default(),
        super::service::ReconcileContext {
            startup_cutoff: Utc::now(),
        },
        &cleanup_invocation_for(
            root.path(),
            "jobs-stale-restart-cleanup",
            &fixture.session_id,
            &fixture.workspace_id,
        ),
        &json!({"olderThanSeconds": 0, "limit": 10}),
    )
    .await;
    assert_eq!(cleanup.expect("cleanup")["archivedCount"], json!(1));

    let archived = fixture
        .invoke_ok(json!({
            "operation": "job_status",
            "jobResourceId": job_resource_id
        }))
        .await;
    assert_eq!(jobs_details(&archived)["job"]["state"], json!("archived"));
}

#[tokio::test]
async fn stale_running_reconciliation_scans_past_newer_non_reconcilable_rows() {
    let ctx = make_test_context();
    let root = tempdir().expect("root");
    let fixture = ExecuteFixture::new(&ctx, root.path(), "jobs-stale-hidden").await;
    let stale_status_id = "job_process:jobs-stale-hidden-status";
    let stale_log_id = "job_process:jobs-stale-hidden-log";
    let stale_time = Utc::now() - ChronoDuration::minutes(5);
    create_running_job_resource_at(&ctx, &fixture, stale_status_id, stale_time).await;
    create_running_job_resource_at(&ctx, &fixture, stale_log_id, stale_time).await;

    let future_time = Utc::now() + ChronoDuration::minutes(5);
    for index in 0..501 {
        create_running_job_resource_at(
            &ctx,
            &fixture,
            &format!("job_process:jobs-stale-hidden-future-{index}"),
            future_time + ChronoDuration::seconds(index),
        )
        .await;
    }

    let status = fixture
        .invoke_ok(json!({
            "operation": "job_status",
            "jobResourceId": stale_status_id
        }))
        .await;
    let status_job = &jobs_details(&status)["job"];
    assert_eq!(status_job["state"], json!("failed"));
    assert!(
        status_job["terminal"]["error"]
            .as_str()
            .unwrap()
            .contains("ownership unknown after jobs domain restart")
    );

    let log = fixture
        .invoke_ok(json!({
            "operation": "job_log",
            "jobResourceId": stale_log_id
        }))
        .await;
    assert_eq!(jobs_details(&log)["status"], json!("failed"));
    let log_version_id = jobs_details(&log)["jobVersionId"].clone();

    let future = ctx
        .engine_host
        .inspect_resource("job_process:jobs-stale-hidden-future-500")
        .await
        .expect("inspect future")
        .expect("future running resource");
    let (_, future_record) = super::support::job_record(&future).expect("future job record");
    assert_eq!(future.resource.lifecycle, "running");
    assert_eq!(future_record.state.as_str(), "running");

    for (stale_id, version_id) in [
        (stale_status_id, status_job["jobVersionId"].clone()),
        (stale_log_id, log_version_id),
    ] {
        let inspection = ctx
            .engine_host
            .inspect_resource(stale_id)
            .await
            .expect("inspect stale")
            .expect("stale resource");
        assert_eq!(inspection.resource.lifecycle, "failed");
        let (_, record) = super::support::job_record(&inspection).expect("stale job record");
        assert!(
            record
                .terminal
                .as_ref()
                .and_then(|terminal| terminal.error.as_deref())
                .is_some_and(|error| error.contains("ownership unknown after jobs domain restart"))
        );
        assert!(
            inspection
                .events
                .iter()
                .any(|event| event.payload["versionId"] == version_id),
            "missing reconcile event for {stale_id}"
        );
    }
}

#[tokio::test]
async fn job_start_completes_and_records_bounded_output() {
    let ctx = make_test_context();
    let root = tempdir().expect("root");
    if !sandbox_available() {
        let fixture = ExecuteFixture::new(&ctx, root.path(), "jobs-sandbox-missing").await;
        let error = fixture
            .invoke_error(json!({
                "operation": "job_start",
                "command": "printf unavailable",
                "idempotencyKey": "jobs-sandbox-missing-start"
            }))
            .await;
        assert!(error.contains("cannot enforce networkPolicy none"));
        return;
    }

    let fixture = ExecuteFixture::new(&ctx, root.path(), "jobs-complete").await;
    let start = fixture
        .invoke_ok(json!({
            "operation": "job_start",
            "command": "printf hello",
            "timeoutMs": 5000,
            "maxOutputBytes": 1000,
            "idempotencyKey": "jobs-complete-start"
        }))
        .await;
    let job_resource_id = job_resource_id(&start);
    let status = fixture.wait_for_state(&job_resource_id, "completed").await;
    let job = &jobs_details(&status)["job"];
    assert!(job["output"]["outputResourceId"].as_str().is_some());
    assert_eq!(job["output"]["stdoutPreview"], json!("hello"));
    assert_eq!(job["output"]["outputTruncated"], json!(false));

    let log = fixture
        .invoke_ok(json!({
            "operation": "job_log",
            "jobResourceId": job_resource_id
        }))
        .await;
    let log_details = jobs_details(&log);
    assert_eq!(log_details["stdoutPreview"], json!("hello"));
    assert_eq!(log_details["outputTruncated"], json!(false));

    let list = fixture
        .invoke_ok(json!({
            "operation": "job_list",
            "state": "completed"
        }))
        .await;
    assert_eq!(jobs_details(&list)["jobs"].as_array().unwrap().len(), 1);

    let inspection = ctx
        .engine_host
        .inspect_resource(&job_resource_id)
        .await
        .expect("inspect")
        .expect("job resource");
    assert!(
        inspection
            .outgoing_links
            .iter()
            .any(|link| link.relation == "produced_output")
    );
}

#[tokio::test]
async fn job_output_is_bounded_and_cancel_is_terminal_idempotent() {
    let ctx = make_test_context();
    let root = tempdir().expect("root");
    if !sandbox_available() {
        return;
    }

    let fixture = ExecuteFixture::new(&ctx, root.path(), "jobs-bound-cancel").await;
    let bounded = fixture
        .invoke_ok(json!({
            "operation": "job_start",
            "command": "printf 1234567890",
            "timeoutMs": 5000,
            "maxOutputBytes": 4,
            "idempotencyKey": "jobs-bounded-start"
        }))
        .await;
    let bounded_id = job_resource_id(&bounded);
    let bounded_status = fixture.wait_for_state(&bounded_id, "completed").await;
    let bounded_job = &jobs_details(&bounded_status)["job"];
    assert_eq!(bounded_job["output"]["stdoutPreview"], json!("1234"));
    assert_eq!(bounded_job["output"]["outputTruncated"], json!(true));

    let start = fixture
        .invoke_ok(json!({
            "operation": "job_start",
            "command": "sleep 2; printf late",
            "timeoutMs": 5000,
            "maxOutputBytes": 1000,
            "idempotencyKey": "jobs-cancel-start"
        }))
        .await;
    let job_resource_id = job_resource_id(&start);
    let cancel = fixture
        .invoke_ok(json!({
            "operation": "job_cancel",
            "jobResourceId": job_resource_id,
            "reason": "test cancellation",
            "idempotencyKey": "jobs-cancel-stop"
        }))
        .await;
    assert_eq!(jobs_details(&cancel)["status"], json!("cancel_requested"));
    let cancelled = fixture.wait_for_state(&job_resource_id, "cancelled").await;
    assert!(
        jobs_details(&cancelled)["job"]["output"]["outputResourceId"]
            .as_str()
            .is_some()
    );

    let replay = fixture
        .invoke_ok(json!({
            "operation": "job_cancel",
            "jobResourceId": job_resource_id,
            "reason": "test cancellation replay",
            "idempotencyKey": "jobs-cancel-stop-replay"
        }))
        .await;
    assert_eq!(jobs_details(&replay)["status"], json!("already_terminal"));
    assert_eq!(jobs_details(&replay)["idempotent"], json!(true));

    let status = fixture
        .invoke_ok(json!({
            "operation": "job_status",
            "jobResourceId": job_resource_id
        }))
        .await;
    assert_eq!(jobs_details(&status)["job"]["state"], json!("cancelled"));
}

#[tokio::test]
async fn job_timeout_records_terminal_output_evidence() {
    let ctx = make_test_context();
    let root = tempdir().expect("root");
    if !sandbox_available() {
        return;
    }

    let fixture = ExecuteFixture::new(&ctx, root.path(), "jobs-timeout").await;
    let start = fixture
        .invoke_ok(json!({
            "operation": "job_start",
            "command": "printf before-timeout; sleep 10",
            "timeoutMs": 100,
            "maxOutputBytes": 1000,
            "idempotencyKey": "jobs-timeout-start"
        }))
        .await;
    let job_resource_id = job_resource_id(&start);
    let status = fixture.wait_for_state(&job_resource_id, "timed_out").await;
    let job = &jobs_details(&status)["job"];
    assert_eq!(job["terminal"]["timedOut"], json!(true));
    assert_eq!(job["output"]["stdoutPreview"], json!("before-timeout"));
    assert!(job["output"]["outputResourceId"].as_str().is_some());
}

#[tokio::test]
async fn background_child_inherited_pipe_is_killed_at_timeout() {
    let ctx = make_test_context();
    let root = tempdir().expect("root");
    if !sandbox_available() {
        return;
    }

    let fixture = ExecuteFixture::new(&ctx, root.path(), "jobs-background-timeout").await;
    let start = fixture
        .invoke_ok(json!({
            "operation": "job_start",
            "command": "printf parent-done; (sleep 10) &",
            "timeoutMs": 150,
            "maxOutputBytes": 1000,
            "idempotencyKey": "jobs-background-timeout-start"
        }))
        .await;
    let job_resource_id = job_resource_id(&start);
    let started = Instant::now();
    let status = fixture.wait_for_state(&job_resource_id, "timed_out").await;
    assert!(
        started.elapsed() < Duration::from_secs(3),
        "background inherited-pipe job should not wait for the child sleep"
    );
    let job = &jobs_details(&status)["job"];
    assert_eq!(job["output"]["stdoutPreview"], json!("parent-done"));
    assert_eq!(job["terminal"]["timedOut"], json!(true));
}

#[tokio::test]
async fn cancel_after_process_exit_preserves_completion_and_output() {
    let ctx = make_test_context();
    let root = tempdir().expect("root");
    if !sandbox_available() {
        return;
    }

    let fixture = ExecuteFixture::new(&ctx, root.path(), "jobs-cancel-race").await;
    let marker = root.path().join("done");
    let start = fixture
        .invoke_ok(json!({
            "operation": "job_start",
            "command": "dd if=/dev/zero bs=1024 count=2048 2>/dev/null | tr '\\0' x; touch done",
            "timeoutMs": 5000,
            "maxOutputBytes": 64,
            "idempotencyKey": "jobs-cancel-race-start"
        }))
        .await;
    let job_resource_id = job_resource_id(&start);
    wait_for_path(&marker).await;
    tokio::time::sleep(Duration::from_millis(100)).await;

    let cancel = fixture
        .invoke_ok(json!({
            "operation": "job_cancel",
            "jobResourceId": job_resource_id,
            "reason": "late cancel should not overwrite completion",
            "idempotencyKey": "jobs-cancel-race-stop"
        }))
        .await;
    assert!(
        matches!(
            jobs_details(&cancel)["status"].as_str(),
            Some("completion_pending" | "already_terminal")
        ),
        "late cancel must not report a delivered cancellation: {}",
        jobs_details(&cancel)
    );
    let status = fixture.wait_for_state(&job_resource_id, "completed").await;
    let job = &jobs_details(&status)["job"];
    assert_eq!(job["state"], json!("completed"));
    assert_eq!(job["terminal"]["cancelled"], json!(false));
    assert_eq!(job["output"]["stdoutPreview"].as_str().unwrap().len(), 64);
    assert!(job["output"]["outputResourceId"].as_str().is_some());
}

#[tokio::test]
async fn shutdown_cancels_running_job_and_records_terminal_state() {
    let ctx = make_test_context();
    let root = tempdir().expect("root");
    if !sandbox_available() {
        return;
    }

    let shutdown = Arc::new(ShutdownCoordinator::new());
    let runtime = super::runtime::JobRuntime::default();
    let runtime_for_shutdown = runtime.clone();
    shutdown.register_phase_callback(ShutdownPhase::Capabilities, "jobs-test", move || {
        let runtime = runtime_for_shutdown.clone();
        async move {
            runtime.cancel_all("server_shutdown").await;
        }
    });

    let fixture = ExecuteFixture::new(&ctx, root.path(), "jobs-shutdown").await;
    let marker = root.path().join("started");
    let payload = json!({
        "command": "printf shutdown-started; touch started; sleep 10",
        "timeoutMs": 10000,
        "maxOutputBytes": 1000
    });
    let invocation = Invocation::new_sync(
        FunctionId::new(super::START_FUNCTION).unwrap(),
        payload,
        execute_context(
            fixture.actor_id.clone(),
            fixture.grant_id.clone(),
            fixture.trace_id.clone(),
            &fixture.session_id,
            &fixture.workspace_id,
            fixture.root,
            Some("jobs-shutdown-start"),
        ),
    );
    let start = super::service::start_job_value(
        &ctx.engine_host,
        Some(shutdown.clone()),
        runtime,
        &invocation,
        &invocation.payload,
    )
    .await
    .expect("direct job start");
    let job_resource_id = start["jobResourceId"].as_str().unwrap().to_owned();

    wait_for_path(&marker).await;
    shutdown
        .graceful_shutdown(Vec::new(), Some(Duration::from_secs(3)))
        .await;

    let status = fixture.wait_for_state(&job_resource_id, "cancelled").await;
    let job = &jobs_details(&status)["job"];
    assert_eq!(job["terminal"]["cancelled"], json!(true));
    assert_eq!(job["cancellation"]["reason"], json!("server_shutdown"));
    assert_eq!(job["output"]["stdoutPreview"], json!("shutdown-started"));
}

struct ExecuteFixture<'a> {
    ctx: &'a ServerRuntimeContext,
    actor_id: ActorId,
    grant_id: AuthorityGrantId,
    trace_id: TraceId,
    session_id: String,
    workspace_id: String,
    root: &'a Path,
}

impl<'a> ExecuteFixture<'a> {
    async fn new(ctx: &'a ServerRuntimeContext, root: &'a Path, key: &str) -> Self {
        let session_id = format!("{key}-session");
        let workspace_id = format!("{key}-workspace");
        let trace_id = TraceId::new(key).unwrap();
        let actor_id = ActorId::new(format!("agent:{session_id}")).unwrap();
        let grant_id = derive_execute_grant(
            ctx,
            &actor_id,
            trace_id.clone(),
            &session_id,
            &workspace_id,
            root,
            "none",
            40,
        )
        .await;
        Self {
            ctx,
            actor_id,
            grant_id,
            trace_id,
            session_id,
            workspace_id,
            root,
        }
    }

    async fn invoke_ok(&self, payload: Value) -> Value {
        let idempotency_key = payload
            .get("idempotencyKey")
            .and_then(Value::as_str)
            .map(str::to_owned);
        invoke_ok(
            self.ctx,
            payload,
            execute_context(
                self.actor_id.clone(),
                self.grant_id.clone(),
                self.trace_id.clone(),
                &self.session_id,
                &self.workspace_id,
                self.root,
                idempotency_key.as_deref(),
            ),
        )
        .await
    }

    async fn invoke_error(&self, payload: Value) -> String {
        let idempotency_key = payload
            .get("idempotencyKey")
            .and_then(Value::as_str)
            .map(str::to_owned);
        invoke_error(
            self.ctx,
            payload,
            execute_context(
                self.actor_id.clone(),
                self.grant_id.clone(),
                self.trace_id.clone(),
                &self.session_id,
                &self.workspace_id,
                self.root,
                idempotency_key.as_deref(),
            ),
        )
        .await
    }

    async fn wait_for_state(&self, job_resource_id: &str, state: &str) -> Value {
        for _ in 0..100 {
            let status = self
                .invoke_ok(json!({
                    "operation": "job_status",
                    "jobResourceId": job_resource_id
                }))
                .await;
            if jobs_details(&status)["job"]["state"] == json!(state) {
                return status;
            }
            tokio::time::sleep(std::time::Duration::from_millis(20)).await;
        }
        panic!("job {job_resource_id} did not reach {state}");
    }
}

async fn invoke_ok(
    ctx: &ServerRuntimeContext,
    payload: Value,
    causal_context: CausalContext,
) -> Value {
    let result = invoke(ctx, payload, causal_context).await;
    assert_eq!(
        result.error, None,
        "expected ok invocation, got {:?}",
        result.error
    );
    result.value.expect("value")
}

async fn invoke_error(
    ctx: &ServerRuntimeContext,
    payload: Value,
    causal_context: CausalContext,
) -> String {
    let result = invoke(ctx, payload, causal_context).await;
    result.error.expect("error").to_string()
}

async fn invoke(
    ctx: &ServerRuntimeContext,
    payload: Value,
    causal_context: CausalContext,
) -> InvocationResult {
    ctx.engine_host
        .invoke(Invocation::new_sync(
            FunctionId::new("capability::execute").unwrap(),
            payload,
            causal_context,
        ))
        .await
}

fn execute_context(
    actor_id: ActorId,
    grant_id: AuthorityGrantId,
    trace_id: TraceId,
    session_id: &str,
    workspace_id: &str,
    root: &Path,
    idempotency_key: Option<&str>,
) -> CausalContext {
    let mut context = CausalContext::new(actor_id, ActorKind::Agent, grant_id, trace_id)
        .with_scope("capability.execute")
        .with_session_id(session_id)
        .with_workspace_id(workspace_id)
        .with_runtime_metadata(
            RUNTIME_METADATA_WORKING_DIRECTORY,
            root.display().to_string(),
        )
        .with_runtime_metadata(RUNTIME_METADATA_PROVIDER_INVOCATION_ID, "provider-jobs")
        .with_runtime_metadata(RUNTIME_METADATA_PROVIDER_TYPE, "openai")
        .with_runtime_metadata(RUNTIME_METADATA_MODEL_PRIMITIVE_NAME, "execute")
        .with_runtime_metadata(RUNTIME_METADATA_RUN_ID, "run-jobs")
        .with_runtime_metadata(RUNTIME_METADATA_TURN, "1");
    if let Some(idempotency_key) = idempotency_key {
        context = context.with_idempotency_key(idempotency_key.to_owned());
    }
    context
}

fn cleanup_invocation(root: &Path, key: &str) -> Invocation {
    cleanup_invocation_for(root, key, "jobs-cleanup-session", "jobs-cleanup-workspace")
}

fn cleanup_invocation_for(
    root: &Path,
    key: &str,
    session_id: &str,
    workspace_id: &str,
) -> Invocation {
    Invocation::new_sync(
        FunctionId::new(super::CLEANUP_FUNCTION).unwrap(),
        json!({}),
        CausalContext::new(
            ActorId::new("engine-client").unwrap(),
            ActorKind::Client,
            AuthorityGrantId::new("engine-transport").unwrap(),
            TraceId::new(key).unwrap(),
        )
        .with_scope(super::WRITE_SCOPE)
        .with_session_id(session_id)
        .with_workspace_id(workspace_id)
        .with_runtime_metadata(
            RUNTIME_METADATA_WORKING_DIRECTORY,
            root.display().to_string(),
        )
        .with_idempotency_key(key),
    )
}

async fn derive_execute_grant(
    ctx: &ServerRuntimeContext,
    actor_id: &ActorId,
    trace_id: TraceId,
    session_id: &str,
    workspace_id: &str,
    root: &Path,
    network_policy: &str,
    remaining_invocations: u64,
) -> AuthorityGrantId {
    let result = ctx
        .engine_host
        .invoke(Invocation::new_sync(
            FunctionId::new("grant::derive").unwrap(),
            json!({
                "parentGrantId": "agent-capability-runtime",
                "subjectActorId": actor_id.as_str(),
                "allowedCapabilities": ["capability::execute"],
                "allowedNamespaces": ["__no_namespace_authority__"],
                "allowedAuthorityScopes": ["capability.execute"],
                "allowedResourceKinds": ["agent_state"],
                "resourceSelectors": ["kind:agent_state"],
                "fileRoots": [root.display().to_string()],
                "networkPolicy": network_policy,
                "maxRisk": "medium",
                "budget": {"remainingInvocations": remaining_invocations},
                "canDelegate": false,
                "provenance": {"source": "jobs_test"}
            }),
            CausalContext::new(
                ActorId::new("system:jobs-test").unwrap(),
                ActorKind::System,
                AuthorityGrantId::new("grant").unwrap(),
                trace_id,
            )
            .with_scope("grant.write")
            .with_session_id(session_id)
            .with_idempotency_key(format!("derive-{workspace_id}-{network_policy}")),
        ))
        .await;
    assert_eq!(
        result.error, None,
        "grant derive failed: {:?}",
        result.error
    );
    AuthorityGrantId::new(
        result.value.unwrap()["grant"]["grantId"]
            .as_str()
            .unwrap()
            .to_owned(),
    )
    .unwrap()
}

async fn create_stale_running_job_resource(
    ctx: &ServerRuntimeContext,
    fixture: &ExecuteFixture<'_>,
    job_resource_id: &str,
) {
    create_running_job_resource_at(
        ctx,
        fixture,
        job_resource_id,
        Utc::now() - ChronoDuration::minutes(5),
    )
    .await;
}

async fn create_running_job_resource_at(
    ctx: &ServerRuntimeContext,
    fixture: &ExecuteFixture<'_>,
    job_resource_id: &str,
    started_at: chrono::DateTime<Utc>,
) {
    let record = super::types::JobProcessRecord {
        schema_version: super::types::JOB_SCHEMA_VERSION.to_owned(),
        state: super::types::JobState::Running,
        command: super::types::JobCommandRecord {
            kind: "shell_command".to_owned(),
            command: "sleep 600".to_owned(),
            working_directory: super::types::JobWorkingDirectory {
                root: "trusted_runtime_metadata".to_owned(),
                canonical_path: fixture.root.display().to_string(),
            },
            network_policy: "none".to_owned(),
        },
        authority: super::types::JobAuthorityRecord {
            actor_id: fixture.actor_id.as_str().to_owned(),
            authority_grant_id: fixture.grant_id.as_str().to_owned(),
            authority_scopes: vec!["capability.execute".to_owned()],
            session_id: Some(fixture.session_id.clone()),
            workspace_id: Some(fixture.workspace_id.clone()),
        },
        limits: super::types::JobLimitsRecord {
            timeout_ms: 60_000,
            max_output_bytes: 1000,
        },
        retention: json!({
            "mode": "explicit",
            "cleanupAfterSeconds": Value::Null
        }),
        created_at: started_at,
        started_at,
        completed_at: None,
        cancellation: super::types::JobCancellationRecord {
            requested: false,
            requested_at: None,
            requested_by: None,
            reason: None,
        },
        terminal: None,
        output: None,
        trace_refs: vec![json!({
            "traceId": fixture.trace_id.as_str(),
            "invocationId": "stale-before-restart",
            "functionId": super::START_FUNCTION
        })],
        replay_refs: vec![json!({
            "kind": "engine_invocation",
            "invocationId": "stale-before-restart",
            "traceId": fixture.trace_id.as_str()
        })],
        revision: 1,
    };
    ctx.engine_host
        .create_resource(CreateResource {
            resource_id: Some(job_resource_id.to_owned()),
            kind: super::JOB_PROCESS_KIND.to_owned(),
            schema_id: Some(super::JOB_PROCESS_SCHEMA_ID.to_owned()),
            scope: EngineResourceScope::Session(fixture.session_id.clone()),
            owner_worker_id: WorkerId::new(super::WORKER).unwrap(),
            owner_actor_id: fixture.actor_id.clone(),
            lifecycle: Some(super::types::JobState::Running.as_str().to_owned()),
            policy: super::support::resource_policy(),
            initial_payload: Some(serde_json::to_value(record).expect("job record payload")),
            locations: Vec::new(),
            trace_id: fixture.trace_id.clone(),
            invocation_id: None,
        })
        .await
        .expect("create stale job resource");
}

fn job_resource_id(value: &Value) -> String {
    jobs_details(value)["jobResourceId"]
        .as_str()
        .expect("job resource id")
        .to_owned()
}

fn jobs_details(value: &Value) -> &Value {
    &value["details"]["jobs"]
}

async fn wait_for_path(path: &Path) {
    for _ in 0..100 {
        if path.exists() {
            return;
        }
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    panic!("path {} was not created", path.display());
}

#[cfg(target_os = "macos")]
fn sandbox_available() -> bool {
    Path::new("/usr/bin/sandbox-exec").exists()
}

#[cfg(not(target_os = "macos"))]
fn sandbox_available() -> bool {
    false
}
