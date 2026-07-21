//! Provider turn-context construction from the already resolved primitive surface.

use crate::domains::agent::context::context_manager::ContextManager;
use crate::shared::protocol::content::{AssistantContent, CapabilityResultContent, UserContent};
use crate::shared::protocol::messages::Context;
use crate::shared::protocol::messages::{
    CapabilityResultMessageContent, Message, UserMessageContent,
};
use tracing::debug;

const MAX_RELEVANCE_QUERY_CHARS: usize = 12_000;
const MAX_RELEVANCE_SEGMENT_CHARS: usize = 2_500;
const MAX_EVOLVING_MESSAGES: usize = 8;

pub(super) fn build_turn_context(
    context_manager: &mut ContextManager,
    server_origin: Option<&str>,
    primitive_surface: Vec<crate::shared::protocol::model_capabilities::ModelCapability>,
) -> Context {
    context_manager.set_server_origin(server_origin.map(String::from));
    context_manager.set_capabilities(primitive_surface.clone());

    let mut context = context_manager.build_base_context();
    context.messages = context_manager.get_messages_arc();
    context.capabilities = Some(primitive_surface);
    context.server_origin = server_origin.map(String::from);

    debug!(
        capability_count = context.capabilities.as_ref().map_or(0, Vec::len),
        "primitive turn context"
    );

    context
}

/// Build a bounded task-intent query from the current user turn and the model's
/// subsequent plan/tool observations. Binary content and hidden thinking never
/// enter worker retrieval.
pub(super) fn worker_relevance_query(messages: &[Message]) -> Option<String> {
    let user_index = messages.iter().rposition(Message::is_real_user_turn)?;
    let evolving_start = messages
        .len()
        .saturating_sub(MAX_EVOLVING_MESSAGES)
        .max(user_index);
    let mut selected = Vec::new();
    if evolving_start > user_index {
        selected.push(&messages[user_index]);
    }
    selected.extend(&messages[evolving_start..]);

    let mut query = String::new();
    for message in selected {
        let (role, text) = relevance_segment(message);
        if text.trim().is_empty() {
            continue;
        }
        let segment = text
            .chars()
            .take(MAX_RELEVANCE_SEGMENT_CHARS)
            .collect::<String>();
        let remaining = MAX_RELEVANCE_QUERY_CHARS.saturating_sub(query.chars().count());
        if remaining == 0 {
            break;
        }
        let framed = format!("{role}: {segment}\n");
        query.extend(framed.chars().take(remaining));
    }
    (!query.trim().is_empty()).then_some(query)
}

fn relevance_segment(message: &Message) -> (&'static str, String) {
    match message {
        Message::User { content, .. } => ("user", user_relevance_text(content)),
        Message::Assistant { content, .. } => {
            let text = content
                .iter()
                .filter_map(|part| match part {
                    AssistantContent::Text { text } => Some(text.clone()),
                    AssistantContent::CapabilityInvocation {
                        name, arguments, ..
                    } => Some(format!(
                        "tool {name} {}",
                        serde_json::to_string(arguments).unwrap_or_default()
                    )),
                    AssistantContent::Thinking { .. } => None,
                })
                .collect::<Vec<_>>()
                .join("\n");
            ("assistant", text)
        }
        Message::CapabilityResult { content, .. } => {
            ("tool_result", capability_result_relevance_text(content))
        }
    }
}

fn user_relevance_text(content: &UserMessageContent) -> String {
    match content {
        UserMessageContent::Text(text) => text.clone(),
        UserMessageContent::Blocks(blocks) => blocks
            .iter()
            .filter_map(|block| match block {
                UserContent::Text { text } => Some(text.clone()),
                UserContent::Document {
                    extracted_text,
                    file_name,
                    ..
                } => extracted_text.clone().or_else(|| file_name.clone()),
                UserContent::Image { .. } => None,
            })
            .collect::<Vec<_>>()
            .join("\n"),
    }
}

fn capability_result_relevance_text(content: &CapabilityResultMessageContent) -> String {
    match content {
        CapabilityResultMessageContent::Text(text) => text.clone(),
        CapabilityResultMessageContent::Blocks(blocks) => blocks
            .iter()
            .filter_map(|block| match block {
                CapabilityResultContent::Text { text } => Some(text.clone()),
                CapabilityResultContent::Image { .. } => None,
            })
            .collect::<Vec<_>>()
            .join("\n"),
    }
}

#[cfg(test)]
mod tests {
    use serde_json::{Map, json};

    use super::*;

    #[test]
    fn relevance_query_tracks_evolving_plan_and_tool_results() {
        let messages = vec![
            Message::user("old unrelated request"),
            Message::assistant("old response"),
            Message::user("research current compiler changes"),
            Message::assistant("I will use recent repository research."),
            Message::Assistant {
                content: vec![AssistantContent::CapabilityInvocation {
                    id: "call-1".to_owned(),
                    name: "worker_discover".to_owned(),
                    arguments: Map::from_iter([(
                        "query".to_owned(),
                        json!("recent compiler repository research"),
                    )]),
                    thought_signature: None,
                }],
                usage: None,
                cost: None,
                stop_reason: None,
                thinking: None,
            },
            Message::CapabilityResult {
                invocation_id: "call-1".to_owned(),
                content: CapabilityResultMessageContent::Text(
                    "Promoted last30days-research at version v2".to_owned(),
                ),
                is_error: None,
            },
        ];

        let query = worker_relevance_query(&messages).expect("query");
        assert!(query.contains("research current compiler changes"));
        assert!(query.contains("recent repository research"));
        assert!(query.contains("last30days-research"));
        assert!(!query.contains("old unrelated request"));
    }

    #[test]
    fn relevance_query_is_bounded_and_excludes_binary_content_and_thinking() {
        let messages = vec![
            Message::User {
                content: UserMessageContent::Blocks(vec![
                    UserContent::Image {
                        data: "secret-binary".repeat(10_000),
                        mime_type: "image/png".to_owned(),
                    },
                    UserContent::Text {
                        text: "x".repeat(20_000),
                    },
                ]),
                timestamp: None,
            },
            Message::Assistant {
                content: vec![AssistantContent::Thinking {
                    thinking: "hidden-plan-marker".to_owned(),
                    kind: Default::default(),
                    signature: None,
                }],
                usage: None,
                cost: None,
                stop_reason: None,
                thinking: None,
            },
        ];

        let query = worker_relevance_query(&messages).expect("query");
        assert!(query.chars().count() <= MAX_RELEVANCE_QUERY_CHARS);
        assert!(!query.contains("secret-binary"));
        assert!(!query.contains("hidden-plan-marker"));
    }
}
