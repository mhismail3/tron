use chrono::{DateTime, Utc};
use serde_json::{Value, json};

use super::contract::{READ_SCOPE, RESOURCE_READ_SCOPE, RESOURCE_WRITE_SCOPE, WRITE_SCOPE};
use super::records::module_runtime_resource_id;
use super::service::{
    cancel_module_runtime_value_at, inspect_module_runtime_value, list_module_runtime_value,
    request_module_runtime_value_at,
};
use super::{Deps, MODULE_RUNTIME_STATE_KIND, MODULE_RUNTIME_STATE_SCHEMA_ID};
use crate::engine::{
    ActorId, ActorKind, AuthorityGrantId, CausalContext, CreateResource, DeriveGrant,
    EngineResourceLocation, EngineResourceScope, FunctionId, Invocation, InvocationId,
    MODULE_LIFECYCLE_STATE_KIND, MODULE_LIFECYCLE_STATE_SCHEMA_ID, RiskLevel, TraceId,
    builtin_resource_type_definitions,
};
use crate::shared::server::test_support::make_test_context;

const DEFAULT_OPERATION_AT: &str = "2026-06-27T12:00:00Z";

struct Fixture {
    deps: Deps,
    session_id: String,
    lifecycle_id: String,
    write_grant_id: AuthorityGrantId,
    read_grant_id: AuthorityGrantId,
}

impl Fixture {
    async fn new(label: &str, lifecycle_state: &str) -> Self {
        let ctx = make_test_context();
        let deps = Deps {
            engine_host: ctx.engine_host.clone(),
        };
        let session_id = format!("{label}-session");
        let scope = EngineResourceScope::Session(session_id.clone());
        let lifecycle_id = format!("module_lifecycle_state:{label}");
        deps.engine_host
            .create_resource(CreateResource {
                resource_id: Some(lifecycle_id.clone()),
                kind: MODULE_LIFECYCLE_STATE_KIND.to_owned(),
                schema_id: Some(MODULE_LIFECYCLE_STATE_SCHEMA_ID.to_owned()),
                scope: scope.clone(),
                owner_worker_id: crate::engine::WorkerId::new("module_lifecycle").unwrap(),
                owner_actor_id: ActorId::new(format!("agent:{session_id}")).unwrap(),
                lifecycle: Some(lifecycle_state.to_owned()),
                policy: json!({"metadataOnly": true, "networkPolicy": "none"}),
                initial_payload: Some(lifecycle_payload(lifecycle_state, &lifecycle_id)),
                locations: vec![EngineResourceLocation {
                    kind: "module_lifecycle_state".to_owned(),
                    uri: format!("module-lifecycle-state:{label}"),
                    mime_type: Some("application/json".to_owned()),
                    size_bytes: None,
                }],
                trace_id: TraceId::new(format!("trace-lifecycle-{label}")).unwrap(),
                invocation_id: None,
            })
            .await
            .expect("seed lifecycle state");
        let runtime_id = module_runtime_resource_id(&scope, &lifecycle_id, "runtime-request-1");
        let write_grant_id = derive_grant(
            &deps,
            &format!("{label}-write"),
            &[
                READ_SCOPE,
                WRITE_SCOPE,
                RESOURCE_READ_SCOPE,
                RESOURCE_WRITE_SCOPE,
            ],
            &[MODULE_RUNTIME_STATE_KIND, MODULE_LIFECYCLE_STATE_KIND],
            &[
                "kind:module_runtime_state",
                "kind:module_lifecycle_state",
                runtime_selector(&runtime_id).as_str(),
                lifecycle_selector(&lifecycle_id).as_str(),
            ],
        )
        .await;
        let read_grant_id = derive_grant(
            &deps,
            &format!("{label}-read"),
            &[READ_SCOPE, RESOURCE_READ_SCOPE],
            &[MODULE_RUNTIME_STATE_KIND],
            &[
                "kind:module_runtime_state",
                runtime_selector(&runtime_id).as_str(),
            ],
        )
        .await;
        Self {
            deps,
            session_id,
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

    async fn request(&self, key: &str) -> Value {
        request_module_runtime_value_at(
            &self.deps,
            &self.write_invocation(key, request_payload(&self.lifecycle_id)),
            &request_payload(&self.lifecycle_id),
            default_operation_at(),
        )
        .await
        .expect("request module runtime")
    }
}

#[test]
fn module_runtime_resource_type_is_registered_with_supervisor_bounds() {
    let definitions = builtin_resource_type_definitions();
    let definition = definitions
        .iter()
        .find(|definition| definition.kind == MODULE_RUNTIME_STATE_KIND)
        .expect("module runtime definition");
    assert_eq!(definition.schema_id, MODULE_RUNTIME_STATE_SCHEMA_ID);
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
        definition.materialization_rules["providerOutput"],
        json!("refs_only")
    );
}

#[tokio::test]
async fn enabled_lifecycle_records_runtime_envelope_and_redacted_projection() {
    let fixture = Fixture::new("module-runtime-enabled", "enabled").await;
    let created = fixture.request("runtime-request").await;
    assert_eq!(created["status"], json!("running"));
    assert_eq!(
        created["moduleRuntime"]["supervision"]["network"]["policy"],
        json!("none")
    );
    assert_eq!(
        created["moduleRuntime"]["outputArtifactRefs"]["items"][0]["resourceId"],
        json!("execution_output:bounded")
    );

    let resource_id = created["moduleRuntimeResourceId"].as_str().unwrap();
    let inspected = inspect_module_runtime_value(
        &fixture.deps,
        &fixture.read_invocation(
            "runtime-inspect",
            json!({"moduleRuntimeResourceId": resource_id}),
        ),
        &json!({"moduleRuntimeResourceId": resource_id}),
    )
    .await
    .expect("inspect runtime");
    let serialized = serde_json::to_string(&inspected).unwrap();
    for forbidden in [
        "\"rawCommand\"",
        "\"stdout\"",
        "\"stderr\"",
        "secret=",
        "/Users/",
        "\"rawAuthorityId\"",
    ] {
        assert!(
            !serialized.contains(forbidden),
            "projection leaked forbidden material {forbidden}: {serialized}"
        );
    }
    assert_eq!(
        inspected["moduleRuntime"]["moduleRuntime"]["sideEffectProof"]["rawOutputStored"],
        json!(false)
    );
}

#[tokio::test]
async fn disabled_quarantined_and_rolled_back_lifecycle_states_deny_runtime_before_create() {
    for state in ["disabled", "quarantined", "rolled_back"] {
        let fixture = Fixture::new(&format!("module-runtime-{state}"), state).await;
        let error = request_module_runtime_value_at(
            &fixture.deps,
            &fixture.write_invocation("runtime-denied", request_payload(&fixture.lifecycle_id)),
            &request_payload(&fixture.lifecycle_id),
            default_operation_at(),
        )
        .await
        .expect_err("runtime request must fail closed");
        assert!(
            error
                .to_string()
                .contains("module runtime denied fail-closed"),
            "{error}"
        );
        let list = list_module_runtime_value(
            &fixture.deps,
            &fixture.read_invocation("runtime-list", json!({})),
            &json!({}),
        )
        .await
        .expect("list runtime");
        assert_eq!(list["moduleRuntimes"].as_array().unwrap().len(), 0);
    }
}

#[tokio::test]
async fn runtime_request_is_idempotent_and_cancel_records_bounded_shutdown_metadata() {
    let fixture = Fixture::new("module-runtime-cancel", "enabled").await;
    let created = fixture.request("runtime-request").await;
    let replay = fixture.request("runtime-request").await;
    assert_eq!(replay["idempotentReplay"], json!(true));
    let resource_id = created["moduleRuntimeResourceId"].as_str().unwrap();
    let version_id = created["moduleRuntimeVersionId"].as_str().unwrap();
    let cancel = cancel_module_runtime_value_at(
        &fixture.deps,
        &fixture.write_invocation(
            "runtime-cancel",
            json!({
                "moduleRuntimeResourceId": resource_id,
                "expectedModuleRuntimeVersionId": version_id,
                "reason": "Cancel supervised runtime envelope."
            }),
        ),
        &json!({
            "moduleRuntimeResourceId": resource_id,
            "expectedModuleRuntimeVersionId": version_id,
            "reason": "Cancel supervised runtime envelope."
        }),
        default_operation_at(),
    )
    .await
    .expect("cancel runtime");
    assert_eq!(cancel["status"], json!("cancelled"));
    assert_eq!(
        cancel["moduleRuntime"]["supervision"]["cancellation"]["state"],
        json!("cancelled")
    );
    assert_eq!(
        cancel["moduleRuntime"]["supervision"]["shutdown"]["state"],
        json!("cancel_on_shutdown")
    );
}

fn request_payload(lifecycle_id: &str) -> Value {
    json!({
        "moduleLifecycleResourceId": lifecycle_id,
        "runtimeRequestId": "runtime-request-1",
        "runtimeKind": "module_feature",
        "runtimeLabel": "Summarize bounded resource refs",
        "runtimeState": "running",
        "reason": "Run enabled module through supervisor metadata envelope.",
        "inputRefs": [{"kind": "resource", "resourceId": "prompt_artifact:input", "role": "input"}],
        "outputArtifactRefs": [{"kind": "execution_output", "resourceId": "execution_output:bounded", "role": "output_ref", "summary": "Bounded output artifact ref only"}],
        "evidenceRefs": [{"kind": "evidence", "id": "runtime-evidence:bounded", "role": "supervision"}],
        "timeoutMs": 30000
    })
}

fn lifecycle_payload(state: &str, lifecycle_id: &str) -> Value {
    json!({
        "schemaVersion": crate::engine::MODULE_LIFECYCLE_STATE_PAYLOAD_SCHEMA_VERSION,
        "state": state,
        "transitionId": "transition",
        "scope": {"kind": "session", "value": "session"},
        "installDecision": {"kind": "module_install_decision", "resourceId": "module_install_decision:accepted", "role": "install_candidate"},
        "transition": {"action": "enable", "to": state, "metadataOnly": true, "executionPerformed": false},
        "previous": {"state": null, "versionId": null, "currentVersionRevalidated": false},
        "approval": {"allowed": true, "rawAuthorityIdsStored": false},
        "rollback": {"proofRefs": [], "status": "not_proven", "metadataOnly": true, "rollbackExecuted": false},
        "runtimeAuthorization": {
            "failClosed": true,
            "enabledAllowsRuntime": state == "enabled",
            "disabledDenied": state == "disabled",
            "quarantinedDenied": state == "quarantined",
            "rolledBackDenied": state == "rolled_back"
        },
        "evidenceRefs": [],
        "traceRefs": [],
        "replayRefs": [],
        "authority": {"rawAuthorityIdsStored": false},
        "idempotency": {"fingerprint": lifecycle_id, "rawKeyStored": false},
        "sideEffectProof": {"metadataOnly": true, "installPerformed": false, "activationPerformed": false, "executionPerformed": false, "rollbackExecuted": false, "dependencyRestorePerformed": false, "packageManagerUsed": false, "networkPolicy": "none", "networkAccessPerformed": false, "repoManagedSkillsTouched": false, "physicalWorkspaceDirectoryCreated": false, "rawCommandsStored": false, "rawLogsStored": false, "fileContentsStored": false, "absolutePathsStored": false},
        "createdAt": DEFAULT_OPERATION_AT,
        "updatedAt": DEFAULT_OPERATION_AT,
        "revision": 1
    })
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
            grant_id: Some(AuthorityGrantId::new(format!("module-runtime-{suffix}")).unwrap()),
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
            budget: json!({"class": "module_runtime_test"}),
            expires_at: None,
            can_delegate: false,
            provenance: json!({"source": "module_runtime_test"}),
            trace_id: TraceId::new(format!("trace-module-runtime-{suffix}")).unwrap(),
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
    .with_workspace_id("workspace-module-runtime")
    .with_session_id(session_id.to_owned())
    .with_idempotency_key(key.to_owned());
    for scope in scopes {
        context = context.with_scope(*scope);
    }
    Invocation {
        id: InvocationId::new(format!("invocation-{key}")).unwrap(),
        function_id: FunctionId::new("capability::execute").unwrap(),
        payload,
        causal_context: context,
        delivery_mode: crate::engine::DeliveryMode::Sync,
    }
}

fn default_operation_at() -> DateTime<Utc> {
    DateTime::parse_from_rfc3339(DEFAULT_OPERATION_AT)
        .unwrap()
        .with_timezone(&Utc)
}

fn runtime_selector(resource_id: &str) -> String {
    format!("resource:{resource_id}")
}

fn lifecycle_selector(resource_id: &str) -> String {
    format!("resource:{resource_id}")
}
