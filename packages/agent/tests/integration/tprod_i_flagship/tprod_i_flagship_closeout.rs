#![cfg(unix)]

use std::sync::Arc;
use std::sync::atomic::Ordering;

use serde_json::{Value, json};
use tron::app::server::TronServer;
use tron::engine::{ApprovalStatus, EngineApprovalRecord};

use super::TprodIFlagshipProvider;

pub(super) async fn assert_agent_ready(
    provider: &TprodIFlagshipProvider,
    events: &[Value],
    server: &Arc<TronServer>,
    session_id: &str,
) {
    let event_types = event_types(events);
    if event_types
        .iter()
        .any(|event_type| event_type == "agent.ready")
    {
        return;
    }
    let approvals = server
        .runtime_context()
        .engine_host
        .list_approvals(None, Some(session_id), 100)
        .await
        .expect("approval diagnostics list succeeds");
    let invocation_records = server
        .runtime_context()
        .engine_host
        .invocation_records()
        .await
        .into_iter()
        .filter(|record| record.session_id.as_deref() == Some(session_id))
        .map(|record| {
            json!({
                "invocationId": record.invocation_id.as_str(),
                "functionId": record.function_id.as_str(),
                "parentInvocationId": record.parent_invocation_id.as_ref().map(|id| id.as_str()),
                "traceId": record.trace_id.as_str(),
                "idempotencyKey": record.idempotency_key,
                "succeeded": record.succeeded,
                "error": record.error.as_ref().map(ToString::to_string),
            })
        })
        .collect::<Vec<_>>();
    panic!(
        "TPROD-I prompt did not emit agent.ready: {}",
        event_debug(provider, events, &approvals, &invocation_records)
    );
}

pub(super) async fn assert_no_waiting_approvals(server: &Arc<TronServer>, session_id: &str) {
    let approvals = server
        .runtime_context()
        .engine_host
        .list_approvals(None, Some(session_id), 100)
        .await
        .expect("approval list succeeds");
    assert!(
        approvals.iter().all(|approval| !matches!(
            approval.status,
            ApprovalStatus::Pending | ApprovalStatus::Approved
        )),
        "JARVIS-11 must not leave interactive approval prompts waiting: {approvals:?}"
    );
    assert!(
        approvals.iter().any(|approval| {
            approval.function_id.as_str() == "capability::conformance_run"
                && approval.status == ApprovalStatus::Executed
        }),
        "JARVIS-11 must keep executed conformance approval audit evidence: {approvals:?}"
    );
}

pub(super) async fn assert_no_manual_approval_resolve_invocation(
    server: &Arc<TronServer>,
    session_id: &str,
) {
    let resolve_invocations = server
        .runtime_context()
        .engine_host
        .invocation_records()
        .await
        .into_iter()
        .filter(|record| {
            record.session_id.as_deref() == Some(session_id)
                && record.function_id.as_str() == "approval::resolve"
        })
        .collect::<Vec<_>>();
    assert!(
        resolve_invocations.is_empty(),
        "JARVIS-11 must use default auto-decisions instead of manual approval::resolve invocations: {resolve_invocations:?}"
    );
}

pub(super) async fn assert_clean_state(
    server: &Arc<TronServer>,
    session_id: &str,
    workspace_id: &str,
    worker_id: &str,
) {
    assert_no_waiting_approvals(server, session_id).await;
    for queue in ["agent", "module"] {
        let queued = super::super::direct_engine_invoke_with_session(
            server,
            "queue::list",
            json!({"queue": queue, "limit": 20}),
            &format!("jarvis-11-queue-list-{queue}"),
            &["queue.read"],
            session_id,
        )
        .await;
        let non_clean_items = queued["items"]
            .as_array()
            .unwrap()
            .iter()
            .filter(|item| {
                !matches!(
                    item["status"].as_str(),
                    Some("completed") | Some("cancelled")
                )
            })
            .collect::<Vec<_>>();
        assert!(
            non_clean_items.is_empty(),
            "JARVIS-11 final queue `{queue}` must have no active or failed work: {queued}"
        );
    }
    let workers = super::super::direct_engine_invoke_with_session(
        server,
        "worker::list",
        json!({}),
        "jarvis-11-worker-list-after-cleanup",
        &["worker.read"],
        session_id,
    )
    .await;
    assert!(
        workers["workers"]
            .as_array()
            .expect("worker list")
            .iter()
            .all(|worker| worker["id"].as_str() != Some(worker_id)),
        "JARVIS-11 final worker list must not keep the spawned helper registered: {workers}"
    );
    let snapshot = super::super::direct_engine_invoke_with_session(
        server,
        "agent::work_snapshot",
        json!({"sessionId": session_id, "workspaceId": workspace_id, "limit": 50}),
        "jarvis-11-work-snapshot-after-cleanup",
        &["agent.read"],
        session_id,
    )
    .await;
    assert_eq!(snapshot["activeWork"].as_array().unwrap().len(), 0);
    assert_eq!(snapshot["guardrails"].as_array().unwrap().len(), 0);
    assert!(
        snapshot["workers"]
            .as_array()
            .expect("work snapshot workers")
            .iter()
            .all(|worker| worker["workerId"].as_str() != Some(worker_id)),
        "JARVIS-11 final Work snapshot must not keep the stopped helper worker: {snapshot}"
    );
}

fn event_types(events: &[Value]) -> Vec<String> {
    events
        .iter()
        .filter_map(|event| event.get("type").and_then(Value::as_str).map(str::to_owned))
        .collect()
}

fn event_debug(
    provider: &TprodIFlagshipProvider,
    events: &[Value],
    approvals: &[EngineApprovalRecord],
    invocation_records: &[Value],
) -> String {
    let tail = events
        .iter()
        .rev()
        .take(20)
        .cloned()
        .collect::<Vec<_>>()
        .into_iter()
        .rev()
        .map(|event| {
            let data = event.get("data").unwrap_or(&Value::Null);
            json!({
                "type": event.get("type"),
                "turn": data.get("turn"),
                "invocationId": data.get("invocationId"),
                "modelPrimitiveName": data.get("modelPrimitiveName"),
                "functionId": data.get("functionId"),
                "contractId": data.get("contractId"),
                "implementationId": data.get("implementationId"),
                "workerId": data.get("workerId"),
                "target": data.pointer("/arguments/target"),
                "argumentFunctionId": data.pointer("/arguments/arguments/functionId"),
                "argumentPluginId": data.pointer("/arguments/arguments/pluginId"),
                "status": data.get("status"),
                "isError": data.get("isError"),
                "error": data.get("error"),
            })
        })
        .collect::<Vec<_>>();
    serde_json::to_string_pretty(&json!({
        "providerCalls": provider.call_count.load(Ordering::SeqCst),
        "eventTypes": event_types(events),
        "tail": tail,
        "approvals": approvals,
        "invocationRecords": invocation_records,
    }))
    .unwrap_or_else(|_| "<unserializable TPROD-I events>".to_owned())
}
