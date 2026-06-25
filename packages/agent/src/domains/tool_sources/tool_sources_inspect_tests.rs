use serde_json::{Value, json};

use super::*;
use crate::engine::durability::resources::EngineResourceVersionState;
use crate::engine::{
    ActorId, CreateResource, EngineResource, EngineResourceInspection, EngineResourceScope,
    EngineResourceVersion, TOOL_SOURCE_CONFORMANCE_REPORT_KIND,
    TOOL_SOURCE_CONFORMANCE_REPORT_SCHEMA_ID, TOOL_SOURCE_PROPOSAL_KIND,
    TOOL_SOURCE_PROPOSAL_SCHEMA_ID, TraceId, WorkerId,
};

#[tokio::test]
async fn inspect_rejects_tool_source_prefix_when_actual_kind_mismatches() {
    let fixture = Fixture::new("inspect-kind-schema").await;
    let cases = vec![
        (
            "proposal-wrong-kind",
            "tool_source_proposal:wrong-kind",
            TOOL_SOURCE_CONFORMANCE_REPORT_KIND,
            TOOL_SOURCE_CONFORMANCE_REPORT_SCHEMA_ID,
            "failed",
            stored_report_payload("tool_source_proposal:wrong-kind"),
            "expected tool_source_proposal",
        ),
        (
            "report-wrong-kind",
            "tool_source_conformance_report:wrong-kind",
            TOOL_SOURCE_PROPOSAL_KIND,
            TOOL_SOURCE_PROPOSAL_SCHEMA_ID,
            "proposed",
            stored_proposal_payload(),
            "expected tool_source_conformance_report",
        ),
    ];

    for (key, resource_id, kind, schema_id, lifecycle, payload, expected_error) in cases {
        fixture
            .deps
            .engine_host
            .create_resource(CreateResource {
                resource_id: Some(resource_id.to_owned()),
                kind: kind.to_owned(),
                schema_id: Some(schema_id.to_owned()),
                scope: EngineResourceScope::Session(fixture.session_id.clone()),
                owner_worker_id: WorkerId::new("tool-source-test").expect("worker id"),
                owner_actor_id: ActorId::new("system:tool-sources-test").expect("actor id"),
                lifecycle: Some(lifecycle.to_owned()),
                policy: json!({"test": "kind-schema-mismatch"}),
                initial_payload: Some(payload),
                locations: Vec::new(),
                trace_id: TraceId::generate(),
                invocation_id: None,
            })
            .await
            .expect("create mismatched resource");

        let error = fixture.inspect_error(key, resource_id).await;
        assert!(error.contains(expected_error), "{error}");
    }
}

#[test]
fn inspect_resource_type_guard_rejects_tool_source_schema_mismatches() {
    let proposal = stored_inspection(
        TOOL_SOURCE_PROPOSAL_KIND,
        "tron.test.wrong_schema.v1",
        "proposed",
        stored_proposal_payload(),
    );
    let error = super::super::service::ensure_tool_source_resource(
        &proposal,
        TOOL_SOURCE_PROPOSAL_KIND,
        "tool_source_inspect",
    )
    .expect_err("proposal schema mismatch must fail")
    .to_string();
    assert!(error.contains(TOOL_SOURCE_PROPOSAL_SCHEMA_ID), "{error}");

    let report = stored_inspection(
        TOOL_SOURCE_CONFORMANCE_REPORT_KIND,
        "tron.test.wrong_schema.v1",
        "failed",
        stored_report_payload("tool_source_proposal:schema-guard"),
    );
    let error = super::super::service::ensure_tool_source_resource(
        &report,
        TOOL_SOURCE_CONFORMANCE_REPORT_KIND,
        "tool_source_inspect",
    )
    .expect_err("report schema mismatch must fail")
    .to_string();
    assert!(
        error.contains(TOOL_SOURCE_CONFORMANCE_REPORT_SCHEMA_ID),
        "{error}"
    );
}

fn stored_proposal_payload() -> Value {
    json!({
        "schemaVersion": "tron.tool_source.v1",
        "state": "proposed",
        "sourceKind": "mcp_server",
        "sourceIdentity": {"id": "mismatch.fixture"},
        "provenance": {"source": "fixture"},
        "sandboxPolicy": {"networkPolicy": "none"},
        "declaredTools": [],
        "declaredSchemas": [],
        "expectedLinkage": {},
        "authority": {"activation": "forbidden"},
        "traceRefs": [],
        "replayRefs": [],
        "evidenceRefs": [],
        "idempotency": {"key": "mismatch"},
        "revision": 1
    })
}

fn stored_report_payload(proposal_id: &str) -> Value {
    json!({
        "schemaVersion": "tron.tool_source.v1",
        "state": "failed",
        "toolSourceProposalResourceId": proposal_id,
        "proposalVersionId": "version:mismatch",
        "status": "failed",
        "checks": [],
        "summary": {"source": "fixture"},
        "authority": {"activation": "forbidden"},
        "traceRefs": [],
        "replayRefs": [],
        "evidenceRefs": [],
        "idempotency": {"key": "mismatch"},
        "revision": 1,
        "activation": {"performed": false, "catalogRegistration": false, "execution": false}
    })
}

fn stored_inspection(
    kind: &str,
    schema_id: &str,
    lifecycle: &str,
    payload: Value,
) -> EngineResourceInspection {
    let now = chrono::Utc::now();
    let resource_id = format!("{kind}:schema-guard");
    let version_id = "version:schema-guard".to_owned();
    EngineResourceInspection {
        resource: EngineResource {
            resource_id: resource_id.clone(),
            kind: kind.to_owned(),
            schema_id: schema_id.to_owned(),
            scope: EngineResourceScope::Session("schema-guard-session".to_owned()),
            owner_worker_id: WorkerId::new("tool-source-test").expect("worker id"),
            owner_actor_id: ActorId::new("system:tool-sources-test").expect("actor id"),
            lifecycle: lifecycle.to_owned(),
            policy: json!({"test": "schema-mismatch"}),
            current_version_id: Some(version_id.clone()),
            trace_id: TraceId::generate(),
            created_by_invocation_id: None,
            created_at: now,
            updated_at: now,
        },
        versions: vec![EngineResourceVersion {
            version_id,
            resource_id,
            parent_version_id: None,
            content_hash: "sha256:schema-guard".to_owned(),
            state: EngineResourceVersionState::Available,
            payload,
            locations: Vec::new(),
            created_by_invocation_id: None,
            trace_id: TraceId::generate(),
            created_at: now,
        }],
        outgoing_links: Vec::new(),
        incoming_links: Vec::new(),
        events: Vec::new(),
    }
}
