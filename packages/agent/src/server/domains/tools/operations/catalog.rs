//! Tool workflow operations.
use super::ToolFunctionHandler;
use super::{
    AuthorityRequirement, EffectClass, EngineResult, FunctionDefinition, FunctionId,
    IdempotencyContract, Provenance, RiskLevel, SYSTEM_AUTHORITY_GRANT, SYSTEM_OWNER_ACTOR,
    TronTool, WorkerDefinition, WorkerKind, capability_runtime,
};
use crate::engine::VisibilityScope;
use crate::server::domains::worker::DomainRegistrationContext;
use serde_json::Value;
use serde_json::json;

pub(crate) fn register_builtin_tools_for_setup(
    deps: &DomainRegistrationContext,
) -> EngineResult<()> {
    let handle = &deps.engine_host;
    let Some(agent_deps) = deps.agent_deps.as_ref() else {
        return Ok(());
    };
    handle.register_worker_for_setup(
        WorkerDefinition::new(
            crate::server::domains::catalog::worker_id("tool")?,
            WorkerKind::InProcess,
            crate::server::domains::catalog::actor_id(SYSTEM_OWNER_ACTOR)?,
            crate::server::domains::catalog::grant_id(SYSTEM_AUTHORITY_GRANT)?,
        )
        .with_namespace_claim("tool"),
        false,
    )?;

    let registry = (agent_deps.tool_factory)();
    let tool_names = registry.names();
    for (tool_order, tool) in registry.list().into_iter().enumerate() {
        let name = tool.name().to_owned();
        let id = tool_function_id(&name)?;
        let definition = tool_function_definition(&id, tool.as_ref(), &tool_names, tool_order)?;
        let handler = ToolFunctionHandler {
            tool,
            process_manager: deps.process_manager.clone(),
            job_manager: deps.job_manager.clone(),
            output_buffer_registry: deps.output_buffer_registry.clone(),
            all_tool_names: tool_names.clone(),
        };
        handle.register_function_for_setup(
            definition,
            Some(std::sync::Arc::new(handler)),
            false,
        )?;
    }
    Ok(())
}

pub(crate) fn tool_function_id(tool_name: &str) -> EngineResult<FunctionId> {
    FunctionId::new(capability_runtime::canonical_tool_function_id(tool_name))
}

pub(crate) fn tool_function_definition(
    id: &FunctionId,
    tool: &dyn TronTool,
    all_tool_names: &[String],
    tool_order: usize,
) -> EngineResult<FunctionDefinition> {
    let tool_def = tool.definition();
    let local_tool_def = tool.local_definition();
    let (effect, risk, authority, approval_required) = classify_tool_capability(tool.name());
    let mut authority = AuthorityRequirement::scope(authority);
    if approval_required {
        authority = authority.with_approval_required();
    }
    let mut definition = FunctionDefinition::new(
        id.clone(),
        crate::server::domains::catalog::worker_id("tool")?,
        tool_def.description.clone(),
        VisibilityScope::System,
        effect,
    )
    .with_risk(risk)
    .with_required_authority(authority)
    .with_provenance(Provenance::system())
    .with_request_schema(normalize_engine_schema(
        serde_json::to_value(&tool_def.parameters).unwrap_or_else(|_| json!({"type": "object"})),
    ))
    .with_response_schema(json!({
        "type": "object",
        "additionalProperties": true
    }));
    if effect.is_mutating() {
        definition =
            definition.with_idempotency(IdempotencyContract::caller_session_engine_ledger());
    }
    definition.metadata = json!({
        "domainWorker": "tool",
        "canonicalCapability": id.as_str(),
        "modelToolName": tool.name(),
        "toolOrder": tool_order,
        "toolName": tool.name(),
        "toolCategory": format!("{:?}", tool.category()),
        "stopsTurn": tool.stops_turn(),
        "isInteractive": tool.is_interactive(),
        "toolStopsTurn": tool.stops_turn(),
        "toolInteractive": tool.is_interactive(),
        "toolSchema": tool_def,
        "localToolSchema": local_tool_def,
        "allToolNames": all_tool_names,
    });
    Ok(definition)
}

pub(crate) fn normalize_engine_schema(schema: Value) -> Value {
    let Some(object) = schema.as_object() else {
        return json!({"type": "object"});
    };
    let mut normalized = serde_json::Map::new();
    for key in [
        "type",
        "description",
        "required",
        "additionalProperties",
        "maxItems",
        "enum",
    ] {
        if let Some(value) = object.get(key) {
            let _ = normalized.insert(key.to_owned(), value.clone());
        }
    }
    if let Some(properties) = object.get("properties").and_then(Value::as_object) {
        let props = properties
            .iter()
            .map(|(key, value)| (key.clone(), normalize_engine_schema(value.clone())))
            .collect();
        let _ = normalized.insert("properties".to_owned(), Value::Object(props));
    }
    if let Some(items) = object.get("items") {
        let _ = normalized.insert("items".to_owned(), normalize_engine_schema(items.clone()));
    }
    if !normalized.contains_key("type") {
        let _ = normalized.insert("type".to_owned(), Value::String("object".to_owned()));
    }
    Value::Object(normalized)
}

pub(crate) fn classify_tool_capability(
    tool_name: &str,
) -> (EffectClass, RiskLevel, &'static str, bool) {
    match tool_name {
        "Read" | "Search" | "Find" | "engine_discover" | "engine_inspect" | "engine_watch" => {
            (EffectClass::PureRead, RiskLevel::Low, "tool.read", false)
        }
        "WebFetch" | "WebSearch" => (
            EffectClass::ExternalSideEffect,
            RiskLevel::Medium,
            "tool.invoke",
            true,
        ),
        "Write" | "Edit" => (
            EffectClass::ReversibleSideEffect,
            RiskLevel::High,
            "tool.write",
            true,
        ),
        "engine_invoke" => (
            EffectClass::DelegatedInvocation,
            RiskLevel::High,
            "tool.invoke",
            true,
        ),
        _ => (
            EffectClass::ExternalSideEffect,
            RiskLevel::Medium,
            "tool.invoke",
            true,
        ),
    }
}
