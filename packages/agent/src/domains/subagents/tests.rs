use serde_json::{Value, json};

use super::projection::PROJECTION_STRING_BYTES;
use super::service::{inspect_subagent_task_value, list_subagent_tasks_value};
use super::validation::{MAX_REF_ITEMS, MAX_SUMMARY_BYTES};
use super::{Deps, READ_SCOPE, SCHEMA_VERSION};
use crate::engine::{
    ActorId, ActorKind, AuthorityGrantId, CausalContext, CreateResource, DeriveGrant,
    EngineResourceScope, FunctionId, Invocation, InvocationId, RiskLevel, SUBAGENT_TASK_KIND,
    SUBAGENT_TASK_SCHEMA_ID, TraceId, WorkerId, builtin_resource_type_definitions,
};
use crate::shared::server::test_support::make_test_context;

#[tokio::test]
async fn read_operations_are_scoped_and_require_explicit_selector() {
    let first = Fixture::new("scope-one").await;
    let second = first.clone_for_session("scope-two-session").await;
    let resource_id = first.seed_readable_task("scope-task").await;

    let inspected = first.inspect("scope-inspect", &resource_id).await;
    assert_eq!(
        inspected["task"]["payload"]["scope"]["kind"],
        json!("session")
    );
    let cross_scope = second.inspect_error("scope-denied", &resource_id).await;
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
    read_grant_id: AuthorityGrantId,
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
        Self {
            deps,
            session_id,
            read_grant_id,
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
        Self {
            deps: self.deps.clone(),
            session_id: session_id.to_owned(),
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

    async fn seed_readable_task(&self, task_id: &str) -> String {
        let resource_id = format!("{SUBAGENT_TASK_KIND}:{task_id}");
        self.deps
            .engine_host
            .create_resource(CreateResource {
                resource_id: Some(resource_id.clone()),
                kind: SUBAGENT_TASK_KIND.to_owned(),
                schema_id: Some(SUBAGENT_TASK_SCHEMA_ID.to_owned()),
                scope: EngineResourceScope::Session(self.session_id.clone()),
                owner_worker_id: WorkerId::new("subagents").unwrap(),
                owner_actor_id: ActorId::new("system:subagents-test").unwrap(),
                lifecycle: Some("requested".to_owned()),
                policy: json!({"read": ["subagents.read", "resource.read"]}),
                initial_payload: Some(json!({
                    "schemaVersion": SCHEMA_VERSION,
                    "state": "requested",
                    "taskId": task_id,
                    "parent": {
                        "sessionId": self.session_id.clone(),
                        "workspaceId": "workspace-subagents",
                        "traceId": format!("trace-{task_id}"),
                        "parentInvocationId": Value::Null,
                        "actorId": "system:subagents-test",
                        "actorKind": "System"
                    },
                    "scope": {"kind": "session", "value": self.session_id.clone()},
                    "objectiveSummary": "Stored read projection fixture",
                    "promptSummary": "Inspect this stored task",
                    "createdAt": "2026-06-24T00:00:00Z",
                    "updatedAt": "2026-06-24T00:00:00Z",
                    "refs": {
                        "trace": [],
                        "replay": [],
                        "evidence": [],
                        "outputs": [],
                        "handoff": []
                    },
                    "activation": {
                        "performed": false,
                        "subagentStarted": false,
                        "workerStarted": false,
                        "jobStarted": false,
                        "catalogRegistration": false,
                        "toolExecution": false,
                        "resultMerged": false
                    },
                    "network": {"performed": false, "requiredPolicy": "none"},
                    "revision": 1
                })),
                locations: Vec::new(),
                trace_id: TraceId::new(format!("trace-seed-{task_id}")).unwrap(),
                invocation_id: None,
            })
            .await
            .expect("seed readable subagent task");
        resource_id
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
