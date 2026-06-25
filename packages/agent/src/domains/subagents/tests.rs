use serde_json::{Value, json};

use super::projection::PROJECTION_STRING_BYTES;
use super::service::{
    create_task_value, inspect_subagent_task_value, list_subagent_tasks_value, update_task_value,
};
use super::validation::{MAX_REF_ITEMS, MAX_SUMMARY_BYTES};
use super::{CREATE_TASK_FUNCTION, Deps, READ_SCOPE, UPDATE_TASK_FUNCTION, WRITE_SCOPE};
use crate::engine::{
    ActorId, ActorKind, AuthorityGrantId, CausalContext, CreateResource, DeriveGrant,
    EngineResourceScope, FunctionId, Invocation, InvocationId, RiskLevel, SUBAGENT_TASK_KIND,
    SUBAGENT_TASK_SCHEMA_ID, TraceId, WorkerId, builtin_resource_type_definitions,
};
use crate::shared::server::test_support::make_test_context;

#[tokio::test]
async fn internal_creation_records_bounded_inert_subagent_task_resource() {
    let fixture = Fixture::new("create").await;
    let created = fixture.create_task("create-key", task_payload()).await;
    let resource_id = created["subagentTaskResourceId"].as_str().unwrap();
    assert_eq!(created["activation"]["subagentStarted"], json!(false));
    assert_eq!(created["network"]["requiredPolicy"], json!("none"));

    let inspection = fixture
        .deps
        .engine_host
        .inspect_resource(resource_id)
        .await
        .expect("inspect")
        .expect("subagent task");
    assert_eq!(inspection.resource.kind, SUBAGENT_TASK_KIND);
    assert_eq!(inspection.resource.schema_id, SUBAGENT_TASK_SCHEMA_ID);
    assert_eq!(inspection.resource.scope.kind(), "session");
    let payload = current_payload(&inspection);
    assert_eq!(payload["taskId"], json!("task-alpha"));
    assert_eq!(
        payload["objectiveSummary"],
        json!("Review a failing unit test")
    );
    assert_eq!(
        payload["promptSummary"],
        json!("Summarize likely root cause")
    );
    assert_eq!(payload["result"], Value::Null);
    assert_eq!(payload["error"], Value::Null);
    assert_eq!(payload["activation"]["toolExecution"], json!(false));
}

#[tokio::test]
async fn lifecycle_update_appends_placeholder_result_without_side_effects() {
    let fixture = Fixture::new("update").await;
    let created = fixture.create_task("update-create", task_payload()).await;
    let resource_id = created["subagentTaskResourceId"].as_str().unwrap();
    let before_catalog = fixture.deps.engine_host.catalog_revision().await.0;
    let updated = fixture
        .update_task(
            "update-key",
            json!({
                "subagentTaskResourceId": resource_id,
                "state": "succeeded",
                "result": {"summary": "Recorded placeholder only"}
            }),
        )
        .await;
    let after_catalog = fixture.deps.engine_host.catalog_revision().await.0;

    assert_eq!(before_catalog, after_catalog);
    assert_eq!(updated["status"], json!("succeeded"));
    let inspected = fixture.inspect("update-inspect", resource_id).await;
    assert_eq!(inspected["task"]["payload"]["state"], json!("succeeded"));
    assert_eq!(
        inspected["task"]["payload"]["result"]["summary"],
        json!("Recorded placeholder only")
    );
    assert_eq!(inspected["activation"]["jobStarted"], json!(false));
}

#[tokio::test]
async fn creation_requires_internal_non_wildcard_authority() {
    let fixture = Fixture::new("authority").await;
    let agent_error = fixture
        .create_task_error_with_actor("agent-denied", ActorKind::Agent, task_payload())
        .await;
    assert!(agent_error.contains("trusted internal"), "{agent_error}");

    let bootstrap_invocation = invocation(
        CREATE_TASK_FUNCTION,
        "bootstrap-denied",
        task_payload(),
        AuthorityGrantId::new("engine-system").unwrap(),
        ActorKind::System,
        &[WRITE_SCOPE, "resource.write"],
        Some("authority-session"),
    );
    let bootstrap = create_task_value(
        &fixture.deps,
        &bootstrap_invocation,
        &bootstrap_invocation.payload,
    )
    .await
    .expect_err("bootstrap grant denied")
    .to_string();
    assert!(bootstrap.contains("non-bootstrap"), "{bootstrap}");

    let wildcard_grant = fixture
        .derive_grant(
            "wildcard-write",
            &[WRITE_SCOPE, "resource.write"],
            &["*"],
            &["kind:subagent_task"],
            "none",
        )
        .await;
    let wildcard_invocation = invocation(
        CREATE_TASK_FUNCTION,
        "wildcard-denied",
        task_payload(),
        wildcard_grant,
        ActorKind::System,
        &[WRITE_SCOPE, "resource.write"],
        Some(&fixture.session_id),
    );
    let wildcard = create_task_value(
        &fixture.deps,
        &wildcard_invocation,
        &wildcard_invocation.payload,
    )
    .await
    .expect_err("wildcard grant denied")
    .to_string();
    assert!(wildcard.contains("wildcard"), "{wildcard}");
}

#[tokio::test]
async fn creation_is_idempotent_per_scope_and_key() {
    let fixture = Fixture::new("idempotent").await;
    let first = fixture.create_task("same-key", task_payload()).await;
    let second = fixture.create_task("same-key", task_payload()).await;
    assert_eq!(
        first["subagentTaskResourceId"],
        second["subagentTaskResourceId"]
    );
    assert_eq!(second["idempotentReplay"], json!(true));

    let listed = fixture.list("list-once").await;
    assert_eq!(listed["tasks"].as_array().unwrap().len(), 1);
}

#[tokio::test]
async fn read_operations_are_scoped_and_require_explicit_selector() {
    let first = Fixture::new("scope-one").await;
    let second = first.clone_for_session("scope-two-session").await;
    let created = first.create_task("scope-key", task_payload()).await;
    let resource_id = created["subagentTaskResourceId"].as_str().unwrap();

    let inspected = first.inspect("scope-inspect", resource_id).await;
    assert_eq!(
        inspected["task"]["payload"]["scope"]["kind"],
        json!("session")
    );
    let cross_scope = second.inspect_error("scope-denied", resource_id).await;
    assert!(
        cross_scope.contains("outside the current scope"),
        "{cross_scope}"
    );

    let no_selector_grant = first
        .derive_grant(
            "no-selector",
            &[READ_SCOPE, "resource.read"],
            &[SUBAGENT_TASK_KIND],
            &["resource:subagent_task:other"],
            "none",
        )
        .await;
    let no_selector = invocation(
        "capability::execute",
        "no-selector",
        json!({"limit": 10}),
        no_selector_grant,
        ActorKind::Agent,
        &[READ_SCOPE, "resource.read"],
        Some(&first.session_id),
    );
    let error = list_subagent_tasks_value(&first.deps, &no_selector, &no_selector.payload)
        .await
        .expect_err("selector is required")
        .to_string();
    assert!(error.contains("kind:subagent_task"), "{error}");
}

#[tokio::test]
async fn inspect_revalidates_stored_kind_and_schema_not_id_prefix() {
    let fixture = Fixture::new("schema-mismatch").await;
    let resource_id = "subagent_task:not-actually-a-subagent";
    fixture
        .deps
        .engine_host
        .create_resource(CreateResource {
            resource_id: Some(resource_id.to_owned()),
            kind: "artifact".to_owned(),
            schema_id: Some("tron.resource.artifact.v1".to_owned()),
            scope: crate::engine::EngineResourceScope::Session(fixture.session_id.clone()),
            owner_worker_id: WorkerId::new("resource").unwrap(),
            owner_actor_id: ActorId::new("system:subagents-test").unwrap(),
            lifecycle: Some("draft".to_owned()),
            policy: json!({"read": ["resource.read"]}),
            initial_payload: Some(json!({"title": "mismatch", "body": "wrong kind"})),
            locations: Vec::new(),
            trace_id: TraceId::new("trace-schema-mismatch").unwrap(),
            invocation_id: None,
        })
        .await
        .expect("create mismatched resource");

    let error = fixture
        .inspect_error("schema-mismatch-inspect", resource_id)
        .await;
    assert!(error.contains("expected subagent_task"), "{error}");
}

#[tokio::test]
async fn read_projections_omit_redact_and_bound_untrusted_stored_payloads() {
    let fixture = Fixture::new("projection").await;
    let resource_id = "subagent_task:unsafe-projection";
    let evidence_refs = (0..(MAX_REF_ITEMS + 5))
        .map(|index| {
            json!({
                "kind": "fixture",
                "id": format!("evidence-{index}-{}", "x".repeat(PROJECTION_STRING_BYTES + 20)),
                "resourceId": format!("evidence:projection-{index}"),
                "token": "Bearer leaked-evidence-token",
                "url": "https://secret.example/evidence",
                "unexpectedNested": {"command": "run hidden helper"}
            })
        })
        .collect::<Vec<_>>();

    fixture
        .deps
        .engine_host
        .create_resource(CreateResource {
            resource_id: Some(resource_id.to_owned()),
            kind: SUBAGENT_TASK_KIND.to_owned(),
            schema_id: Some(SUBAGENT_TASK_SCHEMA_ID.to_owned()),
            scope: EngineResourceScope::Session(fixture.session_id.clone()),
            owner_worker_id: WorkerId::new("subagents").unwrap(),
            owner_actor_id: ActorId::new("system:subagents-test").unwrap(),
            lifecycle: Some("running".to_owned()),
            policy: json!({"read": ["subagents.read", "resource.read"]}),
            initial_payload: Some(json!({
                "schemaVersion": "tron.subagent_task.v1",
                "state": "running",
                "taskId": "task-unsafe",
                "parent": {
                    "sessionId": fixture.session_id.clone(),
                    "workspaceId": "workspace-subagents",
                    "traceId": "trace-projection",
                    "parentInvocationId": "invocation-projection",
                    "actorId": "agent:projection",
                    "actorKind": "Agent",
                    "command": "run leaked command",
                    "token": "Bearer leaked-parent-token"
                },
                "scope": {"kind": "session", "value": fixture.session_id.clone()},
                "objectiveSummary": "x".repeat(MAX_SUMMARY_BYTES + 64),
                "promptSummary": "See https://secret.example/raw-prompt",
                "createdAt": "2026-06-24T00:00:00Z",
                "updatedAt": "2026-06-24T00:00:01Z",
                "refs": {
                    "trace": [{
                        "traceId": "trace-projection",
                        "url": "https://secret.example/trace",
                        "token": "Bearer leaked-trace-token"
                    }],
                    "replay": [{"invocationId": "invocation-projection"}],
                    "evidence": evidence_refs,
                    "outputs": [{
                        "resourceId": "output:safe",
                        "versionId": "version-safe",
                        "command": "run output leak"
                    }]
                },
                "result": {
                    "summary": "r".repeat(PROJECTION_STRING_BYTES + 32),
                    "resourceRefs": [{
                        "resourceId": "result:safe",
                        "versionId": "version-result",
                        "token": "Bearer result-token"
                    }],
                    "token": "Bearer leaked-result-token",
                    "command": "run hidden result"
                },
                "error": {
                    "message": "failed at https://secret.example/error",
                    "code": "E_SAFE",
                    "password": "password=leaked"
                },
                "authority": {
                    "grantId": "grant-secret-123",
                    "requiredScopes": ["subagents.read", "resource.read"],
                    "resourceKind": "subagent_task",
                    "token": "Bearer leaked-authority-token"
                },
                "activation": {
                    "performed": false,
                    "subagentStarted": false,
                    "workerStarted": false,
                    "jobStarted": false,
                    "catalogRegistration": false,
                    "toolExecution": false,
                    "resultMerged": false,
                    "process": {"pid": 1234}
                },
                "network": {
                    "performed": false,
                    "requiredPolicy": "none",
                    "url": "https://secret.example/network"
                },
                "redaction": {"policy": "summary-only"},
                "limits": {
                    "maxSummaryBytes": MAX_SUMMARY_BYTES,
                    "maxRefItems": MAX_REF_ITEMS,
                    "maxPlaceholderBytes": 8192,
                    "maxTotalPayloadBytes": 64000
                },
                "idempotency": {"key": "idempotency-secret-value"},
                "revision": 7,
                "rawPrompt": "raw prompt must never project",
                "unexpectedRoot": {"secret": "Bearer leaked-root-token"}
            })),
            locations: Vec::new(),
            trace_id: TraceId::new("trace-projection-create").unwrap(),
            invocation_id: None,
        })
        .await
        .expect("create unsafe same-kind resource");

    let inspected = fixture.inspect("projection-inspect", resource_id).await;
    let listed = fixture.list("projection-list").await;
    let payload = &inspected["task"]["payload"];
    assert_eq!(payload["state"], json!("running"));
    assert_eq!(payload["promptSummary"]["redacted"], json!(true));
    assert_eq!(
        payload["objectiveSummary"].as_str().unwrap().len(),
        MAX_SUMMARY_BYTES
    );
    assert_eq!(
        payload["refs"]["evidence"]["items"]
            .as_array()
            .unwrap()
            .len(),
        MAX_REF_ITEMS
    );
    assert_eq!(payload["refs"]["evidence"]["truncated"], json!(true));
    assert_eq!(
        payload["result"]["summary"].as_str().unwrap().len(),
        PROJECTION_STRING_BYTES
    );
    assert_eq!(payload["result"]["redacted"], json!(true));
    assert_eq!(payload["error"]["message"]["redacted"], json!(true));
    assert_eq!(payload["authority"]["grantIdRedacted"], json!(true));
    assert_eq!(payload["idempotency"]["keyRedacted"], json!(true));
    assert!(payload.as_object().unwrap().get("rawPrompt").is_none());
    assert!(payload.as_object().unwrap().get("unexpectedRoot").is_none());
    assert!(payload["parent"].get("command").is_none());
    assert!(payload["refs"]["trace"]["items"][0].get("url").is_none());
    assert!(
        payload["result"]["resourceRefs"]["items"][0]
            .get("token")
            .is_none()
    );

    let listed_task = &listed["tasks"][0];
    assert_eq!(listed_task["promptSummary"]["redacted"], json!(true));
    assert_eq!(
        listed_task["objectiveSummary"].as_str().unwrap().len(),
        MAX_SUMMARY_BYTES
    );
    assert_eq!(
        listed_task["refs"]["evidence"]["items"]
            .as_array()
            .unwrap()
            .len(),
        MAX_REF_ITEMS
    );
    assert_eq!(listed_task["refs"]["evidence"]["truncated"], json!(true));

    let inspected_json = serde_json::to_string(&inspected).expect("serialize inspect");
    let listed_json = serde_json::to_string(&listed).expect("serialize list");
    for forbidden in [
        "Bearer leaked",
        "https://secret.example",
        "raw prompt must never project",
        "rawPrompt",
        "unexpectedRoot",
        "run hidden",
        "run leaked command",
        "idempotency-secret-value",
        "grant-secret-123",
        "password=leaked",
    ] {
        assert!(
            !inspected_json.contains(forbidden),
            "inspect leaked forbidden material {forbidden}: {inspected_json}"
        );
        assert!(
            !listed_json.contains(forbidden),
            "list leaked forbidden material {forbidden}: {listed_json}"
        );
    }
}

#[tokio::test]
async fn validation_rejects_unbounded_secret_and_execution_material() {
    let fixture = Fixture::new("validation").await;
    let mut large = task_payload();
    large["objectiveSummary"] = json!("x".repeat(2_049));
    assert!(
        fixture
            .create_task_error("large-objective", large)
            .await
            .contains("exceeds")
    );

    let mut secret = task_payload();
    secret["evidenceRefs"] = json!([{"token": "Bearer not-allowed"}]);
    assert!(
        fixture
            .create_task_error("secret", secret)
            .await
            .contains("secret")
    );

    let mut command = task_payload();
    command["evidenceRefs"] = json!([{"command": "run helper"}]);
    assert!(
        fixture
            .create_task_error("command", command)
            .await
            .contains("execution field")
    );
}

#[test]
fn resource_definitions_include_subagent_task_required_fields() {
    let definitions = builtin_resource_type_definitions();
    let definition = definitions
        .iter()
        .find(|definition| definition.kind == SUBAGENT_TASK_KIND)
        .expect("subagent task definition");
    assert_eq!(definition.schema_id, SUBAGENT_TASK_SCHEMA_ID);
    assert!(
        definition
            .lifecycle_states
            .iter()
            .any(|state| state == "requested")
    );
    assert!(
        definition
            .required_capabilities
            .to_string()
            .contains("subagents.read")
    );
    for field in [
        "schemaVersion",
        "state",
        "taskId",
        "parent",
        "scope",
        "objectiveSummary",
        "promptSummary",
        "createdAt",
        "updatedAt",
        "refs",
        "activation",
        "network",
    ] {
        assert!(
            definition.schema["required"]
                .as_array()
                .unwrap()
                .contains(&json!(field)),
            "subagent task schema must require {field}"
        );
    }
}

#[test]
fn static_non_goal_guards_keep_subagent_tasks_inert() {
    let service = include_str!("service.rs");
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
    ] {
        assert!(
            !service.contains(forbidden),
            "subagent service must not contain {forbidden}"
        );
    }
}

struct Fixture {
    deps: Deps,
    session_id: String,
    grant_id: AuthorityGrantId,
    read_grant_id: AuthorityGrantId,
}

impl Fixture {
    async fn new(label: &str) -> Self {
        let ctx = make_test_context();
        let deps = Deps {
            engine_host: ctx.engine_host.clone(),
        };
        let session_id = format!("{label}-session");
        let grant_id = derive_grant(
            &deps,
            &format!("{label}-write"),
            &[WRITE_SCOPE, READ_SCOPE, "resource.write", "resource.read"],
            &[SUBAGENT_TASK_KIND],
            &["kind:subagent_task"],
            "none",
        )
        .await;
        let read_grant_id = derive_grant(
            &deps,
            &format!("{label}-read"),
            &[READ_SCOPE, "resource.read"],
            &[SUBAGENT_TASK_KIND],
            &["kind:subagent_task"],
            "none",
        )
        .await;
        Self {
            deps,
            session_id,
            grant_id,
            read_grant_id,
        }
    }

    async fn clone_for_session(&self, session_id: &str) -> Self {
        let grant_id = self
            .derive_grant(
                &format!("{session_id}-write"),
                &[WRITE_SCOPE, READ_SCOPE, "resource.write", "resource.read"],
                &[SUBAGENT_TASK_KIND],
                &["kind:subagent_task"],
                "none",
            )
            .await;
        let read_grant_id = self
            .derive_grant(
                &format!("{session_id}-read"),
                &[READ_SCOPE, "resource.read"],
                &[SUBAGENT_TASK_KIND],
                &["kind:subagent_task"],
                "none",
            )
            .await;
        Self {
            deps: self.deps.clone(),
            session_id: session_id.to_owned(),
            grant_id,
            read_grant_id,
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

    async fn create_task(&self, key: &str, payload: Value) -> Value {
        let invocation =
            self.write_invocation(CREATE_TASK_FUNCTION, key, payload, ActorKind::System);
        create_task_value(&self.deps, &invocation, &invocation.payload)
            .await
            .expect("create task")
    }

    async fn create_task_error(&self, key: &str, payload: Value) -> String {
        self.create_task_error_with_actor(key, ActorKind::System, payload)
            .await
    }

    async fn create_task_error_with_actor(
        &self,
        key: &str,
        actor_kind: ActorKind,
        payload: Value,
    ) -> String {
        let invocation = self.write_invocation(CREATE_TASK_FUNCTION, key, payload, actor_kind);
        create_task_value(&self.deps, &invocation, &invocation.payload)
            .await
            .expect_err("create should fail")
            .to_string()
    }

    async fn update_task(&self, key: &str, payload: Value) -> Value {
        let invocation =
            self.write_invocation(UPDATE_TASK_FUNCTION, key, payload, ActorKind::System);
        update_task_value(&self.deps, &invocation, &invocation.payload)
            .await
            .expect("update task")
    }

    async fn list(&self, key: &str) -> Value {
        let invocation = self.read_invocation(key, json!({"limit": 10}));
        list_subagent_tasks_value(&self.deps, &invocation, &invocation.payload)
            .await
            .expect("list tasks")
    }

    async fn inspect(&self, key: &str, resource_id: &str) -> Value {
        let invocation = self.read_invocation(key, json!({"subagentTaskResourceId": resource_id}));
        inspect_subagent_task_value(&self.deps, &invocation, &invocation.payload)
            .await
            .expect("inspect task")
    }

    async fn inspect_error(&self, key: &str, resource_id: &str) -> String {
        let invocation = self.read_invocation(key, json!({"subagentTaskResourceId": resource_id}));
        inspect_subagent_task_value(&self.deps, &invocation, &invocation.payload)
            .await
            .expect_err("inspect should fail")
            .to_string()
    }

    fn write_invocation(
        &self,
        function_id: &str,
        key: &str,
        payload: Value,
        actor_kind: ActorKind,
    ) -> Invocation {
        invocation(
            function_id,
            key,
            payload,
            self.grant_id.clone(),
            actor_kind,
            &[WRITE_SCOPE, "resource.write"],
            Some(&self.session_id),
        )
    }

    fn read_invocation(&self, key: &str, payload: Value) -> Invocation {
        invocation(
            "capability::execute",
            key,
            payload,
            self.read_grant_id.clone(),
            ActorKind::Agent,
            &[READ_SCOPE, "resource.read"],
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
    let grant = deps
        .engine_host
        .derive_authority_grant(DeriveGrant {
            grant_id: Some(AuthorityGrantId::new(format!("subagents-{suffix}")).unwrap()),
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
            budget: json!({"class": "subagent_task_test"}),
            expires_at: None,
            can_delegate: false,
            provenance: json!({"source": "subagents_test"}),
            trace_id: TraceId::new(format!("trace-subagents-{suffix}")).unwrap(),
        })
        .await
        .expect("derive grant");
    grant.grant_id
}

fn invocation(
    function_id: &str,
    key: &str,
    payload: Value,
    grant_id: AuthorityGrantId,
    actor_kind: ActorKind,
    scopes: &[&str],
    session_id: Option<&str>,
) -> Invocation {
    let actor_id = match actor_kind {
        ActorKind::Agent => ActorId::new(format!("agent:{}", session_id.unwrap())).unwrap(),
        ActorKind::System => ActorId::new("system:subagents-test").unwrap(),
        ActorKind::Admin => ActorId::new("admin:subagents-test").unwrap(),
        _ => ActorId::new("client:subagents-test").unwrap(),
    };
    let mut context = CausalContext::new(
        actor_id,
        actor_kind,
        grant_id,
        TraceId::new(format!("trace-{key}")).unwrap(),
    )
    .with_workspace_id("workspace-subagents")
    .with_idempotency_key(key.to_owned());
    if let Some(session_id) = session_id {
        context = context.with_session_id(session_id.to_owned());
    }
    for scope in scopes {
        context = context.with_scope(*scope);
    }
    Invocation {
        id: InvocationId::new(format!("invocation-{key}")).unwrap(),
        function_id: FunctionId::new(function_id).unwrap(),
        delivery_mode: crate::engine::DeliveryMode::Sync,
        payload,
        causal_context: context,
    }
}

fn task_payload() -> Value {
    json!({
        "taskId": "task-alpha",
        "objectiveSummary": "Review a failing unit test",
        "promptSummary": "Summarize likely root cause",
        "evidenceRefs": [{"kind": "fixture", "id": "evidence-1"}],
        "outputRefs": []
    })
}

fn current_payload(inspection: &crate::engine::EngineResourceInspection) -> Value {
    let current = inspection
        .resource
        .current_version_id
        .as_ref()
        .expect("current version");
    inspection
        .versions
        .iter()
        .find(|version| &version.version_id == current)
        .expect("current payload")
        .payload
        .clone()
}
