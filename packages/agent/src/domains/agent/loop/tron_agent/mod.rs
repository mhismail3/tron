//! `TronAgent` multi-turn primitive loop.

use std::sync::Arc;
use std::sync::atomic::{AtomicBool, AtomicI64, AtomicU32, Ordering};

use crate::domains::agent::context::context_manager::ContextManager;
use crate::domains::agent::r#loop::compaction_handler::CompactionHandler;
use crate::domains::agent::r#loop::errors::StopReason;
use crate::domains::agent::r#loop::event_emitter::EventEmitter;
use crate::domains::agent::r#loop::orchestrator::event_persister::EventPersister;
use crate::domains::agent::r#loop::orchestrator::invocation_abort_registry::InvocationAbortRegistry;
use crate::domains::agent::r#loop::turn_runner;
use crate::domains::agent::r#loop::types::{AgentConfig, RunContext, RunResult};
use crate::domains::model::responder::ModelResponder;
use crate::shared::protocol::events::{BaseEvent, TronEvent};
use crate::shared::protocol::messages::{Message, TokenUsage, UserMessageContent};
use tokio::sync::broadcast;
use tokio_util::sync::CancellationToken;
use tracing::{debug, error, info, instrument, warn};

struct RunGuard<'a> {
    flag: &'a AtomicBool,
}

impl<'a> RunGuard<'a> {
    fn new(flag: &'a AtomicBool) -> Option<Self> {
        flag.compare_exchange(false, true, Ordering::SeqCst, Ordering::SeqCst)
            .ok()
            .map(|_| Self { flag })
    }
}

impl Drop for RunGuard<'_> {
    fn drop(&mut self) {
        self.flag.store(false, Ordering::SeqCst);
    }
}

pub struct AgentDeps {
    pub responder: Arc<dyn ModelResponder>,
    pub context_manager: ContextManager,
    pub compaction_trigger_config: crate::domains::agent::context::types::CompactionTriggerConfig,
    pub engine_host: Option<crate::engine::EngineHostHandle>,
}

pub struct TronAgent {
    config: AgentConfig,
    responder: Arc<dyn ModelResponder>,
    context_manager: ContextManager,
    emitter: Arc<EventEmitter>,
    compaction: Arc<CompactionHandler>,
    session_id: String,
    completed_turn_offset: AtomicU32,
    current_turn: AtomicU32,
    is_running: AtomicBool,
    abort_token: CancellationToken,
    external_abort_token: bool,
    persister: Option<Arc<EventPersister>>,
    sequence_counter: Option<Arc<AtomicI64>>,
    invocation_abort_registry: Option<Arc<InvocationAbortRegistry>>,
    engine_host: Option<crate::engine::EngineHostHandle>,
}

impl TronAgent {
    pub fn new(config: AgentConfig, deps: AgentDeps, session_id: String) -> Self {
        Self {
            config,
            responder: deps.responder,
            context_manager: deps.context_manager,
            emitter: Arc::new(EventEmitter::new()),
            compaction: Arc::new(CompactionHandler::new(deps.compaction_trigger_config)),
            session_id,
            completed_turn_offset: AtomicU32::new(0),
            current_turn: AtomicU32::new(0),
            is_running: AtomicBool::new(false),
            abort_token: CancellationToken::new(),
            external_abort_token: false,
            persister: None,
            sequence_counter: None,
            invocation_abort_registry: None,
            engine_host: deps.engine_host,
        }
    }

    #[allow(clippy::too_many_lines)]
    #[instrument(skip(self, ctx), fields(session_id = %self.session_id, model = %self.config.model))]
    pub async fn run(&mut self, content: &str, mut ctx: RunContext) -> RunResult {
        let Some(_guard) = RunGuard::new(&self.is_running) else {
            warn!(
                component = "agent.loop",
                agent_event = "agent_run_rejected_already_running",
                session_id = %self.session_id,
                model = %self.config.model,
                "agent run rejected because the session is already running"
            );
            return RunResult {
                stop_reason: StopReason::Error,
                error: Some("Agent is already running".into()),
                ..Default::default()
            };
        };

        if !self.external_abort_token {
            self.abort_token = CancellationToken::new();
        }
        self.current_turn.store(0, Ordering::Relaxed);

        let mut total_usage = TokenUsage::default();
        let mut final_stop_reason = StopReason::EndTurn;
        let mut interrupted = false;
        let mut error: Option<String> = None;

        let user_content = ctx
            .user_content_override
            .take()
            .unwrap_or_else(|| UserMessageContent::Text(content.to_owned()));
        let user_content_kind = match &user_content {
            UserMessageContent::Text(_) => "text",
            UserMessageContent::Blocks(_) => "blocks",
        };
        self.context_manager.add_message(Message::User {
            content: user_content,
            timestamp: None,
        });

        let run_base = |session_id: &str| {
            BaseEvent::now(session_id).with_trace_context(
                ctx.engine_trace_id
                    .as_ref()
                    .map(|id| id.as_str().to_owned()),
                ctx.parent_invocation_id
                    .as_ref()
                    .map(|id| id.as_str().to_owned()),
            )
        };

        self.emit_run_event(TronEvent::AgentStart {
            base: run_base(&self.session_id),
        });
        self.emit_run_event(TronEvent::SessionProcessingChanged {
            base: run_base(&self.session_id),
            is_processing: true,
        });

        info!(
            component = "agent.loop",
            agent_event = "agent_run_started",
            session_id = %self.session_id,
            run_id = ctx.run_id.as_deref().unwrap_or("none"),
            trace_id = ctx.engine_trace_id.as_ref().map(|id| id.as_str()).unwrap_or("none"),
            parent_invocation_id = ctx.parent_invocation_id.as_ref().map(|id| id.as_str()).unwrap_or("none"),
            model = %self.config.model,
            max_turns = self.config.max_turns,
            user_content_kind,
            has_agent_state_context = ctx.agent_state_context.is_some(),
            "agent run started"
        );

        let max_turns = self.config.max_turns;
        let turn_offset = self.completed_turn_offset.load(Ordering::Relaxed);
        let mut run_turn = 0u32;
        let mut exited_via_break = false;
        let mut previous_context_baseline =
            self.context_manager.get_api_context_tokens().unwrap_or(0);

        while run_turn < max_turns {
            run_turn += 1;
            let session_turn = turn_offset.saturating_add(run_turn);
            self.current_turn.store(session_turn, Ordering::Relaxed);
            debug!(
                component = "agent.loop",
                agent_event = "agent_turn_scheduled",
                session_id = %self.session_id,
                run_id = ctx.run_id.as_deref().unwrap_or("none"),
                turn = session_turn,
                run_turn,
                "agent turn scheduled"
            );

            let result = turn_runner::execute_turn(turn_runner::TurnParams {
                turn: session_turn,
                context_manager: &mut self.context_manager,
                responder: &self.responder,
                compaction: &self.compaction,
                session_id: &self.session_id,
                emitter: &self.emitter,
                cancel: &self.abort_token,
                run_context: &ctx,
                persister: self.persister.as_deref(),
                previous_context_baseline,
                retry_config: self.config.retry.as_ref(),
                workspace_id: self.config.workspace_id.as_deref(),
                server_origin: self.config.server_origin.as_deref(),
                sequence_counter: self.sequence_counter.as_ref().map(|c| c.as_ref()),
                invocation_abort_registry: self.invocation_abort_registry.as_ref(),
                engine_host: self.engine_host.as_ref(),
            })
            .await;

            if let Some(cw) = result.context_window_tokens {
                previous_context_baseline = cw;
            }

            if let Some(ref usage) = result.token_usage {
                total_usage.input_tokens += usage.input_tokens;
                total_usage.output_tokens += usage.output_tokens;
                if let Some(cache) = usage.cache_read_tokens {
                    *total_usage.cache_read_tokens.get_or_insert(0) += cache;
                }
                if let Some(cache) = usage.cache_creation_tokens {
                    *total_usage.cache_creation_tokens.get_or_insert(0) += cache;
                }
            }

            if !result.success {
                error!(
                    session_id = %self.session_id,
                    turn = session_turn,
                    error = ?result.error,
                    "turn failed"
                );
                final_stop_reason = StopReason::Error;
                error = result.error;
                exited_via_break = true;
                break;
            }

            if result.interrupted {
                warn!(session_id = %self.session_id, turn = session_turn, "agent interrupted");
                final_stop_reason = StopReason::Interrupted;
                interrupted = true;
                exited_via_break = true;
                break;
            }

            if result.stop_turn_requested {
                final_stop_reason = StopReason::CapabilityStop;
                exited_via_break = true;
                break;
            }

            if let Some(StopReason::EndTurn | StopReason::NoCapabilityInvocationDrafts) =
                result.stop_reason
            {
                final_stop_reason = result.stop_reason.unwrap_or(StopReason::EndTurn);
                exited_via_break = true;
                break;
            }
        }

        if !exited_via_break && run_turn >= max_turns {
            final_stop_reason = StopReason::MaxTurns;
        }

        self.completed_turn_offset
            .store(turn_offset.saturating_add(run_turn), Ordering::Relaxed);

        info!(
            component = "agent.loop",
            agent_event = "agent_run_completed",
            session_id = %self.session_id,
            run_id = ctx.run_id.as_deref().unwrap_or("none"),
            trace_id = ctx.engine_trace_id.as_ref().map(|id| id.as_str()).unwrap_or("none"),
            parent_invocation_id = ctx.parent_invocation_id.as_ref().map(|id| id.as_str()).unwrap_or("none"),
            turns = run_turn,
            stop_reason = ?final_stop_reason,
            interrupted,
            has_error = error.is_some(),
            "agent run completed"
        );

        self.emit_run_event(TronEvent::AgentEnd {
            base: run_base(&self.session_id),
            error: error.clone(),
        });
        self.emit_run_event(TronEvent::SessionProcessingChanged {
            base: run_base(&self.session_id),
            is_processing: false,
        });

        RunResult {
            turns_executed: run_turn,
            total_token_usage: total_usage,
            stop_reason: final_stop_reason,
            interrupted,
            error,
            last_context_window_tokens: if previous_context_baseline > 0 {
                Some(previous_context_baseline)
            } else {
                None
            },
        }
    }

    fn emit_run_event(&self, event: TronEvent) {
        if let Some(ref counter) = self.sequence_counter {
            let _ = self.emitter.emit_sequenced(event, counter);
        } else {
            let _ = self.emitter.emit(event);
        }
    }

    pub fn set_abort_token(&mut self, token: CancellationToken) {
        self.abort_token = token;
        self.external_abort_token = true;
    }

    pub fn set_persister(&mut self, persister: Option<Arc<EventPersister>>) {
        if let Some(ref p) = persister {
            self.compaction.set_persister(p.clone());
        }
        self.persister = persister;
    }

    pub(crate) fn set_context_control(&mut self, deps: crate::domains::context_control::Deps) {
        self.compaction.set_context_control(deps);
    }

    pub fn set_sequence_counter(&mut self, counter: Arc<AtomicI64>) {
        self.sequence_counter = Some(counter);
    }

    pub fn set_completed_turn_offset(&mut self, offset: u32) {
        self.completed_turn_offset.store(offset, Ordering::Relaxed);
    }

    pub fn set_invocation_abort_registry(&mut self, registry: Arc<InvocationAbortRegistry>) {
        self.invocation_abort_registry = Some(registry);
    }

    pub fn subscribe(&self) -> broadcast::Receiver<TronEvent> {
        self.emitter.subscribe()
    }

    pub fn session_id(&self) -> &str {
        &self.session_id
    }

    #[cfg(test)]
    pub fn context_manager(&self) -> &ContextManager {
        &self.context_manager
    }

    pub fn compaction_handler(&self) -> &Arc<CompactionHandler> {
        &self.compaction
    }
}

#[cfg(test)]
mod tests;
