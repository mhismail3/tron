//! Agent-facing live engine capability tools.
//!
//! These tools are the first stable LLM surface over the canonical capability
//! fabric. They intentionally expose live engine ids (`settings::get`,
//! `events::append`, `stream::poll`) instead of JSON-RPC compatibility ids.

use async_trait::async_trait;
use serde_json::{Value, json};

use crate::core::tools::{Tool, ToolCategory, ToolResultBody, TronToolResult, error_result};
use crate::engine::{
    ActorId, AgentCapabilityClient, AuthorityGrantId, CatalogChangeClass, CatalogChangeKind,
    CatalogRevision, EngineHostHandle, EngineWatchRequest, FunctionId, FunctionQuery, InvocationId,
};
use crate::tools::errors::ToolError;
use crate::tools::traits::{ToolContext, TronTool};
use crate::tools::utils::schema::ToolSchemaBuilder;

const ENGINE_TOOL_GRANT: &str = "agent-engine-tools";

/// Discover live canonical engine capabilities visible to this agent.
pub struct EngineDiscoverTool {
    host: EngineHostHandle,
}

impl EngineDiscoverTool {
    /// Create the tool.
    #[must_use]
    pub fn new(host: EngineHostHandle) -> Self {
        Self { host }
    }
}

/// Inspect one live canonical engine function.
pub struct EngineInspectTool {
    host: EngineHostHandle,
}

impl EngineInspectTool {
    /// Create the tool.
    #[must_use]
    pub fn new(host: EngineHostHandle) -> Self {
        Self { host }
    }
}

/// Pull visible live catalog changes from an engine catalog cursor.
pub struct EngineWatchTool {
    host: EngineHostHandle,
}

impl EngineWatchTool {
    /// Create the tool.
    #[must_use]
    pub fn new(host: EngineHostHandle) -> Self {
        Self { host }
    }
}

/// Invoke one canonical engine function.
pub struct EngineInvokeTool {
    host: EngineHostHandle,
}

impl EngineInvokeTool {
    /// Create the tool.
    #[must_use]
    pub fn new(host: EngineHostHandle) -> Self {
        Self { host }
    }
}

#[async_trait]
impl TronTool for EngineDiscoverTool {
    fn name(&self) -> &str {
        "engine_discover"
    }

    fn category(&self) -> ToolCategory {
        ToolCategory::Custom
    }

    fn definition(&self) -> Tool {
        ToolSchemaBuilder::new(
            self.name(),
            "Search the live canonical engine capability catalog visible to this agent.",
        )
        .property(
            "query",
            json!({"type": "string", "description": "Optional substring to match against function ids or descriptions"}),
        )
        .property(
            "namespace",
            json!({"type": "string", "description": "Optional canonical namespace such as settings, events, stream, state, or queue"}),
        )
        .build()
    }

    async fn execute(&self, params: Value, ctx: &ToolContext) -> Result<TronToolResult, ToolError> {
        let mut query = FunctionQuery::default();
        if let Some(search) = optional_string(&params, "query") {
            query.text = Some(search);
        }
        if let Some(namespace) = optional_string(&params, "namespace") {
            query.namespace_prefix = Some(namespace);
        }
        let client = agent_client(&self.host, ctx)?;
        let functions = client.discover(query).await;
        Ok(json_result(
            format!("Found {} visible engine capabilities.", functions.len()),
            json!({ "functions": functions }),
        ))
    }
}

#[async_trait]
impl TronTool for EngineInspectTool {
    fn name(&self) -> &str {
        "engine_inspect"
    }

    fn category(&self) -> ToolCategory {
        ToolCategory::Custom
    }

    fn definition(&self) -> Tool {
        ToolSchemaBuilder::new(
            self.name(),
            "Inspect the live contract, authority, effect, risk, schema, health, and provenance of one canonical engine function.",
        )
        .required_property(
            "functionId",
            json!({"type": "string", "description": "Canonical function id, for example settings::get or stream::poll"}),
        )
        .build()
    }

    async fn execute(&self, params: Value, ctx: &ToolContext) -> Result<TronToolResult, ToolError> {
        let function_id = required_function_id(&params)?;
        let client = agent_client(&self.host, ctx)?;
        match client.inspect(&function_id).await {
            Ok(function) => Ok(json_result(
                format!("Inspected engine capability {function_id}."),
                json!({ "function": function }),
            )),
            Err(error) => Ok(error_result(error.to_string())),
        }
    }
}

#[async_trait]
impl TronTool for EngineWatchTool {
    fn name(&self) -> &str {
        "engine_watch"
    }

    fn category(&self) -> ToolCategory {
        ToolCategory::Custom
    }

    fn definition(&self) -> Tool {
        ToolSchemaBuilder::new(
            self.name(),
            "Poll live catalog changes visible to this agent after a catalog revision cursor.",
        )
        .property(
            "afterRevision",
            json!({"type": "integer", "description": "Catalog revision cursor to poll after", "minimum": 0}),
        )
        .property(
            "limit",
            json!({"type": "integer", "description": "Maximum changes to return, capped by the engine", "minimum": 1, "maximum": 500}),
        )
        .property(
            "classes",
            json!({"type": "array", "items": {"type": "string"}, "description": "Optional classes: availability, contract, trigger, visibility, health"}),
        )
        .property(
            "kinds",
            json!({"type": "array", "items": {"type": "string"}, "description": "Optional change kinds such as FunctionRegistered or VisibilityChanged"}),
        )
        .property(
            "subjectPrefix",
            json!({"type": "string", "description": "Optional subject id prefix filter"}),
        )
        .build()
    }

    async fn execute(&self, params: Value, ctx: &ToolContext) -> Result<TronToolResult, ToolError> {
        let request = watch_request_from_params(&params)?;
        let client = agent_client(&self.host, ctx)?;
        match client.watch(request).await {
            Ok(page) => Ok(json_result(
                format!("Returned {} live catalog change(s).", page.changes.len()),
                json!({
                    "changes": page.changes,
                    "currentRevision": page.current_revision.0,
                    "nextRevision": page.next_revision.0,
                    "hasMore": page.has_more,
                }),
            )),
            Err(error) => Ok(error_result(error.to_string())),
        }
    }
}

#[async_trait]
impl TronTool for EngineInvokeTool {
    fn name(&self) -> &str {
        "engine_invoke"
    }

    fn category(&self) -> ToolCategory {
        ToolCategory::Custom
    }

    fn definition(&self) -> Tool {
        ToolSchemaBuilder::new(
            self.name(),
            "Invoke a canonical engine function. Mutating functions require an explicit idempotency key.",
        )
        .required_property(
            "functionId",
            json!({"type": "string", "description": "Canonical function id, never an rpc::* compatibility id"}),
        )
        .property(
            "payload",
            json!({"type": "object", "description": "JSON payload for the target function"}),
        )
        .property(
            "idempotencyKey",
            json!({"type": "string", "description": "Required for mutating capabilities; stable across exact retries"}),
        )
        .property(
            "parentInvocationId",
            json!({"type": "string", "description": "Optional parent engine invocation id for causal linking"}),
        )
        .build()
    }

    async fn execute(&self, params: Value, ctx: &ToolContext) -> Result<TronToolResult, ToolError> {
        let function_id = required_function_id(&params)?;
        let payload = params.get("payload").cloned().unwrap_or_else(|| json!({}));
        let idempotency_key = optional_string(&params, "idempotencyKey");
        let parent_invocation_id = optional_string(&params, "parentInvocationId")
            .map(InvocationId::new)
            .transpose()
            .map_err(tool_validation)?;

        let client = agent_client(&self.host, ctx)?;
        let function = match client.inspect(&function_id).await {
            Ok(function) => function,
            Err(error) => return Ok(error_result(error.to_string())),
        };
        if function.effect_class.is_mutating() && idempotency_key.is_none() {
            return Ok(error_result(format!(
                "{function_id} is {:?}; provide idempotencyKey for agent writes",
                function.effect_class
            )));
        }
        let result = client
            .invoke(
                function_id.clone(),
                payload,
                idempotency_key,
                parent_invocation_id,
            )
            .await;
        if let Some(error) = result.error {
            return Ok(json_error_result(
                error.to_string(),
                json!({
                    "invocationId": result.invocation_id,
                    "functionId": function_id,
                }),
            ));
        }
        Ok(json_result(
            format!("Invoked engine capability {function_id}."),
            json!({
                "invocationId": result.invocation_id,
                "functionId": function_id,
                "replayedFrom": result.replayed_from,
                "result": result.value.unwrap_or(Value::Null),
            }),
        ))
    }
}

fn agent_client(
    host: &EngineHostHandle,
    ctx: &ToolContext,
) -> Result<AgentCapabilityClient, ToolError> {
    let actor_id = ActorId::new(format!("agent:{}", ctx.session_id)).map_err(tool_validation)?;
    let grant_id = AuthorityGrantId::new(ENGINE_TOOL_GRANT).map_err(tool_validation)?;
    let mut client = AgentCapabilityClient::new(host.clone(), actor_id, grant_id)
        .with_scopes(agent_authority_scopes())
        .with_session_id(ctx.session_id.clone());
    if let Some(workspace_id) = ctx.workspace_id.clone() {
        client = client.with_workspace_id(workspace_id);
    }
    Ok(client)
}

fn agent_authority_scopes() -> [&'static str; 35] {
    [
        "engine.discover",
        "engine.inspect",
        "engine.watch",
        "engine.invoke",
        "system.read",
        "model.read",
        "settings.read",
        "settings.write",
        "logs.read",
        "logs.write",
        "prompt_library.read",
        "prompt_library.write",
        "skills.read",
        "skills.write",
        "filesystem.read",
        "filesystem.write",
        "events.read",
        "events.write",
        "session.read",
        "session.write",
        "context.read",
        "context.write",
        "job.read",
        "job.write",
        "notifications.read",
        "notifications.write",
        "plan.read",
        "plan.write",
        "stream.read",
        "stream.write",
        "state.read",
        "state.write",
        "queue.read",
        "queue.write",
        "queue.admin",
    ]
}

fn required_function_id(params: &Value) -> Result<FunctionId, ToolError> {
    let Some(value) = optional_string(params, "functionId") else {
        return Err(tool_validation("Missing required parameter: functionId"));
    };
    FunctionId::new(value).map_err(tool_validation)
}

fn watch_request_from_params(params: &Value) -> Result<EngineWatchRequest, ToolError> {
    let after_revision = params
        .get("afterRevision")
        .and_then(Value::as_u64)
        .unwrap_or_default();
    let limit = params
        .get("limit")
        .and_then(Value::as_u64)
        .map_or(100, |value| usize::try_from(value).unwrap_or(usize::MAX));
    let classes = parse_array(params, "classes")?
        .map(|values| values.into_iter().map(parse_change_class).collect())
        .transpose()?;
    let kinds = parse_array(params, "kinds")?
        .map(|values| values.into_iter().map(parse_change_kind).collect())
        .transpose()?;
    Ok(EngineWatchRequest {
        after_revision: CatalogRevision(after_revision),
        limit,
        classes,
        kinds,
        subject_prefix: optional_string(params, "subjectPrefix"),
        owner_worker: None,
    })
}

fn optional_string(params: &Value, key: &str) -> Option<String> {
    params
        .get(key)
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(ToOwned::to_owned)
}

fn parse_array(params: &Value, key: &str) -> Result<Option<Vec<String>>, ToolError> {
    let Some(value) = params.get(key) else {
        return Ok(None);
    };
    let Some(items) = value.as_array() else {
        return Err(tool_validation(format!("{key} must be an array")));
    };
    let values = items
        .iter()
        .map(|item| {
            item.as_str()
                .map(ToOwned::to_owned)
                .ok_or_else(|| tool_validation(format!("{key} entries must be strings")))
        })
        .collect::<Result<Vec<_>, _>>()?;
    Ok(Some(values))
}

fn parse_change_class(value: String) -> Result<CatalogChangeClass, ToolError> {
    match value.trim().to_ascii_lowercase().as_str() {
        "availability" => Ok(CatalogChangeClass::Availability),
        "contract" => Ok(CatalogChangeClass::Contract),
        "trigger" => Ok(CatalogChangeClass::Trigger),
        "visibility" => Ok(CatalogChangeClass::Visibility),
        "health" => Ok(CatalogChangeClass::Health),
        _ => Err(tool_validation(format!(
            "unknown catalog change class: {value}"
        ))),
    }
}

fn parse_change_kind(value: String) -> Result<CatalogChangeKind, ToolError> {
    match value.trim() {
        "WorkerRegistered" => Ok(CatalogChangeKind::WorkerRegistered),
        "WorkerUpdated" => Ok(CatalogChangeKind::WorkerUpdated),
        "WorkerUnregistered" => Ok(CatalogChangeKind::WorkerUnregistered),
        "FunctionRegistered" => Ok(CatalogChangeKind::FunctionRegistered),
        "FunctionUpdated" => Ok(CatalogChangeKind::FunctionUpdated),
        "FunctionUnregistered" => Ok(CatalogChangeKind::FunctionUnregistered),
        "TriggerTypeRegistered" => Ok(CatalogChangeKind::TriggerTypeRegistered),
        "TriggerTypeUpdated" => Ok(CatalogChangeKind::TriggerTypeUpdated),
        "TriggerTypeUnregistered" => Ok(CatalogChangeKind::TriggerTypeUnregistered),
        "TriggerRegistered" => Ok(CatalogChangeKind::TriggerRegistered),
        "TriggerUpdated" => Ok(CatalogChangeKind::TriggerUpdated),
        "TriggerUnregistered" => Ok(CatalogChangeKind::TriggerUnregistered),
        "VisibilityChanged" => Ok(CatalogChangeKind::VisibilityChanged),
        _ => Err(tool_validation(format!(
            "unknown catalog change kind: {value}"
        ))),
    }
}

fn json_result(message: String, details: Value) -> TronToolResult {
    TronToolResult {
        content: ToolResultBody::Blocks(vec![crate::core::content::ToolResultContent::text(
            message,
        )]),
        details: Some(details),
        is_error: None,
        stop_turn: None,
    }
}

fn json_error_result(message: String, details: Value) -> TronToolResult {
    TronToolResult {
        content: ToolResultBody::Blocks(vec![crate::core::content::ToolResultContent::text(
            message,
        )]),
        details: Some(details),
        is_error: Some(true),
        stop_turn: None,
    }
}

fn tool_validation(message: impl std::fmt::Display) -> ToolError {
    ToolError::Validation {
        message: message.to_string(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::engine::{
        AuthorityRequirement, EffectClass, FunctionDefinition, InProcessFunctionHandler,
        Invocation, Provenance, VisibilityScope, WorkerDefinition, WorkerId, WorkerKind,
    };
    use crate::tools::testutil::{extract_text, make_ctx};

    #[derive(Clone)]
    struct Echo;

    #[async_trait]
    impl InProcessFunctionHandler for Echo {
        async fn invoke(&self, invocation: Invocation) -> crate::engine::Result<Value> {
            Ok(json!({ "payload": invocation.payload }))
        }
    }

    fn worker_id(value: &str) -> WorkerId {
        WorkerId::new(value).unwrap()
    }

    async fn host_with_capability(effect: EffectClass) -> EngineHostHandle {
        let host = EngineHostHandle::new_in_memory().unwrap();
        host.register_worker_for_setup(
            WorkerDefinition::new(
                worker_id("alpha"),
                WorkerKind::InProcess,
                ActorId::new("owner").unwrap(),
                AuthorityGrantId::new("grant").unwrap(),
            )
            .with_namespace_claim("alpha"),
            false,
        )
        .unwrap();
        let mut function = FunctionDefinition::new(
            FunctionId::new("alpha::echo").unwrap(),
            worker_id("alpha"),
            "test capability",
            VisibilityScope::Agent,
            effect,
        )
        .with_required_authority(AuthorityRequirement::scope(if effect.is_mutating() {
            "state.write"
        } else {
            "state.read"
        }))
        .with_provenance(Provenance::system());
        if effect.is_mutating() {
            function =
                function.with_idempotency(crate::engine::IdempotencyContract::caller_session());
        }
        host.register_function_for_setup(function, Some(std::sync::Arc::new(Echo)), false)
            .unwrap();
        host
    }

    #[tokio::test]
    async fn discover_filters_rpc_compatibility_namespace() {
        let host = host_with_capability(EffectClass::PureRead).await;
        let tool = EngineDiscoverTool::new(host);
        let result = tool.execute(json!({}), &make_ctx()).await.unwrap();
        assert!(!extract_text(&result).contains("rpc::"));
        let functions = result.details.unwrap()["functions"]
            .as_array()
            .unwrap()
            .clone();
        assert!(
            functions
                .iter()
                .any(|function| function["id"] == "alpha::echo")
        );
    }

    #[tokio::test]
    async fn invoke_read_capability_succeeds_without_idempotency() {
        let host = host_with_capability(EffectClass::PureRead).await;
        let tool = EngineInvokeTool::new(host);
        let result = tool
            .execute(
                json!({"functionId": "alpha::echo", "payload": {"ok": true}}),
                &make_ctx(),
            )
            .await
            .unwrap();
        assert!(result.is_error.is_none());
        assert_eq!(
            result.details.unwrap()["result"]["payload"],
            json!({"ok": true})
        );
    }

    #[tokio::test]
    async fn invoke_mutating_capability_requires_explicit_idempotency() {
        let host = host_with_capability(EffectClass::IdempotentWrite).await;
        let tool = EngineInvokeTool::new(host);
        let result = tool
            .execute(
                json!({"functionId": "alpha::echo", "payload": {"ok": true}}),
                &make_ctx(),
            )
            .await
            .unwrap();
        assert_eq!(result.is_error, Some(true));
        assert!(extract_text(&result).contains("idempotencyKey"));
    }

    #[tokio::test]
    async fn watch_returns_catalog_changes() {
        let host = host_with_capability(EffectClass::PureRead).await;
        let tool = EngineWatchTool::new(host);
        let result = tool
            .execute(json!({"afterRevision": 0}), &make_ctx())
            .await
            .unwrap();
        assert!(result.is_error.is_none());
        assert!(
            result.details.unwrap()["changes"]
                .as_array()
                .unwrap()
                .iter()
                .any(|change| change["subject_id"] == "alpha::echo")
        );
    }
}
