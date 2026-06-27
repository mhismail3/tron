use chrono::{DateTime, Duration, Utc};
use serde_json::{Value, json};

use super::contract::{READ_SCOPE, RESOURCE_READ_SCOPE, RESOURCE_WRITE_SCOPE, WRITE_SCOPE};
use super::records::module_lifecycle_resource_id;
use super::service::{
    decide_module_lifecycle_value_at, ensure_runtime_allowed, inspect_module_lifecycle_value,
    request_module_lifecycle_value_at,
};
use super::{Deps, MODULE_LIFECYCLE_STATE_KIND, MODULE_LIFECYCLE_STATE_SCHEMA_ID};
use crate::engine::{
    ActorId, ActorKind, AuthorityGrantId, CausalContext, CreateResource, DeriveGrant,
    EngineResourceLocation, EngineResourceScope, FunctionId, Invocation, InvocationId,
    MODULE_INSTALL_DECISION_KIND, MODULE_INSTALL_DECISION_SCHEMA_ID, RiskLevel, TraceId,
    builtin_resource_type_definitions,
};
use crate::shared::server::test_support::make_test_context;

const DEFAULT_OPERATION_AT: &str = "2026-06-26T12:00:00Z";

struct Fixture {
    deps: Deps,
    session_id: String,
    install_decision_id: String,
    lifecycle_id: String,
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
        let scope = EngineResourceScope::Session(session_id.clone());
        let install_decision_id = format!("module_install_decision:{label}-candidate");
        deps.engine_host
            .create_resource(CreateResource {
                resource_id: Some(install_decision_id.clone()),
                kind: MODULE_INSTALL_DECISION_KIND.to_owned(),
                schema_id: Some(MODULE_INSTALL_DECISION_SCHEMA_ID.to_owned()),
                scope: scope.clone(),
                owner_worker_id: crate::engine::WorkerId::new("module_install").unwrap(),
                owner_actor_id: ActorId::new(format!("agent:{session_id}")).unwrap(),
                lifecycle: Some("install_candidate".to_owned()),
                policy: json!({"metadataOnly": true, "networkPolicy": "none"}),
                initial_payload: Some(install_decision_payload()),
                locations: vec![EngineResourceLocation {
                    kind: "module_install_decision".to_owned(),
                    uri: format!("module-install-decision:{label}"),
                    mime_type: Some("application/json".to_owned()),
                    size_bytes: None,
                }],
                trace_id: TraceId::new(format!("trace-install-{label}")).unwrap(),
                invocation_id: None,
            })
            .await
            .expect("seed install candidate");
        let lifecycle_id = module_lifecycle_resource_id(&scope, &install_decision_id);
        let write_grant_id = derive_grant(
            &deps,
            &format!("{label}-write"),
            &[
                READ_SCOPE,
                WRITE_SCOPE,
                RESOURCE_READ_SCOPE,
                RESOURCE_WRITE_SCOPE,
            ],
            &[MODULE_LIFECYCLE_STATE_KIND],
            &[
                "kind:module_lifecycle_state",
                lifecycle_selector(&lifecycle_id).as_str(),
            ],
        )
        .await;
        let read_grant_id = derive_grant(
            &deps,
            &format!("{label}-read"),
            &[READ_SCOPE, RESOURCE_READ_SCOPE],
            &[MODULE_LIFECYCLE_STATE_KIND],
            &[
                "kind:module_lifecycle_state",
                lifecycle_selector(&lifecycle_id).as_str(),
            ],
        )
        .await;
        Self {
            deps,
            session_id,
            install_decision_id,
            lifecycle_id,
            write_grant_id,
            read_grant_id,
        }
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

    async fn approval(&self, key: &str, action: &str) -> Value {
        let request_invocation = approval_invocation(
            &format!("{key}-request"),
            json!({
                "action": approval_action(action),
                "scope": scope_ref(&self.session_id),
                "riskClass": "medium",
                "expiresAt": future_time(30),
                "freshness": {"staleAt": future_time(20)},
                "evidenceRefs": [{"kind": "evidence", "resourceId": "evidence:module-lifecycle-approval"}],
                "resourceSelectors": [
                    {"kind": MODULE_LIFECYCLE_STATE_KIND, "resourceId": self.lifecycle_id},
                    {"kind": MODULE_INSTALL_DECISION_KIND, "resourceId": self.install_decision_id}
                ],
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
}

#[test]
fn module_lifecycle_resource_type_is_registered_with_metadata_only_bounds() {
    let definitions = builtin_resource_type_definitions();
    let definition = definitions
        .iter()
        .find(|definition| definition.kind == MODULE_LIFECYCLE_STATE_KIND)
        .expect("module lifecycle definition");
    assert_eq!(definition.schema_id, MODULE_LIFECYCLE_STATE_SCHEMA_ID);
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
        definition.materialization_rules["execution"],
        json!("forbidden")
    );
    assert_eq!(
        definition.materialization_rules["runtimeGuard"],
        json!("fail_closed_disabled_quarantined")
    );
}

#[tokio::test]
async fn lifecycle_request_decision_inspect_and_runtime_denial_are_bounded() {
    let fixture = Fixture::new("module-lifecycle-disable").await;
    let request = request_module_lifecycle_value_at(
        &fixture.deps,
        &fixture.write_invocation(
            "lifecycle-request",
            request_payload(&fixture.install_decision_id, "disable"),
        ),
        &request_payload(&fixture.install_decision_id, "disable"),
        default_operation_at(),
    )
    .await
    .expect("request lifecycle");
    assert_eq!(request["status"], json!("pending"));
    let version_id = request["moduleLifecycleVersionId"].as_str().unwrap();
    let approval = fixture.approval("disable-approval", "disable").await;
    let decision = decide_module_lifecycle_value_at(
        &fixture.deps,
        &fixture.write_invocation(
            "lifecycle-decision",
            json!({
                "moduleLifecycleResourceId": fixture.lifecycle_id,
                "expectedModuleLifecycleVersionId": version_id,
                "decision": "approved",
                "reason": "User approved metadata-only disable state.",
                "approvalRequestResourceId": approval["requestResourceId"],
                "approvalDecisionResourceId": approval["decisionResourceId"]
            }),
        ),
        &json!({
            "moduleLifecycleResourceId": fixture.lifecycle_id,
            "expectedModuleLifecycleVersionId": version_id,
            "decision": "approved",
            "reason": "User approved metadata-only disable state.",
            "approvalRequestResourceId": approval["requestResourceId"],
            "approvalDecisionResourceId": approval["decisionResourceId"]
        }),
        default_operation_at(),
    )
    .await
    .expect("decide lifecycle");
    assert_eq!(decision["status"], json!("disabled"));
    let inspected = inspect_module_lifecycle_value(
        &fixture.deps,
        &fixture.read_invocation(
            "inspect-lifecycle",
            json!({"moduleLifecycleResourceId": fixture.lifecycle_id}),
        ),
        &json!({"moduleLifecycleResourceId": fixture.lifecycle_id}),
    )
    .await
    .expect("inspect lifecycle");
    assert_eq!(
        inspected["moduleLifecycle"]["projection"]["allowlist"],
        json!("module_lifecycle_metadata_redacted_v1")
    );
    assert_no_leaks("module lifecycle projection", &inspected);
    let denied = ensure_runtime_allowed(
        &fixture.deps,
        &EngineResourceScope::Session(fixture.session_id.clone()),
        &fixture.lifecycle_id,
    )
    .await
    .expect_err("disabled runtime denied")
    .to_string();
    assert!(denied.contains("fail-closed"), "{denied}");
}

#[tokio::test]
async fn lifecycle_request_after_decision_records_fresh_pending_transition() {
    let fixture = Fixture::new("module-lifecycle-follow-up").await;
    let disable_request = request_module_lifecycle_value_at(
        &fixture.deps,
        &fixture.write_invocation(
            "disable-request",
            request_payload(&fixture.install_decision_id, "disable"),
        ),
        &request_payload(&fixture.install_decision_id, "disable"),
        default_operation_at(),
    )
    .await
    .expect("request disable lifecycle");
    let disable_request_version = disable_request["moduleLifecycleVersionId"]
        .as_str()
        .expect("disable request version");
    let approval = fixture.approval("follow-up-disable", "disable").await;
    let disable_decision = decide_module_lifecycle_value_at(
        &fixture.deps,
        &fixture.write_invocation(
            "disable-decision",
            json!({
                "moduleLifecycleResourceId": fixture.lifecycle_id,
                "expectedModuleLifecycleVersionId": disable_request_version,
                "decision": "approved",
                "reason": "User approved metadata-only disable state.",
                "approvalRequestResourceId": approval["requestResourceId"],
                "approvalDecisionResourceId": approval["decisionResourceId"]
            }),
        ),
        &json!({
            "moduleLifecycleResourceId": fixture.lifecycle_id,
            "expectedModuleLifecycleVersionId": disable_request_version,
            "decision": "approved",
            "reason": "User approved metadata-only disable state.",
            "approvalRequestResourceId": approval["requestResourceId"],
            "approvalDecisionResourceId": approval["decisionResourceId"]
        }),
        default_operation_at(),
    )
    .await
    .expect("decide disable lifecycle");
    assert_eq!(disable_decision["status"], json!("disabled"));
    let disabled_version = disable_decision["moduleLifecycleVersionId"]
        .as_str()
        .expect("disabled version")
        .to_owned();

    let enable_request = request_module_lifecycle_value_at(
        &fixture.deps,
        &fixture.write_invocation(
            "enable-request",
            request_payload(&fixture.install_decision_id, "enable"),
        ),
        &request_payload(&fixture.install_decision_id, "enable"),
        default_operation_at() + Duration::minutes(1),
    )
    .await
    .expect("request enable lifecycle after disable");
    let enable_version = enable_request["moduleLifecycleVersionId"]
        .as_str()
        .expect("enable request version");
    assert_eq!(enable_request["status"], json!("pending"));
    assert_eq!(enable_request["idempotentReplay"], json!(false));
    assert_ne!(enable_version, disabled_version);
    assert_eq!(
        enable_request["moduleLifecycle"]["transition"]["action"],
        json!("enable")
    );
    assert_eq!(
        enable_request["moduleLifecycle"]["transition"]["from"],
        json!("disabled")
    );

    let inspected = inspect_module_lifecycle_value(
        &fixture.deps,
        &fixture.read_invocation(
            "inspect-follow-up",
            json!({"moduleLifecycleResourceId": fixture.lifecycle_id}),
        ),
        &json!({"moduleLifecycleResourceId": fixture.lifecycle_id}),
    )
    .await
    .expect("inspect follow-up lifecycle");
    assert_eq!(inspected["moduleLifecycle"]["lifecycle"], json!("pending"));
    assert_eq!(
        inspected["moduleLifecycle"]["moduleLifecycle"]["previous"]["state"],
        json!("disabled")
    );
    assert_eq!(
        inspected["moduleLifecycle"]["moduleLifecycle"]["previous"]["versionId"],
        json!(disabled_version)
    );
    assert_eq!(
        inspected["moduleLifecycle"]["moduleLifecycle"]["previous"]["currentVersionRevalidated"],
        json!(true)
    );
}

#[tokio::test]
async fn rollback_requires_ready_proof_refs_and_prerequisite_candidate() {
    let fixture = Fixture::new("module-lifecycle-rollback").await;
    let denied = request_module_lifecycle_value_at(
        &fixture.deps,
        &fixture.write_invocation(
            "rollback-denied",
            json!({
                "moduleInstallDecisionResourceId": fixture.install_decision_id,
                "lifecycleAction": "rollback",
                "reason": "Record a metadata-only rollback without proof."
            }),
        ),
        &json!({
            "moduleInstallDecisionResourceId": fixture.install_decision_id,
            "lifecycleAction": "rollback",
            "reason": "Record a metadata-only rollback without proof."
        }),
        default_operation_at(),
    )
    .await
    .expect_err("rollback without proof denied")
    .to_string();
    assert!(denied.contains("rollback requires ready"), "{denied}");

    let missing = request_module_lifecycle_value_at(
        &fixture.deps,
        &fixture.write_invocation(
            "missing-install",
            request_payload("module_install_decision:missing", "disable"),
        ),
        &request_payload("module_install_decision:missing", "disable"),
        default_operation_at(),
    )
    .await
    .expect_err("missing install candidate denied")
    .to_string();
    assert!(
        missing.contains("missing module install decision"),
        "{missing}"
    );
}

#[tokio::test]
async fn lifecycle_inspect_requires_exact_resource_selector() {
    let fixture = Fixture::new("module-lifecycle-selector").await;
    request_module_lifecycle_value_at(
        &fixture.deps,
        &fixture.write_invocation(
            "selector-request",
            request_payload(&fixture.install_decision_id, "disable"),
        ),
        &request_payload(&fixture.install_decision_id, "disable"),
        default_operation_at(),
    )
    .await
    .expect("request lifecycle");
    let broad_grant = derive_grant(
        &fixture.deps,
        "selector-broad",
        &[READ_SCOPE, RESOURCE_READ_SCOPE],
        &[MODULE_LIFECYCLE_STATE_KIND],
        &["kind:module_lifecycle_state"],
    )
    .await;
    let denied = inspect_module_lifecycle_value(
        &fixture.deps,
        &invocation(
            "selector-denied",
            json!({"moduleLifecycleResourceId": fixture.lifecycle_id}),
            broad_grant,
            &[READ_SCOPE, RESOURCE_READ_SCOPE],
            &fixture.session_id,
        ),
        &json!({"moduleLifecycleResourceId": fixture.lifecycle_id}),
    )
    .await
    .expect_err("kind-only read grant denied")
    .to_string();
    assert!(denied.contains("requires exact resource:"), "{denied}");
}

fn install_decision_payload() -> Value {
    json!({
        "schemaVersion": "tron.module_install_decision.v1",
        "state": "install_candidate",
        "decisionId": "seed-install-candidate",
        "scope": {"kind": "session", "value": "seed"},
        "request": {"kind": "module_install_request", "resourceId": "module_install_request:seed", "versionId": "version:request", "role": "install_request"},
        "validationReport": {"kind": "module_validation_report", "resourceId": "module_validation_report:seed", "versionId": "version:validation", "status": "passed"},
        "approval": {"allowed": true, "approvalEvidenceOnly": true, "derivedAuthorityRequired": true, "rawAuthorityIdsStored": false},
        "decision": {"state": "install_candidate", "result": "approved", "reason": "Seed install candidate.", "denialEvidence": [], "metadataOnly": true, "installPerformed": false},
        "dependencyPolicy": {"refs": [], "status": "not_required", "metadataOnly": true, "restored": false, "packageManagerUsed": false},
        "rollback": {"proofRefs": [{"kind": "evidence", "id": "rollback-proof:seed", "role": "rollback_proof"}], "status": "ready", "metadataOnly": true, "rollbackExecuted": false},
        "traceRefs": [],
        "replayRefs": [],
        "authority": {"grantRedacted": true, "rawAuthorityIdsStored": false, "derivedRuntimeGrantRequired": true, "approvalEvidenceIsAuthority": false},
        "idempotency": {"fingerprint": "seed", "fingerprintAlgorithm": "sha256:test", "keyRedacted": true, "rawKeyStored": false},
        "sideEffectProof": side_effect_proof(),
        "createdAt": DEFAULT_OPERATION_AT,
        "updatedAt": DEFAULT_OPERATION_AT,
        "revision": 1
    })
}

fn side_effect_proof() -> Value {
    json!({
        "metadataOnly": true,
        "installPerformed": false,
        "activationPerformed": false,
        "executionPerformed": false,
        "dependencyRestorePerformed": false,
        "packageManagerUsed": false,
        "networkPolicy": "none",
        "networkAccessPerformed": false,
        "repoManagedSkillsTouched": false,
        "physicalWorkspaceDirectoryCreated": false,
        "rawCommandsStored": false,
        "rawLogsStored": false,
        "fileContentsStored": false,
        "absolutePathsStored": false
    })
}

fn request_payload(install_decision_id: &str, action: &str) -> Value {
    let mut payload = json!({
        "moduleInstallDecisionResourceId": install_decision_id,
        "lifecycleAction": action,
        "reason": "Record a metadata-only module lifecycle transition.",
        "evidenceRefs": [{"kind": "evidence", "id": "lifecycle-evidence:bounded", "role": "lifecycle"}]
    });
    if action == "rollback" {
        payload["rollbackProofRefs"] =
            json!([{"kind": "evidence", "id": "rollback-proof:bounded", "role": "rollback_proof"}]);
        payload["rollbackReadiness"] = json!("ready");
    }
    payload
}

async fn derive_grant(
    deps: &Deps,
    suffix: &str,
    scopes: &[&str],
    resource_kinds: &[&str],
    selectors: &[&str],
) -> AuthorityGrantId {
    let grant = deps
        .engine_host
        .derive_authority_grant(DeriveGrant {
            grant_id: Some(AuthorityGrantId::new(format!("module-lifecycle-{suffix}")).unwrap()),
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
            network_policy: "none".to_owned(),
            max_risk: RiskLevel::Low,
            budget: json!({"class": "module_lifecycle_test"}),
            expires_at: None,
            can_delegate: false,
            provenance: json!({"source": "module_lifecycle_test"}),
            trace_id: TraceId::new(format!("trace-module-lifecycle-{suffix}")).unwrap(),
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
    .with_workspace_id("workspace-module-lifecycle")
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

fn approval_action(action: &str) -> Value {
    json!({
        "kind": "module_lifecycle",
        "operation": "module_lifecycle_decision",
        "lifecycleAction": action,
        "metadataOnly": true
    })
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
    .with_workspace_id("workspace-module-lifecycle")
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

fn lifecycle_selector(resource_id: &str) -> String {
    format!("resource:{resource_id}")
}

fn assert_no_leaks(label: &str, value: &Value) {
    let serialized = serde_json::to_string(value).expect("serialize value");
    for needle in ["grant-", "authorityId", "/Users/"] {
        assert!(
            !serialized.contains(needle),
            "{label} leaked forbidden string {needle}: {serialized}"
        );
    }
}
