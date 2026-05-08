use super::*;

pub(crate) async fn execute_prompt_run(plan: PromptRunPlan) {
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
            engine_host: Some(engine_host.clone()),
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
            crate::server::domains::agent::runtime::runtime::SkillContextResult {
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
        run_id: Some(run_id.clone()),
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
    // turn is waiting for user input, not concluded). Spawned so the engine invocation
    // response returns immediately; the summarizer itself is async inside
    // `trigger_retain`.
    if result.error.is_none() && !result.interrupted && retain_eligible(&result.stop_reason) {
        let deps = crate::server::domains::memory::retain::RetainDeps {
            orchestrator: orchestrator.clone(),
            event_store: event_store.clone(),
            subagent_manager: subagent_manager.clone(),
        };
        let auto_retain_session_id = session_id.clone();
        drop(tokio::spawn(async move {
            crate::server::domains::memory::retain::auto_retain::maybe_fire(
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
