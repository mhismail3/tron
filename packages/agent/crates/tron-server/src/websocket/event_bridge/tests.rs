use super::*;
use tron_core::events::{BaseEvent, agent_start_event};

#[test]
fn converts_agent_start() {
    let event = agent_start_event("s1");
    let rpc = tron_event_to_rpc(&event);
    assert_eq!(rpc.event_type, "agent.start");
    assert_eq!(rpc.session_id.as_deref(), Some("s1"));
}

#[test]
fn converts_text_delta() {
    let event = TronEvent::MessageUpdate {
        base: BaseEvent::now("s1"),
        content: "hello world".into(),
    };
    let rpc = tron_event_to_rpc(&event);
    assert_eq!(rpc.event_type, "agent.text_delta");
    assert_eq!(rpc.data.unwrap()["delta"], "hello world");
}

#[test]
fn converts_tool_execution() {
    let event = TronEvent::ToolExecutionStart {
        base: BaseEvent::now("s1"),
        tool_name: "bash".into(),
        tool_call_id: "tc_1".into(),
        arguments: None,
    };
    let rpc = tron_event_to_rpc(&event);
    assert_eq!(rpc.event_type, "agent.tool_start");
    let data = rpc.data.unwrap();
    assert_eq!(data["toolName"], "bash");
    assert_eq!(data["toolCallId"], "tc_1");
}

#[test]
fn converts_turn_events() {
    let start = TronEvent::TurnStart {
        base: BaseEvent::now("s1"),
        turn: 3,
    };
    let end = TronEvent::TurnEnd {
        base: BaseEvent::now("s1"),
        turn: 3,
        duration: 0,
        token_usage: None,
        token_record: None,
        cost: None,
        stop_reason: None,
        context_limit: None,
        model: None,
    };
    assert_eq!(tron_event_to_rpc(&start).event_type, "agent.turn_start");
    assert_eq!(tron_event_to_rpc(&end).event_type, "agent.turn_end");
}

#[test]
fn converts_agent_complete() {
    let event = TronEvent::AgentEnd {
        base: BaseEvent::now("s1"),
        error: None,
    };
    let rpc = tron_event_to_rpc(&event);
    assert_eq!(rpc.event_type, "agent.complete");
}

#[test]
fn converts_agent_ready() {
    let event = TronEvent::AgentReady {
        base: BaseEvent::now("s1"),
    };
    let rpc = tron_event_to_rpc(&event);
    assert_eq!(rpc.event_type, "agent.ready");
}

#[test]
fn empty_session_id_becomes_none() {
    let event = TronEvent::AgentReady {
        base: BaseEvent::now(""),
    };
    let rpc = tron_event_to_rpc(&event);
    assert!(rpc.session_id.is_none());
}

#[test]
fn has_timestamp() {
    let event = agent_start_event("s1");
    let rpc = tron_event_to_rpc(&event);
    assert!(!rpc.timestamp.is_empty());
}

#[test]
fn message_updates_stay_session_scoped() {
    let event = TronEvent::MessageUpdate {
        base: BaseEvent::now("s1"),
        content: "hello".into(),
    };
    let bridged = tron_event_to_bridged(&event);
    assert_eq!(bridged.scope, BroadcastScope::Session("s1".into()));
}

#[test]
fn turn_start_remains_global() {
    let event = TronEvent::TurnStart {
        base: BaseEvent::now("s1"),
        turn: 1,
    };
    let bridged = tron_event_to_bridged(&event);
    assert_eq!(bridged.scope, BroadcastScope::All);
}

#[test]
fn session_updated_remains_global() {
    let event = TronEvent::SessionUpdated {
        base: BaseEvent::now("s1"),
        title: Some("title".into()),
        model: "claude-opus-4-6".into(),
        message_count: 2,
        input_tokens: 10,
        output_tokens: 20,
        last_turn_input_tokens: 10,
        cache_read_tokens: 0,
        cache_creation_tokens: 0,
        cost: 0.1,
        last_activity: chrono::Utc::now().to_rfc3339(),
        is_active: true,
        last_user_prompt: None,
        last_assistant_response: None,
        parent_session_id: None,
    };
    let bridged = tron_event_to_bridged(&event);
    assert_eq!(bridged.scope, BroadcastScope::All);
}

#[test]
fn session_saved_stays_session_scoped() {
    let event = TronEvent::SessionSaved {
        base: BaseEvent::now("s1"),
        file_path: "/tmp/session.json".into(),
    };
    let bridged = tron_event_to_bridged(&event);
    assert_eq!(bridged.scope, BroadcastScope::Session("s1".into()));
}

#[test]
fn browser_frames_stay_session_scoped() {
    let event = BrowserEvent::Frame {
        session_id: "s1".into(),
        frame: tron_tools::cdp::types::BrowserFrame {
            session_id: "browser-1".into(),
            frame_id: 7,
            timestamp: 1_707_999_045_123,
            data: "payload".into(),
            metadata: Some(tron_tools::cdp::types::FrameMetadata::default()),
        },
    };
    let bridged = browser_event_to_bridged(&event);
    assert_eq!(bridged.scope, BroadcastScope::Session("s1".into()));
}

#[tokio::test]
async fn bridge_routes_browser_frames_to_bound_session() {
    let (tron_tx, _) = broadcast::channel::<TronEvent>(16);
    let (browser_tx, browser_rx) = broadcast::channel::<BrowserEvent>(16);
    let bm = Arc::new(BroadcastManager::new());

    let (conn1_tx, mut conn1_rx) = tokio::sync::mpsc::unbounded_channel();
    let conn1 = super::super::connection::ClientConnection::new("c1".into(), conn1_tx);
    conn1.bind_session("s1");
    bm.add(Arc::new(conn1)).await;

    let (conn2_tx, mut conn2_rx) = tokio::sync::mpsc::unbounded_channel();
    let conn2 = super::super::connection::ClientConnection::new("c2".into(), conn2_tx);
    bm.add(Arc::new(conn2)).await;

    let rx = tron_tx.subscribe();
    let bridge = EventBridge::new(
        rx,
        bm.clone(),
        Some(browser_rx),
        CancellationToken::new(),
        Arc::new(TurnAccumulatorMap::new()),
    );
    let handle = tokio::spawn(bridge.run());

    let _ = browser_tx
        .send(BrowserEvent::Frame {
            session_id: "s1".into(),
            frame: tron_tools::cdp::types::BrowserFrame {
                session_id: "browser-1".into(),
                frame_id: 7,
                timestamp: 1_707_999_045_123,
                data: "payload".into(),
                metadata: Some(tron_tools::cdp::types::FrameMetadata::default()),
            },
        })
        .unwrap();
    tokio::time::sleep(std::time::Duration::from_millis(50)).await;

    let msg = conn1_rx.try_recv();
    assert!(
        msg.is_ok(),
        "bound session client should receive browser frame"
    );
    let parsed: serde_json::Value = serde_json::from_str(&msg.unwrap()).unwrap();
    assert_eq!(parsed["type"], "browser.frame");

    assert!(
        conn2_rx.try_recv().is_err(),
        "unbound client should not receive session-scoped browser frame"
    );

    drop(browser_tx);
    drop(tron_tx);
    let _ = handle.await;
}

#[tokio::test]
async fn bridge_routes_session_events() {
    let (tx, _) = broadcast::channel(16);
    let bm = Arc::new(BroadcastManager::new());

    // Two clients: C1 bound to "s1", C2 unbound (dashboard)
    let (conn1_tx, mut conn1_rx) = tokio::sync::mpsc::unbounded_channel();
    let conn1 = super::super::connection::ClientConnection::new("c1".into(), conn1_tx);
    conn1.bind_session("s1");
    bm.add(Arc::new(conn1)).await;

    let (conn2_tx, mut conn2_rx) = tokio::sync::mpsc::unbounded_channel();
    let conn2 = super::super::connection::ClientConnection::new("c2".into(), conn2_tx);
    bm.add(Arc::new(conn2)).await;

    let rx = tx.subscribe();
    let bridge = EventBridge::new(
        rx,
        bm.clone(),
        None,
        CancellationToken::new(),
        Arc::new(TurnAccumulatorMap::new()),
    );
    let handle = tokio::spawn(bridge.run());

    // AgentStart is NOT in the global list — should only reach C1 (bound to "s1")
    let _ = tx.send(agent_start_event("s1")).unwrap();
    tokio::time::sleep(std::time::Duration::from_millis(50)).await;

    let msg = conn1_rx.try_recv();
    assert!(msg.is_ok());
    let parsed: serde_json::Value = serde_json::from_str(&msg.unwrap()).unwrap();
    assert_eq!(parsed["type"], "agent.start");

    // C2 should NOT receive AgentStart (session-scoped)
    assert!(conn2_rx.try_recv().is_err());

    drop(tx);
    let _ = handle.await;
}

#[tokio::test]
async fn bridge_broadcasts_session_lifecycle_to_all() {
    let (tx, _) = broadcast::channel(16);
    let bm = Arc::new(BroadcastManager::new());

    // C1 bound to "s1", C2 unbound (dashboard)
    let (conn1_tx, mut conn1_rx) = tokio::sync::mpsc::unbounded_channel();
    let conn1 = super::super::connection::ClientConnection::new("c1".into(), conn1_tx);
    conn1.bind_session("s1");
    bm.add(Arc::new(conn1)).await;

    let (conn2_tx, mut conn2_rx) = tokio::sync::mpsc::unbounded_channel();
    let conn2 = super::super::connection::ClientConnection::new("c2".into(), conn2_tx);
    bm.add(Arc::new(conn2)).await;

    let rx = tx.subscribe();
    let bridge = EventBridge::new(
        rx,
        bm.clone(),
        None,
        CancellationToken::new(),
        Arc::new(TurnAccumulatorMap::new()),
    );
    let handle = tokio::spawn(bridge.run());

    // SessionCreated for "s2" — both clients should receive it
    let _ = tx
        .send(TronEvent::SessionCreated {
            base: BaseEvent::now("s2"),
            model: "claude-opus-4-6".into(),
            working_directory: "/tmp".into(),
            source: None,
        })
        .unwrap();
    tokio::time::sleep(std::time::Duration::from_millis(50)).await;

    let msg1 = conn1_rx.try_recv();
    assert!(msg1.is_ok(), "C1 should receive session.created");
    let parsed1: serde_json::Value = serde_json::from_str(&msg1.unwrap()).unwrap();
    assert_eq!(parsed1["type"], "session.created");

    let msg2 = conn2_rx.try_recv();
    assert!(msg2.is_ok(), "C2 should receive session.created");
    let parsed2: serde_json::Value = serde_json::from_str(&msg2.unwrap()).unwrap();
    assert_eq!(parsed2["type"], "session.created");

    drop(tx);
    let _ = handle.await;
}

#[tokio::test]
async fn bridge_broadcasts_turn_start_to_all() {
    let (tx, _) = broadcast::channel(16);
    let bm = Arc::new(BroadcastManager::new());

    let (conn1_tx, mut conn1_rx) = tokio::sync::mpsc::unbounded_channel();
    let conn1 = super::super::connection::ClientConnection::new("c1".into(), conn1_tx);
    conn1.bind_session("s1");
    bm.add(Arc::new(conn1)).await;

    let (conn2_tx, mut conn2_rx) = tokio::sync::mpsc::unbounded_channel();
    let conn2 = super::super::connection::ClientConnection::new("c2".into(), conn2_tx);
    bm.add(Arc::new(conn2)).await;

    let rx = tx.subscribe();
    let bridge = EventBridge::new(
        rx,
        bm.clone(),
        None,
        CancellationToken::new(),
        Arc::new(TurnAccumulatorMap::new()),
    );
    let handle = tokio::spawn(bridge.run());

    // TurnStart for "s1" — both clients should receive it (global)
    let _ = tx
        .send(TronEvent::TurnStart {
            base: BaseEvent::now("s1"),
            turn: 1,
        })
        .unwrap();
    tokio::time::sleep(std::time::Duration::from_millis(50)).await;

    assert!(conn1_rx.try_recv().is_ok(), "C1 should receive turn_start");
    assert!(conn2_rx.try_recv().is_ok(), "C2 should receive turn_start");

    drop(tx);
    let _ = handle.await;
}

#[tokio::test]
async fn bridge_keeps_content_events_session_scoped() {
    let (tx, _) = broadcast::channel(16);
    let bm = Arc::new(BroadcastManager::new());

    let (conn1_tx, mut conn1_rx) = tokio::sync::mpsc::unbounded_channel();
    let conn1 = super::super::connection::ClientConnection::new("c1".into(), conn1_tx);
    conn1.bind_session("s1");
    bm.add(Arc::new(conn1)).await;

    let (conn2_tx, mut conn2_rx) = tokio::sync::mpsc::unbounded_channel();
    let conn2 = super::super::connection::ClientConnection::new("c2".into(), conn2_tx);
    bm.add(Arc::new(conn2)).await;

    let rx = tx.subscribe();
    let bridge = EventBridge::new(
        rx,
        bm.clone(),
        None,
        CancellationToken::new(),
        Arc::new(TurnAccumulatorMap::new()),
    );
    let handle = tokio::spawn(bridge.run());

    // MessageUpdate for "s1" — only C1 should receive it
    let _ = tx
        .send(TronEvent::MessageUpdate {
            base: BaseEvent::now("s1"),
            content: "hello".into(),
        })
        .unwrap();
    tokio::time::sleep(std::time::Duration::from_millis(50)).await;

    assert!(
        conn1_rx.try_recv().is_ok(),
        "C1 should receive message_update"
    );
    assert!(
        conn2_rx.try_recv().is_err(),
        "C2 should NOT receive message_update"
    );

    drop(tx);
    let _ = handle.await;
}

#[tokio::test]
async fn bridge_routes_global_events() {
    let (tx, _) = broadcast::channel(16);
    let bm = Arc::new(BroadcastManager::new());

    let (conn_tx, mut conn_rx) = tokio::sync::mpsc::unbounded_channel();
    let conn = super::super::connection::ClientConnection::new("c1".into(), conn_tx);
    bm.add(Arc::new(conn)).await;

    let rx = tx.subscribe();
    let bridge = EventBridge::new(
        rx,
        bm.clone(),
        None,
        CancellationToken::new(),
        Arc::new(TurnAccumulatorMap::new()),
    );
    let handle = tokio::spawn(bridge.run());

    // Send event with empty session_id (global)
    let _ = tx
        .send(TronEvent::AgentReady {
            base: BaseEvent::now(""),
        })
        .unwrap();

    tokio::time::sleep(std::time::Duration::from_millis(50)).await;

    let msg = conn_rx.try_recv();
    assert!(msg.is_ok());

    drop(tx);
    let _ = handle.await;
}

#[tokio::test]
async fn bridge_continues_without_browser_after_browser_channel_closes() {
    let (tron_tx, _) = broadcast::channel::<TronEvent>(16);
    let (browser_tx, browser_rx) = broadcast::channel::<BrowserEvent>(16);
    let bm = Arc::new(BroadcastManager::new());

    let (conn_tx, mut conn_rx) = tokio::sync::mpsc::unbounded_channel();
    let conn = super::super::connection::ClientConnection::new("c1".into(), conn_tx);
    conn.bind_session("s1");
    bm.add(Arc::new(conn)).await;

    let rx = tron_tx.subscribe();
    let bridge = EventBridge::new(
        rx,
        bm.clone(),
        Some(browser_rx),
        CancellationToken::new(),
        Arc::new(TurnAccumulatorMap::new()),
    );
    let handle = tokio::spawn(bridge.run());

    // Close browser channel
    drop(browser_tx);
    tokio::time::sleep(std::time::Duration::from_millis(50)).await;

    // Tron events should still flow
    let _ = tron_tx.send(agent_start_event("s1")).unwrap();
    tokio::time::sleep(std::time::Duration::from_millis(50)).await;

    let msg = conn_rx.try_recv();
    assert!(msg.is_ok());
    let parsed: serde_json::Value = serde_json::from_str(&msg.unwrap()).unwrap();
    assert_eq!(parsed["type"], "agent.start");

    drop(tron_tx);
    let _ = handle.await;
}

#[test]
fn turn_end_passes_through_token_record() {
    let token_record = serde_json::json!({
        "source": {
            "rawInputTokens": 100,
            "rawOutputTokens": 50,
            "rawCacheReadTokens": 10,
            "rawCacheCreationTokens": 0,
            "rawCacheCreation5mTokens": 0,
            "rawCacheCreation1hTokens": 0,
            "provider": "anthropic",
            "timestamp": "2024-01-01T00:00:00Z",
        },
        "computed": {
            "contextWindowTokens": 110,
            "newInputTokens": 110,
            "previousContextBaseline": 0,
            "calculationMethod": "anthropic_cache_aware",
        },
        "meta": {
            "turn": 2,
            "sessionId": "s1",
            "extractedAt": "2024-01-01T00:00:00Z",
            "normalizedAt": "2024-01-01T00:00:00Z",
        }
    });
    let event = TronEvent::TurnEnd {
        base: BaseEvent::now("s1"),
        turn: 2,
        duration: 5000,
        token_usage: Some(tron_core::events::TurnTokenUsage {
            input_tokens: 100,
            output_tokens: 50,
            cache_read_tokens: Some(10),
            ..Default::default()
        }),
        token_record: Some(token_record.clone()),
        cost: None,
        stop_reason: None,
        context_limit: None,
        model: None,
    };
    let rpc = tron_event_to_rpc(&event);
    let data = rpc.data.unwrap();
    // The token record is passed through unchanged from the runtime
    assert_eq!(data["tokenRecord"], token_record);
}

#[test]
fn turn_end_no_token_record_omits_field() {
    let event = TronEvent::TurnEnd {
        base: BaseEvent::now("s1"),
        turn: 1,
        duration: 1000,
        token_usage: Some(tron_core::events::TurnTokenUsage {
            input_tokens: 50,
            output_tokens: 25,
            ..Default::default()
        }),
        token_record: None,
        cost: None,
        stop_reason: None,
        context_limit: None,
        model: None,
    };
    let rpc = tron_event_to_rpc(&event);
    let data = rpc.data.unwrap();
    assert!(data.get("tokenRecord").is_none());
}

#[test]
fn turn_end_includes_full_payload() {
    let event = TronEvent::TurnEnd {
        base: BaseEvent::now("s1"),
        turn: 2,
        duration: 5000,
        token_usage: Some(tron_core::events::TurnTokenUsage {
            input_tokens: 100,
            output_tokens: 50,
            cache_read_tokens: Some(10),
            ..Default::default()
        }),
        token_record: None,
        cost: Some(0.005),
        stop_reason: Some("end_turn".into()),
        context_limit: Some(200_000),
        model: None,
    };
    let rpc = tron_event_to_rpc(&event);
    assert_eq!(rpc.event_type, "agent.turn_end");
    let data = rpc.data.unwrap();
    assert_eq!(data["turn"], 2);
    assert_eq!(data["duration"], 5000);
    assert_eq!(data["tokenUsage"]["inputTokens"], 100);
    assert_eq!(data["tokenUsage"]["outputTokens"], 50);
    assert_eq!(data["cost"], 0.005);
    assert_eq!(data["stopReason"], "end_turn");
    assert_eq!(data["contextLimit"], 200_000);
}

#[test]
fn tool_end_success_has_required_fields() {
    use tron_core::tools::{ToolResultBody, TronToolResult};
    let event = TronEvent::ToolExecutionEnd {
        base: BaseEvent::now("s1"),
        tool_call_id: "tc_1".into(),
        tool_name: "bash".into(),
        duration: 1500,
        is_error: Some(false),
        result: Some(TronToolResult {
            content: ToolResultBody::Text("file1.txt\nfile2.txt".into()),
            details: None,
            is_error: Some(false),
            stop_turn: None,
        }),
    };
    let rpc = tron_event_to_rpc(&event);
    assert_eq!(rpc.event_type, "agent.tool_end");
    let data = rpc.data.unwrap();
    // Required field: success (non-optional Bool)
    assert_eq!(data["success"], true);
    assert_eq!(data["toolCallId"], "tc_1");
    assert_eq!(data["toolName"], "bash");
    assert_eq!(data["duration"], 1500);
    assert_eq!(data["output"], "file1.txt\nfile2.txt");
    assert!(data.get("result").is_none());
    assert!(data.get("durationMs").is_none());
}

#[test]
fn tool_end_error_has_required_fields() {
    use tron_core::tools::{ToolResultBody, TronToolResult};
    let event = TronEvent::ToolExecutionEnd {
        base: BaseEvent::now("s1"),
        tool_call_id: "tc_1".into(),
        tool_name: "bash".into(),
        duration: 500,
        is_error: Some(true),
        result: Some(TronToolResult {
            content: ToolResultBody::Text("command not found".into()),
            details: None,
            is_error: Some(true),
            stop_turn: None,
        }),
    };
    let rpc = tron_event_to_rpc(&event);
    let data = rpc.data.unwrap();
    assert_eq!(data["success"], false);
    assert_eq!(data["error"], "command not found");
    // On error, output/result should NOT be set
    assert!(data.get("output").is_none());
    assert!(data.get("result").is_none());
    assert_eq!(data["duration"], 500);
    assert!(data.get("durationMs").is_none());
}

#[test]
fn tool_end_with_details() {
    use tron_core::tools::{ToolResultBody, TronToolResult};
    let event = TronEvent::ToolExecutionEnd {
        base: BaseEvent::now("s1"),
        tool_call_id: "tc_1".into(),
        tool_name: "browser".into(),
        duration: 2000,
        is_error: Some(false),
        result: Some(TronToolResult {
            content: ToolResultBody::Text("page loaded".into()),
            details: Some(serde_json::json!({
                "screenshot": "base64data",
                "format": "png",
            })),
            is_error: Some(false),
            stop_turn: None,
        }),
    };
    let rpc = tron_event_to_rpc(&event);
    let data = rpc.data.unwrap();
    assert_eq!(data["success"], true);
    assert_eq!(data["details"]["screenshot"], "base64data");
    assert_eq!(data["details"]["format"], "png");
}

#[test]
fn tool_end_no_result_still_has_success() {
    let event = TronEvent::ToolExecutionEnd {
        base: BaseEvent::now("s1"),
        tool_call_id: "tc_1".into(),
        tool_name: "bash".into(),
        duration: 1500,
        is_error: None,
        result: None,
    };
    let rpc = tron_event_to_rpc(&event);
    let data = rpc.data.unwrap();
    // Even without result, success must be present (required by wire format)
    assert_eq!(data["success"], true);
    assert_eq!(data["duration"], 1500);
    assert!(data.get("durationMs").is_none());
}

#[test]
fn tool_end_content_blocks_joined() {
    use tron_core::content::ToolResultContent;
    use tron_core::tools::{ToolResultBody, TronToolResult};
    let event = TronEvent::ToolExecutionEnd {
        base: BaseEvent::now("s1"),
        tool_call_id: "tc_1".into(),
        tool_name: "read".into(),
        duration: 100,
        is_error: Some(false),
        result: Some(TronToolResult {
            content: ToolResultBody::Blocks(vec![
                ToolResultContent::Text {
                    text: "line 1".into(),
                },
                ToolResultContent::Text {
                    text: "line 2".into(),
                },
            ]),
            details: None,
            is_error: Some(false),
            stop_turn: None,
        }),
    };
    let rpc = tron_event_to_rpc(&event);
    let data = rpc.data.unwrap();
    assert_eq!(data["output"], "line 1\nline 2");
}

#[test]
fn agent_end_includes_error() {
    let event = TronEvent::AgentEnd {
        base: BaseEvent::now("s1"),
        error: Some("rate limit exceeded".into()),
    };
    let rpc = tron_event_to_rpc(&event);
    assert_eq!(rpc.event_type, "agent.complete");
    let data = rpc.data.unwrap();
    assert_eq!(data["error"], "rate limit exceeded");
}

#[test]
fn agent_end_no_error_has_no_data() {
    let event = TronEvent::AgentEnd {
        base: BaseEvent::now("s1"),
        error: None,
    };
    let rpc = tron_event_to_rpc(&event);
    assert_eq!(rpc.event_type, "agent.complete");
    assert!(rpc.data.is_none());
}

#[test]
fn error_includes_context() {
    let event = TronEvent::Error {
        base: BaseEvent::now("s1"),
        error: "connection failed".into(),
        context: Some("during tool execution".into()),
        code: None,
        provider: None,
        category: None,
        suggestion: None,
        retryable: None,
        status_code: None,
        error_type: None,
        model: None,
    };
    let rpc = tron_event_to_rpc(&event);
    assert_eq!(rpc.event_type, "agent.error");
    let data = rpc.data.unwrap();
    assert_eq!(data["message"], "connection failed");
    assert_eq!(data["context"], "during tool execution");
}

#[test]
fn error_enrichment_fields_passed_through() {
    let event = TronEvent::Error {
        base: BaseEvent::now("s1"),
        error: "rate limit".into(),
        context: None,
        code: Some("rate_limit_error".into()),
        provider: Some("anthropic".into()),
        category: Some("rate_limit".into()),
        suggestion: Some("Wait and retry".into()),
        retryable: Some(true),
        status_code: Some(429),
        error_type: Some("RateLimitError".into()),
        model: Some("claude-opus-4-6".into()),
    };
    let rpc = tron_event_to_rpc(&event);
    assert_eq!(rpc.event_type, "agent.error");
    let data = rpc.data.unwrap();
    assert_eq!(data["message"], "rate limit");
    assert_eq!(data["code"], "rate_limit_error");
    assert_eq!(data["provider"], "anthropic");
    assert_eq!(data["category"], "rate_limit");
    assert_eq!(data["suggestion"], "Wait and retry");
    assert_eq!(data["retryable"], true);
    assert_eq!(data["statusCode"], 429);
    assert_eq!(data["errorType"], "RateLimitError");
    assert_eq!(data["model"], "claude-opus-4-6");
}

#[test]
fn error_omits_none_enrichment_fields() {
    let event = TronEvent::Error {
        base: BaseEvent::now("s1"),
        error: "unknown".into(),
        context: None,
        code: None,
        provider: None,
        category: None,
        suggestion: None,
        retryable: None,
        status_code: None,
        error_type: None,
        model: None,
    };
    let rpc = tron_event_to_rpc(&event);
    let data = rpc.data.unwrap();
    assert_eq!(data["message"], "unknown");
    assert!(data.get("code").is_none());
    assert!(data.get("provider").is_none());
    assert!(data.get("statusCode").is_none());
}

#[test]
fn session_created_has_required_fields() {
    let event = TronEvent::SessionCreated {
        base: BaseEvent::now("s1"),
        model: "claude-opus-4-6".into(),
        working_directory: "/tmp/project".into(),
        source: None,
    };
    let rpc = tron_event_to_rpc(&event);
    assert_eq!(rpc.event_type, "session.created");
    let data = rpc.data.unwrap();
    assert_eq!(data["model"], "claude-opus-4-6");
    assert_eq!(data["workingDirectory"], "/tmp/project");
    assert_eq!(data["messageCount"], 0);
    assert_eq!(data["inputTokens"], 0);
    assert_eq!(data["isChat"], false);
    assert_eq!(data["outputTokens"], 0);
    assert_eq!(data["cost"], 0.0);
    assert_eq!(data["isActive"], true);
    assert!(data.get("lastActivity").is_some());
}

#[test]
fn compaction_maps_to_wire_names() {
    let event = TronEvent::CompactionStart {
        base: BaseEvent::now("s1"),
        reason: tron_core::events::CompactionReason::ThresholdExceeded,
        tokens_before: 50_000,
    };
    let rpc = tron_event_to_rpc(&event);
    assert_eq!(rpc.event_type, "agent.compaction_started");

    let event = TronEvent::CompactionComplete {
        base: BaseEvent::now("s1"),
        success: true,
        tokens_before: 50_000,
        tokens_after: 20_000,
        compression_ratio: 0.4,
        reason: None,
        summary: None,
        estimated_context_tokens: None,
    };
    let rpc = tron_event_to_rpc(&event);
    assert_eq!(rpc.event_type, "agent.compaction");
}

#[test]
fn hook_events_map_correctly() {
    let event = TronEvent::HookTriggered {
        base: BaseEvent::now("s1"),
        hook_names: vec!["pre-tool-use".into()],
        hook_event: "PreToolUse".into(),
        tool_name: Some("bash".into()),
        tool_call_id: Some("tc_1".into()),
    };
    let rpc = tron_event_to_rpc(&event);
    assert_eq!(rpc.event_type, "hook.triggered");
    let data = rpc.data.unwrap();
    assert_eq!(data["hookEvent"], "PreToolUse");
    assert_eq!(data["toolName"], "bash");
}

#[test]
fn thinking_events_map_correctly() {
    let start = TronEvent::ThinkingStart {
        base: BaseEvent::now("s1"),
    };
    assert_eq!(tron_event_to_rpc(&start).event_type, "agent.thinking_start");

    let delta = TronEvent::ThinkingDelta {
        base: BaseEvent::now("s1"),
        delta: "hmm".into(),
    };
    let rpc = tron_event_to_rpc(&delta);
    assert_eq!(rpc.event_type, "agent.thinking_delta");
    assert_eq!(rpc.data.unwrap()["delta"], "hmm");

    let end = TronEvent::ThinkingEnd {
        base: BaseEvent::now("s1"),
        thinking: "full thought".into(),
    };
    let rpc = tron_event_to_rpc(&end);
    assert_eq!(rpc.event_type, "agent.thinking_end");
    assert_eq!(rpc.data.unwrap()["thinking"], "full thought");
}

#[test]
fn event_bridge_maps_session_created() {
    let event = TronEvent::SessionCreated {
        base: BaseEvent::now("s1"),
        model: "claude-opus-4-6".into(),
        working_directory: "/tmp".into(),
        source: None,
    };
    let rpc = tron_event_to_rpc(&event);
    assert_eq!(rpc.event_type, "session.created");
    let data = rpc.data.unwrap();
    assert_eq!(data["model"], "claude-opus-4-6");
}

#[test]
fn event_bridge_maps_session_archived() {
    let event = TronEvent::SessionArchived {
        base: BaseEvent::now("s1"),
    };
    let rpc = tron_event_to_rpc(&event);
    assert_eq!(rpc.event_type, "session.archived");
}

#[test]
fn event_bridge_maps_session_forked() {
    let event = TronEvent::SessionForked {
        base: BaseEvent::now("s1"),
        new_session_id: "s2".into(),
    };
    let rpc = tron_event_to_rpc(&event);
    assert_eq!(rpc.event_type, "session.forked");
    let data = rpc.data.unwrap();
    assert_eq!(data["newSessionId"], "s2");
}

#[test]
fn all_event_types_have_wire_mapping() {
    // Ensure every TronEvent variant maps to a wire type with "." separator
    let base = BaseEvent::now("s1");
    let events: Vec<TronEvent> = vec![
        TronEvent::AgentStart { base: base.clone() },
        TronEvent::AgentEnd {
            base: base.clone(),
            error: None,
        },
        TronEvent::AgentReady { base: base.clone() },
        TronEvent::AgentInterrupted {
            base: base.clone(),
            turn: 1,
            partial_content: None,
            active_tool: None,
        },
        TronEvent::TurnStart {
            base: base.clone(),
            turn: 1,
        },
        TronEvent::TurnEnd {
            base: base.clone(),
            turn: 1,
            duration: 0,
            token_usage: None,
            token_record: None,
            cost: None,
            stop_reason: None,
            context_limit: None,
            model: None,
        },
        TronEvent::TurnFailed {
            base: base.clone(),
            turn: 1,
            error: "e".into(),
            code: None,
            category: None,
            recoverable: false,
            partial_content: None,
        },
        TronEvent::ResponseComplete {
            base: base.clone(),
            turn: 1,
            stop_reason: "end_turn".into(),
            token_usage: None,
            has_tool_calls: false,
            tool_call_count: 0,
            token_record: None,
            model: None,
        },
        TronEvent::MessageUpdate {
            base: base.clone(),
            content: "c".into(),
        },
        TronEvent::ToolExecutionStart {
            base: base.clone(),
            tool_call_id: "id".into(),
            tool_name: "n".into(),
            arguments: None,
        },
        TronEvent::ToolExecutionEnd {
            base: base.clone(),
            tool_call_id: "id".into(),
            tool_name: "n".into(),
            duration: 0,
            is_error: None,
            result: None,
        },
        TronEvent::Error {
            base: base.clone(),
            error: "e".into(),
            context: None,
            code: None,
            provider: None,
            category: None,
            suggestion: None,
            retryable: None,
            status_code: None,
            error_type: None,
            model: None,
        },
        TronEvent::CompactionStart {
            base: base.clone(),
            reason: tron_core::events::CompactionReason::Manual,
            tokens_before: 0,
        },
        TronEvent::CompactionComplete {
            base: base.clone(),
            success: true,
            tokens_before: 0,
            tokens_after: 0,
            compression_ratio: 0.0,
            reason: None,
            summary: None,
            estimated_context_tokens: None,
        },
        TronEvent::ThinkingStart { base: base.clone() },
        TronEvent::ThinkingDelta {
            base: base.clone(),
            delta: "d".into(),
        },
        TronEvent::ThinkingEnd {
            base: base.clone(),
            thinking: "t".into(),
        },
        TronEvent::SessionCreated {
            base: base.clone(),
            model: "m".into(),
            working_directory: "/".into(),
            source: None,
        },
        TronEvent::SessionArchived { base: base.clone() },
        TronEvent::SessionUnarchived { base: base.clone() },
        TronEvent::SessionForked {
            base: base.clone(),
            new_session_id: "s2".into(),
        },
        TronEvent::SessionDeleted { base: base.clone() },
        TronEvent::SessionUpdated {
            base: base.clone(),
            title: None,
            model: "m".into(),
            message_count: 0,
            input_tokens: 0,
            output_tokens: 0,
            last_turn_input_tokens: 0,
            cache_read_tokens: 0,
            cache_creation_tokens: 0,
            cost: 0.0,
            last_activity: "t".into(),
            is_active: true,
            last_user_prompt: None,
            last_assistant_response: None,
            parent_session_id: None,
        },
        TronEvent::MemoryUpdating { base: base.clone() },
        TronEvent::MemoryUpdated {
            base: base.clone(),
            title: None,
            entry_type: None,
            event_id: None,
        },
        TronEvent::ContextCleared {
            base: base.clone(),
            tokens_before: 0,
            tokens_after: 0,
        },
        TronEvent::MessageDeleted {
            base: base.clone(),
            target_event_id: "id".into(),
            target_type: "t".into(),
            target_turn: None,
            reason: None,
        },
        TronEvent::RulesLoaded {
            base: base.clone(),
            total_files: 3,
            dynamic_rules_count: 1,
        },
        TronEvent::RulesActivated {
            base: base.clone(),
            rules: vec![tron_core::events::ActivatedRuleInfo {
                relative_path: "src/.claude/CLAUDE.md".into(),
                scope_dir: "src".into(),
            }],
            total_activated: 1,
        },
        TronEvent::MemoryLoaded {
            base: base.clone(),
            count: 2,
        },
        TronEvent::SkillRemoved {
            base: base.clone(),
            skill_name: "n".into(),
        },
        TronEvent::SubagentSpawned {
            base: base.clone(),
            subagent_session_id: "sub-1".into(),
            task: "t".into(),
            model: "m".into(),
            max_turns: 5,
            spawn_depth: 0,
            tool_call_id: None,
            blocking: true,
            working_directory: None,
        },
        TronEvent::SubagentStatusUpdate {
            base: base.clone(),
            subagent_session_id: "sub-1".into(),
            status: "running".into(),
            current_turn: 1,
            activity: None,
        },
        TronEvent::SubagentCompleted {
            base: base.clone(),
            subagent_session_id: "sub-1".into(),
            total_turns: 3,
            duration: 5000,
            full_output: None,
            result_summary: None,
            token_usage: None,
            model: None,
        },
        TronEvent::SubagentFailed {
            base: base.clone(),
            subagent_session_id: "sub-1".into(),
            error: "e".into(),
            duration: 1000,
        },
        TronEvent::SubagentEvent {
            base: base.clone(),
            subagent_session_id: "sub-1".into(),
            event: serde_json::json!({"type": "text_delta"}),
        },
        TronEvent::SubagentResultAvailable {
            base,
            parent_session_id: "p1".into(),
            subagent_session_id: "sub-1".into(),
            task: "t".into(),
            result_summary: "done".into(),
            success: true,
            total_turns: 2,
            duration: 3000,
            token_usage: None,
            error: None,
            completed_at: "2024-01-01T00:00:00Z".into(),
        },
    ];
    for event in &events {
        let rpc = tron_event_to_rpc(event);
        assert!(
            rpc.event_type.contains('.'),
            "Event type '{}' should have '.' separator (from internal '{}')",
            rpc.event_type,
            event.event_type()
        );
    }
}

#[test]
fn session_updated_wire_type_and_data() {
    let event = TronEvent::SessionUpdated {
        base: BaseEvent::now("s1"),
        title: Some("Test Session".into()),
        model: "claude-opus-4-6".into(),
        message_count: 5,
        input_tokens: 100,
        output_tokens: 50,
        last_turn_input_tokens: 20,
        cache_read_tokens: 10,
        cache_creation_tokens: 5,
        cost: 0.01,
        last_activity: "2024-01-01T00:00:00Z".into(),
        is_active: true,
        last_user_prompt: Some("hello".into()),
        last_assistant_response: Some("world".into()),
        parent_session_id: None,
    };
    let rpc = tron_event_to_rpc(&event);
    assert_eq!(rpc.event_type, "session.updated");
    let data = rpc.data.unwrap();
    assert_eq!(data["title"], "Test Session");
    assert_eq!(data["model"], "claude-opus-4-6");
    assert_eq!(data["messageCount"], 5);
    assert_eq!(data["inputTokens"], 100);
    assert_eq!(data["outputTokens"], 50);
    assert_eq!(data["lastTurnInputTokens"], 20);
    assert_eq!(data["cacheReadTokens"], 10);
    assert_eq!(data["cacheCreationTokens"], 5);
    assert_eq!(data["cost"], 0.01);
    assert_eq!(data["isActive"], true);
    assert_eq!(data["lastUserPrompt"], "hello");
    assert_eq!(data["lastAssistantResponse"], "world");
}

#[test]
fn memory_updating_wire_type() {
    let event = TronEvent::MemoryUpdating {
        base: BaseEvent::now("s1"),
    };
    let rpc = tron_event_to_rpc(&event);
    assert_eq!(rpc.event_type, "agent.memory_updating");
    assert_eq!(rpc.data, Some(serde_json::json!({})));
}

#[test]
fn memory_updated_wire_type_and_data() {
    let event = TronEvent::MemoryUpdated {
        base: BaseEvent::now("s1"),
        title: Some("My Entry".into()),
        entry_type: Some("feature".into()),
        event_id: Some("evt_abc123".into()),
    };
    let rpc = tron_event_to_rpc(&event);
    assert_eq!(rpc.event_type, "agent.memory_updated");
    let data = rpc.data.unwrap();
    assert_eq!(data["title"], "My Entry");
    assert_eq!(data["entryType"], "feature");
    assert_eq!(data["eventId"], "evt_abc123");
}

#[test]
fn context_cleared_wire_type_and_data() {
    let event = TronEvent::ContextCleared {
        base: BaseEvent::now("s1"),
        tokens_before: 5000,
        tokens_after: 0,
    };
    let rpc = tron_event_to_rpc(&event);
    assert_eq!(rpc.event_type, "agent.context_cleared");
    let data = rpc.data.unwrap();
    assert_eq!(data["tokensBefore"], 5000);
    assert_eq!(data["tokensAfter"], 0);
}

#[test]
fn message_deleted_wire_type_and_data() {
    let event = TronEvent::MessageDeleted {
        base: BaseEvent::now("s1"),
        target_event_id: "evt-123".into(),
        target_type: "message.user".into(),
        target_turn: Some(3),
        reason: Some("user request".into()),
    };
    let rpc = tron_event_to_rpc(&event);
    assert_eq!(rpc.event_type, "agent.message_deleted");
    let data = rpc.data.unwrap();
    assert_eq!(data["targetEventId"], "evt-123");
    assert_eq!(data["targetType"], "message.user");
    assert_eq!(data["targetTurn"], 3);
    assert_eq!(data["reason"], "user request");
}

#[test]
fn skill_removed_wire_type_and_data() {
    let event = TronEvent::SkillRemoved {
        base: BaseEvent::now("s1"),
        skill_name: "web-search".into(),
    };
    let rpc = tron_event_to_rpc(&event);
    assert_eq!(rpc.event_type, "agent.skill_removed");
    let data = rpc.data.unwrap();
    assert_eq!(data["skillName"], "web-search");
}

#[test]
fn rules_loaded_wire_format() {
    let event = TronEvent::RulesLoaded {
        base: BaseEvent::now("s1"),
        total_files: 5,
        dynamic_rules_count: 2,
    };
    let rpc = tron_event_to_rpc(&event);
    assert_eq!(rpc.event_type, "rules.loaded");
    let data = rpc.data.unwrap();
    assert_eq!(data["totalFiles"], 5);
    assert_eq!(data["dynamicRulesCount"], 2);
}

#[test]
fn memory_loaded_wire_format() {
    let event = TronEvent::MemoryLoaded {
        base: BaseEvent::now("s1"),
        count: 3,
    };
    let rpc = tron_event_to_rpc(&event);
    assert_eq!(rpc.event_type, "memory.loaded");
    assert_eq!(rpc.data.unwrap()["count"], 3);
}

#[test]
fn tool_generating_wire_type() {
    let event = TronEvent::ToolCallGenerating {
        base: BaseEvent::now("s1"),
        tool_call_id: "tc_1".into(),
        tool_name: "bash".into(),
    };
    let rpc = tron_event_to_rpc(&event);
    assert_eq!(rpc.event_type, "agent.tool_generating");
}

#[test]
fn tool_output_wire_type_and_data() {
    let event = TronEvent::ToolExecutionUpdate {
        base: BaseEvent::now("s1"),
        tool_call_id: "tc_1".into(),
        update: "running...".into(),
    };
    let rpc = tron_event_to_rpc(&event);
    assert_eq!(rpc.event_type, "agent.tool_output");
    let data = rpc.data.unwrap();
    assert_eq!(data["toolCallId"], "tc_1");
    assert_eq!(data["output"], "running...");
    // Verify no legacy "update" field
    assert!(data.get("update").is_none());
}

// ── Compaction event chain verification ──

#[test]
fn compaction_start_wire_format_and_data() {
    let event = TronEvent::CompactionStart {
        base: BaseEvent::now("s1"),
        reason: tron_core::events::CompactionReason::ThresholdExceeded,
        tokens_before: 95_000,
    };
    let rpc = tron_event_to_rpc(&event);
    assert_eq!(rpc.event_type, "agent.compaction_started");
    assert_eq!(rpc.session_id.as_deref(), Some("s1"));
    let data = rpc.data.unwrap();
    assert_eq!(data["tokensBefore"], 95_000);
    assert!(data.get("reason").is_some());
}

#[test]
fn compaction_complete_wire_format_and_data() {
    let event = TronEvent::CompactionComplete {
        base: BaseEvent::now("s1"),
        success: true,
        tokens_before: 95_000,
        tokens_after: 30_000,
        compression_ratio: 0.316,
        reason: Some(tron_core::events::CompactionReason::ThresholdExceeded),
        summary: Some("Compacted 3 turns into summary".into()),
        estimated_context_tokens: Some(32_000),
    };
    let rpc = tron_event_to_rpc(&event);
    assert_eq!(rpc.event_type, "agent.compaction");
    assert_eq!(rpc.session_id.as_deref(), Some("s1"));
    let data = rpc.data.unwrap();
    assert_eq!(data["success"], true);
    assert_eq!(data["tokensBefore"], 95_000);
    assert_eq!(data["tokensAfter"], 30_000);
    assert_eq!(data["compressionRatio"], 0.316);
    assert_eq!(data["summary"], "Compacted 3 turns into summary");
    assert_eq!(data["estimatedContextTokens"], 32_000);
    assert!(data.get("reason").is_some());
}

#[test]
fn compaction_complete_minimal_fields() {
    let event = TronEvent::CompactionComplete {
        base: BaseEvent::now("s1"),
        success: false,
        tokens_before: 50_000,
        tokens_after: 50_000,
        compression_ratio: 1.0,
        reason: None,
        summary: None,
        estimated_context_tokens: None,
    };
    let rpc = tron_event_to_rpc(&event);
    assert_eq!(rpc.event_type, "agent.compaction");
    let data = rpc.data.unwrap();
    assert_eq!(data["success"], false);
    assert_eq!(data["tokensBefore"], 50_000);
    assert_eq!(data["tokensAfter"], 50_000);
    assert_eq!(data["compressionRatio"], 1.0);
    // Optional fields should be absent
    assert!(data.get("summary").is_none());
    assert!(data.get("estimatedContextTokens").is_none());
    assert!(data.get("reason").is_none());
}

#[tokio::test]
async fn compaction_events_route_through_bridge() {
    let (tx, _) = broadcast::channel(16);
    let bm = Arc::new(BroadcastManager::new());

    let (conn_tx, mut conn_rx) = tokio::sync::mpsc::unbounded_channel();
    let conn = super::super::connection::ClientConnection::new("c1".into(), conn_tx);
    conn.bind_session("s1");
    bm.add(Arc::new(conn)).await;

    let rx = tx.subscribe();
    let bridge = EventBridge::new(
        rx,
        bm.clone(),
        None,
        CancellationToken::new(),
        Arc::new(TurnAccumulatorMap::new()),
    );
    let handle = tokio::spawn(bridge.run());

    // Send CompactionStart
    let _ = tx
        .send(TronEvent::CompactionStart {
            base: BaseEvent::now("s1"),
            reason: tron_core::events::CompactionReason::ThresholdExceeded,
            tokens_before: 80_000,
        })
        .unwrap();

    tokio::time::sleep(std::time::Duration::from_millis(50)).await;

    let msg = conn_rx.try_recv().unwrap();
    let parsed: serde_json::Value = serde_json::from_str(&msg).unwrap();
    assert_eq!(parsed["type"], "agent.compaction_started");
    assert_eq!(parsed["data"]["tokensBefore"], 80_000);

    // Send CompactionComplete
    let _ = tx
        .send(TronEvent::CompactionComplete {
            base: BaseEvent::now("s1"),
            success: true,
            tokens_before: 80_000,
            tokens_after: 25_000,
            compression_ratio: 0.3125,
            reason: None,
            summary: Some("Summary text".into()),
            estimated_context_tokens: None,
        })
        .unwrap();

    tokio::time::sleep(std::time::Duration::from_millis(50)).await;

    let msg = conn_rx.try_recv().unwrap();
    let parsed: serde_json::Value = serde_json::from_str(&msg).unwrap();
    assert_eq!(parsed["type"], "agent.compaction");
    assert_eq!(parsed["data"]["success"], true);
    assert_eq!(parsed["data"]["tokensAfter"], 25_000);
    assert_eq!(parsed["data"]["summary"], "Summary text");

    drop(tx);
    let _ = handle.await;
}

// ── Subagent event wire format tests ──

#[test]
fn converts_subagent_spawned_with_new_fields() {
    let event = TronEvent::SubagentSpawned {
        base: BaseEvent::now("s1"),
        subagent_session_id: "sub-1".into(),
        task: "count files".into(),
        model: "claude-sonnet-4-5-20250929".into(),
        max_turns: 50,
        spawn_depth: 0,
        tool_call_id: Some("tc_42".into()),
        blocking: false,
        working_directory: Some("/tmp/project".into()),
    };
    let rpc = tron_event_to_rpc(&event);
    assert_eq!(rpc.event_type, "agent.subagent_spawned");
    let data = rpc.data.unwrap();
    assert_eq!(data["toolCallId"], "tc_42");
    assert_eq!(data["blocking"], false);
    assert_eq!(data["workingDirectory"], "/tmp/project");
    assert_eq!(data["subagentSessionId"], "sub-1");
}

#[test]
fn converts_subagent_completed_with_new_fields() {
    let event = TronEvent::SubagentCompleted {
        base: BaseEvent::now("s1"),
        subagent_session_id: "sub-1".into(),
        total_turns: 3,
        duration: 5000,
        full_output: Some("Full result text".into()),
        result_summary: Some("Full resu...".into()),
        token_usage: Some(serde_json::json!({"input": 100})),
        model: Some("claude-sonnet-4-5-20250929".into()),
    };
    let rpc = tron_event_to_rpc(&event);
    assert_eq!(rpc.event_type, "agent.subagent_completed");
    let data = rpc.data.unwrap();
    assert_eq!(data["duration"], 5000);
    assert_eq!(data["fullOutput"], "Full result text");
    assert_eq!(data["resultSummary"], "Full resu...");
    assert_eq!(data["model"], "claude-sonnet-4-5-20250929");
    assert_eq!(data["totalTurns"], 3);
    // Verify durationMs is NOT present (renamed to duration)
    assert!(data.get("durationMs").is_none());
}

#[test]
fn converts_subagent_failed_uses_duration() {
    let event = TronEvent::SubagentFailed {
        base: BaseEvent::now("s1"),
        subagent_session_id: "sub-1".into(),
        error: "provider error".into(),
        duration: 1500,
    };
    let rpc = tron_event_to_rpc(&event);
    assert_eq!(rpc.event_type, "agent.subagent_failed");
    let data = rpc.data.unwrap();
    assert_eq!(data["duration"], 1500);
    assert!(data.get("durationMs").is_none());
}

#[test]
fn converts_subagent_event() {
    let inner = serde_json::json!({
        "type": "text_delta",
        "data": { "delta": "hello" },
        "timestamp": "2024-01-01T00:00:00Z",
    });
    let event = TronEvent::SubagentEvent {
        base: BaseEvent::now("s1"),
        subagent_session_id: "sub-1".into(),
        event: inner.clone(),
    };
    let rpc = tron_event_to_rpc(&event);
    assert_eq!(rpc.event_type, "agent.subagent_event");
    let data = rpc.data.unwrap();
    assert_eq!(data["subagentSessionId"], "sub-1");
    assert_eq!(data["event"], inner);
}

#[test]
fn converts_subagent_result_available() {
    let event = TronEvent::SubagentResultAvailable {
        base: BaseEvent::now("s1"),
        parent_session_id: "parent-1".into(),
        subagent_session_id: "sub-1".into(),
        task: "count files".into(),
        result_summary: "Found 42 files".into(),
        success: true,
        total_turns: 2,
        duration: 3000,
        token_usage: Some(serde_json::json!({"input": 50})),
        error: None,
        completed_at: "2024-01-01T00:00:00Z".into(),
    };
    let rpc = tron_event_to_rpc(&event);
    assert_eq!(rpc.event_type, "agent.subagent_result_available");
    let data = rpc.data.unwrap();
    assert_eq!(data["parentSessionId"], "parent-1");
    assert_eq!(data["subagentSessionId"], "sub-1");
    assert_eq!(data["task"], "count files");
    assert_eq!(data["resultSummary"], "Found 42 files");
    assert_eq!(data["success"], true);
    assert_eq!(data["totalTurns"], 2);
    assert_eq!(data["duration"], 3000);
    assert_eq!(data["completedAt"], "2024-01-01T00:00:00Z");
    assert_eq!(data["tokenUsage"]["input"], 50);
    assert!(data.get("error").is_none());
}

// ── Turn accumulator integration tests ──

#[tokio::test]
async fn bridge_feeds_events_to_accumulator() {
    let map = Arc::new(TurnAccumulatorMap::new());
    let (tx, _) = broadcast::channel(16);
    let bm = Arc::new(BroadcastManager::new());
    let rx = tx.subscribe();
    let bridge = EventBridge::new(rx, bm.clone(), None, CancellationToken::new(), map.clone());
    let handle = tokio::spawn(bridge.run());

    let _ = tx.send(TronEvent::TurnStart {
        base: BaseEvent::now("s1"),
        turn: 1,
    });
    let _ = tx.send(TronEvent::MessageUpdate {
        base: BaseEvent::now("s1"),
        content: "hello".into(),
    });
    tokio::time::sleep(std::time::Duration::from_millis(50)).await;

    let state = map.get_state("s1");
    assert!(state.is_some());
    let (text, _, _) = state.unwrap();
    assert_eq!(text, "hello");

    drop(tx);
    let _ = handle.await;
}

#[tokio::test]
async fn bridge_accumulator_clears_on_agent_end() {
    let map = Arc::new(TurnAccumulatorMap::new());
    let (tx, _) = broadcast::channel(16);
    let bm = Arc::new(BroadcastManager::new());
    let rx = tx.subscribe();
    let bridge = EventBridge::new(rx, bm.clone(), None, CancellationToken::new(), map.clone());
    let handle = tokio::spawn(bridge.run());

    let _ = tx.send(TronEvent::TurnStart {
        base: BaseEvent::now("s1"),
        turn: 1,
    });
    let _ = tx.send(TronEvent::MessageUpdate {
        base: BaseEvent::now("s1"),
        content: "hello".into(),
    });
    let _ = tx.send(TronEvent::AgentEnd {
        base: BaseEvent::now("s1"),
        error: None,
    });
    tokio::time::sleep(std::time::Duration::from_millis(50)).await;

    assert!(map.get_state("s1").is_none());

    drop(tx);
    let _ = handle.await;
}

#[test]
fn converts_worktree_acquired() {
    let event = TronEvent::WorktreeAcquired {
        base: BaseEvent::now("s1"),
        path: "/repo/.worktrees/session/abc".into(),
        branch: "session/abc".into(),
        base_commit: "deadbeef".into(),
        base_branch: Some("main".into()),
    };
    let rpc = tron_event_to_rpc(&event);
    assert_eq!(rpc.event_type, "worktree.acquired");
    let data = rpc.data.unwrap();
    assert_eq!(data["path"], "/repo/.worktrees/session/abc");
    assert_eq!(data["branch"], "session/abc");
    assert_eq!(data["baseCommit"], "deadbeef");
    assert_eq!(data["baseBranch"], "main");
}

#[test]
fn converts_worktree_commit() {
    let event = TronEvent::WorktreeCommit {
        base: BaseEvent::now("s1"),
        commit_hash: "cafebabe".into(),
        message: "wip".into(),
        files_changed: vec!["file.txt".into(), "other.rs".into()],
        insertions: 10,
        deletions: 2,
    };
    let rpc = tron_event_to_rpc(&event);
    assert_eq!(rpc.event_type, "worktree.commit");
    let data = rpc.data.unwrap();
    assert_eq!(data["commitHash"], "cafebabe");
    assert_eq!(data["message"], "wip");
    assert_eq!(data["filesChanged"].as_array().unwrap().len(), 2);
    assert_eq!(data["insertions"], 10);
    assert_eq!(data["deletions"], 2);
}

#[test]
fn converts_worktree_merged() {
    let event = TronEvent::WorktreeMerged {
        base: BaseEvent::now("s1"),
        source_branch: "session/abc".into(),
        target_branch: "main".into(),
        merge_commit: Some("12345678".into()),
        strategy: "merge".into(),
    };
    let rpc = tron_event_to_rpc(&event);
    assert_eq!(rpc.event_type, "worktree.merged");
    let data = rpc.data.unwrap();
    assert_eq!(data["sourceBranch"], "session/abc");
    assert_eq!(data["targetBranch"], "main");
    assert_eq!(data["mergeCommit"], "12345678");
    assert_eq!(data["strategy"], "merge");
}

#[test]
fn converts_worktree_released() {
    let event = TronEvent::WorktreeReleased {
        base: BaseEvent::now("s1"),
        final_commit: Some("cafebabe".into()),
        branch_preserved: true,
        deleted: true,
    };
    let rpc = tron_event_to_rpc(&event);
    assert_eq!(rpc.event_type, "worktree.released");
    let data = rpc.data.unwrap();
    assert_eq!(data["finalCommit"], "cafebabe");
    assert_eq!(data["branchPreserved"], true);
    assert_eq!(data["deleted"], true);
}
