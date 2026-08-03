//! Crash-recoverable provider stream processing for one admitted turn.
//!
//! A streaming journal is mandatory before provider bytes are consumed. This
//! phase returns only a complete, non-interrupted stream; stream failure and
//! cancellation durably terminalize the turn and clean the journal themselves.

use std::sync::Arc;
use std::sync::atomic::AtomicI64;

use metrics::{counter, histogram};
use tracing::{error, info, trace, warn};

use crate::domains::agent::r#loop::event_emitter::EventEmitter;
use crate::domains::agent::r#loop::orchestrator::event_persister::EventPersister;
use crate::domains::agent::r#loop::orchestrator::streaming_journal::StreamingJournal;
use crate::domains::agent::r#loop::stream_processor;
use crate::domains::agent::r#loop::types::{RunContext, StreamResult, TurnResult};
use crate::domains::model::responder::{ModelResponderInfo, ModelResponse};
use crate::shared::server::failure::{
    FailureCategory, FailureEnvelope, FailureOrigin, JOURNAL_CREATE_FAILED,
};

use super::failure::{emit_turn_failure, terminalize_interrupted_turn};
use super::persistence::{build_failed_message_payload, build_interrupted_message_payload};
use super::{interrupted_turn_result, terminalization_error_result, terminalize_cancellation};

pub(super) struct StreamPhaseParams<'a> {
    pub turn: u32,
    pub response: ModelResponse,
    pub session_id: &'a str,
    pub emitter: &'a Arc<EventEmitter>,
    pub cancel: &'a tokio_util::sync::CancellationToken,
    pub run_context: &'a RunContext,
    pub persister: Option<&'a EventPersister>,
    pub previous_context_baseline: u64,
    pub sequence_counter: Option<&'a AtomicI64>,
}

pub(super) struct ProcessedProviderStream {
    pub info: ModelResponderInfo,
    pub stream_result: StreamResult,
    pub journal: StreamingJournal,
}

pub(super) async fn process_provider_stream(
    params: StreamPhaseParams<'_>,
) -> Result<ProcessedProviderStream, TurnResult> {
    let info = params.response.info;
    let stream = params.response.stream;
    let provider_name = info.provider_name;
    let provider_type = info.provider_type;
    let model_name = info.model.as_str();
    let run_id = params.run_context.run_id.as_deref().unwrap_or("none");
    let trace_id = params
        .run_context
        .engine_trace_id
        .as_ref()
        .map(|id| id.as_str())
        .unwrap_or("none");
    info!(
        component = "agent.provider",
        agent_event = "model_stream_opened",
        session_id = params.session_id,
        run_id,
        trace_id,
        turn = params.turn,
        provider = provider_name,
        provider_type = %provider_type.as_str(),
        model = %model_name,
        "model response stream opened"
    );

    let mut journal = match StreamingJournal::create(params.session_id, params.turn) {
        Ok(journal) => journal,
        Err(error) => {
            let error_msg = format!(
                "failed to create streaming journal for crash recovery: {error}. Check that ~/.tron/internal/database/journals/ is writable."
            );
            error!(session_id = params.session_id, turn = params.turn, error = %error_msg);
            let failure = FailureEnvelope::new(
                JOURNAL_CREATE_FAILED,
                FailureCategory::Persistence,
                error_msg.clone(),
                false,
                false,
                FailureOrigin::AgentRuntime,
            );
            emit_turn_failure(
                params.emitter,
                params.persister,
                params.session_id,
                params.turn,
                params.run_context,
                params.sequence_counter,
                &failure,
                None,
            );
            return Err(TurnResult {
                success: false,
                error: Some(error_msg),
                stop_reason: Some(crate::domains::agent::r#loop::errors::StopReason::Error),
                ..Default::default()
            });
        }
    };
    trace!(
        component = "agent.stream",
        agent_event = "streaming_journal_created",
        session_id = params.session_id,
        run_id,
        trace_id,
        turn = params.turn,
        "streaming journal created"
    );

    let stream_result = match stream_processor::process_stream_with_trace(
        stream,
        params.session_id,
        params.emitter,
        params.cancel,
        params.sequence_counter,
        Some(&mut journal),
        params.run_context.engine_trace_id.as_ref(),
        params.run_context.parent_invocation_id.as_ref(),
    )
    .await
    {
        Ok(result) => result,
        Err(stream_failure) => {
            let error_msg = stream_failure.error.to_string();
            error!(session_id = params.session_id, turn = params.turn, error = %error_msg, "stream failed");
            let failure = stream_failure.error.to_failure();
            let partial_content = stream_failure.partial.partial_content.clone();
            let token_usage = stream_failure.partial.token_usage.clone();
            let assistant_payload = build_failed_message_payload(
                &stream_failure.partial.message,
                stream_failure.partial.token_usage.as_ref(),
                params.session_id,
                params.turn,
                model_name,
                provider_type,
                params.previous_context_baseline,
            );
            let terminalized = terminalize_interrupted_turn(
                params.emitter,
                params.persister,
                params.session_id,
                params.turn,
                params.run_context,
                params.sequence_counter,
                &failure,
                assistant_payload,
                partial_content.clone(),
            );
            if terminalized.is_ok()
                && let Err(cleanup_error) = journal.finalize_and_delete()
            {
                warn!(
                    session_id = params.session_id,
                    turn = params.turn,
                    error = %cleanup_error,
                    "failed to finalize streaming journal after durable turn failure"
                );
            }
            return Err(TurnResult {
                success: false,
                error: Some(if let Err(terminal_error) = terminalized {
                    format!("{error_msg}; failed to persist stream failure: {terminal_error}")
                } else {
                    error_msg
                }),
                token_usage,
                stop_reason: Some(crate::domains::agent::r#loop::errors::StopReason::Error),
                partial_content,
                ..Default::default()
            });
        }
    };
    info!(
        component = "agent.stream",
        agent_event = "model_stream_completed",
        session_id = params.session_id,
        run_id,
        trace_id,
        turn = params.turn,
        provider = provider_name,
        model = %model_name,
        stop_reason = %stream_result.stop_reason,
        tool_invocation_count = stream_result.tool_invocations.len(),
        has_token_usage = stream_result.token_usage.is_some(),
        ttft_ms = stream_result.ttft_ms.unwrap_or_default(),
        interrupted = stream_result.interrupted,
        "model response stream completed"
    );

    if let Some(ttft) = stream_result.ttft_ms {
        histogram!("provider_ttft_seconds", "provider" => provider_name).record({
            #[allow(clippy::cast_precision_loss)]
            let seconds = ttft as f64 / 1000.0;
            seconds
        });
    }
    if let Some(usage) = &stream_result.token_usage {
        counter!("llm_tokens_total", "provider" => provider_name, "direction" => "input")
            .increment(usage.input_tokens);
        counter!("llm_tokens_total", "provider" => provider_name, "direction" => "output")
            .increment(usage.output_tokens);
        let cache_read = usage.cache_read_tokens.unwrap_or(0);
        let cache_write = usage.cache_creation_tokens.unwrap_or_else(|| {
            usage.cache_creation_5m_tokens.unwrap_or(0)
                + usage.cache_creation_1h_tokens.unwrap_or(0)
        });
        counter!(
            "provider_prompt_cache_tokens_total",
            "provider" => provider_name,
            "operation" => "read"
        )
        .increment(cache_read);
        counter!(
            "provider_prompt_cache_tokens_total",
            "provider" => provider_name,
            "operation" => "write"
        )
        .increment(cache_write);
        let effective_input =
            if provider_type == crate::shared::protocol::messages::Provider::Anthropic {
                usage
                    .input_tokens
                    .saturating_add(cache_read)
                    .saturating_add(cache_write)
            } else {
                usage.input_tokens
            };
        if effective_input > 0 {
            #[allow(clippy::cast_precision_loss)]
            histogram!(
                "provider_prompt_cache_read_ratio",
                "provider" => provider_name
            )
            .record(cache_read as f64 / effective_input as f64);
        }
    }

    if stream_result.interrupted {
        let assistant_payload = build_interrupted_message_payload(
            &stream_result.message,
            stream_result.token_usage.as_ref(),
            params.session_id,
            params.turn,
            model_name,
            provider_type,
            params.previous_context_baseline,
        );
        let partial_content = stream_result.partial_content.clone();
        let terminalized = terminalize_cancellation(
            params.emitter,
            params.persister,
            params.session_id,
            params.turn,
            params.run_context,
            params.sequence_counter,
            assistant_payload,
            partial_content.clone(),
        );
        if terminalized.is_ok()
            && let Err(error) = journal.finalize_and_delete()
        {
            warn!(
                session_id = params.session_id,
                turn = params.turn,
                error = %error,
                "failed to finalize streaming journal after interruption"
            );
        }
        return Err(match terminalized {
            Ok(()) => interrupted_turn_result(partial_content, stream_result.token_usage),
            Err(error) => {
                terminalization_error_result(error, partial_content, stream_result.token_usage)
            }
        });
    }

    Ok(ProcessedProviderStream {
        info,
        stream_result,
        journal,
    })
}
