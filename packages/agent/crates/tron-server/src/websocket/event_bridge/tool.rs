use serde_json::json;
use tron_core::content::ToolResultContent;
use tron_core::events::TronEvent;
use tron_core::tools::ToolResultBody;

use super::routed::{BridgedEvent, session_scoped, set_opt};

pub(super) fn convert(event: &TronEvent) -> Option<BridgedEvent> {
    match event {
        TronEvent::ToolExecutionStart {
            tool_name,
            tool_call_id,
            arguments,
            ..
        } => {
            let mut data = json!({
                "toolName": tool_name,
                "toolCallId": tool_call_id,
            });
            set_opt(&mut data, "arguments", arguments);
            Some(session_scoped(event, "agent.tool_start", Some(data)))
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
            let mut data = json!({
                "toolName": tool_name,
                "toolCallId": tool_call_id,
                "duration": duration,
                "success": success,
            });
            if let Some(tool_result) = result {
                let result_text = match &tool_result.content {
                    ToolResultBody::Text(text) => text.clone(),
                    ToolResultBody::Blocks(blocks) => blocks
                        .iter()
                        .filter_map(|block| match block {
                            ToolResultContent::Text { text } => Some(text.as_str()),
                            ToolResultContent::Image { .. } => None,
                        })
                        .collect::<Vec<_>>()
                        .join("\n"),
                };
                if success {
                    data["output"] = json!(result_text);
                } else {
                    data["error"] = json!(result_text);
                }
                if let Some(details) = &tool_result.details {
                    data["details"] = details.clone();
                }
            }
            Some(session_scoped(event, "agent.tool_end", Some(data)))
        }
        TronEvent::ToolExecutionUpdate {
            tool_call_id,
            update,
            ..
        } => Some(session_scoped(
            event,
            "agent.tool_output",
            Some(json!({
                "toolCallId": tool_call_id,
                "output": update,
            })),
        )),
        TronEvent::ToolUseBatch { tool_calls, .. } => Some(session_scoped(
            event,
            "agent.tool_use_batch",
            Some(json!({ "toolCalls": tool_calls })),
        )),
        TronEvent::ToolCallArgumentDelta {
            tool_call_id,
            tool_name,
            arguments_delta,
            ..
        } => {
            let mut data = json!({
                "toolCallId": tool_call_id,
                "argumentsDelta": arguments_delta,
            });
            set_opt(&mut data, "toolName", tool_name);
            Some(session_scoped(event, "agent.toolcall_delta", Some(data)))
        }
        TronEvent::ToolCallGenerating {
            tool_call_id,
            tool_name,
            ..
        } => Some(session_scoped(
            event,
            "agent.tool_generating",
            Some(json!({
                "toolCallId": tool_call_id,
                "toolName": tool_name,
            })),
        )),
        _ => None,
    }
}
