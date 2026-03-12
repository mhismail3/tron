use std::sync::Arc;

use serde_json::Value;
use tracing::{debug, warn};

use tron_events::memory::types::LedgerWriteResult;
use tron_events::sqlite::row_types::SessionRow;
use tron_events::types::payloads::memory::{
    EventRange, LedgerDecision, LedgerFileEntry, LedgerTokenCost, MemoryLedgerPayload, TurnRange,
};
use tron_runtime::agent::compaction_handler::SubagentManagerSpawner;
use tron_runtime::context::ledger_writer::{LedgerEntry, LedgerParseResult};
use tron_runtime::context::llm_summarizer::SubsessionSpawner;
use tron_runtime::context::summarizer::serialize_messages;

use super::{CycleSnapshot, LedgerWriteDeps, cron_assistant_text_len, prepare_cron_transcript};

/// Execute the full ledger write pipeline.
pub async fn execute_ledger_write(
    session_id: &str,
    deps: &LedgerWriteDeps,
    source: &str,
) -> LedgerWriteResult {
    let event_store = deps.event_store.clone();
    let session_id_owned = session_id.to_owned();
    let session = match run_store_task("memory.load_session", move || {
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
    let cycle = match run_store_task("memory.build_cycle", move || {
        super::build_cycle_snapshot(&event_store, &session_id_owned)
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
    let event_id = match run_store_task("memory.persist_ledger", move || {
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

async fn run_store_task<T, F>(
    task_name: &'static str,
    f: F,
) -> Result<Result<T, tron_events::EventStoreError>, crate::rpc::errors::RpcError>
where
    T: Send + 'static,
    F: FnOnce() -> Result<T, tron_events::EventStoreError> + Send + 'static,
{
    crate::rpc::context::run_blocking_task(task_name, move || {
        Ok::<_, crate::rpc::errors::RpcError>(f())
    })
    .await
}
