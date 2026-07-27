//! Reference-only worker-result reconstruction for provider turns.
//!
//! Session events retain a provider-tool association rather than another typed
//! result body. This module resolves those associations through the internal
//! worker-kernel projection, hydrates a trailing small result for one provider
//! turn, and projects every consumed result back to its integrity reference.

use std::collections::{HashMap, HashSet};
use std::sync::Arc;

use crate::domains::agent::context::context_manager::ContextManager;
use crate::engine::{EngineHostHandle, InvocationId, TraceId};
use crate::shared::protocol::content::ToolResultContent;
use crate::shared::protocol::messages::{Message, ToolResultMessageContent};

pub(in crate::domains::agent::r#loop::turn_runner) const WORKER_RESULT_ASSOCIATION_KIND: &str =
    "worker_result_association";

#[derive(Debug, Default)]
pub(in crate::domains::agent::r#loop::turn_runner) struct FreshWorkerResults {
    model_tool_invocation_ids: HashSet<String>,
}

impl FreshWorkerResults {
    pub(super) fn model_tool_invocation_ids(&self) -> &HashSet<String> {
        &self.model_tool_invocation_ids
    }
}

/// Rebuild provider/accounting context from durable worker-result truth.
///
/// Only trailing association markers are eligible for one-turn hydration.
/// The returned identities live only for this turn's provider preparation;
/// restart reconstruction derives them again from the persisted markers.
pub(in crate::domains::agent::r#loop::turn_runner) async fn canonicalize_worker_result_context(
    context_manager: &mut ContextManager,
    engine_host: &EngineHostHandle,
    session_id: &str,
    trace_id: Option<&TraceId>,
    parent_invocation_id: Option<&InvocationId>,
) -> Result<FreshWorkerResults, String> {
    let messages = context_manager.get_messages_arc();
    let fresh_result_start = super::turn_context::trailing_tool_result_start(&messages);
    let fresh_model_tool_invocation_ids = messages
        .iter()
        .enumerate()
        .filter(|(index, _)| *index >= fresh_result_start)
        .filter_map(|(_, message)| worker_association_id(message))
        .collect::<HashSet<_>>();
    let projected = project_messages(
        messages,
        engine_host,
        session_id,
        trace_id,
        parent_invocation_id,
        &fresh_model_tool_invocation_ids,
    )
    .await?;
    context_manager
        .set_messages(super::turn_context::project_provider_messages(projected).to_vec());
    Ok(FreshWorkerResults {
        model_tool_invocation_ids: fresh_model_tool_invocation_ids,
    })
}

#[allow(clippy::too_many_arguments)]
pub(super) async fn project_messages(
    messages: Arc<[Message]>,
    engine_host: &EngineHostHandle,
    session_id: &str,
    trace_id: Option<&TraceId>,
    parent_invocation_id: Option<&InvocationId>,
    fresh_model_tool_invocation_ids: &HashSet<String>,
) -> Result<Arc<[Message]>, String> {
    let mut model_tool_invocation_ids = messages
        .iter()
        .filter_map(|message| match message {
            Message::ToolResult {
                invocation_id,
                is_error,
                ..
            } if is_error != &Some(true) => Some(invocation_id.clone()),
            _ => None,
        })
        .collect::<HashSet<_>>()
        .into_iter()
        .collect::<Vec<_>>();
    if model_tool_invocation_ids.is_empty() {
        return Ok(messages);
    }
    model_tool_invocation_ids.sort();
    let mut projections = HashMap::new();
    for ids in model_tool_invocation_ids.chunks(256) {
        let fresh = ids
            .iter()
            .filter(|id| fresh_model_tool_invocation_ids.contains(*id))
            .cloned()
            .collect::<Vec<_>>();
        let items = crate::domains::agent::r#loop::primitive_surface::worker_result_projections(
            engine_host,
            session_id,
            ids,
            &[],
            &fresh,
            &[],
            trace_id,
            parent_invocation_id,
        )
        .await?;
        for item in items {
            let Some(model_tool_invocation_id) = item
                .get("modelToolInvocationId")
                .and_then(serde_json::Value::as_str)
            else {
                continue;
            };
            projections.insert(model_tool_invocation_id.to_owned(), item);
        }
    }
    for expected in association_ids(&messages) {
        if !projections.contains_key(&expected) {
            return Err(format!(
                "durable worker result association '{expected}' could not be resolved"
            ));
        }
    }
    if projections.is_empty() {
        return Ok(messages);
    }
    Ok(messages
        .iter()
        .cloned()
        .map(|message| project_message(message, &projections))
        .collect::<Vec<_>>()
        .into())
}

fn association_ids(messages: &[Message]) -> HashSet<String> {
    messages.iter().filter_map(worker_association_id).collect()
}

fn worker_association_id(message: &Message) -> Option<String> {
    let Message::ToolResult {
        invocation_id,
        content,
        is_error,
    } = message
    else {
        return None;
    };
    if *is_error == Some(true) {
        return None;
    }
    content_texts(content)
        .any(|text| is_worker_association(text, invocation_id))
        .then(|| invocation_id.clone())
}

fn content_texts(content: &ToolResultMessageContent) -> impl Iterator<Item = &str> {
    let (text, blocks): (Option<&str>, &[ToolResultContent]) = match content {
        ToolResultMessageContent::Text(text) => (Some(text.as_str()), &[]),
        ToolResultMessageContent::Blocks(blocks) => (None, blocks.as_slice()),
    };
    text.into_iter()
        .chain(blocks.iter().filter_map(|block| match block {
            ToolResultContent::Text { text } => Some(text.as_str()),
            ToolResultContent::Image { .. } => None,
        }))
}

fn is_worker_association(text: &str, invocation_id: &str) -> bool {
    serde_json::from_str::<serde_json::Value>(text)
        .ok()
        .is_some_and(|value| {
            value.get("kind").and_then(serde_json::Value::as_str)
                == Some(WORKER_RESULT_ASSOCIATION_KIND)
                && value
                    .get("modelToolInvocationId")
                    .and_then(serde_json::Value::as_str)
                    == Some(invocation_id)
        })
}

fn project_message(message: Message, projections: &HashMap<String, serde_json::Value>) -> Message {
    let Message::ToolResult {
        invocation_id,
        content,
        is_error,
    } = message
    else {
        return message;
    };
    if is_error == Some(true) {
        return Message::ToolResult {
            invocation_id,
            content,
            is_error,
        };
    }
    let Some(projection) = projections.get(&invocation_id) else {
        return Message::ToolResult {
            invocation_id,
            content,
            is_error,
        };
    };
    Message::ToolResult {
        invocation_id,
        content: project_content(content, projection),
        is_error,
    }
}

fn project_content(
    content: ToolResultMessageContent,
    projection: &serde_json::Value,
) -> ToolResultMessageContent {
    match content {
        ToolResultMessageContent::Text(text) => {
            ToolResultMessageContent::Text(project_text(&text, projection))
        }
        ToolResultMessageContent::Blocks(blocks) => ToolResultMessageContent::Blocks(
            blocks
                .into_iter()
                .map(|block| match block {
                    ToolResultContent::Text { text } => ToolResultContent::Text {
                        text: project_text(&text, projection),
                    },
                    image => image,
                })
                .collect(),
        ),
    }
}

fn project_text(text: &str, projection: &serde_json::Value) -> String {
    let Some(provider_value) = projection.get("providerValue") else {
        return text.to_owned();
    };
    let Some(reference) = projection.get("reference") else {
        return text.to_owned();
    };
    let parsed = serde_json::from_str::<serde_json::Value>(text).ok();
    if parsed.as_ref().is_some_and(is_stable_worker_receipt) {
        return text.to_owned();
    }
    if let Some(mut record) = parsed.filter(is_worker_invocation_record) {
        if reference.is_object() {
            record["output"] = reference.clone();
        }
        return serde_json::to_string_pretty(&record).unwrap_or_else(|_| text.to_owned());
    }
    serde_json::to_string_pretty(provider_value).unwrap_or_else(|_| provider_value.to_string())
}

fn is_stable_worker_receipt(value: &serde_json::Value) -> bool {
    matches!(
        value.get("kind").and_then(serde_json::Value::as_str),
        Some(
            "worker_invocation_receipt"
                | "worker_result_reference"
                | "worker_result_chunk"
                | "worker_result_read_history"
        )
    )
}

fn is_worker_invocation_record(value: &serde_json::Value) -> bool {
    value.get("invocationId").is_some()
        && value.get("workerId").is_some()
        && value.get("workerVersion").is_some()
        && value.get("status").is_some()
        && value.get("interactionMode").is_some()
        && value.get("output").is_some()
}

#[cfg(test)]
mod tests {
    use async_trait::async_trait;
    use serde_json::json;

    use super::*;
    use crate::domains::agent::context::types::{CompactionConfig, ContextManagerConfig};
    use crate::engine::{
        EffectClass, FunctionDefinition, FunctionId, FunctionVisibility, Invocation, RiskLevel,
        WorkerId,
    };

    fn worker_projection(provider_value: serde_json::Value) -> serde_json::Value {
        json!({
            "modelToolInvocationId":"call-worker",
            "invocationId":"worker_run_1",
            "workerId":"specialist",
            "workerVersion":"version-1",
            "status":"completed",
            "interactionMode":"foreground",
            "reference":{
                "kind":"worker_result_reference",
                "invocationId":"worker_run_1",
                "workerId":"specialist",
                "workerVersion":"version-1",
                "outputSchemaSha256":"sha256:schema",
                "contentSha256":"sha256:content",
                "sizeBytes":128,
                "preview":"Specialist result",
                "message":"Stored durably"
            },
            "providerValue":provider_value,
            "fresh":true
        })
    }

    #[test]
    fn direct_worker_association_projects_exact_once_and_then_reference() {
        let association = json!({
            "kind":WORKER_RESULT_ASSOCIATION_KIND,
            "modelToolInvocationId":"call-worker"
        })
        .to_string();
        assert!(is_worker_association(&association, "call-worker"));

        let fresh = project_text(
            &association,
            &worker_projection(json!({"answer":"exact typed result"})),
        );
        assert_eq!(
            serde_json::from_str::<serde_json::Value>(&fresh).unwrap(),
            json!({"answer":"exact typed result"})
        );

        let reference = worker_projection(json!({
            "kind":"worker_result_reference",
            "invocationId":"worker_run_1",
            "workerId":"specialist",
            "workerVersion":"version-1",
            "outputSchemaSha256":"sha256:schema",
            "contentSha256":"sha256:content",
            "sizeBytes":128,
            "preview":"Specialist result",
            "message":"Stored durably"
        }));
        let historical = project_text(&fresh, &reference);
        assert_eq!(
            serde_json::from_str::<serde_json::Value>(&historical).unwrap()["kind"],
            "worker_result_reference"
        );
        assert!(!historical.contains("exact typed result"));
    }

    #[test]
    fn fixed_worker_interaction_record_keeps_metadata_but_references_its_output() {
        let record = json!({
            "invocationId":"worker_run_1",
            "workerId":"specialist",
            "workerVersion":"version-1",
            "status":"completed",
            "interactionMode":"foreground",
            "output":{"answer":"duplicated"}
        })
        .to_string();
        let projected = project_text(&record, &worker_projection(json!({"ignored":true})));
        let projected: serde_json::Value = serde_json::from_str(&projected).unwrap();

        assert_eq!(projected["status"], "completed");
        assert_eq!(projected["output"]["kind"], "worker_result_reference");
        assert!(!projected.to_string().contains("duplicated"));
    }

    #[derive(Clone)]
    struct ProjectionHandler;

    #[async_trait]
    impl crate::engine::InProcessFunctionHandler for ProjectionHandler {
        async fn invoke(&self, invocation: Invocation) -> crate::engine::Result<serde_json::Value> {
            let ids = invocation.payload["modelToolInvocationIds"]
                .as_array()
                .cloned()
                .unwrap_or_default();
            let fresh = invocation.payload["freshModelToolInvocationIds"]
                .as_array()
                .cloned()
                .unwrap_or_default();
            let reference = json!({
                "kind":"worker_result_reference",
                "invocationId":"worker_run_1",
                "workerId":"specialist",
                "workerVersion":"version-1",
                "outputSchemaSha256":"sha256:schema",
                "contentSha256":"sha256:content",
                "sizeBytes":128,
                "preview":"Specialist result",
                "message":"Stored durably"
            });
            let items = ids
                .into_iter()
                .filter_map(|id| id.as_str().map(ToOwned::to_owned))
                .filter(|id| id == "call-worker")
                .map(|id| {
                    let is_fresh = fresh
                        .iter()
                        .any(|fresh| fresh.as_str() == Some(id.as_str()));
                    json!({
                        "modelToolInvocationId":id,
                        "invocationId":"worker_run_1",
                        "workerId":"specialist",
                        "workerVersion":"version-1",
                        "status":"completed",
                        "interactionMode":"foreground",
                        "reference":reference.clone(),
                        "providerValue":if is_fresh {
                            json!({"answer":"exact typed result"})
                        } else {
                            reference.clone()
                        },
                        "fresh":is_fresh
                    })
                })
                .collect::<Vec<_>>();
            Ok(json!({"items":items}))
        }
    }

    async fn projection_host() -> EngineHostHandle {
        let host = EngineHostHandle::new_in_memory().expect("engine host");
        let function_id =
            FunctionId::new(crate::domains::worker_kernel::WORKER_RESULT_PROJECTION_FUNCTION)
                .unwrap();
        host.register_function(
            FunctionDefinition::new(
                function_id,
                WorkerId::new("worker_kernel").unwrap(),
                "test projection".to_owned(),
                FunctionVisibility::Internal,
                EffectClass::PureRead,
            )
            .with_risk(RiskLevel::Low),
            Arc::new(ProjectionHandler),
        )
        .await
        .unwrap();
        host
    }

    fn projection_context_manager() -> ContextManager {
        ContextManager::new(ContextManagerConfig {
            system_prompt: Some("system".to_owned()),
            working_directory: Some("/tmp".to_owned()),
            compaction: CompactionConfig::default(),
        })
    }

    #[tokio::test]
    async fn restart_projection_delivers_fresh_small_result_once() {
        let host = projection_host().await;
        let mut manager = projection_context_manager();
        manager.add_message(Message::ToolResult {
            invocation_id: "call-worker".to_owned(),
            content: ToolResultMessageContent::Text(
                json!({
                    "kind":WORKER_RESULT_ASSOCIATION_KIND,
                    "modelToolInvocationId":"call-worker"
                })
                .to_string(),
            ),
            is_error: None,
        });

        let fresh = canonicalize_worker_result_context(&mut manager, &host, "sess_1", None, None)
            .await
            .unwrap();
        let projection = super::super::turn_context::build_turn_context(
            &mut manager,
            None,
            Vec::new(),
            &host,
            "sess_1",
            None,
            None,
            &fresh,
        )
        .await
        .unwrap();
        let Message::ToolResult { content, .. } = &projection.context.messages[0] else {
            panic!("expected result");
        };
        let ToolResultMessageContent::Text(text) = content else {
            panic!("expected text");
        };
        assert!(text.contains("exact typed result"));
        assert!(!text.contains("worker_result_reference"));

        manager.set_messages(projection.retained_messages);
        let historical = super::super::turn_context::build_turn_context(
            &mut manager,
            None,
            Vec::new(),
            &host,
            "sess_1",
            None,
            None,
            &FreshWorkerResults::default(),
        )
        .await
        .unwrap();
        let Message::ToolResult { content, .. } = &historical.context.messages[0] else {
            panic!("expected result");
        };
        let ToolResultMessageContent::Text(text) = content else {
            panic!("expected text");
        };
        assert!(text.contains("worker_result_reference"));
        assert!(!text.contains("exact typed result"));

        let mut restarted_after_consumption = projection_context_manager();
        restarted_after_consumption.add_message(Message::ToolResult {
            invocation_id: "call-worker".to_owned(),
            content: ToolResultMessageContent::Text(
                json!({
                    "kind":WORKER_RESULT_ASSOCIATION_KIND,
                    "modelToolInvocationId":"call-worker"
                })
                .to_string(),
            ),
            is_error: None,
        });
        restarted_after_consumption.add_message(Message::assistant("Result consumed."));
        canonicalize_worker_result_context(
            &mut restarted_after_consumption,
            &host,
            "sess_1",
            None,
            None,
        )
        .await
        .unwrap();
        let Message::ToolResult { content, .. } = &restarted_after_consumption.messages_slice()[0]
        else {
            panic!("expected result");
        };
        let ToolResultMessageContent::Text(text) = content else {
            panic!("expected text");
        };
        assert!(text.contains("worker_result_reference"));
        assert!(!text.contains("exact typed result"));
    }

    #[tokio::test]
    async fn missing_fresh_association_fails_before_provider_projection() {
        let host = projection_host().await;
        let mut manager = projection_context_manager();
        manager.add_message(Message::ToolResult {
            invocation_id: "call-missing".to_owned(),
            content: ToolResultMessageContent::Text(
                json!({
                    "kind":WORKER_RESULT_ASSOCIATION_KIND,
                    "modelToolInvocationId":"call-missing"
                })
                .to_string(),
            ),
            is_error: None,
        });

        let error = canonicalize_worker_result_context(&mut manager, &host, "sess_1", None, None)
            .await
            .unwrap_err();
        assert!(error.contains("could not be resolved"));
    }
}
