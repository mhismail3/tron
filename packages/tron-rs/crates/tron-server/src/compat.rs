//! iOS compatibility layer.
//!
//! Translates between clean internal types and the wire format iOS expects.
//! This layer is thin and clearly marked for future removal when iOS is updated.

use serde::Serialize;
use tron_core::events::AgentEvent;
use tron_core::tokens::TokenUsage;
use tron_store::events::EventRow;
use tron_store::sessions::{SessionRow, SessionStatus};

// ── Step 2: Param normalization ──────────────────────────────────────────

/// Mapping of iOS camelCase param keys to Rust snake_case equivalents.
const CAMEL_TO_SNAKE: &[(&str, &str)] = &[
    ("sessionId", "session_id"),
    ("workingDirectory", "working_directory"),
    ("contextFiles", "context_files"),
    ("reasoningLevel", "reasoning_level"),
    ("beforeEventId", "before_event_id"),
    ("afterSequence", "after_sequence"),
    ("afterTimestamp", "after_timestamp"),
    ("deviceToken", "device_token"),
    ("toolCallId", "tool_call_id"),
    ("mimeType", "mime_type"),
    ("fileName", "file_name"),
    ("includeArchived", "include_archived"),
    ("showHidden", "show_hidden"),
];

/// Normalize iOS camelCase params to snake_case for Rust handlers.
/// If the snake_case key already exists, the existing value takes precedence.
pub fn normalize_params(params: &serde_json::Value) -> serde_json::Value {
    let Some(obj) = params.as_object() else {
        return params.clone();
    };
    let mut result = obj.clone();
    for &(camel, snake) in CAMEL_TO_SNAKE {
        if !result.contains_key(snake) {
            if let Some(val) = result.remove(camel) {
                result.insert(snake.to_string(), val);
            }
        } else {
            // snake_case already present — remove camelCase duplicate
            result.remove(camel);
        }
    }
    serde_json::Value::Object(result)
}

// ── Step 3: Event wire format ────────────────────────────────────────────

/// Wire format for agent events sent over WebSocket.
/// Envelope structure: `{ type, sessionId, timestamp, data }`.
#[derive(Debug, Serialize)]
pub struct WireEvent {
    #[serde(rename = "type")]
    pub event_type: String,
    #[serde(rename = "sessionId")]
    pub session_id: String,
    pub timestamp: String,
    pub data: serde_json::Value,
}

/// Map internal event type names to iOS wire format (agent.* prefix).
pub fn wire_event_type(internal_type: &str) -> String {
    match internal_type {
        "turn_start" => "agent.turn_start".into(),
        "text_delta" => "agent.text_delta".into(),
        "thinking_delta" => "agent.thinking_delta".into(),
        "tool_start" => "agent.tool_start".into(),
        "tool_end" => "agent.tool_end".into(),
        "turn_complete" => "agent.turn_end".into(),
        "agent_complete" => "agent.complete".into(),
        "agent_ready" => "agent.ready".into(),
        "subagent_spawned" => "agent.subagent_spawned".into(),
        "subagent_complete" => "agent.subagent_completed".into(),
        "compaction_started" => "agent.compaction_started".into(),
        "compaction_complete" => "agent.compaction".into(),
        other => format!("agent.{other}"),
    }
}

fn now_iso8601() -> String {
    chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Millis, true)
}

/// Convert an internal AgentEvent to the iOS wire format.
pub fn agent_event_to_wire(event: &AgentEvent) -> WireEvent {
    let internal_type = event.event_type();
    let event_type = wire_event_type(internal_type);
    let session_id = event.session_id().to_string();
    let timestamp = now_iso8601();

    let data = match event {
        AgentEvent::TurnStart { turn, .. } => serde_json::json!({
            "turn": turn,
        }),
        AgentEvent::TextDelta { delta, .. } => serde_json::json!({
            "delta": delta,
        }),
        AgentEvent::ThinkingDelta { delta, .. } => serde_json::json!({
            "delta": delta,
        }),
        AgentEvent::ToolStart {
            tool_call_id,
            tool_name,
            ..
        } => serde_json::json!({
            "toolCallId": tool_call_id.to_string(),
            "toolName": tool_name,
        }),
        AgentEvent::ToolEnd {
            tool_call_id,
            result_preview,
            duration_ms,
            ..
        } => serde_json::json!({
            "toolCallId": tool_call_id.to_string(),
            "resultPreview": result_preview,
            "durationMs": duration_ms,
        }),
        AgentEvent::TurnComplete { turn, usage, .. } => serde_json::json!({
            "turn": turn,
            "tokenUsage": usage_to_camel(usage),
        }),
        AgentEvent::AgentComplete { .. } => serde_json::json!({}),
        AgentEvent::AgentReady { .. } => serde_json::json!({}),
        AgentEvent::SubagentSpawned {
            parent_agent_id,
            child_agent_id,
            ..
        } => serde_json::json!({
            "parentAgentId": parent_agent_id.to_string(),
            "childAgentId": child_agent_id.to_string(),
        }),
        AgentEvent::SubagentComplete {
            parent_agent_id,
            child_agent_id,
            result,
            ..
        } => serde_json::json!({
            "parentAgentId": parent_agent_id.to_string(),
            "childAgentId": child_agent_id.to_string(),
            "result": result,
        }),
        AgentEvent::CompactionStarted { .. } => serde_json::json!({}),
        AgentEvent::CompactionComplete {
            tokens_before,
            tokens_after,
            ..
        } => serde_json::json!({
            "tokensBefore": tokens_before,
            "tokensAfter": tokens_after,
        }),
    };

    WireEvent {
        event_type,
        session_id,
        timestamp,
        data,
    }
}

/// Convert TokenUsage to camelCase wire format.
fn usage_to_camel(usage: &TokenUsage) -> serde_json::Value {
    serde_json::json!({
        "inputTokens": usage.input_tokens,
        "outputTokens": usage.output_tokens,
        "cacheReadTokens": usage.cache_read_tokens,
        "cacheCreationTokens": usage.cache_creation_tokens,
    })
}

// ── Step 4: Session response transforms ──────────────────────────────────

/// Convert a SessionRow to iOS camelCase format.
pub fn session_to_ios(session: &SessionRow) -> serde_json::Value {
    let is_active = session.status == SessionStatus::Active;
    let is_archived = session.status == SessionStatus::Archived;
    serde_json::json!({
        "sessionId": session.id.to_string(),
        "workspaceId": session.workspace_id.to_string(),
        "model": session.model,
        "provider": session.provider,
        "workingDirectory": session.working_directory,
        "title": session.title,
        "isActive": is_active,
        "isArchived": is_archived,
        "inputTokens": session.tokens.total_input_tokens,
        "outputTokens": session.tokens.total_output_tokens,
        // iOS SessionInfo fields
        "messageCount": session.tokens.turn_count,
        "cost": session.tokens.total_cost_cents / 100.0,
        "lastActivity": session.updated_at,
        "cacheReadTokens": session.tokens.total_cache_read_tokens,
        "cacheCreationTokens": session.tokens.total_cache_creation_tokens,
        "lastTurnInputTokens": session.tokens.last_turn_input_tokens,
        // Backward compat
        "turnCount": session.tokens.turn_count,
        "totalCostCents": session.tokens.total_cost_cents,
        "createdAt": session.created_at,
        "updatedAt": session.updated_at,
    })
}

/// session.create response: minimal shape.
pub fn session_create_response(session: &SessionRow) -> serde_json::Value {
    serde_json::json!({
        "sessionId": session.id.to_string(),
        "model": session.model,
        "createdAt": session.created_at,
    })
}

/// session.list response.
pub fn session_list_response(sessions: &[SessionRow], limit: u32) -> serde_json::Value {
    let items: Vec<serde_json::Value> = sessions.iter().map(session_to_ios).collect();
    let count = items.len();
    serde_json::json!({
        "sessions": items,
        "totalCount": count,
        "hasMore": count as u32 >= limit,
    })
}

/// session.resume response.
pub fn session_resume_response(session: &SessionRow, message_count: usize) -> serde_json::Value {
    serde_json::json!({
        "sessionId": session.id.to_string(),
        "model": session.model,
        "messageCount": message_count,
        "lastActivity": session.updated_at,
    })
}

/// session.fork response.
pub fn session_fork_response(new_session: &SessionRow, source_session_id: &str) -> serde_json::Value {
    serde_json::json!({
        "newSessionId": new_session.id.to_string(),
        "forkedFromSessionId": source_session_id,
        "model": new_session.model,
        "createdAt": new_session.created_at,
    })
}

// ── Step 5: Model / Settings / Events / Context / Agent State transforms ─

/// Convert a ClaudeModelInfo to iOS wire format.
pub fn model_to_ios(model: &tron_llm::models::ClaudeModelInfo) -> serde_json::Value {
    serde_json::json!({
        "id": model.name,
        "name": model.display_name,
        "provider": "anthropic",
        "contextWindow": model.context_window,
        "maxOutputTokens": model.max_output,
        "supportsThinking": model.supports_thinking,
        "supportsAdaptiveThinking": model.supports_adaptive_thinking,
        "supportsEffort": model.supports_effort,
    })
}

/// model.list response.
pub fn model_list_response() -> serde_json::Value {
    let models = tron_llm::models::all_models();
    let items: Vec<serde_json::Value> = models.iter().map(|m| model_to_ios(m)).collect();
    serde_json::json!({
        "models": items,
    })
}

/// Full iOS settings shape with all expected fields.
pub fn default_settings_ios() -> serde_json::Value {
    serde_json::json!({
        "defaultModel": "claude-sonnet-4-5-20250929",
        "maxConcurrentSessions": 5,
        "compaction": {
            "preserveRecentTurns": 3,
            "triggerTokenThreshold": 150000,
        },
        "memory": {
            "ledger": {
                "enabled": true,
            },
            "autoInject": {
                "enabled": true,
                "maxTokens": 4000,
            },
        },
        "rules": {
            "discoverStandaloneFiles": true,
        },
        "tasks": {
            "autoInject": {
                "enabled": true,
            },
        },
        "tools": {
            "web": {
                "fetch": {
                    "timeoutMs": 15000,
                },
                "search": {
                    "enabled": true,
                },
            },
        },
    })
}

/// Map persisted event types from Rust snake_case to iOS dot.notation.
///
/// Rust stores `message_user` (PersistenceEventType serde), iOS expects `message.user`.
/// Special case: `config_model_switched` → `config.model_switch` (iOS drops the "d").
pub fn persisted_event_type_to_ios(rust_type: &str) -> String {
    match rust_type {
        "message_user" => "message.user".into(),
        "message_assistant" => "message.assistant".into(),
        "tool_call" => "tool.call".into(),
        "tool_result" => "tool.result".into(),
        "stream_turn_start" => "stream.turn_start".into(),
        "stream_turn_end" => "stream.turn_end".into(),
        "compact_boundary" => "compact.boundary".into(),
        "compact_summary" => "compact.summary".into(),
        "context_cleared" => "context.cleared".into(),
        "config_model_switched" => "config.model_switch".into(),
        "skill_added" => "skill.added".into(),
        "skill_removed" => "skill.removed".into(),
        "memory_ledger" => "memory.ledger".into(),
        "session_start" => "session.start".into(),
        "session_fork" => "session.fork".into(),
        // Fallback: replace first `_` with `.` for any unmapped types
        other => {
            if let Some(idx) = other.find('_') {
                format!("{}.{}", &other[..idx], &other[idx + 1..])
            } else {
                other.to_string()
            }
        }
    }
}

/// Convert an EventRow to iOS camelCase format.
pub fn event_row_to_ios(event: &EventRow) -> serde_json::Value {
    serde_json::json!({
        "id": event.id.to_string(),
        "sessionId": event.session_id.to_string(),
        "parentId": event.parent_id.as_ref().map(|id| id.to_string()),
        "sequence": event.sequence,
        "depth": event.depth,
        "type": persisted_event_type_to_ios(&event.event_type),
        "timestamp": event.timestamp,
        "payload": event.payload,
        "workspaceId": event.workspace_id.to_string(),
    })
}

/// events.list / events.sync / events.getSince response.
/// Includes fields for all iOS result types: oldestEventId (getHistory), nextCursor (getSince).
pub fn events_list_response(events: &[EventRow]) -> serde_json::Value {
    let items: Vec<serde_json::Value> = events.iter().map(event_row_to_ios).collect();
    let oldest_id = events.first().map(|e| e.id.to_string());
    let newest_ts = events.last().map(|e| e.timestamp.clone());
    serde_json::json!({
        "events": items,
        "hasMore": false,
        "oldestEventId": oldest_id,
        "nextCursor": newest_ts,
    })
}

/// context.get response.
pub fn context_get_response(session: &SessionRow) -> serde_json::Value {
    serde_json::json!({
        "sessionId": session.id.to_string(),
        "totalInputTokens": session.tokens.total_input_tokens,
        "totalOutputTokens": session.tokens.total_output_tokens,
        "totalCacheReadTokens": session.tokens.total_cache_read_tokens,
        "totalCacheCreationTokens": session.tokens.total_cache_creation_tokens,
        "lastTurnInputTokens": session.tokens.last_turn_input_tokens,
        "totalCostCents": session.tokens.total_cost_cents,
        "turnCount": session.tokens.turn_count,
    })
}

/// context.getDetailedSnapshot / context.getSnapshot response.
///
/// iOS `DetailedContextSnapshotResult` expects: currentTokens, contextLimit,
/// usagePercent, thresholdLevel, breakdown, messages, systemPromptContent,
/// toolsContent, addedSkills, rules, memory, sessionMemories, taskContext.
///
/// Since the Rust server doesn't yet have a full context engine, we derive
/// what we can from session token data and return empty/null for the rest.
pub fn context_detailed_snapshot_response(
    session: &SessionRow,
    event_count: usize,
) -> serde_json::Value {
    let model_info = tron_llm::models::find_model(&session.model);
    let context_limit = model_info.map(|m| m.context_window as u64).unwrap_or(200_000);
    let current_tokens = session.tokens.last_turn_input_tokens;
    let usage_pct = if context_limit > 0 {
        (current_tokens as f64 / context_limit as f64) * 100.0
    } else {
        0.0
    };
    let threshold_level = if usage_pct > 80.0 {
        "high"
    } else if usage_pct > 50.0 {
        "medium"
    } else {
        "low"
    };

    serde_json::json!({
        "currentTokens": current_tokens,
        "contextLimit": context_limit,
        "usagePercent": usage_pct,
        "thresholdLevel": threshold_level,
        "breakdown": {
            "systemPrompt": 0,
            "tools": 0,
            "messages": current_tokens,
            "other": 0
        },
        "messages": [],
        "systemPromptContent": "",
        "toolClarificationContent": null,
        "toolsContent": [],
        "addedSkills": [],
        "rules": null,
        "memory": null,
        "sessionMemories": null,
        "taskContext": null,
        // Extra fields iOS may also read
        "eventCount": event_count,
        "sessionId": session.id.to_string(),
        "model": session.model,
    })
}

/// agent.state / agent.getState response.
pub fn agent_state_response(
    is_running: bool,
    current_turn: u32,
    message_count: usize,
    model: &str,
    input_tokens: u64,
    output_tokens: u64,
) -> serde_json::Value {
    serde_json::json!({
        "isRunning": is_running,
        "wasInterrupted": false,
        "currentTurn": current_turn,
        "messageCount": message_count,
        "model": model,
        "tokenUsage": {
            "input": input_tokens,
            "output": output_tokens,
        },
        "tools": [],
    })
}

/// Convert tool call arguments to iOS wire format.
/// iOS expects `input` instead of `arguments` for tool calls.
pub fn tool_call_to_wire(tool_call: &serde_json::Value) -> serde_json::Value {
    let mut wire = tool_call.clone();
    if let Some(args) = wire.as_object_mut() {
        if let Some(arguments) = args.remove("arguments") {
            args.insert("input".to_string(), arguments);
        }
    }
    wire
}

/// Convert iOS tool call wire format back to internal.
/// iOS sends `input` where we expect `arguments`.
pub fn tool_call_from_wire(wire: &serde_json::Value) -> serde_json::Value {
    let mut internal = wire.clone();
    if let Some(obj) = internal.as_object_mut() {
        if let Some(input) = obj.remove("input") {
            obj.insert("arguments".to_string(), input);
        }
    }
    internal
}

/// Add totalCount to a skill list response (iOS expects this).
pub fn add_total_count(mut value: serde_json::Value, count: usize) -> serde_json::Value {
    if let Some(obj) = value.as_object_mut() {
        obj.insert("totalCount".to_string(), serde_json::json!(count));
    }
    value
}

#[cfg(test)]
mod tests {
    use super::*;
    use tron_core::ids::{AgentId, SessionId, ToolCallId};

    // ── normalize_params tests ───────────────────────────────────────

    #[test]
    fn normalize_camel_to_snake() {
        let params = serde_json::json!({"sessionId": "sess_123", "workingDirectory": "/tmp"});
        let normalized = normalize_params(&params);
        assert_eq!(normalized["session_id"], "sess_123");
        assert_eq!(normalized["working_directory"], "/tmp");
        assert!(normalized.get("sessionId").is_none());
        assert!(normalized.get("workingDirectory").is_none());
    }

    #[test]
    fn normalize_passes_through_snake_case() {
        let params = serde_json::json!({"session_id": "sess_123", "limit": 10});
        let normalized = normalize_params(&params);
        assert_eq!(normalized["session_id"], "sess_123");
        assert_eq!(normalized["limit"], 10);
    }

    #[test]
    fn normalize_handles_both_present() {
        let params = serde_json::json!({"sessionId": "camel", "session_id": "snake"});
        let normalized = normalize_params(&params);
        assert_eq!(normalized["session_id"], "snake");
    }

    #[test]
    fn normalize_handles_empty_object() {
        let normalized = normalize_params(&serde_json::json!({}));
        assert!(normalized.as_object().unwrap().is_empty());
    }

    #[test]
    fn normalize_handles_non_object() {
        let normalized = normalize_params(&serde_json::json!("string"));
        assert_eq!(normalized, serde_json::json!("string"));
    }

    #[test]
    fn normalize_all_known_keys() {
        let params = serde_json::json!({
            "sessionId": "s", "workingDirectory": "/w", "contextFiles": [],
            "reasoningLevel": "high", "beforeEventId": "e", "afterSequence": 1,
            "afterTimestamp": "t", "deviceToken": "dt", "toolCallId": "tc",
            "mimeType": "text/plain", "fileName": "f.txt"
        });
        let n = normalize_params(&params);
        assert!(n.get("session_id").is_some());
        assert!(n.get("working_directory").is_some());
        assert!(n.get("context_files").is_some());
        assert!(n.get("reasoning_level").is_some());
        assert!(n.get("before_event_id").is_some());
        assert!(n.get("after_sequence").is_some());
        assert!(n.get("after_timestamp").is_some());
        assert!(n.get("device_token").is_some());
        assert!(n.get("tool_call_id").is_some());
        assert!(n.get("mime_type").is_some());
        assert!(n.get("file_name").is_some());
    }

    // ── wire_event_type tests ────────────────────────────────────────

    #[test]
    fn wire_event_type_mapping() {
        assert_eq!(wire_event_type("turn_start"), "agent.turn_start");
        assert_eq!(wire_event_type("text_delta"), "agent.text_delta");
        assert_eq!(wire_event_type("thinking_delta"), "agent.thinking_delta");
        assert_eq!(wire_event_type("tool_start"), "agent.tool_start");
        assert_eq!(wire_event_type("tool_end"), "agent.tool_end");
        assert_eq!(wire_event_type("turn_complete"), "agent.turn_end");
        assert_eq!(wire_event_type("agent_complete"), "agent.complete");
        assert_eq!(wire_event_type("agent_ready"), "agent.ready");
        assert_eq!(wire_event_type("subagent_spawned"), "agent.subagent_spawned");
        assert_eq!(wire_event_type("subagent_complete"), "agent.subagent_completed");
        assert_eq!(wire_event_type("compaction_started"), "agent.compaction_started");
        assert_eq!(wire_event_type("compaction_complete"), "agent.compaction");
    }

    // ── agent_event_to_wire tests ────────────────────────────────────

    #[test]
    fn wire_event_has_envelope_structure() {
        let event = AgentEvent::TextDelta {
            session_id: SessionId::new(),
            agent_id: AgentId::new(),
            delta: "hello".into(),
        };
        let wire = agent_event_to_wire(&event);
        let json = serde_json::to_value(&wire).unwrap();

        assert_eq!(json["type"], "agent.text_delta");
        assert!(json["sessionId"].is_string());
        assert!(json["timestamp"].is_string());
        assert_eq!(json["data"]["delta"], "hello");

        // No snake_case at top level
        assert!(json.get("session_id").is_none());
        assert!(json.get("agent_id").is_none());
    }

    #[test]
    fn wire_turn_end_has_camel_case_token_usage() {
        let event = AgentEvent::TurnComplete {
            session_id: SessionId::new(),
            agent_id: AgentId::new(),
            turn: 1,
            usage: TokenUsage {
                input_tokens: 100,
                output_tokens: 50,
                cache_read_tokens: 20,
                ..Default::default()
            },
        };
        let wire = agent_event_to_wire(&event);
        let json = serde_json::to_value(&wire).unwrap();

        assert_eq!(json["type"], "agent.turn_end");
        assert_eq!(json["data"]["turn"], 1);
        assert_eq!(json["data"]["tokenUsage"]["inputTokens"], 100);
        assert_eq!(json["data"]["tokenUsage"]["outputTokens"], 50);
        assert_eq!(json["data"]["tokenUsage"]["cacheReadTokens"], 20);
    }

    #[test]
    fn wire_agent_complete_and_ready_types() {
        let sid = SessionId::new();
        let aid = AgentId::new();
        let complete = agent_event_to_wire(&AgentEvent::AgentComplete {
            session_id: sid.clone(),
            agent_id: aid.clone(),
        });
        let ready = agent_event_to_wire(&AgentEvent::AgentReady {
            session_id: sid,
            agent_id: aid,
        });
        assert_eq!(
            serde_json::to_value(&complete).unwrap()["type"],
            "agent.complete"
        );
        assert_eq!(
            serde_json::to_value(&ready).unwrap()["type"],
            "agent.ready"
        );
    }

    #[test]
    fn wire_tool_events_camel_case() {
        let event = AgentEvent::ToolStart {
            session_id: SessionId::new(),
            agent_id: AgentId::new(),
            tool_call_id: ToolCallId::new(),
            tool_name: "Read".into(),
        };
        let json = serde_json::to_value(&agent_event_to_wire(&event)).unwrap();
        assert!(json["data"]["toolCallId"].is_string());
        assert_eq!(json["data"]["toolName"], "Read");
    }

    #[test]
    fn wire_compaction_events() {
        let event = AgentEvent::CompactionComplete {
            session_id: SessionId::new(),
            tokens_before: 100000,
            tokens_after: 50000,
        };
        let json = serde_json::to_value(&agent_event_to_wire(&event)).unwrap();
        assert_eq!(json["type"], "agent.compaction");
        assert_eq!(json["data"]["tokensBefore"], 100000);
        assert_eq!(json["data"]["tokensAfter"], 50000);
    }

    #[test]
    fn all_event_types_have_envelope() {
        let sid = SessionId::new();
        let aid = AgentId::new();
        let tid = ToolCallId::new();
        let events = vec![
            AgentEvent::TurnStart {
                session_id: sid.clone(),
                agent_id: aid.clone(),
                turn: 1,
            },
            AgentEvent::TextDelta {
                session_id: sid.clone(),
                agent_id: aid.clone(),
                delta: "x".into(),
            },
            AgentEvent::ThinkingDelta {
                session_id: sid.clone(),
                agent_id: aid.clone(),
                delta: "y".into(),
            },
            AgentEvent::ToolStart {
                session_id: sid.clone(),
                agent_id: aid.clone(),
                tool_call_id: tid.clone(),
                tool_name: "R".into(),
            },
            AgentEvent::ToolEnd {
                session_id: sid.clone(),
                agent_id: aid.clone(),
                tool_call_id: tid,
                result_preview: "ok".into(),
                duration_ms: 10,
            },
            AgentEvent::TurnComplete {
                session_id: sid.clone(),
                agent_id: aid.clone(),
                turn: 1,
                usage: TokenUsage::default(),
            },
            AgentEvent::AgentComplete {
                session_id: sid.clone(),
                agent_id: aid.clone(),
            },
            AgentEvent::AgentReady {
                session_id: sid.clone(),
                agent_id: aid.clone(),
            },
            AgentEvent::SubagentSpawned {
                parent_session_id: sid.clone(),
                parent_agent_id: aid.clone(),
                child_agent_id: AgentId::new(),
            },
            AgentEvent::SubagentComplete {
                parent_session_id: sid.clone(),
                parent_agent_id: aid.clone(),
                child_agent_id: AgentId::new(),
                result: "done".into(),
            },
            AgentEvent::CompactionStarted {
                session_id: sid.clone(),
            },
            AgentEvent::CompactionComplete {
                session_id: sid,
                tokens_before: 100,
                tokens_after: 50,
            },
        ];
        for event in events {
            let wire = agent_event_to_wire(&event);
            let json = serde_json::to_value(&wire).unwrap();
            assert!(json["type"].is_string(), "Missing type");
            assert!(
                json["sessionId"].is_string(),
                "Missing sessionId for {:?}",
                json["type"]
            );
            assert!(
                json["timestamp"].is_string(),
                "Missing timestamp for {:?}",
                json["type"]
            );
            assert!(
                json["data"].is_object(),
                "Missing data for {:?}",
                json["type"]
            );
        }
    }

    // ── Session transform tests ──────────────────────────────────────

    fn make_test_session() -> SessionRow {
        use tron_core::ids::WorkspaceId;
        use tron_core::tokens::AccumulatedTokens;
        SessionRow {
            id: SessionId::new(),
            workspace_id: WorkspaceId::new(),
            head_event_id: None,
            root_event_id: None,
            status: SessionStatus::Active,
            model: "claude-sonnet-4-5-20250929".into(),
            provider: "anthropic".into(),
            working_directory: "/tmp/test".into(),
            title: Some("Test Session".into()),
            tokens: AccumulatedTokens {
                total_input_tokens: 1000,
                total_output_tokens: 500,
                total_cache_read_tokens: 200,
                total_cache_creation_tokens: 50,
                last_turn_input_tokens: 100,
                total_cost_cents: 0.5,
                turn_count: 3,
            },
            created_at: "2026-02-15T12:00:00Z".into(),
            updated_at: "2026-02-15T12:30:00Z".into(),
        }
    }

    #[test]
    fn session_to_ios_camel_case() {
        let session = make_test_session();
        let wire = session_to_ios(&session);
        assert_eq!(wire["sessionId"], session.id.to_string());
        assert_eq!(wire["model"], "claude-sonnet-4-5-20250929");
        assert!(wire["isActive"].is_boolean());
        assert!(wire["inputTokens"].is_number());
        assert!(wire["createdAt"].is_string());
        // Must NOT have snake_case keys
        assert!(wire.get("session_id").is_none());
        assert!(wire.get("workspace_id").is_none());
        assert!(wire.get("working_directory").is_none());
    }

    #[test]
    fn session_create_response_shape() {
        let session = make_test_session();
        let wire = session_create_response(&session);
        assert!(wire["sessionId"].is_string());
        assert!(wire["model"].is_string());
        assert!(wire["createdAt"].is_string());
    }

    #[test]
    fn session_list_response_shape() {
        let sessions = vec![make_test_session(), make_test_session()];
        let wire = session_list_response(&sessions, 50);
        assert_eq!(wire["sessions"].as_array().unwrap().len(), 2);
        assert_eq!(wire["totalCount"], 2);
        assert!(wire["sessions"][0]["sessionId"].is_string());
        assert!(wire["sessions"][0]["isActive"].is_boolean());
    }

    #[test]
    fn session_resume_response_shape() {
        let session = make_test_session();
        let wire = session_resume_response(&session, 12);
        assert!(wire["sessionId"].is_string());
        assert_eq!(wire["messageCount"], 12);
        assert!(wire["model"].is_string());
        assert!(wire["lastActivity"].is_string());
    }

    #[test]
    fn session_fork_response_shape() {
        let session = make_test_session();
        let wire = session_fork_response(&session, "sess_source_123");
        assert!(wire["newSessionId"].is_string());
        assert_eq!(wire["forkedFromSessionId"], "sess_source_123");
    }

    #[test]
    fn session_archived_flag() {
        let mut session = make_test_session();
        session.status = SessionStatus::Archived;
        let wire = session_to_ios(&session);
        assert_eq!(wire["isActive"], false);
        assert_eq!(wire["isArchived"], true);
    }

    // ── Model transform tests ────────────────────────────────────────

    #[test]
    fn model_to_ios_shape() {
        let model = &tron_llm::models::CLAUDE_SONNET_4_5;
        let wire = model_to_ios(model);
        assert_eq!(wire["id"], "claude-sonnet-4-5-20250929");
        assert_eq!(wire["name"], "Claude Sonnet 4.5");
        assert_eq!(wire["provider"], "anthropic");
        assert_eq!(wire["contextWindow"], 200000);
        assert_eq!(wire["maxOutputTokens"], 64000);
        assert_eq!(wire["supportsThinking"], true);
    }

    #[test]
    fn model_list_response_shape() {
        let wire = model_list_response();
        assert!(wire["models"].is_array());
        assert!(!wire["models"].as_array().unwrap().is_empty());
        assert!(wire["models"][0]["id"].is_string());
    }

    // ── Settings transform tests ─────────────────────────────────────

    #[test]
    fn default_settings_has_all_ios_fields() {
        let settings = default_settings_ios();
        assert!(settings["defaultModel"].is_string());
        assert!(settings["maxConcurrentSessions"].is_number());
        assert!(settings["compaction"]["preserveRecentTurns"].is_number());
        assert!(settings["compaction"]["triggerTokenThreshold"].is_number());
        assert!(settings["memory"]["ledger"]["enabled"].is_boolean());
        assert!(settings["memory"]["autoInject"]["enabled"].is_boolean());
        assert!(settings["rules"]["discoverStandaloneFiles"].is_boolean());
        assert!(settings["tasks"]["autoInject"]["enabled"].is_boolean());
        assert!(settings["tools"]["web"]["fetch"]["timeoutMs"].is_number());
    }

    // ── Persisted event type mapping tests ─────────────────────────────

    #[test]
    fn persisted_event_type_all_known_mappings() {
        assert_eq!(persisted_event_type_to_ios("message_user"), "message.user");
        assert_eq!(persisted_event_type_to_ios("message_assistant"), "message.assistant");
        assert_eq!(persisted_event_type_to_ios("tool_call"), "tool.call");
        assert_eq!(persisted_event_type_to_ios("tool_result"), "tool.result");
        assert_eq!(persisted_event_type_to_ios("stream_turn_start"), "stream.turn_start");
        assert_eq!(persisted_event_type_to_ios("stream_turn_end"), "stream.turn_end");
        assert_eq!(persisted_event_type_to_ios("compact_boundary"), "compact.boundary");
        assert_eq!(persisted_event_type_to_ios("compact_summary"), "compact.summary");
        assert_eq!(persisted_event_type_to_ios("context_cleared"), "context.cleared");
        assert_eq!(persisted_event_type_to_ios("config_model_switched"), "config.model_switch");
        assert_eq!(persisted_event_type_to_ios("skill_added"), "skill.added");
        assert_eq!(persisted_event_type_to_ios("skill_removed"), "skill.removed");
        assert_eq!(persisted_event_type_to_ios("memory_ledger"), "memory.ledger");
        assert_eq!(persisted_event_type_to_ios("session_start"), "session.start");
        assert_eq!(persisted_event_type_to_ios("session_fork"), "session.fork");
    }

    #[test]
    fn persisted_event_type_unknown_uses_fallback() {
        // Unknown types: replace first `_` with `.`
        assert_eq!(persisted_event_type_to_ios("foo_bar"), "foo.bar");
        assert_eq!(persisted_event_type_to_ios("custom_event_type"), "custom.event_type");
        // No underscore at all — pass through
        assert_eq!(persisted_event_type_to_ios("nounderscore"), "nounderscore");
    }

    // ── Event row transform tests ────────────────────────────────────

    #[test]
    fn event_row_to_ios_converts_event_type() {
        use tron_core::ids::{EventId, WorkspaceId};
        let event = EventRow {
            id: EventId::new(),
            session_id: SessionId::new(),
            parent_id: None,
            sequence: 1,
            depth: 0,
            event_type: "message_user".into(),
            timestamp: "2026-02-15T12:00:00Z".into(),
            payload: serde_json::json!({"role": "user"}),
            workspace_id: WorkspaceId::new(),
        };
        let wire = event_row_to_ios(&event);
        // Must be dot.notation, not snake_case
        assert_eq!(wire["type"], "message.user");
        assert!(wire["sessionId"].is_string());
        assert!(wire["parentId"].is_null() || wire["parentId"].is_string());
        assert!(wire["workspaceId"].is_string());
        assert!(wire.get("session_id").is_none());
    }

    #[test]
    fn event_row_to_ios_all_types_converted() {
        use tron_core::ids::{EventId, WorkspaceId};
        let types = vec![
            ("message_user", "message.user"),
            ("message_assistant", "message.assistant"),
            ("tool_call", "tool.call"),
            ("tool_result", "tool.result"),
            ("compact_boundary", "compact.boundary"),
            ("compact_summary", "compact.summary"),
            ("session_start", "session.start"),
            ("memory_ledger", "memory.ledger"),
            ("config_model_switched", "config.model_switch"),
        ];
        for (rust_type, ios_type) in types {
            let event = EventRow {
                id: EventId::new(),
                session_id: SessionId::new(),
                parent_id: None,
                sequence: 0,
                depth: 0,
                event_type: rust_type.into(),
                timestamp: "2026-02-15T12:00:00Z".into(),
                payload: serde_json::json!({}),
                workspace_id: WorkspaceId::new(),
            };
            let wire = event_row_to_ios(&event);
            assert_eq!(wire["type"], ios_type, "Failed for {rust_type}");
        }
    }

    #[test]
    fn events_list_response_shape() {
        use tron_core::ids::{EventId, WorkspaceId};
        let events = vec![EventRow {
            id: EventId::new(),
            session_id: SessionId::new(),
            parent_id: None,
            sequence: 1,
            depth: 0,
            event_type: "text_delta".into(),
            timestamp: "2026-02-15T12:00:00Z".into(),
            payload: serde_json::json!({}),
            workspace_id: WorkspaceId::new(),
        }];
        let wire = events_list_response(&events);
        assert!(wire["events"].is_array());
        assert!(wire["hasMore"].is_boolean());
        assert!(wire["oldestEventId"].is_string() || wire["oldestEventId"].is_null());
    }

    // ── Context transform tests ──────────────────────────────────────

    #[test]
    fn context_get_response_camel_case() {
        let session = make_test_session();
        let wire = context_get_response(&session);
        assert!(wire["sessionId"].is_string());
        assert!(wire["totalInputTokens"].is_number());
        assert!(wire["turnCount"].is_number());
        assert!(wire.get("session_id").is_none());
    }

    #[test]
    fn context_detailed_snapshot_has_ios_shape() {
        let session = make_test_session();
        let wire = context_detailed_snapshot_response(&session, 10);

        // Required fields for iOS DetailedContextSnapshotResult
        assert!(wire["currentTokens"].is_number());
        assert!(wire["contextLimit"].is_number());
        assert!(wire["usagePercent"].is_number());
        assert!(wire["thresholdLevel"].is_string());
        assert!(wire["breakdown"].is_object());
        assert!(wire["messages"].is_array());
        assert!(wire["systemPromptContent"].is_string());
        assert!(wire["toolsContent"].is_array());
        assert!(wire["addedSkills"].is_array());

        // Nullable fields
        assert!(wire.get("rules").is_some());
        assert!(wire.get("memory").is_some());
        assert!(wire.get("sessionMemories").is_some());
        assert!(wire.get("taskContext").is_some());

        // Breakdown sub-fields
        let bd = &wire["breakdown"];
        assert!(bd["systemPrompt"].is_number());
        assert!(bd["tools"].is_number());
        assert!(bd["messages"].is_number());
    }

    // ── Agent state transform tests ──────────────────────────────────

    #[test]
    fn agent_state_response_full_shape() {
        let wire = agent_state_response(false, 0, 5, "claude-sonnet-4-5-20250929", 1000, 500);
        assert_eq!(wire["isRunning"], false);
        assert_eq!(wire["currentTurn"], 0);
        assert_eq!(wire["messageCount"], 5);
        assert_eq!(wire["model"], "claude-sonnet-4-5-20250929");
        assert_eq!(wire["tokenUsage"]["input"], 1000);
        assert_eq!(wire["tokenUsage"]["output"], 500);
        assert!(wire["tools"].is_array());
        assert!(wire.get("wasInterrupted").is_some());
    }

    // ── Preserved existing tests ─────────────────────────────────────

    #[test]
    fn tool_call_arguments_to_input() {
        let tc = serde_json::json!({
            "name": "Read",
            "arguments": {"file_path": "/tmp/test.txt"}
        });
        let wire = tool_call_to_wire(&tc);
        assert!(wire.get("arguments").is_none());
        assert_eq!(wire["input"]["file_path"], "/tmp/test.txt");
    }

    #[test]
    fn tool_call_input_to_arguments() {
        let wire = serde_json::json!({
            "name": "Read",
            "input": {"file_path": "/tmp/test.txt"}
        });
        let internal = tool_call_from_wire(&wire);
        assert!(internal.get("input").is_none());
        assert_eq!(internal["arguments"]["file_path"], "/tmp/test.txt");
    }

    #[test]
    fn add_total_count_to_response() {
        let resp = serde_json::json!({"skills": ["commit", "review"]});
        let with_count = add_total_count(resp, 2);
        assert_eq!(with_count["totalCount"], 2);
        assert_eq!(with_count["skills"].as_array().unwrap().len(), 2);
    }

    #[test]
    fn session_to_ios_has_all_ios_session_info_fields() {
        let session = make_test_session();
        let wire = session_to_ios(&session);

        // Non-optional in iOS — MUST exist
        assert!(wire["messageCount"].is_number(), "messageCount missing");
        assert_eq!(wire["messageCount"], 3);

        // Optional but expected
        assert!(wire["cost"].is_number(), "cost missing");
        let cost = wire["cost"].as_f64().unwrap();
        assert!((cost - 0.005).abs() < 0.0001, "cost should be 0.005, got {cost}");

        assert!(wire["lastActivity"].is_string(), "lastActivity missing");
        assert_eq!(wire["lastActivity"], "2026-02-15T12:30:00Z");

        assert!(wire["cacheReadTokens"].is_number(), "cacheReadTokens missing");
        assert_eq!(wire["cacheReadTokens"], 200);

        assert!(wire["cacheCreationTokens"].is_number(), "cacheCreationTokens missing");
        assert_eq!(wire["cacheCreationTokens"], 50);

        assert!(wire["lastTurnInputTokens"].is_number(), "lastTurnInputTokens missing");
        assert_eq!(wire["lastTurnInputTokens"], 100);

        // Backward compat fields still present
        assert!(wire["turnCount"].is_number());
        assert!(wire["totalCostCents"].is_number());
        assert!(wire["updatedAt"].is_string());
    }

    #[test]
    fn session_list_response_has_more_field() {
        let sessions = vec![make_test_session(), make_test_session()];
        let wire = session_list_response(&sessions, 50);
        assert_eq!(wire["hasMore"], false); // 2 < 50

        let wire = session_list_response(&sessions, 2);
        assert_eq!(wire["hasMore"], true); // 2 >= 2
    }

    #[test]
    fn normalize_include_archived() {
        let params = serde_json::json!({"includeArchived": true});
        let n = normalize_params(&params);
        assert_eq!(n["include_archived"], true);
        assert!(n.get("includeArchived").is_none());
    }
}
