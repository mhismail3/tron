use chrono::{DateTime, Utc};
use serde_json::{Value, json};

use super::contract::{READ_SCOPE, RESOURCE_READ_SCOPE, RESOURCE_WRITE_SCOPE, WRITE_SCOPE};
use super::service::{
    activate_module_dependency_policy_value_at, inspect_module_dependency_policy_value,
    inspect_module_dependency_request_value, list_module_dependency_decision_value,
    list_module_dependency_policy_value, list_module_dependency_request_value,
    record_module_dependency_decision_value_at, record_module_dependency_request_value_at,
};
use super::{
    Deps, MODULE_DEPENDENCY_DECISION_KIND, MODULE_DEPENDENCY_DECISION_SCHEMA_ID,
    MODULE_DEPENDENCY_POLICY_KIND, MODULE_DEPENDENCY_POLICY_SCHEMA_ID,
    MODULE_DEPENDENCY_REQUEST_KIND, MODULE_DEPENDENCY_REQUEST_SCHEMA_ID,
};
use crate::engine::{
    ActorId, ActorKind, AuthorityGrantId, CausalContext, DeliveryMode, DeriveGrant,
    EngineResourceVersioningMode, FunctionId, Invocation, InvocationId, RiskLevel, TraceId,
    builtin_resource_type_definitions,
};
use crate::shared::server::test_support::make_test_context;

const DEFAULT_OPERATION_AT: &str = "2026-06-27T12:00:00Z";

struct Fixture {
    deps: Deps,
    session_id: String,
    write_grant_id: AuthorityGrantId,
    read_grant_id: AuthorityGrantId,
}

impl Fixture {
    async fn new(label: &str) -> Self {
        let ctx = make_test_context();
        let deps = Deps {
            engine_host: ctx.engine_host.clone(),
        };
        let session_id = format!("{label}-session");
        let write_grant_id = derive_grant(
            &deps,
            &format!("{label}-write"),
            &[
                READ_SCOPE,
                WRITE_SCOPE,
                RESOURCE_READ_SCOPE,
                RESOURCE_WRITE_SCOPE,
            ],
            &[
                MODULE_DEPENDENCY_REQUEST_KIND,
                MODULE_DEPENDENCY_DECISION_KIND,
                MODULE_DEPENDENCY_POLICY_KIND,
            ],
            &[
                "kind:module_dependency_request",
                "kind:module_dependency_decision",
                "kind:module_dependency_policy",
            ],
            "none",
        )
        .await;
        let read_grant_id = derive_grant(
            &deps,
            &format!("{label}-read"),
            &[READ_SCOPE, RESOURCE_READ_SCOPE],
            &[
                MODULE_DEPENDENCY_REQUEST_KIND,
                MODULE_DEPENDENCY_DECISION_KIND,
                MODULE_DEPENDENCY_POLICY_KIND,
            ],
            &[
                "kind:module_dependency_request",
                "kind:module_dependency_decision",
                "kind:module_dependency_policy",
            ],
            "none",
        )
        .await;
        Self {
            deps,
            session_id,
            write_grant_id,
            read_grant_id,
        }
    }

    async fn dependency_request(&self, key: &str) -> Value {
        let invocation = self.write_invocation(key, request_payload(key));
        record_module_dependency_request_value_at(
            &self.deps,
            &invocation,
            &invocation.payload,
            default_operation_at(),
        )
        .await
        .expect("record dependency request")
    }

    async fn dependency_decision(&self, key: &str, request_id: &str, decision: &str) -> Value {
        let grant_id = self
            .exact_write_grant(&format!("{key}-request-exact"), request_id)
            .await;
        let invocation = invocation(
            key,
            json!({
                "moduleDependencyRequestResourceId": request_id,
                "dependencyDecisionId": format!("{key}-decision"),
                "decision": decision,
                "reason": "Dependency policy review reached a metadata-only decision.",
                "denialEvidence": [{"kind": "evidence", "resourceId": "evidence:denial", "role": "denial"}]
            }),
            grant_id,
            &[
                READ_SCOPE,
                WRITE_SCOPE,
                RESOURCE_READ_SCOPE,
                RESOURCE_WRITE_SCOPE,
            ],
            &self.session_id,
        );
        record_module_dependency_decision_value_at(
            &self.deps,
            &invocation,
            &invocation.payload,
            default_operation_at(),
        )
        .await
        .expect("record dependency decision")
    }

    async fn dependency_policy(&self, key: &str, decision_id: &str) -> Value {
        let grant_id = self
            .exact_write_grant(&format!("{key}-decision-exact"), decision_id)
            .await;
        let invocation = invocation(
            key,
            json!({
                "moduleDependencyDecisionResourceId": decision_id,
                "dependencyPolicyId": format!("{key}-policy"),
                "reason": "Activate approved metadata dependency policy for later module-pack work."
            }),
            grant_id,
            &[
                READ_SCOPE,
                WRITE_SCOPE,
                RESOURCE_READ_SCOPE,
                RESOURCE_WRITE_SCOPE,
            ],
            &self.session_id,
        );
        activate_module_dependency_policy_value_at(
            &self.deps,
            &invocation,
            &invocation.payload,
            default_operation_at(),
        )
        .await
        .expect("activate dependency policy")
    }

    async fn exact_read_grant(&self, suffix: &str, resource_id: &str) -> AuthorityGrantId {
        let exact_selector = format!("resource:{resource_id}");
        derive_grant(
            &self.deps,
            suffix,
            &[READ_SCOPE, RESOURCE_READ_SCOPE],
            &[
                MODULE_DEPENDENCY_REQUEST_KIND,
                MODULE_DEPENDENCY_DECISION_KIND,
                MODULE_DEPENDENCY_POLICY_KIND,
            ],
            &[
                "kind:module_dependency_request",
                "kind:module_dependency_decision",
                "kind:module_dependency_policy",
                exact_selector.as_str(),
            ],
            "none",
        )
        .await
    }

    async fn exact_write_grant(&self, suffix: &str, resource_id: &str) -> AuthorityGrantId {
        let exact_selector = format!("resource:{resource_id}");
        derive_grant(
            &self.deps,
            suffix,
            &[
                READ_SCOPE,
                WRITE_SCOPE,
                RESOURCE_READ_SCOPE,
                RESOURCE_WRITE_SCOPE,
            ],
            &[
                MODULE_DEPENDENCY_REQUEST_KIND,
                MODULE_DEPENDENCY_DECISION_KIND,
                MODULE_DEPENDENCY_POLICY_KIND,
            ],
            &[
                "kind:module_dependency_request",
                "kind:module_dependency_decision",
                "kind:module_dependency_policy",
                exact_selector.as_str(),
            ],
            "none",
        )
        .await
    }

    fn write_invocation(&self, key: &str, payload: Value) -> Invocation {
        invocation(
            key,
            payload,
            self.write_grant_id.clone(),
            &[
                READ_SCOPE,
                WRITE_SCOPE,
                RESOURCE_READ_SCOPE,
                RESOURCE_WRITE_SCOPE,
            ],
            &self.session_id,
        )
    }

    fn read_invocation(&self, key: &str, payload: Value) -> Invocation {
        invocation(
            key,
            payload,
            self.read_grant_id.clone(),
            &[READ_SCOPE, RESOURCE_READ_SCOPE],
            &self.session_id,
        )
    }
}

#[test]
fn module_dependency_resource_types_are_registered_with_metadata_only_bounds() {
    let definitions = builtin_resource_type_definitions();
    for (kind, schema_id) in [
        (
            MODULE_DEPENDENCY_REQUEST_KIND,
            MODULE_DEPENDENCY_REQUEST_SCHEMA_ID,
        ),
        (
            MODULE_DEPENDENCY_DECISION_KIND,
            MODULE_DEPENDENCY_DECISION_SCHEMA_ID,
        ),
        (
            MODULE_DEPENDENCY_POLICY_KIND,
            MODULE_DEPENDENCY_POLICY_SCHEMA_ID,
        ),
    ] {
        let definition = definitions
            .iter()
            .find(|definition| definition.kind == kind)
            .expect("module dependency definition");
        assert_eq!(definition.schema_id, schema_id);
        assert_eq!(
            definition.versioning_mode,
            EngineResourceVersioningMode::AppendOnly
        );
        assert_eq!(
            definition.required_capabilities["read"],
            json!([READ_SCOPE, RESOURCE_READ_SCOPE])
        );
        assert_eq!(
            definition.required_capabilities["write"],
            json!([WRITE_SCOPE, RESOURCE_WRITE_SCOPE])
        );
        assert_eq!(
            definition.materialization_rules["networkPolicy"],
            json!("none")
        );
        assert_eq!(
            definition.materialization_rules["packageManager"],
            json!("forbidden")
        );
        assert_eq!(
            definition.redaction_rules["neverReturn"]
                .as_array()
                .unwrap()
                .contains(&json!("packageManagerOutput")),
            true
        );
    }
}

#[tokio::test]
async fn request_decision_policy_record_list_inspect_and_replay_are_metadata_only() {
    let fixture = Fixture::new("module-dependency-flow").await;
    let request = fixture.dependency_request("request").await;
    assert_eq!(request["status"], json!("pending_review"));
    assert_eq!(request["idempotentReplay"], json!(false));
    assert_eq!(
        request["dependencyRequest"]["parityEvidence"]["cargoToml"]["packageManagerExecuted"],
        json!(false)
    );
    let replay = fixture.dependency_request("request").await;
    assert_eq!(replay["idempotentReplay"], json!(true));
    let request_id = request["moduleDependencyRequestResourceId"]
        .as_str()
        .expect("request id");

    let decision = fixture
        .dependency_decision("decision", request_id, "approved")
        .await;
    assert_eq!(decision["status"], json!("approved_policy"));
    let decision_id = decision["moduleDependencyDecisionResourceId"]
        .as_str()
        .expect("decision id");

    let policy = fixture.dependency_policy("policy", decision_id).await;
    assert_eq!(policy["status"], json!("active"));
    assert_eq!(
        policy["dependencyPolicy"]["activation"]["dependencyRestored"],
        json!(false)
    );
    let policy_id = policy["moduleDependencyPolicyResourceId"]
        .as_str()
        .expect("policy id");

    assert_eq!(
        list_module_dependency_request_value(
            &fixture.deps,
            &fixture.read_invocation("list-requests", json!({})),
            &json!({})
        )
        .await
        .expect("list requests")["dependencyRequests"]
            .as_array()
            .unwrap()
            .len(),
        1
    );
    assert_eq!(
        list_module_dependency_decision_value(
            &fixture.deps,
            &fixture.read_invocation("list-decisions", json!({})),
            &json!({})
        )
        .await
        .expect("list decisions")["dependencyDecisions"]
            .as_array()
            .unwrap()
            .len(),
        1
    );
    assert_eq!(
        list_module_dependency_policy_value(
            &fixture.deps,
            &fixture.read_invocation("list-policies", json!({})),
            &json!({})
        )
        .await
        .expect("list policies")["dependencyPolicies"]
            .as_array()
            .unwrap()
            .len(),
        1
    );

    let request_grant = fixture.exact_read_grant("request-exact", request_id).await;
    let inspected_request = inspect_module_dependency_request_value(
        &fixture.deps,
        &invocation(
            "inspect-request",
            json!({"moduleDependencyRequestResourceId": request_id}),
            request_grant,
            &[READ_SCOPE, RESOURCE_READ_SCOPE],
            &fixture.session_id,
        ),
        &json!({"moduleDependencyRequestResourceId": request_id}),
    )
    .await
    .expect("inspect request");
    assert_eq!(
        inspected_request["dependencyRequest"]["dependencyRequest"]["sideEffectProof"]["networkPolicy"],
        json!("none")
    );

    let policy_grant = fixture.exact_read_grant("policy-exact", policy_id).await;
    let inspected_policy = inspect_module_dependency_policy_value(
        &fixture.deps,
        &invocation(
            "inspect-policy",
            json!({"moduleDependencyPolicyResourceId": policy_id}),
            policy_grant,
            &[READ_SCOPE, RESOURCE_READ_SCOPE],
            &fixture.session_id,
        ),
        &json!({"moduleDependencyPolicyResourceId": policy_id}),
    )
    .await
    .expect("inspect policy");
    assert_eq!(
        inspected_policy["dependencyPolicy"]["dependencyPolicy"]["activation"]["packageManagerUsed"],
        json!(false)
    );
}

#[tokio::test]
async fn unsafe_payloads_and_package_manager_parity_are_rejected() {
    let fixture = Fixture::new("module-dependency-unsafe").await;
    for payload in [
        {
            let mut payload = request_payload("raw-command");
            payload["command"] = json!("cargo add portable-pty");
            payload
        },
        {
            let mut payload = request_payload("package-output");
            payload["cargoLockEvidence"]["packageManagerExecuted"] = json!(true);
            payload
        },
        {
            let mut payload = request_payload("local-path");
            payload["rationale"] = json!("Read /Users/example/project/Cargo.toml directly");
            payload
        },
    ] {
        let invocation = fixture.write_invocation("unsafe", payload);
        let error = record_module_dependency_request_value_at(
            &fixture.deps,
            &invocation,
            &invocation.payload,
            default_operation_at(),
        )
        .await
        .expect_err("unsafe payload rejected")
        .to_string();
        assert!(
            error.contains("not accepted")
                || error.contains("package manager")
                || error.contains("path-like"),
            "unexpected error: {error}"
        );
    }
}

#[tokio::test]
async fn rejected_decisions_require_denial_evidence_and_exact_selectors() {
    let fixture = Fixture::new("module-dependency-denial").await;
    let request = fixture.dependency_request("request").await;
    let request_id = request["moduleDependencyRequestResourceId"]
        .as_str()
        .unwrap();

    let missing_evidence = record_module_dependency_decision_value_at(
        &fixture.deps,
        &invocation(
            "denial-missing",
            json!({
                "moduleDependencyRequestResourceId": request_id,
                "dependencyDecisionId": "missing-denial",
                "decision": "rejected",
                "reason": "Reject high risk dependency."
            }),
            fixture
                .exact_write_grant("denial-missing-exact", request_id)
                .await,
            &[
                READ_SCOPE,
                WRITE_SCOPE,
                RESOURCE_READ_SCOPE,
                RESOURCE_WRITE_SCOPE,
            ],
            &fixture.session_id,
        ),
        &json!({
            "moduleDependencyRequestResourceId": request_id,
            "dependencyDecisionId": "missing-denial",
            "decision": "rejected",
            "reason": "Reject high risk dependency."
        }),
        default_operation_at(),
    )
    .await
    .expect_err("denial evidence required")
    .to_string();
    assert!(missing_evidence.contains("denialEvidence"));

    let selector_denied = inspect_module_dependency_request_value(
        &fixture.deps,
        &fixture.read_invocation(
            "selector-denied",
            json!({"moduleDependencyRequestResourceId": request_id}),
        ),
        &json!({"moduleDependencyRequestResourceId": request_id}),
    )
    .await
    .expect_err("exact selector required")
    .to_string();
    assert!(selector_denied.contains("exact resource:"));
}

async fn derive_grant(
    deps: &Deps,
    label: &str,
    scopes: &[&str],
    resource_kinds: &[&str],
    resource_selectors: &[&str],
    network_policy: &str,
) -> AuthorityGrantId {
    deps.engine_host
        .derive_authority_grant(DeriveGrant {
            grant_id: Some(AuthorityGrantId::new(format!("module-dependencies-{label}")).unwrap()),
            parent_grant_id: AuthorityGrantId::new("engine-system").expect("parent grant"),
            subject_actor_id: Some(ActorId::new(format!("actor:{label}")).expect("actor id")),
            subject_worker_id: None,
            subject_invocation_id: None,
            allowed_capabilities: vec!["capability::execute".to_owned()],
            allowed_namespaces: vec!["__no_namespace_authority__".to_owned()],
            allowed_authority_scopes: scopes.iter().map(|scope| (*scope).to_owned()).collect(),
            allowed_resource_kinds: resource_kinds
                .iter()
                .map(|kind| (*kind).to_owned())
                .collect(),
            resource_selectors: resource_selectors
                .iter()
                .map(|selector| (*selector).to_owned())
                .collect(),
            file_roots: vec!["/tmp".to_owned()],
            network_policy: network_policy.to_owned(),
            max_risk: RiskLevel::Low,
            budget: json!({"class": "module_dependencies_test"}),
            expires_at: None,
            can_delegate: false,
            provenance: json!({"test": label}),
            trace_id: TraceId::new(format!("trace-module-dependencies-{label}")).expect("trace id"),
        })
        .await
        .expect("derive grant")
        .grant_id
}

fn request_payload(key: &str) -> Value {
    json!({
        "dependencyRequestId": format!("{key}-dependency-request"),
        "title": "Dependency request",
        "moduleRef": {"kind": "module_manifest", "resourceId": "module_manifest:bounded", "role": "owner"},
        "proposalRef": {"kind": "module_proposal", "resourceId": "module_proposal:bounded", "role": "proposal"},
        "validationRef": {"kind": "module_validation_report", "resourceId": "module_validation_report:passed", "role": "validation"},
        "dependencyName": "portable-pty",
        "dependencyVersionReq": "0.9",
        "dependencyEcosystem": "cargo",
        "rationale": "Module owner needs a dependency policy record before later module-pack work can consider restoration.",
        "securityNeed": "Review terminal boundary and sandbox risk before any future dependency restoration.",
        "licenseNeed": "License must be recorded before future runtime use.",
        "runtimeNeed": "Runtime use is not enabled by this request and remains future module-pack scope.",
        "removalPlan": "Remove the policy if the module pack no longer requires supervised terminal metadata.",
        "riskClass": "high",
        "reviewStatus": "pending_review",
        "cargoTomlEvidence": {
            "status": "unchanged",
            "summary": "Cargo.toml parity checked as metadata only.",
            "evidenceRefs": [{"kind": "evidence", "resourceId": "evidence:cargo-toml", "role": "parity"}],
            "packageManagerExecuted": false,
            "fileMutated": false
        },
        "cargoLockEvidence": {
            "status": "unchanged",
            "summary": "Cargo.lock parity checked as metadata only.",
            "evidenceRefs": [{"kind": "evidence", "resourceId": "evidence:cargo-lock", "role": "parity"}],
            "packageManagerExecuted": false,
            "fileMutated": false
        },
        "evidenceRefs": [{"kind": "evidence", "resourceId": "evidence:dependency-review", "role": "review"}]
    })
}

fn invocation(
    key: &str,
    payload: Value,
    grant_id: AuthorityGrantId,
    scopes: &[&str],
    session_id: &str,
) -> Invocation {
    let mut context = CausalContext::new(
        ActorId::new(format!("actor:{key}")).expect("actor id"),
        ActorKind::Agent,
        grant_id,
        TraceId::new(format!("trace-{key}")).expect("trace id"),
    )
    .with_session_id(session_id.to_owned())
    .with_idempotency_key(format!("idempotency-{key}"));
    for scope in scopes {
        context = context.with_scope((*scope).to_owned());
    }
    Invocation {
        id: InvocationId::new(format!("invocation-{key}")).expect("invocation id"),
        function_id: FunctionId::new("capability::execute").expect("function id"),
        delivery_mode: DeliveryMode::Sync,
        payload,
        causal_context: context,
    }
}

fn default_operation_at() -> DateTime<Utc> {
    DateTime::parse_from_rfc3339(DEFAULT_OPERATION_AT)
        .expect("valid timestamp")
        .with_timezone(&Utc)
}
