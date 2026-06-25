use serde_json::{Value, json};

use super::PROCEDURAL_RECORD_KIND;
use super::service::test_support::procedural_payload;
use super::service::{inspect_procedural_state_value, list_procedural_state_value};
use crate::engine::{
    ActorId, ActorKind, AuthorityGrantId, CausalContext, CreateResource, DeliveryMode, DeriveGrant,
    EngineResourceScope, FunctionId, Invocation, InvocationId, RiskLevel, TraceId, WorkerId,
};

const WORKER: &str = "procedural";

#[tokio::test]
async fn list_and_inspect_reject_unsafe_projection_scalar_fields_without_leaking_values() {
    let oversized = "x".repeat(256);
    let oversized_hash = format!("sha256:{oversized}");
    let cases = vec![
        ("eval.status", json!({"v": "secret-token"}), "secret-token"),
        ("eval.status", json!(oversized.clone()), oversized.as_str()),
        ("eval.status", json!("grant-status-1"), "grant-status-1"),
        (
            "eval.lastRunAt",
            json!("secret-last-run"),
            "secret-last-run",
        ),
        (
            "eval.lastRunAt",
            json!("/Users/a/.ssh/token"),
            "/Users/a/.ssh/token",
        ),
        (
            "eval.lastRunAt",
            json!(["2026-06-25T00:00:00Z"]),
            "2026-06-25T00:00:00Z",
        ),
        ("contentHash", json!({"hash": "secret-hash"}), "secret-hash"),
        ("contentHash", json!(oversized_hash), oversized.as_str()),
        ("contentHash", json!("grant-hash-1"), "grant-hash-1"),
        (
            "contentHash",
            json!("/private/procedural/hash"),
            "/private/procedural/hash",
        ),
    ];

    for (index, (field, value, forbidden)) in cases.into_iter().enumerate() {
        let label = format!("{}-{index}", field.replace('.', "-"));
        let handle = crate::engine::EngineHostHandle::new_in_memory().expect("engine host");
        let session_id = format!("procedural-malicious-session-{index}");
        let workspace_id = format!("workspace-procedural-malicious-{index}");
        let grant = derived_read_grant(&handle, &label).await;
        let resource_id = format!("procedural_record:skill:malicious-{index}");
        create_record(
            &handle,
            &resource_id,
            EngineResourceScope::Session(session_id.clone()),
            malicious_payload(field, value),
        )
        .await;

        let list_invocation = read_invocation(
            &format!("list-{label}"),
            json!({"operation": "procedural_state_list", "proceduralKind": "skill"}),
            grant.clone(),
            &session_id,
            &workspace_id,
        );
        assert_denied_without_leak(
            list_procedural_state_value(&handle, &list_invocation, &list_invocation.payload).await,
            forbidden,
            &label,
            "list",
        );

        let inspect_invocation = read_invocation(
            &format!("inspect-{label}"),
            json!({
                "operation": "procedural_state_inspect",
                "proceduralKind": "skill",
                "proceduralRecordResourceId": resource_id
            }),
            grant,
            &session_id,
            &workspace_id,
        );
        assert_denied_without_leak(
            inspect_procedural_state_value(
                &handle,
                &inspect_invocation,
                &inspect_invocation.payload,
            )
            .await,
            forbidden,
            &label,
            "inspect",
        );
    }
}

fn assert_denied_without_leak(
    result: Result<Value, crate::shared::server::errors::CapabilityError>,
    forbidden: &str,
    label: &str,
    operation: &str,
) {
    let serialized = result
        .expect_err("unsafe projection field must be rejected")
        .to_string();
    assert!(
        !serialized.contains(forbidden),
        "{operation} {label} leaked forbidden material {forbidden}: {serialized}"
    );
}

fn malicious_payload(field: &str, value: Value) -> Value {
    let mut payload = procedural_payload("skill", "malicious projection field", "candidate");
    match field {
        "eval.status" => payload["eval"]["status"] = value,
        "eval.lastRunAt" => payload["eval"]["lastRunAt"] = value,
        "contentHash" => payload["contentHash"] = value,
        other => panic!("unsupported malicious field {other}"),
    }
    payload
}

async fn derived_read_grant(
    handle: &crate::engine::EngineHostHandle,
    suffix: &str,
) -> AuthorityGrantId {
    handle
        .derive_authority_grant(DeriveGrant {
            grant_id: Some(AuthorityGrantId::new(format!("procedural-read-{suffix}")).unwrap()),
            parent_grant_id: AuthorityGrantId::new("engine-system").unwrap(),
            subject_actor_id: None,
            subject_worker_id: None,
            subject_invocation_id: None,
            allowed_capabilities: vec!["capability::execute".to_owned()],
            allowed_namespaces: vec!["__no_namespace_authority__".to_owned()],
            allowed_authority_scopes: vec![
                "procedural.read".to_owned(),
                "resource.read".to_owned(),
            ],
            allowed_resource_kinds: vec![PROCEDURAL_RECORD_KIND.to_owned()],
            resource_selectors: vec![
                "kind:procedural_record".to_owned(),
                "proceduralKind:skill".to_owned(),
            ],
            file_roots: vec!["/tmp".to_owned()],
            network_policy: "none".to_owned(),
            max_risk: RiskLevel::Low,
            budget: json!({"class": "procedural_read_test"}),
            expires_at: None,
            can_delegate: false,
            provenance: json!({"source": "procedural_projection_scalar_test"}),
            trace_id: TraceId::new(format!("trace-procedural-read-{suffix}")).unwrap(),
        })
        .await
        .expect("derive procedural read grant")
        .grant_id
}

fn read_invocation(
    key: &str,
    payload: Value,
    grant_id: AuthorityGrantId,
    session_id: &str,
    workspace_id: &str,
) -> Invocation {
    let context = CausalContext::new(
        ActorId::new(format!("agent:{session_id}")).unwrap(),
        ActorKind::Agent,
        grant_id,
        TraceId::new(format!("trace-procedural-{key}")).unwrap(),
    )
    .with_session_id(session_id.to_owned())
    .with_workspace_id(workspace_id.to_owned())
    .with_scope("procedural.read")
    .with_scope("resource.read");
    Invocation {
        id: InvocationId::new(format!("invocation-procedural-{key}")).unwrap(),
        function_id: FunctionId::new("capability::execute").unwrap(),
        delivery_mode: DeliveryMode::Sync,
        payload,
        causal_context: context,
    }
}

async fn create_record(
    handle: &crate::engine::EngineHostHandle,
    resource_id: &str,
    scope: EngineResourceScope,
    payload: Value,
) {
    handle
        .create_resource(CreateResource {
            resource_id: Some(resource_id.to_owned()),
            kind: PROCEDURAL_RECORD_KIND.to_owned(),
            schema_id: None,
            scope,
            owner_worker_id: WorkerId::new(WORKER).unwrap(),
            owner_actor_id: ActorId::new("agent:procedural-test").unwrap(),
            lifecycle: Some("candidate".to_owned()),
            policy: json!({"owner": WORKER}),
            initial_payload: Some(payload),
            locations: Vec::new(),
            trace_id: TraceId::new(format!("trace-{resource_id}").replace(':', "-")).unwrap(),
            invocation_id: None,
        })
        .await
        .expect("create procedural record");
}
