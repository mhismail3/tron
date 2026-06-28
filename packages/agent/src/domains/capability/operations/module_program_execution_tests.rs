use std::path::Path;

use chrono::Utc;
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use tempfile::tempdir;

use crate::domains::session::event_store::AgentTraceListOptions;
use crate::engine::{
    ActorId, ActorKind, AuthorityGrantId, CausalContext, CreateResource, DeriveGrant,
    EngineResourceLocation, EngineResourceScope, FunctionId, Invocation,
    MODULE_LIFECYCLE_STATE_KIND, MODULE_LIFECYCLE_STATE_SCHEMA_ID,
    RUNTIME_METADATA_MODEL_PRIMITIVE_NAME, RUNTIME_METADATA_PROVIDER_INVOCATION_ID,
    RUNTIME_METADATA_PROVIDER_TYPE, RUNTIME_METADATA_RUN_ID, RUNTIME_METADATA_TURN,
    RUNTIME_METADATA_WORKING_DIRECTORY, RiskLevel, TraceId, WorkerId,
};
use crate::shared::server::context::ServerRuntimeContext;
use crate::shared::server::test_support::make_test_context;

#[tokio::test]
async fn module_program_execution_start_status_cleanup_are_ref_only_provider_safe() {
    if !sandbox_available() {
        return;
    }

    let ctx = make_test_context();
    let root = tempdir().expect("working directory");
    let fixture = Fixture::new(
        &ctx,
        root.path(),
        "module-program-execution",
        "module-runtime-request-1",
    )
    .await;

    let start = fixture
        .invoke_with_grant(
            "start",
            fixture.start_grant().await,
            Some("module-program-execution-start"),
            json!({
                "operation": "module_program_execution_start",
                "moduleLifecycleResourceId": fixture.lifecycle_id,
                "runtimeRequestId": fixture.runtime_request_id,
                "command": "printf slice24b-output",
                "runtimeId": "runtime.shell",
                "languageId": "language.shell",
                "programFingerprint": "sha256:program-execution-fingerprint",
                "networkPolicy": "none",
                "reason": "Run one delegated module job.",
                "timeoutMs": 5000,
                "maxOutputBytes": 1000,
                "idempotencyKey": "module-program-execution-start"
            }),
        )
        .await;
    let start_details = module_details(&start);
    assert_eq!(start_details["status"], json!("running"));
    assert_eq!(
        start_details["providerSafety"]["stdoutPreviewReturned"],
        json!(false)
    );
    assert_eq!(
        start_details["providerSafety"]["rawCommandReturned"],
        json!(false)
    );
    assert_no_provider_leaks("start result", start_details);

    let runtime_resource_id = start_details["moduleRuntime"]["moduleRuntimeResourceId"]
        .as_str()
        .expect("runtime resource id")
        .to_owned();
    assert_eq!(runtime_resource_id, fixture.runtime_resource_id);
    let job_resource_id = start_details["job"]["job"]["jobResourceId"]
        .as_str()
        .expect("job resource id")
        .to_owned();
    let program_resource_id = start_details["programExecution"]["programExecutionResourceId"]
        .as_str()
        .expect("program execution resource id")
        .to_owned();
    let program_payload = fixture
        .ctx
        .engine_host
        .inspect_resource(&program_resource_id)
        .await
        .expect("inspect program resource")
        .expect("program resource")
        .versions
        .last()
        .expect("program version")
        .payload
        .clone();
    assert_no_provider_leaks("program execution payload", &program_payload);

    let status = fixture
        .wait_for_terminal_status(&runtime_resource_id, &job_resource_id)
        .await;
    let status_details = module_details(&status);
    assert_eq!(status_details["status"], json!("completed"));
    let job = &status_details["job"]["job"];
    assert_eq!(job["state"], json!("completed"));
    assert_eq!(job["output"]["kind"], json!("execution_output"));
    assert!(job["output"]["resourceId"].as_str().is_some());
    assert!(job["output"]["contentHash"].as_str().is_some());
    assert_eq!(job["output"]["stdoutPreviewReturned"], json!(false));
    assert_eq!(job["output"]["stderrPreviewReturned"], json!(false));
    assert_eq!(job["output"]["rawOutputReturned"], json!(false));
    assert_no_provider_leaks("status result", status_details);
    let module_runtime_version_id = status_details["moduleRuntime"]["moduleRuntime"]["versionId"]
        .as_str()
        .expect("module runtime version id");

    let cleanup = fixture
        .invoke_with_grant(
            "cleanup",
            fixture
                .cleanup_grant(&runtime_resource_id, &job_resource_id)
                .await,
            Some("module-program-execution-cleanup"),
            json!({
                "operation": "module_program_execution_cleanup",
                "moduleRuntimeResourceId": runtime_resource_id,
                "expectedModuleRuntimeVersionId": module_runtime_version_id,
                "jobResourceId": job_resource_id,
                "expectedJobVersionId": job["jobVersionId"],
                "reason": "Archive terminal delegated module job.",
                "idempotencyKey": "module-program-execution-cleanup"
            }),
        )
        .await;
    let cleanup_details = module_details(&cleanup);
    assert_eq!(cleanup_details["status"], json!("archived"));
    assert_eq!(
        cleanup_details["moduleRuntime"]["moduleRuntime"]["runtime"]["jobDelegated"],
        json!(true)
    );
    assert_eq!(
        cleanup_details["moduleRuntime"]["moduleRuntime"]["supervision"]["cleanup"]["jobCleanupDelegated"],
        json!(true)
    );
    assert_no_provider_leaks("cleanup result", cleanup_details);
    assert_trace_records_are_redacted(&fixture.ctx, &fixture.session_id);
}

#[tokio::test]
async fn module_program_execution_followups_reject_mismatched_runtime_job_pairs_without_mutation() {
    if !sandbox_available() {
        return;
    }

    let ctx = make_test_context();
    let root = tempdir().expect("working directory");
    let fixture = Fixture::new(
        &ctx,
        root.path(),
        "module-program-execution-binding",
        "module-runtime-request-a",
    )
    .await;

    let runtime_request_a = "module-runtime-request-a";
    let runtime_request_b = "module-runtime-request-b";
    let runtime_a = fixture.runtime_resource_id_for(runtime_request_a);
    let runtime_b = fixture.runtime_resource_id_for(runtime_request_b);
    let start_grant = fixture.start_grant_for(&[&runtime_a, &runtime_b]).await;
    let start_a = fixture
        .start_module_program(
            "start-a",
            start_grant.clone(),
            runtime_request_a,
            "printf binding-a",
            "module-program-execution-binding-a",
        )
        .await;
    let start_b = fixture
        .start_module_program(
            "start-b",
            start_grant,
            runtime_request_b,
            "printf binding-b",
            "module-program-execution-binding-b",
        )
        .await;
    let job_a = job_resource_id_from_start(&start_a);
    let job_b = job_resource_id_from_start(&start_b);

    let status_a = fixture.wait_for_terminal_status(&runtime_a, &job_a).await;
    let status_b = fixture.wait_for_terminal_status(&runtime_b, &job_b).await;
    let runtime_a_version_before = runtime_version_id_from_status(&status_a);
    let job_b_version_before = job_version_id_from_status(&status_b);

    let mismatch_read_grant = fixture
        .followup_grant(
            "mismatch-read",
            &[&runtime_a],
            &[&job_b],
            FollowupAccess::Read,
        )
        .await;
    let status_error = fixture
        .invoke_error_with_grant(
            "mismatch-status",
            mismatch_read_grant,
            json!({
                "operation": "module_program_execution_status",
                "moduleRuntimeResourceId": runtime_a,
                "jobResourceId": job_b
            }),
        )
        .await;
    assert!(
        status_error.contains("runtime/job binding mismatch"),
        "{status_error}"
    );

    let mismatch_cleanup_grant = fixture
        .followup_grant(
            "mismatch-cleanup",
            &[&runtime_a],
            &[&job_b],
            FollowupAccess::Write,
        )
        .await;
    let cleanup_error = fixture
        .invoke_error_with_grant(
            "mismatch-cleanup",
            mismatch_cleanup_grant,
            json!({
                "operation": "module_program_execution_cleanup",
                "moduleRuntimeResourceId": runtime_a,
                "expectedModuleRuntimeVersionId": runtime_a_version_before,
                "jobResourceId": job_b,
                "expectedJobVersionId": job_b_version_before,
                "reason": "Attempt mismatched cleanup.",
                "idempotencyKey": "module-program-execution-mismatch-cleanup"
            }),
        )
        .await;
    assert!(
        cleanup_error.contains("runtime/job binding mismatch"),
        "{cleanup_error}"
    );
    assert_eq!(
        current_resource_version(&fixture, &runtime_a).await,
        runtime_a_version_before
    );
    assert_eq!(
        current_resource_version(&fixture, &job_b).await,
        job_b_version_before
    );

    let runtime_request_c = "module-runtime-request-c";
    let runtime_request_d = "module-runtime-request-d";
    let runtime_c = fixture.runtime_resource_id_for(runtime_request_c);
    let runtime_d = fixture.runtime_resource_id_for(runtime_request_d);
    let running_start_grant = fixture.start_grant_for(&[&runtime_c, &runtime_d]).await;
    let start_c = fixture
        .start_module_program(
            "start-c",
            running_start_grant.clone(),
            runtime_request_c,
            "sleep 5",
            "module-program-execution-binding-c",
        )
        .await;
    let start_d = fixture
        .start_module_program(
            "start-d",
            running_start_grant,
            runtime_request_d,
            "sleep 5",
            "module-program-execution-binding-d",
        )
        .await;
    let job_c = job_resource_id_from_start(&start_c);
    let job_d = job_resource_id_from_start(&start_d);
    let runtime_c_version_before =
        start_details(&start_c)["moduleRuntime"]["moduleRuntimeVersionId"]
            .as_str()
            .expect("runtime c version id")
            .to_owned();
    let job_d_version_before = start_details(&start_d)["job"]["job"]["jobVersionId"]
        .as_str()
        .expect("job d version id")
        .to_owned();

    let mismatch_cancel_grant = fixture
        .followup_grant(
            "mismatch-cancel",
            &[&runtime_c],
            &[&job_d],
            FollowupAccess::Write,
        )
        .await;
    let cancel_error = fixture
        .invoke_error_with_grant(
            "mismatch-cancel",
            mismatch_cancel_grant,
            json!({
                "operation": "module_program_execution_cancel",
                "moduleRuntimeResourceId": runtime_c,
                "expectedModuleRuntimeVersionId": runtime_c_version_before,
                "jobResourceId": job_d,
                "reason": "Attempt mismatched cancel.",
                "idempotencyKey": "module-program-execution-mismatch-cancel"
            }),
        )
        .await;
    assert!(
        cancel_error.contains("runtime/job binding mismatch"),
        "{cancel_error}"
    );
    assert_eq!(
        current_resource_version(&fixture, &runtime_c).await,
        runtime_c_version_before
    );
    assert_eq!(
        current_resource_version(&fixture, &job_d).await,
        job_d_version_before
    );

    let cleanup_grant = fixture
        .followup_grant(
            "cleanup-running-test-jobs",
            &[&runtime_c, &runtime_d],
            &[&job_c, &job_d],
            FollowupAccess::Write,
        )
        .await;
    for (key, runtime_resource_id, runtime_version_id, job_resource_id) in [
        (
            "cancel-c",
            runtime_c.as_str(),
            runtime_c_version_before.as_str(),
            job_c.as_str(),
        ),
        (
            "cancel-d",
            runtime_d.as_str(),
            start_details(&start_d)["moduleRuntime"]["moduleRuntimeVersionId"]
                .as_str()
                .expect("runtime d version id"),
            job_d.as_str(),
        ),
    ] {
        let _ = fixture
            .invoke_with_grant(
                key,
                cleanup_grant.clone(),
                None,
                json!({
                    "operation": "module_program_execution_cancel",
                    "moduleRuntimeResourceId": runtime_resource_id,
                    "expectedModuleRuntimeVersionId": runtime_version_id,
                    "jobResourceId": job_resource_id,
                    "reason": "Cancel long-running test job.",
                    "idempotencyKey": format!("module-program-execution-{key}")
                }),
            )
            .await;
    }
}

struct Fixture<'a> {
    ctx: &'a ServerRuntimeContext,
    root: &'a Path,
    session_id: String,
    workspace_id: String,
    actor_id: ActorId,
    lifecycle_id: String,
    runtime_request_id: String,
    runtime_resource_id: String,
}

impl<'a> Fixture<'a> {
    async fn new(
        ctx: &'a ServerRuntimeContext,
        root: &'a Path,
        label: &str,
        runtime_request_id: &str,
    ) -> Self {
        let session_id = format!("{label}-session");
        let workspace_id = format!("{label}-workspace");
        let actor_id = ActorId::new(format!("agent:{session_id}")).unwrap();
        let lifecycle_id = format!("module_lifecycle_state:{label}");
        let runtime_resource_id =
            runtime_resource_id(&session_id, &lifecycle_id, runtime_request_id);
        seed_enabled_lifecycle(ctx, &session_id, &lifecycle_id).await;
        Self {
            ctx,
            root,
            session_id,
            workspace_id,
            actor_id,
            lifecycle_id,
            runtime_request_id: runtime_request_id.to_owned(),
            runtime_resource_id,
        }
    }

    async fn start_grant(&self) -> AuthorityGrantId {
        self.start_grant_for(&[&self.runtime_resource_id]).await
    }

    async fn start_grant_for(&self, runtime_resource_ids: &[&str]) -> AuthorityGrantId {
        let mut selectors = vec![
            "kind:module_runtime_state".to_owned(),
            "kind:module_lifecycle_state".to_owned(),
            "kind:program_execution_record".to_owned(),
            "kind:job_process".to_owned(),
            "kind:execution_output".to_owned(),
            format!("resource:{}", self.lifecycle_id),
        ];
        selectors.extend(
            runtime_resource_ids
                .iter()
                .map(|resource_id| format!("resource:{resource_id}")),
        );
        let selector_refs = selectors.iter().map(String::as_str).collect::<Vec<_>>();
        self.derive_grant(
            &format!("start-{}", short_fingerprint(runtime_resource_ids)),
            &[
                "capability.execute",
                "module_runtime.read",
                "module_runtime.write",
                "program_execution.read",
                "program_execution.write",
                "jobs.read",
                "jobs.write",
                "resource.read",
                "resource.write",
            ],
            &[
                "module_runtime_state",
                "module_lifecycle_state",
                "program_execution_record",
                "job_process",
                "execution_output",
            ],
            &selector_refs,
        )
        .await
    }

    async fn status_grant(
        &self,
        runtime_resource_id: &str,
        job_resource_id: &str,
    ) -> AuthorityGrantId {
        self.followup_grant(
            &format!(
                "status-{}",
                short_fingerprint(&[runtime_resource_id, job_resource_id])
            ),
            &[runtime_resource_id],
            &[job_resource_id],
            FollowupAccess::Read,
        )
        .await
    }

    async fn cleanup_grant(
        &self,
        runtime_resource_id: &str,
        job_resource_id: &str,
    ) -> AuthorityGrantId {
        self.followup_grant(
            &format!(
                "cleanup-{}",
                short_fingerprint(&[runtime_resource_id, job_resource_id])
            ),
            &[runtime_resource_id],
            &[job_resource_id],
            FollowupAccess::Write,
        )
        .await
    }

    async fn followup_grant(
        &self,
        suffix: &str,
        runtime_resource_ids: &[&str],
        job_resource_ids: &[&str],
        access: FollowupAccess,
    ) -> AuthorityGrantId {
        let mut scopes = vec![
            "capability.execute",
            "module_runtime.read",
            "program_execution.read",
            "jobs.read",
            "resource.read",
        ];
        if access == FollowupAccess::Write {
            scopes.extend(["module_runtime.write", "jobs.write", "resource.write"]);
        }
        let mut selectors = vec![
            "kind:module_runtime_state".to_owned(),
            "kind:program_execution_record".to_owned(),
            "kind:job_process".to_owned(),
            "kind:execution_output".to_owned(),
        ];
        selectors.extend(
            runtime_resource_ids
                .iter()
                .map(|resource_id| format!("resource:{resource_id}")),
        );
        selectors.extend(
            job_resource_ids
                .iter()
                .map(|resource_id| format!("resource:{resource_id}")),
        );
        let selector_refs = selectors.iter().map(String::as_str).collect::<Vec<_>>();
        self.derive_grant(
            suffix,
            &scopes,
            &[
                "module_runtime_state",
                "program_execution_record",
                "job_process",
                "execution_output",
            ],
            &selector_refs,
        )
        .await
    }

    async fn start_module_program(
        &self,
        key: &str,
        grant_id: AuthorityGrantId,
        runtime_request_id: &str,
        command: &str,
        idempotency_key: &str,
    ) -> Value {
        self.invoke_with_grant(
            key,
            grant_id,
            Some(idempotency_key),
            json!({
                "operation": "module_program_execution_start",
                "moduleLifecycleResourceId": self.lifecycle_id,
                "runtimeRequestId": runtime_request_id,
                "command": command,
                "runtimeId": "runtime.shell",
                "languageId": "language.shell",
                "programFingerprint": format!("sha256:{runtime_request_id}"),
                "networkPolicy": "none",
                "reason": "Run one delegated module job.",
                "timeoutMs": 10000,
                "maxOutputBytes": 1000,
                "idempotencyKey": idempotency_key
            }),
        )
        .await
    }

    async fn wait_for_terminal_status(
        &self,
        runtime_resource_id: &str,
        job_resource_id: &str,
    ) -> Value {
        let grant_id = self
            .status_grant(runtime_resource_id, job_resource_id)
            .await;
        for index in 0..100 {
            let status = self
                .invoke_with_grant(
                    &format!("status-{index}"),
                    grant_id.clone(),
                    None,
                    json!({
                        "operation": "module_program_execution_status",
                        "moduleRuntimeResourceId": runtime_resource_id,
                        "jobResourceId": job_resource_id
                    }),
                )
                .await;
            if module_details(&status)["status"] == json!("completed") {
                return status;
            }
            tokio::time::sleep(std::time::Duration::from_millis(20)).await;
        }
        panic!("module program execution job did not complete");
    }

    async fn invoke_with_grant(
        &self,
        key: &str,
        grant_id: AuthorityGrantId,
        idempotency_key: Option<&str>,
        payload: Value,
    ) -> Value {
        let result = self
            .ctx
            .engine_host
            .invoke(Invocation::new_sync(
                FunctionId::new("capability::execute").unwrap(),
                payload,
                self.context(key, grant_id, idempotency_key),
            ))
            .await;
        assert_eq!(
            result.error, None,
            "expected module program execution invocation to succeed, got {:?}",
            result.error
        );
        result.value.expect("invoke value")
    }

    async fn invoke_error_with_grant(
        &self,
        key: &str,
        grant_id: AuthorityGrantId,
        payload: Value,
    ) -> String {
        let result = self
            .ctx
            .engine_host
            .invoke(Invocation::new_sync(
                FunctionId::new("capability::execute").unwrap(),
                payload,
                self.context(key, grant_id, None),
            ))
            .await;
        result.error.expect("expected invocation error").to_string()
    }

    fn runtime_resource_id_for(&self, runtime_request_id: &str) -> String {
        runtime_resource_id(&self.session_id, &self.lifecycle_id, runtime_request_id)
    }

    async fn derive_grant(
        &self,
        suffix: &str,
        scopes: &[&str],
        resource_kinds: &[&str],
        selectors: &[&str],
    ) -> AuthorityGrantId {
        let grant = self
            .ctx
            .engine_host
            .derive_authority_grant(DeriveGrant {
                grant_id: Some(
                    AuthorityGrantId::new(format!("module-program-execution-{suffix}")).unwrap(),
                ),
                parent_grant_id: AuthorityGrantId::new("agent-capability-runtime").unwrap(),
                subject_actor_id: Some(self.actor_id.clone()),
                subject_worker_id: None,
                subject_invocation_id: None,
                allowed_capabilities: vec!["capability::execute".to_owned()],
                allowed_namespaces: vec!["__no_namespace_authority__".to_owned()],
                allowed_authority_scopes: scopes.iter().map(|scope| (*scope).to_owned()).collect(),
                allowed_resource_kinds: resource_kinds
                    .iter()
                    .map(|kind| (*kind).to_owned())
                    .collect(),
                resource_selectors: selectors
                    .iter()
                    .map(|selector| (*selector).to_owned())
                    .collect(),
                file_roots: vec![self.root.display().to_string()],
                network_policy: "none".to_owned(),
                max_risk: RiskLevel::Medium,
                budget: json!({"remainingInvocations": 250, "remainingProcessMs": 120000}),
                expires_at: None,
                can_delegate: false,
                provenance: json!({"source": "module_program_execution_test"}),
                trace_id: TraceId::new(format!("trace-module-program-grant-{suffix}")).unwrap(),
            })
            .await
            .expect("derive module program execution grant");
        grant.grant_id
    }

    fn context(
        &self,
        key: &str,
        grant_id: AuthorityGrantId,
        idempotency_key: Option<&str>,
    ) -> CausalContext {
        let mut context = CausalContext::new(
            self.actor_id.clone(),
            ActorKind::Agent,
            grant_id,
            TraceId::new(format!("trace-module-program-execution-{key}")).unwrap(),
        )
        .with_scope("capability.execute")
        .with_scope("module_runtime.read")
        .with_scope("module_runtime.write")
        .with_scope("program_execution.read")
        .with_scope("program_execution.write")
        .with_scope("jobs.read")
        .with_scope("jobs.write")
        .with_scope("resource.read")
        .with_scope("resource.write")
        .with_session_id(self.session_id.clone())
        .with_workspace_id(self.workspace_id.clone())
        .with_runtime_metadata(
            RUNTIME_METADATA_WORKING_DIRECTORY,
            self.root.display().to_string(),
        )
        .with_runtime_metadata(
            RUNTIME_METADATA_PROVIDER_INVOCATION_ID,
            "provider-module-program",
        )
        .with_runtime_metadata(RUNTIME_METADATA_PROVIDER_TYPE, "openai")
        .with_runtime_metadata(RUNTIME_METADATA_MODEL_PRIMITIVE_NAME, "execute")
        .with_runtime_metadata(RUNTIME_METADATA_RUN_ID, "run-module-program")
        .with_runtime_metadata(RUNTIME_METADATA_TURN, "1");
        if let Some(idempotency_key) = idempotency_key {
            context = context.with_idempotency_key(idempotency_key.to_owned());
        }
        context
    }
}

#[derive(Clone, Copy, Eq, PartialEq)]
enum FollowupAccess {
    Read,
    Write,
}

async fn seed_enabled_lifecycle(ctx: &ServerRuntimeContext, session_id: &str, lifecycle_id: &str) {
    ctx.engine_host
        .create_resource(CreateResource {
            resource_id: Some(lifecycle_id.to_owned()),
            kind: MODULE_LIFECYCLE_STATE_KIND.to_owned(),
            schema_id: Some(MODULE_LIFECYCLE_STATE_SCHEMA_ID.to_owned()),
            scope: EngineResourceScope::Session(session_id.to_owned()),
            owner_worker_id: WorkerId::new("module_lifecycle").unwrap(),
            owner_actor_id: ActorId::new(format!("agent:{session_id}")).unwrap(),
            lifecycle: Some("enabled".to_owned()),
            policy: json!({"metadataOnly": true, "networkPolicy": "none"}),
            initial_payload: Some(lifecycle_payload(lifecycle_id)),
            locations: vec![EngineResourceLocation {
                kind: "module_lifecycle_state".to_owned(),
                uri: format!("module-lifecycle-state:{lifecycle_id}"),
                mime_type: Some("application/json".to_owned()),
                size_bytes: None,
            }],
            trace_id: TraceId::new("trace-module-program-lifecycle").unwrap(),
            invocation_id: None,
        })
        .await
        .expect("seed enabled lifecycle");
}

fn lifecycle_payload(lifecycle_id: &str) -> Value {
    let now = Utc::now().to_rfc3339();
    json!({
        "schemaVersion": crate::engine::MODULE_LIFECYCLE_STATE_PAYLOAD_SCHEMA_VERSION,
        "state": "enabled",
        "transitionId": "transition",
        "scope": {"kind": "session", "value": "module-program-execution"},
        "installDecision": {"kind": "module_install_decision", "resourceId": "module_install_decision:accepted", "role": "install_candidate"},
        "transition": {"action": "enable", "to": "enabled", "metadataOnly": true, "executionPerformed": false},
        "previous": {"state": null, "versionId": null, "currentVersionRevalidated": false},
        "approval": {"allowed": true, "rawAuthorityIdsStored": false},
        "rollback": {"proofRefs": [], "status": "not_proven", "metadataOnly": true, "rollbackExecuted": false},
        "runtimeAuthorization": {
            "failClosed": true,
            "enabledAllowsRuntime": true,
            "disabledDenied": false,
            "quarantinedDenied": false,
            "rolledBackDenied": false
        },
        "evidenceRefs": [],
        "traceRefs": [],
        "replayRefs": [],
        "authority": {"rawAuthorityIdsStored": false},
        "idempotency": {"fingerprint": lifecycle_id, "rawKeyStored": false},
        "sideEffectProof": {"metadataOnly": true, "installPerformed": false, "activationPerformed": false, "executionPerformed": false, "rollbackExecuted": false, "dependencyRestorePerformed": false, "packageManagerUsed": false, "networkPolicy": "none", "networkAccessPerformed": false, "repoManagedSkillsTouched": false, "physicalWorkspaceDirectoryCreated": false, "rawCommandsStored": false, "rawLogsStored": false, "fileContentsStored": false, "absolutePathsStored": false},
        "createdAt": now,
        "updatedAt": now,
        "revision": 1
    })
}

fn module_details(result: &Value) -> &Value {
    &result["details"]["moduleProgramExecution"]
}

fn start_details(result: &Value) -> &Value {
    module_details(result)
}

fn job_resource_id_from_start(result: &Value) -> String {
    start_details(result)["job"]["job"]["jobResourceId"]
        .as_str()
        .expect("job resource id")
        .to_owned()
}

fn job_version_id_from_status(result: &Value) -> String {
    module_details(result)["job"]["job"]["jobVersionId"]
        .as_str()
        .expect("job version id")
        .to_owned()
}

fn runtime_version_id_from_status(result: &Value) -> String {
    module_details(result)["moduleRuntime"]["moduleRuntime"]["versionId"]
        .as_str()
        .expect("runtime version id")
        .to_owned()
}

async fn current_resource_version(fixture: &Fixture<'_>, resource_id: &str) -> String {
    fixture
        .ctx
        .engine_host
        .inspect_resource(resource_id)
        .await
        .expect("inspect resource")
        .expect("resource exists")
        .resource
        .current_version_id
        .expect("current version id")
}

fn short_fingerprint(parts: &[&str]) -> String {
    let mut hasher = Sha256::new();
    for part in parts {
        hasher.update(part.as_bytes());
        hasher.update(b"\0");
    }
    hex::encode(hasher.finalize())[..12].to_owned()
}

fn assert_trace_records_are_redacted(ctx: &ServerRuntimeContext, session_id: &str) {
    let records = ctx
        .event_store
        .list_trace_records(&AgentTraceListOptions {
            session_id: Some(session_id),
            trace_id: None,
            limit: Some(100),
        })
        .expect("list trace records");
    assert!(!records.is_empty(), "expected trace records");
    for record in records {
        assert_no_command_output_leaks("trace record", &record.record_json);
        let trace_metadata = &record.record_json["metadata"]["dev.tron"];
        assert_eq!(trace_metadata["rawRequestStored"], json!(false));
        assert_eq!(trace_metadata["request"]["rawPayloadStored"], json!(false));
    }
}

fn assert_no_provider_leaks(label: &str, value: &Value) {
    assert_no_command_output_leaks(label, value);
    let rendered = serde_json::to_string(value).expect("serialize value");
    assert!(
        !rendered.contains("authorityGrantId"),
        "{label} leaked authorityGrantId field: {rendered}"
    );
}

fn assert_no_command_output_leaks(label: &str, value: &Value) {
    let rendered = serde_json::to_string(value).expect("serialize value");
    for forbidden in [
        "printf slice24b-output",
        "slice24b-output",
        "\"stdoutPreview\":\"",
        "\"stderrPreview\":\"",
        "\"stdout\":\"",
        "\"stderr\":\"",
        "\"command\":\"",
        "\"workingDirectory\":\"",
        "raw job",
    ] {
        assert!(
            !rendered.contains(forbidden),
            "{label} leaked {forbidden}: {rendered}"
        );
    }
}

fn runtime_resource_id(
    session_id: &str,
    lifecycle_resource_id: &str,
    runtime_request_id: &str,
) -> String {
    let mut hasher = Sha256::new();
    hasher.update(
        format!("session:{session_id}:{lifecycle_resource_id}:{runtime_request_id}").as_bytes(),
    );
    format!("module_runtime_state:{}", hex::encode(hasher.finalize()))
}

fn sandbox_available() -> bool {
    Path::new("/usr/bin/sandbox-exec").exists()
}
