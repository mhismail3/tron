//! `TronAgent` — multi-turn agent with turn loop, abort, and state tracking.

use std::sync::Arc;
use std::sync::atomic::{AtomicBool, AtomicI64, AtomicU32, Ordering};

use crate::domains::agent::runner::context::context_manager::ContextManager;
use crate::domains::agent::runner::guardrails::GuardrailEngine;
use crate::domains::agent::runner::hooks::engine::HookEngine;
use crate::domains::capability_support::implementations::capability_surface::CapabilitySurfacePolicy;
use crate::domains::model::providers::provider::Provider;
use crate::shared::events::{BaseEvent, TronEvent};
use crate::shared::messages::{Message, TokenUsage, UserMessageContent};
use tokio::sync::broadcast;
use tokio_util::sync::CancellationToken;

use tracing::{debug, error, instrument, warn};

use crate::domains::agent::runner::agent::compaction_handler::CompactionHandler;
use crate::domains::agent::runner::agent::event_emitter::EventEmitter;
use crate::domains::agent::runner::agent::turn_runner;
use crate::domains::agent::runner::errors::StopReason;
use crate::domains::agent::runner::orchestrator::event_persister::EventPersister;
use crate::domains::agent::runner::orchestrator::tool_abort_registry::ToolAbortRegistry;
use crate::domains::agent::runner::types::{AgentConfig, RunContext, RunResult};

/// RAII guard that resets `is_running` to `false` on drop (even on panic).
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

/// Bundled dependencies for constructing a `TronAgent`.
pub struct AgentDeps {
    /// LLM provider for generating completions.
    pub provider: Arc<dyn Provider>,
    /// Live catalog policy for model-facing tools.
    pub tool_surface_policy: CapabilitySurfacePolicy,
    /// Optional guardrail engine for content safety.
    pub guardrails: Option<Arc<parking_lot::Mutex<GuardrailEngine>>>,
    /// Optional hook engine for lifecycle hooks.
    pub hooks: Option<Arc<HookEngine>>,
    /// Context manager for conversation history.
    pub context_manager: ContextManager,
    /// Optional subagent manager for LLM-backed compaction summarization.
    pub subagent_manager:
        Option<Arc<crate::domains::agent::runner::orchestrator::subagent_manager::SubagentManager>>,
    /// Compaction trigger configuration (from settings).
    pub compaction_trigger_config:
        crate::domains::agent::runner::context::types::CompactionTriggerConfig,
    /// Optional process manager for background process execution.
    pub process_manager: Option<
        Arc<dyn crate::domains::capability_support::implementations::traits::ProcessManagerOps>,
    >,
    /// Optional unified job manager for process + subagent lifecycle.
    pub job_manager:
        Option<Arc<dyn crate::domains::capability_support::implementations::traits::JobManagerOps>>,
    /// Optional output buffer registry for process output streaming.
    pub output_buffer_registry: Option<
        Arc<crate::domains::agent::runner::orchestrator::output_buffer::OutputBufferRegistry>,
    >,
    /// Optional engine host for routing model-facing capability primitives.
    pub engine_host: Option<crate::engine::EngineHostHandle>,
}

/// Multi-turn agent that owns all submodules.
pub struct TronAgent {
    config: AgentConfig,
    provider: Arc<dyn Provider>,
    tool_surface_policy: CapabilitySurfacePolicy,
    guardrails: Option<Arc<parking_lot::Mutex<GuardrailEngine>>>,
    hooks: Option<Arc<HookEngine>>,
    context_manager: ContextManager,
    emitter: Arc<EventEmitter>,
    compaction: Arc<CompactionHandler>,
    session_id: String,
    current_turn: AtomicU32,
    is_running: AtomicBool,
    abort_token: CancellationToken,
    /// Whether the abort token was provided externally (e.g. by orchestrator).
    external_abort_token: bool,
    /// Optional inline event persister (injected by orchestrator).
    persister: Option<Arc<EventPersister>>,
    /// Optional per-session sequence counter for monotonic event ordering.
    sequence_counter: Option<Arc<AtomicI64>>,
    /// Optional process manager for background process execution.
    process_manager: Option<
        Arc<dyn crate::domains::capability_support::implementations::traits::ProcessManagerOps>,
    >,
    /// Optional unified job manager for process + subagent lifecycle.
    job_manager:
        Option<Arc<dyn crate::domains::capability_support::implementations::traits::JobManagerOps>>,
    /// Optional output buffer registry for process output streaming.
    output_buffer_registry: Option<
        Arc<crate::domains::agent::runner::orchestrator::output_buffer::OutputBufferRegistry>,
    >,
    /// Optional per-call cancellation registry. Enables `agent.abortTool` to
    /// cancel a single in-flight capability without aborting the whole turn.
    /// When `None` (subagents, older code paths) calls share the turn-level token.
    tool_abort_registry: Option<Arc<ToolAbortRegistry>>,
    /// Optional engine host used by the executor to invoke capability primitives.
    engine_host: Option<crate::engine::EngineHostHandle>,
}

impl TronAgent {
    /// Create a new agent from bundled dependencies.
    pub fn new(config: AgentConfig, deps: AgentDeps, session_id: String) -> Self {
        let compaction = Arc::new(match deps.subagent_manager {
            Some(ref mgr) => CompactionHandler::with_subagent_manager(
                mgr.clone(),
                deps.compaction_trigger_config,
            ),
            None => CompactionHandler::new(deps.compaction_trigger_config),
        });
        Self {
            config,
            provider: deps.provider,
            tool_surface_policy: deps.tool_surface_policy,
            guardrails: deps.guardrails,
            hooks: deps.hooks,
            context_manager: deps.context_manager,
            emitter: Arc::new(EventEmitter::new()),
            compaction,
            session_id,
            process_manager: deps.process_manager,
            job_manager: deps.job_manager,
            output_buffer_registry: deps.output_buffer_registry,
            engine_host: deps.engine_host,
            current_turn: AtomicU32::new(0),
            is_running: AtomicBool::new(false),
            abort_token: CancellationToken::new(),
            external_abort_token: false,
            persister: None,
            sequence_counter: None,
            tool_abort_registry: None,
        }
    }

    /// Run the multi-turn loop with user content.
    #[allow(clippy::too_many_lines)]
    #[instrument(skip(self, ctx), fields(session_id = %self.session_id, model = %self.config.model))]
    pub async fn run(&mut self, content: &str, mut ctx: RunContext) -> RunResult {
        // Reject concurrent runs — guard resets is_running on drop (even on panic)
        let Some(_guard) = RunGuard::new(&self.is_running) else {
            return RunResult {
                stop_reason: StopReason::Error,
                error: Some("Agent is already running".into()),
                ..Default::default()
            };
        };

        // Reset abort token for this run (unless an external token was injected)
        if !self.external_abort_token {
            self.abort_token = CancellationToken::new();
        }
        self.current_turn.store(0, Ordering::Relaxed);

        let mut total_usage = TokenUsage::default();
        let mut final_stop_reason = StopReason::EndTurn;
        let mut interrupted = false;
        let mut error: Option<String> = None;

        // Add user message to context
        let user_content = if let Some(override_content) = ctx.user_content_override.take() {
            override_content
        } else {
            UserMessageContent::Text(content.to_owned())
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

        // Emit AgentStart
        if let Some(ref counter) = self.sequence_counter {
            let _ = self.emitter.emit_sequenced(
                TronEvent::AgentStart {
                    base: run_base(&self.session_id),
                },
                counter,
            );
        } else {
            let _ = self.emitter.emit(TronEvent::AgentStart {
                base: run_base(&self.session_id),
            });
        }
        // Global broadcast for dashboard: this session is now processing
        let _ = self.emitter.emit(TronEvent::SessionProcessingChanged {
            base: run_base(&self.session_id),
            is_processing: true,
        });

        debug!(session_id = %self.session_id, "agent run started");

        let max_turns = self.config.max_turns;
        let mut turn = 0u32;
        let mut exited_via_break = false;
        let mut previous_context_baseline: u64 = 0;

        while turn < max_turns {
            turn += 1;
            self.current_turn.store(turn, Ordering::Relaxed);

            let result = turn_runner::execute_turn(turn_runner::TurnParams {
                turn,
                context_manager: &mut self.context_manager,
                provider: &self.provider,
                tool_surface_policy: &self.tool_surface_policy,
                guardrails: &self.guardrails,
                hooks: &self.hooks,
                compaction: &*self.compaction,
                session_id: &self.session_id,
                emitter: &self.emitter,
                cancel: &self.abort_token,
                run_context: &ctx,
                persister: self.persister.as_deref(),
                persister_arc: self.persister.as_ref(),
                previous_context_baseline,
                subagent_depth: self.config.subagent_depth,
                subagent_max_depth: self.config.subagent_max_depth,
                retry_config: self.config.retry.as_ref(),
                health_tracker: self.config.health_tracker.as_ref(),
                workspace_id: self.config.workspace_id.as_deref(),
                server_origin: self.config.server_origin.as_deref(),
                process_manager: self.process_manager.as_ref(),
                job_manager: self.job_manager.as_ref(),
                output_buffer_registry: self.output_buffer_registry.as_ref(),
                sequence_counter: self.sequence_counter.as_ref().map(|c| c.as_ref()),
                tool_abort_registry: self.tool_abort_registry.as_ref(),
                engine_host: self.engine_host.as_ref(),
            })
            .await;

            // Update baseline for next turn
            if let Some(cw) = result.context_window_tokens {
                previous_context_baseline = cw;
            }

            // Accumulate token usage
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
                error!(session_id = %self.session_id, turn, error = ?result.error, "turn failed");
                final_stop_reason = StopReason::Error;
                error = result.error;
                exited_via_break = true;
                break;
            }

            if result.interrupted {
                warn!(session_id = %self.session_id, turn, "agent interrupted");
                final_stop_reason = StopReason::Interrupted;
                interrupted = true;
                exited_via_break = true;
                break;
            }

            if result.stop_turn_requested {
                final_stop_reason = StopReason::ToolStop;
                exited_via_break = true;
                break;
            }

            if let Some(StopReason::EndTurn | StopReason::NoToolCalls) = result.stop_reason {
                final_stop_reason = result.stop_reason.unwrap_or(StopReason::EndTurn);
                exited_via_break = true;
                break;
            }
            // Continue looping (tool calls executed, more turns needed)
        }

        // If the loop ended because turn >= max_turns (not via break),
        // the agent exhausted its turn budget.
        if !exited_via_break && turn >= max_turns {
            final_stop_reason = StopReason::MaxTurns;
        }

        debug!(session_id = %self.session_id, turns = turn, stop_reason = ?final_stop_reason, "agent run completed");

        // Fire Stop hook (non-blocking, background)
        if let Some(hook_engine) = &self.hooks {
            // Extract last user/assistant messages for suggestion hooks.
            let messages = self.context_manager.messages_slice();
            let last_user = messages.iter().rev().find_map(|m| match m {
                Message::User { content, .. } => {
                    let text = match content {
                        UserMessageContent::Text(s) => s.clone(),
                        UserMessageContent::Blocks(blocks) => {
                            crate::shared::content::extract_text_from_user_content(blocks)
                        }
                    };
                    if text.is_empty() { None } else { Some(text) }
                }
                _ => None,
            });
            let last_assistant = messages.iter().rev().find_map(|m| match m {
                Message::Assistant { content, .. } => {
                    let text: String = content
                        .iter()
                        .filter_map(|c| c.as_text())
                        .collect::<Vec<_>>()
                        .join("\n");
                    if text.is_empty() {
                        None
                    } else {
                        // Truncate to avoid bloating hook context
                        Some(if text.len() > 500 {
                            text[..500].to_string()
                        } else {
                            text
                        })
                    }
                }
                _ => None,
            });

            let hook_ctx = crate::domains::agent::runner::hooks::types::HookContext::Stop {
                session_id: self.session_id.clone(),
                timestamp: chrono::Utc::now().to_rfc3339(),
                stop_reason: format!("{final_stop_reason:?}"),
                final_message: None,
                last_user_prompt: last_user,
                last_assistant_response: last_assistant,
            };
            let _ = hook_engine.execute(&hook_ctx).await;
        }

        // Emit AgentEnd
        if let Some(ref counter) = self.sequence_counter {
            let _ = self.emitter.emit_sequenced(
                TronEvent::AgentEnd {
                    base: run_base(&self.session_id),
                    error: error.clone(),
                },
                counter,
            );
        } else {
            let _ = self.emitter.emit(TronEvent::AgentEnd {
                base: run_base(&self.session_id),
                error: error.clone(),
            });
        }

        // Global broadcast for dashboard: this session stopped processing
        let _ = self.emitter.emit(TronEvent::SessionProcessingChanged {
            base: run_base(&self.session_id),
            is_processing: false,
        });

        // _guard drops here, resetting is_running (even on panic)

        RunResult {
            turns_executed: turn,
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

    /// Set an external abort token (e.g. from the orchestrator).
    /// When set, `run()` will not reset it — the orchestrator controls cancellation.
    pub fn set_abort_token(&mut self, token: CancellationToken) {
        self.abort_token = token;
        self.external_abort_token = true;
    }

    /// Set the inline event persister (e.g. from the orchestrator).
    pub fn set_persister(&mut self, persister: Option<Arc<EventPersister>>) {
        if let Some(ref p) = persister {
            self.compaction.set_persister(p.clone());
        }
        self.persister = persister;
    }

    /// Set the per-session sequence counter for monotonic event ordering.
    pub fn set_sequence_counter(&mut self, counter: Arc<AtomicI64>) {
        self.sequence_counter = Some(counter);
    }

    /// Inject the per-tool cancellation registry (owned by the orchestrator).
    /// Each in-flight tool call gets a child of `abort_token`; `agent.abortTool`
    /// cancels that child without touching siblings or the turn itself.
    pub fn set_tool_abort_registry(&mut self, registry: Arc<ToolAbortRegistry>) {
        self.tool_abort_registry = Some(registry);
    }

    /// Abort the current run.
    pub fn abort(&self) {
        self.abort_token.cancel();
    }

    /// Whether the agent is currently running.
    pub fn is_running(&self) -> bool {
        self.is_running.load(Ordering::Relaxed)
    }

    /// Current turn number (0 if not running).
    pub fn current_turn(&self) -> u32 {
        self.current_turn.load(Ordering::Relaxed)
    }

    /// Subscribe to agent events.
    pub fn subscribe(&self) -> broadcast::Receiver<TronEvent> {
        self.emitter.subscribe()
    }

    /// Get the session ID.
    pub fn session_id(&self) -> &str {
        &self.session_id
    }

    /// Get the current model.
    pub fn model(&self) -> &str {
        &self.config.model
    }

    /// Get a reference to the context manager.
    pub fn context_manager(&self) -> &ContextManager {
        &self.context_manager
    }

    /// Get a mutable reference to the context manager.
    pub fn context_manager_mut(&mut self) -> &mut ContextManager {
        &mut self.context_manager
    }

    /// Get the emitter.
    pub fn emitter(&self) -> &Arc<EventEmitter> {
        &self.emitter
    }

    /// Get the compaction handler (for orchestrator registration).
    pub fn compaction_handler(&self) -> &Arc<CompactionHandler> {
        &self.compaction
    }
}

#[cfg(test)]
impl TronAgent {}

#[cfg(test)]
#[path = "tron_agent_tests.rs"]
mod tests;
