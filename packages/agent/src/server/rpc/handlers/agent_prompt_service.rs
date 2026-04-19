use std::sync::Arc;
use std::sync::atomic::AtomicI64;

use parking_lot::RwLock;
use serde_json::Value;
use tracing::{debug, warn};
use crate::runtime::orchestrator::agent_factory::{AgentFactory, CreateAgentOpts};
use crate::runtime::orchestrator::agent_runner::run_agent;
use crate::runtime::orchestrator::orchestrator::StartedRun;
use crate::runtime::types::{AgentConfig, RunContext, VolatileTokens};
use crate::skills::registry::SkillRegistry;

use crate::server::rpc::context::{AgentDeps, RpcContext};

use super::prompt_runtime::{
    PromptBootstrapData, PromptContextArtifacts, build_skill_context_from_session,
    build_user_content_override, build_user_event_payload, collect_pending_skill_payloads,
    load_prompt_bootstrap, load_prompt_bootstrap_minimal, load_session_update_data,
    persist_user_message_event, resume_prompt_session,
};

#[derive(Clone)]
pub struct PromptRequest {
    pub session_id: String,
    pub prompt: String,
    pub reasoning_level: Option<String>,
    pub images: Option<Vec<Value>>,
    pub attachments: Option<Vec<Value>>,
    /// Optional structured metadata merged into the emitted `message.user`
    /// event payload. Used by interactive tool handlers (confirmation,
    /// answers) to tag the message with `messageKind` and structured fields
    /// so iOS can render a chip without parsing text content.
    pub message_metadata: Option<Value>,
}

struct PromptRunPlan {
    started_run: StartedRun,
    orchestrator: Arc<crate::runtime::orchestrator::orchestrator::Orchestrator>,
    session_manager: Arc<crate::runtime::orchestrator::session_manager::SessionManager>,
    broadcast: Arc<crate::runtime::EventEmitter>,
    provider_factory: Arc<dyn crate::llm::provider::ProviderFactory>,
    tool_factory: Arc<dyn Fn() -> crate::tools::registry::ToolRegistry + Send + Sync>,
    guardrails: Option<Arc<parking_lot::Mutex<crate::runtime::guardrails::GuardrailEngine>>>,
    health_tracker: Arc<crate::llm::ProviderHealthTracker>,
    event_store: Arc<crate::events::EventStore>,
    context_artifacts: Arc<crate::server::rpc::session_context::ContextArtifactsService>,
    skill_registry: Arc<RwLock<SkillRegistry>>,
    subagent_manager: Option<Arc<crate::runtime::orchestrator::subagent_manager::SubagentManager>>,
    shutdown_token: Option<tokio_util::sync::CancellationToken>,
    worktree_coordinator: Option<Arc<crate::worktree::WorktreeCoordinator>>,
    process_manager: Option<Arc<dyn crate::tools::traits::ProcessManagerOps>>,
    job_manager: Option<Arc<dyn crate::tools::traits::JobManagerOps>>,
    output_buffer_registry: Option<Arc<crate::runtime::orchestrator::output_buffer::OutputBufferRegistry>>,
    hook_abort_tracker: Arc<crate::runtime::hooks::abort_tracker::HookAbortTracker>,
    sequence_counter: Option<Arc<AtomicI64>>,
    server_origin: String,
    run_id: String,
    source: Option<String>,
    model: String,
    working_dir: String,
    request: PromptRequest,
}

struct PromptRunCleanup {
    session_manager: Arc<crate::runtime::orchestrator::session_manager::SessionManager>,
    session_id: String,
    started_run: Option<StartedRun>,
}

impl PromptRunCleanup {
    fn new(
        started_run: StartedRun,
        session_manager: Arc<crate::runtime::orchestrator::session_manager::SessionManager>,
        session_id: String,
    ) -> Self {
        Self {
            session_manager,
            session_id,
            started_run: Some(started_run),
        }
    }

    fn cancel_token(&self) -> tokio_util::sync::CancellationToken {
        self.started_run
            .as_ref()
            .expect("started run must exist while prompt is active")
            .cancel_token()
    }

    fn release(&mut self) {
        self.session_manager.clear_processing(&self.session_id);
        self.session_manager.invalidate_session(&self.session_id);
        let _ = self.started_run.take();
    }
}

impl Drop for PromptRunCleanup {
    fn drop(&mut self) {
        self.release();
    }
}

struct ShutdownCancelForwarder(Option<tokio::task::JoinHandle<()>>);

impl ShutdownCancelForwarder {
    fn new(
        shutdown_token: Option<tokio_util::sync::CancellationToken>,
        run_cancel: tokio_util::sync::CancellationToken,
    ) -> Self {
        let handle = shutdown_token.map(|shutdown_token| {
            tokio::spawn(async move {
                shutdown_token.cancelled().await;
                run_cancel.cancel();
            })
        });
        Self(handle)
    }
}

impl Drop for ShutdownCancelForwarder {
    fn drop(&mut self) {
        if let Some(handle) = self.0.take() {
            handle.abort();
        }
    }
}

pub fn spawn_prompt_run(
    ctx: &RpcContext,
    agent_deps: &AgentDeps,
    session: &crate::events::sqlite::row_types::SessionRow,
    started_run: StartedRun,
    run_id: String,
    request: PromptRequest,
) {
    let plan = PromptRunPlan {
        started_run,
        orchestrator: ctx.orchestrator.clone(),
        session_manager: ctx.session_manager.clone(),
        broadcast: ctx.orchestrator.broadcast().clone(),
        provider_factory: agent_deps.provider_factory.clone(),
        tool_factory: agent_deps.tool_factory.clone(),
        guardrails: agent_deps.guardrails.clone(),
        health_tracker: ctx.health_tracker.clone(),
        event_store: ctx.event_store.clone(),
        context_artifacts: ctx.context_artifacts.clone(),
        skill_registry: ctx.skill_registry.clone(),
        subagent_manager: ctx.subagent_manager.clone(),
        shutdown_token: ctx.shutdown_coordinator.as_ref().map(|coord| coord.token()),
        worktree_coordinator: ctx.worktree_coordinator.clone(),
        process_manager: ctx.process_manager.clone(),
        job_manager: ctx.job_manager.clone(),
        output_buffer_registry: ctx.output_buffer_registry.clone(),
        hook_abort_tracker: ctx.hook_abort_tracker.clone(),
        sequence_counter: {
            let sid = &request.session_id;
            // Ensure counter is initialized (idempotent for already-initialized sessions).
            // On first prompt after create, it was already initialized to 0 in session.create.
            // On resume, re-initialize from DB max to pick up any externally-persisted events.
            if ctx.orchestrator.get_sequence_counter(sid).is_none() {
                let max_seq = ctx.event_store.get_max_sequence(sid).unwrap_or(0);
                ctx.orchestrator.init_sequence_counter(sid, max_seq);
            }
            ctx.orchestrator.get_sequence_counter(sid)
        },
        server_origin: ctx.origin.clone(),
        run_id,
        source: session.source.clone(),
        model: session.latest_model.clone(),
        working_dir: session.working_directory.clone(),
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
        orchestrator,
        session_manager,
        broadcast,
        provider_factory,
        tool_factory,
        guardrails,
        health_tracker,
        event_store,
        context_artifacts,
        skill_registry,
        subagent_manager,
        shutdown_token,
        worktree_coordinator,
        process_manager,
        job_manager,
        output_buffer_registry,
        hook_abort_tracker,
        sequence_counter,
        server_origin,
        run_id,
        source,
        model,
        working_dir,
        request,
    } = plan;

    let is_chat = source.as_deref() == Some("chat");

    let PromptRequest {
        session_id,
        prompt,
        reasoning_level,
        images,
        attachments,
        message_metadata,
    } = request;

    // Pre-clone deps needed for auto-drain after the run completes
    let drain_provider_factory = provider_factory.clone();
    let drain_tool_factory = tool_factory.clone();
    let drain_guardrails = guardrails.clone();
    let drain_health_tracker = health_tracker.clone();
    let drain_context_artifacts = context_artifacts.clone();
    let drain_skill_registry = skill_registry.clone();
    let drain_subagent_manager = subagent_manager.clone();
    let drain_shutdown_token = shutdown_token.clone();
    let drain_worktree_coordinator = worktree_coordinator.clone();
    let drain_process_manager = process_manager.clone();
    let drain_job_manager = job_manager.clone();
    let drain_output_buffer_registry = output_buffer_registry.clone();
    let drain_hook_abort_tracker = hook_abort_tracker.clone();
    let drain_server_origin = server_origin.clone();

    // Create per-session hook engine: builtins + discovered user/project hooks.
    // Fresh each session so new/modified hook files are picked up without restart.
    let hooks = {
        use crate::runtime::hooks::builtin;
        use crate::runtime::hooks::discovery::discover_hooks;
        use crate::runtime::hooks::engine::HookEngine;
        use crate::runtime::hooks::registry::HookRegistry;
        use crate::runtime::hooks::types::DiscoveryConfig;

        let settings = crate::settings::get_settings();
        let hook_settings = &settings.hooks;

        let mut engine = HookEngine::new(HookRegistry::new());

        // Register built-in hooks (title gen, branch name gen, etc.)
        if let Some(ref mgr) = subagent_manager {
            builtin::register_builtins(
                &mut engine,
                &hook_settings.llm_model,
                &hook_settings.builtin_hooks,
                mgr,
                &broadcast,
                Some(&event_store),
                worktree_coordinator.as_ref(),
                &hook_abort_tracker,
            );
        }

        // Discover user + project hooks from disk
        let discovered = discover_hooks(&DiscoveryConfig {
            project_path: Some(working_dir.clone()),
            user_home: None,
            include_user_hooks: true,
            extensions: hook_settings.extensions.iter().cloned().collect(),
            ..Default::default()
        });

        if !discovered.is_empty() {
            engine.load_discovered_hooks(
                discovered,
                hook_settings.default_timeout_ms,
                &hook_settings.llm_model,
                subagent_manager.as_ref(),
                Some(&broadcast),
            );
        }

        Some(Arc::new(engine))
    };

    let _ = session_manager.mark_processing(&session_id);
    let mut run_cleanup =
        PromptRunCleanup::new(started_run, session_manager.clone(), session_id.clone());
    let cancel_token = run_cleanup.cancel_token();
    let _shutdown_forwarder = ShutdownCancelForwarder::new(shutdown_token, cancel_token.clone());
    let settings = crate::settings::get_settings();

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
                crate::runtime::orchestrator::session_reconstructor::ReconstructedState {
                    model: model.clone(),
                    working_directory: Some(working_dir.clone()),
                    ..Default::default()
                };
            let fresh_persister = Arc::new(
                crate::runtime::orchestrator::event_persister::EventPersister::new(
                    event_store.clone(),
                ),
            );
            (fresh_state, fresh_persister)
        }
    };

    let mut freshly_acquired_worktree = false;
    let worktree_info: Option<crate::worktree::WorktreeInfo> =
        if let Some(wt_path) = &state.worktree_path {
            worktree_coordinator
                .as_ref()
                .and_then(|coordinator| coordinator.get_info(&session_id))
                .or_else(|| {
                    Some(crate::worktree::WorktreeInfo {
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
                Ok(crate::worktree::AcquireResult::Acquired(info)) => {
                    freshly_acquired_worktree = true;
                    debug!(
                        session_id = %session_id,
                        worktree = %info.worktree_path.display(),
                        branch = %info.branch,
                        "worktree acquired for session"
                    );
                    Some(info)
                }
                Ok(crate::worktree::AcquireResult::Deferred(reason)) => {
                    debug!(
                        session_id = %session_id,
                        reason = ?reason,
                        "worktree deferred, using original directory"
                    );
                    None
                }
                Ok(crate::worktree::AcquireResult::Passthrough) => None,
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
    // Local models (Ollama) use a stripped context: skip subagent/process/user-job
    // result injection at bootstrap time. Pending results remain queued in the
    // event store for future cloud-model turns. See `runtime/context/local_policy.rs`.
    let is_local_model = crate::llm::models::registry::detect_provider_from_model(&model)
        .is_some_and(crate::runtime::context::local_policy::is_local_provider);
    let bootstrap_result = if is_local_model {
        load_prompt_bootstrap_minimal(
            context_artifacts.clone(),
            event_store.clone(),
            session_id.clone(),
            working_dir.clone(),
            settings.as_ref().clone(),
            is_resumed,
            source.clone(),
        )
        .await
    } else {
        load_prompt_bootstrap(
            context_artifacts.clone(),
            event_store.clone(),
            session_id.clone(),
            working_dir.clone(),
            settings.as_ref().clone(),
            is_resumed,
            source.clone(),
        )
        .await
    };
    let prompt_bootstrap = match bootstrap_result {
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
                process_results_context: None,
                user_job_actions_context: None,
            }
        }
    };
    let prompt_artifacts = prompt_bootstrap.artifacts;
    let combined_rules = prompt_artifacts.rules_content;
    let rules_index = prompt_artifacts.rules_index;
    let pre_activated_rules = prompt_artifacts.pre_activated_rules;
    let resolved_ws_id = prompt_artifacts.workspace_id;

    let memory: Option<String> = None;
    // Merge subagent results, process results, and user job actions into unified context
    let mut job_parts: Vec<String> = Vec::new();
    if let Some(a) = prompt_bootstrap.subagent_results_context {
        job_parts.push(a);
    }
    if let Some(p) = prompt_bootstrap.process_results_context {
        job_parts.push(p);
    }
    if let Some(u) = prompt_bootstrap.user_job_actions_context {
        job_parts.push(u);
    }
    let job_results_context = if job_parts.is_empty() {
        None
    } else {
        Some(job_parts.join("\n\n"))
    };

    let memory = if let Some(ref worktree) = worktree_info {
        let worktree_context = format!(
            "\n\n## Environment Isolation\n\
             Working in git worktree: {}\n\
             Branch: {}{}\n{}",
            worktree.worktree_path.display(),
            worktree.branch,
            worktree
                .base_branch
                .as_ref()
                .map(|branch| format!(" (based on {branch})"))
                .unwrap_or_default(),
            crate::runtime::context::system_prompts::GIT_WORKFLOW_PROMPT,
        );
        Some(match memory {
            Some(memory) => format!("{memory}{worktree_context}"),
            None => worktree_context,
        })
    } else {
        memory
    };

    let messages = state.messages.clone();
    let model_for_error = model.clone();

    let provider = match provider_factory.create_for_model(&model).await {
        Ok(provider) => provider,
        Err(error) => {
            warn!(
                model = %model,
                error = %error,
                "failed to create provider for model"
            );
            let _ = broadcast.emit(crate::core::events::TronEvent::Error {
                base: crate::core::events::BaseEvent::now(&session_id),
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
            Some(crate::runtime::context::system_prompts::TRON_CHAT_PROMPT.to_string())
        } else {
            // Precedence: project .tron/SYSTEM.md > global ~/.tron/workspace/memory/rules/SYSTEM.md > embedded
            crate::runtime::context::system_prompts::load_system_prompt_from_file(&working_dir)
                .or_else(crate::runtime::context::system_prompts::load_global_system_prompt)
                .map(|loaded| loaded.content)
        },
        enable_thinking: true,
        max_turns: settings.agent.max_turns,
        compaction: crate::runtime::context::types::CompactionConfig {
            threshold: compactor_settings.compaction_threshold,
            preserve_recent_turns: compactor_settings.preserve_recent_count,
            context_limit: crate::llm::model_context_window(&model),
        },
        retry: Some(crate::core::retry::RetryConfig {
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
            compaction_trigger_config: compactor_settings.into(),
            process_manager: process_manager.clone(),
            job_manager: job_manager.clone(),
            output_buffer_registry,
        },
    );

    agent.set_abort_token(cancel_token);
    agent.set_persister(Some(persister.clone()));
    orchestrator.register_compaction_handler(&session_id, agent.compaction_handler().clone());

    // Collect skills activated since the last message.user for this prompt's payload
    let skills_payload = {
        let registry = skill_registry.read();
        collect_pending_skill_payloads(&event_store, &session_id, Some(&*registry))
    };

    let user_event_payload = build_user_event_payload(
        &prompt,
        images.as_deref(),
        attachments.as_deref(),
        message_metadata.as_ref(),
        skills_payload.as_ref(),
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

    // Refresh skill registry before building context (ensures updated SKILL.md files are loaded)
    {
        let mut registry = skill_registry.write();
        let _ = registry.refresh_if_stale(&working_dir);
    }

    // Build skill context from server-owned session state
    let skill_result = match build_skill_context_from_session(
        skill_registry.clone(),
        event_store.clone(),
        session_id.clone(),
    )
    .await
    {
        Ok(result) => result,
        Err(error) => {
            warn!(
                session_id = %session_id,
                error = %error,
                "failed to build skill context from session"
            );
            super::prompt_runtime::SkillContextResult {
                skill_activation_context: None,
                skill_context: None,
                skill_removal_context: None,
            }
        }
    };

    // Build skill index based on settings (skip for local models — index is stripped at turn time)
    let skill_index_context = if is_local_model {
        None
    } else {
        let settings = crate::settings::get_settings();
        let show_index = &settings.skills.show_index;
        let should_show = match show_index {
            crate::settings::types::ShowIndex::Always => true,
            crate::settings::types::ShowIndex::Never => false,
            crate::settings::types::ShowIndex::WhenNoActiveSkills => {
                skill_result.skill_context.is_none()
            }
        };
        if should_show {
            let registry = skill_registry.read();
            let all_skills = registry.list(None);
            let index = crate::skills::injector::build_skill_index(&all_skills);
            if index.is_empty() { None } else { Some(index) }
        } else {
            None
        }
    };

    // Estimate volatile token counts for context breakdown accounting
    let volatile_tokens = {
        let chars_per_token = 4u64;
        let skill_ctx = skill_result
            .skill_context
            .as_ref()
            .map_or(0, |s| s.len() as u64 / chars_per_token);
        let removal = skill_result
            .skill_removal_context
            .as_ref()
            .map_or(0, |s| s.len() as u64 / chars_per_token);
        let jobs = if is_local_model {
            0 // Job results stripped at turn time for local models
        } else {
            job_results_context
                .as_ref()
                .map_or(0, |s| s.len() as u64 / chars_per_token)
        };
        VolatileTokens {
            skill_context: skill_ctx,
            skill_removal: removal,
            job_results: jobs,
        }
    };

    let run_context = RunContext {
        reasoning_level: reasoning_level
            .and_then(|level| crate::runtime::types::ReasoningLevel::from_str_loose(&level)),
        skill_index_context,
        skill_activation_context: skill_result.skill_activation_context,
        skill_context: skill_result.skill_context,
        skill_removal_context: skill_result.skill_removal_context,
        job_results: job_results_context,
        user_content_override,
        volatile_tokens,
        ..Default::default()
    };

    // Fire WorktreeAcquired hook for fresh acquisitions (background, non-blocking)
    if freshly_acquired_worktree {
        if let (Some(hook_engine), Some(wt_info)) = (&hooks, &worktree_info) {
            debug!(session_id = %session_id, "[hooks] firing WorktreeAcquired");
            let hook_ctx = crate::runtime::hooks::types::HookContext::WorktreeAcquired {
                session_id: session_id.clone(),
                timestamp: chrono::Utc::now().to_rfc3339(),
                branch: wt_info.branch.clone(),
                repo_root: wt_info.repo_root.to_string_lossy().to_string(),
                base_branch: wt_info.base_branch.clone(),
                working_directory: wt_info.worktree_path.to_string_lossy().to_string(),
            };
            let _ = hook_engine.execute(&hook_ctx).await;
            debug!(session_id = %session_id, "[hooks] WorktreeAcquired returned");
        }
    }

    // Fire SessionStart hook (non-blocking, background)
    if let Some(hook_engine) = &hooks {
        debug!(session_id = %session_id, "[hooks] firing SessionStart");
        let hook_ctx = crate::runtime::hooks::types::HookContext::SessionStart {
            session_id: session_id.clone(),
            timestamp: chrono::Utc::now().to_rfc3339(),
            working_directory: working_dir.clone(),
        };
        let _ = hook_engine.execute(&hook_ctx).await;
        debug!(session_id = %session_id, "[hooks] SessionStart returned");
    }

    // Fire UserPromptSubmit hook
    if let Some(hook_engine) = &hooks {
        debug!(session_id = %session_id, "[hooks] firing UserPromptSubmit");
        let hook_ctx = crate::runtime::hooks::types::HookContext::UserPromptSubmit {
            session_id: session_id.clone(),
            timestamp: chrono::Utc::now().to_rfc3339(),
            prompt: prompt.clone(),
        };
        let _ = hook_engine.execute(&hook_ctx).await;
        debug!(session_id = %session_id, "[hooks] UserPromptSubmit returned");
    }

    debug!(session_id = %session_id, "[hooks] all hooks returned, calling run_agent");
    let result = run_agent(&mut agent, &prompt, run_context, &hooks, &broadcast, sequence_counter).await;
    orchestrator.remove_compaction_handler(&session_id);

    let _ = persister.flush().await;

    if result.interrupted {
        if let Err(error) = persister
            .append(
                &session_id,
                crate::events::EventType::NotificationInterrupted,
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

    if let Some(ref error_message) = result.error {
        let parsed = crate::core::errors::parse::parse_error(error_message);
        let _ = broadcast.emit(crate::core::events::TronEvent::Error {
            base: crate::core::events::BaseEvent::now(&session_id),
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

    run_cleanup.release();

    match load_session_update_data(
        session_manager.clone(),
        event_store.clone(),
        session_id.clone(),
    )
    .await
    {
        Ok(Some(update)) => {
            let _ = broadcast.emit(crate::core::events::TronEvent::SessionUpdated {
                base: crate::core::events::BaseEvent::now(&session_id),
                title: update.session.title.clone(),
                model: Some(update.session.latest_model.clone()),
                message_count: Some(update.session.message_count),
                input_tokens: Some(update.session.total_input_tokens),
                output_tokens: Some(update.session.total_output_tokens),
                last_turn_input_tokens: Some(update.session.last_turn_input_tokens),
                cache_read_tokens: Some(update.session.total_cache_read_tokens),
                cache_creation_tokens: Some(update.session.total_cache_creation_tokens),
                cost: Some(update.session.total_cost),
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
                activity_lines: Some(update.activity_lines),
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

    // Auto-drain: check the prompt queue and start the next queued message if present.
    // This runs after the run is fully complete (agent.ready emitted, cleanup done),
    // so the session is free for a new run.
    drain_prompt_queue(
        &event_store,
        &orchestrator,
        &session_manager,
        &session_id,
        &model,
        &working_dir,
        orchestrator.broadcast().clone(),
        drain_provider_factory,
        drain_tool_factory,
        drain_guardrails,
        drain_health_tracker,
        drain_context_artifacts,
        drain_skill_registry,
        drain_subagent_manager,
        drain_shutdown_token,
        drain_worktree_coordinator,
        drain_process_manager,
        drain_job_manager,
        drain_output_buffer_registry,
        drain_hook_abort_tracker,
        drain_server_origin,
    );
}

/// Check the prompt queue for the session and, if there is a pending message,
/// dequeue it and spawn a new prompt run for it.
#[allow(clippy::too_many_arguments)]
fn drain_prompt_queue(
    event_store: &Arc<crate::events::EventStore>,
    orchestrator: &Arc<crate::runtime::orchestrator::orchestrator::Orchestrator>,
    session_manager: &Arc<crate::runtime::orchestrator::session_manager::SessionManager>,
    session_id: &str,
    model: &str,
    working_dir: &str,
    broadcast: Arc<crate::runtime::EventEmitter>,
    provider_factory: Arc<dyn crate::llm::provider::ProviderFactory>,
    tool_factory: Arc<dyn Fn() -> crate::tools::registry::ToolRegistry + Send + Sync>,
    guardrails: Option<Arc<parking_lot::Mutex<crate::runtime::guardrails::GuardrailEngine>>>,
    health_tracker: Arc<crate::llm::ProviderHealthTracker>,
    context_artifacts: Arc<crate::server::rpc::session_context::ContextArtifactsService>,
    skill_registry: Arc<RwLock<SkillRegistry>>,
    subagent_manager: Option<Arc<crate::runtime::orchestrator::subagent_manager::SubagentManager>>,
    shutdown_token: Option<tokio_util::sync::CancellationToken>,
    worktree_coordinator: Option<Arc<crate::worktree::WorktreeCoordinator>>,
    process_manager: Option<Arc<dyn crate::tools::traits::ProcessManagerOps>>,
    job_manager: Option<Arc<dyn crate::tools::traits::JobManagerOps>>,
    output_buffer_registry: Option<Arc<crate::runtime::orchestrator::output_buffer::OutputBufferRegistry>>,
    hook_abort_tracker: Arc<crate::runtime::hooks::abort_tracker::HookAbortTracker>,
    server_origin: String,
) {
    use crate::server::rpc::prompt_queue::PromptQueueService;
    use crate::settings::types::QueueDrainMode;

    let settings = crate::settings::get_settings();
    let drain_mode = &settings.session.queue_drain_mode;

    // Peek at the queue — do NOT dequeue until run is confirmed.
    let pending = match PromptQueueService::get_pending_queue(event_store, session_id) {
        Ok(items) => items,
        Err(e) => {
            warn!(session_id, error = %e, "failed to query prompt queue");
            return;
        }
    };
    if pending.is_empty() {
        return;
    }

    // Determine prompt text based on drain mode.
    //
    // Metadata (messageKind/confirmationDecision/answerCount) is only
    // carried in Sequential mode — batched drains combine multiple user
    // messages into a single prompt, at which point the individual
    // message kinds no longer apply to the merged content.
    let (prompt_text, items_to_dequeue, drained_metadata) = match drain_mode {
        QueueDrainMode::Sequential => {
            // One message per turn
            let item = &pending[0];
            (item.text.clone(), vec![item.clone()], item.metadata.clone())
        }
        QueueDrainMode::Batched => {
            // Combine all pending into a single prompt
            let combined = pending.iter().map(|i| i.text.as_str()).collect::<Vec<_>>().join("\n\n");
            (combined, pending, None)
        }
    };

    debug!(
        session_id,
        mode = ?drain_mode,
        count = items_to_dequeue.len(),
        text_preview = %prompt_text.chars().take(80).collect::<String>(),
        "auto-draining queued prompt(s)"
    );

    let run_id = uuid::Uuid::now_v7().to_string();
    let started_run = match orchestrator.begin_run(session_id, &run_id) {
        Ok(run) => run,
        Err(e) => {
            warn!(session_id, error = %e, "failed to begin run for queued prompt, messages preserved in queue");
            return;
        }
    };

    // Run is registered — NOW it's safe to mark messages as processed.
    for item in &items_to_dequeue {
        if let Err(e) = PromptQueueService::dequeue(event_store, session_id, &item.queue_id, "processed") {
            warn!(session_id, queue_id = %item.queue_id, error = %e, "failed to dequeue message");
        }
        let _ = orchestrator.broadcast().emit(crate::core::events::TronEvent::MessageDequeued {
            base: crate::core::events::BaseEvent::now(session_id),
            queue_id: item.queue_id.clone(),
            reason: "processed".into(),
        });
    }

    // Broadcast the user message so iOS can render the bubble in real-time.
    // In the normal flow, iOS adds the user bubble locally before the RPC.
    // During auto-drain, the server owns the prompt — this event is how iOS learns about it.
    let _ = orchestrator.broadcast().emit(crate::core::events::TronEvent::QueuedMessageSent {
        base: crate::core::events::BaseEvent::now(session_id),
        text: prompt_text.clone(),
        queue_id: items_to_dequeue.first().map(|i| i.queue_id.clone()).unwrap_or_default(),
    });

    let sequence_counter = orchestrator.get_sequence_counter(session_id);

    let plan = PromptRunPlan {
        started_run,
        orchestrator: orchestrator.clone(),
        session_manager: session_manager.clone(),
        broadcast,
        provider_factory,
        tool_factory,
        guardrails,
        health_tracker,
        event_store: event_store.clone(),
        context_artifacts,
        skill_registry,
        subagent_manager,
        shutdown_token: shutdown_token.clone(),
        worktree_coordinator,
        process_manager,
        job_manager,
        output_buffer_registry,
        hook_abort_tracker,
        sequence_counter,
        source: session_manager
            .get_session(session_id)
            .ok()
            .flatten()
            .and_then(|s| s.source),
        server_origin,
        run_id,
        model: model.to_string(),
        working_dir: working_dir.to_string(),
        request: PromptRequest {
            session_id: session_id.to_string(),
            prompt: prompt_text,
            reasoning_level: None,
            images: None,
            attachments: None,
            message_metadata: drained_metadata,
        },
    };

    let _handle = tokio::spawn(async move {
        execute_prompt_run(plan).await;
    });
}
