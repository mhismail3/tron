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
use crate::engine::{EngineResource, EngineResourceInspection, EngineResourceVersion};

pub(crate) const REGISTER_TYPE_FUNCTION: &str = "resource::register_type";
pub(crate) const CREATE_FUNCTION: &str = "resource::create";
pub(crate) const UPDATE_FUNCTION: &str = "resource::update";
pub(crate) const LINK_FUNCTION: &str = "resource::link";
pub(crate) const INSPECT_FUNCTION: &str = "resource::inspect";
pub(crate) const LIST_FUNCTION: &str = "resource::list";
pub(crate) const ARTIFACT_CREATE_FUNCTION: &str = "artifact::create";
pub(crate) const ARTIFACT_UPDATE_FUNCTION: &str = "artifact::update";
pub(crate) const ARTIFACT_PROMOTE_FUNCTION: &str = "artifact::promote";
pub(crate) const ARTIFACT_DISCARD_FUNCTION: &str = "artifact::discard";
pub(crate) const ARTIFACT_INSPECT_FUNCTION: &str = "artifact::inspect";
pub(crate) const GOAL_CREATE_FUNCTION: &str = "goal::create";
pub(crate) const GOAL_COMPLETE_FUNCTION: &str = "goal::complete";
pub(crate) const CLAIM_ATTACH_FUNCTION: &str = "claim::attach";
pub(crate) const EVIDENCE_ATTACH_FUNCTION: &str = "evidence::attach";
pub(crate) const DECISION_CREATE_FUNCTION: &str = "decision::create";

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
    let mut registrations = vec![
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
            handler.clone(),
        ),
    ];
    registrations.extend(resource_wrapper_registrations(handler)?);
    Ok(registrations)
}

struct ResourcePrimitiveHandler {
    store: Arc<std::sync::Mutex<super::ResourceStoreBackend>>,
}

fn resource_wrapper_registrations(
    handler: Arc<ResourcePrimitiveHandler>,
) -> Result<Vec<PrimitiveFunctionRegistration>> {
    let create_response = json!({
        "type": "object",
        "required": ["resource"],
        "additionalProperties": false,
        "properties": {"resource": {"type": "object"}}
    });
    let version_response = json!({
        "type": "object",
        "required": ["version"],
        "additionalProperties": false,
        "properties": {"version": {"type": "object"}}
    });
    let inspect_response = json!({
        "type": "object",
        "required": ["inspection"],
        "additionalProperties": false,
        "properties": {"inspection": {"type": ["object", "null"]}}
    });
    Ok(vec![
        handled_registration(
            resource_wrapper_function(
                ARTIFACT_CREATE_FUNCTION,
                "create an artifact resource",
                EffectClass::IdempotentWrite,
            )
            .with_request_schema(wrapper_create_schema())
            .with_response_schema(create_response.clone()),
            handler.clone(),
        ),
        handled_registration(
            resource_wrapper_function(
                ARTIFACT_UPDATE_FUNCTION,
                "append an artifact resource version",
                EffectClass::IdempotentWrite,
            )
            .with_request_schema(wrapper_update_schema())
            .with_response_schema(version_response.clone()),
            handler.clone(),
        ),
        handled_registration(
            resource_wrapper_function(
                ARTIFACT_PROMOTE_FUNCTION,
                "promote an artifact resource",
                EffectClass::IdempotentWrite,
            )
            .with_request_schema(wrapper_lifecycle_schema())
            .with_response_schema(version_response.clone()),
            handler.clone(),
        ),
        handled_registration(
            resource_wrapper_function(
                ARTIFACT_DISCARD_FUNCTION,
                "discard an artifact resource",
                EffectClass::IdempotentWrite,
            )
            .with_request_schema(wrapper_lifecycle_schema())
            .with_response_schema(version_response.clone()),
            handler.clone(),
        ),
        handled_registration(
            resource_wrapper_function(
                ARTIFACT_INSPECT_FUNCTION,
                "inspect an artifact resource",
                EffectClass::PureRead,
            )
            .with_request_schema(json!({
                "type": "object",
                "required": ["resourceId"],
                "additionalProperties": false,
                "properties": {"resourceId": {"type": "string"}}
            }))
            .with_response_schema(inspect_response),
            handler.clone(),
        ),
        handled_registration(
            resource_wrapper_function(
                GOAL_CREATE_FUNCTION,
                "create a goal resource",
                EffectClass::IdempotentWrite,
            )
            .with_request_schema(wrapper_create_schema())
            .with_response_schema(create_response.clone()),
            handler.clone(),
        ),
        handled_registration(
            resource_wrapper_function(
                GOAL_COMPLETE_FUNCTION,
                "complete a goal with a decision resource",
                EffectClass::IdempotentWrite,
            )
            .with_request_schema(goal_complete_schema())
            .with_response_schema(json!({
                "type": "object",
                "required": ["goalVersion", "decision", "link"],
                "additionalProperties": false,
                "properties": {
                    "goalVersion": {"type": "object"},
                    "decision": {"type": "object"},
                    "link": {"type": "object"}
                }
            })),
            handler.clone(),
        ),
        handled_registration(
            resource_wrapper_function(
                CLAIM_ATTACH_FUNCTION,
                "create a claim resource and attach it to another resource",
                EffectClass::IdempotentWrite,
            )
            .with_request_schema(attach_schema())
            .with_response_schema(attach_response_schema()),
            handler.clone(),
        ),
        handled_registration(
            resource_wrapper_function(
                EVIDENCE_ATTACH_FUNCTION,
                "create an evidence resource and attach it to another resource",
                EffectClass::IdempotentWrite,
            )
            .with_request_schema(attach_schema())
            .with_response_schema(attach_response_schema()),
            handler.clone(),
        ),
        handled_registration(
            resource_wrapper_function(
                DECISION_CREATE_FUNCTION,
                "create a decision resource",
                EffectClass::IdempotentWrite,
            )
            .with_request_schema(wrapper_create_schema())
            .with_response_schema(create_response),
            handler,
        ),
    ])
}

fn resource_wrapper_function(
    id: &str,
    description: &str,
    effect: EffectClass,
) -> crate::engine::FunctionDefinition {
    let authority = if effect.is_mutating() {
        "resource.write"
    } else {
        "resource.read"
    };
    let function = primitive_function(id, RESOURCE_WORKER_ID, description, effect, authority);
    if effect.requires_idempotency() {
        function.with_idempotency(IdempotencyContract::caller_session_engine_ledger())
    } else {
        function
    }
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
            ARTIFACT_CREATE_FUNCTION => Ok(json!({
                "resource": create_wrapper_resource(&mut store, &invocation, "artifact", None)?
            })),
            ARTIFACT_UPDATE_FUNCTION => Ok(json!({
                "version": update_wrapper_resource(&mut store, &invocation, None)?
            })),
            ARTIFACT_PROMOTE_FUNCTION => Ok(json!({
                "version": lifecycle_wrapper_resource(&mut store, &invocation, "artifact", "promoted")?
            })),
            ARTIFACT_DISCARD_FUNCTION => Ok(json!({
                "version": lifecycle_wrapper_resource(&mut store, &invocation, "artifact", "discarded")?
            })),
            ARTIFACT_INSPECT_FUNCTION => {
                let resource_id = required_str(&invocation.payload, "resourceId")?;
                let inspection = store.inspect(resource_id)?;
                ensure_inspected_kind(&inspection, "artifact")?;
                Ok(json!({ "inspection": inspection }))
            }
            GOAL_CREATE_FUNCTION => Ok(json!({
                "resource": create_wrapper_resource(&mut store, &invocation, "goal", None)?
            })),
            GOAL_COMPLETE_FUNCTION => {
                let goal_id = required_string_owned(&invocation.payload, "goalResourceId")?;
                let decision_payload =
                    invocation.payload.get("decision").cloned().ok_or_else(|| {
                        EngineError::PolicyViolation(
                            "goal::complete requires decision payload".to_owned(),
                        )
                    })?;
                let decision = create_typed_resource(
                    &mut store,
                    &invocation,
                    "decision",
                    Some("final"),
                    Some(decision_payload),
                )?;
                let goal_version = lifecycle_resource_by_id(
                    &mut store,
                    &invocation,
                    &goal_id,
                    "goal",
                    "completed",
                )?;
                let link = store.link(LinkResources {
                    source_resource_id: goal_id,
                    target_resource_id: decision.resource_id.clone(),
                    relation: "decided_by".to_owned(),
                    metadata: invocation
                        .payload
                        .get("metadata")
                        .cloned()
                        .unwrap_or_else(|| json!({})),
                    trace_id: invocation.causal_context.trace_id.clone(),
                    invocation_id: Some(invocation.id.clone()),
                })?;
                Ok(json!({
                    "goalVersion": goal_version,
                    "decision": decision,
                    "link": link,
                }))
            }
            CLAIM_ATTACH_FUNCTION => {
                let (resource, link) =
                    create_and_attach_resource(&mut store, &invocation, "claim", "claims_about")?;
                Ok(json!({ "resource": resource, "link": link }))
            }
            EVIDENCE_ATTACH_FUNCTION => {
                let (resource, link) = create_and_attach_resource(
                    &mut store,
                    &invocation,
                    "evidence",
                    "evidence_for",
                )?;
                Ok(json!({ "resource": resource, "link": link }))
            }
            DECISION_CREATE_FUNCTION => Ok(json!({
                "resource": create_wrapper_resource(&mut store, &invocation, "decision", Some("final"))?
            })),
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

fn create_wrapper_resource(
    store: &mut super::ResourceStoreBackend,
    invocation: &Invocation,
    kind: &str,
    lifecycle: Option<&str>,
) -> Result<EngineResource> {
    let payload = invocation.payload.get("payload").cloned().ok_or_else(|| {
        EngineError::PolicyViolation(format!("{} requires payload", invocation.function_id))
    })?;
    create_typed_resource(store, invocation, kind, lifecycle, Some(payload))
}

fn create_typed_resource(
    store: &mut super::ResourceStoreBackend,
    invocation: &Invocation,
    kind: &str,
    lifecycle: Option<&str>,
    payload: Option<Value>,
) -> Result<EngineResource> {
    store.create(CreateResource {
        resource_id: optional_string(invocation.payload.get("resourceId"))?,
        kind: kind.to_owned(),
        schema_id: None,
        scope: resource_scope_from_payload(invocation, false)?,
        owner_worker_id: WorkerId::new(RESOURCE_WORKER_ID).unwrap(),
        owner_actor_id: invocation.causal_context.actor_id.clone(),
        lifecycle: lifecycle
            .map(str::to_owned)
            .or(optional_string(invocation.payload.get("lifecycle"))?),
        policy: invocation
            .payload
            .get("policy")
            .cloned()
            .unwrap_or_else(|| json!({})),
        initial_payload: payload,
        locations: locations(&invocation.payload)?,
        trace_id: invocation.causal_context.trace_id.clone(),
        invocation_id: Some(invocation.id.clone()),
    })
}

fn update_wrapper_resource(
    store: &mut super::ResourceStoreBackend,
    invocation: &Invocation,
    lifecycle: Option<&str>,
) -> Result<EngineResourceVersion> {
    store.update(UpdateResource {
        resource_id: required_string_owned(&invocation.payload, "resourceId")?,
        expected_current_version_id: optional_string(
            invocation.payload.get("expectedCurrentVersionId"),
        )?,
        lifecycle: lifecycle.map(str::to_owned),
        payload: invocation.payload.get("payload").cloned().ok_or_else(|| {
            EngineError::PolicyViolation(format!("{} requires payload", invocation.function_id))
        })?,
        locations: locations(&invocation.payload)?,
        trace_id: invocation.causal_context.trace_id.clone(),
        invocation_id: Some(invocation.id.clone()),
    })
}

fn lifecycle_wrapper_resource(
    store: &mut super::ResourceStoreBackend,
    invocation: &Invocation,
    kind: &str,
    lifecycle: &str,
) -> Result<EngineResourceVersion> {
    let resource_id = required_string_owned(&invocation.payload, "resourceId")?;
    lifecycle_resource_by_id(store, invocation, &resource_id, kind, lifecycle)
}

fn lifecycle_resource_by_id(
    store: &mut super::ResourceStoreBackend,
    invocation: &Invocation,
    resource_id: &str,
    kind: &str,
    lifecycle: &str,
) -> Result<EngineResourceVersion> {
    let inspection = store
        .inspect(resource_id)?
        .ok_or_else(|| EngineError::NotFound {
            kind: "resource",
            id: resource_id.to_owned(),
        })?;
    ensure_resource_kind(&inspection, kind)?;
    let caller_expected = optional_string(invocation.payload.get("expectedCurrentVersionId"))?;
    if caller_expected.is_some()
        && caller_expected.as_ref() != inspection.resource.current_version_id.as_ref()
    {
        return Err(EngineError::PolicyViolation(format!(
            "resource {resource_id} version conflict: expected {:?}, actual {:?}",
            caller_expected, inspection.resource.current_version_id
        )));
    }
    let payload = current_payload(&inspection)?;
    let expected_current_version_id = caller_expected.or(inspection.resource.current_version_id);
    store.update(UpdateResource {
        resource_id: resource_id.to_owned(),
        expected_current_version_id,
        lifecycle: Some(lifecycle.to_owned()),
        payload,
        locations: Vec::new(),
        trace_id: invocation.causal_context.trace_id.clone(),
        invocation_id: Some(invocation.id.clone()),
    })
}

fn create_and_attach_resource(
    store: &mut super::ResourceStoreBackend,
    invocation: &Invocation,
    kind: &str,
    default_relation: &str,
) -> Result<(EngineResource, crate::engine::EngineResourceLink)> {
    let resource = create_wrapper_resource(store, invocation, kind, None)?;
    let target_resource_id = required_string_owned(&invocation.payload, "targetResourceId")?;
    let relation = optional_string(invocation.payload.get("relation"))?
        .unwrap_or_else(|| default_relation.to_owned());
    let link = store.link(LinkResources {
        source_resource_id: resource.resource_id.clone(),
        target_resource_id,
        relation,
        metadata: invocation
            .payload
            .get("metadata")
            .cloned()
            .unwrap_or_else(|| json!({})),
        trace_id: invocation.causal_context.trace_id.clone(),
        invocation_id: Some(invocation.id.clone()),
    })?;
    Ok((resource, link))
}

fn ensure_inspected_kind(
    inspection: &Option<EngineResourceInspection>,
    expected: &str,
) -> Result<()> {
    if let Some(inspection) = inspection {
        ensure_resource_kind(inspection, expected)?;
    }
    Ok(())
}

fn ensure_resource_kind(inspection: &EngineResourceInspection, expected: &str) -> Result<()> {
    if inspection.resource.kind == expected {
        Ok(())
    } else {
        Err(EngineError::PolicyViolation(format!(
            "resource {} is kind {}, expected {expected}",
            inspection.resource.resource_id, inspection.resource.kind
        )))
    }
}

fn current_payload(inspection: &EngineResourceInspection) -> Result<Value> {
    inspection
        .resource
        .current_version_id
        .as_ref()
        .and_then(|current| {
            inspection
                .versions
                .iter()
                .find(|version| &version.version_id == current)
        })
        .map(|version| version.payload.clone())
        .ok_or_else(|| {
            EngineError::PolicyViolation(format!(
                "resource {} has no current payload",
                inspection.resource.resource_id
            ))
        })
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

fn wrapper_create_schema() -> Value {
    json!({
        "type": "object",
        "required": ["payload"],
        "additionalProperties": false,
        "properties": {
            "resourceId": {"type": "string"},
            "scope": {"type": "string", "enum": ["system", "workspace", "session"]},
            "sessionId": {"type": "string"},
            "workspaceId": {"type": "string"},
            "lifecycle": {"type": "string"},
            "policy": {"type": "object"},
            "payload": {},
            "locations": locations_schema()
        }
    })
}

fn wrapper_update_schema() -> Value {
    json!({
        "type": "object",
        "required": ["resourceId", "payload"],
        "additionalProperties": false,
        "properties": {
            "resourceId": {"type": "string"},
            "expectedCurrentVersionId": {"type": "string"},
            "payload": {},
            "locations": locations_schema()
        }
    })
}

fn wrapper_lifecycle_schema() -> Value {
    json!({
        "type": "object",
        "required": ["resourceId"],
        "additionalProperties": false,
        "properties": {
            "resourceId": {"type": "string"},
            "expectedCurrentVersionId": {"type": "string"}
        }
    })
}

fn goal_complete_schema() -> Value {
    json!({
        "type": "object",
        "required": ["goalResourceId", "decision"],
        "additionalProperties": false,
        "properties": {
            "goalResourceId": {"type": "string"},
            "decision": {"type": "object"},
            "metadata": {"type": "object"}
        }
    })
}

fn attach_schema() -> Value {
    json!({
        "type": "object",
        "required": ["targetResourceId", "payload"],
        "additionalProperties": false,
        "properties": {
            "resourceId": {"type": "string"},
            "targetResourceId": {"type": "string"},
            "relation": {"type": "string"},
            "scope": {"type": "string", "enum": ["system", "workspace", "session"]},
            "sessionId": {"type": "string"},
            "workspaceId": {"type": "string"},
            "lifecycle": {"type": "string"},
            "policy": {"type": "object"},
            "payload": {},
            "locations": locations_schema(),
            "metadata": {"type": "object"}
        }
    })
}

fn attach_response_schema() -> Value {
    json!({
        "type": "object",
        "required": ["resource", "link"],
        "additionalProperties": false,
        "properties": {
            "resource": {"type": "object"},
            "link": {"type": "object"}
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
