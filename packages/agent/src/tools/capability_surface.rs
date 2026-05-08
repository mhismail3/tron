//! Live engine-catalog projection for provider tool schemas.
//!
//! The provider-facing tool list is now resolved from the live engine catalog
//! at each model-call boundary. Tool contracts, policy metadata, and execution
//! targets all come from canonical engine functions.

use std::collections::{BTreeMap, BTreeSet, HashSet};

use serde_json::Value;

use crate::core::messages::Provider;
use crate::core::tools::{Tool, ToolParameterSchema};
use crate::engine::{
    ActorContext, ActorId, ActorKind, AuthorityGrantId, EngineHostHandle, FunctionDefinition,
    FunctionHealth, FunctionId, FunctionQuery,
};
use crate::runtime::context::local_policy::ContextPolicy;
use crate::tools::traits::ExecutionMode;

const TOOL_SURFACE_GRANT: &str = "agent-tool-surface";

/// One live model-facing capability resolved from the engine catalog.
#[derive(Clone, Debug)]
pub struct EngineToolTarget {
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
    /// How this tool is scheduled relative to other tool calls in the same turn.
    pub execution_mode: ExecutionMode,
}

/// Profile/session policy applied to the live tool catalog before a provider
/// request is sent and again at the execution boundary.
#[derive(Clone, Debug, Default)]
pub struct ToolSurfacePolicy {
    pub allowed_tools: Option<BTreeSet<String>>,
    pub denied_tools: BTreeSet<String>,
    pub expose_interactive_tools: bool,
    pub remove_spawn_tools_at_max_depth: bool,
    pub is_unattended: bool,
    pub subagent_max_depth: u32,
}

impl ToolSurfacePolicy {
    pub(crate) fn from_profile(
        policy: &crate::core::profile::ToolPolicySpec,
        explicit_denied: &[String],
        is_unattended: bool,
        subagent_max_depth: u32,
    ) -> Self {
        let mut denied_tools = policy.denied_tools.iter().cloned().collect::<BTreeSet<_>>();
        denied_tools.extend(explicit_denied.iter().cloned());
        Self {
            allowed_tools: policy
                .allowed_tools
                .as_ref()
                .map(|tools| tools.iter().cloned().collect()),
            denied_tools,
            expose_interactive_tools: policy.expose_interactive_tools.unwrap_or(false),
            remove_spawn_tools_at_max_depth: policy.remove_spawn_tools_at_max_depth.unwrap_or(true),
            is_unattended,
            subagent_max_depth,
        }
    }

    fn allows(&self, target: &EngineToolTarget) -> bool {
        if let Some(allowed) = &self.allowed_tools
            && !allowed.contains(&target.model_tool_name)
        {
            return false;
        }
        if self.denied_tools.contains(&target.model_tool_name) {
            return false;
        }
        if self.is_unattended && target.is_interactive && !self.expose_interactive_tools {
            return false;
        }
        if self.is_unattended
            && self.remove_spawn_tools_at_max_depth
            && self.subagent_max_depth == 0
            && matches!(target.model_tool_name.as_str(), "SpawnSubagent" | "Wait")
        {
            return false;
        }
        true
    }
}

/// Tool surface resolved once for a provider request.
#[derive(Clone, Debug)]
pub struct ResolvedToolSurface {
    pub tools: Vec<Tool>,
    pub targets_by_name: BTreeMap<String, EngineToolTarget>,
    pub all_tool_names: Vec<String>,
    pub turn_stopping_tools: HashSet<String>,
}

/// Resolve model-facing tool schemas from the live engine catalog.
pub(crate) async fn resolve_provider_tools(
    host: &EngineHostHandle,
    session_id: &str,
    workspace_id: Option<&str>,
    provider: Provider,
    context_policy: &ContextPolicy,
    tool_policy: &ToolSurfacePolicy,
) -> Result<ResolvedToolSurface, String> {
    let targets = resolve_tool_targets(host, session_id, workspace_id).await?;
    let local_filter = context_policy.tool_filter();
    let mut tools = Vec::new();
    let mut targets_by_name = BTreeMap::new();
    let mut all_tool_names = Vec::new();
    let mut turn_stopping_tools = HashSet::new();
    for target in targets {
        if !tool_policy.allows(&target) {
            continue;
        }
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
        all_tool_names.push(target.model_tool_name.clone());
        if target.stops_turn {
            let _ = turn_stopping_tools.insert(target.model_tool_name.clone());
        }
        let _ = targets_by_name.insert(target.model_tool_name.clone(), target);
        tools.push(tool);
    }
    tracing::debug!(
        provider = provider.as_str(),
        local = context_policy.is_local(),
        tool_count = tools.len(),
        "resolved provider tool surface from engine catalog"
    );
    Ok(ResolvedToolSurface {
        tools,
        targets_by_name,
        all_tool_names,
        turn_stopping_tools,
    })
}

/// Resolve the canonical engine function for a model tool call.
/// List model-facing tool names visible to an agent actor before profile
/// policy filtering. Used for skill deny-list expansion.
pub(crate) async fn list_model_tool_names(
    host: &EngineHostHandle,
    session_id: &str,
    workspace_id: Option<&str>,
) -> Result<Vec<String>, String> {
    Ok(resolve_tool_targets(host, session_id, workspace_id)
        .await?
        .into_iter()
        .map(|target| target.model_tool_name)
        .collect())
}

/// List model-facing tool schemas visible to an agent actor before profile
/// policy filtering. Context read models use this to mirror the current live
/// catalog without owning a separate tool list.
pub(crate) async fn list_model_tools(
    host: &EngineHostHandle,
    session_id: &str,
    workspace_id: Option<&str>,
) -> Result<Vec<Tool>, String> {
    Ok(resolve_tool_targets(host, session_id, workspace_id)
        .await?
        .into_iter()
        .map(|target| model_tool_schema(&target))
        .collect())
}

async fn resolve_tool_targets(
    host: &EngineHostHandle,
    session_id: &str,
    workspace_id: Option<&str>,
) -> Result<Vec<EngineToolTarget>, String> {
    let actor = tool_surface_actor(session_id, workspace_id)?;
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
            execution_mode: execution_mode(&function),
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

fn execution_mode(function: &FunctionDefinition) -> ExecutionMode {
    let Some(mode) = function
        .metadata
        .get("toolExecutionMode")
        .and_then(Value::as_object)
    else {
        return ExecutionMode::Parallel;
    };
    match mode.get("kind").and_then(Value::as_str) {
        Some("serialized") => ExecutionMode::Serialized(
            mode.get("group")
                .and_then(Value::as_str)
                .unwrap_or("default")
                .to_owned(),
        ),
        _ => ExecutionMode::Parallel,
    }
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
