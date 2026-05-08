//! Tool operation implementations.
//!
//! Built-in tool result delivery, built-in tool catalog registration, and tool
//! invocation handlers live here behind canonical `tool::*` functions.

use super::*;
use crate::engine::{
    AuthorityRequirement, EffectClass, EngineError, FunctionDefinition, FunctionId,
    IdempotencyContract, InProcessFunctionHandler, Provenance, Result as EngineResult, RiskLevel,
    WorkerDefinition, WorkerKind,
};
use crate::server::domains::catalog::{SYSTEM_AUTHORITY_GRANT, SYSTEM_OWNER_ACTOR};
use crate::server::shared::errors::{self, CapabilityError};
use crate::server::shared::params::{require_param, require_string_param};
use crate::tools::capability_runtime;
use crate::tools::traits::{ToolContext, TronTool};
use async_trait::async_trait;
use serde_json::{Value, json};

pub(super) async fn tool_result_value(
    payload: &Value,
    deps: &Deps,
) -> Result<Value, CapabilityError> {
    let _session_id = require_string_param(Some(payload), "sessionId")?;
    let tool_use_id = require_string_param(Some(payload), "toolUseId")?;
    let result = require_param(Some(payload), "result")?;

    if deps
        .orchestrator
        .resolve_tool_call(&tool_use_id, result.clone())
    {
        Ok(json!({
            "success": true,
            "toolCallId": tool_use_id,
        }))
    } else {
        Err(CapabilityError::NotFound {
            code: errors::NOT_FOUND.into(),
            message: format!("No pending tool call '{tool_use_id}'"),
        })
    }
}

pub(crate) fn register_builtin_tools_for_setup(deps: &DomainSetupContext) -> EngineResult<()> {
    let handle = &deps.engine_host;
    let Some(agent_deps) = deps.agent_deps.as_ref() else {
        return Ok(());
    };
    handle.register_worker_for_setup(
        WorkerDefinition::new(
            catalog::worker_id("tool")?,
            WorkerKind::InProcess,
            catalog::actor_id(SYSTEM_OWNER_ACTOR)?,
            catalog::grant_id(SYSTEM_AUTHORITY_GRANT)?,
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

pub(super) fn tool_function_id(tool_name: &str) -> EngineResult<FunctionId> {
    FunctionId::new(capability_runtime::canonical_tool_function_id(tool_name))
}

pub(super) fn tool_function_definition(
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
        catalog::worker_id("tool")?,
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

fn normalize_engine_schema(schema: Value) -> Value {
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

fn classify_tool_capability(tool_name: &str) -> (EffectClass, RiskLevel, &'static str, bool) {
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

struct ToolFunctionHandler {
    tool: std::sync::Arc<dyn TronTool>,
    process_manager: Option<std::sync::Arc<dyn crate::tools::traits::ProcessManagerOps>>,
    job_manager: Option<std::sync::Arc<dyn crate::tools::traits::JobManagerOps>>,
    output_buffer_registry:
        Option<std::sync::Arc<crate::runtime::orchestrator::output_buffer::OutputBufferRegistry>>,
    all_tool_names: Vec<String>,
}

#[async_trait]
impl InProcessFunctionHandler for ToolFunctionHandler {
    async fn invoke(&self, invocation: Invocation) -> Result<Value, EngineError> {
        let payload = invocation.payload;
        let runtime_id = payload
            .get("__runtimeToolInvocationId")
            .and_then(Value::as_str)
            .map(ToOwned::to_owned)
            .unwrap_or_else(|| invocation.id.to_string());
        if let Some(execution) = capability_runtime::take_runtime_tool_execution(&runtime_id) {
            if execution.tool_name != self.tool.name() {
                return Err(EngineError::DomainFailure {
                    domain: "tool".to_owned(),
                    code: "TOOL_RUNTIME_CONTEXT_MISMATCH".to_owned(),
                    message: "tool runtime context was prepared for a different tool".to_owned(),
                    details: Some(json!({
                        "expected": self.tool.name(),
                        "actual": execution.tool_name,
                        "runtimeInvocationId": runtime_id,
                    })),
                });
            }
            let result = execute_tool_with_runtime_context(
                self.tool.as_ref(),
                execution.params,
                &execution.context,
            )
            .await;
            return serde_json::to_value(result).map_err(|error| {
                EngineError::HandlerFailed(format!("failed to serialize tool result: {error}"))
            });
        }

        let params = payload
            .get("params")
            .cloned()
            .unwrap_or_else(|| payload.clone());
        let session_id = payload
            .get("sessionId")
            .and_then(Value::as_str)
            .or(invocation.causal_context.session_id.as_deref())
            .unwrap_or("engine-tool")
            .to_owned();
        let working_directory = payload
            .get("workingDirectory")
            .and_then(Value::as_str)
            .unwrap_or(".")
            .to_owned();
        let tool_call_id = payload
            .get("toolCallId")
            .and_then(Value::as_str)
            .map(ToOwned::to_owned)
            .unwrap_or_else(|| invocation.id.to_string());
        let tool_ctx = ToolContext {
            tool_call_id,
            session_id,
            working_directory,
            cancellation: tokio_util::sync::CancellationToken::new(),
            subagent_depth: 0,
            subagent_max_depth: 0,
            workspace_id: invocation.causal_context.workspace_id.clone(),
            output_tx: None,
            process_manager: self.process_manager.clone(),
            job_manager: self.job_manager.clone(),
            output_buffer_registry: self.output_buffer_registry.clone(),
            event_emitter: None,
            event_persister: None,
            turn: 0,
            all_tool_names: self.all_tool_names.clone(),
        };
        let result = execute_tool_with_runtime_context(self.tool.as_ref(), params, &tool_ctx).await;
        serde_json::to_value(result).map_err(|error| {
            EngineError::HandlerFailed(format!("failed to serialize tool result: {error}"))
        })
    }
}

async fn execute_tool_with_runtime_context(
    tool: &dyn TronTool,
    params: Value,
    tool_ctx: &ToolContext,
) -> crate::core::tools::TronToolResult {
    if tool_ctx.cancellation.is_cancelled() {
        return crate::core::tools::error_result("Operation cancelled");
    }
    tokio::select! {
        biased;
        () = tool_ctx.cancellation.cancelled() => {
            crate::core::tools::error_result("Operation cancelled")
        }
        result = tool.execute(params, tool_ctx) => {
            match result {
                Ok(result) => result,
                Err(error) => crate::core::tools::error_result(error.to_string()),
            }
        }
    }
}
