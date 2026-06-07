use crate::shared::content::CapabilityResultContent;
use crate::shared::events::{CapabilityEventIdentity, TronEvent};
use crate::shared::model_capabilities::CapabilityResultBody;
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
            model_primitive_name,
            invocation_id,
            arguments,
            capability_identity,
            ..
        } => {
            let mut data = json!({
                "modelPrimitiveName": model_primitive_name,
                "invocationId": invocation_id,
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
            model_primitive_name,
            invocation_id,
            duration,
            is_error,
            result,
            capability_identity,
            ..
        } => {
            let result_is_error = is_error.unwrap_or_else(|| {
                result
                    .as_ref()
                    .and_then(|capability_result| capability_result.is_error)
                    .unwrap_or(false)
            });
            let mut data = json!({
                "modelPrimitiveName": model_primitive_name,
                "invocationId": invocation_id,
                "duration": duration,
                "isError": result_is_error,
                "content": "",
            });
            if let Some(capability_result) = result {
                let result_text = match &capability_result.content {
                    CapabilityResultBody::Text(text) => text.clone(),
                    CapabilityResultBody::Blocks(blocks) => blocks
                        .iter()
                        .filter_map(|block| match block {
                            CapabilityResultContent::Text { text } => Some(text.as_str()),
                            CapabilityResultContent::Image { .. } => None,
                        })
                        .collect::<Vec<_>>()
                        .join("\n"),
                };
                data["content"] = json!(result_text);
                if let Some(details) = &capability_result.details {
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
            invocation_id,
            update,
            ..
        } => Some(session_scoped(
            event,
            "capability.invocation.output",
            Some(json!({
                "invocationId": invocation_id,
                "output": update,
            })),
        )),
        TronEvent::CapabilityInvocationProgress {
            invocation_id,
            message,
            percent,
            capability_identity,
            ..
        } => {
            let mut data = json!({ "invocationId": invocation_id });
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
            invocation_id,
            model_primitive_name,
            requested_contract_id,
            requested_implementation_id,
            requested_function_id,
            capability_identity,
            ..
        } => {
            let mut data = json!({
                "invocationId": invocation_id,
                "modelPrimitiveName": model_primitive_name,
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
        TronEvent::CapabilityInvocationBatch {
            capability_invocations,
            ..
        } => Some(session_scoped(
            event,
            "capability.invocation.batch",
            Some(json!({ "capabilityInvocations": capability_invocations })),
        )),
        TronEvent::CapabilityInvocationArgumentDelta {
            invocation_id,
            model_primitive_name,
            arguments_delta,
            ..
        } => {
            let mut data = json!({
                "invocationId": invocation_id,
                "argumentsDelta": arguments_delta,
            });
            set_opt(&mut data, "modelPrimitiveName", model_primitive_name);
            Some(session_scoped(
                event,
                "capability.invocation.arguments_delta",
                Some(data),
            ))
        }
        TronEvent::CapabilityInvocationGenerating {
            invocation_id,
            model_primitive_name,
            capability_identity,
            ..
        } => {
            let mut data = json!({
                "invocationId": invocation_id,
                "modelPrimitiveName": model_primitive_name,
            });
            set_identity(&mut data, capability_identity);
            Some(session_scoped(
                event,
                "capability.invocation.generating",
                Some(data),
            ))
        }
        _ => None,
    }
}
