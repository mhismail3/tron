use super::PreparedSessionContext;
use crate::shared::server::errors::CapabilityError;
use serde_json::Value;
use serde_json::json;

pub(super) fn snapshot_response(
    snapshot: &crate::domains::agent::runner::context::types::ContextSnapshot,
) -> Value {
    json!({
        "currentTokens": snapshot.current_tokens,
        "contextLimit": snapshot.context_limit,
        "usagePercent": snapshot.usage_percent,
        "thresholdLevel": snapshot.threshold_level,
        "breakdown": {
            "systemPrompt": snapshot.breakdown.system_prompt,
            "capabilities": snapshot.breakdown.capabilities,
            "environment": snapshot.breakdown.environment,
            "messages": snapshot.breakdown.messages,
            "providerAdjustment": snapshot.breakdown.provider_adjustment,
        },
    })
}

pub(super) fn build_detailed_snapshot_response(
    _session_id: &str,
    prepared: PreparedSessionContext,
) -> Result<Value, CapabilityError> {
    let PreparedSessionContext {
        session,
        context_manager,
    } = prepared;

    let detailed = context_manager.get_detailed_snapshot();
    let composed_system_prompt = build_composed_system_prompt(&context_manager);

    Ok(json!({
        "currentTokens": detailed.snapshot.current_tokens,
        "contextLimit": detailed.snapshot.context_limit,
        "usagePercent": detailed.snapshot.usage_percent,
        "thresholdLevel": detailed.snapshot.threshold_level,
        "breakdown": {
            "systemPrompt": detailed.snapshot.breakdown.system_prompt,
            "capabilities": detailed.snapshot.breakdown.capabilities,
            "environment": detailed.snapshot.breakdown.environment,
            "messages": detailed.snapshot.breakdown.messages,
            "providerAdjustment": detailed.snapshot.breakdown.provider_adjustment,
        },
        "messages": build_detailed_messages(&detailed.messages),
        "systemPromptContent": detailed.system_prompt_content,
        "capabilityClarificationContent": detailed.capability_clarification_content,
        "capabilitiesContent": detailed.capabilities_content,
        "composedSystemPrompt": composed_system_prompt,
        "environment": {
            "workingDirectory": session.working_directory,
        },
    }))
}

fn build_detailed_messages(
    messages: &[crate::domains::agent::runner::context::types::DetailedMessageInfo],
) -> Vec<Value> {
    messages
        .iter()
        .map(|message| {
            let mut value = json!({
                "index": message.index,
                "role": message.role,
                "tokens": message.tokens,
                "summary": message.summary,
                "content": message.content,
            });
            if let Some(capability_invocations) = message.capability_invocations.as_ref() {
                value["capabilityInvocations"] = json!(
                    capability_invocations
                        .iter()
                        .map(|capability_invocation| json!({
                            "id": capability_invocation.id,
                            "name": capability_invocation.name,
                            "tokens": capability_invocation.tokens,
                            "arguments": capability_invocation.arguments,
                        }))
                        .collect::<Vec<_>>()
                );
            }
            if let Some(invocation_id) = message.invocation_id.as_ref() {
                value["invocationId"] = json!(invocation_id);
            }
            if let Some(is_error) = message.is_error {
                value["isError"] = json!(is_error);
            }
            if let Some(event_id) = message.event_id.as_ref() {
                value["eventId"] = json!(event_id);
            }
            value
        })
        .collect()
}

fn build_composed_system_prompt(
    context_manager: &crate::domains::agent::runner::context::context_manager::ContextManager,
) -> String {
    let mut composed_context = context_manager.build_base_context();
    composed_context.server_origin = None;

    crate::domains::model::providers::compose_context_parts(&composed_context).join("\n\n")
}
