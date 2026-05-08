use super::PromptEngineCausality;

pub(crate) async fn publish_prompt_runtime_stream(
    engine_host: &crate::engine::EngineHostHandle,
    causality: Option<&PromptEngineCausality>,
    session_id: &str,
    action: &str,
    mut payload: serde_json::Value,
) {
    if let (Some(causality), Some(object)) = (causality, payload.as_object_mut()) {
        object.insert(
            "traceId".to_owned(),
            serde_json::json!(causality.context.trace_id.as_str()),
        );
        object.insert(
            "parentInvocationId".to_owned(),
            serde_json::json!(
                causality
                    .parent_invocation_id
                    .as_ref()
                    .map(|id| id.as_str())
            ),
        );
        object.insert(
            "invocationId".to_owned(),
            serde_json::json!(causality.invocation_id.as_str()),
        );
        object.insert(
            "functionId".to_owned(),
            serde_json::json!(causality.function_id.as_str()),
        );
        object.insert(
            "catalogRevision".to_owned(),
            serde_json::json!(causality.context.catalog_revision.0),
        );
        object.insert(
            "expectedFunctionRevision".to_owned(),
            serde_json::json!(
                causality
                    .expected_function_revision
                    .map(|revision| revision.0)
            ),
        );
        object.insert(
            "idempotencyKey".to_owned(),
            serde_json::json!(causality.idempotency_key.clone()),
        );
    }
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
