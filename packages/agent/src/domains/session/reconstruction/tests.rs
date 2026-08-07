//! Provider-audit manifest, projection, redaction, and digest tests.

use super::*;
use crate::domains::session::event_store::{AppendOptions, EventType};
use crate::domains::session::lifecycle::SessionLifecycleService;
use crate::shared::protocol::events::{BaseEvent, TronEvent};
use crate::shared::server::test_support::make_test_context;

// ── reconcile_in_flight tests ──

#[test]
fn strips_text_thinking_when_tools_executing() {
    let result = SessionReconstructionService::reconcile_in_flight(
        "I'll run sleep 10.".into(),
        json!([{
            "invocationId": "tc_1",
            "toolName": "test_tool",
            "status": "running",
            "startedAt": "2026-04-07T12:00:00Z",
            "streamingOutput": "running...",
        }]),
        json!([
            { "type": "thinking", "thinking": "The user wants sleep 10." },
            { "type": "text", "text": "I'll run sleep 10." },
            { "type": "tool_ref", "invocationId": "tc_1" },
        ]),
    );

    // Text/thinking stripped — already in persisted message.assistant
    let seq = result["contentSequence"].as_array().unwrap();
    assert_eq!(seq.len(), 1);
    assert_eq!(seq[0]["type"], "tool_ref");
    assert_eq!(seq[0]["invocationId"], "tc_1");

    // Streaming cleared
    assert!(result["streaming"].is_null());

    // Tool invocations preserved with full detail
    let tools = result["toolInvocations"].as_array().unwrap();
    assert_eq!(tools.len(), 1);
    assert_eq!(tools[0]["status"], "running");
    assert_eq!(tools[0]["startedAt"], "2026-04-07T12:00:00Z");
    assert_eq!(tools[0]["streamingOutput"], "running...");
}

#[test]
fn keeps_text_thinking_when_still_generating() {
    let result = SessionReconstructionService::reconcile_in_flight(
        "Let me think...".into(),
        json!([{
            "invocationId": "tc_1",
            "toolName": "test_tool",
            "status": "generating",
        }]),
        json!([
            { "type": "thinking", "thinking": "Planning..." },
            { "type": "text", "text": "Let me think..." },
            { "type": "tool_ref", "invocationId": "tc_1" },
        ]),
    );

    // Everything kept — LLM still streaming, no persisted message.assistant yet
    let seq = result["contentSequence"].as_array().unwrap();
    assert_eq!(seq.len(), 3);
    assert_eq!(seq[0]["type"], "thinking");
    assert_eq!(seq[1]["type"], "text");
    assert_eq!(seq[2]["type"], "tool_ref");

    // Streaming active
    assert_eq!(result["streaming"]["type"], "text");
    assert_eq!(result["streaming"]["content"], "Let me think...");
}

#[test]
fn keeps_everything_when_no_tools() {
    let result = SessionReconstructionService::reconcile_in_flight(
        "Here is my response...".into(),
        json!([]),
        json!([
            { "type": "thinking", "thinking": "I'll explain." },
            { "type": "text", "text": "Here is my response..." },
        ]),
    );

    // Everything kept — text-only response still streaming
    let seq = result["contentSequence"].as_array().unwrap();
    assert_eq!(seq.len(), 2);
    assert_eq!(seq[0]["type"], "thinking");
    assert_eq!(seq[1]["type"], "text");

    // Streaming active
    assert_eq!(result["streaming"]["type"], "text");
}

#[test]
fn strips_when_mixed_tool_statuses() {
    // One tool running, one still generating — strip because at least one is executing
    let result = SessionReconstructionService::reconcile_in_flight(
        "Running tools...".into(),
        json!([
            { "invocationId": "tc_1", "toolName": "test_tool", "status": "running" },
            { "invocationId": "tc_2", "toolName": "inspect", "status": "generating" },
        ]),
        json!([
            { "type": "thinking", "thinking": "Let me run both." },
            { "type": "text", "text": "Running tools..." },
            { "type": "tool_ref", "invocationId": "tc_1" },
            { "type": "tool_ref", "invocationId": "tc_2" },
        ]),
    );

    let seq = result["contentSequence"].as_array().unwrap();
    assert_eq!(seq.len(), 2); // Only tool_refs
    assert_eq!(seq[0]["invocationId"], "tc_1");
    assert_eq!(seq[1]["invocationId"], "tc_2");
    assert!(result["streaming"].is_null());

    // Both tool invocations preserved
    assert_eq!(result["toolInvocations"].as_array().unwrap().len(), 2);
}

#[test]
fn strips_when_tool_completed() {
    let result = SessionReconstructionService::reconcile_in_flight(
        "Done.".into(),
        json!([{
            "invocationId": "tc_1",
            "toolName": "inspect",
            "status": "completed",
            "result": "file contents...",
            "completedAt": "2026-04-07T12:00:01Z",
        }]),
        json!([
            { "type": "text", "text": "Done." },
            { "type": "tool_ref", "invocationId": "tc_1" },
        ]),
    );

    let seq = result["contentSequence"].as_array().unwrap();
    assert_eq!(seq.len(), 1);
    assert_eq!(seq[0]["type"], "tool_ref");
    assert!(result["streaming"].is_null());
}

#[test]
fn strips_when_tool_errored() {
    let result = SessionReconstructionService::reconcile_in_flight(
        "Trying...".into(),
        json!([{
            "invocationId": "tc_1",
            "toolName": "test_tool",
            "status": "error",
            "isError": true,
            "result": "command not found",
        }]),
        json!([
            { "type": "text", "text": "Trying..." },
            { "type": "tool_ref", "invocationId": "tc_1" },
        ]),
    );

    let seq = result["contentSequence"].as_array().unwrap();
    assert_eq!(seq.len(), 1);
    assert_eq!(seq[0]["type"], "tool_ref");
}

#[test]
fn preserves_streaming_output_and_timestamps() {
    let result = SessionReconstructionService::reconcile_in_flight(
        "text".into(),
        json!([{
            "invocationId": "tc_1",
            "toolName": "test_tool",
            "status": "running",
            "arguments": { "command": "sleep 10" },
            "startedAt": "2026-04-07T12:00:00Z",
            "streamingOutput": "partial output line 1\nline 2\n",
            "isError": false,
        }]),
        json!([
            { "type": "tool_ref", "invocationId": "tc_1" },
        ]),
    );

    let tool = &result["toolInvocations"][0];
    assert_eq!(tool["startedAt"], "2026-04-07T12:00:00Z");
    assert_eq!(tool["streamingOutput"], "partial output line 1\nline 2\n");
    assert_eq!(tool["arguments"]["command"], "sleep 10");
    assert_eq!(tool["isError"], false);
}

#[test]
fn no_streaming_when_text_empty_and_no_tools() {
    let result = SessionReconstructionService::reconcile_in_flight(
        String::new(),
        json!([]),
        json!([
            { "type": "thinking", "thinking": "hmm" },
        ]),
    );

    assert_eq!(result["streaming"]["type"], "thinking");
    assert_eq!(result["streaming"]["content"], "hmm");
    assert_eq!(result["contentSequence"].as_array().unwrap().len(), 1);
}

#[test]
fn active_thinking_reports_thinking_streaming_type() {
    let result = SessionReconstructionService::reconcile_in_flight(
        String::new(),
        json!([]),
        json!([
            { "type": "thinking", "thinking": "Analyzing order..." },
        ]),
    );

    assert_eq!(result["streaming"]["type"], "thinking");
    assert_eq!(result["streaming"]["content"], "Analyzing order...");
}

#[test]
fn completed_provider_response_is_not_reconstructed_as_streaming() {
    let result = SessionReconstructionService::reconcile_turn_snapshot((
        "complete text".into(),
        json!([]),
        json!([{ "type": "text", "text": "complete text" }]),
        true,
    ));

    assert!(result["streaming"].is_null());
    assert!(result["contentSequence"].as_array().unwrap().is_empty());
}

#[test]
fn strips_multiple_text_and_thinking_blocks() {
    // Interleaved: thinking, text, tool, text, tool
    let result = SessionReconstructionService::reconcile_in_flight(
        "second text".into(),
        json!([
            { "invocationId": "tc_1", "toolName": "test_tool", "status": "running" },
            { "invocationId": "tc_2", "toolName": "inspect", "status": "running" },
        ]),
        json!([
            { "type": "thinking", "thinking": "plan A" },
            { "type": "text", "text": "first text" },
            { "type": "tool_ref", "invocationId": "tc_1" },
            { "type": "thinking", "thinking": "plan B" },
            { "type": "text", "text": "second text" },
            { "type": "tool_ref", "invocationId": "tc_2" },
        ]),
    );

    let seq = result["contentSequence"].as_array().unwrap();
    assert_eq!(seq.len(), 2);
    assert!(seq.iter().all(|item| item["type"] == "tool_ref"));
}

#[test]
fn run_or_turn_transition_invalidates_reconstruction_generation() {
    let active = |run_id: &str, generation: u64| {
        Some((
            run_id.to_owned(),
            Some(TurnReconstructionSnapshot {
                generation,
                sequence_consistent: true,
                last_sequence: Some(9),
                admission_committed: true,
                compaction_reason: None,
                state: None,
            }),
        ))
    };

    assert!(same_reconstruction_generation(
        &active("run-1", 3),
        &active("run-1", 3)
    ));
    assert!(!same_reconstruction_generation(
        &active("run-1", 3),
        &active("run-1", 4)
    ));
    assert!(!same_reconstruction_generation(
        &active("run-1", 3),
        &active("run-2", 3)
    ));
}

#[tokio::test]
async fn reconstruction_defers_provider_audits_and_embeds_latest_inventory() {
    let ctx = make_test_context();
    let session_id = ctx
        .session_manager
        .create_session("model", "/tmp", Some("bounded-audits"))
        .unwrap();

    for turn in 1..=12 {
        ctx.event_store
            .append(&AppendOptions {
                session_id: &session_id,
                event_type: EventType::ModelProviderRequest,
                payload: json!({
                    "format": "tron.model_provider_request.v4",
                    "turn": turn,
                    "providerType": "openai",
                    "providerName": "OpenAI",
                    "model": "model",
                    "requestClassification": "interactive",
                    "messageCount": turn,
                    "toolCount": 23,
                    "contextManifest": {
                        "systemContributions": [{"kind": "base"}],
                        "messages": [{"contentKinds": ["text"]}],
                        "automaticContext": [],
                        "agentDeliveries": [],
                        "environment": {"workingDirectory": "/tmp"},
                    },
                    "providerAdditions": [],
                    "padding": "x".repeat(20_000),
                }),
                parent_id: None,
                sequence: None,
            })
            .unwrap();
    }
    ctx.event_store
        .append(&AppendOptions {
            session_id: &session_id,
            event_type: EventType::MessageAssistant,
            payload: json!({
                "content": [{"type": "text", "text": "done"}],
                "turn": 12,
                "model": "model",
                "stopReason": "end_turn",
            }),
            parent_id: None,
            sequence: None,
        })
        .unwrap();

    let result = SessionReconstructionService::reconstruct(
        &Deps::from_test_context(&ctx),
        session_id,
        None,
        None,
    )
    .await
    .unwrap();

    let audits = result["events"]
        .as_array()
        .unwrap()
        .iter()
        .filter(|event| event["type"] == EventType::ModelProviderRequest.as_str())
        .collect::<Vec<_>>();
    assert_eq!(audits.len(), 12);
    assert!(audits.iter().all(|event| {
        event["payload"]["projection"] == "deferred"
            && event["payload"].get("padding").is_none()
            && event["payload"].get("contextManifest").is_none()
    }));
    assert_eq!(
        result["metadata"]["latestContextRequest"]["messageCount"],
        12
    );
    assert_eq!(result["metadata"]["latestContextRequest"]["toolCount"], 23);
    assert!(result.to_string().len() < 30_000);
}

#[tokio::test]
async fn raw_allocator_cannot_advance_reconstruction_watermark() {
    let ctx = make_test_context();
    let session_id = ctx
        .session_manager
        .create_session("model", "/tmp", Some("watermark"))
        .unwrap();
    let _run = ctx
        .orchestrator
        .begin_run(&session_id, "run-stable")
        .unwrap();

    let user = ctx
        .event_store
        .append(&AppendOptions {
            session_id: &session_id,
            event_type: EventType::MessageUser,
            payload: json!({ "content": "prompt", "turn": 1 }),
            parent_id: None,
            sequence: Some(1),
        })
        .unwrap();
    assert!(
        ctx.orchestrator
            .commit_run_admission(&session_id, "run-stable", user.sequence)
    );

    ctx.orchestrator
        .turn_accumulators()
        .update_from_event(&TronEvent::TurnStart {
            base: BaseEvent::now(&session_id).with_sequence(2),
            turn: 1,
            agent_delivery_continuation: None,
        });
    ctx.orchestrator
        .turn_accumulators()
        .update_from_event(&TronEvent::MessageUpdate {
            base: BaseEvent::now(&session_id).with_sequence(3),
            content: "covered text".into(),
        });

    ctx.event_store
        .append(&AppendOptions {
            session_id: &session_id,
            event_type: EventType::MessageAssistant,
            payload: json!({
                "content": [{ "type": "text", "text": "not represented yet" }],
                "turn": 1,
                "model": "model",
                "stopReason": "end_turn"
            }),
            parent_id: None,
            sequence: Some(4),
        })
        .unwrap();

    let _ = ctx
        .orchestrator
        .ensure_sequence_counter_at_least(&session_id, 3);
    assert_eq!(ctx.orchestrator.next_sequence(&session_id).unwrap(), 4);

    let result = SessionReconstructionService::reconstruct(
        &Deps::from_test_context(&ctx),
        session_id.clone(),
        None,
        None,
    )
    .await
    .unwrap();

    assert_eq!(result["lastSequence"], 3);
    assert_eq!(result["inFlight"]["streaming"]["content"], "covered text");
    assert!(
        result["events"]
            .as_array()
            .unwrap()
            .iter()
            .all(|event| event["sequence"].as_i64().unwrap() <= 3)
    );
}

#[tokio::test]
async fn reconstruction_waits_for_durable_user_message_admission() {
    let ctx = make_test_context();
    let session_id = ctx
        .session_manager
        .create_session("model", "/tmp", Some("pre-turn"))
        .unwrap();
    let _run = ctx
        .orchestrator
        .begin_run(&session_id, "run-pre-turn")
        .unwrap();
    let deps = Deps::from_test_context(&ctx);
    let mut reconstruction = Box::pin(SessionReconstructionService::reconstruct(
        &deps,
        session_id.clone(),
        None,
        None,
    ));
    tokio::select! {
        result = &mut reconstruction => panic!("reconstruction escaped pending admission: {result:?}"),
        () = tokio::time::sleep(std::time::Duration::from_millis(20)) => {}
    }

    let user = ctx
        .event_store
        .append(&AppendOptions {
            session_id: &session_id,
            event_type: EventType::MessageUser,
            payload: json!({ "content": "hello", "turn": 1 }),
            parent_id: None,
            sequence: Some(1),
        })
        .unwrap();
    assert!(
        ctx.orchestrator
            .commit_run_admission(&session_id, "run-pre-turn", user.sequence)
    );

    let result = reconstruction.await.unwrap();

    assert_eq!(result["lastSequence"], 1);
    assert_eq!(
        result["events"].as_array().unwrap().last().unwrap()["id"],
        user.id
    );
    assert!(result["inFlight"].is_null());
}

#[tokio::test]
async fn reconstruction_waiter_retries_when_pending_run_is_released() {
    let ctx = make_test_context();
    let session_id = ctx
        .session_manager
        .create_session("model", "/tmp", Some("released-admission"))
        .unwrap();
    let run = ctx
        .orchestrator
        .begin_run(&session_id, "run-released")
        .unwrap();
    let deps = Deps::from_test_context(&ctx);
    let mut reconstruction = Box::pin(SessionReconstructionService::reconstruct(
        &deps,
        session_id.clone(),
        None,
        None,
    ));
    tokio::select! {
        result = &mut reconstruction => panic!("reconstruction escaped pending admission: {result:?}"),
        () = tokio::time::sleep(std::time::Duration::from_millis(20)) => {}
    }

    drop(run);
    let result = tokio::time::timeout(std::time::Duration::from_secs(1), reconstruction)
        .await
        .expect("released admission wakes reconstruction")
        .unwrap();

    assert_eq!(result["isRunning"], false);
    assert_eq!(result["agentPhase"], "idle");
}

#[tokio::test]
async fn terminal_projection_stays_running_until_run_guard_release() {
    let ctx = make_test_context();
    let session_id = ctx
        .session_manager
        .create_session("model", "/tmp", Some("terminal-cut"))
        .unwrap();
    let run = ctx
        .orchestrator
        .begin_run(&session_id, "run-terminal")
        .unwrap();
    let user = ctx
        .event_store
        .append(&AppendOptions {
            session_id: &session_id,
            event_type: EventType::MessageUser,
            payload: json!({ "content": "hello", "turn": 1 }),
            parent_id: None,
            sequence: Some(1),
        })
        .unwrap();
    assert!(
        ctx.orchestrator
            .commit_run_admission(&session_id, "run-terminal", user.sequence)
    );
    let _ = ctx.orchestrator.broadcast().emit(TronEvent::AgentStart {
        base: BaseEvent::now(&session_id).with_sequence(2),
    });
    let _ = ctx.orchestrator.broadcast().emit(TronEvent::AgentEnd {
        base: BaseEvent::now(&session_id).with_sequence(3),
        error: None,
    });

    let result = SessionReconstructionService::reconstruct(
        &Deps::from_test_context(&ctx),
        session_id.clone(),
        None,
        None,
    )
    .await
    .unwrap();

    assert_eq!(result["isRunning"], true);
    assert_eq!(result["agentPhase"], "processing");
    assert_eq!(result["lastSequence"], 3);
    assert!(result["inFlight"].is_null());

    drop(run);
    let idle = SessionReconstructionService::reconstruct(
        &Deps::from_test_context(&ctx),
        session_id,
        None,
        None,
    )
    .await
    .unwrap();
    assert_eq!(idle["isRunning"], false);
    assert_eq!(idle["agentPhase"], "idle");
}

#[tokio::test]
async fn persisted_completed_response_is_not_duplicated_as_in_flight_text() {
    let ctx = make_test_context();
    let session_id = ctx
        .session_manager
        .create_session("model", "/tmp", Some("completed-response"))
        .unwrap();
    let _run = ctx
        .orchestrator
        .begin_run(&session_id, "run-completed-response")
        .unwrap();
    let user = ctx
        .event_store
        .append(&AppendOptions {
            session_id: &session_id,
            event_type: EventType::MessageUser,
            payload: json!({ "content": "prompt", "turn": 1 }),
            parent_id: None,
            sequence: Some(1),
        })
        .unwrap();
    assert!(ctx.orchestrator.commit_run_admission(
        &session_id,
        "run-completed-response",
        user.sequence
    ));
    let _ = ctx.orchestrator.broadcast().emit(TronEvent::TurnStart {
        base: BaseEvent::now(&session_id).with_sequence(2),
        turn: 1,
        agent_delivery_continuation: None,
    });
    let _ = ctx.orchestrator.broadcast().emit(TronEvent::MessageUpdate {
        base: BaseEvent::now(&session_id).with_sequence(3),
        content: "complete text".into(),
    });
    ctx.event_store
        .append(&AppendOptions {
            session_id: &session_id,
            event_type: EventType::MessageAssistant,
            payload: json!({
                "content": [{ "type": "text", "text": "complete text" }],
                "turn": 1,
                "model": "model",
                "stopReason": "end_turn"
            }),
            parent_id: None,
            sequence: Some(4),
        })
        .unwrap();
    let _ = ctx
        .orchestrator
        .broadcast()
        .emit(TronEvent::ResponseComplete {
            base: BaseEvent::now(&session_id).with_sequence(5),
            turn: 1,
            stop_reason: "end_turn".into(),
            token_usage: None,
            has_tool_invocations: false,
            tool_invocation_count: 0,
            token_record: None,
            model: Some("model".into()),
            agent_delivery_continuation: None,
        });

    let result = SessionReconstructionService::reconstruct(
        &Deps::from_test_context(&ctx),
        session_id,
        None,
        None,
    )
    .await
    .unwrap();

    assert_eq!(
        result["events"]
            .as_array()
            .unwrap()
            .iter()
            .filter(|event| event["type"] == "message.assistant")
            .count(),
        1
    );
    assert!(result["inFlight"]["streaming"].is_null());
    assert!(
        result["inFlight"]["contentSequence"]
            .as_array()
            .unwrap()
            .is_empty()
    );
    assert_eq!(result["lastSequence"], 5);
}

#[tokio::test]
async fn fork_ancestors_never_advance_child_live_watermark() {
    let ctx = make_test_context();
    let parent_id = ctx
        .session_manager
        .create_session("model", "/tmp", Some("parent"))
        .unwrap();
    for turn in 1..=4 {
        ctx.event_store
            .append(&AppendOptions {
                session_id: &parent_id,
                event_type: EventType::MessageUser,
                payload: json!({ "content": format!("parent-{turn}"), "turn": turn }),
                parent_id: None,
                sequence: None,
            })
            .unwrap();
    }
    assert_eq!(ctx.event_store.get_max_sequence(&parent_id).unwrap(), 4);

    let fork = SessionLifecycleService::fork(
        &Deps::from_test_context(&ctx),
        parent_id.clone(),
        None,
        Some("child".into()),
    )
    .await
    .unwrap();
    let child_id = fork["newSessionId"].as_str().unwrap().to_owned();
    let child_root_id = fork["rootEventId"].as_str().unwrap().to_owned();

    let initial = SessionReconstructionService::reconstruct(
        &Deps::from_test_context(&ctx),
        child_id.clone(),
        None,
        None,
    )
    .await
    .unwrap();
    assert_eq!(initial["lastSequence"], 0);

    let ancestor_page = SessionReconstructionService::reconstruct(
        &Deps::from_test_context(&ctx),
        child_id,
        Some(1),
        Some(child_root_id),
    )
    .await
    .unwrap();
    assert_eq!(ancestor_page["events"].as_array().unwrap().len(), 1);
    assert_eq!(ancestor_page["events"][0]["sessionId"], parent_id);
    assert_eq!(ancestor_page["lastSequence"], 0);
}
