//! Event bridge — converts `TronEvent`s from the Orchestrator broadcast into
//! `RpcEvent`s and routes them through the `BroadcastManager`.

use std::sync::Arc;

use crate::rpc::types::RpcEvent;
use tokio::sync::broadcast;
use tokio_util::sync::CancellationToken;
use tron_core::events::TronEvent;
use tron_tools::cdp::types::BrowserEvent;

use super::broadcast::BroadcastManager;

/// Bridges orchestrator events and browser events to WebSocket clients.
pub struct EventBridge {
    rx: broadcast::Receiver<TronEvent>,
    browser_rx: Option<broadcast::Receiver<BrowserEvent>>,
    broadcast: Arc<BroadcastManager>,
    cancel: CancellationToken,
}

impl EventBridge {
    /// Create a new event bridge.
    ///
    /// `browser_rx` is optional — when `None`, browser frame delivery is disabled.
    pub fn new(
        rx: broadcast::Receiver<TronEvent>,
        broadcast: Arc<BroadcastManager>,
        browser_rx: Option<broadcast::Receiver<BrowserEvent>>,
        cancel: CancellationToken,
    ) -> Self {
        Self {
            rx,
            browser_rx,
            broadcast,
            cancel,
        }
    }

    /// Run the bridge loop. Exits on shutdown signal or when the broadcast sender is dropped.
    #[tracing::instrument(skip_all, name = "event_bridge")]
    pub async fn run(mut self) {
        if let Some(mut browser_rx) = self.browser_rx.take() {
            // Dual-channel select: TronEvent + BrowserEvent + shutdown
            loop {
                tokio::select! {
                    () = self.cancel.cancelled() => {
                        tracing::info!("event bridge: shutdown signal received");
                        break;
                    }
                    result = self.rx.recv() => {
                        match result {
                            Ok(event) => self.bridge_tron_event(&event).await,
                            Err(broadcast::error::RecvError::Lagged(n)) => {
                                tracing::warn!(lagged = n, "event bridge lagged");
                            }
                            Err(broadcast::error::RecvError::Closed) => {
                                tracing::info!("event bridge: sender closed, exiting");
                                break;
                            }
                        }
                    }
                    result = browser_rx.recv() => {
                        match result {
                            Ok(event) => self.bridge_browser_event(&event).await,
                            Err(broadcast::error::RecvError::Lagged(n)) => {
                                tracing::warn!(lagged = n, "browser event bridge lagged");
                            }
                            Err(broadcast::error::RecvError::Closed) => {
                                tracing::debug!("browser event channel closed, continuing with TronEvent only");
                                self.run_tron_only().await;
                                break;
                            }
                        }
                    }
                }
            }
        } else {
            self.run_tron_only().await;
        }
    }

    async fn run_tron_only(&mut self) {
        loop {
            tokio::select! {
                () = self.cancel.cancelled() => {
                    tracing::info!("event bridge: shutdown signal received");
                    break;
                }
                result = self.rx.recv() => {
                    match result {
                        Ok(event) => self.bridge_tron_event(&event).await,
                        Err(broadcast::error::RecvError::Lagged(n)) => {
                            tracing::warn!(lagged = n, "event bridge lagged");
                        }
                        Err(broadcast::error::RecvError::Closed) => {
                            tracing::info!("event bridge: sender closed, exiting");
                            break;
                        }
                    }
                }
            }
        }
    }

    async fn bridge_tron_event(&self, event: &TronEvent) {
        let event_type = event.event_type();
        tracing::debug!(event_type, "bridging event to client");
        let rpc_event = tron_event_to_rpc(event);
        let session_id = event.session_id();

        if session_id.is_empty() {
            self.broadcast.broadcast_all(&rpc_event).await;
        } else {
            self.broadcast
                .broadcast_to_session(session_id, &rpc_event)
                .await;
        }
    }

    async fn bridge_browser_event(&self, event: &BrowserEvent) {
        let rpc_event = browser_event_to_rpc(event);
        let session_id = match event {
            BrowserEvent::Frame { session_id, .. } | BrowserEvent::Closed { session_id } => {
                session_id
            }
        };
        self.broadcast
            .broadcast_to_session(session_id, &rpc_event)
            .await;
    }
}

/// Convert a `BrowserEvent` to an `RpcEvent` for WebSocket transmission.
fn browser_event_to_rpc(event: &BrowserEvent) -> RpcEvent {
    match event {
        BrowserEvent::Frame {
            session_id, frame, ..
        } => RpcEvent {
            event_type: "browser.frame".to_string(),
            session_id: Some(session_id.clone()),
            timestamp: chrono::Utc::now().to_rfc3339(),
            data: Some(serde_json::json!({
                "sessionId": frame.session_id,
                "data": frame.data,
                "frameId": frame.frame_id,
                "timestamp": frame.timestamp,
                "metadata": frame.metadata,
            })),
            run_id: None,
        },
        BrowserEvent::Closed { session_id } => RpcEvent {
            event_type: "browser.closed".to_string(),
            session_id: Some(session_id.clone()),
            timestamp: chrono::Utc::now().to_rfc3339(),
            data: Some(serde_json::json!({
                "sessionId": session_id,
            })),
            run_id: None,
        },
    }
}

/// Convert a `TronEvent` to an `RpcEvent` for WebSocket transmission.
#[allow(clippy::too_many_lines)]
pub fn tron_event_to_rpc(event: &TronEvent) -> RpcEvent {
    let event_type = event.event_type();
    let session_id = event.session_id();
    let timestamp = event.timestamp();

    let data = match event {
        TronEvent::MessageUpdate { content, .. } => Some(serde_json::json!({ "delta": content })),
        TronEvent::TurnStart { turn, .. } => Some(serde_json::json!({ "turn": turn })),
        TronEvent::TurnEnd {
            turn,
            duration,
            token_usage,
            token_record,
            cost,
            stop_reason,
            context_limit,
            model,
            ..
        } => {
            let mut data = serde_json::json!({
                "turn": turn,
                "duration": duration,
                "durationMs": duration,
            });
            if let Some(usage) = token_usage {
                data["tokenUsage"] = serde_json::to_value(usage).unwrap_or_default();
            }
            if let Some(record) = token_record {
                data["tokenRecord"] = record.clone();
            }
            if let Some(c) = cost {
                data["cost"] = serde_json::json!(c);
            }
            if let Some(sr) = stop_reason {
                data["stopReason"] = serde_json::json!(sr);
            }
            if let Some(limit) = context_limit {
                data["contextLimit"] = serde_json::json!(limit);
            }
            if let Some(m) = model {
                data["model"] = serde_json::json!(m);
            }
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
                let mut result_text = match &tool_result.content {
                    tron_core::tools::ToolResultBody::Text(t) => t.clone(),
                    tron_core::tools::ToolResultBody::Blocks(blocks) => blocks
                        .iter()
                        .filter_map(|b| {
                            if let tron_core::content::ToolResultContent::Text { text } = b {
                                Some(text.as_str())
                            } else {
                                None
                            }
                        })
                        .collect::<Vec<_>>()
                        .join("\n"),
                };
                result_text = crate::rpc::adapters::adapt_tool_execution_result_for_ios(
                    tool_name,
                    success,
                    &result_text,
                    tool_result.details.as_ref(),
                );
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
            token_record,
            model,
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
            if let Some(record) = token_record {
                data["tokenRecord"] = record.clone();
            }
            if let Some(m) = model {
                data["model"] = serde_json::json!(m);
            }
            Some(data)
        }
        TronEvent::Error {
            error,
            context,
            code,
            provider,
            category,
            suggestion,
            retryable,
            status_code,
            error_type,
            model,
            ..
        } => {
            let mut data = serde_json::json!({ "message": error });
            if let Some(ctx) = context {
                data["context"] = serde_json::json!(ctx);
            }
            if let Some(c) = code {
                data["code"] = serde_json::json!(c);
            }
            if let Some(p) = provider {
                data["provider"] = serde_json::json!(p);
            }
            if let Some(cat) = category {
                data["category"] = serde_json::json!(cat);
            }
            if let Some(s) = suggestion {
                data["suggestion"] = serde_json::json!(s);
            }
            if let Some(r) = retryable {
                data["retryable"] = serde_json::json!(r);
            }
            if let Some(sc) = status_code {
                data["statusCode"] = serde_json::json!(sc);
            }
            if let Some(et) = error_type {
                data["errorType"] = serde_json::json!(et);
            }
            if let Some(m) = model {
                data["model"] = serde_json::json!(m);
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
        TronEvent::ThinkingDelta { delta, .. } => Some(serde_json::json!({ "delta": delta })),
        TronEvent::ThinkingEnd { thinking, .. } => {
            Some(serde_json::json!({ "thinking": thinking }))
        }
        TronEvent::SessionCreated {
            base,
            model,
            working_directory,
            ..
        } => Some(serde_json::json!({
            "model": model,
            "workingDirectory": working_directory,
            "messageCount": 0,
            "inputTokens": 0,
            "outputTokens": 0,
            "cost": 0.0,
            "lastActivity": base.timestamp,
            "isActive": true,
        })),
        TronEvent::SessionForked { new_session_id, .. } => Some(serde_json::json!({
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
            title,
            entry_type,
            event_id,
            ..
        } => Some(serde_json::json!({
            "title": title,
            "entryType": entry_type,
            "eventId": event_id,
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
        TronEvent::RulesLoaded {
            total_files,
            dynamic_rules_count,
            ..
        } => Some(serde_json::json!({
            "totalFiles": total_files,
            "dynamicRulesCount": dynamic_rules_count,
        })),
        TronEvent::RulesActivated {
            rules,
            total_activated,
            ..
        } => Some(serde_json::json!({
            "rules": rules.iter().map(|r| serde_json::json!({
                "relativePath": r.relative_path,
                "scopeDir": r.scope_dir,
            })).collect::<Vec<_>>(),
            "totalActivated": total_activated,
        })),
        TronEvent::MemoryLoaded { count, .. } => Some(serde_json::json!({
            "count": count,
        })),
        TronEvent::SkillRemoved { skill_name, .. } => Some(serde_json::json!({
            "skillName": skill_name,
        })),
        TronEvent::SubagentSpawned {
            subagent_session_id,
            task,
            model,
            max_turns,
            spawn_depth,
            tool_call_id,
            blocking,
            working_directory,
            ..
        } => {
            let mut data = serde_json::json!({
                "subagentSessionId": subagent_session_id,
                "task": task,
                "model": model,
                "maxTurns": max_turns,
                "spawnDepth": spawn_depth,
                "blocking": blocking,
            });
            if let Some(id) = tool_call_id {
                data["toolCallId"] = serde_json::json!(id);
            }
            if let Some(wd) = working_directory {
                data["workingDirectory"] = serde_json::json!(wd);
            }
            Some(data)
        }
        TronEvent::SubagentStatusUpdate {
            subagent_session_id,
            status,
            current_turn,
            activity,
            ..
        } => {
            let mut data = serde_json::json!({
                "subagentSessionId": subagent_session_id,
                "status": status,
                "currentTurn": current_turn,
            });
            if let Some(act) = activity {
                data["activity"] = serde_json::json!(act);
            }
            Some(data)
        }
        TronEvent::SubagentCompleted {
            subagent_session_id,
            total_turns,
            duration,
            full_output,
            result_summary,
            token_usage,
            model,
            ..
        } => {
            let mut data = serde_json::json!({
                "subagentSessionId": subagent_session_id,
                "totalTurns": total_turns,
                "duration": duration,
            });
            if let Some(o) = full_output {
                data["fullOutput"] = serde_json::json!(o);
            }
            if let Some(s) = result_summary {
                data["resultSummary"] = serde_json::json!(s);
            }
            if let Some(tu) = token_usage {
                data["tokenUsage"] = tu.clone();
            }
            if let Some(m) = model {
                data["model"] = serde_json::json!(m);
            }
            Some(data)
        }
        TronEvent::SubagentFailed {
            subagent_session_id,
            error,
            duration,
            ..
        } => Some(serde_json::json!({
            "subagentSessionId": subagent_session_id,
            "error": error,
            "duration": duration,
        })),
        TronEvent::SubagentEvent {
            subagent_session_id,
            event,
            ..
        } => Some(serde_json::json!({
            "subagentSessionId": subagent_session_id,
            "event": event,
        })),
        TronEvent::SubagentResultAvailable {
            parent_session_id,
            subagent_session_id,
            task,
            result_summary,
            success,
            total_turns,
            duration,
            token_usage,
            error,
            completed_at,
            ..
        } => {
            let mut data = serde_json::json!({
                "parentSessionId": parent_session_id,
                "subagentSessionId": subagent_session_id,
                "task": task,
                "resultSummary": result_summary,
                "success": success,
                "totalTurns": total_turns,
                "duration": duration,
                "completedAt": completed_at,
            });
            if let Some(tu) = token_usage {
                data["tokenUsage"] = tu.clone();
            }
            if let Some(e) = error {
                data["error"] = serde_json::json!(e);
            }
            Some(data)
        }
        // Events with no additional data (empty object so iOS can decode `data: {}`)
        TronEvent::AgentStart { .. }
        | TronEvent::AgentReady { .. }
        | TronEvent::ThinkingStart { .. }
        | TronEvent::MemoryUpdating { .. }
        | TronEvent::SessionSaved { .. }
        | TronEvent::SessionLoaded { .. }
        | TronEvent::SessionArchived { .. }
        | TronEvent::SessionUnarchived { .. }
        | TronEvent::SessionDeleted { .. } => Some(serde_json::json!({})),
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
        "rules_loaded" => "rules.loaded",
        "rules_activated" => "rules.activated",
        "memory_loaded" => "memory.loaded",
        "skill_removed" => "agent.skill_removed",
        "subagent_spawned" => "agent.subagent_spawned",
        "subagent_status_update" => "agent.subagent_status",
        "subagent_completed" => "agent.subagent_completed",
        "subagent_failed" => "agent.subagent_failed",
        "subagent_event" => "agent.subagent_event",
        "subagent_result_available" => "agent.subagent_result_available",
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

    #[tokio::test]
    async fn bridge_routes_session_events() {
        let (tx, _) = broadcast::channel(16);
        let bm = Arc::new(BroadcastManager::new());

        // Add a connection bound to session "s1"
        let (conn_tx, mut conn_rx) = tokio::sync::mpsc::channel(32);
        let conn = super::super::connection::ClientConnection::new("c1".into(), conn_tx);
        conn.bind_session("s1".into());
        bm.add(Arc::new(conn)).await;

        let rx = tx.subscribe();
        let bridge = EventBridge::new(rx, bm.clone(), None, CancellationToken::new());

        // Spawn bridge
        let handle = tokio::spawn(bridge.run());

        // Send an event
        let _ = tx.send(agent_start_event("s1")).unwrap();

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
        let conn = super::super::connection::ClientConnection::new("c1".into(), conn_tx);
        bm.add(Arc::new(conn)).await;

        let rx = tx.subscribe();
        let bridge = EventBridge::new(rx, bm.clone(), None, CancellationToken::new());
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
                cache_creation_tokens: None,
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
                cache_read_tokens: None,
                cache_creation_tokens: None,
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
                cache_creation_tokens: None,
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
        assert_eq!(data["durationMs"], 5000);
        assert_eq!(data["tokenUsage"]["inputTokens"], 100);
        assert_eq!(data["tokenUsage"]["outputTokens"], 50);
        assert_eq!(data["cost"], 0.005);
        assert_eq!(data["stopReason"], "end_turn");
        assert_eq!(data["contextLimit"], 200_000);
    }

    #[test]
    fn tool_end_success_has_required_ios_fields() {
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
        assert_eq!(data["durationMs"], 500);
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
        // Even without result, success must be present (iOS requires it)
        assert_eq!(data["success"], true);
        assert_eq!(data["durationMs"], 1500);
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
    fn session_created_has_full_ios_fields() {
        let event = TronEvent::SessionCreated {
            base: BaseEvent::now("s1"),
            model: "claude-opus-4-6".into(),
            working_directory: "/tmp/project".into(),
        };
        let rpc = tron_event_to_rpc(&event);
        assert_eq!(rpc.event_type, "session.created");
        let data = rpc.data.unwrap();
        assert_eq!(data["model"], "claude-opus-4-6");
        assert_eq!(data["workingDirectory"], "/tmp/project");
        assert_eq!(data["messageCount"], 0);
        assert_eq!(data["inputTokens"], 0);
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

        let (conn_tx, mut conn_rx) = tokio::sync::mpsc::channel(32);
        let conn = super::super::connection::ClientConnection::new("c1".into(), conn_tx);
        conn.bind_session("s1".into());
        bm.add(Arc::new(conn)).await;

        let rx = tx.subscribe();
        let bridge = EventBridge::new(rx, bm.clone(), None, CancellationToken::new());
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
}
