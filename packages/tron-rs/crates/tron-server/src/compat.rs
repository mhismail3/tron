//! iOS compatibility layer.
//!
//! Translates between clean internal types and the wire format iOS expects.
//! This layer is thin and clearly marked for future removal when iOS is updated.

use serde::Serialize;
use tron_core::events::AgentEvent;
use tron_core::tokens::TokenUsage;

/// Wire format for agent events sent over WebSocket.
/// Matches what iOS expects.
#[derive(Debug, Serialize)]
pub struct WireEvent {
    #[serde(rename = "type")]
    pub event_type: String,
    #[serde(flatten)]
    pub data: serde_json::Value,
}

/// Convert an internal AgentEvent to the wire format.
pub fn agent_event_to_wire(event: &AgentEvent) -> WireEvent {
    let event_type = event.event_type().to_string();

    let data = match event {
        AgentEvent::TurnStart {
            session_id,
            agent_id,
            turn,
        } => serde_json::json!({
            "session_id": session_id,
            "agent_id": agent_id,
            "turn": turn,
        }),
        AgentEvent::TextDelta {
            session_id,
            agent_id,
            delta,
        } => serde_json::json!({
            "session_id": session_id,
            "agent_id": agent_id,
            "delta": delta,
        }),
        AgentEvent::ThinkingDelta {
            session_id,
            agent_id,
            delta,
        } => serde_json::json!({
            "session_id": session_id,
            "agent_id": agent_id,
            "delta": delta,
        }),
        AgentEvent::ToolStart {
            session_id,
            agent_id,
            tool_call_id,
            tool_name,
        } => serde_json::json!({
            "session_id": session_id,
            "agent_id": agent_id,
            "tool_call_id": tool_call_id,
            "tool_name": tool_name,
        }),
        AgentEvent::ToolEnd {
            session_id,
            agent_id,
            tool_call_id,
            result_preview,
            duration_ms,
        } => serde_json::json!({
            "session_id": session_id,
            "agent_id": agent_id,
            "tool_call_id": tool_call_id,
            "result_preview": result_preview,
            "duration_ms": duration_ms,
        }),
        AgentEvent::TurnComplete {
            session_id,
            agent_id,
            turn,
            usage,
        } => {
            let mut data = serde_json::json!({
                "session_id": session_id,
                "agent_id": agent_id,
                "turn": turn,
            });
            // iOS expects token_usage at top level
            if let Some(obj) = usage_to_wire(usage) {
                data["token_usage"] = obj;
            }
            data
        }
        AgentEvent::AgentComplete {
            session_id,
            agent_id,
        } => serde_json::json!({
            "session_id": session_id,
            "agent_id": agent_id,
        }),
        AgentEvent::AgentReady {
            session_id,
            agent_id,
        } => serde_json::json!({
            "session_id": session_id,
            "agent_id": agent_id,
        }),
        AgentEvent::SubagentSpawned {
            parent_session_id,
            parent_agent_id,
            child_agent_id,
        } => serde_json::json!({
            "session_id": parent_session_id,
            "parent_agent_id": parent_agent_id,
            "child_agent_id": child_agent_id,
        }),
        AgentEvent::SubagentComplete {
            parent_session_id,
            parent_agent_id,
            child_agent_id,
            result,
        } => serde_json::json!({
            "session_id": parent_session_id,
            "parent_agent_id": parent_agent_id,
            "child_agent_id": child_agent_id,
            "result": result,
        }),
        AgentEvent::CompactionStarted { session_id } => serde_json::json!({
            "session_id": session_id,
        }),
        AgentEvent::CompactionComplete {
            session_id,
            tokens_before,
            tokens_after,
        } => serde_json::json!({
            "session_id": session_id,
            "tokens_before": tokens_before,
            "tokens_after": tokens_after,
        }),
    };

    WireEvent { event_type, data }
}

/// Convert TokenUsage to wire format.
fn usage_to_wire(usage: &TokenUsage) -> Option<serde_json::Value> {
    Some(serde_json::json!({
        "input_tokens": usage.input_tokens,
        "output_tokens": usage.output_tokens,
        "cache_read_tokens": usage.cache_read_tokens,
        "cache_creation_tokens": usage.cache_creation_tokens,
    }))
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
    use tron_core::ids::{AgentId, SessionId};

    #[test]
    fn turn_start_wire_format() {
        let event = AgentEvent::TurnStart {
            session_id: SessionId::new(),
            agent_id: AgentId::new(),
            turn: 3,
        };
        let wire = agent_event_to_wire(&event);
        assert_eq!(wire.event_type, "turn_start");
        assert_eq!(wire.data["turn"], 3);
    }

    #[test]
    fn agent_complete_then_ready_ordering() {
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

        // iOS relies on these being distinct event types
        assert_eq!(complete.event_type, "agent_complete");
        assert_eq!(ready.event_type, "agent_ready");
    }

    #[test]
    fn turn_complete_includes_token_usage() {
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
        assert_eq!(wire.data["token_usage"]["input_tokens"], 100);
        assert_eq!(wire.data["token_usage"]["output_tokens"], 50);
        assert_eq!(wire.data["token_usage"]["cache_read_tokens"], 20);
    }

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
    fn all_event_types_serialize() {
        let sid = SessionId::new();
        let aid = AgentId::new();
        let tid = tron_core::ids::ToolCallId::new();

        let events = vec![
            AgentEvent::TurnStart { session_id: sid.clone(), agent_id: aid.clone(), turn: 1 },
            AgentEvent::TextDelta { session_id: sid.clone(), agent_id: aid.clone(), delta: "hi".into() },
            AgentEvent::ThinkingDelta { session_id: sid.clone(), agent_id: aid.clone(), delta: "hmm".into() },
            AgentEvent::ToolStart { session_id: sid.clone(), agent_id: aid.clone(), tool_call_id: tid.clone(), tool_name: "Read".into() },
            AgentEvent::ToolEnd { session_id: sid.clone(), agent_id: aid.clone(), tool_call_id: tid, result_preview: "ok".into(), duration_ms: 10 },
            AgentEvent::TurnComplete { session_id: sid.clone(), agent_id: aid.clone(), turn: 1, usage: TokenUsage::default() },
            AgentEvent::AgentComplete { session_id: sid.clone(), agent_id: aid.clone() },
            AgentEvent::AgentReady { session_id: sid.clone(), agent_id: aid.clone() },
            AgentEvent::CompactionStarted { session_id: sid.clone() },
            AgentEvent::CompactionComplete { session_id: sid, tokens_before: 100000, tokens_after: 50000 },
        ];

        for event in events {
            let wire = agent_event_to_wire(&event);
            let json = serde_json::to_string(&wire).unwrap();
            assert!(json.contains("\"type\""), "Missing type field in {json}");
        }
    }
}
