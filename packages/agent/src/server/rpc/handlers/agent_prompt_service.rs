use std::sync::Arc;
use std::sync::atomic::AtomicI64;

use crate::runtime::orchestrator::agent_factory::{AgentFactory, CreateAgentOpts};
use crate::runtime::orchestrator::agent_runner::run_agent;
use crate::runtime::orchestrator::orchestrator::StartedRun;
use crate::runtime::types::{AgentConfig, RunContext, VolatileTokens};
use crate::skills::registry::SkillRegistry;
use parking_lot::RwLock;
use serde::Serialize;
use serde_json::Value;
use tracing::{debug, warn};

use crate::engine::policy::ENGINE_INTERNAL_INVOKE_SCOPE;
use crate::engine::queue::publish_queue_lifecycle_event;
use crate::engine::{
    ActorId, ActorKind, AuthorityGrantId, CausalContext, EngineQueueDrainer, EnqueueInvocation,
    FunctionId, Invocation, InvocationId, PublishStreamEvent, TraceId, VisibilityScope,
};
use crate::server::rpc::context::{AgentDeps, RpcContext};
use crate::server::rpc::errors::RpcError;

use super::prompt_runtime::{
    PromptBootstrapData, PromptContextArtifacts, build_user_content_override,
    build_user_event_payload, collect_pending_skill_payloads, load_prompt_bootstrap,
    load_prompt_bootstrap_minimal, load_session_update_data, persist_user_message_event,
    prepare_skill_context_from_session, resume_prompt_session,
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
    /// Optional engine causality propagated from accepted/apply invocations
    /// into completion-triggered prompt queue drains.
    pub engine_causality: Option<PromptEngineCausality>,
}

#[derive(Clone)]
pub struct PromptEngineCausality {
    context: CausalContext,
    parent_invocation_id: Option<InvocationId>,
}

impl PromptEngineCausality {
    #[must_use]
    pub fn from_invocation(invocation: &Invocation) -> Self {
        Self {
            context: invocation.causal_context.clone(),
            parent_invocation_id: Some(invocation.id.clone()),
        }
    }
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PromptDrainOutcome {
    pub drained: bool,
    pub count: usize,
    pub run_id: Option<String>,
    pub reason: Option<String>,
}

impl PromptDrainOutcome {
    fn drained(run_id: String, count: usize) -> Self {
        Self {
            drained: true,
            count,
            run_id: Some(run_id),
            reason: None,
        }
    }

    fn not_drained(reason: impl Into<String>) -> Self {
        Self {
            drained: false,
            count: 0,
            run_id: None,
            reason: Some(reason.into()),
        }
    }
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
    memory_registry: Arc<parking_lot::Mutex<crate::runtime::memory::MemoryRegistry>>,
    profile_runtime: Arc<crate::runtime::ProfileRuntime>,
    subagent_manager: Option<Arc<crate::runtime::orchestrator::subagent_manager::SubagentManager>>,
    shutdown_token: Option<tokio_util::sync::CancellationToken>,
    worktree_coordinator: Option<Arc<crate::worktree::WorktreeCoordinator>>,
    process_manager: Option<Arc<dyn crate::tools::traits::ProcessManagerOps>>,
    job_manager: Option<Arc<dyn crate::tools::traits::JobManagerOps>>,
    output_buffer_registry:
        Option<Arc<crate::runtime::orchestrator::output_buffer::OutputBufferRegistry>>,
    hook_abort_tracker: Arc<crate::runtime::hooks::abort_tracker::HookAbortTracker>,
    engine_host: crate::engine::EngineHostHandle,
    engine_causality: Option<PromptEngineCausality>,
    sequence_counter: Option<Arc<AtomicI64>>,
    server_origin: String,
    run_id: String,
    source: Option<String>,
    profile: String,
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
    let engine_causality = request.engine_causality.clone();
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
        memory_registry: ctx.memory_registry.clone(),
        profile_runtime: ctx.profile_runtime.clone(),
        subagent_manager: ctx.subagent_manager.clone(),
        shutdown_token: ctx.shutdown_coordinator.as_ref().map(|coord| coord.token()),
        worktree_coordinator: ctx.worktree_coordinator.clone(),
        process_manager: ctx.process_manager.clone(),
        job_manager: ctx.job_manager.clone(),
        output_buffer_registry: ctx.output_buffer_registry.clone(),
        hook_abort_tracker: ctx.hook_abort_tracker.clone(),
        engine_host: ctx.engine_host.clone(),
        engine_causality,
        sequence_counter: {
            let sid = &request.session_id;
            let max_seq = ctx.event_store.get_max_sequence(sid).unwrap_or(0);
            Some(
                ctx.orchestrator
                    .ensure_sequence_counter_at_least(sid, max_seq),
            )
        },
        server_origin: ctx.origin.clone(),
        run_id,
        source: session.source.clone(),
        profile: session.profile.clone(),
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
        memory_registry,
        profile_runtime,
        subagent_manager,
        shutdown_token,
        worktree_coordinator,
        process_manager,
        job_manager,
        output_buffer_registry,
        hook_abort_tracker,
        engine_host,
        engine_causality,
        sequence_counter,
        server_origin,
        run_id,
        source,
        profile,
        model,
        working_dir,
        request,
    } = plan;

    let session_plan = match profile_runtime.plan_session(crate::runtime::SessionPlanRequest {
        requested_profile: Some(profile.clone()),
        model: model.clone(),
        source: source.clone(),
        entrypoint: None,
    }) {
        Ok(plan) => plan,
        Err(error) => {
            warn!(
                session_id = %request.session_id,
                profile = %profile,
                error = %error,
                "failed to resolve session profile"
            );
            let _ = broadcast.emit(crate::core::events::TronEvent::Error {
                base: crate::core::events::BaseEvent::now(&request.session_id),
                error: format!("Session profile `{profile}` is invalid: {error}"),
                context: None,
                code: Some("PROFILE_INVALID".into()),
                provider: None,
                category: Some("profile".into()),
                suggestion: Some(
                    "Repair the profile or create a new session with a valid profile.".into(),
                ),
                retryable: Some(false),
                status_code: None,
                error_type: Some("profile".into()),
                model: Some(model),
            });
            return;
        }
    };
    let resolved_profile = session_plan.resolved_profile.clone();

    let is_chat = profile == crate::core::profile::CHAT_PROFILE
        || !should_acquire_worktree_for_source(source.as_deref());

    let PromptRequest {
        session_id,
        prompt,
        reasoning_level,
        images,
        attachments,
        message_metadata,
        engine_causality: _,
    } = request;

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
        engine.set_error_policy(hook_settings.error_policy);

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
    let worktree_info: Option<crate::worktree::WorktreeInfo> = if is_chat {
        // INVARIANT: Chat sessions never acquire a worktree. This is a
        // server-enforced rule independent of the global IsolationMode
        // and any per-session `useWorktree` override — chat sessions are
        // conversational and have no working tree to isolate. See
        // `should_acquire_worktree_for_source`.
        None
    } else if let Some(wt_path) = &state.worktree_path {
        // External-deletion recovery: the event log recorded a worktree
        // path for this session, but the directory itself may have been
        // deleted or moved out-of-band (user `rm -rf`'d it, external
        // cleanup script, volume unmount, symlink target removed). When
        // the recorded path no longer resolves to a directory, drop it
        // and re-enter the acquire branch — otherwise every downstream
        // git op operates on a dead directory and fails.
        let path_buf = std::path::PathBuf::from(wt_path);
        if !path_buf.is_dir() {
            warn!(
                session_id = %session_id,
                stale_path = %path_buf.display(),
                "recorded worktree path no longer exists on disk; re-acquiring"
            );
            // Re-enter the acquire branch inline — the outer `else if`
            // chain does not fall through on its own.
            if let Some(ref coordinator) = worktree_coordinator {
                let use_worktree_override = event_store
                    .get_session(&session_id)
                    .ok()
                    .flatten()
                    .and_then(|row| row.use_worktree);
                match coordinator
                    .maybe_acquire_with_override(
                        &session_id,
                        std::path::Path::new(&working_dir),
                        use_worktree_override,
                    )
                    .await
                {
                    Ok(crate::worktree::AcquireResult::Acquired(info)) => {
                        freshly_acquired_worktree = true;
                        Some(info)
                    }
                    Ok(crate::worktree::AcquireResult::Deferred(_)) => None,
                    Ok(crate::worktree::AcquireResult::Passthrough) => None,
                    Err(error) => {
                        warn!(
                            session_id = %session_id,
                            error = %error,
                            "worktree re-acquisition after stale path failed; using original directory"
                        );
                        None
                    }
                }
            } else {
                None
            }
        } else {
            worktree_coordinator
                .as_ref()
                .and_then(|coordinator| coordinator.get_info(&session_id))
                .or_else(|| {
                    Some(crate::worktree::WorktreeInfo {
                        session_id: session_id.clone(),
                        worktree_path: path_buf,
                        branch: String::new(),
                        base_commit: String::new(),
                        base_branch: None,
                        original_working_dir: std::path::PathBuf::from(&working_dir),
                        repo_root: std::path::PathBuf::from(&working_dir),
                    })
                })
        }
    } else if let Some(ref coordinator) = worktree_coordinator {
        // Look up the session's optional per-session worktree override.
        // None defers to the global IsolationMode setting.
        let use_worktree_override = event_store
            .get_session(&session_id)
            .ok()
            .flatten()
            .and_then(|row| row.use_worktree);
        match coordinator
            .maybe_acquire_with_override(
                &session_id,
                std::path::Path::new(&working_dir),
                use_worktree_override,
            )
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
    let context_policy = session_plan.runtime_context_policy();
    // Bootstrap result injection follows the active profile context policy.
    // Skipped results stay queued in the event store for future turns whose
    // profile policy allows them.
    let bootstrap_result = if context_policy.skip_pending_jobs_bootstrap() {
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

    // Load user memory (MEMORY.md + rules/ listing) for this turn according to
    // the active profile context policy.
    let memory: Option<String> = if context_policy.strip_memory() {
        None
    } else {
        let mut reg = memory_registry.lock();
        Some(reg.content(&crate::core::paths::home_dir()).to_string())
    };
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
            resolved_profile
                .spec
                .entrypoint_prompts
                .get("gitWorkflow")
                .map(|prompt| prompt.content.as_str())
                .unwrap_or(""),
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
    let context_limit = provider.context_window();
    let profile_prompt = session_plan
        .prompt
        .as_ref()
        .map(|prompt| prompt.content.clone())
        .unwrap_or_default();
    let system_prompt = if profile == crate::core::profile::NORMAL_PROFILE {
        crate::runtime::context::instruction_prompts::load_system_prompt_from_file(&working_dir)
            .or_else(crate::runtime::context::instruction_prompts::load_global_system_prompt)
            .map(|loaded| loaded.content)
            .or(Some(profile_prompt))
    } else {
        Some(profile_prompt)
    };
    let config = AgentConfig {
        model: model.clone(),
        working_directory: Some(working_dir.clone()),
        server_origin: Some(server_origin),
        system_prompt,
        enable_thinking: true,
        max_turns: settings.agent.max_turns,
        compaction: crate::runtime::context::types::CompactionConfig {
            threshold: compactor_settings.compaction_threshold,
            preserve_recent_turns: compactor_settings.preserve_recent_count,
            context_limit,
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
            context_policy: session_plan.runtime_context_policy(),
            tool_policy: session_plan.tool_policy.clone(),
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
    agent.set_tool_abort_registry(orchestrator.tool_abort_registry().clone());
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

    // Prepare skill context — note this also writes a `skills.cleared`
    // event under AskUser policy. See prepare_skill_context_from_session
    // for the full side-effect contract.
    let skill_result = match prepare_skill_context_from_session(
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

    // Build skill index based on settings and the active profile context policy.
    let skill_index_context = if context_policy.strip_skill_index() {
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
        let jobs = if context_policy.strip_job_results() {
            0
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

    let mut run_context = RunContext {
        reasoning_level: reasoning_level
            .and_then(|level| crate::runtime::types::ReasoningLevel::from_str_loose(&level)),
        skill_index_context,
        skill_activation_context: skill_result.skill_activation_context,
        skill_context: skill_result.skill_context,
        skill_removal_context: skill_result.skill_removal_context,
        job_results: job_results_context,
        profile_name: Some(profile.clone()),
        resolved_profile: Some(resolved_profile.clone()),
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

    // Fire UserPromptSubmit hook. If any hook returns an AddContext
    // action with non-empty `added_context`, prepend that content to
    // the prompt inside a clearly-marked XML-style block so the LLM
    // can distinguish it from what the user typed.
    let mut effective_prompt = prompt.clone();
    if let Some(hook_engine) = &hooks {
        debug!(session_id = %session_id, "[hooks] firing UserPromptSubmit");
        let hook_ctx = crate::runtime::hooks::types::HookContext::UserPromptSubmit {
            session_id: session_id.clone(),
            timestamp: chrono::Utc::now().to_rfc3339(),
            prompt: prompt.clone(),
        };
        let hook_result = hook_engine.execute(&hook_ctx).await;
        if hook_result.action == crate::runtime::hooks::types::HookAction::AddContext
            && let Some(content) = hook_result.added_context
            && !content.is_empty()
        {
            debug!(
                session_id = %session_id,
                bytes = content.len(),
                "[hooks] UserPromptSubmit injected added_context into prompt"
            );
            run_context.hook_context = Some(content.clone());
            effective_prompt = format!(
                "<hook-context>\n{content}\n</hook-context>\n\n{prompt}",
                content = content,
                prompt = prompt,
            );
        }
        debug!(session_id = %session_id, "[hooks] UserPromptSubmit returned");
    }

    debug!(session_id = %session_id, "[hooks] all hooks returned, calling run_agent");
    let result = run_agent(
        &mut agent,
        &effective_prompt,
        run_context,
        &hooks,
        &broadcast,
        sequence_counter,
    )
    .await;
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

    // Auto-retain: fire policy evaluation on successful completion. Subagent
    // and disabled-interval cases are filtered inside `maybe_fire`, so the
    // gate here only covers interrupt/error (retentions of half-finished runs
    // would summarize noise) and interactive-tool pauses (`ToolStop` — the
    // turn is waiting for user input, not concluded). Spawned so the RPC
    // response returns immediately; the summarizer itself is async inside
    // `trigger_retain`.
    if result.error.is_none() && !result.interrupted && retain_eligible(&result.stop_reason) {
        let deps = crate::server::rpc::handlers::memory::RetainDeps {
            orchestrator: orchestrator.clone(),
            event_store: event_store.clone(),
            subagent_manager: subagent_manager.clone(),
        };
        let auto_retain_session_id = session_id.clone();
        drop(tokio::spawn(async move {
            crate::server::rpc::handlers::memory::auto_retain::maybe_fire(
                &deps,
                &auto_retain_session_id,
            )
            .await;
        }));
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
    publish_prompt_runtime_stream(
        &engine_host,
        engine_causality.as_ref(),
        &session_id,
        "completed",
        serde_json::json!({
            "runId": run_id,
            "turnsExecuted": result.turns_executed,
            "interrupted": result.interrupted,
            "stopReason": format!("{:?}", result.stop_reason),
            "error": result.error,
        }),
    )
    .await;

    // Auto-drain is now hidden engine queue work. Completion only enqueues
    // the drain capability, so queue handoff, trace propagation, and
    // idempotency are visible through the engine ledger and stream records.
    enqueue_prompt_queue_drain(
        &engine_host,
        &session_id,
        &run_id,
        engine_causality.as_ref(),
    )
    .await;
}

/// Check the prompt queue for the session and, if there is a pending message,
/// dequeue it and spawn a new prompt run for it.
#[allow(clippy::too_many_arguments)]
pub(crate) fn drain_prompt_queue(
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
    memory_registry: Arc<parking_lot::Mutex<crate::runtime::memory::MemoryRegistry>>,
    profile_runtime: Arc<crate::runtime::ProfileRuntime>,
    subagent_manager: Option<Arc<crate::runtime::orchestrator::subagent_manager::SubagentManager>>,
    shutdown_token: Option<tokio_util::sync::CancellationToken>,
    worktree_coordinator: Option<Arc<crate::worktree::WorktreeCoordinator>>,
    process_manager: Option<Arc<dyn crate::tools::traits::ProcessManagerOps>>,
    job_manager: Option<Arc<dyn crate::tools::traits::JobManagerOps>>,
    output_buffer_registry: Option<
        Arc<crate::runtime::orchestrator::output_buffer::OutputBufferRegistry>,
    >,
    hook_abort_tracker: Arc<crate::runtime::hooks::abort_tracker::HookAbortTracker>,
    server_origin: String,
    engine_host: crate::engine::EngineHostHandle,
    engine_causality: Option<PromptEngineCausality>,
) -> Result<PromptDrainOutcome, RpcError> {
    use crate::server::rpc::prompt_queue::PromptQueueService;
    use crate::settings::types::QueueDrainMode;

    let settings = crate::settings::get_settings();
    let drain_mode = &settings.session.queue_drain_mode;

    // Peek at the queue — do NOT dequeue until run is confirmed.
    let pending = match PromptQueueService::get_pending_queue(event_store, session_id) {
        Ok(items) => items,
        Err(e) => {
            warn!(session_id, error = %e, "failed to query prompt queue");
            return Err(e);
        }
    };
    if pending.is_empty() {
        return Ok(PromptDrainOutcome::not_drained("empty"));
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
            let combined = pending
                .iter()
                .map(|i| i.text.as_str())
                .collect::<Vec<_>>()
                .join("\n\n");
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
            return Ok(PromptDrainOutcome::not_drained("busy"));
        }
    };

    // Run is registered — NOW it's safe to mark messages as processed.
    for item in &items_to_dequeue {
        if let Err(e) =
            PromptQueueService::dequeue(event_store, session_id, &item.queue_id, "processed")
        {
            warn!(session_id, queue_id = %item.queue_id, error = %e, "failed to dequeue message");
        }
        let _ = orchestrator
            .broadcast()
            .emit(crate::core::events::TronEvent::MessageDequeued {
                base: crate::core::events::BaseEvent::now(session_id),
                queue_id: item.queue_id.clone(),
                reason: "processed".into(),
            });
    }

    // Broadcast the user message so iOS can render the bubble in real-time.
    // In the normal flow, iOS adds the user bubble locally before the RPC.
    // During auto-drain, the server owns the prompt — this event is how iOS learns about it.
    let _ = orchestrator
        .broadcast()
        .emit(crate::core::events::TronEvent::QueuedMessageSent {
            base: crate::core::events::BaseEvent::now(session_id),
            text: prompt_text.clone(),
            queue_id: items_to_dequeue
                .first()
                .map(|i| i.queue_id.clone())
                .unwrap_or_default(),
        });

    let max_seq = event_store.get_max_sequence(session_id).unwrap_or(0);
    let sequence_counter = Some(orchestrator.ensure_sequence_counter_at_least(session_id, max_seq));

    let session_row = session_manager.get_session(session_id).ok().flatten();
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
        memory_registry,
        profile_runtime,
        subagent_manager,
        shutdown_token: shutdown_token.clone(),
        worktree_coordinator,
        process_manager,
        job_manager,
        output_buffer_registry,
        hook_abort_tracker,
        engine_host,
        engine_causality: engine_causality.clone(),
        sequence_counter,
        source: session_row.as_ref().and_then(|s| s.source.clone()),
        profile: session_row
            .as_ref()
            .map(|s| s.profile.clone())
            .unwrap_or_else(|| crate::core::profile::NORMAL_PROFILE.to_string()),
        server_origin,
        run_id: run_id.clone(),
        model: model.to_string(),
        working_dir: working_dir.to_string(),
        request: PromptRequest {
            session_id: session_id.to_string(),
            prompt: prompt_text,
            reasoning_level: None,
            images: None,
            attachments: None,
            message_metadata: drained_metadata,
            engine_causality,
        },
    };

    let _handle = tokio::spawn(async move {
        execute_prompt_run(plan).await;
    });
    Ok(PromptDrainOutcome::drained(run_id, items_to_dequeue.len()))
}

async fn enqueue_prompt_queue_drain(
    engine_host: &crate::engine::EngineHostHandle,
    session_id: &str,
    completed_run_id: &str,
    causality: Option<&PromptEngineCausality>,
) {
    let function_id = match FunctionId::new("agent::prompt_queue_drain") {
        Ok(id) => id,
        Err(error) => {
            warn!(session_id, error = %error, "invalid prompt queue drain function id");
            return;
        }
    };
    let mut authority_scopes = causality
        .map(|causality| causality.context.authority_scopes.clone())
        .unwrap_or_else(|| vec!["agent.write".to_owned()]);
    for scope in ["agent.write", ENGINE_INTERNAL_INVOKE_SCOPE] {
        if !authority_scopes.iter().any(|existing| existing == scope) {
            authority_scopes.push(scope.to_owned());
        }
    }
    let item = engine_host
        .enqueue_invocation(EnqueueInvocation {
            queue: "agent".to_owned(),
            function_id,
            target_revision: None,
            payload: serde_json::json!({
                "sessionId": session_id,
                "completedRunId": completed_run_id,
            }),
            actor_id: causality
                .map(|causality| causality.context.actor_id.clone())
                .unwrap_or_else(|| ActorId::new("system").expect("valid static actor id")),
            actor_kind: causality
                .map(|causality| causality.context.actor_kind.clone())
                .unwrap_or(ActorKind::System),
            authority_grant_id: causality
                .map(|causality| causality.context.authority_grant_id.clone())
                .unwrap_or_else(|| {
                    AuthorityGrantId::new("prompt-runtime").expect("valid static grant id")
                }),
            authority_scopes,
            trace_id: causality
                .map(|causality| causality.context.trace_id.clone())
                .unwrap_or_else(TraceId::generate),
            parent_invocation_id: causality
                .and_then(|causality| causality.parent_invocation_id.clone()),
            trigger_id: causality.and_then(|causality| causality.context.trigger_id.clone()),
            session_id: Some(session_id.to_owned()),
            workspace_id: causality.and_then(|causality| causality.context.workspace_id.clone()),
            idempotency_key: Some(format!(
                "agent.prompt.queue_drain:{session_id}:{completed_run_id}"
            )),
        })
        .await;
    let item = match item {
        Ok(item) => item,
        Err(error) => {
            warn!(session_id, error = %error, "failed to enqueue prompt queue drain");
            return;
        }
    };
    publish_queue_lifecycle_event(engine_host, "enqueue", &item, None).await;
    let host = engine_host.clone();
    let receipt = item.receipt_id.clone();
    drop(tokio::spawn(async move {
        let _ = EngineQueueDrainer::drain_receipt(&host, &receipt, "agent-prompt-auto-drain").await;
    }));
}

async fn publish_prompt_runtime_stream(
    engine_host: &crate::engine::EngineHostHandle,
    causality: Option<&PromptEngineCausality>,
    session_id: &str,
    action: &str,
    payload: serde_json::Value,
) {
    let _ = engine_host
        .publish_stream_event(PublishStreamEvent {
            topic: "agent.queue".to_owned(),
            payload: serde_json::json!({
                "type": format!("agent.prompt.{action}"),
                "action": action,
                "sessionId": session_id,
                "payload": payload,
            }),
            visibility: VisibilityScope::Session,
            session_id: Some(session_id.to_owned()),
            workspace_id: causality.and_then(|causality| causality.context.workspace_id.clone()),
            producer: "agent::prompt_apply".to_owned(),
            trace_id: causality.map(|causality| causality.context.trace_id.clone()),
            parent_invocation_id: causality
                .and_then(|causality| causality.parent_invocation_id.clone()),
        })
        .await;
}

/// Returns true if a new prompt run for this session should attempt worktree
/// acquisition. Chat sessions (`source == Some("chat")`) are conversational and
/// never get worktrees regardless of global isolation mode or per-session
/// `useWorktree` override — the server is authoritative on this invariant, so
/// callers don't need to pass `useWorktree: false` explicitly.
fn should_acquire_worktree_for_source(source: Option<&str>) -> bool {
    source != Some("chat")
}

/// Whether a finished agent run's stop reason represents a coherent
/// conclusion that auto-retain can safely summarize.
///
/// - `EndTurn`, `NoToolCalls`, `MaxTurns` — agent produced real work.
/// - `ToolStop` — interactive tool paused the turn awaiting user input;
///   summarizing mid-dialog produces incoherent output.
/// - `Error`, `Interrupted` — already filtered by caller, included here
///   as defense in depth.
fn retain_eligible(stop_reason: &crate::runtime::errors::StopReason) -> bool {
    use crate::runtime::errors::StopReason;
    matches!(
        stop_reason,
        StopReason::EndTurn | StopReason::NoToolCalls | StopReason::MaxTurns
    )
}

#[cfg(test)]
mod retain_eligible_tests {
    use super::retain_eligible;
    use crate::runtime::errors::StopReason;

    #[test]
    fn end_turn_is_eligible() {
        assert!(retain_eligible(&StopReason::EndTurn));
    }

    #[test]
    fn no_tool_calls_is_eligible() {
        assert!(retain_eligible(&StopReason::NoToolCalls));
    }

    #[test]
    fn max_turns_is_eligible() {
        assert!(retain_eligible(&StopReason::MaxTurns));
    }

    #[test]
    fn tool_stop_is_not_eligible() {
        assert!(!retain_eligible(&StopReason::ToolStop));
    }

    #[test]
    fn interrupted_is_not_eligible() {
        assert!(!retain_eligible(&StopReason::Interrupted));
    }

    #[test]
    fn error_is_not_eligible() {
        assert!(!retain_eligible(&StopReason::Error));
    }
}

#[cfg(test)]
mod should_acquire_worktree_tests {
    use super::should_acquire_worktree_for_source;

    #[test]
    fn chat_source_never_acquires_worktree() {
        assert!(!should_acquire_worktree_for_source(Some("chat")));
    }

    #[test]
    fn project_source_may_acquire_worktree() {
        assert!(should_acquire_worktree_for_source(Some("project")));
    }

    #[test]
    fn missing_source_may_acquire_worktree() {
        // Rows without an explicit source default to non-chat behavior.
        assert!(should_acquire_worktree_for_source(None));
    }

    #[test]
    fn unknown_source_may_acquire_worktree() {
        // Forward compat: unknown sources get default (non-chat) behavior.
        assert!(should_acquire_worktree_for_source(Some("future_source")));
    }

    #[test]
    fn empty_string_source_may_acquire_worktree() {
        // Edge case: empty string is not "chat".
        assert!(should_acquire_worktree_for_source(Some("")));
    }

    #[test]
    fn uppercase_chat_does_not_match() {
        // Case-sensitive match — only exact "chat" skips.
        assert!(should_acquire_worktree_for_source(Some("Chat")));
        assert!(should_acquire_worktree_for_source(Some("CHAT")));
    }
}
