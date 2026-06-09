use std::collections::BTreeMap;
use std::sync::Arc;

use serde_json::json;

use super::*;
use crate::domains::session::event_store::identity::{
    EventIdentity, SessionCreationIdentity, SessionIdentity, WorkspaceIdentity,
};
use crate::domains::session::event_store::{AGENT_TRACE_VERSION, AgentTraceRecord};
use crate::domains::session::event_store::{
    AppendOptions, ConnectionConfig, EventStore, EventType, new_file, run_migrations,
};
use crate::engine::catalog::discovery::ActorKind;
use crate::engine::durability::queue::EnqueueInvocation;
use crate::engine::durability::streams::PublishStreamEvent;
use crate::engine::kernel::ids::{ActorId, AuthorityGrantId, FunctionId, TraceId};
use crate::engine::kernel::types::VisibilityScope;
use crate::engine::{CausalContext, EngineHostHandle, Invocation};

struct ReplayHarness {
    _temp: tempfile::TempDir,
    event_store: Arc<EventStore>,
    engine_host: EngineHostHandle,
}

fn harness() -> ReplayHarness {
    let temp = tempfile::tempdir().expect("tempdir");
    let db_path = temp.path().join("tron.sqlite");
    let pool = new_file(
        db_path.to_str().expect("db path"),
        &ConnectionConfig::default(),
    )
    .expect("event store");
    {
        let conn = pool.get().expect("connection");
        run_migrations(&conn).expect("migrations");
        crate::shared::storage::ensure_storage_schema(&conn).expect("storage schema");
    }
    let event_store = Arc::new(EventStore::new(pool));
    let engine_host = EngineHostHandle::open_sqlite(&db_path).expect("engine host");
    ReplayHarness {
        _temp: temp,
        event_store,
        engine_host,
    }
}

#[test]
fn canonical_hash_sorts_nested_object_keys() {
    let left = json!({"b": 1, "a": {"d": 4, "c": 3}});
    let right = json!({"a": {"c": 3, "d": 4}, "b": 1});

    assert_eq!(
        canonical_hash(&left).unwrap(),
        canonical_hash(&right).unwrap()
    );
}

#[tokio::test]
async fn replay_manifest_is_byte_stable_and_covers_durable_sections() {
    let harness = harness();
    let created = harness
        .event_store
        .create_session_with_identity(
            "openai/gpt-4o",
            "/tmp/tron-replay-workspace",
            Some("Replay manifest test"),
            Some("openai"),
            SessionCreationIdentity::new(
                WorkspaceIdentity::new("ws_replay_manifest", "2026-06-09T12:00:00Z"),
                SessionIdentity::new("sess_replay_manifest", "2026-06-09T12:00:01Z"),
                EventIdentity::new("evt_replay_root", "2026-06-09T12:00:02Z"),
            ),
        )
        .expect("session");
    let session_id = created.session.id.clone();
    let workspace_id = created.session.workspace_id.clone();

    harness
        .event_store
        .append_with_identity(
            &AppendOptions {
                session_id: &session_id,
                event_type: EventType::ModelProviderRequest,
                payload: json!({
                    "format": "tron.model_provider_request.v1",
                    "provider": "openai",
                    "model": "gpt-4o",
                    "request": {"messages": [{"role": "user", "content": "hi"}]},
                }),
                parent_id: None,
                sequence: None,
            },
            EventIdentity::new("evt_provider_audit", "2026-06-09T12:00:03Z"),
        )
        .expect("provider audit");

    for id in ["trace-b", "trace-a"] {
        harness
            .event_store
            .append_trace_record(&AgentTraceRecord {
                id: id.to_owned(),
                trace_id: "trace-shared".to_owned(),
                invocation_id: format!("inv-{id}"),
                parent_invocation_id: None,
                provider_invocation_id: None,
                session_id: Some(session_id.clone()),
                workspace_id: Some(workspace_id.clone()),
                turn: Some(1),
                model_primitive_name: "execute".to_owned(),
                operation: "observe".to_owned(),
                status: "ok".to_owned(),
                timestamp: "2026-06-09T12:00:04Z".to_owned(),
                completed_at: Some("2026-06-09T12:00:05Z".to_owned()),
                duration_ms: Some(1),
                record_json: json!({
                    "version": AGENT_TRACE_VERSION,
                    "id": id,
                }),
            })
            .expect("trace record");
    }

    harness
        .engine_host
        .publish_stream_event(PublishStreamEvent {
            topic: "events.session".to_owned(),
            payload: json!({"stream": 1}),
            visibility: VisibilityScope::Session,
            session_id: Some(session_id.clone()),
            workspace_id: Some(workspace_id.clone()),
            producer: "test".to_owned(),
            trace_id: Some(trace_id("stream-trace")),
            parent_invocation_id: None,
        })
        .await
        .expect("stream event");
    harness
        .engine_host
        .publish_stream_event(PublishStreamEvent {
            topic: "events.session".to_owned(),
            payload: json!({"stream": "other-session"}),
            visibility: VisibilityScope::Session,
            session_id: Some("sess_other".to_owned()),
            workspace_id: Some(workspace_id.clone()),
            producer: "test".to_owned(),
            trace_id: Some(trace_id("other-stream-trace")),
            parent_invocation_id: None,
        })
        .await
        .expect("other stream event");

    enqueue_for_session(&harness.engine_host, "beta", &session_id, &workspace_id).await;
    enqueue_for_session(&harness.engine_host, "alpha", &session_id, &workspace_id).await;

    let result = harness
        .engine_host
        .invoke(Invocation::new_sync(
            FunctionId::new("state::set").unwrap(),
            json!({
                "scope": "session",
                "sessionId": session_id,
                "namespace": "replay",
                "key": "marker",
                "value": {"ok": true}
            }),
            CausalContext::new(
                actor_id("actor-replay"),
                ActorKind::System,
                grant_id("grant"),
                trace_id("state-trace"),
            )
            .with_scope("state.write")
            .with_session_id(session_id.clone())
            .with_workspace_id(workspace_id.clone())
            .with_idempotency_key("state-set-replay"),
        ))
        .await;
    assert_eq!(result.error, None, "state invocation failed: {result:?}");

    let deps = ReplayDeps::new(harness.event_store.clone(), harness.engine_host.clone());
    let first = replay_manifest_value(deps.clone(), session_id.clone())
        .await
        .expect("first manifest");
    let second = replay_manifest_value(deps, session_id)
        .await
        .expect("second manifest");
    assert_eq!(first, second);

    assert_eq!(first["format"], REPLAY_MANIFEST_FORMAT);
    assert_eq!(first["replayHash"].as_str().unwrap().len(), 64);
    for hash in first["sectionHashes"].as_object().unwrap().values() {
        assert_eq!(hash.as_str().unwrap().len(), 64);
    }

    let provider_audits = first["sections"]["providerAudits"].as_array().unwrap();
    assert_eq!(provider_audits.len(), 1);
    assert_eq!(provider_audits[0]["eventId"], "evt_provider_audit");

    let traces = first["sections"]["traceRecords"].as_array().unwrap();
    let trace_ids = traces
        .iter()
        .map(|record| record["id"].as_str().unwrap())
        .collect::<Vec<_>>();
    assert_eq!(trace_ids, ["trace-a", "trace-b"]);

    let streams = first["sections"]["engineStreams"].as_array().unwrap();
    assert_eq!(streams.len(), 1);
    assert_eq!(streams[0]["payload"], json!({"stream": 1}));

    let queue_items = first["sections"]["engineQueueItems"].as_array().unwrap();
    let queue_names = queue_items
        .iter()
        .map(|item| item["queue"].as_str().unwrap())
        .collect::<Vec<_>>();
    assert_eq!(queue_names, ["alpha", "beta"]);

    assert_eq!(
        first["sections"]["engineInvocations"]
            .as_array()
            .unwrap()
            .len(),
        1
    );
}

async fn enqueue_for_session(
    engine_host: &EngineHostHandle,
    queue: &str,
    session_id: &str,
    workspace_id: &str,
) {
    engine_host
        .enqueue_invocation(EnqueueInvocation {
            queue: queue.to_owned(),
            function_id: FunctionId::new("state::get").unwrap(),
            payload: json!({
                "scope": "session",
                "sessionId": session_id,
                "namespace": "replay",
                "key": "marker"
            }),
            actor_id: actor_id("actor-queue"),
            actor_kind: ActorKind::System,
            authority_grant_id: grant_id("grant-queue"),
            authority_scopes: vec!["state.read".to_owned()],
            runtime_metadata: BTreeMap::new(),
            trace_id: trace_id(&format!("{queue}-trace")),
            parent_invocation_id: None,
            trigger_id: None,
            session_id: Some(session_id.to_owned()),
            workspace_id: Some(workspace_id.to_owned()),
            idempotency_key: Some(format!("{queue}-key")),
        })
        .await
        .expect("queue item");
}

fn actor_id(value: &str) -> ActorId {
    ActorId::new(value).unwrap()
}

fn grant_id(value: &str) -> AuthorityGrantId {
    AuthorityGrantId::new(value).unwrap()
}

fn trace_id(value: &str) -> TraceId {
    TraceId::new(value).unwrap()
}
