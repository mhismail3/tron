use std::collections::BTreeSet;

use chrono::{TimeZone, Utc};
use serde_json::{Value, json};

use crate::engine::{RegisterResourceType, builtin_resource_type_definitions};

use super::types::{
    ApprovalDecisionRecord, ApprovalDecisionRevision, ApprovalDecisionState, ApprovalIdempotency,
    ApprovalRequestRecord, ApprovalRequestRevision, ApprovalRequestState, DECISION_SCHEMA_VERSION,
    REQUEST_SCHEMA_VERSION,
};

#[test]
fn resource_definitions_match_domain_constants_and_payloads() {
    let definitions = builtin_resource_type_definitions();
    let request_definition = resource_definition(&definitions, super::APPROVAL_REQUEST_KIND);
    let decision_definition = resource_definition(&definitions, super::APPROVAL_DECISION_KIND);

    assert_eq!(
        request_definition.schema_id,
        super::APPROVAL_REQUEST_SCHEMA_ID
    );
    assert_eq!(
        decision_definition.schema_id,
        super::APPROVAL_DECISION_SCHEMA_ID
    );

    assert_resource_schema_matches_record(
        &request_definition.schema,
        request_record_value(),
        &[
            "schemaVersion",
            "state",
            "requester",
            "action",
            "scope",
            "riskClass",
            "createdAt",
            "expiresAt",
            "freshness",
            "evidenceRefs",
            "resourceSelectors",
            "traceRefs",
            "replayRefs",
            "denialBehavior",
            "idempotency",
            "revision",
        ],
    );
    assert_resource_schema_matches_record(
        &decision_definition.schema,
        decision_record_value(),
        &[
            "schemaVersion",
            "requestResourceId",
            "requestVersionId",
            "state",
            "decisionActor",
            "decidedAt",
            "expiresAt",
            "action",
            "scope",
            "riskClass",
            "evidenceRefs",
            "resourceSelectors",
            "traceRefs",
            "replayRefs",
            "denialBehavior",
            "idempotency",
            "revision",
        ],
    );

    let capabilities = super::contract::capabilities().expect("approval capabilities");
    assert_output_contract(
        &capabilities
            .iter()
            .find(|spec| spec.function_id.as_str() == super::REQUEST_FUNCTION)
            .expect("request capability")
            .output_contract,
        &[super::APPROVAL_REQUEST_KIND],
    );
    assert_output_contract(
        &capabilities
            .iter()
            .find(|spec| spec.function_id.as_str() == super::DECIDE_FUNCTION)
            .expect("decide capability")
            .output_contract,
        &[super::APPROVAL_DECISION_KIND, super::APPROVAL_REQUEST_KIND],
    );
}

fn resource_definition<'a>(
    definitions: &'a [RegisterResourceType],
    kind: &str,
) -> &'a RegisterResourceType {
    definitions
        .iter()
        .find(|definition| definition.kind == kind)
        .unwrap_or_else(|| panic!("missing built-in resource definition for {kind}"))
}

fn assert_resource_schema_matches_record(schema: &Value, record: Value, required_fields: &[&str]) {
    let schema_fields = object_keys(&schema["properties"]);
    let record_fields = object_keys(&record);
    assert_eq!(
        schema_fields, record_fields,
        "approval resource schema properties must match serialized domain record fields"
    );

    let required = string_array_values(&schema["required"]);
    let expected_required = required_fields
        .iter()
        .map(|field| (*field).to_owned())
        .collect::<BTreeSet<_>>();
    assert_eq!(
        required, expected_required,
        "approval resource required fields must match the domain-owned persisted payload"
    );
    assert!(
        required.is_subset(&record_fields),
        "required fields must be serialized by the domain record"
    );
}

fn assert_output_contract(contract: &crate::engine::DurableOutputContract, expected: &[&str]) {
    let crate::engine::DurableOutputContract::ResourceBacked {
        produced_resource_kinds,
        required_resource_refs,
    } = contract
    else {
        panic!("approval capability must declare resource-backed output");
    };
    assert!(
        *required_resource_refs,
        "approval capabilities must return resource refs"
    );
    assert_eq!(
        produced_resource_kinds
            .iter()
            .cloned()
            .collect::<BTreeSet<_>>(),
        expected
            .iter()
            .map(|kind| (*kind).to_owned())
            .collect::<BTreeSet<_>>()
    );
}

fn request_record_value() -> Value {
    serde_json::to_value(ApprovalRequestRecord {
        schema_version: REQUEST_SCHEMA_VERSION.to_owned(),
        state: ApprovalRequestState::Pending,
        requester: json!({"kind": "client", "id": "engine-client"}),
        action: action(),
        scope: scope(),
        risk_class: "high".to_owned(),
        created_at: timestamp(),
        expires_at: future_timestamp(),
        freshness: json!({"staleAt": "2099-01-01T12:10:00Z"}),
        evidence_refs: vec![json!({"resourceId": "evidence:approval-test"})],
        resource_selectors: selectors(),
        trace_refs: vec![json!({"traceId": "approval-schema-alignment"})],
        replay_refs: vec![json!({"source": "engine_invocation_ledger"})],
        denial_behavior: json!({"mode": "fail_closed"}),
        idempotency: sample_idempotency(super::REQUEST_FUNCTION),
        revision: ApprovalRequestRevision {
            number: 1,
            current_version_id: Some("ver_request".to_owned()),
        },
    })
    .expect("approval request record should serialize")
}

fn decision_record_value() -> Value {
    serde_json::to_value(ApprovalDecisionRecord {
        schema_version: DECISION_SCHEMA_VERSION.to_owned(),
        request_resource_id: "approval_request:request".to_owned(),
        request_version_id: "ver_request".to_owned(),
        state: ApprovalDecisionState::Approved,
        decision_actor: json!({"kind": "user", "id": "operator"}),
        decided_at: timestamp(),
        expires_at: future_timestamp(),
        freshness_until: Some(future_timestamp()),
        action: action(),
        scope: scope(),
        risk_class: "high".to_owned(),
        evidence_refs: vec![json!({"resourceId": "evidence:approval-test"})],
        resource_selectors: selectors(),
        trace_refs: vec![json!({"traceId": "approval-schema-alignment"})],
        replay_refs: vec![json!({"source": "engine_invocation_ledger"})],
        denial_behavior: json!({"mode": "fail_closed"}),
        idempotency: sample_idempotency(super::DECIDE_FUNCTION),
        revision: ApprovalDecisionRevision {
            number: 1,
            expected_request_version_id: "ver_request".to_owned(),
            recorded_request_version_id: "ver_decided_request".to_owned(),
        },
    })
    .expect("approval decision record should serialize")
}

fn sample_idempotency(function_id: &str) -> ApprovalIdempotency {
    ApprovalIdempotency {
        key: Some("approval-schema-alignment".to_owned()),
        invocation_id: "inv_approval_schema_alignment".to_owned(),
        function_id: function_id.to_owned(),
    }
}

fn object_keys(value: &Value) -> BTreeSet<String> {
    value
        .as_object()
        .expect("value should be an object")
        .keys()
        .cloned()
        .collect()
}

fn string_array_values(value: &Value) -> BTreeSet<String> {
    value
        .as_array()
        .expect("value should be an array")
        .iter()
        .map(|item| {
            item.as_str()
                .expect("array item should be a string")
                .to_owned()
        })
        .collect()
}

fn action() -> Value {
    json!({"kind": "future_tool", "operation": "write_file"})
}

fn scope() -> Value {
    json!({"kind": "workspace", "id": "approval-workspace"})
}

fn selectors() -> Vec<Value> {
    vec![json!({"kind": "resource", "id": "workspace-file:/tmp/example"})]
}

fn timestamp() -> chrono::DateTime<Utc> {
    Utc.with_ymd_and_hms(2026, 6, 19, 12, 0, 0)
        .single()
        .expect("valid approval test timestamp")
}

fn future_timestamp() -> chrono::DateTime<Utc> {
    Utc.with_ymd_and_hms(2099, 1, 1, 12, 0, 0)
        .single()
        .expect("valid approval future timestamp")
}
