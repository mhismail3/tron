//! Resource primitive worker contracts and handlers.
//!
//! `resource::*` is the canonical capability surface for durable engine
//! resources. Higher-level modules such as artifacts, goals, claims, evidence,
//! decisions, and generated UI should compose these functions instead of
//! creating separate persistence planes.

use std::sync::Arc;

use async_trait::async_trait;
use serde_json::{Value, json};

use super::{
    PrimitiveFunctionRegistration, PrimitiveStores, RESOURCE_WORKER_ID, handled_registration,
    optional_string, optional_u64, primitive_function, required_str, required_string_owned,
};
use crate::engine::{
    CreateResource, EffectClass, EngineError, EngineResourceLocation, EngineResourceScope,
    EngineResourceVersioningMode, IdempotencyContract, InProcessFunctionHandler, Invocation,
    LinkResources, ListResources, RegisterResourceType, Result, UpdateResource, VisibilityScope,
    WorkerId,
};

pub(crate) const REGISTER_TYPE_FUNCTION: &str = "resource::register_type";
pub(crate) const CREATE_FUNCTION: &str = "resource::create";
pub(crate) const UPDATE_FUNCTION: &str = "resource::update";
pub(crate) const LINK_FUNCTION: &str = "resource::link";
pub(crate) const INSPECT_FUNCTION: &str = "resource::inspect";
pub(crate) const LIST_FUNCTION: &str = "resource::list";

pub(super) fn registrations(
    stores: &PrimitiveStores,
) -> Result<Vec<PrimitiveFunctionRegistration>> {
    let handler = Arc::new(ResourcePrimitiveHandler {
        store: stores.resources.clone(),
    });
    let mut register_type = primitive_function(
        REGISTER_TYPE_FUNCTION,
        RESOURCE_WORKER_ID,
        "register or update a typed durable resource definition",
        EffectClass::IdempotentWrite,
        "resource.admin",
    )
    .with_idempotency(IdempotencyContract::caller_system_engine_ledger())
    .with_request_schema(register_type_schema())
    .with_response_schema(json!({
        "type": "object",
        "required": ["typeDefinition"],
        "additionalProperties": false,
        "properties": {"typeDefinition": {"type": "object"}}
    }));
    register_type.visibility = VisibilityScope::Admin;
    Ok(vec![
        handled_registration(register_type, handler.clone()),
        handled_registration(
            primitive_function(
                CREATE_FUNCTION,
                RESOURCE_WORKER_ID,
                "create a typed durable engine resource",
                EffectClass::IdempotentWrite,
                "resource.write",
            )
            .with_idempotency(IdempotencyContract::caller_session_engine_ledger())
            .with_request_schema(create_schema())
            .with_response_schema(json!({
                "type": "object",
                "required": ["resource"],
                "additionalProperties": false,
                "properties": {"resource": {"type": "object"}}
            })),
            handler.clone(),
        ),
        handled_registration(
            primitive_function(
                UPDATE_FUNCTION,
                RESOURCE_WORKER_ID,
                "append a compare-and-set resource version",
                EffectClass::IdempotentWrite,
                "resource.write",
            )
            .with_idempotency(IdempotencyContract::caller_session_engine_ledger())
            .with_request_schema(update_schema())
            .with_response_schema(json!({
                "type": "object",
                "required": ["version"],
                "additionalProperties": false,
                "properties": {"version": {"type": "object"}}
            })),
            handler.clone(),
        ),
        handled_registration(
            primitive_function(
                LINK_FUNCTION,
                RESOURCE_WORKER_ID,
                "create a typed relation between two resources",
                EffectClass::IdempotentWrite,
                "resource.write",
            )
            .with_idempotency(IdempotencyContract::caller_session_engine_ledger())
            .with_request_schema(link_schema())
            .with_response_schema(json!({
                "type": "object",
                "required": ["link"],
                "additionalProperties": false,
                "properties": {"link": {"type": "object"}}
            })),
            handler.clone(),
        ),
        handled_registration(
            primitive_function(
                INSPECT_FUNCTION,
                RESOURCE_WORKER_ID,
                "inspect one resource with versions, links, and events",
                EffectClass::PureRead,
                "resource.read",
            )
            .with_request_schema(json!({
                "type": "object",
                "required": ["resourceId"],
                "additionalProperties": false,
                "properties": {"resourceId": {"type": "string"}}
            }))
            .with_response_schema(json!({
                "type": "object",
                "required": ["inspection"],
                "additionalProperties": false,
                "properties": {"inspection": {"type": ["object", "null"]}}
            })),
            handler.clone(),
        ),
        handled_registration(
            primitive_function(
                LIST_FUNCTION,
                RESOURCE_WORKER_ID,
                "list typed resources",
                EffectClass::PureRead,
                "resource.read",
            )
            .with_request_schema(list_schema())
            .with_response_schema(json!({
                "type": "object",
                "required": ["resources"],
                "additionalProperties": false,
                "properties": {"resources": {"type": "array"}}
            })),
            handler,
        ),
    ])
}

struct ResourcePrimitiveHandler {
    store: Arc<std::sync::Mutex<super::ResourceStoreBackend>>,
}

#[async_trait]
impl InProcessFunctionHandler for ResourcePrimitiveHandler {
    async fn invoke(&self, invocation: Invocation) -> Result<Value> {
        let mut store = self
            .store
            .lock()
            .map_err(|_| EngineError::HandlerFailed("resource store lock poisoned".to_owned()))?;
        match invocation.function_id.as_str() {
            REGISTER_TYPE_FUNCTION => {
                let request = RegisterResourceType {
                    kind: required_string_owned(&invocation.payload, "kind")?,
                    schema_id: required_string_owned(&invocation.payload, "schemaId")?,
                    schema: invocation
                        .payload
                        .get("schema")
                        .cloned()
                        .unwrap_or_else(|| json!({"type": "object"})),
                    lifecycle_states: string_array(&invocation.payload, "lifecycleStates")?,
                    versioning_mode: versioning_mode(&invocation.payload)?,
                    allowed_link_relations: optional_string_array(
                        &invocation.payload,
                        "allowedLinkRelations",
                    )?
                    .unwrap_or_default(),
                    default_retention: invocation
                        .payload
                        .get("defaultRetention")
                        .cloned()
                        .unwrap_or_else(|| json!({"class": "scratch"})),
                    redaction_rules: invocation
                        .payload
                        .get("redactionRules")
                        .cloned()
                        .unwrap_or_else(|| json!({"preview": "redacted"})),
                    materialization_rules: invocation
                        .payload
                        .get("materializationRules")
                        .cloned()
                        .unwrap_or_else(|| json!({})),
                    required_capabilities: invocation
                        .payload
                        .get("requiredCapabilities")
                        .cloned()
                        .unwrap_or_else(|| json!({})),
                    owner_worker_id: optional_worker_id(&invocation.payload, "ownerWorkerId")?
                        .unwrap_or_else(|| WorkerId::new(RESOURCE_WORKER_ID).unwrap()),
                };
                Ok(json!({ "typeDefinition": store.register_type(request)? }))
            }
            CREATE_FUNCTION => {
                let request = CreateResource {
                    resource_id: optional_string(invocation.payload.get("resourceId"))?,
                    kind: required_string_owned(&invocation.payload, "kind")?,
                    schema_id: optional_string(invocation.payload.get("schemaId"))?,
                    scope: resource_scope_from_payload(&invocation, false)?,
                    owner_worker_id: optional_worker_id(&invocation.payload, "ownerWorkerId")?
                        .unwrap_or_else(|| WorkerId::new(RESOURCE_WORKER_ID).unwrap()),
                    owner_actor_id: invocation.causal_context.actor_id.clone(),
                    lifecycle: optional_string(invocation.payload.get("lifecycle"))?,
                    policy: invocation
                        .payload
                        .get("policy")
                        .cloned()
                        .unwrap_or_else(|| json!({})),
                    initial_payload: invocation.payload.get("payload").cloned(),
                    locations: locations(&invocation.payload)?,
                    trace_id: invocation.causal_context.trace_id.clone(),
                    invocation_id: Some(invocation.id.clone()),
                };
                Ok(json!({ "resource": store.create(request)? }))
            }
            UPDATE_FUNCTION => {
                let request = UpdateResource {
                    resource_id: required_string_owned(&invocation.payload, "resourceId")?,
                    expected_current_version_id: optional_string(
                        invocation.payload.get("expectedCurrentVersionId"),
                    )?,
                    lifecycle: optional_string(invocation.payload.get("lifecycle"))?,
                    payload: invocation.payload.get("payload").cloned().ok_or_else(|| {
                        EngineError::PolicyViolation("resource update requires payload".to_owned())
                    })?,
                    locations: locations(&invocation.payload)?,
                    trace_id: invocation.causal_context.trace_id.clone(),
                    invocation_id: Some(invocation.id.clone()),
                };
                Ok(json!({ "version": store.update(request)? }))
            }
            LINK_FUNCTION => {
                let request = LinkResources {
                    source_resource_id: required_string_owned(
                        &invocation.payload,
                        "sourceResourceId",
                    )?,
                    target_resource_id: required_string_owned(
                        &invocation.payload,
                        "targetResourceId",
                    )?,
                    relation: required_string_owned(&invocation.payload, "relation")?,
                    metadata: invocation
                        .payload
                        .get("metadata")
                        .cloned()
                        .unwrap_or_else(|| json!({})),
                    trace_id: invocation.causal_context.trace_id.clone(),
                    invocation_id: Some(invocation.id.clone()),
                };
                Ok(json!({ "link": store.link(request)? }))
            }
            INSPECT_FUNCTION => {
                let resource_id = required_str(&invocation.payload, "resourceId")?;
                Ok(json!({ "inspection": store.inspect(resource_id)? }))
            }
            LIST_FUNCTION => {
                let filter = ListResources {
                    kind: optional_string(invocation.payload.get("kind"))?,
                    scope: optional_resource_scope_filter(&invocation)?,
                    lifecycle: optional_string(invocation.payload.get("lifecycle"))?,
                    limit: optional_u64(invocation.payload.get("limit"))?.unwrap_or(100) as usize,
                };
                Ok(json!({ "resources": store.list(filter)? }))
            }
            _ => Err(EngineError::NotFound {
                kind: "function",
                id: invocation.function_id.to_string(),
            }),
        }
    }
}

fn optional_resource_scope_filter(invocation: &Invocation) -> Result<Option<EngineResourceScope>> {
    if invocation.payload.get("scope").is_none() {
        return Ok(None);
    }
    resource_scope_from_payload(invocation, false).map(Some)
}

fn register_type_schema() -> Value {
    json!({
        "type": "object",
        "required": ["kind", "schemaId", "lifecycleStates"],
        "additionalProperties": false,
        "properties": {
            "kind": {"type": "string"},
            "schemaId": {"type": "string"},
            "schema": {"type": "object"},
            "lifecycleStates": {"type": "array", "items": {"type": "string"}, "minItems": 1},
            "versioningMode": {"type": "string", "enum": ["append_only", "current_pointer"]},
            "allowedLinkRelations": {"type": "array", "items": {"type": "string"}},
            "defaultRetention": {"type": "object"},
            "redactionRules": {"type": "object"},
            "materializationRules": {"type": "object"},
            "requiredCapabilities": {"type": "object"},
            "ownerWorkerId": {"type": "string"}
        }
    })
}

fn create_schema() -> Value {
    json!({
        "type": "object",
        "required": ["kind"],
        "additionalProperties": false,
        "properties": resource_properties(true)
    })
}

fn update_schema() -> Value {
    json!({
        "type": "object",
        "required": ["resourceId", "payload"],
        "additionalProperties": false,
        "properties": {
            "resourceId": {"type": "string"},
            "expectedCurrentVersionId": {"type": "string"},
            "lifecycle": {"type": "string"},
            "payload": {},
            "locations": locations_schema()
        }
    })
}

fn link_schema() -> Value {
    json!({
        "type": "object",
        "required": ["sourceResourceId", "targetResourceId", "relation"],
        "additionalProperties": false,
        "properties": {
            "sourceResourceId": {"type": "string"},
            "targetResourceId": {"type": "string"},
            "relation": {"type": "string"},
            "metadata": {"type": "object"}
        }
    })
}

fn list_schema() -> Value {
    json!({
        "type": "object",
        "additionalProperties": false,
        "properties": {
            "kind": {"type": "string"},
            "scope": {"type": "string", "enum": ["system", "workspace", "session"]},
            "sessionId": {"type": "string"},
            "workspaceId": {"type": "string"},
            "lifecycle": {"type": "string"},
            "limit": {"type": "integer"}
        }
    })
}

fn resource_properties(include_creation: bool) -> Value {
    let mut properties = serde_json::Map::new();
    if include_creation {
        properties.insert("resourceId".to_owned(), json!({"type": "string"}));
        properties.insert("kind".to_owned(), json!({"type": "string"}));
        properties.insert("schemaId".to_owned(), json!({"type": "string"}));
        properties.insert("ownerWorkerId".to_owned(), json!({"type": "string"}));
    }
    properties.insert(
        "scope".to_owned(),
        json!({"type": "string", "enum": ["system", "workspace", "session"]}),
    );
    properties.insert("sessionId".to_owned(), json!({"type": "string"}));
    properties.insert("workspaceId".to_owned(), json!({"type": "string"}));
    properties.insert("lifecycle".to_owned(), json!({"type": "string"}));
    properties.insert("policy".to_owned(), json!({"type": "object"}));
    properties.insert("payload".to_owned(), json!({}));
    properties.insert("locations".to_owned(), locations_schema());
    Value::Object(properties)
}

fn locations_schema() -> Value {
    json!({
        "type": "array",
        "items": {
            "type": "object",
            "required": ["kind", "uri"],
            "additionalProperties": false,
            "properties": {
                "kind": {"type": "string"},
                "uri": {"type": "string"},
                "mimeType": {"type": "string"},
                "sizeBytes": {"type": "integer"}
            }
        }
    })
}

fn resource_scope_from_payload(
    invocation: &Invocation,
    allow_absent: bool,
) -> Result<EngineResourceScope> {
    let explicit = optional_string(invocation.payload.get("scope"))?;
    match explicit.as_deref() {
        Some("system") => Ok(EngineResourceScope::System),
        Some("workspace") => {
            let workspace_id = optional_string(invocation.payload.get("workspaceId"))?
                .or(invocation.causal_context.workspace_id.clone())
                .ok_or_else(|| {
                    EngineError::PolicyViolation(
                        "workspace-scoped resource requires workspaceId".to_owned(),
                    )
                })?;
            Ok(EngineResourceScope::Workspace(workspace_id))
        }
        Some("session") => {
            let session_id = optional_string(invocation.payload.get("sessionId"))?
                .or(invocation.causal_context.session_id.clone())
                .ok_or_else(|| {
                    EngineError::PolicyViolation(
                        "session-scoped resource requires sessionId".to_owned(),
                    )
                })?;
            Ok(EngineResourceScope::Session(session_id))
        }
        Some(other) => Err(EngineError::PolicyViolation(format!(
            "unsupported resource scope {other}"
        ))),
        None if allow_absent => Err(EngineError::PolicyViolation(
            "resource scope filter absent".to_owned(),
        )),
        None => {
            if let Some(workspace_id) = &invocation.causal_context.workspace_id {
                Ok(EngineResourceScope::Workspace(workspace_id.clone()))
            } else if let Some(session_id) = &invocation.causal_context.session_id {
                Ok(EngineResourceScope::Session(session_id.clone()))
            } else {
                Ok(EngineResourceScope::System)
            }
        }
    }
}

fn versioning_mode(payload: &Value) -> Result<EngineResourceVersioningMode> {
    match optional_string(payload.get("versioningMode"))?
        .unwrap_or_else(|| "append_only".to_owned())
        .as_str()
    {
        "append_only" => Ok(EngineResourceVersioningMode::AppendOnly),
        "current_pointer" => Ok(EngineResourceVersioningMode::CurrentPointer),
        other => Err(EngineError::PolicyViolation(format!(
            "unsupported resource versioning mode {other}"
        ))),
    }
}

fn locations(payload: &Value) -> Result<Vec<EngineResourceLocation>> {
    payload
        .get("locations")
        .cloned()
        .map(serde_json::from_value)
        .transpose()
        .map_err(|error| {
            EngineError::PolicyViolation(format!("invalid resource locations: {error}"))
        })
        .map(Option::unwrap_or_default)
}

fn string_array(payload: &Value, field: &str) -> Result<Vec<String>> {
    optional_string_array(payload, field)?.ok_or_else(|| {
        EngineError::PolicyViolation(format!("required field {field} must be a string array"))
    })
}

fn optional_string_array(payload: &Value, field: &str) -> Result<Option<Vec<String>>> {
    let Some(value) = payload.get(field) else {
        return Ok(None);
    };
    let Some(items) = value.as_array() else {
        return Err(EngineError::PolicyViolation(format!(
            "field {field} must be an array"
        )));
    };
    items
        .iter()
        .map(|item| {
            item.as_str().map(str::to_owned).ok_or_else(|| {
                EngineError::PolicyViolation(format!("field {field} must be a string array"))
            })
        })
        .collect::<Result<Vec<_>>>()
        .map(Some)
}

fn optional_worker_id(payload: &Value, field: &str) -> Result<Option<WorkerId>> {
    optional_string(payload.get(field))?
        .map(WorkerId::new)
        .transpose()
}
