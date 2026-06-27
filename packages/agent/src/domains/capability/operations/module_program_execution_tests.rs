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
        self.derive_grant(
            "start",
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
            &[
                "kind:module_runtime_state",
                "kind:module_lifecycle_state",
                "kind:program_execution_record",
                "kind:job_process",
                "kind:execution_output",
                &format!("resource:{}", self.lifecycle_id),
                &format!("resource:{}", self.runtime_resource_id),
            ],
        )
        .await
    }

    async fn status_grant(
        &self,
        runtime_resource_id: &str,
        job_resource_id: &str,
    ) -> AuthorityGrantId {
        self.derive_grant(
            "status",
            &[
                "capability.execute",
                "module_runtime.read",
                "program_execution.read",
                "jobs.read",
                "resource.read",
            ],
            &[
                "module_runtime_state",
                "program_execution_record",
                "job_process",
                "execution_output",
            ],
            &[
                "kind:module_runtime_state",
                "kind:program_execution_record",
                "kind:job_process",
                "kind:execution_output",
                &format!("resource:{runtime_resource_id}"),
                &format!("resource:{job_resource_id}"),
            ],
        )
        .await
    }

    async fn cleanup_grant(
        &self,
        runtime_resource_id: &str,
        job_resource_id: &str,
    ) -> AuthorityGrantId {
        self.derive_grant(
            "cleanup",
            &[
                "capability.execute",
                "module_runtime.read",
                "module_runtime.write",
                "program_execution.read",
                "jobs.read",
                "jobs.write",
                "resource.read",
                "resource.write",
            ],
            &[
                "module_runtime_state",
                "program_execution_record",
                "job_process",
                "execution_output",
            ],
            &[
                "kind:module_runtime_state",
                "kind:program_execution_record",
                "kind:job_process",
                "kind:execution_output",
                &format!("resource:{runtime_resource_id}"),
                &format!("resource:{job_resource_id}"),
            ],
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
