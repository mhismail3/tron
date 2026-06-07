use super::{
    AgentDeps, PromptRequest, PromptRunPlan, PromptRuntimeDeps, StartedRun, execute_prompt_run,
};

pub fn spawn_prompt_run(
    runtime_deps: &PromptRuntimeDeps,
    agent_deps: &AgentDeps,
    session: &crate::domains::session::event_store::sqlite::row_types::SessionRow,
    started_run: StartedRun,
    run_id: String,
    request: PromptRequest,
) {
    let engine_causality = request.engine_causality.clone();
    let plan = PromptRunPlan {
        started_run,
        orchestrator: runtime_deps.orchestrator.clone(),
        session_manager: runtime_deps.session_manager.clone(),
        broadcast: runtime_deps.orchestrator.broadcast().clone(),
        provider_factory: agent_deps.provider_factory.clone(),
        health_tracker: runtime_deps.health_tracker.clone(),
        event_store: runtime_deps.event_store.clone(),
        profile_runtime: runtime_deps.profile_runtime.clone(),
        shutdown_token: runtime_deps
            .shutdown_coordinator
            .as_ref()
            .map(|coord| coord.token()),
        engine_host: runtime_deps.engine_host.clone(),
        engine_causality,
        sequence_counter: {
            let sid = &request.session_id;
            let max_seq = runtime_deps.event_store.get_max_sequence(sid).unwrap_or(0);
            Some(
                runtime_deps
                    .orchestrator
                    .ensure_sequence_counter_at_least(sid, max_seq),
            )
        },
        server_origin: runtime_deps.origin.clone(),
        run_id,
        model: session.latest_model.clone(),
        working_dir: session.working_directory.clone(),
        request,
    };

    let shutdown_coordinator = runtime_deps.shutdown_coordinator.clone();
    let handle = tokio::spawn(async move {
        execute_prompt_run(plan).await;
    });
    if let Some(coord) = shutdown_coordinator {
        coord.register_task(handle);
    }
}
