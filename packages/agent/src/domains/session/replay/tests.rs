use std::sync::Arc;

use serde_json::json;

use super::*;
use crate::domains::session::event_store::identity::{
    EventIdentity, SessionCreationIdentity, SessionIdentity, WorkspaceIdentity,
};
use crate::domains::session::event_store::{
    AppendOptions, ConnectionConfig, EventStore, EventType, new_file, run_migrations,
};
use crate::engine::{
    ActorId, ActorKind, CausalContext, EffectClass, EngineHostHandle, FunctionDefinition,
    FunctionId, IdempotencyContract, InProcessFunctionHandler, Invocation, PublishStreamEvent,
    TraceId, VisibilityScope, WorkerId,
};

struct ReplayWriteHandler;

#[async_trait::async_trait]
impl InProcessFunctionHandler for ReplayWriteHandler {
    async fn invoke(&self, invocation: Invocation) -> crate::engine::Result<serde_json::Value> {
        Ok(json!({"stored": invocation.payload}))
    }
}

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
    engine_host
        .register_function_for_setup(
            FunctionDefinition::new(
                FunctionId::new("replay::write").expect("function id"),
                WorkerId::new("replay").expect("owner id"),
                "Write deterministic replay evidence",
                VisibilityScope::System,
                EffectClass::IdempotentWrite,
            )
            .with_idempotency(IdempotencyContract::caller_session_engine_ledger()),
            Some(Arc::new(ReplayWriteHandler)),
        )
        .expect("register replay write function");
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
                    "format": "tron.model_provider_request.v2",
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

    let result = harness
        .engine_host
        .invoke(Invocation::new_sync(
            FunctionId::new("replay::write").unwrap(),
            json!({"sessionId": session_id, "value": {"ok": true}}),
            CausalContext::new(
                actor_id("actor-replay"),
                ActorKind::System,
                trace_id("state-trace"),
            )
            .with_session_id(session_id.clone())
            .with_workspace_id(workspace_id.clone())
            .with_idempotency_key("state-set-replay"),
        ))
        .await;
    assert_eq!(result.error, None, "state invocation failed: {result:?}");

    let failed_result = harness
        .engine_host
        .invoke(Invocation::new_sync(
            FunctionId::new("missing::run").unwrap(),
            json!({}),
            CausalContext::new(
                actor_id("actor-replay"),
                ActorKind::System,
                trace_id("missing-trace"),
            )
            .with_session_id(session_id.clone())
            .with_workspace_id(workspace_id.clone()),
        ))
        .await;
    assert!(
        failed_result.error.is_some(),
        "missing function should produce an engine failure"
    );

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

    let streams = first["sections"]["engineStreams"].as_array().unwrap();
    assert_eq!(streams.len(), 1);
    assert_eq!(streams[0]["payload"], json!({"stream": 1}));
    assert_eq!(streams[0]["payloadHash"].as_str().unwrap().len(), 64);

    let idempotency_entries = first["sections"]["engineIdempotencyEntries"]
        .as_array()
        .unwrap();
    assert_eq!(idempotency_entries.len(), 1);
    assert_eq!(
        idempotency_entries[0]["requestHash"],
        idempotency_entries[0]["payloadFingerprint"]
    );
    assert_eq!(
        idempotency_entries[0]["outcomeHash"]
            .as_str()
            .unwrap()
            .len(),
        64
    );

    let invocations = first["sections"]["engineInvocations"].as_array().unwrap();
    assert_eq!(invocations.len(), 2);
    for invocation in invocations {
        assert_eq!(invocation["resultHash"].as_str().unwrap().len(), 64);
    }
    let failed_invocation = invocations
        .iter()
        .find(|invocation| invocation["functionId"] == "missing::run")
        .expect("failed invocation should be exported");
    assert_eq!(
        failed_invocation["error"]["failure"]["code"],
        "ENGINE_STORED_INVOCATION_ERROR"
    );
    assert_eq!(
        failed_invocation["error"]["failure"]["category"],
        "capability"
    );
    assert_eq!(
        failed_invocation["error"]["kind"],
        "stored_invocation_error"
    );

    let roundtrip = roundtrip::roundtrip_manifest(&first).expect("offline roundtrip");
    assert_eq!(roundtrip.replay_hash, roundtrip.recomputed_replay_hash);
    assert!(roundtrip.section_hash_mismatches.is_empty());
    assert!(
        roundtrip
            .cross_record_references
            .cross_record_reference_errors
            .is_empty()
    );
    assert_eq!(roundtrip.counts.engine_idempotency_entries, 1);
    assert_eq!(roundtrip.counts.engine_invocations, 2);
}

fn actor_id(value: &str) -> ActorId {
    ActorId::new(value).unwrap()
}

fn trace_id(value: &str) -> TraceId {
    TraceId::new(value).unwrap()
}
