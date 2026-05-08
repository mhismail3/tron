use super::*;

pub(crate) async fn publish_prompt_runtime_stream(
    engine_host: &crate::engine::EngineHostHandle,
    causality: Option<&PromptEngineCausality>,
    session_id: &str,
    action: &str,
    payload: serde_json::Value,
) {
    crate::server::domains::agent::stream::AgentStreamPublisher::new(engine_host)
        .prompt_runtime(
            causality.and_then(|causality| causality.context.workspace_id.clone()),
            causality.map(|causality| causality.context.trace_id.clone()),
            causality.and_then(|causality| causality.parent_invocation_id.clone()),
            session_id,
            action,
            payload,
        )
        .await;
}
