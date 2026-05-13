use crate::shared::content::ToolResultContent;
use crate::shared::events::{CapabilityEventIdentity, TronEvent};
use crate::shared::tools::ToolResultBody;
use serde_json::json;

use super::routed::{ProjectedEvent, session_scoped, set_opt};

fn set_identity(data: &mut serde_json::Value, identity: &CapabilityEventIdentity) {
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
        TronEvent::CapabilityInvocationStarted {
            tool_name,
            tool_call_id,
            arguments,
            capability_identity,
            ..
        } => {
            let mut data = json!({
                "modelToolName": tool_name,
                "invocationId": tool_call_id,
            });
            set_opt(&mut data, "arguments", arguments);
            set_identity(&mut data, capability_identity);
            Some(session_scoped(
                event,
                "capability.invocation.started",
                Some(data),
            ))
        }
        TronEvent::CapabilityInvocationCompleted {
            tool_name,
            tool_call_id,
            duration,
            is_error,
            result,
            capability_identity,
            ..
        } => {
            let success = !is_error.unwrap_or(false);
            let mut data = json!({
                "modelToolName": tool_name,
                "invocationId": tool_call_id,
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
            set_identity(&mut data, capability_identity);
            Some(session_scoped(
                event,
                "capability.invocation.completed",
                Some(data),
            ))
        }
        TronEvent::CapabilityInvocationOutput {
            tool_call_id,
            update,
            ..
        } => Some(session_scoped(
            event,
            "capability.invocation.output",
            Some(json!({
                "invocationId": tool_call_id,
                "output": update,
            })),
        )),
        TronEvent::CapabilityInvocationProgress {
            tool_call_id,
            message,
            percent,
            capability_identity,
            ..
        } => {
            let mut data = json!({ "invocationId": tool_call_id });
            set_opt(&mut data, "message", message);
            set_opt(&mut data, "percent", percent);
            set_identity(&mut data, capability_identity);
            Some(session_scoped(
                event,
                "capability.invocation.progress",
                Some(data),
            ))
        }
        TronEvent::CapabilityResolution {
            tool_call_id,
            model_tool_name,
            requested_contract_id,
            requested_implementation_id,
            requested_function_id,
            capability_identity,
            ..
        } => {
            let mut data = json!({
                "invocationId": tool_call_id,
                "modelToolName": model_tool_name,
            });
            set_opt(&mut data, "requestedContractId", requested_contract_id);
            set_opt(
                &mut data,
                "requestedImplementationId",
                requested_implementation_id,
            );
            set_opt(&mut data, "requestedFunctionId", requested_function_id);
            set_identity(&mut data, capability_identity);
            Some(session_scoped(event, "capability.resolution", Some(data)))
        }
        TronEvent::CapabilityInvocationBatch { tool_calls, .. } => Some(session_scoped(
            event,
            "capability.invocation.batch",
            Some(json!({ "toolCalls": tool_calls })),
        )),
        TronEvent::CapabilityInvocationArgumentDelta {
            tool_call_id,
            tool_name,
            arguments_delta,
            ..
        } => {
            let mut data = json!({
                "invocationId": tool_call_id,
                "argumentsDelta": arguments_delta,
            });
            set_opt(&mut data, "modelToolName", tool_name);
            Some(session_scoped(
                event,
                "capability.invocation.arguments_delta",
                Some(data),
            ))
        }
        TronEvent::CapabilityInvocationGenerating {
            tool_call_id,
            tool_name,
            capability_identity,
            ..
        } => {
            let mut data = json!({
                "invocationId": tool_call_id,
                "modelToolName": tool_name,
            });
            set_identity(&mut data, capability_identity);
            Some(session_scoped(
                event,
                "capability.invocation.generating",
                Some(data),
            ))
        }
        TronEvent::JobBackgrounded {
            job_id,
            reason,
            label,
            tool_call_id,
            ..
        } => Some(session_scoped(
            event,
            "agent.job_backgrounded",
            Some(json!({
                "jobId": job_id,
                "reason": reason,
                "label": label,
                "invocationId": tool_call_id,
            })),
        )),
        _ => None,
    }
}
