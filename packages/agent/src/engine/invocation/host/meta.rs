//! Engine meta-function definitions and payload projection helpers.
//!
//! The host root coordinates locks and invocation flow. This module owns the
//! stable `engine::*` worker/function vocabulary, meta request schemas, watch
//! DTOs, visibility projection, delegated invocation shaping, and small payload
//! parsers used by those meta functions.

use super::*;

pub(super) const ENGINE_WORKER_ID: &str = "engine";
pub(super) const ENGINE_OWNER_ACTOR: &str = "system";
pub(super) const ENGINE_AUTHORITY_GRANT: &str = "engine-system";

pub(super) const DISCOVER_FUNCTION: &str = "engine::discover";
pub(super) const INSPECT_FUNCTION: &str = "engine::inspect";
pub(super) const WATCH_FUNCTION: &str = "engine::watch";
pub(super) const INVOKE_FUNCTION: &str = "engine::invoke";
pub(super) const PROMOTE_FUNCTION: &str = "engine::promote";

const WATCH_DEFAULT_LIMIT: usize = 100;
pub(super) const WATCH_MAX_LIMIT: usize = 500;

/// Cursor-pull request for catalog changes.
#[derive(Clone, Debug, PartialEq)]
pub struct CatalogWatchRequest {
    /// Return changes after this catalog revision.
    pub after_revision: CatalogRevision,
    /// Maximum number of visible matching changes to return.
    pub limit: usize,
    /// Optional change-class filter.
    pub classes: Option<Vec<CatalogChangeClass>>,
    /// Optional exact change-kind filter.
    pub kinds: Option<Vec<CatalogChangeKind>>,
    /// Optional subject id prefix.
    pub subject_prefix: Option<String>,
    /// Optional owner worker filter.
    pub owner_worker: Option<WorkerId>,
}

impl Default for CatalogWatchRequest {
    fn default() -> Self {
        Self {
            after_revision: CatalogRevision(0),
            limit: WATCH_DEFAULT_LIMIT,
            classes: None,
            kinds: None,
            subject_prefix: None,
            owner_worker: None,
        }
    }
}

/// Cursor-pull response for catalog changes.
#[derive(Clone, Debug, PartialEq)]
pub struct CatalogWatchResponse {
    /// Visible matching changes.
    pub changes: Vec<CatalogChange>,
    /// Current live catalog revision.
    pub current_revision: CatalogRevision,
    /// Cursor to use for the next request.
    pub next_revision: CatalogRevision,
    /// Whether more visible matching changes remain after this page.
    pub has_more: bool,
}

pub(super) fn engine_worker() -> WorkerDefinition {
    WorkerDefinition::new(
        worker_id(ENGINE_WORKER_ID).expect("valid engine worker id"),
        WorkerKind::System,
        actor_id(ENGINE_OWNER_ACTOR).expect("valid engine owner actor"),
        grant_id(ENGINE_AUTHORITY_GRANT).expect("valid engine authority grant"),
    )
    .with_namespace_claim(ENGINE_WORKER_ID)
}

pub(super) fn meta_function_definitions() -> Result<Vec<FunctionDefinition>> {
    let owner = worker_id(ENGINE_WORKER_ID)?;
    let mut definitions = vec![
        meta_function(
            DISCOVER_FUNCTION,
            "discover live engine capabilities",
            EffectClass::PureRead,
        )
        .with_request_schema(discover_schema()),
        meta_function(
            INSPECT_FUNCTION,
            "inspect a live engine catalog item",
            EffectClass::PureRead,
        )
        .with_request_schema(inspect_schema()),
        meta_function(
            WATCH_FUNCTION,
            "watch catalog changes by cursor",
            EffectClass::PureRead,
        )
        .with_request_schema(watch_schema()),
        meta_function(
            INVOKE_FUNCTION,
            "invoke another engine capability",
            EffectClass::DelegatedInvocation,
        )
        .with_request_schema(invoke_schema()),
        meta_function(
            PROMOTE_FUNCTION,
            "promote a session capability to a wider scope",
            EffectClass::IdempotentWrite,
        )
        .with_idempotency(IdempotencyContract::caller_session_engine_ledger())
        .with_required_authority(AuthorityRequirement::scope("engine.promote"))
        .with_risk(RiskLevel::Medium)
        .with_request_schema(promote_schema()),
    ];
    for definition in &mut definitions {
        definition.owner_worker = owner.clone();
        definition.opaque_response = true;
        definition.provenance = Provenance::system();
    }
    Ok(definitions)
}

pub(super) fn same_meta_function_contract(
    existing: &FunctionDefinition,
    expected: &FunctionDefinition,
) -> bool {
    existing.id == expected.id
        && existing.owner_worker == expected.owner_worker
        && existing.description == expected.description
        && existing.request_schema == expected.request_schema
        && existing.response_schema == expected.response_schema
        && existing.opaque_response == expected.opaque_response
        && existing.tags == expected.tags
        && existing.visibility == expected.visibility
        && existing.effect_class == expected.effect_class
        && existing.risk_level == expected.risk_level
        && existing.idempotency == expected.idempotency
        && existing.required_authority == expected.required_authority
        && existing.allowed_delivery_modes == expected.allowed_delivery_modes
        && existing.health == expected.health
        && existing.provenance == expected.provenance
        && existing.metadata == expected.metadata
}

fn meta_function(id: &str, description: &str, effect: EffectClass) -> FunctionDefinition {
    FunctionDefinition::new(
        function_id(id).expect("valid static engine function id"),
        worker_id(ENGINE_WORKER_ID).expect("valid engine worker id"),
        description,
        VisibilityScope::System,
        effect,
    )
}

fn discover_schema() -> Value {
    json!({
        "type": "object",
        "additionalProperties": false,
        "properties": {
            "visibility": {"type": "string"},
            "namespacePrefix": {"type": "string"},
            "text": {"type": "string"},
            "effectClass": {"type": "string"},
            "maxRisk": {"type": "string"},
            "health": {"type": "string"},
            "includeInternal": {"type": "boolean"}
        }
    })
}

fn inspect_schema() -> Value {
    json!({
        "type": "object",
        "required": ["kind", "id"],
        "additionalProperties": false,
        "properties": {
            "kind": {"type": "string", "enum": ["function", "worker", "trigger_type", "trigger"]},
            "id": {"type": "string"}
        }
    })
}

fn watch_schema() -> Value {
    json!({
        "type": "object",
        "additionalProperties": false,
        "properties": {
            "afterRevision": {"type": "integer"},
            "limit": {"type": "integer"},
            "classes": {"type": "array", "items": {"type": "string"}},
            "kinds": {"type": "array", "items": {"type": "string"}},
            "subjectPrefix": {"type": "string"},
            "ownerWorker": {"type": "string"}
        }
    })
}

fn invoke_schema() -> Value {
    json!({
        "type": "object",
        "required": ["functionId"],
        "additionalProperties": false,
        "properties": {
            "functionId": {"type": "string"},
            "payload": {},
            "deliveryMode": {"type": "string", "enum": ["sync"]},
            "idempotencyKey": {"type": "string"}
        }
    })
}

fn promote_schema() -> Value {
    json!({
        "type": "object",
        "required": ["functionId", "targetVisibility"],
        "additionalProperties": false,
        "properties": {
            "functionId": {"type": "string"},
            "ownerWorker": {"type": "string"},
            "targetVisibility": {"type": "string", "enum": ["workspace", "system"]},
            "workspaceId": {"type": "string"}
        }
    })
}

pub(super) fn actor_context(context: &CausalContext) -> ActorContext {
    ActorContext {
        actor_id: context.actor_id.clone(),
        actor_kind: context.actor_kind.clone(),
        authority_grant_id: context.authority_grant_id.clone(),
        authority_scopes: context.authority_scopes.clone(),
        session_id: context.session_id.clone(),
        workspace_id: context.workspace_id.clone(),
    }
}

pub(super) fn is_change_visible_to_actor(change: &CatalogChange, actor: &ActorContext) -> bool {
    is_visibility_visible(
        &change.visibility,
        change.session_id.as_deref(),
        change.workspace_id.as_deref(),
        actor,
    )
}

pub(super) fn is_visibility_visible(
    visibility: &VisibilityScope,
    session_id: Option<&str>,
    workspace_id: Option<&str>,
    actor: &ActorContext,
) -> bool {
    match visibility {
        VisibilityScope::Internal => actor.actor_kind.is_admin_like(),
        VisibilityScope::Session => {
            actor.actor_kind.is_admin_like()
                || matches!((actor.session_id.as_deref(), session_id), (Some(a), Some(b)) if a == b)
        }
        VisibilityScope::Workspace => {
            actor.actor_kind.is_admin_like()
                || matches!((actor.workspace_id.as_deref(), workspace_id), (Some(a), Some(b)) if a == b)
        }
        VisibilityScope::System => true,
        VisibilityScope::Client => {
            matches!(actor.actor_kind, ActorKind::Client) || actor.actor_kind.is_admin_like()
        }
        VisibilityScope::Worker => {
            matches!(actor.actor_kind, ActorKind::Worker) || actor.actor_kind.is_admin_like()
        }
        VisibilityScope::Agent => {
            matches!(actor.actor_kind, ActorKind::Agent) || actor.actor_kind.is_admin_like()
        }
        VisibilityScope::Admin => actor.actor_kind.is_admin_like(),
    }
}

pub(super) fn catalog_change_value(change: &CatalogChange) -> Value {
    json!({
        "id": change.id.as_str(),
        "beforeRevision": change.before.0,
        "afterRevision": change.after.0,
        "kind": change_kind_str(&change.kind),
        "subjectId": change.subject_id.as_str(),
        "subjectKind": change.subject_kind.as_str(),
        "class": change.class.as_str(),
        "visibility": change.visibility.as_str(),
        "sessionId": change.session_id.as_deref(),
        "workspaceId": change.workspace_id.as_deref(),
        "ownerWorker": change.owner_worker.as_ref().map(WorkerId::as_str),
        "timestamp": change.timestamp.to_rfc3339(),
    })
}

pub(super) fn invocation_result_value(result: &InvocationResult) -> Value {
    json!({
        "invocationId": result.invocation_id.as_str(),
        "functionId": result.function_id.as_str(),
        "traceId": result.trace_id.as_str(),
        "value": result.value.as_ref(),
        "error": result.error.as_ref().map(error_value),
        "replayedFrom": result.replayed_from.as_ref().map(InvocationId::as_str),
    })
}

pub(super) fn delegated_invoke_value(child_result: &InvocationResult) -> Value {
    json!({
        "child": invocation_result_value(child_result),
    })
}

pub(super) fn delegated_child_invocation(invocation: &Invocation) -> Result<Invocation> {
    let target_id = function_id(required_str(&invocation.payload, "functionId")?)?;
    let payload = invocation
        .payload
        .get("payload")
        .cloned()
        .unwrap_or(Value::Null);
    let delivery_mode = optional_delivery_mode(invocation.payload.get("deliveryMode"))?
        .unwrap_or(DeliveryMode::Sync);
    let idempotency_key = optional_string(invocation.payload.get("idempotencyKey"))?;

    let mut child_context = invocation.causal_context.clone();
    child_context.parent_invocation_id = Some(invocation.id.clone());
    child_context.idempotency_key = idempotency_key;
    child_context.delivery_mode = delivery_mode;
    Ok(Invocation::new_sync(target_id, payload, child_context).with_delivery_mode(delivery_mode))
}

pub(super) fn error_value(error: &EngineError) -> Value {
    let stored = StoredEngineError::from_engine_error(error);
    json!({
        "kind": stored.kind,
        "message": stored.message,
        "details": stored.details,
    })
}

pub(super) fn required_str<'a>(payload: &'a Value, field: &str) -> Result<&'a str> {
    payload.get(field).and_then(Value::as_str).ok_or_else(|| {
        EngineError::PolicyViolation(format!("required field {field} must be a string"))
    })
}

pub(super) fn optional_string(value: Option<&Value>) -> Result<Option<String>> {
    value
        .map(|value| {
            value.as_str().map(str::to_owned).ok_or_else(|| {
                EngineError::PolicyViolation("optional field must be a string".to_owned())
            })
        })
        .transpose()
}

pub(super) fn optional_u64(value: Option<&Value>) -> Result<Option<u64>> {
    value
        .map(|value| {
            value.as_u64().ok_or_else(|| {
                EngineError::PolicyViolation("optional field must be an integer".to_owned())
            })
        })
        .transpose()
}

fn watch_limit(value: Option<&Value>) -> Result<usize> {
    let Some(limit) = optional_u64(value)? else {
        return Ok(WATCH_DEFAULT_LIMIT);
    };
    if limit == 0 {
        return Err(EngineError::PolicyViolation(
            "watch limit must be greater than zero".to_owned(),
        ));
    }
    Ok((limit as usize).min(WATCH_MAX_LIMIT))
}

pub(super) fn watch_request_from_payload(payload: &Value) -> Result<CatalogWatchRequest> {
    Ok(CatalogWatchRequest {
        after_revision: CatalogRevision(
            optional_u64(payload.get("afterRevision"))?.unwrap_or_default(),
        ),
        limit: watch_limit(payload.get("limit"))?,
        classes: optional_change_classes(payload.get("classes"))?,
        kinds: optional_change_kinds(payload.get("kinds"))?,
        subject_prefix: optional_string(payload.get("subjectPrefix"))?,
        owner_worker: optional_string(payload.get("ownerWorker"))?
            .map(WorkerId::new)
            .transpose()?,
    })
}

fn optional_change_classes(value: Option<&Value>) -> Result<Option<Vec<CatalogChangeClass>>> {
    value
        .map(|value| {
            let items = value.as_array().ok_or_else(|| {
                EngineError::PolicyViolation("classes must be an array".to_owned())
            })?;
            items
                .iter()
                .map(|item| {
                    item.as_str()
                        .ok_or_else(|| {
                            EngineError::PolicyViolation(
                                "classes entries must be strings".to_owned(),
                            )
                        })
                        .and_then(parse_change_class)
                })
                .collect()
        })
        .transpose()
}

fn optional_change_kinds(value: Option<&Value>) -> Result<Option<Vec<CatalogChangeKind>>> {
    value
        .map(|value| {
            let items = value
                .as_array()
                .ok_or_else(|| EngineError::PolicyViolation("kinds must be an array".to_owned()))?;
            items
                .iter()
                .map(|item| {
                    item.as_str()
                        .ok_or_else(|| {
                            EngineError::PolicyViolation("kinds entries must be strings".to_owned())
                        })
                        .and_then(parse_change_kind)
                })
                .collect()
        })
        .transpose()
}

pub(super) fn optional_visibility(value: Option<&Value>) -> Result<Option<VisibilityScope>> {
    value
        .map(|value| {
            value
                .as_str()
                .ok_or_else(|| {
                    EngineError::PolicyViolation("visibility must be a string".to_owned())
                })
                .and_then(parse_visibility)
        })
        .transpose()
}

pub(super) fn required_visibility(payload: &Value, field: &str) -> Result<VisibilityScope> {
    parse_visibility(required_str(payload, field)?)
}

pub(super) fn optional_effect(value: Option<&Value>) -> Result<Option<EffectClass>> {
    value
        .map(|value| {
            value
                .as_str()
                .ok_or_else(|| {
                    EngineError::PolicyViolation("effectClass must be a string".to_owned())
                })
                .and_then(parse_effect)
        })
        .transpose()
}

pub(super) fn optional_risk(value: Option<&Value>) -> Result<Option<RiskLevel>> {
    value
        .map(|value| {
            value
                .as_str()
                .ok_or_else(|| EngineError::PolicyViolation("maxRisk must be a string".to_owned()))
                .and_then(parse_risk)
        })
        .transpose()
}

pub(super) fn optional_health(value: Option<&Value>) -> Result<Option<FunctionHealth>> {
    value
        .map(|value| {
            value
                .as_str()
                .ok_or_else(|| EngineError::PolicyViolation("health must be a string".to_owned()))
                .and_then(parse_health)
        })
        .transpose()
}

pub(super) fn optional_delivery_mode(value: Option<&Value>) -> Result<Option<DeliveryMode>> {
    value
        .map(|value| {
            value
                .as_str()
                .ok_or_else(|| {
                    EngineError::PolicyViolation("deliveryMode must be a string".to_owned())
                })
                .and_then(parse_delivery_mode)
        })
        .transpose()
}

fn parse_visibility(value: &str) -> Result<VisibilityScope> {
    match value {
        "internal" => Ok(VisibilityScope::Internal),
        "session" => Ok(VisibilityScope::Session),
        "workspace" => Ok(VisibilityScope::Workspace),
        "system" => Ok(VisibilityScope::System),
        "client" => Ok(VisibilityScope::Client),
        "worker" => Ok(VisibilityScope::Worker),
        "agent" => Ok(VisibilityScope::Agent),
        "admin" => Ok(VisibilityScope::Admin),
        _ => Err(EngineError::PolicyViolation(format!(
            "unsupported visibility {value}"
        ))),
    }
}

fn parse_effect(value: &str) -> Result<EffectClass> {
    match value {
        "pure_read" => Ok(EffectClass::PureRead),
        "deterministic_compute" => Ok(EffectClass::DeterministicCompute),
        "delegated_invocation" => Ok(EffectClass::DelegatedInvocation),
        "idempotent_write" => Ok(EffectClass::IdempotentWrite),
        "append_only_event" => Ok(EffectClass::AppendOnlyEvent),
        "reversible_side_effect" => Ok(EffectClass::ReversibleSideEffect),
        "external_side_effect" => Ok(EffectClass::ExternalSideEffect),
        "irreversible_side_effect" => Ok(EffectClass::IrreversibleSideEffect),
        _ => Err(EngineError::PolicyViolation(format!(
            "unsupported effect class {value}"
        ))),
    }
}

fn parse_risk(value: &str) -> Result<RiskLevel> {
    match value {
        "low" => Ok(RiskLevel::Low),
        "medium" => Ok(RiskLevel::Medium),
        "high" => Ok(RiskLevel::High),
        "critical" => Ok(RiskLevel::Critical),
        _ => Err(EngineError::PolicyViolation(format!(
            "unsupported risk level {value}"
        ))),
    }
}

fn parse_health(value: &str) -> Result<FunctionHealth> {
    match value {
        "healthy" => Ok(FunctionHealth::Healthy),
        "degraded" => Ok(FunctionHealth::Degraded),
        "unhealthy" => Ok(FunctionHealth::Unhealthy),
        "unknown" => Ok(FunctionHealth::Unknown),
        _ => Err(EngineError::PolicyViolation(format!(
            "unsupported health {value}"
        ))),
    }
}

fn parse_delivery_mode(value: &str) -> Result<DeliveryMode> {
    match value {
        "sync" => Ok(DeliveryMode::Sync),
        _ => Err(EngineError::PolicyViolation(format!(
            "unsupported delivery mode {value}"
        ))),
    }
}

fn parse_change_class(value: &str) -> Result<CatalogChangeClass> {
    match value {
        "availability" => Ok(CatalogChangeClass::Availability),
        "contract" => Ok(CatalogChangeClass::Contract),
        "trigger" => Ok(CatalogChangeClass::Trigger),
        "visibility" => Ok(CatalogChangeClass::Visibility),
        "health" => Ok(CatalogChangeClass::Health),
        _ => Err(EngineError::PolicyViolation(format!(
            "unsupported catalog change class {value}"
        ))),
    }
}

fn parse_change_kind(value: &str) -> Result<CatalogChangeKind> {
    match value {
        "worker_registered" => Ok(CatalogChangeKind::WorkerRegistered),
        "worker_updated" => Ok(CatalogChangeKind::WorkerUpdated),
        "worker_unregistered" => Ok(CatalogChangeKind::WorkerUnregistered),
        "function_registered" => Ok(CatalogChangeKind::FunctionRegistered),
        "function_updated" => Ok(CatalogChangeKind::FunctionUpdated),
        "function_unregistered" => Ok(CatalogChangeKind::FunctionUnregistered),
        "trigger_type_registered" => Ok(CatalogChangeKind::TriggerTypeRegistered),
        "trigger_type_updated" => Ok(CatalogChangeKind::TriggerTypeUpdated),
        "trigger_type_unregistered" => Ok(CatalogChangeKind::TriggerTypeUnregistered),
        "trigger_registered" => Ok(CatalogChangeKind::TriggerRegistered),
        "trigger_updated" => Ok(CatalogChangeKind::TriggerUpdated),
        "trigger_unregistered" => Ok(CatalogChangeKind::TriggerUnregistered),
        "visibility_changed" => Ok(CatalogChangeKind::VisibilityChanged),
        "health_changed" => Ok(CatalogChangeKind::HealthChanged),
        _ => Err(EngineError::PolicyViolation(format!(
            "unsupported catalog change kind {value}"
        ))),
    }
}

fn change_kind_str(kind: &CatalogChangeKind) -> &'static str {
    match kind {
        CatalogChangeKind::WorkerRegistered => "worker_registered",
        CatalogChangeKind::WorkerUpdated => "worker_updated",
        CatalogChangeKind::WorkerUnregistered => "worker_unregistered",
        CatalogChangeKind::FunctionRegistered => "function_registered",
        CatalogChangeKind::FunctionUpdated => "function_updated",
        CatalogChangeKind::FunctionUnregistered => "function_unregistered",
        CatalogChangeKind::TriggerTypeRegistered => "trigger_type_registered",
        CatalogChangeKind::TriggerTypeUpdated => "trigger_type_updated",
        CatalogChangeKind::TriggerTypeUnregistered => "trigger_type_unregistered",
        CatalogChangeKind::TriggerRegistered => "trigger_registered",
        CatalogChangeKind::TriggerUpdated => "trigger_updated",
        CatalogChangeKind::TriggerUnregistered => "trigger_unregistered",
        CatalogChangeKind::VisibilityChanged => "visibility_changed",
        CatalogChangeKind::HealthChanged => "health_changed",
    }
}

pub(super) fn worker_id(value: &str) -> Result<WorkerId> {
    WorkerId::new(value)
}

pub(super) fn function_id(value: &str) -> Result<FunctionId> {
    FunctionId::new(value)
}

pub(super) fn actor_id(value: &str) -> Result<ActorId> {
    ActorId::new(value)
}

pub(super) fn grant_id(value: &str) -> Result<AuthorityGrantId> {
    AuthorityGrantId::new(value)
}

pub(super) fn is_host_dispatched_primitive_namespace(namespace: &str) -> bool {
    matches!(
        namespace,
        "catalog" | "worker" | "control" | "storage" | "ui"
    )
}

pub(super) fn is_host_dispatched_primitive_function(function_id: &FunctionId) -> bool {
    is_host_dispatched_primitive_namespace(function_id.namespace())
}
