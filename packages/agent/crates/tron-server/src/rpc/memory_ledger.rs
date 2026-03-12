//! Shared memory-ledger pipeline used by manual and automatic writes.

use std::sync::Arc;

use serde_json::Value;
use tracing::{debug, warn};

use tron_core::messages::{Message, UserMessageContent};
use tron_events::memory::types::LedgerWriteResult;
use tron_events::sqlite::row_types::{EventRow, SessionRow};
use tron_events::types::payloads::memory::{
    EventRange, LedgerDecision, LedgerFileEntry, LedgerTokenCost, MemoryLedgerPayload, TurnRange,
};
use tron_runtime::agent::compaction_handler::SubagentManagerSpawner;
use tron_runtime::context::ledger_writer::{LedgerEntry, LedgerParseResult};
use tron_runtime::context::llm_summarizer::SubsessionSpawner;
use tron_runtime::context::summarizer::serialize_messages;

/// Messages and metadata for the current ledger cycle.
pub struct CycleSnapshot {
    /// Messages in the cycle after the most recent ledger boundary.
    pub messages: Vec<Message>,
    /// First event ID covered by this cycle.
    pub first_event_id: String,
    /// Last event ID covered by this cycle.
    pub last_event_id: String,
    /// First user turn covered by this cycle.
    pub first_turn: i64,
    /// Last user turn covered by this cycle.
    pub last_turn: i64,
}

/// Dependencies for the shared ledger write pipeline.
pub struct LedgerWriteDeps {
    /// Event store for reading session history and persisting ledger events.
    pub event_store: Arc<tron_events::EventStore>,
    /// Subagent manager for spawning LLM summarizer sessions.
    pub subagent_manager:
        Option<Arc<tron_runtime::orchestrator::subagent_manager::SubagentManager>>,
    /// Embedding controller for fire-and-forget semantic vector indexing.
    pub embedding_controller: Option<Arc<tokio::sync::Mutex<tron_embeddings::EmbeddingController>>>,
    /// Shutdown coordinator for tracking in-flight embedding tasks.
    pub shutdown_coordinator: Option<Arc<crate::shutdown::ShutdownCoordinator>>,
}

/// Build the message cycle since the latest `memory.ledger` boundary.
pub fn build_cycle_snapshot(
    event_store: &tron_events::EventStore,
    session_id: &str,
) -> Result<Option<CycleSnapshot>, tron_events::EventStoreError> {
    let boundary = event_store.get_latest_event_by_type(session_id, "memory.ledger")?;

    let (cycle_events, prior_turns) = if let Some(boundary_event) = boundary {
        let payload = serde_json::from_str::<MemoryLedgerPayload>(&boundary_event.payload)
            .unwrap_or_default();
        (
            event_store.get_events_since(session_id, boundary_event.sequence)?,
            payload.turn_range.last_turn,
        )
    } else {
        (
            event_store.get_events_by_session(
                session_id,
                &tron_events::sqlite::repositories::event::ListEventsOptions {
                    limit: None,
                    offset: None,
                },
            )?,
            0,
        )
    };

    if cycle_events.is_empty() {
        return Ok(None);
    }

    let messages = reconstruct_core_messages(&cycle_events);
    if messages.is_empty() {
        return Ok(None);
    }

    #[allow(clippy::cast_possible_wrap)]
    let user_turns_in_cycle = messages.iter().filter(|message| message.is_user()).count() as i64;
    if user_turns_in_cycle == 0 {
        return Ok(None);
    }

    let first_event_id = cycle_events
        .first()
        .map(|event| event.id.clone())
        .unwrap_or_default();
    let last_event_id = cycle_events
        .last()
        .map(|event| event.id.clone())
        .unwrap_or_default();

    Ok(Some(CycleSnapshot {
        messages,
        first_event_id,
        last_event_id,
        first_turn: prior_turns + 1,
        last_turn: prior_turns + user_turns_in_cycle,
    }))
}

/// Execute the full ledger write pipeline.
pub async fn execute_ledger_write(
    session_id: &str,
    deps: &LedgerWriteDeps,
    source: &str,
) -> LedgerWriteResult {
    let event_store = deps.event_store.clone();
    let session_id_owned = session_id.to_owned();
    let session = match run_blocking_store("memory.load_session", move || {
        event_store.get_session(&session_id_owned)
    })
    .await
    {
        Ok(Ok(Some(session))) => session,
        Ok(Ok(None)) => return LedgerWriteResult::skipped("session not found or empty"),
        Ok(Err(error)) => return ledger_read_failure(session_id, &error),
        Err(_) => return LedgerWriteResult::failed("failed to load session history"),
    };

    if session.message_count == 0 {
        return LedgerWriteResult::skipped("no_messages");
    }

    let event_store = deps.event_store.clone();
    let session_id_owned = session_id.to_owned();
    let cycle = match run_blocking_store("memory.build_cycle", move || {
        build_cycle_snapshot(&event_store, &session_id_owned)
    })
    .await
    {
        Ok(Ok(Some(cycle))) => cycle,
        Ok(Ok(None)) => return LedgerWriteResult::skipped("no new messages since last boundary"),
        Ok(Err(error)) => return ledger_read_failure(session_id, &error),
        Err(_) => return LedgerWriteResult::failed("failed to load session history"),
    };

    let llm_result = summarize_cycle(session_id, &session, &cycle, deps, source).await;

    match llm_result {
        Some(LedgerParseResult::Skip) => {
            debug!(
                session_id,
                "LLM classified interaction as trivial, skipping"
            );
            LedgerWriteResult::skipped("trivial interaction")
        }
        Some(LedgerParseResult::Entry(entry)) => {
            let payload = build_ledger_payload(&cycle, &entry, &session, source);
            persist_and_embed(deps, session_id, &session, &entry, payload).await
        }
        None => LedgerWriteResult::skipped("LLM call failed"),
    }
}

async fn summarize_cycle(
    session_id: &str,
    session: &SessionRow,
    cycle: &CycleSnapshot,
    deps: &LedgerWriteDeps,
    source: &str,
) -> Option<LedgerParseResult> {
    let cycle_message_count = cycle.messages.len();
    let has_subagent = deps.subagent_manager.is_some();
    debug!(
        session_id,
        has_subagent, cycle_message_count, "executing ledger write"
    );

    let manager = deps.subagent_manager.as_ref()?;

    let transcript = if source == "cron" {
        let filtered = prepare_cron_transcript(&cycle.messages);
        if cron_assistant_text_len(&filtered) < 500 {
            debug!(
                session_id,
                "cron session had no meaningful assistant output, skipping ledger"
            );
            return Some(LedgerParseResult::Skip);
        }
        serialize_messages(&filtered)
    } else {
        serialize_messages(&cycle.messages)
    };

    let spawner = SubagentManagerSpawner {
        manager: manager.clone(),
        parent_session_id: session_id.to_owned(),
        working_directory: session.working_directory.clone(),
        system_prompt: tron_runtime::context::system_prompts::MEMORY_LEDGER_PROMPT.to_string(),
        model: Some("claude-haiku-4-5-20251001".to_string()),
    };
    let result = spawner.spawn_summarizer(&transcript).await;
    if result.success {
        result.output.as_deref().and_then(|output| {
            tron_runtime::context::ledger_writer::parse_ledger_response(output).ok()
        })
    } else {
        debug!(session_id, error = ?result.error, "subsession ledger call failed");
        None
    }
}

fn build_ledger_payload(
    cycle: &CycleSnapshot,
    entry: &LedgerEntry,
    session: &SessionRow,
    source: &str,
) -> MemoryLedgerPayload {
    MemoryLedgerPayload {
        event_range: EventRange {
            first_event_id: cycle.first_event_id.clone(),
            last_event_id: cycle.last_event_id.clone(),
        },
        turn_range: TurnRange {
            first_turn: cycle.first_turn,
            last_turn: cycle.last_turn,
        },
        title: entry.title.clone(),
        entry_type: entry.entry_type.clone(),
        status: entry.status.clone(),
        tags: entry.tags.clone(),
        input: entry.input.clone(),
        actions: entry.actions.clone(),
        files: entry
            .files
            .iter()
            .map(|file| LedgerFileEntry {
                path: file.path.clone(),
                op: file.op.clone(),
                why: file.why.clone(),
            })
            .collect(),
        decisions: entry
            .decisions
            .iter()
            .map(|decision| LedgerDecision {
                choice: decision.choice.clone(),
                reason: decision.reason.clone(),
            })
            .collect(),
        lessons: entry.lessons.clone(),
        thinking_insights: entry.thinking_insights.clone(),
        token_cost: LedgerTokenCost {
            input: session.total_input_tokens,
            output: session.total_output_tokens,
        },
        model: session.latest_model.clone(),
        working_directory: session.working_directory.clone(),
        source: source.to_string(),
    }
}

async fn persist_and_embed(
    deps: &LedgerWriteDeps,
    session_id: &str,
    session: &SessionRow,
    entry: &LedgerEntry,
    payload: MemoryLedgerPayload,
) -> LedgerWriteResult {
    let payload_json = serde_json::to_value(&payload).unwrap_or_else(|error| {
        warn!(
            session_id,
            error = %error,
            "failed to serialize memory ledger payload"
        );
        Value::Null
    });

    let event_store = deps.event_store.clone();
    let session_id_owned = session_id.to_owned();
    let payload_for_write = payload_json.clone();
    let event_id = match run_blocking_store("memory.persist_ledger", move || {
        event_store.append(&tron_events::AppendOptions {
            session_id: &session_id_owned,
            event_type: tron_events::EventType::MemoryLedger,
            payload: payload_for_write,
            parent_id: None,
        })
    })
    .await
    {
        Ok(Ok(row)) => row.id,
        Ok(Err(error)) => {
            warn!(
                session_id,
                error = %error,
                title = %entry.title,
                "failed to persist memory.ledger event"
            );
            return match error {
                tron_events::EventStoreError::Busy { .. } => {
                    LedgerWriteResult::failed("database temporarily busy")
                }
                _ => LedgerWriteResult::failed("failed to persist ledger entry"),
            };
        }
        Err(_) => return LedgerWriteResult::failed("failed to persist ledger entry"),
    };

    spawn_embed_memory(
        deps.embedding_controller.as_ref(),
        &event_id,
        &session.workspace_id,
        &payload_json,
        deps.shutdown_coordinator.as_ref(),
    );

    debug!(
        session_id,
        title = %entry.title,
        entry_type = %entry.entry_type,
        event_id = %event_id,
        "ledger entry written"
    );

    LedgerWriteResult::written(
        entry.title.clone(),
        entry.entry_type.clone(),
        event_id,
        payload_json,
    )
}

fn ledger_read_failure(
    session_id: &str,
    error: &tron_events::EventStoreError,
) -> LedgerWriteResult {
    warn!(session_id, error = %error, "failed to load memory ledger context");
    match error {
        tron_events::EventStoreError::Busy { .. } => {
            LedgerWriteResult::failed("database temporarily busy")
        }
        _ => LedgerWriteResult::failed("failed to load session history"),
    }
}

fn reconstruct_core_messages(rows: &[EventRow]) -> Vec<Message> {
    let events = tron_events::event_rows_to_session_events(rows);
    tron_events::reconstruct_from_events(&events)
        .messages_with_event_ids
        .into_iter()
        .filter_map(|message| {
            serde_json::to_value(message.message)
                .ok()
                .and_then(|json| serde_json::from_value(json).ok())
        })
        .collect()
}

/// Spawn a fire-and-forget embedding task.
fn spawn_embed_memory(
    controller: Option<&Arc<tokio::sync::Mutex<tron_embeddings::EmbeddingController>>>,
    event_id: &str,
    workspace_id: &str,
    payload: &Value,
    shutdown_coordinator: Option<&Arc<crate::shutdown::ShutdownCoordinator>>,
) {
    if let Some(controller) = controller {
        let controller = Arc::clone(controller);
        let event_id = event_id.to_owned();
        let workspace_id = workspace_id.to_owned();
        let payload = payload.clone();
        let handle = tokio::spawn(async move {
            let controller = controller.lock().await;
            if let Err(error) = controller
                .embed_memory(&event_id, &workspace_id, &payload)
                .await
            {
                warn!(error = %error, event_id, "failed to embed ledger entry");
            }
        });
        if let Some(coordinator) = shutdown_coordinator {
            coordinator.register_task(handle);
        }
    }
}

/// Prepare transcript for a cron session by stripping long boilerplate user prompts.
pub fn prepare_cron_transcript(messages: &[Message]) -> Vec<Message> {
    messages
        .iter()
        .map(|message| {
            if let Message::User { content, .. } = message
                && user_message_len(content) > 500
            {
                return Message::User {
                    content: UserMessageContent::Text(
                        "[Recurring cron task prompt omitted — focus on the assistant's actions below]".into(),
                    ),
                    timestamp: None,
                };
            }
            message.clone()
        })
        .collect()
}

/// Total text length across all assistant messages.
pub fn cron_assistant_text_len(messages: &[Message]) -> usize {
    messages
        .iter()
        .map(|message| {
            if let Message::Assistant { content, .. } = message {
                content
                    .iter()
                    .filter_map(|block| block.as_text())
                    .map(str::len)
                    .sum::<usize>()
            } else {
                0
            }
        })
        .sum()
}

pub(crate) fn user_message_len(content: &UserMessageContent) -> usize {
    match content {
        UserMessageContent::Text(text) => text.len(),
        UserMessageContent::Blocks(blocks) => blocks
            .iter()
            .filter_map(|block| block.as_text())
            .map(str::len)
            .sum(),
    }
}

async fn run_blocking_store<T, F>(
    _task_name: &'static str,
    f: F,
) -> Result<T, tokio::task::JoinError>
where
    T: Send + 'static,
    F: FnOnce() -> T + Send + 'static,
{
    tokio::task::spawn_blocking(f).await
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::rpc::handlers::test_helpers::make_test_context;
    use futures::stream;
    use serde_json::json;
    use tron_core::content::AssistantContent;
    use tron_core::events::{AssistantMessage, StreamEvent};
    use tron_core::messages::TokenUsage;
    use tron_llm::models::types::Provider as LlmProvider;
    use tron_llm::provider::{
        Provider, ProviderError, ProviderFactory, ProviderStreamOptions, StreamEventStream,
    };

    const LEDGER_JSON: &str =
        r#"{"title":"Ledger test","entryType":"research","input":"test","actions":["done"]}"#;

    #[tokio::test]
    async fn cycle_snapshot_without_boundary_returns_full_range() {
        let ctx = make_test_context();
        let sid = ctx
            .session_manager
            .create_session("claude-opus-4-6", "/tmp/project", Some("test"))
            .unwrap();

        let _ = ctx.event_store.append(&tron_events::AppendOptions {
            session_id: &sid,
            event_type: tron_events::EventType::MessageUser,
            payload: json!({"content": "Hello"}),
            parent_id: None,
        });
        let _ = ctx.event_store.append(&tron_events::AppendOptions {
            session_id: &sid,
            event_type: tron_events::EventType::MessageAssistant,
            payload: json!({
                "content": [{"type": "text", "text": "Hi"}],
                "turn": 1,
                "tokenUsage": {"inputTokens": 5, "outputTokens": 3}
            }),
            parent_id: None,
        });

        let cycle = build_cycle_snapshot(&ctx.event_store, &sid)
            .unwrap()
            .expect("cycle");

        assert_eq!(cycle.first_turn, 1);
        assert_eq!(cycle.last_turn, 1);
        assert_eq!(cycle.messages.len(), 2);
        assert_eq!(
            cycle.first_event_id,
            ctx.event_store
                .get_events_by_session(
                    &sid,
                    &tron_events::sqlite::repositories::event::ListEventsOptions {
                        limit: None,
                        offset: None,
                    },
                )
                .unwrap()
                .first()
                .unwrap()
                .id
        );
    }

    #[tokio::test]
    async fn cycle_snapshot_uses_boundary_turn_range_instead_of_rescanning_history() {
        let ctx = make_test_context();
        let sid = ctx
            .session_manager
            .create_session("claude-opus-4-6", "/tmp/project", Some("test"))
            .unwrap();

        for turn in 1..=3 {
            let _ = ctx.event_store.append(&tron_events::AppendOptions {
                session_id: &sid,
                event_type: tron_events::EventType::MessageUser,
                payload: json!({"content": format!("Request {turn}")}),
                parent_id: None,
            });
            let _ = ctx.event_store.append(&tron_events::AppendOptions {
                session_id: &sid,
                event_type: tron_events::EventType::MessageAssistant,
                payload: json!({
                    "content": [{"type": "text", "text": format!("Response {turn}")}],
                    "turn": turn,
                    "tokenUsage": {"inputTokens": 10, "outputTokens": 5}
                }),
                parent_id: None,
            });
        }

        let _ = ctx.event_store.append(&tron_events::AppendOptions {
            session_id: &sid,
            event_type: tron_events::EventType::MemoryLedger,
            payload: json!({
                "turnRange": {"firstTurn": 1, "lastTurn": 3},
                "title": "First three turns"
            }),
            parent_id: None,
        });

        let _ = ctx.event_store.append(&tron_events::AppendOptions {
            session_id: &sid,
            event_type: tron_events::EventType::MessageUser,
            payload: json!({"content": "Fourth request"}),
            parent_id: None,
        });
        let _ = ctx.event_store.append(&tron_events::AppendOptions {
            session_id: &sid,
            event_type: tron_events::EventType::MessageAssistant,
            payload: json!({
                "content": [{"type": "text", "text": "Fourth response"}],
                "turn": 4,
                "tokenUsage": {"inputTokens": 10, "outputTokens": 5}
            }),
            parent_id: None,
        });

        let cycle = build_cycle_snapshot(&ctx.event_store, &sid)
            .unwrap()
            .expect("cycle");

        assert_eq!(cycle.first_turn, 4);
        assert_eq!(cycle.last_turn, 4);
        assert_eq!(cycle.messages.len(), 2);
        match &cycle.messages[0] {
            Message::User { content, .. } => match content {
                UserMessageContent::Text(text) => assert_eq!(text, "Fourth request"),
                UserMessageContent::Blocks(_) => panic!("expected text user message"),
            },
            other => panic!("expected user message, got {other:?}"),
        }
    }

    #[tokio::test]
    async fn cycle_snapshot_skips_assistant_only_tail() {
        let ctx = make_test_context();
        let sid = ctx
            .session_manager
            .create_session("claude-opus-4-6", "/tmp/project", Some("test"))
            .unwrap();

        let _ = ctx.event_store.append(&tron_events::AppendOptions {
            session_id: &sid,
            event_type: tron_events::EventType::MemoryLedger,
            payload: json!({
                "turnRange": {"firstTurn": 1, "lastTurn": 1},
                "title": "Boundary"
            }),
            parent_id: None,
        });
        let _ = ctx.event_store.append(&tron_events::AppendOptions {
            session_id: &sid,
            event_type: tron_events::EventType::MessageAssistant,
            payload: json!({
                "content": [{"type": "text", "text": "orphan"}],
                "turn": 2
            }),
            parent_id: None,
        });

        assert!(
            build_cycle_snapshot(&ctx.event_store, &sid)
                .unwrap()
                .is_none()
        );
    }

    struct LedgerMockProvider;

    #[async_trait::async_trait]
    impl Provider for LedgerMockProvider {
        fn provider_type(&self) -> LlmProvider {
            LlmProvider::Anthropic
        }

        fn model(&self) -> &'static str {
            "mock-ledger"
        }

        async fn stream(
            &self,
            _context: &tron_core::messages::Context,
            _options: &ProviderStreamOptions,
        ) -> Result<StreamEventStream, ProviderError> {
            let stream = stream::iter(vec![
                Ok(StreamEvent::Start),
                Ok(StreamEvent::TextDelta {
                    delta: LEDGER_JSON.into(),
                }),
                Ok(StreamEvent::Done {
                    message: AssistantMessage {
                        content: vec![AssistantContent::text(LEDGER_JSON)],
                        token_usage: Some(TokenUsage {
                            input_tokens: 10,
                            output_tokens: 5,
                            ..Default::default()
                        }),
                    },
                    stop_reason: "end_turn".into(),
                }),
            ]);
            Ok(Box::pin(stream))
        }
    }

    struct LedgerMockProviderFactory;

    #[async_trait::async_trait]
    impl ProviderFactory for LedgerMockProviderFactory {
        async fn create_for_model(&self, _model: &str) -> Result<Arc<dyn Provider>, ProviderError> {
            Ok(Arc::new(LedgerMockProvider))
        }
    }

    #[tokio::test]
    async fn execute_ledger_write_uses_session_working_directory() {
        let ctx = make_test_context();
        let sid = ctx
            .session_manager
            .create_session("mock", "/tmp/real-working-dir", Some("test"))
            .unwrap();

        let _ = ctx.event_store.append(&tron_events::AppendOptions {
            session_id: &sid,
            event_type: tron_events::EventType::MessageUser,
            payload: json!({"content": "Do the work"}),
            parent_id: None,
        });
        let _ = ctx.event_store.append(&tron_events::AppendOptions {
            session_id: &sid,
            event_type: tron_events::EventType::MessageAssistant,
            payload: json!({
                "content": [{"type": "text", "text": "Completed the work"}],
                "turn": 1,
                "tokenUsage": {"inputTokens": 10, "outputTokens": 5}
            }),
            parent_id: None,
        });

        let broadcast = Arc::new(tron_runtime::EventEmitter::new());
        let subagent = Arc::new(
            tron_runtime::orchestrator::subagent_manager::SubagentManager::new(
                ctx.session_manager.clone(),
                ctx.event_store.clone(),
                broadcast,
                Arc::new(LedgerMockProviderFactory),
                None,
                None,
            ),
        );
        subagent.set_tool_factory(Arc::new(tron_tools::registry::ToolRegistry::new));

        let deps = LedgerWriteDeps {
            event_store: ctx.event_store.clone(),
            subagent_manager: Some(subagent),
            embedding_controller: None,
            shutdown_coordinator: None,
        };

        let result = execute_ledger_write(&sid, &deps, "auto").await;
        assert!(result.written, "expected ledger write to succeed");

        let events = ctx
            .event_store
            .get_events_by_type(&sid, &["memory.ledger"], Some(10))
            .unwrap();
        let payload: MemoryLedgerPayload = serde_json::from_str(&events[0].payload).unwrap();
        assert_eq!(payload.working_directory, "/tmp/real-working-dir");
        assert_eq!(payload.source, "auto");
    }
}
