//! Agent-facing live engine capability tools.
//!
//! These tools are the first stable LLM surface over the canonical capability
//! fabric. They intentionally expose live engine ids (`settings::get`,
//! `events::append`, `stream::poll`) instead of transport method names.

use async_trait::async_trait;
use serde_json::{Value, json};

use crate::domains::tools::implementations::errors::ToolError;
use crate::domains::tools::implementations::traits::{ToolContext, TronTool};
use crate::domains::tools::implementations::utils::schema::ToolSchemaBuilder;
use crate::engine::{
    ActorId, AgentCapabilityClient, AuthorityGrantId, CatalogChangeClass, CatalogChangeKind,
    CatalogRevision, EngineHostHandle, EngineWatchRequest, FunctionDefinition, FunctionId,
    FunctionQuery, InvocationId,
};
use crate::shared::tools::{Tool, ToolCategory, ToolResultBody, TronToolResult, error_result};

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
            "Search the live canonical engine capability catalog visible to this agent. Use this before probing Tron internals with Bash, HTTP, or MCP.",
        )
        .property(
            "query",
            json!({"type": "string", "description": "Optional natural-language or canonical-id search. Terms such as 'sandbox spawn worker' match sandbox::spawn_worker."}),
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
            format_discover_result(&functions),
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
            "Inspect one canonical engine function and return model-readable schema, authority, idempotency, approval, lease, stream, and compensation metadata.",
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
                format_inspect_result(&function_id, &function),
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
            "Poll live catalog changes visible to this agent after a catalog revision cursor. Use this to notice newly connected or disconnected workers.",
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
            Ok(page) => {
                let change_preview = serde_json::to_value(&page.changes).unwrap_or(Value::Null);
                Ok(json_result(
                    format_watch_result(
                        page.changes.len(),
                        page.current_revision.0,
                        page.next_revision.0,
                        page.has_more,
                        &change_preview,
                    ),
                    json!({
                    "changes": page.changes,
                    "currentRevision": page.current_revision.0,
                    "nextRevision": page.next_revision.0,
                    "hasMore": page.has_more,
                    }),
                ))
            }
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
            "Invoke a canonical engine function through the engine policy/ledger path. Mutating functions require an explicit idempotency key and may pause for approval.",
        )
        .required_property(
            "functionId",
            json!({"type": "string", "description": "Canonical engine function id"}),
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
            let engine_details = match &error {
                crate::engine::EngineError::DomainFailure { details, .. } => details.clone(),
                _ => None,
            };
            let message = error.to_string();
            let approval_required = is_approval_required(engine_details.as_ref());
            let mut tool_result = json_error_result(
                format_engine_error_result(
                    &function_id,
                    &result.invocation_id,
                    &message,
                    engine_details.as_ref(),
                ),
                json!({
                    "invocationId": result.invocation_id,
                    "functionId": function_id,
                    "engine": engine_details,
                    "approvalRequired": approval_required,
                }),
            );
            if approval_required {
                tool_result.stop_turn = Some(true);
            }
            return Ok(tool_result);
        }
        let result_value = result.value.unwrap_or(Value::Null);
        Ok(json_result(
            format_invoke_result(
                &function_id,
                &result.invocation_id,
                result.replayed_from.as_ref(),
                Some(&result_value),
            ),
            json!({
                "invocationId": result.invocation_id,
                "functionId": function_id,
                "replayedFrom": result.replayed_from,
                "result": result_value,
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

fn agent_authority_scopes() -> Vec<&'static str> {
    vec![
        "catalog.read",
        "engine.read",
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
        "worker.read",
        "worker.write",
        "sandbox.read",
        "sandbox.write",
        "observability.read",
        "tool.read",
        "tool.write",
        "tool.invoke",
    ]
}

fn format_discover_result(functions: &[FunctionDefinition]) -> String {
    if functions.is_empty() {
        return "Found 0 visible engine capabilities. Try a namespace filter such as `sandbox`, `catalog`, `worker`, `observability`, or a shorter query. Do not probe Tron engine capabilities through Bash, HTTP, or MCP when this tool returns no matches.".to_owned();
    }

    let mut lines = vec![
        format!("Found {} visible engine capabilities.", functions.len()),
        "Use canonical function ids with `engine_inspect` for full contract details, then `engine_invoke` for execution.".to_owned(),
        "For Tron engine capability work, stay on these engine tools instead of `/api/*`, `/ws`, Bash curl probes, or MCP search.".to_owned(),
        "For worker creation or on-the-fly capability registration, inspect and invoke `worker::protocol_guide`; it returns the current /engine/workers handshake and an executable local worker template.".to_owned(),
        String::new(),
    ];
    for function in functions.iter().take(40) {
        lines.push(format_function_summary(function));
    }
    if functions.len() > 40 {
        lines.push(format!(
            "... {} more omitted; refine with `namespace` or `query`.",
            functions.len() - 40
        ));
    }
    lines.join("\n")
}

fn format_function_summary(function: &FunctionDefinition) -> String {
    let required = required_schema_fields(function.request_schema.as_ref());
    let properties = schema_property_names(function.request_schema.as_ref());
    let mut parts = vec![
        format!(
            "- `{}` — {} [worker={}, effect={:?}, risk={:?}, visibility={:?}, health={:?}]",
            function.id,
            function.description,
            function.owner_worker,
            function.effect_class,
            function.risk_level,
            function.visibility,
            function.health
        ),
        format!("  authority: {}", authority_summary(function)),
    ];
    if let Some(idempotency) = &function.idempotency {
        parts.push(format!(
            "  idempotency: {:?}, scope={:?}, replay={}, ledger={:?}",
            idempotency.key_source,
            idempotency.dedupe_scope,
            idempotency.replay_behavior.as_str(),
            idempotency.ledger_kind
        ));
    }
    if !required.is_empty() {
        parts.push(format!("  request required: {}", required.join(", ")));
    }
    if !properties.is_empty() {
        parts.push(format!("  request fields: {}", properties.join(", ")));
    }
    let topics = declared_stream_topics(function);
    if !topics.is_empty() {
        parts.push(format!("  stream topics: {}", topics.join(", ")));
    }
    if function.id.as_str() == "sandbox::spawn_worker" {
        parts.push("  agent guidance: first invoke `worker::protocol_guide`, write the returned worker template, then call this function with expectedFunctionIds and a stable idempotencyKey.".to_owned());
    } else if function.id.as_str() == "worker::protocol_guide" {
        parts.push("  agent guidance: use this before writing or registering a sandbox worker; do not search Tron source for the worker protocol.".to_owned());
    }
    parts.join("\n")
}

fn format_inspect_result(function_id: &FunctionId, function: &FunctionDefinition) -> String {
    let mut lines = vec![
        format!("Engine capability `{function_id}`"),
        "This is the canonical contract to follow. Invoke it only through `engine_invoke` unless the user explicitly asks for direct server debugging.".to_owned(),
        String::new(),
        format!("Owner worker: {}", function.owner_worker),
        format!("Description: {}", function.description),
        format!("Revision: {}", function.revision.0),
        format!("Visibility: {:?}", function.visibility),
        format!("Effect/Risk/Health: {:?} / {:?} / {:?}", function.effect_class, function.risk_level, function.health),
        format!("Authority: {}", authority_summary(function)),
    ];

    if let Some(idempotency) = &function.idempotency {
        lines.push(format!(
            "Idempotency: key={:?}, scope={:?}, replay={}, ledger={:?}",
            idempotency.key_source,
            idempotency.dedupe_scope,
            idempotency.replay_behavior.as_str(),
            idempotency.ledger_kind
        ));
    } else if function.effect_class.is_mutating() {
        lines.push(
            "Idempotency: missing from contract; mutating invocation will fail closed.".to_owned(),
        );
    } else {
        lines.push("Idempotency: not required for this read/compute capability.".to_owned());
    }

    if let Some(lease) = &function.resource_lease {
        lines.push(format!(
            "Resource lease: kind={}, idTemplate={}, ttlMs={}, exclusive={}, topic={}",
            lease.resource_kind,
            lease.resource_id_template,
            lease.ttl_ms,
            lease.exclusive,
            lease.stream_topic
        ));
    }
    if let Some(compensation) = &function.compensation {
        lines.push(format!(
            "Compensation: {:?} — {}",
            compensation.kind, compensation.notes
        ));
    }
    let topics = declared_stream_topics(function);
    if !topics.is_empty() {
        lines.push(format!("Declared stream topics: {}", topics.join(", ")));
    }
    let guidance = agent_guidance(function_id, function);
    if !guidance.is_empty() {
        lines.push(String::new());
        lines.push("Agent guidance:".to_owned());
        lines.extend(guidance.into_iter().map(|item| format!("- {item}")));
    }
    lines.push(String::new());
    lines.push("Request schema:".to_owned());
    lines.push(json_preview(
        function.request_schema.as_ref().unwrap_or(&Value::Null),
        12_000,
    ));
    lines.push(String::new());
    lines.push("Response schema:".to_owned());
    lines.push(json_preview(
        function.response_schema.as_ref().unwrap_or(&Value::Null),
        8_000,
    ));
    if !function.metadata.is_null() {
        lines.push(String::new());
        lines.push("Contract metadata:".to_owned());
        lines.push(json_preview(&function.metadata, 8_000));
    }
    lines.join("\n")
}

fn agent_guidance(function_id: &FunctionId, function: &FunctionDefinition) -> Vec<String> {
    let mut guidance = function
        .metadata
        .get("agentGuidance")
        .and_then(Value::as_array)
        .map(|items| {
            items
                .iter()
                .filter_map(Value::as_str)
                .map(ToOwned::to_owned)
                .collect::<Vec<_>>()
        })
        .unwrap_or_default();
    if function_id.as_str() == "sandbox::spawn_worker" {
        guidance.push(
            "To create a new capability: invoke `worker::protocol_guide` first, save the returned template in the requested working directory, then invoke `sandbox::spawn_worker` with that command, expectedFunctionIds, visibility, and a stable idempotencyKey.".to_owned(),
        );
        guidance.push(
            "After spawn succeeds, use `engine_watch` or `catalog::list` to observe the catalog revision, invoke the new canonical function through `engine_invoke`, then stop it with `sandbox::stop_spawned_worker`.".to_owned(),
        );
    }
    guidance
}

fn format_watch_result(
    change_count: usize,
    current_revision: u64,
    next_revision: u64,
    has_more: bool,
    changes: &Value,
) -> String {
    let mut lines = vec![
        format!("Returned {change_count} live catalog change(s)."),
        format!(
            "Catalog revisions: current={current_revision}, next={next_revision}, hasMore={has_more}"
        ),
        "Use changed function ids with `engine_inspect`; refresh provider tools after catalog revision changes.".to_owned(),
    ];
    if change_count > 0 {
        lines.push(String::new());
        lines.push(json_preview(changes, 12_000));
    }
    lines.join("\n")
}

fn format_invoke_result(
    function_id: &FunctionId,
    invocation_id: &InvocationId,
    replayed_from: Option<&InvocationId>,
    value: Option<&Value>,
) -> String {
    let mut lines = vec![
        format!("Invoked engine capability `{function_id}` through the engine path."),
        format!("Invocation id: {invocation_id}"),
    ];
    if let Some(replayed) = replayed_from {
        lines.push(format!("Idempotency replayed from invocation: {replayed}"));
    }
    if let Some(value) = value {
        lines.push(String::new());
        lines.push("Result:".to_owned());
        lines.push(json_preview(value, 12_000));
    }
    lines.join("\n")
}

fn format_engine_error_result(
    function_id: &FunctionId,
    invocation_id: &InvocationId,
    error: &str,
    engine_details: Option<&Value>,
) -> String {
    let mut lines = vec![
        format!("Engine invocation `{function_id}` failed through the engine path."),
        format!("Invocation id: {invocation_id}"),
        format!("Error: {error}"),
    ];
    if let Some(details) = engine_details {
        lines.push(String::new());
        lines.push("Engine details:".to_owned());
        lines.push(json_preview(details, 8_000));
        if details
            .get("code")
            .and_then(Value::as_str)
            .is_some_and(|code| code == "APPROVAL_REQUIRED")
        {
            lines.push(
                "Approval is required before this autonomous agent invocation can run. The engine has published an `approval.pending` stream event for the user client to resolve through canonical `approval::resolve`. This tool result stops the turn; wait for the next user/client action instead of probing approval state.".to_owned(),
            );
        }
    }
    lines.join("\n")
}

fn is_approval_required(engine_details: Option<&Value>) -> bool {
    engine_details
        .and_then(|details| details.get("code"))
        .and_then(Value::as_str)
        .is_some_and(|code| code == "APPROVAL_REQUIRED")
}

fn authority_summary(function: &FunctionDefinition) -> String {
    let scopes = if function.required_authority.scopes.is_empty() {
        "none".to_owned()
    } else {
        function.required_authority.scopes.join(", ")
    };
    format!(
        "scopes=[{}], approvalRequired={}",
        scopes, function.required_authority.approval_required
    )
}

fn required_schema_fields(schema: Option<&Value>) -> Vec<String> {
    schema
        .and_then(|schema| schema.get("required"))
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(Value::as_str)
        .map(ToOwned::to_owned)
        .collect()
}

fn schema_property_names(schema: Option<&Value>) -> Vec<String> {
    let mut names = schema
        .and_then(|schema| schema.get("properties"))
        .and_then(Value::as_object)
        .map(|properties| properties.keys().cloned().collect::<Vec<_>>())
        .unwrap_or_default();
    names.sort();
    names
}

fn declared_stream_topics(function: &FunctionDefinition) -> Vec<String> {
    fn from_array(value: Option<&Value>) -> Vec<String> {
        value
            .and_then(Value::as_array)
            .into_iter()
            .flatten()
            .filter_map(Value::as_str)
            .map(ToOwned::to_owned)
            .collect()
    }
    let mut topics = from_array(function.metadata.get("streamTopics"));
    if topics.is_empty() {
        topics = from_array(function.metadata.pointer("/highRiskContract/streamTopics"));
    }
    topics.sort();
    topics.dedup();
    topics
}

fn json_preview(value: &Value, max_bytes: usize) -> String {
    let rendered = serde_json::to_string_pretty(value).unwrap_or_else(|_| value.to_string());
    truncate_chars(&rendered, max_bytes)
}

fn truncate_chars(value: &str, max_chars: usize) -> String {
    if value.chars().count() <= max_chars {
        return value.to_owned();
    }
    let mut truncated = value.chars().take(max_chars).collect::<String>();
    truncated.push_str("\n... truncated; refine the query or inspect a narrower function.");
    truncated
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
        content: ToolResultBody::Blocks(vec![crate::shared::content::ToolResultContent::text(
            message,
        )]),
        details: Some(details),
        is_error: None,
        stop_turn: None,
    }
}

fn json_error_result(message: String, details: Value) -> TronToolResult {
    TronToolResult {
        content: ToolResultBody::Blocks(vec![crate::shared::content::ToolResultContent::text(
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
    use crate::domains::tools::implementations::testutil::{extract_text, make_ctx};
    use crate::engine::{
        AuthorityRequirement, CompensationContract, CompensationKind, EffectClass,
        FunctionDefinition, IdempotencyContract, InProcessFunctionHandler, Invocation, Provenance,
        RiskLevel, VisibilityScope, WorkerDefinition, WorkerId, WorkerKind,
    };

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

    async fn host_with_approval_gated_capability() -> EngineHostHandle {
        let host = EngineHostHandle::new_in_memory().unwrap();
        host.register_worker_for_setup(
            WorkerDefinition::new(
                worker_id("danger"),
                WorkerKind::InProcess,
                ActorId::new("owner").unwrap(),
                AuthorityGrantId::new("grant").unwrap(),
            )
            .with_namespace_claim("danger"),
            false,
        )
        .unwrap();
        let function = FunctionDefinition::new(
            FunctionId::new("danger::delete").unwrap(),
            worker_id("danger"),
            "approval gated delete",
            VisibilityScope::Agent,
            EffectClass::IdempotentWrite,
        )
        .with_required_authority(
            AuthorityRequirement::scope("state.write").with_approval_required(),
        )
        .with_risk(RiskLevel::High)
        .with_idempotency(IdempotencyContract::caller_session_engine_ledger())
        .with_compensation(CompensationContract::new(
            CompensationKind::ManualOnly,
            "approval-gated test operation is manually compensated",
        ))
        .with_provenance(Provenance::system());
        host.register_function_for_setup(function, Some(std::sync::Arc::new(Echo)), false)
            .unwrap();
        host
    }

    #[tokio::test]
    async fn discover_filters_noncanonical_namespace() {
        let host = host_with_capability(EffectClass::PureRead).await;
        let tool = EngineDiscoverTool::new(host);
        let result = tool.execute(json!({}), &make_ctx()).await.unwrap();
        assert!(!extract_text(&result).contains(&format!("{}::", "rpc")));
        assert!(extract_text(&result).contains("alpha::echo"));
        assert!(extract_text(&result).contains("Use canonical function ids"));
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
    async fn discover_points_worker_registration_queries_to_protocol_guide() {
        let host = EngineHostHandle::new_in_memory().unwrap();
        let tool = EngineDiscoverTool::new(host);
        let result = tool
            .execute(
                json!({"query": "worker protocol register capabilities"}),
                &make_ctx(),
            )
            .await
            .unwrap();
        let text = extract_text(&result);

        assert!(text.contains("worker::protocol_guide"));
        assert!(text.contains("invoke `worker::protocol_guide`"));
    }

    #[tokio::test]
    async fn inspect_returns_model_readable_contract() {
        let host = host_with_capability(EffectClass::IdempotentWrite).await;
        let tool = EngineInspectTool::new(host);
        let result = tool
            .execute(json!({"functionId": "alpha::echo"}), &make_ctx())
            .await
            .unwrap();
        let text = extract_text(&result);

        assert!(text.contains("Engine capability `alpha::echo`"));
        assert!(text.contains("Authority: scopes=[state.write]"));
        assert!(text.contains("Idempotency: key=Caller"));
        assert!(text.contains("Request schema:"));
    }

    #[tokio::test]
    async fn invoke_protocol_guide_returns_executable_worker_recipe() {
        let host = EngineHostHandle::new_in_memory().unwrap();
        let tool = EngineInvokeTool::new(host);
        let result = tool
            .execute(
                json!({
                    "functionId": "worker::protocol_guide",
                    "payload": {
                        "functionId": "demo::echo",
                        "workerId": "demo-echo-worker",
                        "language": "python"
                    }
                }),
                &make_ctx(),
            )
            .await
            .unwrap();
        let details = result.details.unwrap();
        let recipe = &details["result"];

        assert!(result.is_error.is_none());
        assert_eq!(recipe["endpoint"], "/engine/workers");
        assert_eq!(recipe["protocolVersion"], 1);
        assert!(
            recipe["pythonTemplate"]
                .as_str()
                .unwrap()
                .contains("demo::echo")
        );
        assert!(
            recipe["pythonTemplate"]
                .as_str()
                .unwrap()
                .contains("Authorization: Bearer")
        );
    }

    #[tokio::test]
    async fn invoke_protocol_guide_accepts_common_language_aliases() {
        let host = EngineHostHandle::new_in_memory().unwrap();
        let tool = EngineInvokeTool::new(host);
        let result = tool
            .execute(
                json!({
                    "functionId": "worker::protocol_guide",
                    "payload": {
                        "functionId": "demo::echo",
                        "workerId": "demo-echo-worker",
                        "language": "node"
                    }
                }),
                &make_ctx(),
            )
            .await
            .unwrap();
        let details = result.details.unwrap();
        let recipe = &details["result"];

        assert!(result.is_error.is_none());
        assert_eq!(recipe["requestedLanguage"], "node");
        assert_eq!(recipe["templateLanguage"], "python");
        assert!(
            recipe["pythonTemplate"]
                .as_str()
                .unwrap()
                .contains("demo::echo")
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
        assert!(extract_text(&result).contains("through the engine path"));
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
    async fn invoke_approval_required_stops_agent_turn() {
        let host = host_with_approval_gated_capability().await;
        let tool = EngineInvokeTool::new(host);
        let result = tool
            .execute(
                json!({
                    "functionId": "danger::delete",
                    "payload": {"id": "target"},
                    "idempotencyKey": "danger-delete-key"
                }),
                &make_ctx(),
            )
            .await
            .unwrap();

        assert_eq!(result.is_error, Some(true));
        assert_eq!(result.stop_turn, Some(true));
        let details = result.details.as_ref().unwrap();
        assert_eq!(details["approvalRequired"], true);
        assert_eq!(details["engine"]["code"], "APPROVAL_REQUIRED");
        assert!(
            extract_text(&result).contains("This tool result stops the turn"),
            "approval-required engine invocations must block instead of inviting polling"
        );
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

    #[test]
    fn agent_engine_tools_can_use_worker_sandbox_and_observability_scopes() {
        let scopes = agent_authority_scopes();

        assert!(scopes.contains(&"sandbox.write"));
        assert!(scopes.contains(&"sandbox.read"));
        assert!(scopes.contains(&"worker.read"));
        assert!(scopes.contains(&"worker.write"));
        assert!(scopes.contains(&"catalog.read"));
        assert!(scopes.contains(&"observability.read"));
    }
}
