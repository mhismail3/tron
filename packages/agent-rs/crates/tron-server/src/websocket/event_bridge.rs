//! Event bridge — converts `TronEvent`s from the Orchestrator broadcast into
//! `RpcEvent`s and routes them through the `BroadcastManager`.

use std::sync::Arc;

use tokio::sync::broadcast;
use tron_core::events::TronEvent;
use tron_rpc::types::RpcEvent;

use super::broadcast::BroadcastManager;

/// Bridges orchestrator events to WebSocket clients.
pub struct EventBridge {
    rx: broadcast::Receiver<TronEvent>,
    broadcast: Arc<BroadcastManager>,
}

impl EventBridge {
    /// Create a new event bridge.
    pub fn new(rx: broadcast::Receiver<TronEvent>, broadcast: Arc<BroadcastManager>) -> Self {
        Self { rx, broadcast }
    }

    /// Run the bridge loop. Exits when the broadcast sender is dropped.
    #[tracing::instrument(skip_all, name = "event_bridge")]
    pub async fn run(mut self) {
        loop {
            match self.rx.recv().await {
                Ok(event) => {
                    let event_type = event.event_type();
                    tracing::debug!(event_type, "bridging event to client");
                    let rpc_event = tron_event_to_rpc(&event);
                    let session_id = event.session_id();

                    if session_id.is_empty() {
                        self.broadcast.broadcast_all(&rpc_event).await;
                    } else {
                        self.broadcast
                            .broadcast_to_session(session_id, &rpc_event)
                            .await;
                    }
                }
                Err(broadcast::error::RecvError::Lagged(n)) => {
                    tracing::warn!(lagged = n, "event bridge lagged");
                }
                Err(broadcast::error::RecvError::Closed) => {
                    tracing::info!("Event bridge: sender closed, exiting");
                    break;
                }
            }
        }
    }
}

/// Convert a `TronEvent` to an `RpcEvent` for WebSocket transmission.
#[allow(clippy::too_many_lines)]
pub fn tron_event_to_rpc(event: &TronEvent) -> RpcEvent {
    let event_type = event.event_type();
    let session_id = event.session_id();
    let timestamp = event.timestamp();

    let data = match event {
        TronEvent::MessageUpdate { content, .. } => {
            Some(serde_json::json!({ "delta": content }))
        }
        TronEvent::TurnStart { turn, .. } => {
            Some(serde_json::json!({ "turn": turn }))
        }
        TronEvent::TurnEnd {
            turn,
            duration,
            token_usage,
            cost,
            context_limit,
            ..
        } => {
            let mut data = serde_json::json!({
                "turn": turn,
                "duration": duration,
            });
            if let Some(usage) = token_usage {
                data["tokenUsage"] = serde_json::to_value(usage).unwrap_or_default();
            }
            if let Some(c) = cost {
                data["cost"] = serde_json::json!(c);
            }
            if let Some(limit) = context_limit {
                data["contextLimit"] = serde_json::json!(limit);
            }
            // ADAPTER(ios-compat): iOS reads tokenRecord.source.rawXxxTokens for stats line.
            // REMOVE: delete these two lines; iOS should read tokenUsage directly.
            tron_rpc::adapters::adapt_turn_end_data(&mut data, session_id, *turn);
            Some(data)
        }
        TronEvent::ToolExecutionStart {
            tool_name,
            tool_call_id,
            arguments,
            ..
        } => {
            let mut data = serde_json::json!({
                "toolName": tool_name,
                "toolCallId": tool_call_id,
            });
            if let Some(args) = arguments {
                data["arguments"] = serde_json::json!(args);
            }
            Some(data)
        }
        TronEvent::ToolExecutionEnd {
            tool_name,
            tool_call_id,
            duration,
            is_error,
            result,
            ..
        } => {
            let success = !is_error.unwrap_or(false);
            let mut data = serde_json::json!({
                "toolName": tool_name,
                "toolCallId": tool_call_id,
                "duration": duration,
                "durationMs": duration,
                "success": success,
            });
            // Extract result text from TronToolResult
            if let Some(tool_result) = result {
                let result_text = match &tool_result.content {
                    tron_core::tools::ToolResultBody::Text(t) => t.clone(),
                    tron_core::tools::ToolResultBody::Blocks(blocks) => {
                        blocks
                            .iter()
                            .filter_map(|b| {
                                if let tron_core::content::ToolResultContent::Text { text } = b {
                                    Some(text.as_str())
                                } else {
                                    None
                                }
                            })
                            .collect::<Vec<_>>()
                            .join("\n")
                    }
                };
                if success {
                    data["output"] = serde_json::json!(result_text);
                    data["result"] = serde_json::json!(result_text);
                } else {
                    data["error"] = serde_json::json!(result_text);
                }
                if let Some(ref details) = tool_result.details {
                    data["details"] = details.clone();
                }
            }
            Some(data)
        }
        TronEvent::ToolExecutionUpdate {
            tool_call_id,
            update,
            ..
        } => Some(serde_json::json!({
            "toolCallId": tool_call_id,
            "output": update,
        })),
        TronEvent::ToolUseBatch { tool_calls, .. } => {
            Some(serde_json::json!({ "toolCalls": tool_calls }))
        }
        TronEvent::ToolCallArgumentDelta {
            tool_call_id,
            tool_name,
            arguments_delta,
            ..
        } => {
            let mut data = serde_json::json!({
                "toolCallId": tool_call_id,
                "argumentsDelta": arguments_delta,
            });
            if let Some(name) = tool_name {
                data["toolName"] = serde_json::json!(name);
            }
            Some(data)
        }
        TronEvent::ToolCallGenerating {
            tool_call_id,
            tool_name,
            ..
        } => Some(serde_json::json!({
            "toolCallId": tool_call_id,
            "toolName": tool_name,
        })),
        TronEvent::AgentEnd { error, .. } => {
            error.as_ref().map(|e| serde_json::json!({ "error": e }))
        }
        TronEvent::AgentInterrupted {
            turn,
            partial_content,
            active_tool,
            ..
        } => {
            let mut data = serde_json::json!({ "turn": turn });
            if let Some(content) = partial_content {
                data["partialContent"] = serde_json::json!(content);
            }
            if let Some(tool) = active_tool {
                data["activeTool"] = serde_json::json!(tool);
            }
            Some(data)
        }
        TronEvent::TurnFailed {
            turn,
            error,
            code,
            category,
            recoverable,
            partial_content,
            ..
        } => {
            let mut data = serde_json::json!({
                "turn": turn,
                "error": error,
                "recoverable": recoverable,
            });
            if let Some(c) = code {
                data["code"] = serde_json::json!(c);
            }
            if let Some(cat) = category {
                data["category"] = serde_json::json!(cat);
            }
            if let Some(content) = partial_content {
                data["partialContent"] = serde_json::json!(content);
            }
            Some(data)
        }
        TronEvent::ResponseComplete {
            turn,
            stop_reason,
            token_usage,
            has_tool_calls,
            tool_call_count,
            ..
        } => {
            let mut data = serde_json::json!({
                "turn": turn,
                "stopReason": stop_reason,
                "hasToolCalls": has_tool_calls,
                "toolCallCount": tool_call_count,
            });
            if let Some(usage) = token_usage {
                data["tokenUsage"] = serde_json::to_value(usage).unwrap_or_default();
            }
            Some(data)
        }
        TronEvent::Error {
            error, context, ..
        } => {
            let mut data = serde_json::json!({ "message": error });
            if let Some(ctx) = context {
                data["context"] = serde_json::json!(ctx);
            }
            Some(data)
        }
        TronEvent::CompactionStart {
            reason,
            tokens_before,
            ..
        } => Some(serde_json::json!({
            "reason": reason,
            "tokensBefore": tokens_before,
        })),
        TronEvent::CompactionComplete {
            success,
            tokens_before,
            tokens_after,
            compression_ratio,
            reason,
            summary,
            estimated_context_tokens,
            ..
        } => {
            let mut data = serde_json::json!({
                "success": success,
                "tokensBefore": tokens_before,
                "tokensAfter": tokens_after,
                "compressionRatio": compression_ratio,
            });
            if let Some(r) = reason {
                data["reason"] = serde_json::to_value(r).unwrap_or_default();
            }
            if let Some(s) = summary {
                data["summary"] = serde_json::json!(s);
            }
            if let Some(t) = estimated_context_tokens {
                data["estimatedContextTokens"] = serde_json::json!(t);
            }
            Some(data)
        }
        TronEvent::ContextWarning {
            usage_percent,
            message,
            ..
        } => Some(serde_json::json!({
            "usagePercent": usage_percent,
            "message": message,
        })),
        TronEvent::HookTriggered {
            hook_names,
            hook_event,
            tool_name,
            tool_call_id,
            ..
        } => {
            let mut data = serde_json::json!({
                "hookNames": hook_names,
                "hookEvent": hook_event,
            });
            if let Some(name) = tool_name {
                data["toolName"] = serde_json::json!(name);
            }
            if let Some(id) = tool_call_id {
                data["toolCallId"] = serde_json::json!(id);
            }
            Some(data)
        }
        TronEvent::HookCompleted {
            hook_names,
            hook_event,
            result,
            duration,
            reason,
            tool_name,
            tool_call_id,
            ..
        } => {
            let mut data = serde_json::json!({
                "hookNames": hook_names,
                "hookEvent": hook_event,
                "result": result,
            });
            if let Some(d) = duration {
                data["duration"] = serde_json::json!(d);
            }
            if let Some(r) = reason {
                data["reason"] = serde_json::json!(r);
            }
            if let Some(name) = tool_name {
                data["toolName"] = serde_json::json!(name);
            }
            if let Some(id) = tool_call_id {
                data["toolCallId"] = serde_json::json!(id);
            }
            Some(data)
        }
        TronEvent::HookBackgroundStarted {
            hook_names,
            hook_event,
            execution_id,
            ..
        } => Some(serde_json::json!({
            "hookNames": hook_names,
            "hookEvent": hook_event,
            "executionId": execution_id,
        })),
        TronEvent::HookBackgroundCompleted {
            hook_names,
            hook_event,
            execution_id,
            result,
            duration,
            error,
            ..
        } => {
            let mut data = serde_json::json!({
                "hookNames": hook_names,
                "hookEvent": hook_event,
                "executionId": execution_id,
                "result": result,
                "duration": duration,
            });
            if let Some(e) = error {
                data["error"] = serde_json::json!(e);
            }
            Some(data)
        }
        TronEvent::ApiRetry {
            attempt,
            max_retries,
            delay_ms,
            error_category,
            error_message,
            ..
        } => Some(serde_json::json!({
            "attempt": attempt,
            "maxRetries": max_retries,
            "delayMs": delay_ms,
            "errorCategory": error_category,
            "errorMessage": error_message,
        })),
        TronEvent::ThinkingDelta { delta, .. } => {
            Some(serde_json::json!({ "delta": delta }))
        }
        TronEvent::ThinkingEnd { thinking, .. } => {
            Some(serde_json::json!({ "thinking": thinking }))
        }
        TronEvent::SessionCreated {
            model,
            working_directory,
            ..
        } => Some(serde_json::json!({
            "model": model,
            "workingDirectory": working_directory,
        })),
        TronEvent::SessionForked {
            new_session_id, ..
        } => Some(serde_json::json!({
            "newSessionId": new_session_id,
        })),
        TronEvent::SessionUpdated {
            title,
            model,
            message_count,
            input_tokens,
            output_tokens,
            last_turn_input_tokens,
            cache_read_tokens,
            cache_creation_tokens,
            cost,
            last_activity,
            is_active,
            last_user_prompt,
            last_assistant_response,
            parent_session_id,
            ..
        } => Some(serde_json::json!({
            "title": title,
            "model": model,
            "messageCount": message_count,
            "inputTokens": input_tokens,
            "outputTokens": output_tokens,
            "lastTurnInputTokens": last_turn_input_tokens,
            "cacheReadTokens": cache_read_tokens,
            "cacheCreationTokens": cache_creation_tokens,
            "cost": cost,
            "lastActivity": last_activity,
            "isActive": is_active,
            "lastUserPrompt": last_user_prompt,
            "lastAssistantResponse": last_assistant_response,
            "parentSessionId": parent_session_id,
        })),
        TronEvent::MemoryUpdated {
            title, entry_type, ..
        } => Some(serde_json::json!({
            "title": title,
            "entryType": entry_type,
        })),
        TronEvent::ContextCleared {
            tokens_before,
            tokens_after,
            ..
        } => Some(serde_json::json!({
            "tokensBefore": tokens_before,
            "tokensAfter": tokens_after,
        })),
        TronEvent::MessageDeleted {
            target_event_id,
            target_type,
            target_turn,
            reason,
            ..
        } => Some(serde_json::json!({
            "targetEventId": target_event_id,
            "targetType": target_type,
            "targetTurn": target_turn,
            "reason": reason,
        })),
        TronEvent::SkillRemoved { skill_name, .. } => Some(serde_json::json!({
            "skillName": skill_name,
        })),
        // Events with no additional data
        TronEvent::AgentStart { .. }
        | TronEvent::AgentReady { .. }
        | TronEvent::ThinkingStart { .. }
        | TronEvent::MemoryUpdating { .. }
        | TronEvent::SessionSaved { .. }
        | TronEvent::SessionLoaded { .. }
        | TronEvent::SessionArchived { .. }
        | TronEvent::SessionUnarchived { .. }
        | TronEvent::SessionDeleted { .. } => None,
    };

    // Map internal event types to wire format
    let wire_type = match event_type {
        "agent_start" => "agent.start",
        "agent_end" => "agent.complete",
        "agent_ready" => "agent.ready",
        "agent_interrupted" => "agent.interrupted",
        "message_update" => "agent.text_delta",
        "turn_start" => "agent.turn_start",
        "turn_end" => "agent.turn_end",
        "agent.turn_failed" => "agent.turn_failed",
        "response_complete" => "agent.response_complete",
        "tool_execution_start" => "agent.tool_start",
        "tool_execution_end" => "agent.tool_end",
        "tool_execution_update" => "agent.tool_output",
        "tool_use_batch" => "agent.tool_use_batch",
        "toolcall_delta" => "agent.toolcall_delta",
        "toolcall_generating" => "agent.tool_generating",
        "hook_triggered" => "hook.triggered",
        "hook_completed" => "hook.completed",
        "hook.background_started" => "hook.background_started",
        "hook.background_completed" => "hook.background_completed",
        "compaction_start" => "agent.compaction_started",
        "compaction_complete" => "agent.compaction",
        "context_warning" => "context.warning",
        "api_retry" => "agent.retry",
        "thinking_start" => "agent.thinking_start",
        "thinking_delta" => "agent.thinking_delta",
        "thinking_end" => "agent.thinking_end",
        "error" => "agent.error",
        "session_created" => "session.created",
        "session_archived" => "session.archived",
        "session_unarchived" => "session.unarchived",
        "session_forked" => "session.forked",
        "session_deleted" => "session.deleted",
        "session_updated" => "session.updated",
        "memory_updating" => "agent.memory_updating",
        "memory_updated" => "agent.memory_updated",
        "context_cleared" => "agent.context_cleared",
        "message_deleted" => "agent.message_deleted",
        "skill_removed" => "agent.skill_removed",
        other => other,
    };

    RpcEvent {
        event_type: wire_type.to_string(),
        session_id: if session_id.is_empty() {
            None
        } else {
            Some(session_id.to_string())
        },
        timestamp: timestamp.to_string(),
        data,
        run_id: None,
    }
}

#[cfg(test)]
mod tests {
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
            context_limit: None,
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

    #[tokio::test]
    async fn bridge_routes_session_events() {
        let (tx, _) = broadcast::channel(16);
        let bm = Arc::new(BroadcastManager::new());

        // Add a connection bound to session "s1"
        let (conn_tx, mut conn_rx) = tokio::sync::mpsc::channel(32);
        let conn =
            super::super::connection::ClientConnection::new("c1".into(), conn_tx);
        conn.bind_session("s1".into());
        bm.add(Arc::new(conn)).await;

        let rx = tx.subscribe();
        let bridge = EventBridge::new(rx, bm.clone());

        // Spawn bridge
        let handle = tokio::spawn(bridge.run());

        // Send an event
        tx.send(agent_start_event("s1")).unwrap();

        // Give bridge time to process
        tokio::time::sleep(std::time::Duration::from_millis(50)).await;

        // Check that the connection received the event
        let msg = conn_rx.try_recv();
        assert!(msg.is_ok());
        let parsed: serde_json::Value = serde_json::from_str(&msg.unwrap()).unwrap();
        assert_eq!(parsed["type"], "agent.start");

        // Drop sender to close bridge
        drop(tx);
        let _ = handle.await;
    }

    #[tokio::test]
    async fn bridge_routes_global_events() {
        let (tx, _) = broadcast::channel(16);
        let bm = Arc::new(BroadcastManager::new());

        let (conn_tx, mut conn_rx) = tokio::sync::mpsc::channel(32);
        let conn =
            super::super::connection::ClientConnection::new("c1".into(), conn_tx);
        bm.add(Arc::new(conn)).await;

        let rx = tx.subscribe();
        let bridge = EventBridge::new(rx, bm.clone());
        let handle = tokio::spawn(bridge.run());

        // Send event with empty session_id (global)
        tx.send(TronEvent::AgentReady {
            base: BaseEvent::now(""),
        })
        .unwrap();

        tokio::time::sleep(std::time::Duration::from_millis(50)).await;

        let msg = conn_rx.try_recv();
        assert!(msg.is_ok());

        drop(tx);
        let _ = handle.await;
    }

    #[test]
    fn turn_end_includes_token_record() {
        let event = TronEvent::TurnEnd {
            base: BaseEvent::now("s1"),
            turn: 2,
            duration: 5000,
            token_usage: Some(tron_core::events::TurnTokenUsage {
                input_tokens: 100,
                output_tokens: 50,
                cache_read_tokens: Some(10),
                cache_creation_tokens: None,
            }),
            token_record: None,
            cost: None,
            context_limit: None,
        };
        let rpc = tron_event_to_rpc(&event);
        let data = rpc.data.unwrap();
        assert!(data["tokenRecord"]["source"]["rawInputTokens"].is_number());
        assert_eq!(data["tokenRecord"]["source"]["rawInputTokens"], 100);
        assert_eq!(data["tokenRecord"]["source"]["rawOutputTokens"], 50);
        assert_eq!(data["tokenRecord"]["source"]["rawCacheReadTokens"], 10);
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
                cache_creation_tokens: None,
            }),
            token_record: None,
            cost: Some(0.005),
            context_limit: Some(200_000),
        };
        let rpc = tron_event_to_rpc(&event);
        assert_eq!(rpc.event_type, "agent.turn_end");
        let data = rpc.data.unwrap();
        assert_eq!(data["turn"], 2);
        assert_eq!(data["duration"], 5000);
        assert_eq!(data["tokenUsage"]["inputTokens"], 100);
        assert_eq!(data["tokenUsage"]["outputTokens"], 50);
        assert_eq!(data["cost"], 0.005);
        assert_eq!(data["contextLimit"], 200_000);
    }

    #[test]
    fn tool_end_success_has_required_ios_fields() {
        use tron_core::tools::{TronToolResult, ToolResultBody};
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
        // iOS REQUIRED field: success (non-optional Bool)
        assert_eq!(data["success"], true);
        assert_eq!(data["toolCallId"], "tc_1");
        assert_eq!(data["toolName"], "bash");
        assert_eq!(data["duration"], 1500);
        assert_eq!(data["durationMs"], 1500);
        assert_eq!(data["output"], "file1.txt\nfile2.txt");
        assert_eq!(data["result"], "file1.txt\nfile2.txt");
    }

    #[test]
    fn tool_end_error_has_required_ios_fields() {
        use tron_core::tools::{TronToolResult, ToolResultBody};
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
        assert_eq!(data["durationMs"], 500);
    }

    #[test]
    fn tool_end_with_details() {
        use tron_core::tools::{TronToolResult, ToolResultBody};
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
        // Even without result, success must be present (iOS requires it)
        assert_eq!(data["success"], true);
        assert_eq!(data["durationMs"], 1500);
    }

    #[test]
    fn tool_end_content_blocks_joined() {
        use tron_core::tools::{TronToolResult, ToolResultBody};
        use tron_core::content::ToolResultContent;
        let event = TronEvent::ToolExecutionEnd {
            base: BaseEvent::now("s1"),
            tool_call_id: "tc_1".into(),
            tool_name: "read".into(),
            duration: 100,
            is_error: Some(false),
            result: Some(TronToolResult {
                content: ToolResultBody::Blocks(vec![
                    ToolResultContent::Text { text: "line 1".into() },
                    ToolResultContent::Text { text: "line 2".into() },
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
        };
        let rpc = tron_event_to_rpc(&event);
        assert_eq!(rpc.event_type, "agent.error");
        let data = rpc.data.unwrap();
        assert_eq!(data["message"], "connection failed");
        assert_eq!(data["context"], "during tool execution");
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
            TronEvent::AgentEnd { base: base.clone(), error: None },
            TronEvent::AgentReady { base: base.clone() },
            TronEvent::AgentInterrupted { base: base.clone(), turn: 1, partial_content: None, active_tool: None },
            TronEvent::TurnStart { base: base.clone(), turn: 1 },
            TronEvent::TurnEnd { base: base.clone(), turn: 1, duration: 0, token_usage: None, token_record: None, cost: None, context_limit: None },
            TronEvent::TurnFailed { base: base.clone(), turn: 1, error: "e".into(), code: None, category: None, recoverable: false, partial_content: None },
            TronEvent::ResponseComplete { base: base.clone(), turn: 1, stop_reason: "end_turn".into(), token_usage: None, has_tool_calls: false, tool_call_count: 0 },
            TronEvent::MessageUpdate { base: base.clone(), content: "c".into() },
            TronEvent::ToolExecutionStart { base: base.clone(), tool_call_id: "id".into(), tool_name: "n".into(), arguments: None },
            TronEvent::ToolExecutionEnd { base: base.clone(), tool_call_id: "id".into(), tool_name: "n".into(), duration: 0, is_error: None, result: None },
            TronEvent::Error { base: base.clone(), error: "e".into(), context: None },
            TronEvent::CompactionStart { base: base.clone(), reason: tron_core::events::CompactionReason::Manual, tokens_before: 0 },
            TronEvent::CompactionComplete { base: base.clone(), success: true, tokens_before: 0, tokens_after: 0, compression_ratio: 0.0, reason: None, summary: None, estimated_context_tokens: None },
            TronEvent::ThinkingStart { base: base.clone() },
            TronEvent::ThinkingDelta { base: base.clone(), delta: "d".into() },
            TronEvent::ThinkingEnd { base: base.clone(), thinking: "t".into() },
            TronEvent::SessionCreated { base: base.clone(), model: "m".into(), working_directory: "/".into() },
            TronEvent::SessionArchived { base: base.clone() },
            TronEvent::SessionUnarchived { base: base.clone() },
            TronEvent::SessionForked { base: base.clone(), new_session_id: "s2".into() },
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
            TronEvent::MemoryUpdated { base: base.clone(), title: None, entry_type: None },
            TronEvent::ContextCleared { base: base.clone(), tokens_before: 0, tokens_after: 0 },
            TronEvent::MessageDeleted { base: base.clone(), target_event_id: "id".into(), target_type: "t".into(), target_turn: None, reason: None },
            TronEvent::SkillRemoved { base, skill_name: "n".into() },
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
        let event = TronEvent::MemoryUpdating { base: BaseEvent::now("s1") };
        let rpc = tron_event_to_rpc(&event);
        assert_eq!(rpc.event_type, "agent.memory_updating");
        assert!(rpc.data.is_none());
    }

    #[test]
    fn memory_updated_wire_type_and_data() {
        let event = TronEvent::MemoryUpdated {
            base: BaseEvent::now("s1"),
            title: Some("My Entry".into()),
            entry_type: Some("feature".into()),
        };
        let rpc = tron_event_to_rpc(&event);
        assert_eq!(rpc.event_type, "agent.memory_updated");
        let data = rpc.data.unwrap();
        assert_eq!(data["title"], "My Entry");
        assert_eq!(data["entryType"], "feature");
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
}
