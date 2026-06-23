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
async fn cancel_request_version_conflict_does_not_drop_runtime_terminal_output() {
    let ctx = make_test_context();
    let root = tempdir().expect("root");
    if !sandbox_available() {
        return;
    }
    super::support::clear_finalize_race_hook();
    let _hook_guard = FinalizeRaceHookGuard;

    let fixture = ExecuteFixture::new(&ctx, root.path()).await;
    let marker = root.path().join("started");
    let start = fixture
        .invoke_ok(json!({
            "operation": "job_start",
            "command": "printf race-start; touch started; while true; do sleep 1; done",
            "timeoutMs": 5000,
            "maxOutputBytes": 1000,
            "idempotencyKey": "jobs-finalize-cancel-race-start"
        }))
        .await;
    let job_resource_id = job_resource_id(&start);
    wait_for_path(&marker).await;
    let hook = super::support::install_finalize_race_hook(job_resource_id.clone());

    let ctx_for_cancel = ctx.clone();
    let cancel_context = fixture.execute_context(Some("jobs-finalize-cancel-race-stop"));
    let cancel_job_resource_id = job_resource_id.clone();
    let cancel_task = tokio::spawn(async move {
        invoke_ok(
            &ctx_for_cancel,
            json!({
                "operation": "job_cancel",
                "jobResourceId": cancel_job_resource_id,
                "reason": "force stale finalization retry",
                "idempotencyKey": "jobs-finalize-cancel-race-stop"
            }),
            cancel_context,
        )
        .await
    });

    hook.wait_for_cancel_after_runtime().await;
    hook.wait_for_finalize_before_update().await;
    hook.release_cancel_after_runtime();
    let cancel = cancel_task.await.expect("cancel task");
    assert_eq!(jobs_details(&cancel)["status"], json!("cancel_requested"));

    hook.release_finalize_before_update();
    let status = fixture.wait_for_state(&job_resource_id, "cancelled").await;
    let job = &jobs_details(&status)["job"];
    assert_eq!(job["terminal"]["cancelled"], json!(true));
    assert_eq!(
        job["cancellation"]["reason"],
        json!("force stale finalization retry")
    );
    assert_eq!(job["output"]["stdoutPreview"], json!("race-start"));
    assert!(job["output"]["outputResourceId"].as_str().is_some());

    let log = fixture
        .invoke_ok(json!({
            "operation": "job_log",
            "jobResourceId": job_resource_id
        }))
        .await;
    assert_eq!(jobs_details(&log)["stdoutPreview"], json!("race-start"));
    assert!(jobs_details(&log)["outputResourceId"].as_str().is_some());
}

struct ExecuteFixture<'a> {
    ctx: &'a ServerRuntimeContext,
    actor_id: ActorId,
    grant_id: AuthorityGrantId,
    trace_id: TraceId,
    root: &'a Path,
}

impl<'a> ExecuteFixture<'a> {
    async fn new(ctx: &'a ServerRuntimeContext, root: &'a Path) -> Self {
        let trace_id = TraceId::new("jobs-finalize-cancel-race").unwrap();
        let actor_id = ActorId::new("agent:jobs-finalize-cancel-race-session").unwrap();
        let grant_id = derive_execute_grant(ctx, &actor_id, trace_id.clone(), root).await;
        Self {
            ctx,
            actor_id,
            grant_id,
            trace_id,
            root,
        }
    }

    async fn invoke_ok(&self, payload: Value) -> Value {
        let key = payload
            .get("idempotencyKey")
            .and_then(Value::as_str)
            .map(str::to_owned);
        invoke_ok(self.ctx, payload, self.execute_context(key.as_deref())).await
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

    fn execute_context(&self, idempotency_key: Option<&str>) -> CausalContext {
        let mut context = CausalContext::new(
            self.actor_id.clone(),
            ActorKind::Agent,
            self.grant_id.clone(),
            self.trace_id.clone(),
        )
        .with_scope("capability.execute")
        .with_session_id("jobs-finalize-cancel-race-session")
        .with_workspace_id("jobs-finalize-cancel-race-workspace")
        .with_runtime_metadata(
            RUNTIME_METADATA_WORKING_DIRECTORY,
            self.root.display().to_string(),
        )
        .with_runtime_metadata(
            RUNTIME_METADATA_PROVIDER_INVOCATION_ID,
            "provider-jobs-race",
        )
        .with_runtime_metadata(RUNTIME_METADATA_PROVIDER_TYPE, "openai")
        .with_runtime_metadata(RUNTIME_METADATA_MODEL_PRIMITIVE_NAME, "execute")
        .with_runtime_metadata(RUNTIME_METADATA_RUN_ID, "run-jobs-race")
        .with_runtime_metadata(RUNTIME_METADATA_TURN, "1");
        if let Some(key) = idempotency_key {
            context = context.with_idempotency_key(key.to_owned());
        }
        context
    }
}

async fn invoke_ok(
    ctx: &ServerRuntimeContext,
    payload: Value,
    causal_context: CausalContext,
) -> Value {
    let result = invoke(ctx, payload, causal_context).await;
    assert_eq!(result.error, None, "expected ok, got {:?}", result.error);
    result.value.expect("value")
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

async fn derive_execute_grant(
    ctx: &ServerRuntimeContext,
    actor_id: &ActorId,
    trace_id: TraceId,
    root: &Path,
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
                "networkPolicy": "none",
                "maxRisk": "medium",
                "budget": {"remainingInvocations": 20},
                "canDelegate": false,
                "provenance": {"source": "jobs_race_test"}
            }),
            CausalContext::new(
                ActorId::new("system:jobs-race-test").unwrap(),
                ActorKind::System,
                AuthorityGrantId::new("grant").unwrap(),
                trace_id,
            )
            .with_scope("grant.write")
            .with_session_id("jobs-finalize-cancel-race-session")
            .with_idempotency_key("derive-jobs-finalize-cancel-race"),
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

async fn wait_for_path(path: &Path) {
    for _ in 0..100 {
        if path.exists() {
            return;
        }
        tokio::time::sleep(std::time::Duration::from_millis(20)).await;
    }
    panic!("path {} was not created", path.display());
}

struct FinalizeRaceHookGuard;

impl Drop for FinalizeRaceHookGuard {
    fn drop(&mut self) {
        super::support::clear_finalize_race_hook();
    }
}

#[cfg(target_os = "macos")]
fn sandbox_available() -> bool {
    Path::new("/usr/bin/sandbox-exec").exists()
}

#[cfg(not(target_os = "macos"))]
fn sandbox_available() -> bool {
    false
}
