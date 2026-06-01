use super::*;

#[test]
fn session_updated_event_type() {
    let e = TronEvent::SessionUpdated {
        base: BaseEvent::now("s1"),
        title: Some("title".into()),
        model: Some("claude-opus-4-6".into()),
        event_count: Some(8),
        turn_count: Some(2),
        message_count: Some(5),
        input_tokens: Some(100),
        output_tokens: Some(50),
        last_turn_input_tokens: Some(20),
        cache_read_tokens: Some(10),
        cache_creation_tokens: Some(5),
        cost: Some(0.01),
        last_activity: "2024-01-01T00:00:00Z".into(),
        is_active: true,
        last_user_prompt: Some("hello".into()),
        last_assistant_response: Some("world".into()),
        parent_session_id: None,
        activity_lines: None,
    };
    assert_eq!(e.event_type(), "session_updated");
    assert_eq!(e.session_id(), "s1");
    let json = serde_json::to_value(&e).unwrap();
    assert_eq!(json["eventCount"], 8);
    assert_eq!(json["turnCount"], 2);
}

#[test]
fn memory_updating_event_type() {
    let e = TronEvent::MemoryUpdating {
        base: BaseEvent::now("s1"),
    };
    assert_eq!(e.event_type(), "memory_updating");
}

#[test]
fn memory_updated_event_type() {
    let e = TronEvent::MemoryUpdated {
        base: BaseEvent::now("s1"),
        title: Some("entry".into()),
        summary: Some("summary text".into()),
        entry_type: Some("feature".into()),
        event_id: Some("evt_123".into()),
        resource_refs: Some(vec![]),
    };
    assert_eq!(e.event_type(), "memory_updated");
}

#[test]
fn context_cleared_event_type() {
    let e = TronEvent::ContextCleared {
        base: BaseEvent::now("s1"),
        tokens_before: 5000,
        tokens_after: 0,
    };
    assert_eq!(e.event_type(), "context_cleared");
    let json = serde_json::to_value(&e).unwrap();
    assert_eq!(json["tokensBefore"], 5000);
    assert_eq!(json["tokensAfter"], 0);
}

#[test]
fn message_deleted_event_type() {
    let e = TronEvent::MessageDeleted {
        base: BaseEvent::now("s1"),
        target_event_id: "evt-123".into(),
        target_type: "message.user".into(),
        target_turn: Some(3),
        reason: Some("user request".into()),
    };
    assert_eq!(e.event_type(), "message_deleted");
    let json = serde_json::to_value(&e).unwrap();
    assert_eq!(json["targetEventId"], "evt-123");
    assert_eq!(json["targetType"], "message.user");
    assert_eq!(json["targetTurn"], 3);
}

#[test]
fn rules_loaded_event_type() {
    let e = TronEvent::RulesLoaded {
        base: BaseEvent::now("s1"),
        total_files: 3,
        dynamic_rules_count: 1,
    };
    assert_eq!(e.event_type(), "rules_loaded");
    let json = serde_json::to_value(&e).unwrap();
    assert_eq!(json["totalFiles"], 3);
    assert_eq!(json["dynamicRulesCount"], 1);
}

#[test]
fn display_frame_event_type_and_fields() {
    let e = TronEvent::DisplayFrame {
        base: BaseEvent::now("sess-1"),
        stream_id: "stream-1".into(),
        invocation_id: "call-1".into(),
        data: "base64jpeg".into(),
        frame_id: 42,
        width: 1280,
        height: 720,
    };
    assert_eq!(e.event_type(), "display_frame");
    assert_eq!(e.session_id(), "sess-1");

    let json = serde_json::to_value(&e).unwrap();
    assert_eq!(json["streamId"], "stream-1");
    assert_eq!(json["invocationId"], "call-1");
    assert_eq!(json["data"], "base64jpeg");
    assert_eq!(json["frameId"], 42);
    assert_eq!(json["width"], 1280);
    assert_eq!(json["height"], 720);
}

#[test]
fn display_frame_serde_roundtrip() {
    let original = TronEvent::DisplayFrame {
        base: BaseEvent::now("s1"),
        stream_id: "s".into(),
        invocation_id: "t".into(),
        data: "d".into(),
        frame_id: 1,
        width: 640,
        height: 480,
    };
    let json = serde_json::to_string(&original).unwrap();
    let deserialized: TronEvent = serde_json::from_str(&json).unwrap();
    assert_eq!(original, deserialized);
}

// ── Process management events ──

#[test]
fn process_spawned_event_type_and_fields() {
    let e = TronEvent::ProcessSpawned {
        base: BaseEvent::now("sess-1"),
        process_id: "proc-abc".into(),
        label: "cargo build".into(),
        kind: "shell".into(),
        background: true,
        invocation_id: "tc-1".into(),
    };
    assert_eq!(e.event_type(), "process_spawned");
    assert_eq!(e.session_id(), "sess-1");
    let json = serde_json::to_value(&e).unwrap();
    assert_eq!(json["processId"], "proc-abc");
    assert_eq!(json["label"], "cargo build");
    assert_eq!(json["kind"], "shell");
    assert_eq!(json["background"], true);
    assert_eq!(json["invocationId"], "tc-1");
}

#[test]
fn process_spawned_serde_roundtrip() {
    let original = TronEvent::ProcessSpawned {
        base: BaseEvent::now("s1"),
        process_id: "proc-1".into(),
        label: "test".into(),
        kind: "shell".into(),
        background: false,
        invocation_id: "tc-1".into(),
    };
    let json = serde_json::to_string(&original).unwrap();
    let back: TronEvent = serde_json::from_str(&json).unwrap();
    assert_eq!(original, back);
}

#[test]
fn process_status_update_event_type() {
    let e = TronEvent::ProcessStatusUpdate {
        base: BaseEvent::now("s1"),
        process_id: "proc-1".into(),
        status: "background".into(),
    };
    assert_eq!(e.event_type(), "process_status_update");
    let json = serde_json::to_value(&e).unwrap();
    assert_eq!(json["processId"], "proc-1");
    assert_eq!(json["status"], "background");
}

#[test]
fn process_completed_event_type_and_fields() {
    let e = TronEvent::ProcessCompleted {
        base: BaseEvent::now("sess-1"),
        parent_session_id: "sess-1".into(),
        process_id: "proc-abc".into(),
        label: "npm test".into(),
        success: false,
        exit_code: Some(1),
        duration: 12300,
        result_summary: "3 tests failed".into(),
        blob_id: Some("blob-xyz".into()),
        completed_at: "2026-03-29T12:00:00Z".into(),
    };
    assert_eq!(e.event_type(), "process_completed");
    let json = serde_json::to_value(&e).unwrap();
    assert_eq!(json["parentSessionId"], "sess-1");
    assert_eq!(json["processId"], "proc-abc");
    assert_eq!(json["label"], "npm test");
    assert_eq!(json["success"], false);
    assert_eq!(json["exitCode"], 1);
    assert_eq!(json["duration"], 12300);
    assert_eq!(json["resultSummary"], "3 tests failed");
    assert_eq!(json["blobId"], "blob-xyz");
    assert_eq!(json["completedAt"], "2026-03-29T12:00:00Z");
}

#[test]
fn process_completed_nullable_fields() {
    let e = TronEvent::ProcessCompleted {
        base: BaseEvent::now("s1"),
        parent_session_id: "s1".into(),
        process_id: "proc-1".into(),
        label: "stream".into(),
        success: true,
        exit_code: None,
        duration: 5000,
        result_summary: "stream ended".into(),
        blob_id: None,
        completed_at: "2026-03-29T12:00:00Z".into(),
    };
    let json = serde_json::to_value(&e).unwrap();
    // skip_serializing_if = None means these fields should be absent.
    assert!(json.get("exitCode").is_none());
    assert!(json.get("blobId").is_none());
}

#[test]
fn process_completed_serde_roundtrip() {
    let original = TronEvent::ProcessCompleted {
        base: BaseEvent::now("s1"),
        parent_session_id: "s1".into(),
        process_id: "proc-1".into(),
        label: "test".into(),
        success: true,
        exit_code: Some(0),
        duration: 100,
        result_summary: "ok".into(),
        blob_id: None,
        completed_at: "2026-03-29T12:00:00Z".into(),
    };
    let json = serde_json::to_string(&original).unwrap();
    let back: TronEvent = serde_json::from_str(&json).unwrap();
    assert_eq!(original, back);
}
