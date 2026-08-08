use super::*;

#[tokio::test]
async fn graph_projects_linked_agent_and_model_session_truth() {
    use crate::domains::session::event_store::{AppendOptions, EventType};

    let home = crate::shared::server::test_support::unique_tron_home();
    let (context, runtime) =
        crate::shared::server::test_support::make_test_context_and_worker_runtime_at(&home, None);
    let bundle = serde_json::from_value::<WorkerBundle>(json!({
        "schemaVersion":"tron.worker_bundle.v1",
        "workerId":"graph-agent",
        "name":"Graph Agent",
        "description":"Exercises authoritative agent-session graph projection",
        "modelExposure":"internal",
        "inputSchema":{
            "type":"object","additionalProperties":false,
            "required":["query"],"properties":{"query":{"type":"string"}}
        },
        "outputSchema":{
            "type":"object","additionalProperties":false,
            "required":["summary"],"properties":{"summary":{"type":"string"}}
        },
        "runner":{"kind":"agent","instructions":"Return a summary.","model":"mock/model"},
        "provenance":[{"source":"test:run-graph"}]
    }))
    .unwrap();
    let mut prepared = runtime.store.prepare(bundle, None).unwrap();
    runtime.store.finalize(&mut prepared).unwrap();
    let published = runtime.store.publish(prepared).unwrap();
    let (invocation, _) = runtime
        .store
        .begin_invocation(
            &published.worker.worker_id,
            &published.version,
            &json!({"query":"Inspect this run"}),
            "graph-agent-key",
            "graph-agent-trace",
            0,
            "manual",
            Some("origin-session"),
        )
        .unwrap();
    assert!(
        runtime
            .store
            .claim_running(&invocation.invocation_id)
            .unwrap()
    );
    let session_id = context
        .session_manager
        .create_worker_session("mock/model", "/tmp", Some("Worker: Graph Agent"))
        .unwrap();
    runtime
        .store
        .set_agent_session_id(&invocation.invocation_id, &session_id)
        .unwrap();
    context
        .event_store
        .append(&AppendOptions {
            session_id: &session_id,
            event_type: EventType::StreamTurnStart,
            payload: json!({"turn":1}),
            parent_id: None,
            sequence: None,
        })
        .unwrap();
    context
        .event_store
        .append(&AppendOptions {
            session_id: &session_id,
            event_type: EventType::StreamTurnEnd,
            payload: json!({
                "turn":1,
                "model":"mock/model",
                "latency":125,
                "stopReason":"end_turn",
                "tokenUsage":{
                    "inputTokens":100,
                    "outputTokens":20,
                    "cacheReadTokens":10,
                    "cacheCreationTokens":5
                },
                "cost":0.0125
            }),
            parent_id: None,
            sequence: None,
        })
        .unwrap();
    let (child, _) = runtime
        .store
        .begin_invocation_with_context(
            &published.worker.worker_id,
            &published.version,
            &json!({"query":"Inspect only this child"}),
            "graph-agent-child-key",
            "graph-agent-trace",
            1,
            "agent",
            Some("origin-session"),
            WorkerInteractionMode::Foreground,
            None,
            Some(&invocation.invocation_id),
            None,
            None,
            None,
        )
        .unwrap();
    assert!(runtime.store.claim_running(&child.invocation_id).unwrap());
    let child_session_id = context
        .session_manager
        .create_worker_session("mock/model", "/tmp", Some("Worker: Graph Child"))
        .unwrap();
    runtime
        .store
        .set_agent_session_id(&child.invocation_id, &child_session_id)
        .unwrap();
    context
        .event_store
        .append(&AppendOptions {
            session_id: &child_session_id,
            event_type: EventType::StreamTurnEnd,
            payload: json!({
                "turn":1,
                "model":"mock/model",
                "latency":75,
                "stopReason":"end_turn",
                "tokenUsage":{
                    "inputTokens":200,
                    "outputTokens":30,
                    "cacheReadTokens":20,
                    "cacheCreationTokens":7
                },
                "cost":0.0025
            }),
            parent_id: None,
            sequence: None,
        })
        .unwrap();
    let (grandchild, _) = runtime
        .store
        .begin_invocation_with_context(
            &published.worker.worker_id,
            &published.version,
            &json!({"query":"Inspect this descendant"}),
            "graph-agent-grandchild-key",
            "graph-agent-trace",
            2,
            "agent",
            Some("origin-session"),
            WorkerInteractionMode::Foreground,
            None,
            Some(&child.invocation_id),
            None,
            None,
            None,
        )
        .unwrap();
    assert!(
        runtime
            .store
            .claim_running(&grandchild.invocation_id)
            .unwrap()
    );
    let grandchild_session_id = context
        .session_manager
        .create_worker_session("mock/model", "/tmp", Some("Worker: Graph Grandchild"))
        .unwrap();
    runtime
        .store
        .set_agent_session_id(&grandchild.invocation_id, &grandchild_session_id)
        .unwrap();
    context
        .event_store
        .append(&AppendOptions {
            session_id: &grandchild_session_id,
            event_type: EventType::StreamTurnEnd,
            payload: json!({
                "turn":1,
                "model":"mock/model",
                "latency":50,
                "stopReason":"end_turn",
                "tokenUsage":{
                    "inputTokens":300,
                    "outputTokens":40,
                    "cacheReadTokens":30,
                    "cacheCreationTokens":9
                },
                "cost":0.0035
            }),
            parent_id: None,
            sequence: None,
        })
        .unwrap();
    runtime
        .store
        .complete_invocation(
            &grandchild.invocation_id,
            &published.worker.worker_id,
            Ok(&json!({"summary":"Grandchild complete"})),
        )
        .unwrap();
    let completed_child = runtime
        .store
        .complete_invocation(
            &child.invocation_id,
            &published.worker.worker_id,
            Ok(&json!({"summary":"Child complete"})),
        )
        .unwrap();
    runtime
        .store
        .complete_invocation(
            &invocation.invocation_id,
            &published.worker.worker_id,
            Ok(&json!({"summary":"Complete"})),
        )
        .unwrap();

    let graph = runtime.project_run_graph(&completed_child).unwrap();
    assert_eq!(graph["usage"]["inputTokens"], 600);
    assert_eq!(graph["usage"]["outputTokens"], 90);
    assert!((graph["usage"]["cost"].as_f64().unwrap() - 0.0185).abs() < f64::EPSILON);
    assert_eq!(graph["timing"]["modelMs"], 250);
    assert_eq!(
        graph["requestedInvocation"]["invocationId"],
        completed_child.invocation_id
    );
    assert_eq!(
        graph["requestedInvocation"]["workerVersion"],
        published.version
    );
    assert_eq!(graph["requestedInvocation"]["usage"]["inputTokens"], 500);
    assert_eq!(graph["requestedInvocation"]["usage"]["outputTokens"], 70);
    assert_eq!(graph["requestedInvocation"]["usage"]["cost"], 0.006);
    assert_eq!(
        graph["requestedInvocation"]["usage"]["includesDescendants"],
        true
    );
    assert!(graph["requestedInvocation"]["timing"]["wallMs"].is_u64());
    let nodes = graph["nodes"].as_array().unwrap();
    assert!(
        nodes
            .iter()
            .any(|node| { node["kind"] == "agent" && node["sessionId"] == session_id })
    );
    assert!(nodes.iter().any(|node| {
        node["kind"] == "model" && node["model"] == "mock/model" && node["turn"] == 1
    }));

    let metrics = runtime.project_run_metrics(&completed_child).unwrap();
    assert_eq!(metrics["invocationId"], completed_child.invocation_id);
    assert_eq!(metrics["workerId"], published.worker.worker_id);
    assert_eq!(metrics["workerName"], published.worker.name);
    assert_eq!(metrics["workerVersion"], published.version);
    assert_eq!(metrics["status"], "completed");
    assert_eq!(metrics["usage"]["inputTokens"], 500);
    assert_eq!(metrics["usage"]["outputTokens"], 70);
    assert_eq!(metrics["usage"]["cost"], 0.006);
    assert_eq!(metrics["usage"]["includesDescendants"], true);
    assert!(metrics["timing"]["wallMs"].is_u64());
    assert!(metrics.get("nodes").is_none());
    assert!(metrics.get("timeline").is_none());

    for index in 0..127 {
        runtime
            .store
            .begin_invocation_with_context(
                &published.worker.worker_id,
                &published.version,
                &json!({"query":format!("Bounded descendant {index}")}),
                &format!("graph-agent-bounded-child-{index}"),
                "graph-agent-trace",
                2,
                "agent",
                Some("origin-session"),
                WorkerInteractionMode::Foreground,
                None,
                Some(&completed_child.invocation_id),
                None,
                None,
                None,
            )
            .unwrap();
    }
    assert!(
        runtime
            .project_run_metrics(&completed_child)
            .unwrap_err()
            .contains("exceeds the bounded metrics projection")
    );
}

#[test]
fn engine_event_filters_are_recursive_json_subsets() {
    assert!(json_subset_matches(
        &json!({"kind":"message","nested":{"status":"ready"}}),
        &json!({"kind":"message","nested":{"status":"ready","extra":1}}),
    ));
    assert!(!json_subset_matches(
        &json!({"kind":"different"}),
        &json!({"kind":"message"}),
    ));
}

#[test]
fn engine_event_projection_overlays_only_typed_payload_fields_without_an_envelope() {
    let materialized = materialize_engine_event_input(
        &json!({"topic":"configured","asOf":"2026-07-20"}),
        &json!({"topic":"from-event","ready":true,"requestId":"ignored"}),
        &json!({
            "type":"object",
            "additionalProperties":false,
            "properties":{"topic":{"type":"string"},"asOf":{"type":"string"}}
        }),
    );
    assert_eq!(
        materialized,
        json!({"topic":"from-event","asOf":"2026-07-20"})
    );
    assert!(materialized.get("event").is_none());
    assert!(materialized.get("requestId").is_none());
}
