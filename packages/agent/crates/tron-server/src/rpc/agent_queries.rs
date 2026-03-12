//! Shared query-side services for agent RPC handlers.

use serde_json::{Value, json};

use crate::rpc::context::RpcContext;
use crate::rpc::errors::RpcError;

pub(crate) struct AgentQueryService;

impl AgentQueryService {
    pub(crate) async fn get_state(ctx: &RpcContext, session_id: String) -> Result<Value, RpcError> {
        let is_running = ctx.orchestrator.has_active_run(&session_id);
        let run_id = ctx.orchestrator.get_run_id(&session_id);

        let tool_names: Vec<String> = ctx
            .agent_deps
            .as_ref()
            .map(|deps| (deps.tool_factory)().names())
            .unwrap_or_default();

        let (current_turn_text, current_turn_tool_calls, content_sequence) = if is_running {
            tracing::trace!(
                session_id = %session_id,
                "agent.getState: session is running, fetching accumulator"
            );
            if let Some((text, tools, seq)) =
                ctx.orchestrator.turn_accumulators().get_state(&session_id)
            {
                tracing::trace!(
                    session_id = %session_id,
                    text_len = text.len(),
                    tool_count = tools.as_array().map_or(0, std::vec::Vec::len),
                    seq_count = seq.as_array().map_or(0, std::vec::Vec::len),
                    "agent.getState: returning accumulated content"
                );
                (Some(Value::String(text)), Some(tools), Some(seq))
            } else {
                tracing::warn!(
                    session_id = %session_id,
                    "agent.getState: no accumulator found despite isRunning=true"
                );
                (None, None, None)
            }
        } else {
            (None, None, None)
        };

        let session_manager = ctx.session_manager.clone();
        let event_store = ctx.event_store.clone();
        let session_id_for_lookup = session_id.clone();
        let (
            model,
            current_turn,
            message_count,
            total_input,
            total_output,
            cache_read,
            cache_creation,
            was_interrupted,
        ) = ctx
            .run_blocking("agent.get_state", move || {
                let metadata = if let Ok(Some(session)) =
                    session_manager.get_session(&session_id_for_lookup)
                {
                    (
                        session.latest_model.clone(),
                        session.turn_count,
                        session.message_count,
                        session.total_input_tokens,
                        session.total_output_tokens,
                        session.total_cache_read_tokens,
                        session.total_cache_creation_tokens,
                    )
                } else {
                    (String::new(), 0, 0, 0, 0, 0, 0)
                };

                let was_interrupted = if is_running {
                    false
                } else {
                    event_store
                        .was_session_interrupted(&session_id_for_lookup)
                        .unwrap_or(false)
                };

                Ok((
                    metadata.0,
                    metadata.1,
                    metadata.2,
                    metadata.3,
                    metadata.4,
                    metadata.5,
                    metadata.6,
                    was_interrupted,
                ))
            })
            .await?;

        Ok(json!({
            "sessionId": session_id,
            "isRunning": is_running,
            "currentTurn": current_turn,
            "messageCount": message_count,
            "model": model,
            "runId": run_id,
            "tokenUsage": {
                "input": total_input,
                "output": total_output,
                "cacheReadTokens": cache_read,
                "cacheCreationTokens": cache_creation,
            },
            "tools": tool_names,
            "wasInterrupted": was_interrupted,
            "currentTurnText": current_turn_text,
            "currentTurnToolCalls": current_turn_tool_calls,
            "contentSequence": content_sequence,
        }))
    }
}
