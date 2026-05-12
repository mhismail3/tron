//! Live capability projection and execution primitives.
//!
//! The functions here intentionally adapt the existing engine catalog rather
//! than creating a second capability catalog. A catalog function is projected as a
//! stable contract plus one concrete implementation. Future plugin manifests
//! can add richer contract/binding rows without changing the model-facing
//! `search`/`inspect`/`execute` surface.

use serde_json::{Value, json};
use sha2::{Digest, Sha256};

use super::Deps;
use super::types::{
    CapabilityBindingRecord, CapabilityContractRecord, CapabilityExecutionRecord,
    CapabilityImplementationRecord, CapabilityInspectionRecord,
};
use crate::engine::{
    ActorContext, ActorKind, AuthorityGrantId, CausalContext, DeliveryMode, EffectClass,
    EngineApprovalRequest, FunctionDefinition, FunctionHealth, FunctionId, FunctionQuery,
    FunctionRevision, Invocation, RiskLevel,
};
use crate::shared::content::ToolResultContent;
use crate::shared::server::error_mapping::engine_error_to_capability_error;
use crate::shared::server::errors::CapabilityError;
use crate::shared::tools::{CapabilityResult, ToolResultBody};

const DEFAULT_LIMIT: usize = 12;
const MAX_LIMIT: usize = 50;
const CAPABILITY_ALLOW_SCOPE_PREFIX: &str = "capability.allow:";
const CAPABILITY_DENY_SCOPE_PREFIX: &str = "capability.deny:";

pub(crate) async fn search_value(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<Value, CapabilityError> {
    let params = &invocation.payload;
    let query = string_field(params, "query").unwrap_or_default();
    let namespace = string_field(params, "namespace");
    let limit = u64_field(params, "limit")
        .map(|value| value.clamp(1, MAX_LIMIT as u64) as usize)
        .unwrap_or(DEFAULT_LIMIT);
    let include_unavailable = bool_field(params, "includeUnavailable").unwrap_or(false);
    let max_risk = risk_field(params, "riskMax")?;
    let effect = effect_field(params, "effect")?;

    let actor = actor_from_invocation(invocation)?;
    let mut functions = deps
        .engine_host
        .discover(&FunctionQuery {
            actor: Some(actor),
            namespace_prefix: namespace,
            text: if query.trim().is_empty() {
                None
            } else {
                Some(query.clone())
            },
            effect_class: effect,
            max_risk,
            health: if include_unavailable {
                None
            } else {
                Some(FunctionHealth::Healthy)
            },
            ..FunctionQuery::default()
        })
        .await;
    functions.retain(|function| !is_capability_primitive(function));
    functions.sort_by(|a, b| {
        ranking_score(b, &query)
            .cmp(&ranking_score(a, &query))
            .then_with(|| a.id.as_str().cmp(b.id.as_str()))
    });
    functions.truncate(limit);

    let catalog_revision = deps.engine_host.catalog_revision().await;
    let results = functions
        .iter()
        .map(|function| {
            let projection = CapabilityProjection::from_function(function, catalog_revision.0);
            projection.search_result(&query)
        })
        .collect::<Vec<_>>();
    let summary = render_search_summary(&query, &results);
    tool_result_value(CapabilityResult {
        content: ToolResultBody::Blocks(vec![ToolResultContent::text(summary)]),
        details: Some(json!({
            "query": query,
            "catalogRevision": catalog_revision.0,
            "results": results,
            "searchMode": {
                "lexical": true,
                "localVector": false,
                "cloudEmbeddings": false
            }
        })),
        is_error: None,
        stop_turn: None,
    })
}

pub(crate) async fn inspect_value(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<Value, CapabilityError> {
    let actor = actor_from_invocation(invocation)?;
    let function = resolve_target_function(&invocation.payload, deps, &actor).await?;
    let catalog_revision = deps.engine_host.catalog_revision().await;
    let projection = CapabilityProjection::from_function(&function, catalog_revision.0);
    let details = serde_json::to_value(projection.inspection(&function)).map_err(|error| {
        CapabilityError::Internal {
            message: error.to_string(),
        }
    })?;
    let summary = render_inspection_summary(&details);
    tool_result_value(CapabilityResult {
        content: ToolResultBody::Blocks(vec![ToolResultContent::text(summary)]),
        details: Some(details),
        is_error: None,
        stop_turn: None,
    })
}

pub(crate) async fn execute_value(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<Value, CapabilityError> {
    let mode = string_field(&invocation.payload, "mode").unwrap_or_else(|| "invoke".to_owned());
    match mode.as_str() {
        "invoke" => execute_invoke_value(invocation, deps).await,
        other => Err(CapabilityError::InvalidParams {
            message: format!("Unsupported capability execute mode '{other}'"),
        }),
    }
}

async fn execute_invoke_value(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<Value, CapabilityError> {
    let actor = actor_from_invocation(invocation)?;
    let function = resolve_target_function(&invocation.payload, deps, &actor).await?;
    if is_capability_primitive(&function) {
        return Err(CapabilityError::InvalidParams {
            message: "execute cannot recursively invoke capability primitives; call search or inspect directly".to_owned(),
        });
    }
    let selected_for_policy =
        CapabilityProjection::from_function(&function, deps.engine_host.catalog_revision().await.0);
    enforce_execution_policy(invocation, &selected_for_policy, &function)?;

    let expected_revision = u64_field(&invocation.payload, "expectedRevision");
    if requires_fresh_revision(&function) && expected_revision.is_none() {
        return Err(CapabilityError::Custom {
            code: "INSPECTION_REQUIRED".to_owned(),
            message: format!(
                "{} is mutating or elevated-risk; inspect it first and pass expectedRevision={}",
                function.id.as_str(),
                function.revision.0
            ),
            details: Some(json!({
                "functionId": function.id.as_str(),
                "expectedRevision": function.revision.0,
                "riskLevel": format!("{:?}", function.risk_level),
                "effectClass": format!("{:?}", function.effect_class)
            })),
        });
    }

    if let Some(expected) = expected_revision
        && expected != function.revision.0
    {
        return Err(CapabilityError::Custom {
            code: "STALE_CAPABILITY_REVISION".to_owned(),
            message: format!(
                "{} is at revision {}, not requested revision {expected}",
                function.id.as_str(),
                function.revision.0
            ),
            details: Some(json!({
                "functionId": function.id.as_str(),
                "expectedRevision": expected,
                "currentRevision": function.revision.0,
            })),
        });
    }

    let payload = invocation
        .payload
        .get("payload")
        .cloned()
        .unwrap_or_else(|| json!({}));
    let idempotency_key = child_idempotency_key(
        invocation,
        &function,
        &payload,
        function.effect_class.is_mutating(),
    )?;
    let mut causal_context = CausalContext::new(
        invocation.causal_context.actor_id.clone(),
        invocation.causal_context.actor_kind.clone(),
        invocation.causal_context.authority_grant_id.clone(),
        invocation.causal_context.trace_id.clone(),
    )
    .with_parent_invocation(invocation.id.clone());
    if let Some(session_id) = &invocation.causal_context.session_id {
        causal_context = causal_context.with_session_id(session_id.clone());
    }
    if let Some(workspace_id) = &invocation.causal_context.workspace_id {
        causal_context = causal_context.with_workspace_id(workspace_id.clone());
    }
    for scope in invocation
        .causal_context
        .authority_scopes
        .iter()
        .chain(function.required_authority.scopes.iter())
    {
        if !causal_context.has_scope(scope) {
            causal_context = causal_context.with_scope(scope.clone());
        }
    }
    if let Some(key) = idempotency_key {
        causal_context = causal_context.with_idempotency_key(key);
    }

    let mut child = Invocation::new_sync(function.id.clone(), payload, causal_context);
    if let Some(expected) = expected_revision {
        child = child.expecting_revision(FunctionRevision(expected));
    }
    if function.required_authority.approval_required {
        let approval = deps
            .engine_host
            .request_approval(EngineApprovalRequest {
                function_id: function.id.clone(),
                payload: child.payload.clone(),
                causal_context: child.causal_context.clone(),
                delivery_mode: DeliveryMode::Sync,
            })
            .await
            .map_err(engine_error_to_capability_error)?;
        return tool_result_value(CapabilityResult {
            content: ToolResultBody::Blocks(vec![ToolResultContent::text(format!(
                "Approval required before executing {}.",
                function.id.as_str()
            ))]),
            details: Some(json!({
                "status": "approval_required",
                "approvalState": {
                    "approvalId": approval.approval_id,
                    "status": approval.status,
                    "functionId": function.id.as_str(),
                    "traceId": approval.trace_id.as_str()
                },
                "selectedImplementation": CapabilityProjection::from_function(
                    &function,
                    deps.engine_host.catalog_revision().await.0
                ).implementation_id
            })),
            is_error: Some(true),
            stop_turn: Some(true),
        });
    }
    let result = deps.engine_host.invoke(child).await;
    if let Some(error) = result.error.clone() {
        return Err(engine_error_to_capability_error(error));
    }
    let output = result.value.clone().unwrap_or(Value::Null);
    let catalog_revision = result.catalog_revision.0;
    let selected = CapabilityProjection::from_function(&function, catalog_revision);
    let record = CapabilityExecutionRecord {
        status: "ok".to_owned(),
        trace_id: result.trace_id.as_str().to_owned(),
        root_invocation_id: invocation.id.as_str().to_owned(),
        child_invocations: vec![result.invocation_id.as_str().to_owned()],
        selected_implementation: selected.implementation_id,
        function_id: result.function_id.as_str().to_owned(),
        catalog_revision,
        function_revision: result.function_revision.0,
        output: output.clone(),
        approval_state: None,
        plugin_versions: vec![selected.plugin_id],
    };
    let mut details = serde_json::to_value(record).map_err(|error| CapabilityError::Internal {
        message: error.to_string(),
    })?;
    if let Some(replayed_from) = result.replayed_from {
        details["replayedFrom"] = json!(replayed_from.as_str());
    }

    if let Ok(mut nested) = serde_json::from_value::<CapabilityResult>(output.clone()) {
        nested.details = Some(merge_optional_details(nested.details, details));
        return tool_result_value(nested);
    }

    let text = serde_json::to_string_pretty(&output).unwrap_or_else(|_| output.to_string());
    tool_result_value(CapabilityResult {
        content: ToolResultBody::Blocks(vec![ToolResultContent::text(text)]),
        details: Some(details),
        is_error: None,
        stop_turn: None,
    })
}

async fn resolve_target_function(
    params: &Value,
    deps: &Deps,
    actor: &ActorContext,
) -> Result<FunctionDefinition, CapabilityError> {
    if let Some(function_id) = target_function_id(params) {
        let function_id =
            FunctionId::new(function_id).map_err(|error| CapabilityError::InvalidParams {
                message: error.to_string(),
            })?;
        return deps
            .engine_host
            .inspect_function(&function_id, Some(actor))
            .await
            .map_err(engine_error_to_capability_error);
    }

    let Some(contract_id) = string_field(params, "contractId")
        .or_else(|| string_field(params, "contract_id"))
        .or_else(|| string_field(params, "capabilityId"))
        .or_else(|| string_field(params, "capability_id"))
    else {
        return Err(CapabilityError::InvalidParams {
            message: "Pass one of functionId, implementationId, capabilityId, or contractId"
                .to_owned(),
        });
    };
    let mut functions = deps
        .engine_host
        .discover(&FunctionQuery {
            actor: Some(actor.clone()),
            health: Some(FunctionHealth::Healthy),
            ..FunctionQuery::default()
        })
        .await;
    functions.retain(|function| {
        let projection = CapabilityProjection::from_function(function, 0);
        projection.contract_id == contract_id
            || projection.implementation_id == contract_id
            || projection.capability_id() == contract_id
            || function.id.as_str() == contract_id
    });
    functions.sort_by(|a, b| {
        implementation_preference(a)
            .cmp(&implementation_preference(b))
            .then_with(|| a.id.as_str().cmp(b.id.as_str()))
    });
    functions
        .into_iter()
        .next()
        .ok_or_else(|| CapabilityError::NotFound {
            code: "CAPABILITY_NOT_FOUND".to_owned(),
            message: format!("No visible healthy capability matches '{contract_id}'"),
        })
}

fn target_function_id(params: &Value) -> Option<String> {
    for key in ["functionId", "function_id"] {
        if let Some(value) = string_field(params, key) {
            return Some(value);
        }
    }
    for key in [
        "implementationId",
        "implementation_id",
        "capabilityId",
        "capability_id",
    ] {
        let Some(value) = string_field(params, key) else {
            continue;
        };
        if let Some(function_id) = value.strip_prefix("function:") {
            return Some(function_id.to_owned());
        }
        if value.contains("::") {
            return Some(value);
        }
    }
    None
}

fn actor_from_invocation(invocation: &Invocation) -> Result<ActorContext, CapabilityError> {
    let mut actor = ActorContext::new(
        invocation.causal_context.actor_id.clone(),
        invocation.causal_context.actor_kind.clone(),
        AuthorityGrantId::new(invocation.causal_context.authority_grant_id.as_str()).map_err(
            |error| CapabilityError::Internal {
                message: error.to_string(),
            },
        )?,
    );
    actor.authority_scopes = invocation.causal_context.authority_scopes.clone();
    actor.session_id = invocation.causal_context.session_id.clone();
    actor.workspace_id = invocation.causal_context.workspace_id.clone();
    if !matches!(
        actor.actor_kind,
        ActorKind::Agent | ActorKind::System | ActorKind::Admin
    ) {
        tracing::debug!(
            actor_kind = ?actor.actor_kind,
            "capability primitive invoked by non-agent actor"
        );
    }
    Ok(actor)
}

#[derive(Clone, Debug)]
struct CapabilityProjection {
    contract_id: String,
    implementation_id: String,
    plugin_id: String,
    worker_id: String,
    function_id: String,
    catalog_revision: u64,
    schema_digest: String,
}

impl CapabilityProjection {
    fn from_function(function: &FunctionDefinition, catalog_revision: u64) -> Self {
        let contract_id = string_metadata(function, "contractId")
            .or_else(|| string_metadata(function, "capabilityContractId"))
            .unwrap_or_else(|| default_contract_id(function));
        let implementation_id = string_metadata(function, "implementationId")
            .or_else(|| string_metadata(function, "capabilityImplementationId"))
            .unwrap_or_else(|| format!("function:{}", function.id.as_str()));
        let plugin_id = string_metadata(function, "pluginId")
            .or_else(|| string_metadata(function, "domainModule"))
            .unwrap_or_else(|| default_plugin_id(function));
        let schema_digest = schema_digest(function);
        Self {
            contract_id,
            implementation_id,
            plugin_id,
            worker_id: function.owner_worker.as_str().to_owned(),
            function_id: function.id.as_str().to_owned(),
            catalog_revision,
            schema_digest,
        }
    }

    fn capability_id(&self) -> String {
        self.implementation_id.clone()
    }

    fn search_result(&self, query: &str) -> Value {
        json!({
            "kind": "implementation",
            "capabilityId": self.capability_id(),
            "contractId": self.contract_id,
            "implementationId": self.implementation_id,
            "pluginId": self.plugin_id,
            "workerId": self.worker_id,
            "functionId": self.function_id,
            "catalogRevision": self.catalog_revision,
            "schemaDigest": self.schema_digest,
            "relevance": ranking_hint(&self.function_id, query),
            "requiresInspect": true
        })
    }

    fn inspection(&self, function: &FunctionDefinition) -> CapabilityInspectionRecord {
        CapabilityInspectionRecord {
            contract: CapabilityContractRecord {
                contract_id: self.contract_id.clone(),
                version: function.revision.0,
                display_name: display_name(function),
                description: function.description.clone(),
                input_schema: function.request_schema.clone(),
                output_schema: function.response_schema.clone(),
                effect_class: effect_name(function.effect_class).to_owned(),
                risk_level: risk_name(function.risk_level).to_owned(),
                idempotency_contract: serde_json::to_value(&function.idempotency).ok(),
                approval_contract: json!({
                    "approvalRequired": function.required_authority.approval_required
                }),
                lease_contract: serde_json::to_value(&function.resource_lease).ok(),
                compensation_contract: serde_json::to_value(&function.compensation).ok(),
                examples: Vec::new(),
                semantic_tags: function.tags.clone(),
            },
            implementation: CapabilityImplementationRecord {
                implementation_id: self.implementation_id.clone(),
                contract_id: self.contract_id.clone(),
                plugin_id: self.plugin_id.clone(),
                worker_id: self.worker_id.clone(),
                function_id: self.function_id.clone(),
                version: function.revision.0,
                health: format!("{:?}", function.health),
                visibility: function.visibility.as_str().to_owned(),
                latency_class: "unknown".to_owned(),
                cost_class: "unknown".to_owned(),
                trust_tier: trust_tier(function).to_owned(),
                authority_requirements: serde_json::to_value(&function.required_authority)
                    .unwrap_or(Value::Null),
                runtime_requirements: runtime_requirements(function),
                schema_digest: self.schema_digest.clone(),
                catalog_revision: self.catalog_revision,
                provenance: serde_json::to_value(&function.provenance).unwrap_or(Value::Null),
            },
            binding: CapabilityBindingRecord {
                contract_id: self.contract_id.clone(),
                selected_implementation: self.implementation_id.clone(),
                selection_policy: "direct_catalog_default".to_owned(),
                secondary_implementations: Vec::new(),
                enabled: true,
            },
            execution_requirements: json!({
                "expectedRevision": function.revision.0,
                "freshInspectionRequired": requires_fresh_revision(function),
                "idempotencyKeyRequired": function.effect_class.is_mutating(),
                "approvalRequired": function.required_authority.approval_required,
                "timeoutMs": null,
                "budget": null
            }),
            docs: json!({
                "summary": function.description,
                "metadata": function.metadata
            }),
        }
    }
}

fn is_capability_primitive(function: &FunctionDefinition) -> bool {
    function
        .metadata
        .get("capabilityPrimitive")
        .and_then(Value::as_bool)
        .unwrap_or(false)
}

fn default_contract_id(function: &FunctionDefinition) -> String {
    function.id.as_str().to_owned()
}

fn default_plugin_id(function: &FunctionDefinition) -> String {
    match function.owner_worker.as_str() {
        "mcp" => "external.mcp".to_owned(),
        worker => format!("first_party.{worker}"),
    }
}

fn schema_digest(function: &FunctionDefinition) -> String {
    let material = json!({
        "functionId": function.id.as_str(),
        "revision": function.revision.0,
        "request": function.request_schema,
        "response": function.response_schema,
        "effect": effect_name(function.effect_class),
        "risk": risk_name(function.risk_level),
    });
    let serialized = serde_json::to_vec(&material).unwrap_or_default();
    sha256_hex(&serialized)
}

fn ranking_score(function: &FunctionDefinition, query: &str) -> i64 {
    if query.trim().is_empty() {
        return 0;
    }
    let haystack = searchable_text(function);
    query
        .split_whitespace()
        .map(|term| {
            let term = term.to_ascii_lowercase();
            if function.id.as_str().to_ascii_lowercase() == term {
                100
            } else if function.id.as_str().to_ascii_lowercase().contains(&term) {
                50
            } else if haystack.contains(&term) {
                10
            } else {
                0
            }
        })
        .sum()
}

fn ranking_hint(function_id: &str, query: &str) -> Value {
    json!({
        "score": if query.trim().is_empty() { 0 } else { 1 },
        "matchedBy": "local_lexical",
        "snippet": function_id
    })
}

fn searchable_text(function: &FunctionDefinition) -> String {
    let mut text = [
        function.id.as_str().to_owned(),
        function.description.clone(),
        function.tags.join(" "),
        function.metadata.to_string(),
    ]
    .join(" ");
    text.make_ascii_lowercase();
    text
}

fn implementation_preference(function: &FunctionDefinition) -> u8 {
    match function.owner_worker.as_str() {
        "mcp" => 20,
        _ => 0,
    }
}

fn enforce_execution_policy(
    invocation: &Invocation,
    projection: &CapabilityProjection,
    function: &FunctionDefinition,
) -> Result<(), CapabilityError> {
    if matches!(
        invocation.causal_context.actor_kind,
        ActorKind::System | ActorKind::Admin
    ) {
        return Ok(());
    }

    let candidates = [
        projection.contract_id.as_str(),
        projection.implementation_id.as_str(),
        projection.function_id.as_str(),
        function.id.as_str(),
    ];
    if policy_scope_matches(
        &invocation.causal_context.authority_scopes,
        CAPABILITY_DENY_SCOPE_PREFIX,
        &candidates,
    ) {
        return Err(CapabilityError::Custom {
            code: "CAPABILITY_DENIED".to_owned(),
            message: format!(
                "{} is denied by the active capability policy",
                function.id.as_str()
            ),
            details: Some(json!({
                "contractId": projection.contract_id,
                "implementationId": projection.implementation_id,
                "functionId": function.id.as_str()
            })),
        });
    }
    if policy_scope_matches(
        &invocation.causal_context.authority_scopes,
        CAPABILITY_ALLOW_SCOPE_PREFIX,
        &candidates,
    ) {
        return Ok(());
    }
    Err(CapabilityError::Custom {
        code: "CAPABILITY_DENIED".to_owned(),
        message: format!(
            "{} is not allowed by the active capability policy",
            function.id.as_str()
        ),
        details: Some(json!({
            "contractId": projection.contract_id,
            "implementationId": projection.implementation_id,
            "functionId": function.id.as_str()
        })),
    })
}

fn policy_scope_matches(scopes: &[String], prefix: &str, candidates: &[&str]) -> bool {
    scopes.iter().any(|scope| {
        let Some(value) = scope.strip_prefix(prefix) else {
            return false;
        };
        value == "*" || candidates.contains(&value)
    })
}

fn requires_fresh_revision(function: &FunctionDefinition) -> bool {
    function.effect_class.is_mutating() || function.risk_level >= RiskLevel::Medium
}

fn child_idempotency_key(
    invocation: &Invocation,
    function: &FunctionDefinition,
    payload: &Value,
    required: bool,
) -> Result<Option<String>, CapabilityError> {
    if let Some(key) = string_field(&invocation.payload, "idempotencyKey")
        .or_else(|| string_field(&invocation.payload, "idempotency_key"))
    {
        return Ok(Some(key));
    }
    if let Some(parent_key) = invocation.causal_context.idempotency_key.as_deref() {
        let material = json!({
            "parent": parent_key,
            "functionId": function.id.as_str(),
            "payload": payload,
        });
        let serialized = serde_json::to_vec(&material).unwrap_or_default();
        return Ok(Some(format!(
            "capability-execute:v1:{}",
            sha256_hex(&serialized)
        )));
    }
    if required {
        return Err(CapabilityError::InvalidParams {
            message: format!(
                "{} mutates state; pass idempotencyKey or invoke through a model tool call with engine idempotency",
                function.id.as_str()
            ),
        });
    }
    Ok(None)
}

fn render_search_summary(query: &str, results: &[Value]) -> String {
    if results.is_empty() {
        return if query.trim().is_empty() {
            "No visible capabilities found.".to_owned()
        } else {
            format!("No visible capabilities found for '{query}'.")
        };
    }
    let mut lines = vec![format!(
        "Found {} visible capabilities. Inspect one before executing mutating or elevated-risk work.",
        results.len()
    )];
    for result in results.iter().take(8) {
        let function_id = result
            .get("functionId")
            .and_then(Value::as_str)
            .unwrap_or("<unknown>");
        let contract_id = result
            .get("contractId")
            .and_then(Value::as_str)
            .unwrap_or("<unknown>");
        lines.push(format!("- {contract_id} -> {function_id}"));
    }
    lines.join("\n")
}

fn render_inspection_summary(details: &Value) -> String {
    let implementation = &details["implementation"];
    let contract = &details["contract"];
    let function_id = implementation["functionId"].as_str().unwrap_or("<unknown>");
    let contract_id = contract["contractId"].as_str().unwrap_or("<unknown>");
    let effect = contract["effectClass"].as_str().unwrap_or("unknown");
    let risk = contract["riskLevel"].as_str().unwrap_or("unknown");
    let expected = details["executionRequirements"]["expectedRevision"]
        .as_u64()
        .unwrap_or_default();
    format!(
        "{contract_id} is implemented by {function_id}. effect={effect}, risk={risk}, expectedRevision={expected}."
    )
}

fn tool_result_value(result: CapabilityResult) -> Result<Value, CapabilityError> {
    serde_json::to_value(result).map_err(|error| CapabilityError::Internal {
        message: error.to_string(),
    })
}

fn merge_optional_details(existing: Option<Value>, extra: Value) -> Value {
    match existing {
        Some(Value::Object(mut object)) => {
            let _ = object.insert("capabilityExecution".to_owned(), extra);
            Value::Object(object)
        }
        Some(value) => json!({
            "toolDetails": value,
            "capabilityExecution": extra
        }),
        None => extra,
    }
}

fn string_metadata(function: &FunctionDefinition, key: &str) -> Option<String> {
    function
        .metadata
        .get(key)
        .and_then(Value::as_str)
        .map(ToOwned::to_owned)
}

fn runtime_requirements(function: &FunctionDefinition) -> Value {
    json!({
        "workerKind": function.metadata.get("workerKind").cloned().unwrap_or(Value::Null),
        "deliveryModes": function.allowed_delivery_modes.iter().map(|mode| format!("{:?}", mode)).collect::<Vec<_>>()
    })
}

fn display_name(function: &FunctionDefinition) -> String {
    string_metadata(function, "modelToolName")
        .or_else(|| {
            function
                .id
                .as_str()
                .rsplit_once("::")
                .map(|(_, name)| name.to_owned())
        })
        .unwrap_or_else(|| function.id.as_str().to_owned())
}

fn trust_tier(function: &FunctionDefinition) -> &'static str {
    match function.owner_worker.as_str() {
        "mcp" => "external_mcp",
        worker if function.provenance.source == "system" || worker != "sandbox" => {
            "first_party_signed"
        }
        "sandbox" => "session_generated",
        _ => "untrusted",
    }
}

fn risk_field(params: &Value, key: &str) -> Result<Option<RiskLevel>, CapabilityError> {
    let Some(value) = string_field(params, key) else {
        return Ok(None);
    };
    match value.to_ascii_lowercase().as_str() {
        "low" => Ok(Some(RiskLevel::Low)),
        "medium" => Ok(Some(RiskLevel::Medium)),
        "high" => Ok(Some(RiskLevel::High)),
        "critical" => Ok(Some(RiskLevel::Critical)),
        _ => Err(CapabilityError::InvalidParams {
            message: format!("Unsupported riskMax '{value}'"),
        }),
    }
}

fn effect_field(params: &Value, key: &str) -> Result<Option<EffectClass>, CapabilityError> {
    let Some(value) = string_field(params, key) else {
        return Ok(None);
    };
    let normalized = value
        .chars()
        .filter(|ch| ch.is_ascii_alphanumeric())
        .collect::<String>()
        .to_ascii_lowercase();
    match normalized.as_str() {
        "pureread" => Ok(Some(EffectClass::PureRead)),
        "deterministiccompute" => Ok(Some(EffectClass::DeterministicCompute)),
        "delegatedinvocation" => Ok(Some(EffectClass::DelegatedInvocation)),
        "idempotentwrite" => Ok(Some(EffectClass::IdempotentWrite)),
        "appendonlyevent" => Ok(Some(EffectClass::AppendOnlyEvent)),
        "reversiblesideeffect" => Ok(Some(EffectClass::ReversibleSideEffect)),
        "externalsideeffect" => Ok(Some(EffectClass::ExternalSideEffect)),
        "irreversiblesideeffect" => Ok(Some(EffectClass::IrreversibleSideEffect)),
        _ => Err(CapabilityError::InvalidParams {
            message: format!("Unsupported effect '{value}'"),
        }),
    }
}

fn effect_name(effect: EffectClass) -> &'static str {
    match effect {
        EffectClass::PureRead => "pure_read",
        EffectClass::DeterministicCompute => "deterministic_compute",
        EffectClass::DelegatedInvocation => "delegated_invocation",
        EffectClass::IdempotentWrite => "idempotent_write",
        EffectClass::AppendOnlyEvent => "append_only_event",
        EffectClass::ReversibleSideEffect => "reversible_side_effect",
        EffectClass::ExternalSideEffect => "external_side_effect",
        EffectClass::IrreversibleSideEffect => "irreversible_side_effect",
    }
}

fn risk_name(risk: RiskLevel) -> &'static str {
    match risk {
        RiskLevel::Low => "low",
        RiskLevel::Medium => "medium",
        RiskLevel::High => "high",
        RiskLevel::Critical => "critical",
    }
}

fn string_field(params: &Value, key: &str) -> Option<String> {
    params
        .get(key)
        .and_then(Value::as_str)
        .map(ToOwned::to_owned)
}

fn u64_field(params: &Value, key: &str) -> Option<u64> {
    params.get(key).and_then(Value::as_u64)
}

fn bool_field(params: &Value, key: &str) -> Option<bool> {
    params.get(key).and_then(Value::as_bool)
}

fn sha256_hex(bytes: &[u8]) -> String {
    let mut hasher = Sha256::new();
    hasher.update(bytes);
    hex::encode(hasher.finalize())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::engine::{VisibilityScope, WorkerId};

    fn test_function(id: &str) -> FunctionDefinition {
        FunctionDefinition::new(
            FunctionId::new(id).expect("function id"),
            WorkerId::new(id.split("::").next().expect("namespace")).expect("worker id"),
            "Searchable test function",
            VisibilityScope::System,
            EffectClass::PureRead,
        )
    }

    #[test]
    fn projection_defaults_contract_and_implementation_from_function() {
        let function = test_function("filesystem::read_file");
        let projection = CapabilityProjection::from_function(&function, 7);
        assert_eq!(projection.contract_id, "filesystem::read_file");
        assert_eq!(
            projection.implementation_id,
            "function:filesystem::read_file"
        );
        assert_eq!(projection.plugin_id, "first_party.filesystem");
        assert_eq!(projection.catalog_revision, 7);
        assert!(!projection.schema_digest.is_empty());
    }

    #[test]
    fn stale_revision_needed_for_mutating_or_risky_functions() {
        let mut read = test_function("alpha::read");
        assert!(!requires_fresh_revision(&read));
        read.effect_class = EffectClass::IdempotentWrite;
        assert!(requires_fresh_revision(&read));
        read.effect_class = EffectClass::PureRead;
        read.risk_level = RiskLevel::Medium;
        assert!(requires_fresh_revision(&read));
    }

    #[test]
    fn child_idempotency_derives_from_parent_tool_call_key() {
        let function = test_function("filesystem::read_file");
        let causal = CausalContext::new(
            crate::engine::ActorId::new("agent:s1").expect("actor id"),
            ActorKind::Agent,
            AuthorityGrantId::new("agent-tool-runtime").expect("grant id"),
            crate::engine::TraceId::new("trace").expect("trace id"),
        )
        .with_idempotency_key("parent-key");
        let invocation = Invocation::new_sync(
            FunctionId::new("capability::execute").expect("function id"),
            json!({"payload": {"path": "a"}}),
            causal,
        );
        let key = child_idempotency_key(&invocation, &function, &json!({"path": "a"}), true)
            .expect("key")
            .expect("derived key");
        assert!(key.starts_with("capability-execute:v1:"));
    }

    #[test]
    fn explicit_implementation_id_can_address_function_ids() {
        let params = json!({"implementationId": "function:filesystem::read_file"});
        assert_eq!(
            target_function_id(&params),
            Some("filesystem::read_file".to_owned())
        );
    }

    #[test]
    fn retired_harness_symbols_do_not_reappear_in_runtime_source() {
        let manifest = std::path::Path::new(env!("CARGO_MANIFEST_DIR"));
        let src = manifest.join("src");
        let forbidden = [
            concat!("Tron", "Tool"),
            concat!("Tool", "Context"),
            concat!("capability", "_runtime"),
            concat!("builtin", "_function", "_registrations"),
            concat!("Mcp", "Search"),
            concat!("Mcp", "Call"),
            concat!("Engine", "Discover"),
            concat!("Engine", "Inspect"),
            concat!("Engine", "Invoke"),
            concat!("Engine", "Watch"),
            concat!("allowed", "Tools"),
            concat!("denied", "Tools"),
            concat!("inherit", "Tools"),
            concat!("tool", "Policy"),
            concat!("tool", "Policies"),
            concat!("allowed", "_tools"),
            concat!("denied", "_tools"),
            concat!("inherit", "_tools"),
            concat!("PROGRAM", "_RUNTIME", "_NOT", "_LINKED"),
            concat!("Ask", "User", "Question"),
            concat!("Web", "Fetch"),
            concat!("Web", "Search"),
            concat!("Spawn", "Subagent"),
        ];
        let mut failures = Vec::new();
        scan_source_for_forbidden(&src, &forbidden, &mut failures);
        assert!(
            failures.is_empty(),
            "retired harness symbols found:\n{}",
            failures.join("\n")
        );
    }

    fn scan_source_for_forbidden(
        path: &std::path::Path,
        forbidden: &[&str],
        failures: &mut Vec<String>,
    ) {
        let Ok(entries) = std::fs::read_dir(path) else {
            return;
        };
        for entry in entries.flatten() {
            let path = entry.path();
            if path.is_dir() {
                scan_source_for_forbidden(&path, forbidden, failures);
                continue;
            }
            if path.extension().and_then(|ext| ext.to_str()) != Some("rs") {
                continue;
            }
            if path.ends_with("domains/session/event_store/types/generated.rs") {
                continue;
            }
            let Ok(text) = std::fs::read_to_string(&path) else {
                continue;
            };
            for symbol in forbidden {
                if text.contains(symbol) {
                    failures.push(format!("{} contains {symbol}", path.display()));
                }
            }
        }
    }
}
