use super::*;
use crate::server::rpc::handlers::test_helpers::make_test_context;
use serde_json::json;

#[tokio::test]
async fn create_session_success() {
    let ctx = make_test_context();
    let result = CreateSessionHandler
        .handle(Some(json!({"workingDirectory": "/tmp"})), &ctx)
        .await
        .unwrap();
    assert!(result["sessionId"].is_string());
}

#[tokio::test]
async fn create_session_missing_working_dir() {
    let ctx = make_test_context();
    let err = CreateSessionHandler
        .handle(Some(json!({})), &ctx)
        .await
        .unwrap_err();
    assert_eq!(err.code(), "INVALID_PARAMS");
}

#[tokio::test]
async fn create_session_with_model_and_title() {
    let ctx = make_test_context();
    let result = CreateSessionHandler
        .handle(
            Some(json!({
                "workingDirectory": "/tmp",
                "model": "claude-opus-4-20250514",
                "title": "my session"
            })),
            &ctx,
        )
        .await
        .unwrap();
    assert!(result["sessionId"].is_string());
}

#[tokio::test]
async fn resume_session_success() {
    let ctx = make_test_context();
    let sid = ctx
        .session_manager
        .create_session("model", "/tmp", Some("test"), None)
        .unwrap();

    let result = ResumeSessionHandler
        .handle(Some(json!({"sessionId": sid})), &ctx)
        .await
        .unwrap();
    assert_eq!(result["model"], "model");
}

#[tokio::test]
async fn resume_session_not_found() {
    let ctx = make_test_context();
    let err = ResumeSessionHandler
        .handle(Some(json!({"sessionId": "nonexistent"})), &ctx)
        .await
        .unwrap_err();
    assert_eq!(err.code(), "SESSION_NOT_FOUND");
}

#[tokio::test]
async fn list_sessions_empty() {
    let ctx = make_test_context();
    let result = ListSessionsHandler.handle(None, &ctx).await.unwrap();
    assert!(result["sessions"].as_array().unwrap().is_empty());
}

#[tokio::test]
async fn list_sessions_populated() {
    let ctx = make_test_context();
    let _ = ctx
        .session_manager
        .create_session("m", "/a", Some("s1"), None)
        .unwrap();
    let _ = ctx
        .session_manager
        .create_session("m", "/b", Some("s2"), None)
        .unwrap();

    let result = ListSessionsHandler.handle(None, &ctx).await.unwrap();
    assert_eq!(result["sessions"].as_array().unwrap().len(), 2);
}

#[tokio::test]
async fn list_sessions_has_cache_tokens() {
    let ctx = make_test_context();
    let _ = ctx
        .session_manager
        .create_session("m", "/a", Some("s1"), None)
        .unwrap();

    let result = ListSessionsHandler.handle(None, &ctx).await.unwrap();
    let session = &result["sessions"][0];
    assert!(session.get("cacheReadTokens").is_some());
    assert!(session.get("cacheCreationTokens").is_some());
    assert!(session["cacheReadTokens"].is_number());
    assert!(session["cacheCreationTokens"].is_number());
}

#[tokio::test]
async fn list_sessions_has_last_turn_input_tokens() {
    let ctx = make_test_context();
    let _ = ctx
        .session_manager
        .create_session("m", "/a", Some("s1"), None)
        .unwrap();

    let result = ListSessionsHandler.handle(None, &ctx).await.unwrap();
    let session = &result["sessions"][0];
    assert!(session.get("lastTurnInputTokens").is_some());
    assert!(session["lastTurnInputTokens"].is_number());
}

#[tokio::test]
async fn list_sessions_has_message_previews() {
    let ctx = make_test_context();
    let sid = ctx
        .session_manager
        .create_session("m", "/a", Some("s1"), None)
        .unwrap();

    // Add a user message
    let _ = ctx
        .event_store
        .append(&crate::events::AppendOptions {
            session_id: &sid,
            event_type: crate::events::EventType::MessageUser,
            payload: json!({"text": "hello user"}),
            parent_id: None,
            sequence: None,
        })
        .unwrap();

    let result = ListSessionsHandler.handle(None, &ctx).await.unwrap();
    let session = &result["sessions"][0];
    assert!(session.get("lastUserPrompt").is_some());
    assert!(session.get("lastAssistantResponse").is_some());
}

#[tokio::test]
async fn list_sessions_empty_previews() {
    let ctx = make_test_context();
    let _ = ctx
        .session_manager
        .create_session("m", "/a", Some("s1"), None)
        .unwrap();

    let result = ListSessionsHandler.handle(None, &ctx).await.unwrap();
    let session = &result["sessions"][0];
    // No messages → null previews
    assert!(session["lastUserPrompt"].is_null());
    assert!(session["lastAssistantResponse"].is_null());
}

#[tokio::test]
async fn list_sessions_cost_field() {
    use crate::events::sqlite::repositories::session::{IncrementCounters, SessionRepo};

    let ctx = make_test_context();
    let sid = ctx
        .session_manager
        .create_session("m", "/a", Some("s1"), None)
        .unwrap();

    // Simulate accumulated cost from turns
    let conn = ctx.event_store.pool().get().unwrap();
    let _ = SessionRepo::increment_counters(
        &conn,
        &sid,
        &IncrementCounters {
            cost: Some(0.42),
            ..Default::default()
        },
    )
    .unwrap();
    drop(conn);

    let result = ListSessionsHandler.handle(None, &ctx).await.unwrap();
    let session = &result["sessions"][0];
    assert!((session["cost"].as_f64().unwrap() - 0.42).abs() < f64::EPSILON);
}

#[tokio::test]
async fn delete_session_success() {
    let ctx = make_test_context();
    let sid = ctx
        .session_manager
        .create_session("m", "/tmp", Some("t"), None)
        .unwrap();

    let result = DeleteSessionHandler
        .handle(Some(json!({"sessionId": sid})), &ctx)
        .await
        .unwrap();
    assert_eq!(result["deleted"], true);
}

#[tokio::test]
async fn delete_session_missing_param() {
    let ctx = make_test_context();
    let err = DeleteSessionHandler
        .handle(Some(json!({})), &ctx)
        .await
        .unwrap_err();
    assert_eq!(err.code(), "INVALID_PARAMS");
}

#[tokio::test]
async fn fork_returns_new_session_id() {
    let ctx = make_test_context();
    let sid = ctx
        .session_manager
        .create_session("m", "/tmp", Some("t"), None)
        .unwrap();

    let result = ForkSessionHandler
        .handle(Some(json!({"sessionId": sid})), &ctx)
        .await
        .unwrap();
    assert!(result["newSessionId"].is_string());
    let fork_id = result["newSessionId"].as_str().unwrap();
    assert_ne!(fork_id, sid);
}

#[tokio::test]
async fn fork_returns_forked_from_session_id() {
    let ctx = make_test_context();
    let sid = ctx
        .session_manager
        .create_session("m", "/tmp", Some("t"), None)
        .unwrap();

    let result = ForkSessionHandler
        .handle(Some(json!({"sessionId": sid})), &ctx)
        .await
        .unwrap();
    assert_eq!(result["forkedFromSessionId"].as_str().unwrap(), sid);
}

#[tokio::test]
async fn fork_returns_event_ids() {
    let ctx = make_test_context();
    let sid = ctx
        .session_manager
        .create_session("m", "/tmp", Some("t"), None)
        .unwrap();

    let result = ForkSessionHandler
        .handle(Some(json!({"sessionId": sid})), &ctx)
        .await
        .unwrap();
    // forkedFromEventId and rootEventId should be real strings, not null
    assert!(
        result["forkedFromEventId"].is_string(),
        "forkedFromEventId should be a string, got: {}",
        result["forkedFromEventId"]
    );
    assert!(
        result["rootEventId"].is_string(),
        "rootEventId should be a string, got: {}",
        result["rootEventId"]
    );
    assert!(!result["forkedFromEventId"].as_str().unwrap().is_empty());
    assert!(!result["rootEventId"].as_str().unwrap().is_empty());
}

#[tokio::test]
async fn fork_from_specific_event() {
    let ctx = make_test_context();
    let sid = ctx
        .session_manager
        .create_session("m", "/tmp", Some("t"), None)
        .unwrap();

    // Append two events so we can fork from the first one (not HEAD)
    let first = ctx
        .event_store
        .append(&crate::events::AppendOptions {
            session_id: &sid,
            event_type: crate::events::EventType::MessageUser,
            payload: json!({"text": "first"}),
            parent_id: None,
            sequence: None,
        })
        .unwrap();
    let _ = ctx
        .event_store
        .append(&crate::events::AppendOptions {
            session_id: &sid,
            event_type: crate::events::EventType::MessageAssistant,
            payload: json!({"text": "second"}),
            parent_id: None,
            sequence: None,
        })
        .unwrap();

    let result = ForkSessionHandler
        .handle(
            Some(json!({"sessionId": sid, "fromEventId": first.id})),
            &ctx,
        )
        .await
        .unwrap();

    assert_eq!(
        result["forkedFromEventId"].as_str().unwrap(),
        first.id,
        "should fork from the specified event, not HEAD"
    );
}

#[tokio::test]
async fn fork_without_from_event_id_forks_from_head() {
    let ctx = make_test_context();
    let sid = ctx
        .session_manager
        .create_session("m", "/tmp", Some("t"), None)
        .unwrap();

    // Get the HEAD event ID
    let session = ctx.event_store.get_session(&sid).unwrap().unwrap();
    let head_event_id = session.head_event_id.unwrap();

    let result = ForkSessionHandler
        .handle(Some(json!({"sessionId": sid})), &ctx)
        .await
        .unwrap();
    assert_eq!(
        result["forkedFromEventId"].as_str().unwrap(),
        head_event_id,
        "fork without fromEventId should fork from HEAD"
    );
}

#[tokio::test]
async fn get_head_success() {
    let ctx = make_test_context();
    let sid = ctx
        .session_manager
        .create_session("m", "/tmp", Some("t"), None)
        .unwrap();

    let result = GetHeadHandler
        .handle(Some(json!({"sessionId": sid})), &ctx)
        .await
        .unwrap();
    assert_eq!(result["sessionId"].as_str().unwrap(), sid);
}

#[tokio::test]
async fn get_head_not_found() {
    let ctx = make_test_context();
    let err = GetHeadHandler
        .handle(Some(json!({"sessionId": "nope"})), &ctx)
        .await
        .unwrap_err();
    assert_eq!(err.code(), "SESSION_NOT_FOUND");
}

#[tokio::test]
async fn get_state_success() {
    let ctx = make_test_context();
    let sid = ctx
        .session_manager
        .create_session("my-model", "/tmp", Some("t"), None)
        .unwrap();

    let result = GetStateHandler
        .handle(Some(json!({"sessionId": sid})), &ctx)
        .await
        .unwrap();
    assert_eq!(result["model"], "my-model");
    assert_eq!(result["turnCount"], 0);
}

#[tokio::test]
async fn get_state_has_workspace_id() {
    let ctx = make_test_context();
    let sid = ctx
        .session_manager
        .create_session("m", "/tmp/workspace", Some("t"), None)
        .unwrap();

    let result = GetStateHandler
        .handle(Some(json!({"sessionId": sid})), &ctx)
        .await
        .unwrap();
    assert_eq!(result["workspaceId"], "/tmp/workspace");
}

#[tokio::test]
async fn get_state_has_cache_read_tokens() {
    let ctx = make_test_context();
    let sid = ctx
        .session_manager
        .create_session("m", "/tmp", Some("t"), None)
        .unwrap();

    let result = GetStateHandler
        .handle(Some(json!({"sessionId": sid})), &ctx)
        .await
        .unwrap();
    assert!(result["tokenUsage"]["cacheReadTokens"].is_number());
}

#[tokio::test]
async fn get_state_has_cache_creation_tokens() {
    let ctx = make_test_context();
    let sid = ctx
        .session_manager
        .create_session("m", "/tmp", Some("t"), None)
        .unwrap();

    let result = GetStateHandler
        .handle(Some(json!({"sessionId": sid})), &ctx)
        .await
        .unwrap();
    assert!(result["tokenUsage"]["cacheCreationTokens"].is_number());
}

#[tokio::test]
async fn get_state_token_usage_complete() {
    let ctx = make_test_context();
    let sid = ctx
        .session_manager
        .create_session("m", "/tmp", Some("t"), None)
        .unwrap();

    let result = GetStateHandler
        .handle(Some(json!({"sessionId": sid})), &ctx)
        .await
        .unwrap();
    let tu = &result["tokenUsage"];
    assert!(tu["inputTokens"].is_number());
    assert!(tu["outputTokens"].is_number());
    assert!(tu["cacheReadTokens"].is_number());
    assert!(tu["cacheCreationTokens"].is_number());
}

#[tokio::test]
async fn get_state_not_found() {
    let ctx = make_test_context();
    let err = GetStateHandler
        .handle(Some(json!({"sessionId": "missing"})), &ctx)
        .await
        .unwrap_err();
    assert_eq!(err.code(), "SESSION_NOT_FOUND");
}

// ── Session lifecycle events ──

#[tokio::test]
async fn create_session_emits_event() {
    let ctx = make_test_context();
    let mut rx = ctx.orchestrator.subscribe();

    let _ = CreateSessionHandler
        .handle(Some(json!({"workingDirectory": "/tmp"})), &ctx)
        .await
        .unwrap();

    let event = rx.try_recv().unwrap();
    assert_eq!(event.event_type(), "session_created");
}

#[tokio::test]
async fn archive_session_emits_event() {
    let ctx = make_test_context();
    let sid = ctx
        .session_manager
        .create_session("m", "/tmp", Some("t"), None)
        .unwrap();

    let mut rx = ctx.orchestrator.subscribe();

    let _ = ArchiveSessionHandler
        .handle(Some(json!({"sessionId": sid})), &ctx)
        .await
        .unwrap();

    let event = rx.try_recv().unwrap();
    assert_eq!(event.event_type(), "session_archived");
}

#[tokio::test]
async fn unarchive_session_emits_event() {
    let ctx = make_test_context();
    let sid = ctx
        .session_manager
        .create_session("m", "/tmp", Some("t"), None)
        .unwrap();
    ctx.session_manager.archive_session(&sid).unwrap();

    let mut rx = ctx.orchestrator.subscribe();

    let _ = UnarchiveSessionHandler
        .handle(Some(json!({"sessionId": sid})), &ctx)
        .await
        .unwrap();

    let event = rx.try_recv().unwrap();
    assert_eq!(event.event_type(), "session_unarchived");
}

#[tokio::test]
async fn fork_session_emits_event() {
    let ctx = make_test_context();
    let sid = ctx
        .session_manager
        .create_session("m", "/tmp", Some("t"), None)
        .unwrap();

    let mut rx = ctx.orchestrator.subscribe();

    let result = ForkSessionHandler
        .handle(Some(json!({"sessionId": sid})), &ctx)
        .await
        .unwrap();

    let event = rx.try_recv().unwrap();
    assert_eq!(event.event_type(), "session_forked");
    // Verify forked event has newSessionId
    let new_id = result["newSessionId"].as_str().unwrap();
    assert!(!new_id.is_empty());
}

#[tokio::test]
async fn delete_session_emits_event() {
    let ctx = make_test_context();
    let sid = ctx
        .session_manager
        .create_session("m", "/tmp", Some("t"), None)
        .unwrap();

    let mut rx = ctx.orchestrator.subscribe();

    let _ = DeleteSessionHandler
        .handle(Some(json!({"sessionId": sid})), &ctx)
        .await
        .unwrap();

    let event = rx.try_recv().unwrap();
    assert_eq!(event.event_type(), "session_deleted");
}

// ── session.getHistory tests ──

#[tokio::test]
async fn get_history_empty_session() {
    let ctx = make_test_context();
    let sid = ctx
        .session_manager
        .create_session("m", "/tmp", Some("t"), None)
        .unwrap();

    let result = GetHistoryHandler
        .handle(Some(json!({"sessionId": sid})), &ctx)
        .await
        .unwrap();
    assert!(result["messages"].as_array().unwrap().is_empty());
    assert_eq!(result["hasMore"], false);
}

#[tokio::test]
async fn get_history_with_messages() {
    let ctx = make_test_context();
    let sid = ctx
        .session_manager
        .create_session("m", "/tmp", Some("t"), None)
        .unwrap();

    let _ = ctx
        .event_store
        .append(&crate::events::AppendOptions {
            session_id: &sid,
            event_type: crate::events::EventType::MessageUser,
            payload: json!({"text": "hello"}),
            parent_id: None,
            sequence: None,
        })
        .unwrap();
    let _ = ctx
        .event_store
        .append(&crate::events::AppendOptions {
            session_id: &sid,
            event_type: crate::events::EventType::MessageAssistant,
            payload: json!({"text": "world"}),
            parent_id: None,
            sequence: None,
        })
        .unwrap();

    let result = GetHistoryHandler
        .handle(Some(json!({"sessionId": sid})), &ctx)
        .await
        .unwrap();
    let messages = result["messages"].as_array().unwrap();
    assert_eq!(messages.len(), 2);
}

#[tokio::test]
async fn get_history_returns_has_more() {
    let ctx = make_test_context();
    let sid = ctx
        .session_manager
        .create_session("m", "/tmp", Some("t"), None)
        .unwrap();

    for _ in 0..5 {
        let _ = ctx
            .event_store
            .append(&crate::events::AppendOptions {
                session_id: &sid,
                event_type: crate::events::EventType::MessageUser,
                payload: json!({"text": "msg"}),
                parent_id: None,
                sequence: None,
            })
            .unwrap();
    }

    let result = GetHistoryHandler
        .handle(Some(json!({"sessionId": sid, "limit": 3})), &ctx)
        .await
        .unwrap();
    let messages = result["messages"].as_array().unwrap();
    assert_eq!(messages.len(), 3);
    assert_eq!(result["hasMore"], true);
}

#[tokio::test]
async fn get_history_before_id_pagination() {
    let ctx = make_test_context();
    let sid = ctx
        .session_manager
        .create_session("m", "/tmp", Some("t"), None)
        .unwrap();

    let e1 = ctx
        .event_store
        .append(&crate::events::AppendOptions {
            session_id: &sid,
            event_type: crate::events::EventType::MessageUser,
            payload: json!({"text": "first"}),
            parent_id: None,
            sequence: None,
        })
        .unwrap();
    let _ = ctx
        .event_store
        .append(&crate::events::AppendOptions {
            session_id: &sid,
            event_type: crate::events::EventType::MessageUser,
            payload: json!({"text": "second"}),
            parent_id: None,
            sequence: None,
        })
        .unwrap();

    // Get history before the second message
    let result = GetHistoryHandler
        .handle(Some(json!({"sessionId": sid, "beforeId": e1.id})), &ctx)
        .await
        .unwrap();
    let messages = result["messages"].as_array().unwrap();
    // beforeId cuts off at (but not including) e1
    assert!(messages.is_empty());
}

#[tokio::test]
async fn get_history_missing_session() {
    let ctx = make_test_context();
    let err = GetHistoryHandler
        .handle(Some(json!({"sessionId": "nope"})), &ctx)
        .await
        .unwrap_err();
    assert_eq!(err.code(), "SESSION_NOT_FOUND");
}

#[tokio::test]
async fn get_history_message_shape() {
    let ctx = make_test_context();
    let sid = ctx
        .session_manager
        .create_session("m", "/tmp", Some("t"), None)
        .unwrap();

    let _ = ctx
        .event_store
        .append(&crate::events::AppendOptions {
            session_id: &sid,
            event_type: crate::events::EventType::MessageUser,
            payload: json!({"text": "hello"}),
            parent_id: None,
            sequence: None,
        })
        .unwrap();

    let result = GetHistoryHandler
        .handle(Some(json!({"sessionId": sid})), &ctx)
        .await
        .unwrap();
    let msg = &result["messages"][0];
    assert!(msg["id"].is_string());
    assert_eq!(msg["role"], "user");
    assert!(msg["content"].is_object());
    assert!(msg["timestamp"].is_string());
}

#[tokio::test]
async fn get_history_tool_result_has_tool_call_id_at_top() {
    let ctx = make_test_context();
    let sid = ctx
        .session_manager
        .create_session("m", "/tmp", Some("t"), None)
        .unwrap();

    let _ = ctx
        .event_store
        .append(&crate::events::AppendOptions {
            session_id: &sid,
            event_type: crate::events::EventType::ToolResult,
            payload: json!({"toolCallId": "tc1", "content": "result data", "isError": false}),
            parent_id: None,
            sequence: None,
        })
        .unwrap();

    let result = GetHistoryHandler
        .handle(Some(json!({"sessionId": sid})), &ctx)
        .await
        .unwrap();
    let msg = &result["messages"][0];
    assert_eq!(
        msg["toolCallId"], "tc1",
        "toolCallId should be hoisted to message level"
    );
}

#[tokio::test]
async fn get_history_tool_result_content_preserved() {
    let ctx = make_test_context();
    let sid = ctx
        .session_manager
        .create_session("m", "/tmp", Some("t"), None)
        .unwrap();

    let _ = ctx
        .event_store
        .append(&crate::events::AppendOptions {
            session_id: &sid,
            event_type: crate::events::EventType::ToolResult,
            payload: json!({"toolCallId": "tc1", "content": "file contents", "isError": false}),
            parent_id: None,
            sequence: None,
        })
        .unwrap();

    let result = GetHistoryHandler
        .handle(Some(json!({"sessionId": sid})), &ctx)
        .await
        .unwrap();
    let msg = &result["messages"][0];
    assert_eq!(msg["content"]["content"], "file contents");
}

#[tokio::test]
async fn get_history_tool_result_has_is_error() {
    let ctx = make_test_context();
    let sid = ctx
        .session_manager
        .create_session("m", "/tmp", Some("t"), None)
        .unwrap();

    let _ = ctx
        .event_store
        .append(&crate::events::AppendOptions {
            session_id: &sid,
            event_type: crate::events::EventType::ToolResult,
            payload: json!({"toolCallId": "tc1", "content": "error msg", "isError": true}),
            parent_id: None,
            sequence: None,
        })
        .unwrap();

    let result = GetHistoryHandler
        .handle(Some(json!({"sessionId": sid})), &ctx)
        .await
        .unwrap();
    let msg = &result["messages"][0];
    assert_eq!(
        msg["isError"], true,
        "isError should be hoisted to message level"
    );
}

#[tokio::test]
async fn get_history_assistant_latency_preserved() {
    let ctx = make_test_context();
    let sid = ctx
        .session_manager
        .create_session("m", "/tmp", Some("t"), None)
        .unwrap();

    let _ = ctx
        .event_store
        .append(&crate::events::AppendOptions {
            session_id: &sid,
            event_type: crate::events::EventType::MessageAssistant,
            payload: json!({
                "content": [{"type": "text", "text": "hello"}],
                "latency": 1234
            }),
            parent_id: None,
            sequence: None,
        })
        .unwrap();

    let result = GetHistoryHandler
        .handle(Some(json!({"sessionId": sid})), &ctx)
        .await
        .unwrap();
    let msg = &result["messages"][0];
    assert_eq!(
        msg["content"]["latency"], 1234,
        "latency should be preserved in content"
    );
}

#[tokio::test]
async fn get_history_includes_tool_results() {
    let ctx = make_test_context();
    let sid = ctx
        .session_manager
        .create_session("m", "/tmp", Some("t"), None)
        .unwrap();

    // User message
    let _ = ctx
        .event_store
        .append(&crate::events::AppendOptions {
            session_id: &sid,
            event_type: crate::events::EventType::MessageUser,
            payload: json!({"content": "read a file"}),
            parent_id: None,
            sequence: None,
        })
        .unwrap();

    // Assistant message with tool_use block
    let _ = ctx.event_store.append(&crate::events::AppendOptions {
        session_id: &sid,
        event_type: crate::events::EventType::MessageAssistant,
        payload: json!({"content": [{"type": "tool_use", "id": "tc1", "name": "Read", "arguments": {"path": "/tmp/test"}}]}),
        parent_id: None,
        sequence: None,
    }).unwrap();

    // Tool result (persisted as tool.result)
    let _ = ctx.event_store.append(&crate::events::AppendOptions {
        session_id: &sid,
        event_type: crate::events::EventType::ToolResult,
        payload: json!({"toolCallId": "tc1", "content": "file contents here", "isError": false}),
        parent_id: None,
        sequence: None,
    }).unwrap();

    let result = GetHistoryHandler
        .handle(Some(json!({"sessionId": sid})), &ctx)
        .await
        .unwrap();
    let messages = result["messages"].as_array().unwrap();
    assert_eq!(
        messages.len(),
        3,
        "should include user, assistant, and tool result"
    );
    assert_eq!(messages[0]["role"], "user");
    assert_eq!(messages[1]["role"], "assistant");
    assert_eq!(messages[2]["role"], "tool");
    assert_eq!(messages[2]["content"]["toolCallId"], "tc1");
    assert_eq!(messages[2]["content"]["content"], "file contents here");
}

// ── Optimistic context event tests ──

async fn wait_for_event_count(
    ctx: &RpcContext,
    session_id: &str,
    event_types: &[&str],
    expected: usize,
) -> Vec<crate::events::sqlite::row_types::EventRow> {
    tokio::time::timeout(std::time::Duration::from_secs(2), async {
        loop {
            let events = ctx
                .event_store
                .get_events_by_type(session_id, event_types, Some(10))
                .unwrap();
            if events.len() >= expected {
                break events;
            }
            tokio::time::sleep(std::time::Duration::from_millis(25)).await;
        }
    })
    .await
    .expect("timed out waiting for optimistic context events")
}

#[tokio::test]
async fn create_session_emits_rules_loaded_when_rules_exist() {
    // Set up a temp dir with a CLAUDE.md file
    let tmp =
        std::env::temp_dir().join(format!("tron-session-test-rules-{}", uuid::Uuid::new_v4()));
    std::fs::create_dir_all(tmp.join(".claude")).unwrap();
    std::fs::write(tmp.join(".claude").join("CLAUDE.md"), "# Rules").unwrap();

    let ctx = make_test_context();
    let mut rx = ctx.orchestrator.subscribe();

    let result = CreateSessionHandler
        .handle(
            Some(json!({"workingDirectory": tmp.to_string_lossy()})),
            &ctx,
        )
        .await
        .unwrap();

    let sid = result["sessionId"].as_str().unwrap();

    // Check persisted rules.loaded event
    let rules_events = wait_for_event_count(&ctx, sid, &["rules.loaded"], 1).await;
    assert_eq!(
        rules_events.len(),
        1,
        "rules.loaded should be persisted once"
    );

    // Check broadcast events: session_created then rules_loaded
    let e1 = rx.try_recv().unwrap();
    assert_eq!(e1.event_type(), "session_created");
    let e2 = tokio::time::timeout(std::time::Duration::from_secs(2), async {
        loop {
            match rx.try_recv() {
                Ok(event) => break event,
                Err(tokio::sync::broadcast::error::TryRecvError::Empty) => {
                    tokio::time::sleep(std::time::Duration::from_millis(25)).await;
                }
                Err(err) => panic!("unexpected broadcast error: {err}"),
            }
        }
    })
    .await
    .expect("timed out waiting for rules_loaded broadcast");
    assert_eq!(e2.event_type(), "rules_loaded");

    let _ = std::fs::remove_dir_all(&tmp);
}

#[tokio::test]
async fn create_session_no_rules_event_when_no_rules() {
    let tmp = std::env::temp_dir().join(format!(
        "tron-session-test-norules-{}",
        uuid::Uuid::new_v4()
    ));
    std::fs::create_dir_all(&tmp).unwrap();

    let ctx = make_test_context();

    let result = CreateSessionHandler
        .handle(
            Some(json!({"workingDirectory": tmp.to_string_lossy()})),
            &ctx,
        )
        .await
        .unwrap();

    let sid = result["sessionId"].as_str().unwrap();

    let rules_events = ctx
        .event_store
        .get_events_by_type(sid, &["rules.loaded"], Some(10))
        .unwrap();
    assert!(
        rules_events.is_empty(),
        "no rules.loaded event when no rules files exist"
    );

    let _ = std::fs::remove_dir_all(&tmp);
}

#[tokio::test]
async fn create_session_rules_loaded_has_correct_total_files() {
    let tmp =
        std::env::temp_dir().join(format!("tron-session-test-rcount-{}", uuid::Uuid::new_v4()));
    std::fs::create_dir_all(tmp.join(".claude")).unwrap();
    std::fs::write(tmp.join(".claude").join("CLAUDE.md"), "# Rules").unwrap();

    let ctx = make_test_context();

    let result = CreateSessionHandler
        .handle(
            Some(json!({"workingDirectory": tmp.to_string_lossy()})),
            &ctx,
        )
        .await
        .unwrap();

    let sid = result["sessionId"].as_str().unwrap();
    let rules_events = wait_for_event_count(&ctx, sid, &["rules.loaded"], 1).await;
    let payload: serde_json::Value = serde_json::from_str(&rules_events[0].payload).unwrap();
    // At least 1 file (the project rules); may also have global rules
    assert!(
        payload["totalFiles"].as_u64().unwrap() >= 1,
        "totalFiles should be >= 1, got: {}",
        payload["totalFiles"]
    );

    let _ = std::fs::remove_dir_all(&tmp);
}

// ── session.reconstruct tests ──

#[tokio::test]
async fn reconstruct_empty_session() {
    let ctx = make_test_context();
    let sid = ctx
        .session_manager
        .create_session("m", "/tmp", Some("t"), None)
        .unwrap();

    let result = ReconstructHandler
        .handle(Some(json!({"sessionId": sid})), &ctx)
        .await
        .unwrap();

    // Empty session has the session.start event
    let events = result["events"].as_array().unwrap();
    assert!(events.len() <= 1); // session.start or empty
    assert_eq!(result["isRunning"], false);
    assert_eq!(result["agentPhase"], "idle");
    assert!(result["inFlight"].is_null());
    assert_eq!(result["hasMoreEvents"], false);
}

#[tokio::test]
async fn reconstruct_session_with_history() {
    let ctx = make_test_context();
    let sid = ctx
        .session_manager
        .create_session("m", "/tmp", Some("t"), None)
        .unwrap();

    // Add some events
    for i in 0..5 {
        let _ = ctx
            .event_store
            .append(&crate::events::AppendOptions {
                session_id: &sid,
                event_type: crate::events::EventType::MessageUser,
                payload: json!({"text": format!("msg {i}")}),
                parent_id: None,
                sequence: None,
            })
            .unwrap();
    }

    let result = ReconstructHandler
        .handle(Some(json!({"sessionId": sid})), &ctx)
        .await
        .unwrap();

    let events = result["events"].as_array().unwrap();
    // session.start + 5 messages
    assert!(events.len() >= 5);
    assert_eq!(result["isRunning"], false);
    assert!(result["inFlight"].is_null());
}

#[tokio::test]
async fn reconstruct_with_limit() {
    let ctx = make_test_context();
    let sid = ctx
        .session_manager
        .create_session("m", "/tmp", Some("t"), None)
        .unwrap();

    // Add 20 events
    for i in 0..20 {
        let _ = ctx
            .event_store
            .append(&crate::events::AppendOptions {
                session_id: &sid,
                event_type: crate::events::EventType::MessageUser,
                payload: json!({"text": format!("msg {i}")}),
                parent_id: None,
                sequence: None,
            })
            .unwrap();
    }

    let result = ReconstructHandler
        .handle(Some(json!({"sessionId": sid, "limit": 5})), &ctx)
        .await
        .unwrap();

    let events = result["events"].as_array().unwrap();
    assert_eq!(events.len(), 5);
    assert_eq!(result["hasMoreEvents"], true);
}

#[tokio::test]
async fn reconstruct_with_before_sequence() {
    let ctx = make_test_context();
    let sid = ctx
        .session_manager
        .create_session("m", "/tmp", Some("t"), None)
        .unwrap();

    // Add 10 events (session.start is seq 0, so these are seq 1-10)
    for i in 0..10 {
        let _ = ctx
            .event_store
            .append(&crate::events::AppendOptions {
                session_id: &sid,
                event_type: crate::events::EventType::MessageUser,
                payload: json!({"text": format!("msg {i}")}),
                parent_id: None,
                sequence: None,
            })
            .unwrap();
    }

    // Get events before sequence 5
    let result = ReconstructHandler
        .handle(
            Some(json!({"sessionId": sid, "beforeSequence": 5})),
            &ctx,
        )
        .await
        .unwrap();

    let events = result["events"].as_array().unwrap();
    // All events should have sequence < 5
    for ev in events {
        assert!(ev["sequence"].as_i64().unwrap() < 5);
    }
}

#[tokio::test]
async fn reconstruct_pagination_combined() {
    let ctx = make_test_context();
    let sid = ctx
        .session_manager
        .create_session("m", "/tmp", Some("t"), None)
        .unwrap();

    // Add 20 events
    for i in 0..20 {
        let _ = ctx
            .event_store
            .append(&crate::events::AppendOptions {
                session_id: &sid,
                event_type: crate::events::EventType::MessageUser,
                payload: json!({"text": format!("msg {i}")}),
                parent_id: None,
                sequence: None,
            })
            .unwrap();
    }

    // Get last 3 events before sequence 10
    let result = ReconstructHandler
        .handle(
            Some(json!({"sessionId": sid, "beforeSequence": 10, "limit": 3})),
            &ctx,
        )
        .await
        .unwrap();

    let events = result["events"].as_array().unwrap();
    assert_eq!(events.len(), 3);
    for ev in events {
        assert!(ev["sequence"].as_i64().unwrap() < 10);
    }
    // Should still have more events before these
    assert_eq!(result["hasMoreEvents"], true);
}

#[tokio::test]
async fn reconstruct_oldest_sequence_correct() {
    let ctx = make_test_context();
    let sid = ctx
        .session_manager
        .create_session("m", "/tmp", Some("t"), None)
        .unwrap();

    for i in 0..5 {
        let _ = ctx
            .event_store
            .append(&crate::events::AppendOptions {
                session_id: &sid,
                event_type: crate::events::EventType::MessageUser,
                payload: json!({"text": format!("msg {i}")}),
                parent_id: None,
                sequence: None,
            })
            .unwrap();
    }

    let result = ReconstructHandler
        .handle(Some(json!({"sessionId": sid})), &ctx)
        .await
        .unwrap();

    let events = result["events"].as_array().unwrap();
    let oldest = result["oldestSequence"].as_i64().unwrap();
    assert_eq!(oldest, events[0]["sequence"].as_i64().unwrap());
}

#[tokio::test]
async fn reconstruct_idle_no_inflight() {
    let ctx = make_test_context();
    let sid = ctx
        .session_manager
        .create_session("m", "/tmp", Some("t"), None)
        .unwrap();

    let result = ReconstructHandler
        .handle(Some(json!({"sessionId": sid})), &ctx)
        .await
        .unwrap();

    assert_eq!(result["isRunning"], false);
    assert!(result["inFlight"].is_null());
}

#[tokio::test]
async fn reconstruct_nonexistent_session() {
    let ctx = make_test_context();
    let err = ReconstructHandler
        .handle(
            Some(json!({"sessionId": "nonexistent-session-xyz"})),
            &ctx,
        )
        .await
        .unwrap_err();
    assert_eq!(err.code(), "SESSION_NOT_FOUND");
}

#[tokio::test]
async fn reconstruct_events_wire_format() {
    let ctx = make_test_context();
    let sid = ctx
        .session_manager
        .create_session("m", "/tmp", Some("t"), None)
        .unwrap();

    let _ = ctx
        .event_store
        .append(&crate::events::AppendOptions {
            session_id: &sid,
            event_type: crate::events::EventType::MessageUser,
            payload: json!({"text": "hello"}),
            parent_id: None,
            sequence: None,
        })
        .unwrap();

    let result = ReconstructHandler
        .handle(Some(json!({"sessionId": sid})), &ctx)
        .await
        .unwrap();

    let events = result["events"].as_array().unwrap();
    // Check wire format has required fields (camelCase)
    let last_event = events.last().unwrap();
    assert!(last_event.get("id").is_some());
    assert!(last_event.get("type").is_some());
    assert!(last_event.get("sessionId").is_some());
    assert!(last_event.get("timestamp").is_some());
    assert!(last_event.get("sequence").is_some());
}

#[tokio::test]
async fn reconstruct_metadata_correct() {
    let ctx = make_test_context();
    let sid = ctx
        .session_manager
        .create_session("claude-test-model", "/tmp/test", Some("Test Session"), None)
        .unwrap();

    let result = ReconstructHandler
        .handle(Some(json!({"sessionId": sid})), &ctx)
        .await
        .unwrap();

    let metadata = &result["metadata"];
    assert_eq!(metadata["model"], "claude-test-model");
    assert_eq!(metadata["workingDirectory"], "/tmp/test");
    assert!(metadata.get("tokenUsage").is_some());
}

#[tokio::test]
async fn reconstruct_last_sequence_matches_events() {
    let ctx = make_test_context();
    let sid = ctx
        .session_manager
        .create_session("m", "/tmp", Some("t"), None)
        .unwrap();

    for i in 0..3 {
        let _ = ctx
            .event_store
            .append(&crate::events::AppendOptions {
                session_id: &sid,
                event_type: crate::events::EventType::MessageUser,
                payload: json!({"text": format!("msg {i}")}),
                parent_id: None,
                sequence: None,
            })
            .unwrap();
    }

    let result = ReconstructHandler
        .handle(Some(json!({"sessionId": sid})), &ctx)
        .await
        .unwrap();

    let events = result["events"].as_array().unwrap();
    let last_seq = result["lastSequence"].as_i64().unwrap();
    let max_event_seq = events.last().unwrap()["sequence"].as_i64().unwrap();
    // lastSequence should be >= the max event sequence
    assert!(last_seq >= max_event_seq);
}

#[tokio::test]
async fn reconstruct_running_agent_has_inflight() {
    let ctx = make_test_context();
    let sid = ctx
        .session_manager
        .create_session("m", "/tmp", Some("t"), None)
        .unwrap();

    // Simulate a running agent: begin_run + populate accumulator
    let _run = ctx.orchestrator.begin_run(&sid, "run_1").unwrap();
    ctx.orchestrator
        .turn_accumulators()
        .handle_turn_start(&sid);
    ctx.orchestrator
        .turn_accumulators()
        .handle_text_delta(&sid, "partial response");

    let result = ReconstructHandler
        .handle(Some(json!({"sessionId": sid})), &ctx)
        .await
        .unwrap();

    assert_eq!(result["isRunning"], true);
    assert!(!result["inFlight"].is_null());
    assert!(result["inFlight"]["contentSequence"].is_array());
    assert!(result["inFlight"]["streaming"].is_object());
    assert_eq!(result["inFlight"]["streaming"]["type"], "text");
    assert_eq!(
        result["inFlight"]["streaming"]["content"],
        "partial response"
    );
}

#[tokio::test]
async fn reconstruct_running_agent_tool_status() {
    let ctx = make_test_context();
    let sid = ctx
        .session_manager
        .create_session("m", "/tmp", Some("t"), None)
        .unwrap();

    let _run = ctx.orchestrator.begin_run(&sid, "run_1").unwrap();
    let acc = ctx.orchestrator.turn_accumulators();
    acc.handle_turn_start(&sid);
    acc.handle_text_delta(&sid, "I'll run two tools");
    acc.handle_tool_generating(&sid, "tc_1", "bash");
    acc.handle_tool_start(&sid, "tc_1", None);
    acc.handle_tool_end(&sid, "tc_1", Some("output"), false);
    acc.handle_tool_generating(&sid, "tc_2", "read");
    acc.handle_tool_start(&sid, "tc_2", None);

    let result = ReconstructHandler
        .handle(Some(json!({"sessionId": sid})), &ctx)
        .await
        .unwrap();

    let in_flight = &result["inFlight"];
    assert!(!in_flight.is_null());
    let tools = in_flight["toolCalls"].as_array().unwrap();
    assert_eq!(tools.len(), 2);
    assert_eq!(tools[0]["status"], "completed");
    assert_eq!(tools[0]["toolName"], "bash");
    assert_eq!(tools[1]["status"], "running");
    assert_eq!(tools[1]["toolName"], "read");
}

#[tokio::test]
async fn reconstruct_running_agent_streaming_thinking() {
    let ctx = make_test_context();
    let sid = ctx
        .session_manager
        .create_session("m", "/tmp", Some("t"), None)
        .unwrap();

    let _run = ctx.orchestrator.begin_run(&sid, "run_1").unwrap();
    let acc = ctx.orchestrator.turn_accumulators();
    acc.handle_turn_start(&sid);
    acc.handle_thinking_delta(&sid, "Let me analyze this...");

    let result = ReconstructHandler
        .handle(Some(json!({"sessionId": sid})), &ctx)
        .await
        .unwrap();

    let in_flight = &result["inFlight"];
    assert!(!in_flight.is_null());
    let seq = in_flight["contentSequence"].as_array().unwrap();
    assert_eq!(seq.len(), 1);
    assert_eq!(seq[0]["type"], "thinking");
    assert_eq!(seq[0]["thinking"], "Let me analyze this...");
    // streaming should be null when only thinking (no text yet)
    assert!(in_flight["streaming"].is_null());
}

#[tokio::test]
async fn reconstruct_inflight_content_sequence_ordering() {
    let ctx = make_test_context();
    let sid = ctx
        .session_manager
        .create_session("m", "/tmp", Some("t"), None)
        .unwrap();

    let _run = ctx.orchestrator.begin_run(&sid, "run_1").unwrap();
    let acc = ctx.orchestrator.turn_accumulators();
    acc.handle_turn_start(&sid);
    acc.handle_thinking_delta(&sid, "thinking...");
    acc.handle_text_delta(&sid, "First I'll ");
    acc.handle_tool_generating(&sid, "tc_1", "bash");
    acc.handle_text_delta(&sid, "then more text");

    let result = ReconstructHandler
        .handle(Some(json!({"sessionId": sid})), &ctx)
        .await
        .unwrap();

    let seq = result["inFlight"]["contentSequence"].as_array().unwrap();
    assert_eq!(seq.len(), 4); // thinking, text, tool_ref, text
    assert_eq!(seq[0]["type"], "thinking");
    assert_eq!(seq[1]["type"], "text");
    assert_eq!(seq[2]["type"], "tool_ref");
    assert_eq!(seq[3]["type"], "text");
}

#[tokio::test]
async fn reconstruct_last_sequence_from_counter() {
    let ctx = make_test_context();
    let sid = ctx
        .session_manager
        .create_session("m", "/tmp", Some("t"), None)
        .unwrap();

    // Init counter higher than DB events (simulates non-persisted events)
    ctx.orchestrator.init_sequence_counter(&sid, 100);

    let result = ReconstructHandler
        .handle(Some(json!({"sessionId": sid})), &ctx)
        .await
        .unwrap();

    // lastSequence should come from counter, not from events
    assert_eq!(result["lastSequence"], 100);
}

// ── Phase 6 edge case tests ──

#[tokio::test]
async fn reconstruct_limit_zero_returns_no_events() {
    let ctx = make_test_context();
    let sid = ctx
        .session_manager
        .create_session("m", "/tmp", Some("t"), None)
        .unwrap();

    // Add some events
    for i in 0..5 {
        let _ = ctx
            .event_store
            .append(&crate::events::AppendOptions {
                session_id: &sid,
                event_type: crate::events::EventType::MessageUser,
                payload: json!({"text": format!("msg {i}")}),
                parent_id: None,
                sequence: None,
            })
            .unwrap();
    }

    let result = ReconstructHandler
        .handle(Some(json!({"sessionId": sid, "limit": 0})), &ctx)
        .await
        .unwrap();

    let events = result["events"].as_array().unwrap();
    assert_eq!(events.len(), 0);
    // isRunning and metadata should still be populated
    assert_eq!(result["isRunning"], false);
    assert!(result["metadata"].is_object());
}

#[tokio::test]
async fn reconstruct_before_sequence_zero_returns_empty() {
    let ctx = make_test_context();
    let sid = ctx
        .session_manager
        .create_session("m", "/tmp", Some("t"), None)
        .unwrap();

    for i in 0..5 {
        let _ = ctx
            .event_store
            .append(&crate::events::AppendOptions {
                session_id: &sid,
                event_type: crate::events::EventType::MessageUser,
                payload: json!({"text": format!("msg {i}")}),
                parent_id: None,
                sequence: None,
            })
            .unwrap();
    }

    let result = ReconstructHandler
        .handle(
            Some(json!({"sessionId": sid, "beforeSequence": 0})),
            &ctx,
        )
        .await
        .unwrap();

    let events = result["events"].as_array().unwrap();
    assert_eq!(events.len(), 0);
    assert_eq!(result["hasMoreEvents"], false);
}

#[tokio::test]
async fn list_sessions_has_is_running_field() {
    let ctx = make_test_context();
    let _ = ctx
        .session_manager
        .create_session("m", "/a", Some("s1"), None)
        .unwrap();

    let result = ListSessionsHandler.handle(None, &ctx).await.unwrap();
    let session = &result["sessions"][0];
    // No active run → isRunning should be false
    assert_eq!(session["isRunning"], false);
}
