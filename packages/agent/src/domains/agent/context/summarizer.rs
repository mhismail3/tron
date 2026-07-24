//! Summarizer trait and utilities for compaction.
//!
//! Defines the [`Summarizer`] trait used by the compaction engine, plus the
//! worker-backed production policy and deterministic recovery summarization.

use serde_json::Value;
use sha2::{Digest, Sha256};

use crate::engine::{ActorId, ActorKind, CausalContext, FunctionId, Invocation, TraceId};
use crate::shared::protocol::content::{AssistantContent, ToolResultContent};
use crate::shared::protocol::messages::{Message, ToolResultMessageContent, UserMessageContent};

use super::types::SummaryResult;

// =============================================================================
// Summarizer Trait
// =============================================================================

/// Causal facts available to semantic summary policy.
#[derive(Clone, Debug, Default)]
pub struct SummaryContext {
    pub session_id: String,
    pub trace_id: Option<TraceId>,
    pub parent_invocation_id: Option<crate::engine::InvocationId>,
    pub worker_causal_depth: u32,
    pub origin_worker_id: Option<String>,
}

/// Trait for generating compaction summaries from conversation messages.
#[async_trait::async_trait]
pub trait Summarizer: Send + Sync {
    /// Summarize a sequence of messages into a structured result.
    async fn summarize(
        &self,
        messages: &[Message],
        context: &SummaryContext,
    ) -> Result<SummaryResult, Box<dyn std::error::Error + Send + Sync>>;
}

/// Production summary policy: use an atomically activated worker hook when one
/// exists and recover through [`KeywordSummarizer`] otherwise.
pub struct WorkerHookSummarizer {
    host: crate::engine::EngineHostHandle,
    recovery: KeywordSummarizer,
}

impl WorkerHookSummarizer {
    #[must_use]
    pub fn new(host: crate::engine::EngineHostHandle) -> Self {
        Self {
            host,
            recovery: KeywordSummarizer::new(),
        }
    }
}

#[async_trait::async_trait]
impl Summarizer for WorkerHookSummarizer {
    async fn summarize(
        &self,
        messages: &[Message],
        context: &SummaryContext,
    ) -> Result<SummaryResult, Box<dyn std::error::Error + Send + Sync>> {
        let projected = project_messages(messages);
        let mut payload = serde_json::json!({"messages":projected});
        if let Some(worker_id) = &context.origin_worker_id {
            payload["originWorkerId"] = Value::String(worker_id.clone());
        }
        let Ok(actor_id) = ActorId::new("system:context-summary") else {
            return self.recovery.summarize(messages, context).await;
        };
        let mut causal = CausalContext::new(
            actor_id,
            ActorKind::System,
            context.trace_id.clone().unwrap_or_else(TraceId::generate),
        )
        .with_session_id(context.session_id.clone())
        .with_trigger_depth(context.worker_causal_depth)
        .with_idempotency_key(format!(
            "context-summary:{}:{}",
            hex::encode(Sha256::digest(
                serde_json::to_vec(&payload).unwrap_or_default()
            )),
            uuid::Uuid::now_v7()
        ));
        if let Some(parent) = &context.parent_invocation_id {
            causal = causal.with_parent_invocation(parent.clone());
        }
        let Ok(function_id) =
            FunctionId::new(crate::domains::worker_kernel::CONTEXT_SUMMARY_FUNCTION)
        else {
            return self.recovery.summarize(messages, context).await;
        };
        // Detach the durable engine invocation from the caller's wait. If a
        // user cancels compaction, the worker delivery and engine ledger still
        // reach a durable terminal state while the context checkpoint is
        // restored by the compaction handler.
        let host = self.host.clone();
        let task = tokio::spawn(async move {
            host.invoke(Invocation::new_sync(function_id, payload, causal))
                .await
        });
        let Ok(outcome) = task.await else {
            return self.recovery.summarize(messages, context).await;
        };
        if outcome.error.is_none() {
            if let Some(narrative) = outcome
                .value
                .as_ref()
                .filter(|value| value["handled"] == true)
                .and_then(|value| value["narrative"].as_str())
                .filter(|value| !value.trim().is_empty())
            {
                return Ok(SummaryResult {
                    narrative: narrative.to_owned(),
                });
            }
        } else {
            tracing::warn!(
                session_id = %context.session_id,
                error = %outcome.error.as_ref().expect("checked above"),
                "worker context-summary hook failed; using deterministic recovery"
            );
        }
        self.recovery.summarize(messages, context).await
    }
}

// =============================================================================
// Keyword Summarizer
// =============================================================================

/// Fast recovery summarizer that extracts keywords from messages.
///
/// Used when the LLM summarizer fails (timeout, parse error, etc.).
/// Produces a simple narrative by concatenating user messages and
/// extracting file paths and tool ids.
pub struct KeywordSummarizer;

impl KeywordSummarizer {
    /// Create a new keyword summarizer.
    #[must_use]
    pub fn new() -> Self {
        Self
    }
}

impl Default for KeywordSummarizer {
    fn default() -> Self {
        Self::new()
    }
}

#[async_trait::async_trait]
impl Summarizer for KeywordSummarizer {
    async fn summarize(
        &self,
        messages: &[Message],
        _context: &SummaryContext,
    ) -> Result<SummaryResult, Box<dyn std::error::Error + Send + Sync>> {
        let mut user_messages = Vec::new();
        let mut files_modified = Vec::new();
        let mut model_tool_names = Vec::new();

        for msg in messages {
            match msg {
                Message::User { content, .. } => {
                    let text = user_content_text(content);
                    if !text.is_empty() {
                        user_messages.push(truncate(&text, 200));
                    }
                }
                Message::Assistant { content, .. } => {
                    for block in content {
                        match block {
                            AssistantContent::ToolInvocation {
                                name, arguments, ..
                            } => {
                                if !model_tool_names.contains(name) {
                                    model_tool_names.push(name.clone());
                                }
                                if let Some(path) = arguments
                                    .get("file_path")
                                    .or_else(|| arguments.get("path"))
                                    .and_then(Value::as_str)
                                {
                                    let p = path.to_string();
                                    if !files_modified.contains(&p) {
                                        files_modified.push(p);
                                    }
                                }
                            }
                            AssistantContent::Text { .. } => {}
                            AssistantContent::Thinking { .. } => {}
                        }
                    }
                }
                Message::ToolResult { .. } => {}
            }
        }

        let narrative = if user_messages.is_empty() {
            format!("({} messages summarized)", messages.len())
        } else {
            let mut parts = Vec::new();
            parts.push(format!("The user made {} requests.", user_messages.len()));
            parts.push(format!("Key requests: {}", user_messages.join("; ")));
            if !model_tool_names.is_empty() {
                parts.push(format!("Tools used: {}", model_tool_names.join(", ")));
            }
            if !files_modified.is_empty() {
                parts.push(format!("Files touched: {}", files_modified.join(", ")));
            }
            parts.join(" ")
        };

        Ok(SummaryResult {
            narrative: crate::shared::foundation::text::truncate_with_suffix(
                &narrative,
                crate::domains::worker_kernel::CONTEXT_SUMMARY_MAX_NARRATIVE_BYTES,
                "...",
            ),
        })
    }
}

/// Produce the bounded semantic transcript exposed to a summary worker.
/// Hidden thinking, tool arguments, binary data, usage, and cost never cross
/// this hook boundary.
fn project_messages(messages: &[Message]) -> Vec<Value> {
    let mut projected = Vec::new();
    for message in messages {
        match message {
            Message::User { content, .. } => {
                push_projection(&mut projected, "user", &user_content_text(content));
            }
            Message::Assistant { content, .. } => {
                for block in content {
                    match block {
                        AssistantContent::Text { text } => {
                            push_projection(&mut projected, "assistant", text);
                        }
                        AssistantContent::ToolInvocation { name, .. } => {
                            push_projection(&mut projected, "tool", &format!("{name} invoked"));
                        }
                        AssistantContent::Thinking { .. } => {}
                    }
                }
            }
            Message::ToolResult { content, .. } => match content {
                ToolResultMessageContent::Text(text) => {
                    push_projection(&mut projected, "tool", text);
                }
                ToolResultMessageContent::Blocks(blocks) => {
                    for block in blocks {
                        if let ToolResultContent::Text { text } = block {
                            push_projection(&mut projected, "tool", text);
                        }
                    }
                }
            },
        }
        if projected.len() >= 256 {
            break;
        }
    }
    projected
}

fn push_projection(projected: &mut Vec<Value>, role: &str, text: &str) {
    if projected.len() >= 256 || text.trim().is_empty() {
        return;
    }
    projected.push(serde_json::json!({
        "role":role,
        "text":truncate(text, 4096),
    }));
}

/// Truncate a string to a maximum length, appending "..." if truncated.
fn truncate(s: &str, max_len: usize) -> String {
    crate::shared::foundation::text::truncate_with_suffix(s, max_len, "...")
}

// =============================================================================
// Content text extraction helpers
// =============================================================================

/// Extract text from a `UserMessageContent`.
fn user_content_text(content: &UserMessageContent) -> String {
    match content {
        UserMessageContent::Text(t) => t.clone(),
        UserMessageContent::Blocks(blocks) => blocks
            .iter()
            .filter_map(|b| b.as_text())
            .collect::<Vec<_>>()
            .join("\n"),
    }
}

// =============================================================================
// Tests
// =============================================================================

#[cfg(test)]
mod tests {
    use super::*;
    use crate::shared::protocol::content::UserContent;
    use crate::shared::protocol::messages::ToolResultMessageContent;

    fn worker_bundle(command: &str, worker_id: &str) -> Value {
        serde_json::json!({
            "schemaVersion":"tron.worker_bundle.v1",
            "workerId":worker_id,
            "name":"Context Summary Policy",
            "description":"Creates durable semantic context summaries",
            "inputSchema":{
                "type":"object","additionalProperties":false,"required":["messages"],
                "properties":{
                    "originWorkerId":{"type":"string"},
                    "messages":{"type":"array","maxItems":256,"items":{
                        "type":"object","additionalProperties":false,"required":["role","text"],
                        "properties":{
                            "role":{"type":"string","enum":["user","assistant","tool"]},
                            "text":{"type":"string","maxLength":4096}
                        }
                    }}
                }
            },
            "outputSchema":{
                "type":"object","additionalProperties":false,"required":["narrative"],
                "properties":{"narrative":{"type":"string","minLength":1,"maxLength":4000}}
            },
            "runner":{"kind":"command","command":["sh","-c",command]},
            "engineHooks":["context_summary"],
            "provenance":[{"source":"test:context-summary-policy"}]
        })
    }

    async fn install_worker(host: &crate::engine::EngineHostHandle, bundle: Value) -> String {
        let outcome = host
            .invoke(Invocation::new_sync(
                FunctionId::new("worker_kernel::upsert").unwrap(),
                serde_json::json!({"bundle":bundle}),
                CausalContext::new(
                    ActorId::new("agent:summary-test").unwrap(),
                    ActorKind::Agent,
                    TraceId::generate(),
                )
                .with_session_id("summary-test")
                .with_idempotency_key(format!("install-summary-{}", uuid::Uuid::now_v7())),
            ))
            .await;
        assert_eq!(outcome.error, None, "worker upsert failed");
        outcome.value.unwrap()["worker"]["workerId"]
            .as_str()
            .unwrap()
            .to_owned()
    }

    fn summary_context() -> SummaryContext {
        SummaryContext {
            session_id: "summary-test".to_owned(),
            ..Default::default()
        }
    }
    #[test]
    fn truncate_bounds_long_string() {
        let result = truncate("hello world", 8);
        assert!(result.ends_with("..."));
        assert!(result.len() <= 8);
    }

    #[tokio::test]
    async fn keyword_summarizer_basic() {
        let summarizer = KeywordSummarizer;
        let messages = vec![
            Message::user("Fix the login bug"),
            Message::assistant("I'll look at the login code."),
        ];
        let result = summarizer
            .summarize(&messages, &SummaryContext::default())
            .await
            .unwrap();
        assert!(!result.narrative.is_empty());
        assert!(result.narrative.contains("1 requests"));
    }

    #[tokio::test]
    async fn keyword_summarizer_empty_messages() {
        let summarizer = KeywordSummarizer;
        let result = summarizer
            .summarize(&[], &SummaryContext::default())
            .await
            .unwrap();
        assert!(result.narrative.contains("0 messages summarized"));
    }

    #[tokio::test]
    async fn keyword_recovery_never_exceeds_the_durable_summary_ceiling() {
        let messages = (0..40)
            .map(|index| Message::user(format!("request {index}: {}", "é".repeat(200))))
            .collect::<Vec<_>>();

        let result = KeywordSummarizer::new()
            .summarize(&messages, &SummaryContext::default())
            .await
            .unwrap();

        assert!(
            result.narrative.len()
                <= crate::domains::worker_kernel::CONTEXT_SUMMARY_MAX_NARRATIVE_BYTES
        );
        assert!(result.narrative.is_char_boundary(result.narrative.len()));
    }

    #[tokio::test]
    async fn production_summarizer_uses_an_active_worker_hook() {
        let context = crate::shared::server::test_support::make_test_context();
        install_worker(
            &context.engine_host,
            worker_bundle(
                "printf '{\"narrative\":\"semantic worker summary\"}'",
                "summary-policy",
            ),
        )
        .await;
        let summarizer = WorkerHookSummarizer::new(context.engine_host.clone());

        let result = summarizer
            .summarize(
                &[Message::user("Keep the semantic details")],
                &summary_context(),
            )
            .await
            .unwrap();

        assert_eq!(result.narrative, "semantic worker summary");
    }

    #[tokio::test]
    async fn production_summarizer_preserves_origin_worker_evidence_in_hook_input() {
        let context = crate::shared::server::test_support::make_test_context();
        install_worker(
            &context.engine_host,
            worker_bundle(
                r#"python3 -c 'import json,sys; payload=json.load(sys.stdin); print(json.dumps({"narrative": payload.get("originWorkerId", "missing")}))'"#,
                "origin-aware-summary-policy",
            ),
        )
        .await;
        let summarizer = WorkerHookSummarizer::new(context.engine_host.clone());
        let mut summary_context = summary_context();
        summary_context.origin_worker_id = Some("delegated-context".to_owned());

        let result = summarizer
            .summarize(
                &[Message::user("Keep the semantic details")],
                &summary_context,
            )
            .await
            .unwrap();

        assert_eq!(result.narrative, "delegated-context");
    }

    #[tokio::test]
    async fn failed_worker_hook_disables_itself_and_compaction_recovers() {
        let context = crate::shared::server::test_support::make_test_context();
        let worker_id = install_worker(
            &context.engine_host,
            worker_bundle("printf failure >&2; exit 7", "failing-summary-policy"),
        )
        .await;
        let summarizer = WorkerHookSummarizer::new(context.engine_host.clone());

        let result = summarizer
            .summarize(&[Message::user("Recover this request")], &summary_context())
            .await
            .unwrap();

        assert!(result.narrative.contains("Recover this request"));
        let list = context
            .engine_host
            .invoke(Invocation::new_sync(
                FunctionId::new("worker_kernel::list").unwrap(),
                serde_json::json!({"includeRetired":false}),
                CausalContext::new(
                    ActorId::new("agent:summary-test").unwrap(),
                    ActorKind::Agent,
                    TraceId::generate(),
                )
                .with_session_id("summary-test"),
            ))
            .await
            .value
            .unwrap();
        let worker = list["workers"]
            .as_array()
            .unwrap()
            .iter()
            .find(|worker| worker["workerId"] == worker_id)
            .unwrap();
        assert_eq!(worker["enabled"], false);
        assert_eq!(worker["health"], "failed");
    }

    #[test]
    fn worker_projection_excludes_thinking_arguments_and_binary_results() {
        let messages = vec![
            Message::Assistant {
                content: vec![
                    AssistantContent::Thinking {
                        thinking: "private chain".to_owned(),
                        kind: crate::shared::protocol::content::ThinkingContentKind::Thinking,
                        signature: None,
                    },
                    AssistantContent::ToolInvocation {
                        id: "call-1".to_owned(),
                        name: "filesystem_read".to_owned(),
                        arguments: serde_json::Map::from_iter([(
                            "secret".to_owned(),
                            Value::String("do-not-project".to_owned()),
                        )]),
                        thought_signature: None,
                    },
                ],
                usage: None,
                cost: None,
                stop_reason: None,
                thinking: None,
            },
            Message::ToolResult {
                invocation_id: "call-1".to_owned(),
                content: ToolResultMessageContent::Blocks(vec![
                    ToolResultContent::Text {
                        text: "visible result".to_owned(),
                    },
                    ToolResultContent::Image {
                        data: "base64-binary".to_owned(),
                        mime_type: "image/png".to_owned(),
                    },
                ]),
                is_error: None,
            },
        ];

        let projection = serde_json::to_string(&project_messages(&messages)).unwrap();
        assert!(projection.contains("filesystem_read invoked"));
        assert!(projection.contains("visible result"));
        assert!(!projection.contains("private chain"));
        assert!(!projection.contains("do-not-project"));
        assert!(!projection.contains("base64-binary"));
    }

    // -- User content helpers --

    #[test]
    fn user_content_text_joins_blocks() {
        let content = UserMessageContent::Blocks(vec![
            UserContent::Text {
                text: "First block".into(),
            },
            UserContent::Text {
                text: "Second block".into(),
            },
        ]);
        let result = user_content_text(&content);
        assert_eq!(result, "First block\nSecond block");
    }

    // -- user_content_text --

    #[test]
    fn user_content_text_from_string() {
        let content = UserMessageContent::Text("hello".into());
        assert_eq!(user_content_text(&content), "hello");
    }

    #[test]
    fn user_content_text_from_blocks() {
        let content =
            UserMessageContent::Blocks(vec![UserContent::text("one"), UserContent::text("two")]);
        assert_eq!(user_content_text(&content), "one\ntwo");
    }
}
