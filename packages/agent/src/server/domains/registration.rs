//! Domain worker registration.
//!
//! This module registers canonical in-process domain workers, their functions,
//! hidden apply functions, tool functions, and trigger definitions. Transport
//! startup calls this module once; individual domain workers own the executable
//! behavior and metadata.
//!
//! Domain workers such as `skills`, `filesystem`, `events`, `notifications`, `plan`, `settings`,
//! `logs`, `prompt_library`, `model`, `session`, `context`, `job`, `agent`,
//! `git`, `worktree`, `auth`, `device`, `voice_notes`, `transcription`,
//! `browser`, `display`, `sandbox`, `mcp`, and `system` own executable
//! function contracts and behavior metadata. A separate `tool` worker registers
//! built-in agent tools as
//! canonical `tool::*` functions. Provider requests now resolve schemas from
//! the live catalog, so built-ins, engine meta-tools, and eligible MCP
//! capabilities are all surfaced through the same agent-facing capability
//! fabric instead of through a frozen `ToolRegistry` snapshot.
//! `engine_ws` trigger records capture public engine protocol messages.
//! `cron_schedule` trigger records capture scheduled automation fires.
//!
//! # INVARIANT: canonical capabilities are the executable surface
//!
//! Domain method names are internal operation keys for service routing only.
//! Only canonical function ids are registered.

use async_trait::async_trait;
use serde_json::{Value, json};

use crate::engine::{
    AuthorityRequirement, CompensationContract, CompensationKind, EffectClass, EngineError,
    EngineHostHandle, FunctionDefinition, FunctionId, IdempotencyContract,
    InProcessFunctionHandler, Invocation, Provenance, Result as EngineResult, RiskLevel,
    VisibilityScope, WorkerDefinition, WorkerKind,
};
use crate::server::shared::context::ServerCapabilityContext;
use crate::tools::capability_runtime;
use crate::tools::traits::{ToolContext, TronTool};

use crate::server::domains::catalog;

pub(crate) use crate::server::domains::catalog::{SYSTEM_AUTHORITY_GRANT, SYSTEM_OWNER_ACTOR};

/// Register server-owned domain workers, canonical functions, and trigger records.
pub fn register_domain_workers_for_context(ctx: &ServerCapabilityContext) -> EngineResult<()> {
    register_domain_workers(
        &ctx.engine_host,
        crate::server::domains::EngineCapabilityDeps::from_context(ctx),
    )?;
    register_tool_worker_for_context(ctx)?;
    Ok(())
}

fn register_domain_workers(
    handle: &EngineHostHandle,
    deps: crate::server::domains::EngineCapabilityDeps,
) -> EngineResult<()> {
    let canonical_specs = catalog::canonical_capability_specs()?;
    let public_transport_specs = catalog::public_engine_transport_specs()?;
    for module in catalog::domain_worker_modules()? {
        handle.register_worker_for_setup(module.worker, false)?;
    }
    handle.register_trigger_type_for_setup(catalog::engine_ws_trigger_type()?, false)?;
    handle.register_trigger_type_for_setup(catalog::manual_trigger_type()?, false)?;
    handle.register_trigger_type_for_setup(catalog::cron_schedule_trigger_type()?, false)?;
    for spec in &canonical_specs {
        if matches!(
            spec.function_id.as_str(),
            "engine::discover"
                | "engine::inspect"
                | "engine::watch"
                | "engine::invoke"
                | "engine::promote"
                | "approval::get"
                | "approval::list"
                | "approval::resolve"
        ) {
            continue;
        }
        let handler = Some({
            std::sync::Arc::new(crate::server::domains::CanonicalFunctionHandler {
                method: spec.method,
                deps: deps.clone(),
                handler: crate::server::domains::handler_for_method(spec.method)
                    .map_err(crate::server::shared::error_mapping::capability_error_to_engine)?,
            }) as std::sync::Arc<dyn crate::engine::InProcessFunctionHandler>
        });
        handle.register_function_for_setup(
            catalog::function_definition_for_capability(&catalog::capability_spec_for_method(
                spec.method,
            )?),
            handler,
            false,
        )?;
    }
    register_hidden_job_apply_functions(handle, &deps)?;
    register_hidden_agent_prompt_functions(handle, &deps)?;
    register_hidden_cron_schedule_function(handle, &deps)?;
    for spec in &public_transport_specs {
        if let Some(trigger) = catalog::engine_ws_trigger_for_spec(spec)? {
            handle.register_trigger_for_setup(trigger, false)?;
        }
    }
    crate::server::domains::cron::project_all_cron_triggers_for_setup(handle, &deps)?;
    Ok(())
}

fn register_tool_worker_for_context(ctx: &ServerCapabilityContext) -> EngineResult<()> {
    let handle = &ctx.engine_host;
    let Some(agent_deps) = ctx.agent_deps.as_ref() else {
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
            process_manager: ctx.process_manager.clone(),
            job_manager: ctx.job_manager.clone(),
            output_buffer_registry: ctx.output_buffer_registry.clone(),
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

fn tool_function_id(tool_name: &str) -> EngineResult<FunctionId> {
    FunctionId::new(capability_runtime::canonical_tool_function_id(tool_name))
}

fn tool_function_definition(
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

fn register_hidden_agent_prompt_functions(
    handle: &EngineHostHandle,
    deps: &crate::server::domains::EngineCapabilityDeps,
) -> EngineResult<()> {
    for (id, method, description, request_schema, response_schema) in [
        (
            "agent::prompt_apply",
            "agent::prompt_apply",
            "apply a queued agent prompt command",
            agent_prompt_apply_request_schema(),
            agent_prompt_response_schema(),
        ),
        (
            "agent::run_turn",
            "agent::run_turn",
            "start one accepted agent turn behind the engine runtime boundary",
            agent_prompt_apply_request_schema(),
            agent_prompt_response_schema(),
        ),
        (
            "agent::prompt_queue_drain",
            "agent::prompt_queue_drain",
            "drain the next queued prompt after a run completes",
            agent_prompt_queue_drain_request_schema(),
            agent_prompt_queue_drain_response_schema(),
        ),
    ] {
        let mut definition = FunctionDefinition::new(
            FunctionId::new(id)?,
            catalog::worker_id("agent")?,
            description,
            VisibilityScope::Internal,
            EffectClass::ExternalSideEffect,
        )
        .with_risk(RiskLevel::High)
        .with_required_authority(AuthorityRequirement::scope("agent.write"))
        .with_idempotency(IdempotencyContract::caller_session_engine_ledger())
        .with_compensation(CompensationContract::new(
            CompensationKind::ExternalIrreversible,
            "hidden prompt apply functions start or drain live agent runtime work; rollback is manual and event-store history remains authoritative",
        ))
        .with_provenance(Provenance::system())
        .with_request_schema(request_schema)
        .with_response_schema(response_schema);
        definition.metadata = serde_json::json!({
            "internal": true,
            "canonicalCapability": id,
            "hiddenPromptRuntimeFunction": true,
        });
        handle.register_function_for_setup(
            definition,
            Some(std::sync::Arc::new(
                crate::server::domains::CanonicalFunctionHandler {
                    method,
                    deps: deps.clone(),
                    handler: crate::server::domains::handler_for_method(method).map_err(
                        crate::server::shared::error_mapping::capability_error_to_engine,
                    )?,
                },
            )),
            false,
        )?;
    }
    Ok(())
}

fn agent_prompt_apply_request_schema() -> Value {
    json!({
        "type": "object",
        "required": ["runId", "sessionId", "prompt"],
        "additionalProperties": false,
        "properties": {
            "runId": {"type": "string"},
            "sessionId": {"type": "string"},
            "prompt": {"type": "string"},
            "reasoningLevel": {"type": "string"},
            "images": {"type": "array", "items": {"type": "object", "additionalProperties": true}},
            "attachments": {"type": "array", "items": {"type": "object", "additionalProperties": true}},
            "source": {"type": "string"},
            "workspaceId": {"type": "string"}
        }
    })
}

fn agent_prompt_response_schema() -> Value {
    json!({
        "type": "object",
        "required": ["acknowledged", "runId"],
        "additionalProperties": false,
        "properties": {
            "acknowledged": {"type": "boolean"},
            "runId": {"type": "string"}
        }
    })
}

fn agent_prompt_queue_drain_request_schema() -> Value {
    json!({
        "type": "object",
        "required": ["sessionId", "completedRunId"],
        "additionalProperties": false,
        "properties": {
            "sessionId": {"type": "string"},
            "completedRunId": {"type": "string"},
            "workspaceId": {"type": "string"}
        }
    })
}

fn agent_prompt_queue_drain_response_schema() -> Value {
    json!({
        "type": "object",
        "required": ["drained", "count"],
        "additionalProperties": false,
        "properties": {
            "drained": {"type": "boolean"},
            "count": {"type": "integer"},
            "runId": {"type": ["string", "null"]},
            "reason": {"type": ["string", "null"]}
        }
    })
}

fn register_hidden_job_apply_functions(
    handle: &EngineHostHandle,
    deps: &crate::server::domains::EngineCapabilityDeps,
) -> EngineResult<()> {
    for (id, method, public_method, description) in [
        (
            "job::background_apply",
            "job::background_apply",
            "job::background",
            "apply a queued background-job command",
        ),
        (
            "job::cancel_apply",
            "job::cancel_apply",
            "job::cancel",
            "apply a queued job-cancel command",
        ),
    ] {
        let mut definition = FunctionDefinition::new(
            FunctionId::new(id)?,
            catalog::worker_id("job")?,
            description,
            VisibilityScope::Internal,
            EffectClass::ReversibleSideEffect,
        )
        .with_risk(RiskLevel::High)
        .with_required_authority(AuthorityRequirement::scope("job.write"))
        .with_idempotency(IdempotencyContract::caller_system_engine_ledger())
        .with_compensation(CompensationContract::new(
            CompensationKind::ManualOnly,
            "hidden job apply functions delegate to the process manager; queue/idempotency records prevent duplicate starts or cancellations",
        ))
        .with_provenance(Provenance::system());
        if let Some(schema) =
            crate::server::domains::schemas::request_schema_for_method(public_method)
        {
            definition = definition.with_request_schema(schema);
        }
        if let Some(schema) =
            crate::server::domains::schemas::response_schema_for_method(public_method)
        {
            definition = definition.with_response_schema(schema);
        }
        definition.metadata = serde_json::json!({
            "internal": true,
            "canonicalCapability": id,
            "hiddenApplyFunction": true,
        });
        handle.register_function_for_setup(
            definition,
            Some(std::sync::Arc::new(
                crate::server::domains::CanonicalFunctionHandler {
                    method,
                    deps: deps.clone(),
                    handler: crate::server::domains::handler_for_method(method).map_err(
                        crate::server::shared::error_mapping::capability_error_to_engine,
                    )?,
                },
            )),
            false,
        )?;
    }
    Ok(())
}

fn register_hidden_cron_schedule_function(
    handle: &EngineHostHandle,
    deps: &crate::server::domains::EngineCapabilityDeps,
) -> EngineResult<()> {
    let mut definition = FunctionDefinition::new(
        FunctionId::new("cron::scheduled_fire")?,
        catalog::worker_id("cron")?,
        "apply one cron schedule fire through the engine trigger runtime",
        VisibilityScope::Internal,
        EffectClass::ExternalSideEffect,
    )
    .with_risk(RiskLevel::High)
    .with_required_authority(AuthorityRequirement::scope("cron.write"))
    .with_idempotency(IdempotencyContract::caller_system_engine_ledger())
    .with_compensation(CompensationContract::new(
        CompensationKind::ManualOnly,
        "cron scheduled fires execute existing cron payload boundaries and are audited through cron run history",
    ))
    .with_provenance(Provenance::system())
    .with_request_schema(json!({
        "type": "object",
        "required": ["jobId", "scheduledAt"],
        "additionalProperties": false,
        "properties": {
            "jobId": {"type": "string"},
            "scheduledAt": {"type": ["string", "integer"]}
        }
    }))
    .with_response_schema(json!({
        "type": "object",
        "required": ["started", "skipped", "jobId", "scheduledAt"],
        "additionalProperties": false,
        "properties": {
            "started": {"type": "boolean"},
            "skipped": {"type": "boolean"},
            "reason": {"type": "string"},
            "jobId": {"type": "string"},
            "scheduledAt": {"type": "string"},
            "nextRunAt": {"type": ["string", "null"]}
        }
    }));
    definition.metadata = serde_json::json!({
        "internal": true,
        "canonicalCapability": "cron::scheduled_fire",
        "hiddenCronScheduleFunction": true,
    });
    handle.register_function_for_setup(
        definition,
        Some(std::sync::Arc::new(
            crate::server::domains::CanonicalFunctionHandler {
                method: "cron::scheduled_fire",
                deps: deps.clone(),
                handler: crate::server::domains::handler_for_method("cron::scheduled_fire")
                    .map_err(crate::server::shared::error_mapping::capability_error_to_engine)?,
            },
        )),
        false,
    )?;
    Ok(())
}
