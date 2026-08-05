//! Provider turn-context construction from the already resolved primitive surface.

use std::sync::Arc;

use crate::domains::agent::context::context_manager::ContextManager;
use crate::engine::{EngineHostHandle, InvocationId, TraceId};
#[cfg(test)]
use crate::shared::protocol::content::AssistantContent;
use crate::shared::protocol::content::{ToolResultContent, UserContent};
use crate::shared::protocol::messages::Context;
use crate::shared::protocol::messages::{Message, ToolResultMessageContent, UserMessageContent};
use sha2::{Digest, Sha256};
use tracing::debug;

const MAX_RELEVANCE_QUERY_CHARS: usize = 12_000;
pub(super) const MAX_PROVIDER_TOOL_RESULT_BYTES: usize = 32 * 1_024;

const PROVIDER_RESULT_PREFIX: &str = "\
[Tron model-context projection: this tool result was too large to send to the model in full.";
const PROVIDER_RESULT_GUIDANCE: &str = "\
 The complete result remains in durable tool evidence. Use a narrower read or a file/worker \
reference instead of relaying large or binary content through model context.]\n\
--- retained prefix ---\n";
const PROVIDER_RESULT_SUFFIX: &str = "\n--- retained suffix ---\n";
const WORKER_RESULT_CHUNK_KIND: &str = "worker_result_chunk";
const WORKER_RESULT_HISTORY_KIND: &str = "worker_result_read_history";

pub(super) use super::turn_worker_results::{
    FreshWorkerResults, WORKER_RESULT_ASSOCIATION_KIND, canonicalize_worker_result_context,
};

pub(super) struct TurnContextProjection {
    pub context: Context,
    pub retained_messages: Vec<Message>,
}

#[allow(clippy::too_many_arguments)]
pub(super) async fn build_turn_context(
    context_manager: &mut ContextManager,
    server_origin: Option<&str>,
    primitive_surface: Vec<crate::shared::protocol::model_tools::ModelTool>,
    engine_host: &EngineHostHandle,
    session_id: &str,
    trace_id: Option<&TraceId>,
    parent_invocation_id: Option<&InvocationId>,
    fresh_worker_results: &FreshWorkerResults,
) -> Result<TurnContextProjection, String> {
    context_manager.set_server_origin(server_origin.map(String::from));
    context_manager.set_tools(primitive_surface.clone());

    let messages = context_manager.get_messages_arc();
    let provider_messages = super::turn_worker_results::project_messages(
        messages.clone(),
        engine_host,
        session_id,
        trace_id,
        parent_invocation_id,
        fresh_worker_results.model_tool_invocation_ids(),
    )
    .await?;
    let retained_messages = super::turn_worker_results::project_messages(
        messages,
        engine_host,
        session_id,
        trace_id,
        parent_invocation_id,
        &std::collections::HashSet::new(),
    )
    .await?;
    let mut context = context_manager.build_base_context();
    context.messages = project_provider_messages(provider_messages);
    context.tools = Some(primitive_surface);
    context.server_origin = server_origin.map(String::from);

    debug!(
        tool_count = context.tools.as_ref().map_or(0, Vec::len),
        "primitive turn context"
    );

    Ok(TurnContextProjection {
        context,
        retained_messages: project_retained_messages(retained_messages).to_vec(),
    })
}

/// Bound textual tool evidence before it crosses any provider boundary.
///
/// Exact output stays in the durable completion event. This projection is
/// deterministic and carries the original digest so a model can recognize
/// that it is seeing retained evidence rather than the complete result.
pub(super) fn project_provider_result_text(text: &str) -> String {
    if text.len() <= MAX_PROVIDER_TOOL_RESULT_BYTES {
        return text.to_owned();
    }

    let digest = hex::encode(Sha256::digest(text.as_bytes()));
    let metadata = format!(" originalBytes={} sha256={digest}.", text.len());
    let framing_bytes = PROVIDER_RESULT_PREFIX.len()
        + metadata.len()
        + PROVIDER_RESULT_GUIDANCE.len()
        + PROVIDER_RESULT_SUFFIX.len();
    let retained_budget = MAX_PROVIDER_TOOL_RESULT_BYTES.saturating_sub(framing_bytes);
    let prefix_budget = retained_budget / 2;
    let suffix_budget = retained_budget.saturating_sub(prefix_budget);
    let prefix = utf8_prefix(text, prefix_budget);
    let suffix = utf8_suffix(text, suffix_budget);

    let projected = format!(
        "{PROVIDER_RESULT_PREFIX}{metadata}{PROVIDER_RESULT_GUIDANCE}{prefix}\
         {PROVIDER_RESULT_SUFFIX}{suffix}"
    );
    debug_assert!(projected.len() <= MAX_PROVIDER_TOOL_RESULT_BYTES);
    projected
}

pub(super) fn project_provider_messages(messages: Arc<[Message]>) -> Arc<[Message]> {
    let fresh_result_start = trailing_tool_result_start(&messages);
    project_provider_messages_from(messages, fresh_result_start)
}

fn project_retained_messages(messages: Arc<[Message]>) -> Arc<[Message]> {
    let historical_end = messages.len();
    project_provider_messages_from(messages, historical_end)
}

fn project_provider_messages_from(
    messages: Arc<[Message]>,
    fresh_result_start: usize,
) -> Arc<[Message]> {
    if !messages.iter().enumerate().any(|(index, message)| {
        message_requires_projection(message)
            || (index < fresh_result_start && message_has_worker_result_chunk(message))
    }) {
        return messages;
    }

    messages
        .iter()
        .cloned()
        .enumerate()
        .map(|(index, message)| match message {
            Message::ToolResult {
                invocation_id,
                content,
                is_error,
            } => Message::ToolResult {
                invocation_id,
                content: project_tool_result_content(content, index < fresh_result_start),
                is_error,
            },
            other => other,
        })
        .collect::<Vec<_>>()
        .into()
}

/// The only results that need their full bounded projection are the trailing
/// batch produced immediately before the provider call being assembled.
///
/// A result earlier in the transcript has already been delivered to one model
/// turn. Worker result chunks remain re-readable through their durable
/// reference, so replaying those bytes on every later turn only grows context.
pub(super) fn trailing_tool_result_start(messages: &[Message]) -> usize {
    messages
        .iter()
        .rposition(|message| !matches!(message, Message::ToolResult { .. }))
        .map_or(0, |index| index.saturating_add(1))
}

fn message_requires_projection(message: &Message) -> bool {
    let Message::ToolResult { content, .. } = message else {
        return false;
    };
    match content {
        ToolResultMessageContent::Text(text) => text.len() > MAX_PROVIDER_TOOL_RESULT_BYTES,
        ToolResultMessageContent::Blocks(blocks) => {
            blocks
                .iter()
                .filter_map(|block| match block {
                    ToolResultContent::Text { text } => Some(text.len()),
                    ToolResultContent::Image { .. } => None,
                })
                .fold(0usize, usize::saturating_add)
                > MAX_PROVIDER_TOOL_RESULT_BYTES
        }
    }
}

fn message_has_worker_result_chunk(message: &Message) -> bool {
    let Message::ToolResult { content, .. } = message else {
        return false;
    };
    match content {
        ToolResultMessageContent::Text(text) => worker_result_history(text).is_some(),
        ToolResultMessageContent::Blocks(blocks) => blocks.iter().any(|block| match block {
            ToolResultContent::Text { text } => worker_result_history(text).is_some(),
            ToolResultContent::Image { .. } => false,
        }),
    }
}

fn project_tool_result_content(
    content: ToolResultMessageContent,
    historical: bool,
) -> ToolResultMessageContent {
    match content {
        ToolResultMessageContent::Text(text) => ToolResultMessageContent::Text(
            historical_worker_result(&text, historical)
                .unwrap_or_else(|| project_provider_result_text(&text)),
        ),
        ToolResultMessageContent::Blocks(blocks) => {
            let blocks = if historical {
                blocks
                    .into_iter()
                    .map(|block| match block {
                        ToolResultContent::Text { text } => ToolResultContent::Text {
                            text: historical_worker_result(&text, true).unwrap_or(text),
                        },
                        image => image,
                    })
                    .collect::<Vec<_>>()
            } else {
                blocks
            };
            let joined_text = blocks
                .iter()
                .filter_map(|block| match block {
                    ToolResultContent::Text { text } => Some(text.as_str()),
                    ToolResultContent::Image { .. } => None,
                })
                .collect::<Vec<_>>()
                .join("\n");
            if joined_text.len() <= MAX_PROVIDER_TOOL_RESULT_BYTES {
                return ToolResultMessageContent::Blocks(blocks);
            }

            let mut projected = vec![ToolResultContent::Text {
                text: project_provider_result_text(&joined_text),
            }];
            projected.extend(
                blocks
                    .into_iter()
                    .filter(|block| matches!(block, ToolResultContent::Image { .. })),
            );
            ToolResultMessageContent::Blocks(projected)
        }
    }
}

fn historical_worker_result(text: &str, historical: bool) -> Option<String> {
    if historical {
        worker_result_history(text)
    } else {
        None
    }
}

/// Replace an already-consumed bounded worker read with its durable reference.
///
/// This is deliberately schema-agnostic: the projection preserves the generic
/// result reference plus the exact pointer/page coordinates. A worker that
/// needs the bytes again can issue the same bounded read.
fn worker_result_history(text: &str) -> Option<String> {
    let chunk = serde_json::from_str::<serde_json::Value>(text).ok()?;
    if chunk.get("kind")?.as_str()? != WORKER_RESULT_CHUNK_KIND {
        return None;
    }
    let reference = chunk.get("reference")?.clone();
    if reference.get("kind")?.as_str()? != "worker_result_reference"
        || !reference
            .get("contentSha256")?
            .as_str()?
            .starts_with("sha256:")
        || !reference
            .get("outputSchemaSha256")?
            .as_str()?
            .starts_with("sha256:")
        || reference.get("sizeBytes")?.as_u64().is_none()
    {
        return None;
    }
    let invocation_id = reference.get("invocationId")?.as_str()?;
    let pointer = chunk.get("pointer").and_then(serde_json::Value::as_str)?;
    let offset = chunk
        .get("offset")
        .and_then(serde_json::Value::as_u64)
        .unwrap_or(0);
    serde_json::to_string(&serde_json::json!({
        "kind":WORKER_RESULT_HISTORY_KIND,
        "reference":reference,
        "pointer":pointer,
        "offset":offset,
        "message":format!(
            "This bounded result page was delivered on the immediately following model turn and is omitted from later context. Call worker_result_read with invocationId '{invocation_id}', pointer '{pointer}', and offset {offset} to read it again."
        ),
    }))
    .ok()
}

fn utf8_prefix(text: &str, max_bytes: usize) -> &str {
    let mut end = max_bytes.min(text.len());
    while !text.is_char_boundary(end) {
        end = end.saturating_sub(1);
    }
    &text[..end]
}

fn utf8_suffix(text: &str, max_bytes: usize) -> &str {
    let mut start = text.len().saturating_sub(max_bytes);
    while !text.is_char_boundary(start) {
        start += 1;
    }
    &text[start..]
}

/// Build one stable bounded task-intent query from the latest real user turn.
///
/// Assistant plans and tool results are deliberately excluded: resolving the
/// provider surface again within one prompt run must not let a model-selected
/// tool manufacture relevance for unrelated workers.
pub(super) fn worker_routing_query(messages: &[Message]) -> Option<String> {
    let message = messages
        .iter()
        .rfind(|message| message.is_real_user_turn())?;
    let Message::User { content, .. } = message else {
        return None;
    };
    let query = user_relevance_text(content)
        .chars()
        .take(MAX_RELEVANCE_QUERY_CHARS)
        .collect::<String>();
    (!query.trim().is_empty()).then_some(query)
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

#[cfg(test)]
mod tests {
    use serde_json::{Map, json};

    use super::*;

    #[test]
    fn relevance_query_is_stable_for_the_latest_user_request() {
        let messages = vec![
            Message::user("old unrelated request"),
            Message::assistant("old response"),
            Message::user("research current compiler changes"),
            Message::assistant("I will use recent repository research."),
            Message::Assistant {
                content: vec![AssistantContent::ToolInvocation {
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
            Message::ToolResult {
                invocation_id: "call-1".to_owned(),
                content: ToolResultMessageContent::Text(
                    "Promoted last30days-research at version v2".to_owned(),
                ),
                is_error: None,
            },
        ];

        let query = worker_routing_query(&messages).expect("query");
        assert!(query.contains("research current compiler changes"));
        assert!(!query.contains("recent repository research"));
        assert!(!query.contains("last30days-research"));
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

        let query = worker_routing_query(&messages).expect("query");
        assert!(query.chars().count() <= MAX_RELEVANCE_QUERY_CHARS);
        assert!(!query.contains("secret-binary"));
        assert!(!query.contains("hidden-plan-marker"));
    }

    #[test]
    fn oversized_tool_result_projection_is_bounded_deterministic_and_utf8_safe() {
        let original = format!(
            "begin:{}:end",
            "🦌quoted\\content".repeat(MAX_PROVIDER_TOOL_RESULT_BYTES)
        );

        let first = project_provider_result_text(&original);
        let second = project_provider_result_text(&original);

        assert_eq!(first, second);
        assert!(first.len() <= MAX_PROVIDER_TOOL_RESULT_BYTES);
        assert!(first.contains("Tron model-context projection"));
        assert!(first.contains(&format!("originalBytes={}", original.len())));
        assert!(first.contains(&hex::encode(Sha256::digest(original.as_bytes()))));
        assert!(first.contains("begin:"));
        assert!(first.contains(":end"));
        assert!(std::str::from_utf8(first.as_bytes()).is_ok());
    }

    #[test]
    fn historical_oversized_tool_results_are_projected_before_provider_context() {
        let oversized = format!("prefix-{}-suffix", "A".repeat(900_000));
        let messages: Arc<[Message]> = vec![
            Message::user("transcribe the local fixture"),
            Message::ToolResult {
                invocation_id: "call-large".to_owned(),
                content: ToolResultMessageContent::Text(oversized.clone()),
                is_error: None,
            },
        ]
        .into();

        let projected = project_provider_messages(messages);
        let Message::ToolResult { content, .. } = &projected[1] else {
            panic!("expected tool result");
        };
        let ToolResultMessageContent::Text(text) = content else {
            panic!("expected text result");
        };

        assert!(text.len() <= MAX_PROVIDER_TOOL_RESULT_BYTES);
        assert!(text.contains("prefix-"));
        assert!(text.contains("-suffix"));
        assert!(!text.contains(&oversized));
    }

    fn worker_result_chunk(evidence: &str) -> String {
        serde_json::to_string(&serde_json::json!({
            "kind":"worker_result_chunk",
            "reference":{
                "kind":"worker_result_reference",
                "invocationId":"worker_run_1",
                "workerId":"specialist",
                "workerVersion":"version-1",
                "outputSchemaSha256":"sha256:schema",
                "contentSha256":"sha256:content",
                "sizeBytes":24_000,
                "preview":"Specialist result",
                "message":"Stored durably"
            },
            "pointer":"/evidence",
            "value":{"evidence":evidence},
            "children":[],
            "offset":0,
            "returned":1,
            "total":1,
            "nextOffset":null,
            "truncated":false
        }))
        .unwrap()
    }

    #[test]
    fn fresh_worker_result_chunk_is_available_for_one_model_turn() {
        let chunk = worker_result_chunk(&"evidence ".repeat(1_000));
        let messages: Arc<[Message]> = vec![
            Message::user("inspect the specialist result"),
            Message::assistant("Reading the relevant result path."),
            Message::ToolResult {
                invocation_id: "call-read".to_owned(),
                content: ToolResultMessageContent::Text(chunk.clone()),
                is_error: None,
            },
        ]
        .into();

        let projected = project_provider_messages(messages);
        let Message::ToolResult { content, .. } = &projected[2] else {
            panic!("expected tool result");
        };
        let ToolResultMessageContent::Text(text) = content else {
            panic!("expected text result");
        };
        assert_eq!(text, &chunk);
    }

    #[test]
    fn consumed_worker_result_chunk_ages_to_rereadable_reference() {
        let evidence = "evidence ".repeat(1_000);
        let chunk = worker_result_chunk(&evidence);
        let messages: Arc<[Message]> = vec![
            Message::user("inspect the specialist result"),
            Message::assistant("Reading the relevant result path."),
            Message::ToolResult {
                invocation_id: "call-read".to_owned(),
                content: ToolResultMessageContent::Text(chunk),
                is_error: None,
            },
            Message::assistant("I used that evidence to request validation."),
            Message::ToolResult {
                invocation_id: "call-validation".to_owned(),
                content: ToolResultMessageContent::Text("validation complete".to_owned()),
                is_error: None,
            },
        ]
        .into();

        let projected = project_provider_messages(messages);
        let Message::ToolResult { content, .. } = &projected[2] else {
            panic!("expected historical tool result");
        };
        let ToolResultMessageContent::Text(text) = content else {
            panic!("expected text result");
        };
        let history: serde_json::Value = serde_json::from_str(text).unwrap();
        assert_eq!(history["kind"], WORKER_RESULT_HISTORY_KIND);
        assert_eq!(
            history["reference"]["invocationId"],
            serde_json::json!("worker_run_1")
        );
        assert_eq!(history["pointer"], "/evidence");
        assert_eq!(history["offset"], 0);
        assert!(
            history["message"]
                .as_str()
                .unwrap()
                .contains("worker_result_read")
        );
        assert!(!text.contains(&evidence));

        let Message::ToolResult { content, .. } = &projected[4] else {
            panic!("expected fresh tool result");
        };
        assert_eq!(
            content,
            &ToolResultMessageContent::Text("validation complete".to_owned())
        );
    }

    #[test]
    fn retained_context_ages_even_a_trailing_bounded_worker_page() {
        let chunk = worker_result_chunk(&"evidence ".repeat(1_000));
        let messages: Arc<[Message]> = vec![Message::ToolResult {
            invocation_id: "call-read".to_owned(),
            content: ToolResultMessageContent::Text(chunk),
            is_error: None,
        }]
        .into();

        let retained = project_retained_messages(messages);
        let Message::ToolResult { content, .. } = &retained[0] else {
            panic!("expected tool result");
        };
        let ToolResultMessageContent::Text(text) = content else {
            panic!("expected text");
        };
        assert_eq!(
            serde_json::from_str::<serde_json::Value>(text).unwrap()["kind"],
            WORKER_RESULT_HISTORY_KIND
        );
    }
}
