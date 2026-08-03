use crate::shared::protocol::content::ToolResultContent;
use crate::shared::protocol::events::{ToolEventIdentity, TronEvent};
use crate::shared::protocol::model_tools::ToolResultBody;
use serde_json::json;

use super::routed::{ProjectedEvent, session_scoped, set_opt};

fn set_identity(data: &mut serde_json::Value, identity: &ToolEventIdentity) {
    if identity.is_empty() {
        return;
    }
    if let Ok(value) = serde_json::to_value(identity)
        && let Some(fields) = value.as_object()
        && let Some(target) = data.as_object_mut()
    {
        target.extend(fields.clone());
    }
}

pub(super) fn convert(event: &TronEvent) -> Option<ProjectedEvent> {
    match event {
        TronEvent::ToolInvocationStarted {
            tool_name,
            invocation_id,
            arguments,
            tool_identity,
            ..
        } => {
            let mut data = json!({
                "toolName": tool_name,
                "invocationId": invocation_id,
            });
            set_opt(&mut data, "arguments", arguments);
            set_identity(&mut data, tool_identity);
            Some(session_scoped(event, "tool.invocation.started", Some(data)))
        }
        TronEvent::ToolInvocationCompleted {
            tool_name,
            invocation_id,
            duration,
            is_error,
            result,
            tool_identity,
            ..
        } => {
            let result_is_error = is_error.unwrap_or_else(|| {
                result
                    .as_ref()
                    .and_then(|tool_result| tool_result.is_error)
                    .unwrap_or(false)
            });
            let mut data = json!({
                "toolName": tool_name,
                "invocationId": invocation_id,
                "duration": duration,
                "isError": result_is_error,
                "content": "",
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
                data["content"] = json!(result_text);
                if let Some(details) = &tool_result.details {
                    data["details"] = details.clone();
                }
            }
            set_identity(&mut data, tool_identity);
            Some(session_scoped(
                event,
                "tool.invocation.completed",
                Some(data),
            ))
        }
        TronEvent::ToolInvocationOutput {
            invocation_id,
            update,
            ..
        } => Some(session_scoped(
            event,
            "tool.invocation.output",
            Some(json!({
                "invocationId": invocation_id,
                "output": update,
            })),
        )),
        TronEvent::ToolInvocationProgress {
            invocation_id,
            tool_name,
            message,
            percent,
            tool_identity,
            ..
        } => {
            let mut data = json!({ "invocationId": invocation_id });
            set_opt(&mut data, "toolName", tool_name);
            set_opt(&mut data, "message", message);
            set_opt(&mut data, "percent", percent);
            set_identity(&mut data, tool_identity);
            Some(session_scoped(
                event,
                "tool.invocation.progress",
                Some(data),
            ))
        }
        TronEvent::ToolInvocationBatch {
            tool_invocations, ..
        } => Some(session_scoped(
            event,
            "tool.invocation.batch",
            Some(json!({ "toolInvocations": tool_invocations })),
        )),
        TronEvent::ToolInvocationArgumentDelta {
            invocation_id,
            tool_name,
            arguments_delta,
            ..
        } => {
            let mut data = json!({
                "invocationId": invocation_id,
                "argumentsDelta": arguments_delta,
            });
            set_opt(&mut data, "toolName", tool_name);
            Some(session_scoped(
                event,
                "tool.invocation.arguments_delta",
                Some(data),
            ))
        }
        TronEvent::ToolInvocationGenerating {
            invocation_id,
            tool_name,
            tool_identity,
            ..
        } => {
            let mut data = json!({
                "invocationId": invocation_id,
                "toolName": tool_name,
            });
            set_identity(&mut data, tool_identity);
            Some(session_scoped(
                event,
                "tool.invocation.generating",
                Some(data),
            ))
        }
        _ => None,
    }
}
