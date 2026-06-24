use serde_json::Map;

use crate::shared::protocol::content::AssistantContent;
use crate::shared::protocol::events::AssistantMessage;
use crate::shared::protocol::messages::CapabilityInvocationDraft;

/// Finalize an in-progress capability invocation from accumulated deltas.
pub(super) fn finalize_capability_invocation(
    capability_invocations: &mut Vec<CapabilityInvocationDraft>,
    current_id: &mut Option<String>,
    current_name: &mut Option<String>,
    current_args: &mut String,
) {
    if let (Some(id), Some(name)) = (current_id.take(), current_name.take()) {
        if current_args.trim().is_empty() {
            current_args.clear();
            return;
        }
        let arguments: Map<String, serde_json::Value> = match serde_json::from_str(current_args) {
            Ok(map) => map,
            Err(e) => {
                tracing::warn!(
                    component = "agent.stream",
                    agent_event = "stream_capability_invocation_arguments_malformed",
                    model_primitive_name = %name,
                    invocation_id = %id,
                    error = %e,
                    args_len = current_args.len(),
                    "malformed capability invocation arguments, using empty map"
                );
                Map::new()
            }
        };
        if let Some(pos) = capability_invocations.iter().position(|tc| tc.id == id) {
            capability_invocations[pos] = CapabilityInvocationDraft::new(id, name, arguments);
        } else {
            capability_invocations.push(CapabilityInvocationDraft::new(id, name, arguments));
        }
        current_args.clear();
    }
}

/// Build an `AssistantMessage` from accumulated parts.
pub(super) fn build_message(
    text: &str,
    thinking: &str,
    thinking_signature: Option<&str>,
    capability_invocations: &[CapabilityInvocationDraft],
) -> AssistantMessage {
    let mut content: Vec<AssistantContent> = Vec::with_capacity(3);

    if !thinking.is_empty() {
        content.push(AssistantContent::Thinking {
            thinking: thinking.to_owned(),
            signature: thinking_signature.map(String::from),
        });
    }

    if !text.is_empty() {
        let trimmed = text.trim_end();
        if !trimmed.is_empty() {
            content.push(AssistantContent::text(trimmed));
        }
    }

    for tc in capability_invocations {
        content.push(AssistantContent::CapabilityInvocation {
            id: tc.id.clone(),
            name: tc.name.clone(),
            arguments: tc.arguments.clone(),
            thought_signature: tc.thought_signature.clone(),
        });
    }

    AssistantMessage {
        content,
        token_usage: None,
    }
}
