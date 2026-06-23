use std::path::Path;

use serde_json::{Value, json};
use tempfile::tempdir;

use crate::engine::{
    ActorId, ActorKind, AuthorityGrantId, CausalContext, FunctionId, Invocation, InvocationResult,
    RUNTIME_METADATA_MODEL_PRIMITIVE_NAME, RUNTIME_METADATA_PROVIDER_INVOCATION_ID,
    RUNTIME_METADATA_PROVIDER_TYPE, RUNTIME_METADATA_RUN_ID, RUNTIME_METADATA_TURN,
    RUNTIME_METADATA_WORKING_DIRECTORY, TraceId,
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
    assert_eq!(jobs_details(&cancel)["status"], json!("cancelled"));

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

    tokio::time::sleep(std::time::Duration::from_millis(250)).await;
    let status = fixture
        .invoke_ok(json!({
            "operation": "job_status",
            "jobResourceId": job_resource_id
        }))
        .await;
    assert_eq!(jobs_details(&status)["job"]["state"], json!("cancelled"));
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
        .with_session_id("jobs-cleanup-session")
        .with_workspace_id("jobs-cleanup-workspace")
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

fn job_resource_id(value: &Value) -> String {
    jobs_details(value)["jobResourceId"]
        .as_str()
        .expect("job resource id")
        .to_owned()
}

fn jobs_details(value: &Value) -> &Value {
    &value["details"]["jobs"]
}

#[cfg(target_os = "macos")]
fn sandbox_available() -> bool {
    Path::new("/usr/bin/sandbox-exec").exists()
}

#[cfg(not(target_os = "macos"))]
fn sandbox_available() -> bool {
    false
}
