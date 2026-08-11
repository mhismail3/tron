use std::sync::Arc;

use super::{PromptRequest, PromptRunPlan, PromptRuntimeDeps, StartedRun, execute_prompt_run};
use crate::domains::model::responder::ModelResponderFactory;

pub fn spawn_prompt_run(
    runtime_deps: &PromptRuntimeDeps,
    responder_factory: Arc<dyn ModelResponderFactory>,
    session: &crate::domains::session::event_store::SessionRow,
    started_run: StartedRun,
    run_id: String,
    request: PromptRequest,
) {
    spawn_prompt_run_with_model(
        runtime_deps,
        responder_factory,
        session,
        started_run,
        run_id,
        None,
        request,
    );
}

/// Spawn the ordinary persistent-session loop with an immutable execution-time
/// model snapshot. Reusable assignments use this seam so a per-assignment
/// override does not rewrite the stable transcript's default model.
pub(crate) fn spawn_prompt_run_with_model(
    runtime_deps: &PromptRuntimeDeps,
    responder_factory: Arc<dyn ModelResponderFactory>,
    session: &crate::domains::session::event_store::SessionRow,
    started_run: StartedRun,
    run_id: String,
    model_override: Option<String>,
    request: PromptRequest,
) {
    let plan = PromptRunPlan {
        started_run,
        orchestrator: runtime_deps.orchestrator.clone(),
        session_manager: runtime_deps.session_manager.clone(),
        responder_factory,
        settings: runtime_deps.settings.clone(),
        event_store: runtime_deps.event_store.clone(),
        shutdown_token: runtime_deps
            .shutdown_coordinator
            .as_ref()
            .map(|coord| coord.token()),
        engine_host: runtime_deps.engine_host.clone(),
        server_origin: runtime_deps.origin.clone(),
        run_id,
        model: model_override.unwrap_or_else(|| session.latest_model.clone()),
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
