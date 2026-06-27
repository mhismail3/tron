use chrono::{DateTime, Duration, Utc};
use serde_json::{Value, json};

use super::contract::{READ_SCOPE, RESOURCE_READ_SCOPE, RESOURCE_WRITE_SCOPE, WRITE_SCOPE};
use super::service::{
    inspect_module_install_decision_value, inspect_module_install_request_value,
    list_module_install_decision_value, list_module_install_request_value,
    record_module_install_decision_value_at, record_module_install_request_value_at,
};
use super::{
    Deps, MODULE_INSTALL_DECISION_KIND, MODULE_INSTALL_DECISION_SCHEMA_ID,
    MODULE_INSTALL_REQUEST_KIND, MODULE_INSTALL_REQUEST_SCHEMA_ID,
};
use crate::engine::{
    ActorId, ActorKind, AuthorityGrantId, CausalContext, DeriveGrant, FunctionId, Invocation,
    InvocationId, ListResources, RiskLevel, TraceId, builtin_resource_type_definitions,
};
use crate::shared::server::test_support::make_test_context;

const DEFAULT_OPERATION_AT: &str = "2026-06-26T12:00:00Z";

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
            &[MODULE_INSTALL_REQUEST_KIND, MODULE_INSTALL_DECISION_KIND],
            &[
                "kind:module_install_request",
                "kind:module_install_decision",
            ],
            "none",
        )
        .await;
        let read_grant_id = derive_grant(
            &deps,
            &format!("{label}-read"),
            &[READ_SCOPE, RESOURCE_READ_SCOPE],
            &[MODULE_INSTALL_REQUEST_KIND, MODULE_INSTALL_DECISION_KIND],
            &[
                "kind:module_install_request",
                "kind:module_install_decision",
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

    async fn passed_validation_report(&self, key: &str) -> String {
        let validation_deps = crate::domains::module_validation::Deps {
            engine_host: self.deps.engine_host.clone(),
        };
        let validation_grant_id = derive_grant(
            &self.deps,
            &format!("{key}-validation"),
            &[
                crate::domains::module_validation::contract::READ_SCOPE,
                crate::domains::module_validation::contract::WRITE_SCOPE,
                RESOURCE_READ_SCOPE,
                RESOURCE_WRITE_SCOPE,
            ],
            &[crate::engine::MODULE_VALIDATION_REPORT_KIND],
            &["kind:module_validation_report"],
            "none",
        )
        .await;
        let invocation = invocation(
            key,
            validation_payload(),
            validation_grant_id,
            &[
                crate::domains::module_validation::contract::READ_SCOPE,
                crate::domains::module_validation::contract::WRITE_SCOPE,
                RESOURCE_READ_SCOPE,
                RESOURCE_WRITE_SCOPE,
            ],
            &self.session_id,
        );
        let recorded =
            crate::domains::module_validation::service::record_module_validation_report_value_at(
                &validation_deps,
                &invocation,
                &invocation.payload,
                default_operation_at(),
            )
            .await
            .expect("record validation report");
        recorded["moduleValidationReportResourceId"]
            .as_str()
            .expect("validation report id")
            .to_owned()
    }

    async fn install_request(&self, key: &str, validation_report_id: &str) -> Value {
        let invocation = self.write_invocation(key, request_payload(validation_report_id));
        record_module_install_request_value_at(
            &self.deps,
            &invocation,
            &invocation.payload,
            default_operation_at(),
        )
        .await
        .expect("record install request")
    }

    async fn approval(&self, key: &str, request_id: &str, validation_report_id: &str) -> Value {
        let request_invocation = approval_invocation(
            &format!("{key}-request"),
            json!({
                "action": approval_action(),
                "scope": scope_ref(&self.session_id),
                "riskClass": "medium",
                "expiresAt": future_time(30),
                "freshness": {"staleAt": future_time(20)},
                "evidenceRefs": [{"kind": "evidence", "resourceId": "evidence:module-install-approval"}],
                "resourceSelectors": approval_selectors(request_id, validation_report_id),
                "denialBehavior": {"mode": "fail_closed", "onDenied": "record_denial"}
            }),
            key,
            &self.session_id,
        );
        let request = crate::domains::approval::service::request_approval_value(
            &self.deps.engine_host,
            &request_invocation,
            &request_invocation.payload,
        )
        .await
        .expect("request approval");
        let decision_invocation = approval_invocation(
            &format!("{key}-decision"),
            json!({
                "requestResourceId": request["requestResourceId"],
                "expectedRequestVersionId": request["requestVersionId"],
                "state": "approved",
                "decisionActor": {"kind": "user", "id": "operator"},
                "expiresAt": future_time(30),
                "freshnessUntil": future_time(20)
            }),
            key,
            &self.session_id,
        );
        crate::domains::approval::service::decide_approval_value(
            &self.deps.engine_host,
            &decision_invocation,
            &decision_invocation.payload,
        )
        .await
        .expect("decide approval")
    }

    async fn decision(&self, key: &str, payload: Value) -> Result<Value, String> {
        let invocation = self.write_invocation(key, payload);
        record_module_install_decision_value_at(
            &self.deps,
            &invocation,
            &invocation.payload,
            default_operation_at(),
        )
        .await
        .map_err(|error| error.to_string())
    }

    async fn request_error(&self, key: &str, payload: Value) -> String {
        let invocation = self.write_invocation(key, payload);
        record_module_install_request_value_at(
            &self.deps,
            &invocation,
            &invocation.payload,
            default_operation_at(),
        )
        .await
        .expect_err("request should fail")
        .to_string()
    }

    async fn exact_read_grant(&self, suffix: &str, resource_id: &str) -> AuthorityGrantId {
        let exact_selector = format!("resource:{resource_id}");
        derive_grant(
            &self.deps,
            suffix,
            &[READ_SCOPE, RESOURCE_READ_SCOPE],
            &[MODULE_INSTALL_REQUEST_KIND, MODULE_INSTALL_DECISION_KIND],
            &[
                "kind:module_install_request",
                "kind:module_install_decision",
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
fn module_install_resource_types_are_registered_with_metadata_only_bounds() {
    let definitions = builtin_resource_type_definitions();
    let request = definitions
        .iter()
        .find(|definition| definition.kind == MODULE_INSTALL_REQUEST_KIND)
        .expect("module install request definition");
    assert_eq!(request.schema_id, MODULE_INSTALL_REQUEST_SCHEMA_ID);
    assert_eq!(
        request.required_capabilities["read"],
        json!([READ_SCOPE, RESOURCE_READ_SCOPE])
    );
    assert_eq!(
        request.required_capabilities["write"],
        json!([WRITE_SCOPE, RESOURCE_WRITE_SCOPE])
    );
    assert_eq!(
        request.materialization_rules["networkPolicy"],
        json!("none")
    );
    assert_eq!(request.materialization_rules["install"], json!("forbidden"));
    assert_eq!(
        request.materialization_rules["installCandidate"],
        json!("metadata_gate_state_only")
    );
    assert_eq!(
        request.materialization_rules["approvalIsAuthority"],
        json!(false)
    );

    let decision = definitions
        .iter()
        .find(|definition| definition.kind == MODULE_INSTALL_DECISION_KIND)
        .expect("module install decision definition");
    assert_eq!(decision.schema_id, MODULE_INSTALL_DECISION_SCHEMA_ID);
    assert_eq!(
        decision.materialization_rules["packageManager"],
        json!("forbidden")
    );
    assert_eq!(
        decision.materialization_rules["derivedAuthorityRequired"],
        json!(true)
    );
}

#[tokio::test]
async fn request_and_decision_record_list_inspect_replay_are_bounded() {
    let fixture = Fixture::new("module-install-happy").await;
    let validation_report_id = fixture.passed_validation_report("passed-validation").await;
    let request = fixture
        .install_request("install-request", &validation_report_id)
        .await;
    assert_eq!(request["status"], json!("pending_review"));
    assert_eq!(request["idempotentReplay"], json!(false));
    let request_id = request["moduleInstallRequestResourceId"].as_str().unwrap();
    let request_replay = fixture
        .install_request("install-request", &validation_report_id)
        .await;
    assert_eq!(request_replay["idempotentReplay"], json!(true));

    let approval = fixture
        .approval("approval", request_id, &validation_report_id)
        .await;
    let decision_payload = decision_payload(
        request_id,
        approval["requestResourceId"].as_str().unwrap(),
        approval["decisionResourceId"].as_str().unwrap(),
        "approved",
    );
    let decision = fixture
        .decision("install-decision", decision_payload)
        .await
        .expect("record install decision");
    assert_eq!(decision["status"], json!("install_candidate"));
    let decision_id = decision["moduleInstallDecisionResourceId"]
        .as_str()
        .unwrap();
    let stored = fixture
        .deps
        .engine_host
        .inspect_resource(decision_id)
        .await
        .expect("inspect decision")
        .expect("decision resource");
    assert_eq!(stored.resource.kind, MODULE_INSTALL_DECISION_KIND);
    assert_eq!(stored.resource.schema_id, MODULE_INSTALL_DECISION_SCHEMA_ID);

    let request_list = list_module_install_request_value(
        &fixture.deps,
        &fixture.read_invocation("list-requests", json!({})),
        &json!({}),
    )
    .await
    .expect("list requests");
    assert_eq!(request_list["installRequests"].as_array().unwrap().len(), 1);
    let decision_list = list_module_install_decision_value(
        &fixture.deps,
        &fixture.read_invocation("list-decisions", json!({})),
        &json!({}),
    )
    .await
    .expect("list decisions");
    assert_eq!(
        decision_list["installDecisions"].as_array().unwrap().len(),
        1
    );

    let request_exact = fixture.exact_read_grant("request-exact", request_id).await;
    let request_inspect_invocation = invocation(
        "inspect-request",
        json!({"moduleInstallRequestResourceId": request_id}),
        request_exact,
        &[READ_SCOPE, RESOURCE_READ_SCOPE],
        &fixture.session_id,
    );
    let inspected_request = inspect_module_install_request_value(
        &fixture.deps,
        &request_inspect_invocation,
        &request_inspect_invocation.payload,
    )
    .await
    .expect("inspect request");
    assert_eq!(
        inspected_request["installRequest"]["projection"]["allowlist"],
        json!("module_install_metadata_redacted_v1")
    );

    let decision_exact = fixture
        .exact_read_grant("decision-exact", decision_id)
        .await;
    let decision_inspect_invocation = invocation(
        "inspect-decision",
        json!({"moduleInstallDecisionResourceId": decision_id}),
        decision_exact,
        &[READ_SCOPE, RESOURCE_READ_SCOPE],
        &fixture.session_id,
    );
    let inspected_decision = inspect_module_install_decision_value(
        &fixture.deps,
        &decision_inspect_invocation,
        &decision_inspect_invocation.payload,
    )
    .await
    .expect("inspect decision");
    assert_no_leaks(
        "module install projection",
        &inspected_decision,
        &["grant-", "authorityId", "/Users/"],
    );
    assert_eq!(
        inspected_decision["installDecision"]["projection"]["rawCommandsReturned"],
        json!(false)
    );
    assert_eq!(
        inspected_decision["installDecision"]["projection"]["debugPayloadReturned"],
        json!(false)
    );
    assert_eq!(
        inspected_decision["installDecision"]["installDecision"]["approval"]["approvalEvidenceOnly"],
        json!(true)
    );
}

#[tokio::test]
async fn approval_denials_fail_closed() {
    let fixture = Fixture::new("module-install-approval-denial").await;
    let validation_report_id = fixture
        .passed_validation_report("approval-validation")
        .await;
    let request = fixture
        .install_request("approval-request", &validation_report_id)
        .await;
    let request_id = request["moduleInstallRequestResourceId"].as_str().unwrap();
    let missing = fixture
        .decision(
            "missing-approval",
            decision_payload(
                request_id,
                "approval_request:missing",
                "approval_decision:missing",
                "approved",
            ),
        )
        .await
        .expect_err("missing approval denied");
    assert!(missing.contains("approval_request_missing"), "{missing}");

    let approval_request_invocation = approval_invocation(
        "wrong-risk-request",
        json!({
            "action": approval_action(),
            "scope": scope_ref(&fixture.session_id),
            "riskClass": "high",
            "expiresAt": future_time(30),
            "evidenceRefs": [{"kind": "evidence", "resourceId": "evidence:wrong-risk"}],
            "resourceSelectors": approval_selectors(request_id, &validation_report_id),
            "denialBehavior": {"mode": "fail_closed"}
        }),
        "wrong-risk",
        &fixture.session_id,
    );
    let approval_request = crate::domains::approval::service::request_approval_value(
        &fixture.deps.engine_host,
        &approval_request_invocation,
        &approval_request_invocation.payload,
    )
    .await
    .expect("request wrong-risk approval");
    let denied = fixture
        .decision(
            "pending-approval",
            decision_payload(
                request_id,
                approval_request["requestResourceId"].as_str().unwrap(),
                "approval_decision:missing",
                "approved",
            ),
        )
        .await
        .expect_err("pending/mismatched approval denied");
    assert!(
        denied.contains("approval_request_risk_mismatch")
            || denied.contains("approval_decision_missing"),
        "{denied}"
    );
}

#[tokio::test]
async fn validation_prerequisite_and_unsafe_payloads_are_denied_before_storage() {
    let fixture = Fixture::new("module-install-prereq").await;
    let missing = fixture
        .request_error(
            "missing-validation",
            request_payload("module_validation_report:missing"),
        )
        .await;
    assert!(
        missing.contains("missing module validation report"),
        "{missing}"
    );

    let validation_report_id = fixture.passed_validation_report("unsafe-validation").await;
    for (label, field, value, expected) in [
        (
            "raw-path",
            "summary",
            json!("/Users/example/module"),
            "unsafe path",
        ),
        ("raw-command", "title", json!("cargo test"), "shell-command"),
        ("debug", "debugPayload", json!({"x": true}), "not accepted"),
        (
            "token",
            "installRequestId",
            json!("github_pat_11AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"),
            "token-like",
        ),
    ] {
        let mut payload = request_payload(&validation_report_id);
        payload[field] = value;
        let denied = fixture.request_error(label, payload).await;
        assert!(denied.contains(expected), "{label}: {denied}");
    }

    let resources = fixture
        .deps
        .engine_host
        .list_resources(ListResources {
            kind: Some(MODULE_INSTALL_REQUEST_KIND.to_owned()),
            scope: None,
            lifecycle: None,
            limit: 10,
        })
        .await
        .expect("list install requests after denial");
    assert!(
        resources.is_empty(),
        "unsafe module install payloads must be rejected before storage"
    );
}

#[tokio::test]
async fn install_inspect_requires_exact_resource_selector() {
    let fixture = Fixture::new("module-install-selector").await;
    let validation_report_id = fixture
        .passed_validation_report("selector-validation")
        .await;
    let request = fixture
        .install_request("selector-request", &validation_report_id)
        .await;
    let request_id = request["moduleInstallRequestResourceId"].as_str().unwrap();
    let invocation = fixture.read_invocation(
        "selector-denied",
        json!({"moduleInstallRequestResourceId": request_id}),
    );
    let denied =
        inspect_module_install_request_value(&fixture.deps, &invocation, &invocation.payload)
            .await
            .expect_err("kind-only read grant denied")
            .to_string();
    assert!(denied.contains("requires exact resource:"), "{denied}");
}

fn validation_payload() -> Value {
    json!({
        "reportId": "slice-23d-validation-report",
        "lifecycleState": "passed",
        "title": "Module Validation Harness",
        "summary": "Bounded validation evidence for module install review.",
        "moduleRefs": [{"kind": "module_manifest", "resourceId": "module_manifest:module_registry", "role": "module"}],
        "proposalRefs": [{"kind": "module_proposal", "resourceId": "module_proposal:proposal_23d", "role": "proposal"}],
        "manifestProjectionParity": [{"name": "manifest_projection", "status": "passed", "summary": "Manifest declarations matched provider projection.", "fingerprint": "sha256:manifest_parity"}],
        "resourceProjectionParity": [{"name": "resource_projection", "status": "passed", "summary": "Resource schema and kind matched stored report.", "fingerprint": "sha256:resource_parity"}],
        "providerProjectionParity": [{"name": "provider_projection", "status": "passed", "summary": "Provider metadata stayed bounded and redacted.", "fingerprint": "sha256:provider_parity"}],
        "docEvidence": [{"kind": "prompt_artifact", "resourceId": "prompt_artifact:docs", "role": "docs", "fingerprint": "sha256:docs"}],
        "testEvidence": [{"kind": "prompt_artifact", "resourceId": "prompt_artifact:tests", "role": "tests", "fingerprint": "sha256:tests"}],
        "commandRefs": [{"kind": "command_identity", "id": "cmd:cargo-test-module-validation", "role": "command_identity", "fingerprint": "sha256:command_identity", "preview": "focused module validation test command identity"}],
        "resultRefs": [{"kind": "command_result", "id": "result:cargo-test-module-validation", "role": "result_ref", "status": "passed", "fingerprint": "sha256:command_result", "preview": "bounded deterministic result reference"}],
        "failureEvidence": [],
        "traceRefs": [{"kind": "trace", "id": "trace-module-validation", "role": "trace"}],
        "replayRefs": [{"kind": "replay", "id": "replay-module-validation", "role": "replay"}],
        "validationStatus": "passed",
        "validationChecks": [{"name": "docs_tests_present", "status": "passed", "summary": "Docs and tests evidence refs are present.", "fingerprint": "sha256:docs_tests"}]
    })
}

fn request_payload(validation_report_id: &str) -> Value {
    json!({
        "installRequestId": "slice-23d-install-review",
        "title": "Module Install Review",
        "summary": "Review a passed validation report as a metadata-only install candidate.",
        "moduleValidationReportResourceId": validation_report_id,
        "dependencyPolicyRefs": [{"kind": "policy", "id": "dependency-policy:bounded", "role": "dependency_policy"}],
        "dependencyPolicyStatus": "linked",
        "rollbackProofRefs": [{"kind": "evidence", "id": "rollback-proof:bounded", "role": "rollback_proof"}],
        "rollbackReadiness": "ready",
        "evidenceRefs": [{"kind": "evidence", "id": "review-evidence:bounded", "role": "review"}]
    })
}

fn decision_payload(
    request_id: &str,
    approval_request_id: &str,
    approval_decision_id: &str,
    decision: &str,
) -> Value {
    json!({
        "installDecisionId": "slice-23d-install-decision",
        "moduleInstallRequestResourceId": request_id,
        "decision": decision,
        "reason": "User review approved this metadata-only install candidate.",
        "approvalRequestResourceId": approval_request_id,
        "approvalDecisionResourceId": approval_decision_id,
        "denialEvidence": if decision == "approved" {
            json!([])
        } else {
            json!([{"kind": "evidence", "id": "denial-evidence:bounded", "role": "denial"}])
        }
    })
}

fn approval_action() -> Value {
    json!({
        "kind": "module_install",
        "operation": "module_install_decision_record",
        "metadataOnly": true
    })
}

fn approval_selectors(request_id: &str, validation_report_id: &str) -> Vec<Value> {
    vec![
        json!({"kind": MODULE_INSTALL_REQUEST_KIND, "resourceId": request_id}),
        json!({"kind": "module_validation_report", "resourceId": validation_report_id}),
    ]
}

fn approval_invocation(
    key: &str,
    payload: Value,
    idempotency: &str,
    session_id: &str,
) -> Invocation {
    let context = CausalContext::new(
        ActorId::new(format!("agent:{session_id}")).unwrap(),
        ActorKind::Agent,
        AuthorityGrantId::new("engine-system").unwrap(),
        TraceId::new(format!("trace-{key}")).unwrap(),
    )
    .with_scope(crate::domains::approval::WRITE_SCOPE)
    .with_workspace_id("workspace-module-install")
    .with_session_id(session_id.to_owned())
    .with_idempotency_key(format!("approval-{idempotency}-{key}"));
    Invocation {
        id: InvocationId::new(format!("invocation-{key}")).unwrap(),
        function_id: FunctionId::new("approval::request").unwrap(),
        delivery_mode: crate::engine::DeliveryMode::Sync,
        payload,
        causal_context: context,
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
            grant_id: Some(AuthorityGrantId::new(format!("module-install-{suffix}")).unwrap()),
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
            budget: json!({"class": "module_install_test"}),
            expires_at: None,
            can_delegate: false,
            provenance: json!({"source": "module_install_test"}),
            trace_id: TraceId::new(format!("trace-module-install-{suffix}")).unwrap(),
        })
        .await
        .expect("derive grant");
    grant.grant_id
}

fn invocation(
    key: &str,
    payload: Value,
    grant_id: AuthorityGrantId,
    scopes: &[&str],
    session_id: &str,
) -> Invocation {
    let mut context = CausalContext::new(
        ActorId::new(format!("agent:{session_id}")).unwrap(),
        ActorKind::Agent,
        grant_id,
        TraceId::new(format!("trace-{key}")).unwrap(),
    )
    .with_workspace_id("workspace-module-install")
    .with_session_id(session_id.to_owned())
    .with_idempotency_key(key.to_owned());
    for scope in scopes {
        context = context.with_scope(*scope);
    }
    Invocation {
        id: InvocationId::new(format!("invocation-{key}")).unwrap(),
        function_id: FunctionId::new("capability::execute").unwrap(),
        delivery_mode: crate::engine::DeliveryMode::Sync,
        payload,
        causal_context: context,
    }
}

fn default_operation_at() -> DateTime<Utc> {
    DateTime::parse_from_rfc3339(DEFAULT_OPERATION_AT)
        .expect("test timestamp")
        .with_timezone(&Utc)
}

fn future_time(minutes: i64) -> String {
    (default_operation_at() + Duration::minutes(minutes)).to_rfc3339()
}

fn scope_ref(session_id: &str) -> Value {
    json!({"kind": "session", "value": session_id})
}

fn assert_no_leaks(label: &str, value: &Value, needles: &[&str]) {
    let serialized = serde_json::to_string(value).expect("serialize value");
    for needle in needles {
        assert!(
            !serialized.contains(needle),
            "{label} leaked forbidden string {needle}: {serialized}"
        );
    }
}
