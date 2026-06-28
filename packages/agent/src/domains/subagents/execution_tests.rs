use serde_json::{Value, json};

use super::execution::{
    cancel_subagent_value, launch_subagent_value, result_subagent_value, status_subagent_value,
};
use super::{Deps, READ_SCOPE, WRITE_SCOPE};
use crate::engine::{
    ActorId, ActorKind, AuthorityGrantId, CausalContext, DeriveGrant, FunctionId, Invocation,
    InvocationId, RiskLevel, SUBAGENT_TASK_KIND, TraceId,
};
use crate::shared::server::test_support::make_test_context;

#[tokio::test]
async fn launch_records_delegated_module_worker_lifecycle_without_parent_merge() {
    let fixture = Fixture::new("launch").await;
    let launched = fixture.launch("launch-key", launch_payload()).await;
    let resource_id = launched["subagentTaskResourceId"].as_str().unwrap();

    assert_eq!(launched["status"], json!("running"));
    assert_eq!(
        launched["execution"]["modelPolicy"],
        json!("accepted_jobs_program_execution_v1")
    );
    assert_eq!(launched["execution"]["workerStarted"], json!(true));
    assert_eq!(launched["execution"]["jobStarted"], json!(true));
    assert_eq!(launched["execution"]["toolExecution"], json!(false));
    assert_eq!(launched["network"]["requiredPolicy"], json!("none"));
    assert_eq!(
        launched["delegation"]["moduleRuntimeRef"]["kind"],
        json!("module_runtime_state")
    );

    let status = fixture.status("launch-status", resource_id).await;
    let task = &status["task"]["payload"];
    assert_eq!(task["state"], json!("running"));
    assert_eq!(task["parent"]["sessionId"], json!(fixture.session_id));
    assert_eq!(
        task["execution"]["modelPolicy"],
        json!("accepted_jobs_program_execution_v1")
    );
    assert_eq!(task["execution"]["worker"]["started"], json!(true));
    assert_eq!(task["execution"]["job"]["jobStarted"], json!(true));
    assert_eq!(task["execution"]["sideEffects"]["network"], json!(false));
    assert_eq!(task["activation"]["workerStarted"], json!(true));
    assert_eq!(task["activation"]["jobStarted"], json!(true));
    assert_eq!(task["activation"]["resultMerged"], json!(false));
    assert_eq!(task["delegation"]["jobRef"]["kind"], json!("job_process"));

    let result = fixture.result("launch-result", resource_id).await;
    assert_eq!(result["status"], json!("running"));
    assert_eq!(result["result"]["status"], json!("running"));
    assert_eq!(result["projection"]["resultMergePerformed"], json!(false));
}

#[tokio::test]
async fn launch_requires_explicit_delegation_policy_and_concurrency_budget() {
    let fixture = Fixture::new("policy").await;
    let mut missing_policy = launch_payload();
    missing_policy
        .as_object_mut()
        .unwrap()
        .remove("modelPolicy");
    let error = fixture.launch_error("missing-policy", missing_policy).await;
    assert!(error.contains("missing modelPolicy"), "{error}");

    let mut unknown_worker = launch_payload();
    unknown_worker["workerKind"] = json!("spawn_anything");
    let error = fixture.launch_error("unknown-worker", unknown_worker).await;
    assert!(error.contains("workerKind"), "{error}");

    let first = fixture.launch("first-running", launch_payload()).await;
    assert_eq!(first["status"], json!("running"));
    let mut second_payload = launch_payload();
    second_payload["taskId"] = json!("task-beta");
    let second = fixture.launch_error("second-running", second_payload).await;
    assert!(second.contains("concurrency limit"), "{second}");
}

#[tokio::test]
async fn launch_is_idempotent_for_same_scope_and_key() {
    let fixture = Fixture::new("idempotent-launch").await;
    let first = fixture.launch("same-launch", launch_payload()).await;
    let second = fixture.launch("same-launch", launch_payload()).await;
    assert_eq!(
        first["subagentTaskResourceId"],
        second["subagentTaskResourceId"]
    );
    assert_eq!(second["idempotentReplay"], json!(true));
}

#[tokio::test]
async fn cancel_uses_freshness_and_is_idempotent_after_terminal_state() {
    let fixture = Fixture::new("cancel").await;
    let launched = fixture.launch("cancel-launch", launch_payload()).await;
    let resource_id = launched["subagentTaskResourceId"].as_str().unwrap();
    let version_id = launched["subagentTaskVersionId"].as_str().unwrap();

    let stale = fixture
        .cancel_error(
            "cancel-stale",
            json!({
                "subagentTaskResourceId": resource_id,
                "expectedSubagentTaskVersionId": "stale-version",
                "reason": "stale should fail"
            }),
        )
        .await;
    assert!(stale.contains("version is stale"), "{stale}");

    let cancelled = fixture
        .cancel(
            "cancel-good",
            json!({
                "subagentTaskResourceId": resource_id,
                "expectedSubagentTaskVersionId": version_id,
                "reason": "user cancelled"
            }),
        )
        .await;
    assert_eq!(cancelled["status"], json!("cancelled"));
    assert_eq!(cancelled["idempotent"], json!(false));

    let replay = fixture
        .cancel(
            "cancel-replay",
            json!({
                "subagentTaskResourceId": resource_id,
                "reason": "already terminal"
            }),
        )
        .await;
    assert_eq!(replay["status"], json!("cancelled"));
    assert_eq!(replay["idempotent"], json!(true));

    let result = fixture.result("cancel-result", resource_id).await;
    assert_eq!(result["result"]["status"], json!("cancelled"));
    assert_eq!(result["execution"]["resultMerged"], json!(false));
}

#[tokio::test]
async fn execution_operations_fail_closed_for_authority_and_scope() {
    let first = Fixture::new("scope-a").await;
    let second = first.clone_for_session("scope-b-session").await;
    let launched = first.launch("scope-launch", launch_payload()).await;
    let resource_id = launched["subagentTaskResourceId"].as_str().unwrap();

    let cross_scope = second
        .status_error("scope-status-denied", resource_id)
        .await;
    assert!(
        cross_scope.contains("outside the current scope"),
        "{cross_scope}"
    );

    let read_only = first
        .derive_grant(
            "read-only-cancel",
            &[READ_SCOPE, "resource.read"],
            &[SUBAGENT_TASK_KIND],
            &["kind:subagent_task"],
            "none",
        )
        .await;
    let read_only_invocation = invocation(
        "capability::execute",
        "read-only-cancel",
        json!({"subagentTaskResourceId": resource_id, "reason": "no write"}),
        read_only,
        ActorKind::Agent,
        Some(&first.session_id),
    );
    let error = cancel_subagent_value(
        &first.deps,
        &read_only_invocation,
        &read_only_invocation.payload,
    )
    .await
    .expect_err("write grant required")
    .to_string();
    assert!(error.contains("subagents.write"), "{error}");

    let wildcard = first
        .derive_grant(
            "wildcard-launch",
            &[READ_SCOPE, WRITE_SCOPE, "resource.read", "resource.write"],
            &[SUBAGENT_TASK_KIND],
            &["*", "kind:subagent_task"],
            "none",
        )
        .await;
    let wildcard_invocation = invocation(
        "capability::execute",
        "wildcard-launch",
        launch_payload(),
        wildcard,
        ActorKind::Agent,
        Some(&first.session_id),
    );
    let error = launch_subagent_value(
        &first.deps,
        &wildcard_invocation,
        &wildcard_invocation.payload,
        &delegated_start_value(),
    )
    .await
    .expect_err("broad selector denied")
    .to_string();
    assert!(error.contains("broad resource selector"), "{error}");
}

#[tokio::test]
async fn execution_validation_rejects_unbounded_or_execution_shaped_evidence() {
    let fixture = Fixture::new("validation").await;
    let mut too_large = launch_payload();
    too_large["evidenceRefs"] = json!([{"kind": "fixture", "id": "x".repeat(9_000)}]);
    let large = fixture.launch_error("too-large", too_large).await;
    assert!(large.contains("exceeds"), "{large}");

    let mut command = launch_payload();
    command["handoffRefs"] = json!([{"command": "run hidden helper"}]);
    let command_error = fixture.launch_error("command", command).await;
    assert!(command_error.contains("handoffRefs"), "{command_error}");

    let mut raw_path = launch_payload();
    raw_path["promptSummary"] = json!("Read /Users/example/private prompt");
    let path_error = fixture.launch_error("raw-path", raw_path).await;
    assert!(path_error.contains("summary-only"), "{path_error}");

    let mut scalar_ref_path = launch_payload();
    scalar_ref_path["sourceRef"] = json!({"kind": "artifact", "path": "/tmp/raw-source"});
    let scalar_ref_error = fixture
        .launch_error("scalar-ref-path", scalar_ref_path)
        .await;
    assert!(
        scalar_ref_error.contains("refs/fingerprints"),
        "{scalar_ref_error}"
    );
}

#[test]
fn static_non_goal_guards_keep_subagent_execution_foundation_narrow() {
    let execution = include_str!("execution.rs");
    for forbidden in [
        "std::process::Command",
        ".spawn(",
        "register_function",
        "register_worker",
        "mcp_start",
        "web_search",
        "browser_",
        "cookie_store",
        "login_session",
        "process_run(",
        "job_start(",
        "worker_lifecycle::launch",
        "tool::execute",
    ] {
        assert!(
            !execution.contains(forbidden),
            "subagent execution must not contain {forbidden}"
        );
    }
}

#[derive(Clone)]
struct Fixture {
    deps: Deps,
    session_id: String,
    read_grant_id: AuthorityGrantId,
    write_grant_id: AuthorityGrantId,
}

impl Fixture {
    async fn new(label: &str) -> Self {
        let ctx = make_test_context();
        let deps = Deps {
            engine_host: ctx.engine_host.clone(),
        };
        let session_id = format!("{label}-session");
        let read_grant_id = derive_grant(
            &deps,
            &format!("{label}-read"),
            &[READ_SCOPE, "resource.read"],
            &[SUBAGENT_TASK_KIND],
            &["kind:subagent_task"],
            "none",
        )
        .await;
        let write_grant_id = derive_grant(
            &deps,
            &format!("{label}-write"),
            &[READ_SCOPE, WRITE_SCOPE, "resource.read", "resource.write"],
            &[SUBAGENT_TASK_KIND],
            &["kind:subagent_task"],
            "none",
        )
        .await;
        Self {
            deps,
            session_id,
            read_grant_id,
            write_grant_id,
        }
    }

    async fn clone_for_session(&self, session_id: &str) -> Self {
        let read_grant_id = self
            .derive_grant(
                &format!("{session_id}-read"),
                &[READ_SCOPE, "resource.read"],
                &[SUBAGENT_TASK_KIND],
                &["kind:subagent_task"],
                "none",
            )
            .await;
        let write_grant_id = self
            .derive_grant(
                &format!("{session_id}-write"),
                &[READ_SCOPE, WRITE_SCOPE, "resource.read", "resource.write"],
                &[SUBAGENT_TASK_KIND],
                &["kind:subagent_task"],
                "none",
            )
            .await;
        Self {
            deps: self.deps.clone(),
            session_id: session_id.to_owned(),
            read_grant_id,
            write_grant_id,
        }
    }

    async fn derive_grant(
        &self,
        suffix: &str,
        scopes: &[&str],
        resource_kinds: &[&str],
        selectors: &[&str],
        network_policy: &str,
    ) -> AuthorityGrantId {
        derive_grant(
            &self.deps,
            suffix,
            scopes,
            resource_kinds,
            selectors,
            network_policy,
        )
        .await
    }

    async fn launch(&self, key: &str, payload: Value) -> Value {
        let invocation = self.write_invocation(key, payload);
        launch_subagent_value(
            &self.deps,
            &invocation,
            &invocation.payload,
            &delegated_start_value(),
        )
        .await
        .expect("launch subagent")
    }

    async fn launch_error(&self, key: &str, payload: Value) -> String {
        let invocation = self.write_invocation(key, payload);
        launch_subagent_value(
            &self.deps,
            &invocation,
            &invocation.payload,
            &delegated_start_value(),
        )
        .await
        .expect_err("launch should fail")
        .to_string()
    }

    async fn status(&self, key: &str, resource_id: &str) -> Value {
        let invocation = self.read_invocation(key, json!({"subagentTaskResourceId": resource_id}));
        status_subagent_value(&self.deps, &invocation, &invocation.payload)
            .await
            .expect("status")
    }

    async fn status_error(&self, key: &str, resource_id: &str) -> String {
        let invocation = self.read_invocation(key, json!({"subagentTaskResourceId": resource_id}));
        status_subagent_value(&self.deps, &invocation, &invocation.payload)
            .await
            .expect_err("status should fail")
            .to_string()
    }

    async fn result(&self, key: &str, resource_id: &str) -> Value {
        let invocation = self.read_invocation(key, json!({"subagentTaskResourceId": resource_id}));
        result_subagent_value(&self.deps, &invocation, &invocation.payload)
            .await
            .expect("result")
    }

    async fn cancel(&self, key: &str, payload: Value) -> Value {
        let invocation = self.write_invocation(key, payload);
        cancel_subagent_value(&self.deps, &invocation, &invocation.payload)
            .await
            .expect("cancel")
    }

    async fn cancel_error(&self, key: &str, payload: Value) -> String {
        let invocation = self.write_invocation(key, payload);
        cancel_subagent_value(&self.deps, &invocation, &invocation.payload)
            .await
            .expect_err("cancel should fail")
            .to_string()
    }

    fn read_invocation(&self, key: &str, payload: Value) -> Invocation {
        invocation(
            "capability::execute",
            key,
            payload,
            self.read_grant_id.clone(),
            ActorKind::Agent,
            Some(&self.session_id),
        )
    }

    fn write_invocation(&self, key: &str, payload: Value) -> Invocation {
        invocation(
            "capability::execute",
            key,
            payload,
            self.write_grant_id.clone(),
            ActorKind::Agent,
            Some(&self.session_id),
        )
    }
}

async fn derive_grant(
    deps: &Deps,
    suffix: &str,
    scopes: &[&str],
    resource_kinds: &[&str],
    selectors: &[&str],
    network_policy: &str,
) -> AuthorityGrantId {
    deps.engine_host
        .derive_authority_grant(DeriveGrant {
            grant_id: Some(AuthorityGrantId::new(format!("subagent-exec-{suffix}")).unwrap()),
            parent_grant_id: AuthorityGrantId::new("engine-system").unwrap(),
            subject_actor_id: None,
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
            file_roots: vec!["/tmp".to_owned()],
            network_policy: network_policy.to_owned(),
            max_risk: RiskLevel::Low,
            budget: json!({"class": "subagent_execution_test"}),
            expires_at: None,
            can_delegate: false,
            provenance: json!({"source": "subagent_execution_test"}),
            trace_id: TraceId::new(format!("trace-subagent-exec-{suffix}")).unwrap(),
        })
        .await
        .expect("derive grant")
        .grant_id
}

fn invocation(
    function_id: &str,
    key: &str,
    payload: Value,
    grant_id: AuthorityGrantId,
    actor_kind: ActorKind,
    session_id: Option<&str>,
) -> Invocation {
    let actor_id = match actor_kind {
        ActorKind::Agent => ActorId::new(format!("agent:{}", session_id.unwrap())).unwrap(),
        ActorKind::System => ActorId::new("system:subagent-exec-test").unwrap(),
        _ => ActorId::new("client:subagent-exec-test").unwrap(),
    };
    let context = CausalContext::new(
        actor_id,
        actor_kind,
        grant_id,
        TraceId::new(format!("trace-{key}")).unwrap(),
    )
    .with_workspace_id("workspace-subagent-exec")
    .with_session_id(session_id.unwrap().to_owned())
    .with_idempotency_key(key.to_owned());
    Invocation {
        id: InvocationId::new(format!("invocation-{key}")).unwrap(),
        function_id: FunctionId::new(function_id).unwrap(),
        delivery_mode: crate::engine::DeliveryMode::Sync,
        payload,
        causal_context: context,
    }
}

fn launch_payload() -> Value {
    json!({
        "taskId": "task-alpha",
        "objectiveSummary": "Investigate a bounded fixture",
        "promptSummary": "Return a summary-only result",
        "modelPolicy": "accepted_jobs_program_execution_v1",
        "workerKind": "module_program_execution",
        "modulePackId": "jobs_program_execution",
        "moduleLifecycleResourceId": "module_lifecycle_state:subagent-test",
        "runtimeRequestId": "subagent-runtime-request",
        "runtimeId": "runtime.shell",
        "languageId": "language.shell",
        "programFingerprint": "sha256:subagent-program",
        "command": "printf subagent",
        "evidenceRefs": [{"kind": "fixture", "id": "evidence-1"}],
        "handoffRefs": [{"kind": "fingerprint", "id": "handoff-1"}],
        "outputRefs": []
    })
}

fn delegated_start_value() -> Value {
    json!({
        "status": "running",
        "moduleRuntime": {
            "moduleRuntimeResourceId": "module_runtime_state:delegated-runtime",
            "moduleRuntimeVersionId": "runtime-version-1"
        },
        "programExecution": {
            "programExecutionResourceId": "program_execution_record:delegated-program",
            "programExecutionVersionId": "program-version-1"
        },
        "job": {
            "job": {
                "jobResourceId": "job_process:delegated-job",
                "jobVersionId": "job-version-1",
                "state": "running"
            }
        }
    })
}
