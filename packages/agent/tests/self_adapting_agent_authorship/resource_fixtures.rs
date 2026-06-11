use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use tron::engine::TraceId;

use super::support::{execute_causal_context, invoke_execute, test_runtime, trace_operations};

#[tokio::test]
async fn saa_execute_can_author_goal_evidence_decision_memory_and_rule_resources() {
    let runtime = test_runtime();
    let workspace = tempfile::tempdir().unwrap();
    let created = runtime
        .ctx
        .event_store
        .create_session(
            "gpt-5.5",
            workspace.path().to_str().unwrap(),
            Some("saa resource authorship"),
            Some("openai"),
        )
        .unwrap();
    let trace_id = TraceId::generate();
    let session_id = created.session.id.as_str();
    let workspace_id = created.session.workspace_id.as_str();

    execute_resource(
        &runtime.ctx,
        &trace_id,
        session_id,
        workspace_id,
        workspace.path(),
        "goal",
        "saa-goal",
        "open",
        json!({
            "intent": "Prove durable self-authorship through typed resources",
            "successCriteria": ["goal, claim, evidence, decision, memory, and rule are linked"],
            "expectedOutputKinds": ["agent_memory", "agent_rule", "artifact"]
        }),
        "saa-provider-goal",
    )
    .await;

    execute_resource(
        &runtime.ctx,
        &trace_id,
        session_id,
        workspace_id,
        workspace.path(),
        "claim",
        "saa-claim",
        "accepted",
        json!({
            "statement": "The SAA fixture created typed resources through execute.",
            "confidence": 0.99,
            "metadata": {"fixture": "saa"}
        }),
        "saa-provider-claim",
    )
    .await;

    execute_resource(
        &runtime.ctx,
        &trace_id,
        session_id,
        workspace_id,
        workspace.path(),
        "evidence",
        "saa-evidence",
        "accepted",
        json!({
            "summary": "Trace-backed fixture evidence for SAA resource authorship.",
            "source": "self_adapting_agent_authorship_invariants",
            "resourceRef": "trace:saa-resource-authorship",
            "metadata": {"redaction": "no_private_payloads"}
        }),
        "saa-provider-evidence",
    )
    .await;

    execute_link(
        &runtime.ctx,
        &trace_id,
        session_id,
        workspace_id,
        workspace.path(),
        "saa-claim",
        "saa-goal",
        "claims_about",
        "saa-provider-link-claim",
    )
    .await;
    execute_link(
        &runtime.ctx,
        &trace_id,
        session_id,
        workspace_id,
        workspace.path(),
        "saa-evidence",
        "saa-claim",
        "evidence_for",
        "saa-provider-link-evidence",
    )
    .await;

    execute_resource(
        &runtime.ctx,
        &trace_id,
        session_id,
        workspace_id,
        workspace.path(),
        "decision",
        "saa-decision",
        "final",
        json!({
            "status": "accepted",
            "summary": "SAA resource authorship fixture is promotion-ready evidence, not live worker launch.",
            "promotedResources": ["saa-goal"],
            "metadata": {"promotionBoundary": "engine::promote remains explicit"}
        }),
        "saa-provider-decision",
    )
    .await;
    execute_link(
        &runtime.ctx,
        &trace_id,
        session_id,
        workspace_id,
        workspace.path(),
        "saa-goal",
        "saa-decision",
        "decided_by",
        "saa-provider-link-decision",
    )
    .await;

    execute_resource(
        &runtime.ctx,
        &trace_id,
        session_id,
        workspace_id,
        workspace.path(),
        "agent_memory",
        "saa-memory",
        "active",
        json!({
            "statement": "SAA memory stores learned facts as typed resources with evidence refs.",
            "status": "active",
            "scope": {"kind": "session", "sessionId": session_id},
            "confidence": 0.98,
            "provenance": {"source": "saa_fixture", "traceId": trace_id.as_str()},
            "evidenceRefs": ["saa-evidence"],
            "metadata": {"noPromptPlane": true}
        }),
        "saa-provider-memory",
    )
    .await;

    execute_resource(
        &runtime.ctx,
        &trace_id,
        session_id,
        workspace_id,
        workspace.path(),
        "agent_rule",
        "saa-rule",
        "proposed",
        json!({
            "rule": "Promotion-ready artifacts require evidence and explicit decisions before host promotion.",
            "status": "proposed",
            "scope": {"kind": "workspace", "workspaceId": workspace_id},
            "rationale": "SAA proves authorship without autonomous live capability mutation.",
            "provenance": {"source": "saa_fixture", "traceId": trace_id.as_str()},
            "evidenceRefs": ["saa-evidence"],
            "decisionRefs": ["saa-decision"],
            "metadata": {"workerLaunch": "not_authorized"}
        }),
        "saa-provider-rule",
    )
    .await;

    for (source, target, relation, provider_id) in [
        (
            "saa-memory",
            "saa-evidence",
            "supported_by",
            "saa-provider-link-memory",
        ),
        (
            "saa-rule",
            "saa-decision",
            "decided_by",
            "saa-provider-link-rule",
        ),
    ] {
        execute_link(
            &runtime.ctx,
            &trace_id,
            session_id,
            workspace_id,
            workspace.path(),
            source,
            target,
            relation,
            provider_id,
        )
        .await;
    }

    let inspected = invoke_execute(
        &runtime.ctx,
        json!({"operation": "resource_inspect", "resourceId": "saa-rule"}),
        execute_causal_context(
            &runtime.ctx,
            trace_id.clone(),
            session_id,
            workspace_id,
            workspace.path(),
            "saa-provider-inspect-rule",
            "saa-inspect-rule",
        )
        .await,
    )
    .await;
    let details = inspected.details.as_ref().unwrap();
    assert_eq!(details["primitiveOperation"], "resource_inspect");
    let inspection = &details["resource"]["inspection"];
    assert_eq!(inspection["resource"]["kind"], "agent_rule");
    assert_eq!(inspection["resource"]["lifecycle"], "proposed");
    assert!(
        !serde_json::to_string(inspection)
            .unwrap()
            .contains("private_payload"),
        "fixture must not leak private payload marker"
    );

    let operations = trace_operations(&runtime.ctx, session_id, &trace_id);
    for required in ["resource_create", "resource_link", "resource_inspect"] {
        assert!(
            operations.iter().any(|operation| operation == required),
            "SAA trace evidence missing operation {required}: {operations:?}"
        );
    }
}

#[tokio::test]
async fn saa_execute_can_author_patch_materialized_file_and_ui_surface_without_live_promotion() {
    let runtime = test_runtime();
    let workspace = tempfile::tempdir().unwrap();
    let created = runtime
        .ctx
        .event_store
        .create_session(
            "gpt-5.5",
            workspace.path().to_str().unwrap(),
            Some("saa promotion boundary"),
            Some("openai"),
        )
        .unwrap();
    let trace_id = TraceId::generate();
    let session_id = created.session.id.as_str();
    let workspace_id = created.session.workspace_id.as_str();
    let target = workspace.path().join("generated").join("worker-spec.md");
    let target_hash = sha256_hex(b"# worker spec\nstatus: promotion-ready\n");

    execute_resource(
        &runtime.ctx,
        &trace_id,
        session_id,
        workspace_id,
        workspace.path(),
        "patch_proposal",
        "saa-patch",
        "proposed",
        json!({
            "targetPath": "generated/worker-spec.md",
            "baseContentHash": "sha256:empty",
            "diff": "--- /dev/null\n+++ generated/worker-spec.md\n@@\n+# worker spec\n+status: promotion-ready\n",
            "status": "proposed",
            "result": {"requiresDecisionRef": "saa-decision"}
        }),
        "saa-provider-patch",
    )
    .await;

    execute_resource(
        &runtime.ctx,
        &trace_id,
        session_id,
        workspace_id,
        workspace.path(),
        "materialized_file",
        "saa-materialized-file",
        "draft",
        json!({
            "canonicalPath": target.display().to_string(),
            "relativePath": "generated/worker-spec.md",
            "entryType": "file",
            "content": "# worker spec\nstatus: promotion-ready\n",
            "contentHash": target_hash,
            "sizeBytes": 38,
            "mimeType": "text/markdown",
            "metadata": {
                "traceRef": trace_id.as_str(),
                "workspaceMutation": "not_yet_applied"
            }
        }),
        "saa-provider-materialized",
    )
    .await;
    assert!(
        !target.exists(),
        "resource_create must represent materialized files before workspace mutation"
    );
    execute_link(
        &runtime.ctx,
        &trace_id,
        session_id,
        workspace_id,
        workspace.path(),
        "saa-patch",
        "saa-materialized-file",
        "produces",
        "saa-provider-link-materialized",
    )
    .await;

    execute_resource(
        &runtime.ctx,
        &trace_id,
        session_id,
        workspace_id,
        workspace.path(),
        "ui_surface",
        "saa-ui-surface",
        "active",
        json!({
            "surfaceId": "saa-runtime-surface",
            "title": "SAA Authorship",
            "purpose": "Inspect promotion-ready artifacts",
            "schemaVersion": 1,
            "layout": {
                "type": "Section",
                "props": {"title": "Artifacts"},
                "children": [
                    {
                        "type": "ResourceRef",
                        "props": {
                            "resourceId": "saa-patch",
                            "kind": "patch_proposal",
                            "label": "Patch proposal"
                        }
                    },
                    {
                        "type": "Text",
                        "props": {"text": "Promotion requires explicit evidence and decision refs."}
                    }
                ]
            },
            "actions": [{
                "actionId": "inspect",
                "label": "Inspect",
                "expiresAt": "2100-01-01T00:00:00Z",
                "inputSchema": {"type": "object"}
            }],
            "expiresAt": "2100-01-01T00:00:00Z"
        }),
        "saa-provider-ui",
    )
    .await;

    let inspected = invoke_execute(
        &runtime.ctx,
        json!({"operation": "resource_inspect", "resourceId": "saa-ui-surface"}),
        execute_causal_context(
            &runtime.ctx,
            trace_id.clone(),
            session_id,
            workspace_id,
            workspace.path(),
            "saa-provider-inspect-ui",
            "saa-inspect-ui",
        )
        .await,
    )
    .await;
    let inspection = &inspected.details.as_ref().unwrap()["resource"]["inspection"];
    assert_eq!(inspection["resource"]["kind"], "ui_surface");
    assert_eq!(inspection["versions"][0]["payload"]["schemaVersion"], 1);
    assert_eq!(
        inspection["versions"][0]["payload"]["layout"]["children"][0]["type"],
        "ResourceRef"
    );

    let operations = trace_operations(&runtime.ctx, session_id, &trace_id);
    for required in ["resource_create", "resource_link", "resource_inspect"] {
        assert!(
            operations.iter().any(|operation| operation == required),
            "SAA trace evidence missing operation {required}: {operations:?}"
        );
    }
}

async fn execute_resource(
    ctx: &tron::shared::server::context::ServerRuntimeContext,
    trace_id: &TraceId,
    session_id: &str,
    workspace_id: &str,
    working_directory: &std::path::Path,
    kind: &str,
    resource_id: &str,
    lifecycle: &str,
    resource_payload: Value,
    provider_invocation_id: &str,
) {
    let result = invoke_execute(
        ctx,
        json!({
            "operation": "resource_create",
            "kind": kind,
            "resourceId": resource_id,
            "scope": "session",
            "lifecycle": lifecycle,
            "resourcePayload": resource_payload,
            "reason": "SAA typed resource fixture"
        }),
        execute_causal_context(
            ctx,
            trace_id.clone(),
            session_id,
            workspace_id,
            working_directory,
            provider_invocation_id,
            &format!("{provider_invocation_id}-key"),
        )
        .await,
    )
    .await;
    let details = result.details.as_ref().unwrap();
    assert_eq!(details["primitiveOperation"], "resource_create");
    assert_eq!(details["resource"]["resource"]["resourceId"], resource_id);
    assert_eq!(details["resource"]["resource"]["kind"], kind);
}

async fn execute_link(
    ctx: &tron::shared::server::context::ServerRuntimeContext,
    trace_id: &TraceId,
    session_id: &str,
    workspace_id: &str,
    working_directory: &std::path::Path,
    source_resource_id: &str,
    target_resource_id: &str,
    relation: &str,
    provider_invocation_id: &str,
) {
    let result = invoke_execute(
        ctx,
        json!({
            "operation": "resource_link",
            "sourceResourceId": source_resource_id,
            "targetResourceId": target_resource_id,
            "relation": relation,
            "metadata": {"fixture": "saa"},
            "reason": "SAA resource lineage fixture"
        }),
        execute_causal_context(
            ctx,
            trace_id.clone(),
            session_id,
            workspace_id,
            working_directory,
            provider_invocation_id,
            &format!("{provider_invocation_id}-key"),
        )
        .await,
    )
    .await;
    let details = result.details.as_ref().unwrap();
    assert_eq!(details["primitiveOperation"], "resource_link");
    assert_eq!(details["resource"]["link"]["relation"], relation);
}

fn sha256_hex(bytes: &[u8]) -> String {
    let mut hasher = Sha256::new();
    hasher.update(bytes);
    format!("sha256:{:x}", hasher.finalize())
}
