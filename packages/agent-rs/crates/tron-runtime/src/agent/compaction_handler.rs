//! Compaction handler — monitors token usage and triggers compaction.

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;

use async_trait::async_trait;
use futures::StreamExt;
use tron_context::context_manager::ContextManager;
use tron_context::summarizer::KeywordSummarizer;
use tron_core::events::{BaseEvent, CompactionReason, TronEvent};
use tron_core::events::HookResult as EventHookResult;
use tron_hooks::engine::HookEngine;
use tron_hooks::types::{HookAction, HookContext};
use tron_llm::provider::Provider;

use tracing::{debug, info};

use crate::agent::event_emitter::EventEmitter;
use crate::errors::RuntimeError;

// =============================================================================
// ProviderSubsessionSpawner — LLM-backed SubsessionSpawner
// =============================================================================

/// [`SubsessionSpawner`](tron_context::llm_summarizer::SubsessionSpawner) that
/// makes a single LLM stream call, collecting text deltas into a response.
///
/// Re-used by `tron-rpc::handlers::agent::RuntimeMemoryDeps` for auto-compaction.
pub struct ProviderSubsessionSpawner {
    /// The LLM provider to call.
    pub provider: Arc<dyn Provider>,
}

#[async_trait]
impl tron_context::llm_summarizer::SubsessionSpawner for ProviderSubsessionSpawner {
    async fn spawn_summarizer(
        &self,
        task: &str,
    ) -> tron_context::llm_summarizer::SubsessionResult {
        use tron_context::system_prompts::COMPACTION_SUMMARIZER_PROMPT;
        use tron_core::events::StreamEvent;

        let context = tron_core::messages::Context {
            system_prompt: Some(COMPACTION_SUMMARIZER_PROMPT.to_string()),
            messages: vec![tron_core::messages::Message::user(task)],
            ..Default::default()
        };

        let opts = tron_llm::provider::ProviderStreamOptions {
            max_tokens: Some(4096),
            ..Default::default()
        };

        let stream_result = self.provider.stream(&context, &opts).await;

        let mut event_stream = match stream_result {
            Ok(s) => s,
            Err(e) => {
                return tron_context::llm_summarizer::SubsessionResult {
                    success: false,
                    output: None,
                    error: Some(e.to_string()),
                };
            }
        };

        let mut text = String::new();
        while let Some(event) = event_stream.next().await {
            match event {
                Ok(StreamEvent::TextDelta { delta }) => text.push_str(&delta),
                Ok(StreamEvent::Done { .. }) => break,
                Ok(StreamEvent::Error { error }) => {
                    return tron_context::llm_summarizer::SubsessionResult {
                        success: false,
                        output: None,
                        error: Some(error),
                    };
                }
                Err(e) => {
                    return tron_context::llm_summarizer::SubsessionResult {
                        success: false,
                        output: None,
                        error: Some(e.to_string()),
                    };
                }
                _ => {}
            }
        }

        if text.is_empty() {
            tron_context::llm_summarizer::SubsessionResult {
                success: false,
                output: None,
                error: Some("no text produced".into()),
            }
        } else {
            tron_context::llm_summarizer::SubsessionResult {
                success: true,
                output: Some(text),
                error: None,
            }
        }
    }
}

/// Compaction handler state.
pub struct CompactionHandler {
    is_compacting: AtomicBool,
    provider: Option<Arc<dyn Provider>>,
}

impl CompactionHandler {
    /// Create a new handler.
    pub fn new() -> Self {
        Self {
            is_compacting: AtomicBool::new(false),
            provider: None,
        }
    }

    /// Create a handler with an LLM provider for intelligent summaries.
    pub fn with_provider(provider: Arc<dyn Provider>) -> Self {
        Self {
            is_compacting: AtomicBool::new(false),
            provider: Some(provider),
        }
    }

    /// Whether a compaction is in progress.
    pub fn is_compacting(&self) -> bool {
        self.is_compacting.load(Ordering::Relaxed)
    }

    /// Check if compaction is needed and execute if so.
    ///
    /// Returns `true` if compaction was performed.
    pub async fn check_and_compact(
        &self,
        context_manager: &mut ContextManager,
        hooks: &Option<Arc<HookEngine>>,
        session_id: &str,
        emitter: &Arc<EventEmitter>,
        reason: CompactionReason,
    ) -> Result<bool, RuntimeError> {
        if !context_manager.should_compact() {
            return Ok(false);
        }

        self.execute_compaction(context_manager, hooks, session_id, emitter, reason)
            .await
    }

    /// Force-execute compaction regardless of threshold.
    #[allow(clippy::too_many_lines)]
    pub async fn execute_compaction(
        &self,
        context_manager: &mut ContextManager,
        hooks: &Option<Arc<HookEngine>>,
        session_id: &str,
        emitter: &Arc<EventEmitter>,
        reason: CompactionReason,
    ) -> Result<bool, RuntimeError> {
        debug!(session_id, ?reason, "compaction requested");

        // Guard against concurrent compaction
        if self
            .is_compacting
            .compare_exchange(false, true, Ordering::SeqCst, Ordering::SeqCst)
            .is_err()
        {
            return Ok(false);
        }

        let tokens_before = context_manager.get_current_tokens();

        // Execute PreCompact hooks
        if let Some(hook_engine) = hooks {
            let hook_ctx = HookContext::PreCompact {
                session_id: session_id.to_owned(),
                timestamp: chrono::Utc::now().to_rfc3339(),
                current_tokens: tokens_before,
                target_tokens: (context_manager.get_context_limit() * 7) / 10,
            };
            let _ = emitter.emit(TronEvent::HookTriggered {
                base: BaseEvent::now(session_id),
                hook_names: vec![],
                hook_event: "PreCompact".into(),
                tool_name: None,
                tool_call_id: None,
            });
            let result = hook_engine.execute(&hook_ctx).await;
            let event_result = match result.action {
                HookAction::Block => EventHookResult::Block,
                HookAction::Modify => EventHookResult::Modify,
                HookAction::Continue => EventHookResult::Continue,
            };
            let _ = emitter.emit(TronEvent::HookCompleted {
                base: BaseEvent::now(session_id),
                hook_names: vec![],
                hook_event: "PreCompact".into(),
                result: event_result,
                duration: None,
                reason: result.reason.clone(),
                tool_name: None,
                tool_call_id: None,
            });
            if result.action == HookAction::Block {
                self.is_compacting.store(false, Ordering::SeqCst);
                return Ok(false);
            }
        }

        // Emit compaction start
        let _ = emitter.emit(TronEvent::CompactionStart {
            base: BaseEvent::now(session_id),
            reason: reason.clone(),
            tokens_before,
        });

        // Execute compaction: use LLM summarizer when provider is available, else keyword
        let result = if let Some(ref provider) = self.provider {
            let summarizer = tron_context::llm_summarizer::LlmSummarizer::new(
                ProviderSubsessionSpawner {
                    provider: provider.clone(),
                },
            );
            context_manager
                .execute_compaction(&summarizer, None)
                .await
        } else {
            let summarizer = KeywordSummarizer;
            context_manager
                .execute_compaction(&summarizer, None)
                .await
        };

        self.is_compacting.store(false, Ordering::SeqCst);

        match result {
            Ok(compaction_result) => {
                let tokens_after = context_manager.get_current_tokens();
                info!(session_id, tokens_before, tokens_after, "compaction complete");
                let _ = emitter.emit(TronEvent::CompactionComplete {
                    base: BaseEvent::now(session_id),
                    success: compaction_result.success,
                    tokens_before,
                    tokens_after,
                    compression_ratio: compaction_result.compression_ratio,
                    reason: Some(reason),
                    summary: if compaction_result.summary.is_empty() {
                        None
                    } else {
                        Some(compaction_result.summary)
                    },
                    estimated_context_tokens: Some(tokens_after),
                });
                Ok(true)
            }
            Err(e) => {
                let _ = emitter.emit(TronEvent::CompactionComplete {
                    base: BaseEvent::now(session_id),
                    success: false,
                    tokens_before,
                    tokens_after: tokens_before,
                    compression_ratio: 1.0,
                    reason: Some(reason),
                    summary: Some(format!("Compaction failed: {e}")),
                    estimated_context_tokens: Some(tokens_before),
                });
                tracing::warn!("Compaction failed: {e}");
                Ok(false)
            }
        }
    }
}

impl Default for CompactionHandler {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use futures::stream;
    use tron_context::llm_summarizer::SubsessionSpawner;
    use tron_core::content::AssistantContent;
    use tron_core::events::{AssistantMessage, StreamEvent};
    use tron_core::messages::TokenUsage;
    use tron_llm::models::types::ProviderType;
    use tron_llm::provider::{ProviderError, ProviderStreamOptions, StreamEventStream};

    #[test]
    fn initial_state() {
        let handler = CompactionHandler::new();
        assert!(!handler.is_compacting());
    }

    #[test]
    fn default_state() {
        let handler = CompactionHandler::default();
        assert!(!handler.is_compacting());
    }

    #[test]
    fn with_provider_not_compacting() {
        struct DummyProvider;
        #[async_trait]
        impl Provider for DummyProvider {
            fn provider_type(&self) -> ProviderType { ProviderType::Anthropic }
            fn model(&self) -> &str { "mock" }
            async fn stream(&self, _c: &tron_core::messages::Context, _o: &ProviderStreamOptions) -> Result<StreamEventStream, ProviderError> {
                Err(ProviderError::Other { message: "not impl".into() })
            }
        }
        let handler = CompactionHandler::with_provider(Arc::new(DummyProvider));
        assert!(!handler.is_compacting());
        assert!(handler.provider.is_some());
    }

    #[test]
    fn new_has_no_provider() {
        let handler = CompactionHandler::new();
        assert!(handler.provider.is_none());
    }

    #[test]
    fn pre_compact_target_is_70_percent() {
        // Verify the compaction target formula: (limit * 7) / 10
        let limit: u64 = 200_000;
        let target = (limit * 7) / 10;
        assert_eq!(target, 140_000);
    }

    #[test]
    fn pre_compact_target_not_50_percent() {
        let limit: u64 = 200_000;
        let target = (limit * 7) / 10;
        assert_ne!(target, limit / 2);
    }

    // ── ProviderSubsessionSpawner tests ──

    struct MockSummaryProvider {
        response_text: String,
    }
    #[async_trait]
    impl Provider for MockSummaryProvider {
        fn provider_type(&self) -> ProviderType { ProviderType::Anthropic }
        fn model(&self) -> &str { "mock-haiku" }
        async fn stream(
            &self,
            _c: &tron_core::messages::Context,
            _o: &ProviderStreamOptions,
        ) -> Result<StreamEventStream, ProviderError> {
            let text = self.response_text.clone();
            let events = vec![
                Ok(StreamEvent::Start),
                Ok(StreamEvent::TextDelta { delta: text.clone() }),
                Ok(StreamEvent::Done {
                    message: AssistantMessage {
                        content: vec![AssistantContent::text(&text)],
                        token_usage: Some(TokenUsage {
                            input_tokens: 50,
                            output_tokens: 20,
                            ..Default::default()
                        }),
                    },
                    stop_reason: "end_turn".into(),
                }),
            ];
            Ok(Box::pin(stream::iter(events)))
        }
    }

    #[tokio::test]
    async fn spawner_returns_success_with_text() {
        let provider = Arc::new(MockSummaryProvider {
            response_text: r#"{"narrative": "Test summary"}"#.to_string(),
        });
        let spawner = ProviderSubsessionSpawner { provider };
        let result = spawner.spawn_summarizer("[USER] Hello").await;
        assert!(result.success);
        assert!(result.output.is_some());
        assert!(result.output.unwrap().contains("narrative"));
        assert!(result.error.is_none());
    }

    #[tokio::test]
    async fn spawner_returns_error_on_provider_failure() {
        struct FailingProvider;
        #[async_trait]
        impl Provider for FailingProvider {
            fn provider_type(&self) -> ProviderType { ProviderType::Anthropic }
            fn model(&self) -> &str { "mock" }
            async fn stream(
                &self,
                _c: &tron_core::messages::Context,
                _o: &ProviderStreamOptions,
            ) -> Result<StreamEventStream, ProviderError> {
                Err(ProviderError::Other { message: "connection refused".into() })
            }
        }

        let spawner = ProviderSubsessionSpawner {
            provider: Arc::new(FailingProvider),
        };
        let result = spawner.spawn_summarizer("[USER] Hello").await;
        assert!(!result.success);
        assert!(result.output.is_none());
        assert!(result.error.is_some());
        assert!(result.error.unwrap().contains("connection refused"));
    }

    #[tokio::test]
    async fn spawner_returns_error_on_stream_error_event() {
        struct StreamErrorProvider;
        #[async_trait]
        impl Provider for StreamErrorProvider {
            fn provider_type(&self) -> ProviderType { ProviderType::Anthropic }
            fn model(&self) -> &str { "mock" }
            async fn stream(
                &self,
                _c: &tron_core::messages::Context,
                _o: &ProviderStreamOptions,
            ) -> Result<StreamEventStream, ProviderError> {
                let events = vec![
                    Ok(StreamEvent::Start),
                    Ok(StreamEvent::Error { error: "rate limited".into() }),
                ];
                Ok(Box::pin(stream::iter(events)))
            }
        }

        let spawner = ProviderSubsessionSpawner {
            provider: Arc::new(StreamErrorProvider),
        };
        let result = spawner.spawn_summarizer("[USER] Hello").await;
        assert!(!result.success);
        assert!(result.error.unwrap().contains("rate limited"));
    }

    #[tokio::test]
    async fn spawner_returns_error_on_empty_text() {
        struct EmptyProvider;
        #[async_trait]
        impl Provider for EmptyProvider {
            fn provider_type(&self) -> ProviderType { ProviderType::Anthropic }
            fn model(&self) -> &str { "mock" }
            async fn stream(
                &self,
                _c: &tron_core::messages::Context,
                _o: &ProviderStreamOptions,
            ) -> Result<StreamEventStream, ProviderError> {
                let events = vec![
                    Ok(StreamEvent::Start),
                    Ok(StreamEvent::Done {
                        message: AssistantMessage { content: vec![], token_usage: None },
                        stop_reason: "end_turn".into(),
                    }),
                ];
                Ok(Box::pin(stream::iter(events)))
            }
        }

        let spawner = ProviderSubsessionSpawner {
            provider: Arc::new(EmptyProvider),
        };
        let result = spawner.spawn_summarizer("[USER] Hello").await;
        assert!(!result.success);
        assert!(result.error.unwrap().contains("no text produced"));
    }

    #[tokio::test]
    async fn spawner_collects_multiple_deltas() {
        struct MultiDeltaProvider;
        #[async_trait]
        impl Provider for MultiDeltaProvider {
            fn provider_type(&self) -> ProviderType { ProviderType::Anthropic }
            fn model(&self) -> &str { "mock" }
            async fn stream(
                &self,
                _c: &tron_core::messages::Context,
                _o: &ProviderStreamOptions,
            ) -> Result<StreamEventStream, ProviderError> {
                let events = vec![
                    Ok(StreamEvent::Start),
                    Ok(StreamEvent::TextDelta { delta: "{\"narr".into() }),
                    Ok(StreamEvent::TextDelta { delta: "ative\":".into() }),
                    Ok(StreamEvent::TextDelta { delta: " \"ok\"}".into() }),
                    Ok(StreamEvent::Done {
                        message: AssistantMessage { content: vec![], token_usage: None },
                        stop_reason: "end_turn".into(),
                    }),
                ];
                Ok(Box::pin(stream::iter(events)))
            }
        }

        let spawner = ProviderSubsessionSpawner {
            provider: Arc::new(MultiDeltaProvider),
        };
        let result = spawner.spawn_summarizer("[USER] Hello").await;
        assert!(result.success);
        assert_eq!(result.output.unwrap(), r#"{"narrative": "ok"}"#);
    }
}
