//! Live engine-catalog projection for provider tool schemas.
//!
//! The provider-facing tool list is now resolved from the live engine catalog
//! at each model-call boundary. `ToolRegistry` remains a temporary
//! implementation/policy backing for built-in tools, but it is no longer the
//! schema authority for production model requests.

use std::collections::BTreeSet;

use serde_json::Value;

use crate::core::messages::Provider;
use crate::core::tools::{Tool, ToolParameterSchema};
use crate::engine::{
    ActorContext, ActorId, ActorKind, AuthorityGrantId, EngineHostHandle, FunctionDefinition,
    FunctionHealth, FunctionId, FunctionQuery,
};
use crate::runtime::context::local_policy::ContextPolicy;
use crate::tools::registry::ToolRegistry;

const TOOL_SURFACE_GRANT: &str = "agent-tool-surface";

/// One live model-facing capability resolved from the engine catalog.
#[derive(Clone, Debug)]
pub(crate) struct EngineToolTarget {
    /// Model-facing tool name.
    pub model_tool_name: String,
    /// Canonical engine function id.
    pub function_id: FunctionId,
    /// Captured function definition.
    pub function: FunctionDefinition,
    /// Whether this tool stops the current agent turn.
    pub stops_turn: bool,
    /// Whether this tool is interactive.
    pub is_interactive: bool,
}

/// Resolve model-facing tool schemas from the live engine catalog.
pub(crate) async fn resolve_provider_tools(
    host: &EngineHostHandle,
    registry: &ToolRegistry,
    session_id: &str,
    workspace_id: Option<&str>,
    provider: Provider,
    context_policy: &ContextPolicy,
) -> Result<Vec<Tool>, String> {
    let targets = resolve_tool_targets(host, registry, session_id, workspace_id).await?;
    let local_filter = context_policy.tool_filter();
    let mut tools = Vec::new();
    for target in targets {
        if let Some(filter) = local_filter.as_ref()
            && !filter.iter().any(|name| name == &target.model_tool_name)
        {
            continue;
        }
        let tool = if context_policy.is_local() {
            local_tool_schema(&target.function).unwrap_or_else(|| model_tool_schema(&target))
        } else {
            model_tool_schema(&target)
        };
        tools.push(tool);
    }
    tracing::debug!(
        provider = provider.as_str(),
        local = context_policy.is_local(),
        tool_count = tools.len(),
        "resolved provider tool surface from engine catalog"
    );
    Ok(tools)
}

/// Resolve the canonical engine function for a model tool call.
pub(crate) async fn resolve_model_tool_target(
    host: &EngineHostHandle,
    registry: &ToolRegistry,
    session_id: &str,
    workspace_id: Option<&str>,
    model_tool_name: &str,
) -> Result<Option<EngineToolTarget>, String> {
    let targets = resolve_tool_targets(host, registry, session_id, workspace_id).await?;
    Ok(targets
        .into_iter()
        .find(|target| target.model_tool_name == model_tool_name))
}

async fn resolve_tool_targets(
    host: &EngineHostHandle,
    registry: &ToolRegistry,
    session_id: &str,
    workspace_id: Option<&str>,
) -> Result<Vec<EngineToolTarget>, String> {
    let actor = tool_surface_actor(session_id, workspace_id)?;
    let registry_names = registry.names().into_iter().collect::<BTreeSet<_>>();
    let allow_dynamic_mcp = registry_names.contains("McpCall");
    let mut functions = host
        .discover(&FunctionQuery {
            actor: Some(actor),
            health: Some(FunctionHealth::Healthy),
            ..FunctionQuery::default()
        })
        .await;
    functions.sort_by_key(|function| {
        (
            function
                .metadata
                .get("toolOrder")
                .and_then(Value::as_u64)
                .unwrap_or(u64::MAX),
            function.id.as_str().to_owned(),
        )
    });

    let mut seen_names = BTreeSet::new();
    let mut targets = Vec::new();
    for function in functions {
        if function.id.namespace() == "rpc" || function.visibility.as_str() == "internal" {
            continue;
        }
        if function.request_schema.is_none() {
            continue;
        }
        let Some(model_tool_name) = model_tool_name(&function) else {
            continue;
        };
        let is_dynamic_mcp = function
            .metadata
            .get("mcpTool")
            .and_then(Value::as_bool)
            .unwrap_or(false);
        if !registry_names.contains(&model_tool_name) && !(allow_dynamic_mcp && is_dynamic_mcp) {
            continue;
        }
        if !authority_is_available(&function) {
            continue;
        }
        if !seen_names.insert(model_tool_name.clone()) {
            tracing::warn!(
                model_tool_name,
                function_id = %function.id,
                "duplicate model tool name hidden from provider surface"
            );
            continue;
        }
        targets.push(EngineToolTarget {
            stops_turn: metadata_bool(&function, "stopsTurn").unwrap_or(false),
            is_interactive: metadata_bool(&function, "isInteractive").unwrap_or(false),
            model_tool_name,
            function_id: function.id.clone(),
            function,
        });
    }
    Ok(targets)
}

fn tool_surface_actor(
    session_id: &str,
    workspace_id: Option<&str>,
) -> Result<ActorContext, String> {
    let mut actor = ActorContext::new(
        ActorId::new(format!("agent:{session_id}")).map_err(|error| error.to_string())?,
        ActorKind::Agent,
        AuthorityGrantId::new(TOOL_SURFACE_GRANT).map_err(|error| error.to_string())?,
    )
    .with_scope("tool.read")
    .with_scope("tool.write")
    .with_scope("tool.invoke")
    .with_scope("mcp.read")
    .with_scope("mcp.write")
    .with_session_id(session_id.to_owned());
    if let Some(workspace_id) = workspace_id {
        actor = actor.with_workspace_id(workspace_id.to_owned());
    }
    Ok(actor)
}

fn authority_is_available(function: &FunctionDefinition) -> bool {
    function.required_authority.scopes.iter().all(|scope| {
        matches!(
            scope.as_str(),
            "tool.read" | "tool.write" | "tool.invoke" | "mcp.read" | "mcp.write"
        )
    })
}

fn model_tool_name(function: &FunctionDefinition) -> Option<String> {
    function
        .metadata
        .get("modelToolName")
        .and_then(Value::as_str)
        .map(ToOwned::to_owned)
}

fn metadata_bool(function: &FunctionDefinition, key: &str) -> Option<bool> {
    function.metadata.get(key).and_then(Value::as_bool)
}

fn model_tool_schema(target: &EngineToolTarget) -> Tool {
    if let Some(tool) = target
        .function
        .metadata
        .get("toolSchema")
        .and_then(|value| serde_json::from_value::<Tool>(value.clone()).ok())
    {
        return tool;
    }
    Tool {
        name: target.model_tool_name.clone(),
        description: target.function.description.clone(),
        parameters: parameter_schema_from_value(
            target
                .function
                .request_schema
                .clone()
                .unwrap_or_else(|| serde_json::json!({"type": "object"})),
        ),
    }
}

fn local_tool_schema(function: &FunctionDefinition) -> Option<Tool> {
    function
        .metadata
        .get("localToolSchema")
        .and_then(|value| serde_json::from_value::<Tool>(value.clone()).ok())
}

fn parameter_schema_from_value(value: Value) -> ToolParameterSchema {
    serde_json::from_value(value).unwrap_or_else(|_| ToolParameterSchema {
        schema_type: "object".to_owned(),
        properties: None,
        required: None,
        description: None,
        extra: serde_json::Map::new(),
    })
}
