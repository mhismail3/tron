use std::sync::Arc;

use async_trait::async_trait;
use parking_lot::RwLock;
use serde_json::Value;
use tracing::{debug, warn};
use tron_runtime::orchestrator::agent_factory::{AgentFactory, CreateAgentOpts};
use tron_runtime::orchestrator::agent_runner::run_agent;
use tron_runtime::orchestrator::orchestrator::StartedRun;
use tron_runtime::types::{AgentConfig, RunContext};
use tron_skills::registry::SkillRegistry;

use crate::rpc::context::{AgentDeps, RpcContext};

use super::prompt_runtime::{
    PromptBootstrapData, PromptContextArtifacts, build_skill_context, build_user_content_override,
    build_user_event_payload, load_prompt_bootstrap, load_recent_events, load_session_model,
    load_session_update_data, persist_user_message_event, resume_prompt_session,
};

#[derive(Clone)]
pub struct PromptRequest {
    pub session_id: String,
    pub prompt: String,
    pub reasoning_level: Option<String>,
    pub images: Option<Vec<Value>>,
    pub attachments: Option<Vec<Value>>,
    pub skills: Option<Vec<String>>,
    pub spells: Option<Vec<String>>,
    pub raw_skills_json: Option<Vec<Value>>,
    pub raw_spells_json: Option<Vec<Value>>,
    pub device_context: Option<String>,
}

struct RuntimeMemoryDeps {
    subagent_manager: Option<Arc<tron_runtime::orchestrator::subagent_manager::SubagentManager>>,
    event_store: Arc<tron_events::EventStore>,
    broadcast: Arc<tron_runtime::EventEmitter>,
    session_id: String,
    embedding_controller: Option<Arc<tokio::sync::Mutex<tron_embeddings::EmbeddingController>>>,
    shutdown_coordinator: Option<Arc<crate::shutdown::ShutdownCoordinator>>,
    ledger_enabled: bool,
}

#[async_trait]
impl tron_events::memory::manager::MemoryManagerDeps for RuntimeMemoryDeps {
    async fn write_ledger_entry(
        &self,
        _opts: &tron_events::memory::types::LedgerWriteOpts,
    ) -> tron_events::memory::types::LedgerWriteResult {
        let deps = crate::rpc::memory_ledger::LedgerWriteDeps {
            event_store: self.event_store.clone(),
            subagent_manager: self.subagent_manager.clone(),
            embedding_controller: self.embedding_controller.clone(),
            shutdown_coordinator: self.shutdown_coordinator.clone(),
        };
        crate::rpc::memory_ledger::execute_ledger_write(&self.session_id, &deps, "auto").await
    }

    fn is_ledger_enabled(&self) -> bool {
        self.ledger_enabled
    }

    fn emit_memory_updating(&self, _session_id: &str) {
        let _ = self
            .broadcast
            .emit(tron_core::events::TronEvent::MemoryUpdating {
                base: tron_core::events::BaseEvent::now(&self.session_id),
            });
    }

    fn emit_memory_updated(
        &self,
        _session_id: &str,
        title: Option<&str>,
        entry_type: Option<&str>,
        event_id: Option<&str>,
    ) {
        let _ = self
            .broadcast
            .emit(tron_core::events::TronEvent::MemoryUpdated {
                base: tron_core::events::BaseEvent::now(&self.session_id),
                title: title.map(String::from),
                entry_type: entry_type.map(String::from),
                event_id: event_id.map(String::from),
            });
    }

    fn on_memory_written(&self, _payload: &serde_json::Value, _title: &str) {}

    fn session_id(&self) -> &str {
        &self.session_id
    }

    fn workspace_id(&self) -> Option<&str> {
        None
    }
}

struct PromptRunPlan {
    started_run: StartedRun,
    session_manager: Arc<tron_runtime::orchestrator::session_manager::SessionManager>,
    broadcast: Arc<tron_runtime::EventEmitter>,
    provider_factory: Arc<dyn tron_llm::provider::ProviderFactory>,
    tool_factory: Arc<dyn Fn() -> tron_tools::registry::ToolRegistry + Send + Sync>,
    guardrails: Option<Arc<parking_lot::Mutex<tron_runtime::guardrails::GuardrailEngine>>>,
    hooks: Option<Arc<tron_runtime::hooks::engine::HookEngine>>,
    health_tracker: Arc<tron_llm::ProviderHealthTracker>,
    event_store: Arc<tron_events::EventStore>,
    context_artifacts: Arc<crate::rpc::session_context::ContextArtifactsService>,
    embedding_controller: Option<Arc<tokio::sync::Mutex<tron_embeddings::EmbeddingController>>>,
    skill_registry: Arc<RwLock<SkillRegistry>>,
    subagent_manager: Option<Arc<tron_runtime::orchestrator::subagent_manager::SubagentManager>>,
    shutdown_coordinator: Option<Arc<crate::shutdown::ShutdownCoordinator>>,
    worktree_coordinator: Option<Arc<tron_worktree::WorktreeCoordinator>>,
    browser_service: Option<Arc<tron_tools::cdp::service::BrowserService>>,
    server_origin: String,
    run_id: String,
    model: String,
    working_dir: String,
    is_chat: bool,
    request: PromptRequest,
}

pub fn spawn_prompt_run(
    ctx: &RpcContext,
    agent_deps: &AgentDeps,
    session: &tron_events::sqlite::row_types::SessionRow,
    started_run: StartedRun,
    run_id: String,
    request: PromptRequest,
) {
    let plan = PromptRunPlan {
        started_run,
        session_manager: ctx.session_manager.clone(),
        broadcast: ctx.orchestrator.broadcast().clone(),
        provider_factory: agent_deps.provider_factory.clone(),
        tool_factory: agent_deps.tool_factory.clone(),
        guardrails: agent_deps.guardrails.clone(),
        hooks: agent_deps.hooks.clone(),
        health_tracker: ctx.health_tracker.clone(),
        event_store: ctx.event_store.clone(),
        context_artifacts: ctx.context_artifacts.clone(),
        embedding_controller: ctx.embedding_controller.clone(),
        skill_registry: ctx.skill_registry.clone(),
        subagent_manager: ctx.subagent_manager.clone(),
        shutdown_coordinator: ctx.shutdown_coordinator.clone(),
        worktree_coordinator: ctx.worktree_coordinator.clone(),
        browser_service: ctx.browser_service.clone(),
        server_origin: ctx.origin.clone(),
        run_id,
        model: session.latest_model.clone(),
        working_dir: session.working_directory.clone(),
        is_chat: session.source.as_deref() == Some("chat"),
        request,
    };

    let shutdown_coordinator = ctx.shutdown_coordinator.clone();
    let handle = tokio::spawn(async move {
        execute_prompt_run(plan).await;
    });
    if let Some(coord) = shutdown_coordinator {
        coord.register_task(handle);
    }
}

async fn execute_prompt_run(plan: PromptRunPlan) {
    let PromptRunPlan {
        started_run,
        session_manager,
        broadcast,
        provider_factory,
        tool_factory,
        guardrails,
        hooks,
        health_tracker,
        event_store,
        context_artifacts,
        embedding_controller,
        skill_registry,
        subagent_manager,
        shutdown_coordinator,
        worktree_coordinator,
        browser_service,
        server_origin,
        run_id,
        model,
        working_dir,
        is_chat,
        request,
    } = plan;

    let PromptRequest {
        session_id,
        prompt,
        reasoning_level,
        images,
        attachments,
        skills,
        spells,
        raw_skills_json,
        raw_spells_json,
        device_context,
    } = request;

    let started_run_guard = started_run;
    let cancel_token = started_run_guard.cancel_token();
    let settings = tron_settings::get_settings();

    let (state, persister) = match resume_prompt_session(
        session_manager.clone(),
        session_id.clone(),
    )
    .await
    {
        Ok(active) => (active.state, active.persister),
        Err(error) => {
            warn!(session_id = %session_id, error = %error, "failed to resume session, starting fresh");
            let fresh_state =
                tron_runtime::orchestrator::session_reconstructor::ReconstructedState {
                    model: model.clone(),
                    working_directory: Some(working_dir.clone()),
                    ..Default::default()
                };
            let fresh_persister = Arc::new(
                tron_runtime::orchestrator::event_persister::EventPersister::new(
                    event_store.clone(),
                ),
            );
            (fresh_state, fresh_persister)
        }
    };

    let worktree_info: Option<tron_worktree::WorktreeInfo> =
        if let Some(wt_path) = &state.worktree_path {
            worktree_coordinator
                .as_ref()
                .and_then(|coordinator| coordinator.get_info(&session_id))
                .or_else(|| {
                    Some(tron_worktree::WorktreeInfo {
                        session_id: session_id.clone(),
                        worktree_path: std::path::PathBuf::from(wt_path),
                        branch: String::new(),
                        base_commit: String::new(),
                        base_branch: None,
                        original_working_dir: std::path::PathBuf::from(&working_dir),
                        repo_root: std::path::PathBuf::from(&working_dir),
                    })
                })
        } else if let Some(ref coordinator) = worktree_coordinator {
            match coordinator
                .maybe_acquire(&session_id, std::path::Path::new(&working_dir))
                .await
            {
                Ok(tron_worktree::AcquireResult::Acquired(info)) => {
                    debug!(
                        session_id = %session_id,
                        worktree = %info.worktree_path.display(),
                        branch = %info.branch,
                        "worktree acquired for session"
                    );
                    Some(info)
                }
                Ok(tron_worktree::AcquireResult::Passthrough) => None,
                Err(error) => {
                    warn!(
                        session_id = %session_id,
                        error = %error,
                        "worktree acquisition failed, using original directory"
                    );
                    None
                }
            }
        } else {
            None
        };

    let working_dir = worktree_info
        .as_ref()
        .map(|info| info.worktree_path.to_string_lossy().to_string())
        .unwrap_or(working_dir);

    let is_resumed = !state.messages.is_empty();
    let prompt_bootstrap = match load_prompt_bootstrap(
        context_artifacts.clone(),
        event_store.clone(),
        session_id.clone(),
        working_dir.clone(),
        settings.as_ref().clone(),
        is_chat,
        is_resumed,
    )
    .await
    {
        Ok(artifacts) => artifacts,
        Err(error) => {
            warn!(
                session_id = %session_id,
                working_dir = %working_dir,
                error = %error,
                "failed to load prompt bootstrap"
            );
            PromptBootstrapData {
                artifacts: PromptContextArtifacts::default(),
                subagent_results_context: None,
            }
        }
    };
    let prompt_artifacts = prompt_bootstrap.artifacts;
    let combined_rules = prompt_artifacts.rules_content;
    let rules_index = prompt_artifacts.rules_index;
    let pre_activated_rules = prompt_artifacts.pre_activated_rules;
    let resolved_ws_id = prompt_artifacts.workspace_id;

    let memory = {
        let auto_inject = &settings.context.memory.auto_inject;

        if auto_inject.enabled && !is_chat {
            if let Some(ref controller) = embedding_controller {
                let controller = controller.lock().await;
                match resolved_ws_id.as_deref() {
                    Some(workspace_id) => {
                        let count = auto_inject.count.clamp(1, 10);
                        let query_context = if auto_inject.semantic_injection {
                            Some(prompt.as_str())
                        } else {
                            None
                        };
                        controller
                            .load_workspace_memory(
                                &event_store,
                                workspace_id,
                                count,
                                query_context,
                                auto_inject.recency_anchor_count,
                            )
                            .await
                            .map(|memory| memory.content)
                    }
                    None => None,
                }
            } else {
                None
            }
        } else {
            None
        }
    };
    let subagent_results_context = prompt_bootstrap.subagent_results_context;

    let memory = if let Some(ref worktree) = worktree_info {
        let worktree_context = format!(
            "\n\n## Environment Isolation\n\
             Working in git worktree: {}\n\
             Branch: {}{}",
            worktree.worktree_path.display(),
            worktree.branch,
            worktree
                .base_branch
                .as_ref()
                .map(|branch| format!(" (based on {branch})"))
                .unwrap_or_default(),
        );
        Some(match memory {
            Some(memory) => format!("{memory}{worktree_context}"),
            None => worktree_context,
        })
    } else {
        memory
    };

    let messages = state.messages.clone();
    let working_dir_for_memory = working_dir.clone();
    let model_for_error = model.clone();

    let provider = match provider_factory.create_for_model(&model).await {
        Ok(provider) => provider,
        Err(error) => {
            warn!(
                model = %model,
                error = %error,
                "failed to create provider for model"
            );
            let _ = broadcast.emit(tron_core::events::TronEvent::Error {
                base: tron_core::events::BaseEvent::now(&session_id),
                error: error.to_string(),
                context: None,
                code: None,
                provider: None,
                category: Some(error.category().to_owned()),
                suggestion: None,
                retryable: Some(error.is_retryable()),
                status_code: None,
                error_type: Some(error.category().to_owned()),
                model: Some(model_for_error),
            });
            return;
        }
    };

    let compactor_settings = &settings.context.compactor;
    let config = AgentConfig {
        model: model.clone(),
        working_directory: Some(working_dir.clone()),
        server_origin: Some(server_origin),
        system_prompt: if is_chat {
            Some(tron_runtime::context::system_prompts::TRON_CHAT_PROMPT.to_string())
        } else {
            None
        },
        enable_thinking: true,
        max_turns: settings.agent.max_turns,
        compaction: tron_runtime::context::types::CompactionConfig {
            threshold: compactor_settings.compaction_threshold,
            preserve_ratio: compactor_settings.preserve_ratio,
            context_limit: tron_llm::model_context_window(&model),
        },
        retry: Some(tron_core::retry::RetryConfig {
            max_retries: settings.retry.max_retries,
            base_delay_ms: settings.retry.base_delay_ms,
            max_delay_ms: settings.retry.max_delay_ms,
            jitter_factor: settings.retry.jitter_factor,
        }),
        health_tracker: Some(health_tracker),
        workspace_id: resolved_ws_id.clone(),
        ..AgentConfig::default()
    };

    let provider_type_str = provider.provider_type().as_str().to_string();
    let tools = tool_factory();
    let mut agent = AgentFactory::create_agent(
        config,
        session_id.clone(),
        CreateAgentOpts {
            provider,
            tools,
            guardrails,
            hooks: hooks.clone(),
            is_unattended: false,
            denied_tools: vec![],
            subagent_depth: 0,
            subagent_max_depth: settings.agent.subagent_max_depth,
            rules_content: combined_rules,
            initial_messages: messages,
            memory_content: memory,
            rules_index,
            pre_activated_rules,
            subagent_manager: subagent_manager.clone(),
        },
    );

    agent.set_abort_token(cancel_token);
    agent.set_persister(Some(persister.clone()));

    let user_event_payload = build_user_event_payload(
        &prompt,
        images.as_deref(),
        attachments.as_deref(),
        raw_skills_json.as_deref(),
        raw_spells_json.as_deref(),
    );
    if let Err(error) =
        persist_user_message_event(event_store.clone(), session_id.clone(), user_event_payload)
            .await
    {
        warn!(
            session_id = %session_id,
            error = %error,
            "failed to persist message.user event"
        );
    }

    let user_content_override =
        build_user_content_override(&prompt, &model, images.as_deref(), attachments.as_deref());

    let skill_context = match build_skill_context(
        skill_registry,
        event_store.clone(),
        session_id.clone(),
        skills,
        spells,
    )
    .await
    {
        Ok(context) => context,
        Err(error) => {
            warn!(
                session_id = %session_id,
                error = %error,
                "failed to build skill context"
            );
            None
        }
    };
    let run_context = RunContext {
        reasoning_level: reasoning_level
            .and_then(|level| tron_runtime::types::ReasoningLevel::from_str_loose(&level)),
        skill_context,
        subagent_results: subagent_results_context,
        user_content_override,
        device_context,
        ..Default::default()
    };

    let result = run_agent(&mut agent, &prompt, run_context, &hooks, &broadcast).await;

    let _ = persister.flush().await;

    if result.interrupted {
        if let Err(error) = persister
            .append(
                &session_id,
                tron_events::EventType::NotificationInterrupted,
                serde_json::json!({
                    "timestamp": chrono::Utc::now().to_rfc3339(),
                    "turn": result.turns_executed,
                }),
            )
            .await
        {
            tracing::error!(
                session_id = %session_id,
                error = %error,
                "failed to persist notification.interrupted"
            );
        }
        let _ = persister.flush().await;
    }

    if let Some(ref browser_service) = browser_service
        && let Err(error) = browser_service.close_session(&session_id).await
    {
        tracing::debug!(
            session_id = %session_id,
            error = %error,
            "failed to close browser session after run"
        );
    }

    if let Some(ref error_message) = result.error {
        let parsed = tron_core::errors::parse::parse_error(error_message);
        let _ = broadcast.emit(tron_core::events::TronEvent::Error {
            base: tron_core::events::BaseEvent::now(&session_id),
            error: error_message.clone(),
            context: None,
            code: None,
            provider: Some(provider_type_str.clone()),
            category: Some(parsed.category.to_string()),
            suggestion: parsed.suggestion,
            retryable: Some(parsed.is_retryable),
            status_code: None,
            error_type: Some(parsed.category.to_string()),
            model: Some(model_for_error.clone()),
        });
    }

    session_manager.invalidate_session(&session_id);
    drop(started_run_guard);

    let session_model = match load_session_model(session_manager.clone(), session_id.clone()).await
    {
        Ok(Some(session_model)) => session_model,
        Ok(None) => String::new(),
        Err(error) => {
            warn!(
                session_id = %session_id,
                error = %error,
                "failed to load session model for memory pipeline"
            );
            String::new()
        }
    };
    let context_limit = tron_llm::model_context_window(&session_model);
    let last_context_window = result.last_context_window_tokens.unwrap_or(0);
    #[allow(clippy::cast_precision_loss)]
    let token_ratio = if context_limit > 0 {
        last_context_window as f64 / context_limit as f64
    } else {
        0.0
    };

    let memory_deps = RuntimeMemoryDeps {
        subagent_manager: subagent_manager.clone(),
        event_store: event_store.clone(),
        broadcast: broadcast.clone(),
        session_id: session_id.clone(),
        embedding_controller: embedding_controller.clone(),
        shutdown_coordinator: shutdown_coordinator.clone(),
        ledger_enabled: settings.context.memory.ledger.enabled,
    };

    let (recent_event_types, recent_tool_calls) =
        match load_recent_events(event_store.clone(), session_id.clone()).await {
            Ok(recent) => recent,
            Err(error) => {
                warn!(
                    session_id = %session_id,
                    error = %error,
                    "failed to gather recent events for memory pipeline"
                );
                (Vec::new(), Vec::new())
            }
        };

    let mut memory_manager = tron_events::memory::manager::MemoryManager::new(memory_deps);
    memory_manager
        .on_cycle_complete(tron_events::memory::types::CycleInfo {
            model: session_model,
            working_directory: working_dir_for_memory,
            current_token_ratio: token_ratio,
            recent_event_types,
            recent_tool_calls,
        })
        .await;

    match load_session_update_data(
        session_manager.clone(),
        event_store.clone(),
        session_id.clone(),
    )
    .await
    {
        Ok(Some(update)) => {
            let _ = broadcast.emit(tron_core::events::TronEvent::SessionUpdated {
                base: tron_core::events::BaseEvent::now(&session_id),
                title: update.session.title.clone(),
                model: update.session.latest_model.clone(),
                message_count: update.session.message_count,
                input_tokens: update.session.total_input_tokens,
                output_tokens: update.session.total_output_tokens,
                last_turn_input_tokens: update.session.last_turn_input_tokens,
                cache_read_tokens: update.session.total_cache_read_tokens,
                cache_creation_tokens: update.session.total_cache_creation_tokens,
                cost: update.session.total_cost,
                last_activity: update.session.last_activity_at.clone(),
                is_active: false,
                last_user_prompt: update
                    .preview
                    .as_ref()
                    .and_then(|preview| preview.last_user_prompt.clone()),
                last_assistant_response: update
                    .preview
                    .as_ref()
                    .and_then(|preview| preview.last_assistant_response.clone()),
                parent_session_id: update.session.parent_session_id.clone(),
            });
        }
        Ok(None) => {}
        Err(error) => {
            warn!(
                session_id = %session_id,
                error = %error,
                "failed to load session update data"
            );
        }
    }

    debug!(
        session_id = %session_id,
        run_id = %run_id,
        stop_reason = ?result.stop_reason,
        turns = result.turns_executed,
        "prompt run completed"
    );
}
