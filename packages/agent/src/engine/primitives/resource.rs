//! Resource primitive worker contracts and handlers.
//!
//! `resource::*` is the canonical capability surface for durable engine
//! resources. Higher-level modules such as artifacts, goals, claims, evidence,
//! decisions, and generated UI should compose these functions instead of
//! creating separate persistence planes.

use std::path::{Path, PathBuf};
use std::sync::Arc;

use async_trait::async_trait;
use serde_json::{Value, json};
use sha2::{Digest, Sha256};

use super::{
    PrimitiveFunctionRegistration, PrimitiveStores, RESOURCE_WORKER_ID, handled_registration,
    optional_string, optional_u64, primitive_function, required_str, required_string_owned,
};
use crate::engine::{
    CreateResource, DurableOutputContract, EffectClass, EngineError, EngineResourceLocation,
    EngineResourceScope, EngineResourceVersioningMode, IdempotencyContract,
    InProcessFunctionHandler, Invocation, LinkResources, ListResources, RegisterResourceType,
    Result, UpdateResource, VisibilityScope, WorkerId,
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
pub(crate) const MATERIALIZED_FILE_CREATE_FUNCTION: &str = "materialized_file::create";
pub(crate) const MATERIALIZED_FILE_READ_FUNCTION: &str = "materialized_file::read";
pub(crate) const MATERIALIZED_FILE_UPDATE_FUNCTION: &str = "materialized_file::update";
pub(crate) const MATERIALIZED_FILE_PROMOTE_FUNCTION: &str = "materialized_file::promote";
pub(crate) const MATERIALIZED_FILE_DISCARD_FUNCTION: &str = "materialized_file::discard";
pub(crate) const MATERIALIZED_FILE_INSPECT_FUNCTION: &str = "materialized_file::inspect";
pub(crate) const MATERIALIZED_FILE_HASH_VERIFY_FUNCTION: &str = "materialized_file::hash_verify";
pub(crate) const PATCH_PROPOSE_FUNCTION: &str = "patch::propose";
pub(crate) const PATCH_APPLY_FUNCTION: &str = "patch::apply";
pub(crate) const PATCH_MERGE_FUNCTION: &str = "patch::merge";
pub(crate) const ARTIFACT_MATERIALIZE_FUNCTION: &str = "artifact::materialize";

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
                "required": ["resource", "resourceRefs"],
                "additionalProperties": false,
                "properties": {
                    "resource": {"type": "object"},
                    "resourceRefs": resource_refs_schema()
                }
            }))
            .with_output_contract(DurableOutputContract::resource_backed(["*"])),
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
                "required": ["version", "resourceRefs"],
                "additionalProperties": false,
                "properties": {
                    "version": {"type": "object"},
                    "resourceRefs": resource_refs_schema()
                }
            }))
            .with_output_contract(DurableOutputContract::resource_backed(["*"])),
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
        "required": ["resource", "resourceRefs"],
        "additionalProperties": false,
        "properties": {
            "resource": {"type": "object"},
            "resourceRefs": resource_refs_schema()
        }
    });
    let version_response = json!({
        "type": "object",
        "required": ["version", "resourceRefs"],
        "additionalProperties": false,
        "properties": {
            "version": {"type": "object"},
            "resource": {"type": "object"},
            "resourceRefs": resource_refs_schema()
        }
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
                ARTIFACT_MATERIALIZE_FUNCTION,
                "materialize an artifact resource into a file resource",
                EffectClass::IdempotentWrite,
            )
            .with_request_schema(artifact_materialize_schema())
            .with_response_schema(json!({
                "type": "object",
                "required": ["artifact", "materializedFile", "version", "resourceRefs"],
                "additionalProperties": false,
                "properties": {
                    "artifact": {"type": "object"},
                    "materializedFile": {"type": "object"},
                    "version": {"type": "object"},
                    "resourceRefs": resource_refs_schema()
                }
            }))
            .with_output_contract(DurableOutputContract::resource_backed([
                "materialized_file",
            ])),
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
                "required": ["goalVersion", "decision", "link", "resourceRefs"],
                "additionalProperties": false,
                "properties": {
                    "goalVersion": {"type": "object"},
                    "decision": {"type": "object"},
                    "link": {"type": "object"},
                    "resourceRefs": resource_refs_schema()
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
            .with_response_schema(create_response.clone()),
            handler.clone(),
        ),
        handled_registration(
            resource_wrapper_function(
                MATERIALIZED_FILE_CREATE_FUNCTION,
                "create a materialized file resource",
                EffectClass::IdempotentWrite,
            )
            .with_request_schema(materialized_file_create_schema())
            .with_response_schema(version_response.clone())
            .with_output_contract(DurableOutputContract::resource_backed([
                "materialized_file",
            ])),
            handler.clone(),
        ),
        handled_registration(
            resource_wrapper_function(
                MATERIALIZED_FILE_READ_FUNCTION,
                "read a materialized file resource",
                EffectClass::PureRead,
            )
            .with_request_schema(json!({
                "type": "object",
                "required": ["resourceId"],
                "additionalProperties": false,
                "properties": {"resourceId": {"type": "string"}}
            }))
            .with_response_schema(json!({
                "type": "object",
                "required": ["content", "resource"],
                "additionalProperties": false,
                "properties": {"content": {"type": "string"}, "resource": {"type": "object"}}
            })),
            handler.clone(),
        ),
        handled_registration(
            resource_wrapper_function(
                MATERIALIZED_FILE_UPDATE_FUNCTION,
                "append a materialized file resource version",
                EffectClass::IdempotentWrite,
            )
            .with_request_schema(materialized_file_update_schema())
            .with_response_schema(version_response.clone())
            .with_output_contract(DurableOutputContract::resource_backed([
                "materialized_file",
            ])),
            handler.clone(),
        ),
        handled_registration(
            resource_wrapper_function(
                MATERIALIZED_FILE_PROMOTE_FUNCTION,
                "promote a materialized file resource",
                EffectClass::IdempotentWrite,
            )
            .with_request_schema(wrapper_lifecycle_schema())
            .with_response_schema(version_response.clone())
            .with_output_contract(DurableOutputContract::resource_backed([
                "materialized_file",
            ])),
            handler.clone(),
        ),
        handled_registration(
            resource_wrapper_function(
                MATERIALIZED_FILE_DISCARD_FUNCTION,
                "discard a materialized file resource",
                EffectClass::IdempotentWrite,
            )
            .with_request_schema(wrapper_lifecycle_schema())
            .with_response_schema(version_response.clone())
            .with_output_contract(DurableOutputContract::resource_backed([
                "materialized_file",
            ])),
            handler.clone(),
        ),
        handled_registration(
            resource_wrapper_function(
                MATERIALIZED_FILE_INSPECT_FUNCTION,
                "inspect a materialized file resource",
                EffectClass::PureRead,
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
            resource_wrapper_function(
                MATERIALIZED_FILE_HASH_VERIFY_FUNCTION,
                "verify materialized file bytes against their content hash",
                EffectClass::IdempotentWrite,
            )
            .with_request_schema(json!({
                "type": "object",
                "required": ["resourceId"],
                "additionalProperties": false,
                "properties": {"resourceId": {"type": "string"}}
            }))
            .with_response_schema(version_response.clone())
            .with_output_contract(DurableOutputContract::resource_backed([
                "materialized_file",
            ])),
            handler.clone(),
        ),
        handled_registration(
            resource_wrapper_function(
                PATCH_PROPOSE_FUNCTION,
                "create a patch proposal resource",
                EffectClass::IdempotentWrite,
            )
            .with_request_schema(patch_propose_schema())
            .with_response_schema(create_response.clone())
            .with_output_contract(DurableOutputContract::resource_backed(["patch_proposal"])),
            handler.clone(),
        ),
        handled_registration(
            resource_wrapper_function(
                PATCH_APPLY_FUNCTION,
                "apply a patch proposal and produce file resources",
                EffectClass::IdempotentWrite,
            )
            .with_request_schema(patch_apply_schema())
            .with_response_schema(json!({
                "type": "object",
                "required": ["patch", "version", "resourceRefs"],
                "additionalProperties": false,
                "properties": {
                    "patch": {"type": "object"},
                    "version": {"type": "object"},
                    "resourceRefs": resource_refs_schema()
                }
            }))
            .with_output_contract(DurableOutputContract::resource_backed([
                "patch_proposal",
                "materialized_file",
            ])),
            handler.clone(),
        ),
        handled_registration(
            resource_wrapper_function(
                PATCH_MERGE_FUNCTION,
                "merge a patch proposal resource",
                EffectClass::IdempotentWrite,
            )
            .with_request_schema(wrapper_lifecycle_schema())
            .with_response_schema(version_response)
            .with_output_contract(DurableOutputContract::resource_backed(["patch_proposal"])),
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
        function
            .with_idempotency(IdempotencyContract::caller_session_engine_ledger())
            .with_output_contract(DurableOutputContract::resource_backed(["*"]))
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
                let resource = store.create(request)?;
                let resource_ref = resource_ref_from_resource(&resource, "created");
                Ok(json!({
                    "resource": resource,
                    "resourceRefs": [resource_ref],
                }))
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
                    state: None,
                    locations: locations(&invocation.payload)?,
                    trace_id: invocation.causal_context.trace_id.clone(),
                    invocation_id: Some(invocation.id.clone()),
                };
                let version = store.update(request)?;
                let kind = resource_kind_for_version(&store, &version)?;
                let resource_ref = resource_ref_from_version(&version, &kind, "updated");
                Ok(json!({
                    "version": version,
                    "resourceRefs": [resource_ref],
                }))
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
            ARTIFACT_CREATE_FUNCTION => {
                wrapper_create_response(&mut store, &invocation, "artifact", None, "created")
            }
            ARTIFACT_UPDATE_FUNCTION => {
                let version = update_wrapper_resource(&mut store, &invocation, None)?;
                wrapper_version_response(&mut store, version, "updated")
            }
            ARTIFACT_PROMOTE_FUNCTION => {
                let version =
                    lifecycle_wrapper_resource(&mut store, &invocation, "artifact", "promoted")?;
                wrapper_version_response(&mut store, version, "promoted")
            }
            ARTIFACT_DISCARD_FUNCTION => {
                let version =
                    lifecycle_wrapper_resource(&mut store, &invocation, "artifact", "discarded")?;
                wrapper_version_response(&mut store, version, "discarded")
            }
            ARTIFACT_INSPECT_FUNCTION => {
                let resource_id = required_str(&invocation.payload, "resourceId")?;
                let inspection = store.inspect(resource_id)?;
                ensure_inspected_kind(&inspection, "artifact")?;
                Ok(json!({ "inspection": inspection }))
            }
            ARTIFACT_MATERIALIZE_FUNCTION => artifact_materialize_response(&mut store, &invocation),
            GOAL_CREATE_FUNCTION => {
                wrapper_create_response(&mut store, &invocation, "goal", None, "created")
            }
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
                let goal_ref = resource_ref_from_version(&goal_version, "goal", "completed");
                let decision_ref = resource_ref_from_resource(&decision, "decision");
                Ok(json!({
                    "goalVersion": goal_version,
                    "decision": decision,
                    "link": link,
                    "resourceRefs": [goal_ref, decision_ref],
                }))
            }
            CLAIM_ATTACH_FUNCTION => {
                let (resource, link) =
                    create_and_attach_resource(&mut store, &invocation, "claim", "claims_about")?;
                let resource_ref = resource_ref_from_resource(&resource, "claim");
                Ok(json!({
                    "resource": resource,
                    "link": link,
                    "resourceRefs": [resource_ref]
                }))
            }
            EVIDENCE_ATTACH_FUNCTION => {
                let (resource, link) = create_and_attach_resource(
                    &mut store,
                    &invocation,
                    "evidence",
                    "evidence_for",
                )?;
                let resource_ref = resource_ref_from_resource(&resource, "evidence");
                Ok(json!({
                    "resource": resource,
                    "link": link,
                    "resourceRefs": [resource_ref]
                }))
            }
            DECISION_CREATE_FUNCTION => wrapper_create_response(
                &mut store,
                &invocation,
                "decision",
                Some("final"),
                "decision",
            ),
            MATERIALIZED_FILE_CREATE_FUNCTION => {
                materialized_file_create_response(&mut store, &invocation)
            }
            MATERIALIZED_FILE_READ_FUNCTION => {
                materialized_file_read_response(&mut store, &invocation)
            }
            MATERIALIZED_FILE_UPDATE_FUNCTION => {
                materialized_file_update_response(&mut store, &invocation)
            }
            MATERIALIZED_FILE_PROMOTE_FUNCTION => {
                let version = lifecycle_wrapper_resource(
                    &mut store,
                    &invocation,
                    "materialized_file",
                    "promoted",
                )?;
                wrapper_version_response(&mut store, version, "promoted")
            }
            MATERIALIZED_FILE_DISCARD_FUNCTION => {
                let version = lifecycle_wrapper_resource(
                    &mut store,
                    &invocation,
                    "materialized_file",
                    "discarded",
                )?;
                wrapper_version_response(&mut store, version, "discarded")
            }
            MATERIALIZED_FILE_INSPECT_FUNCTION => {
                let resource_id = required_str(&invocation.payload, "resourceId")?;
                let inspection = store.inspect(resource_id)?;
                ensure_inspected_kind(&inspection, "materialized_file")?;
                Ok(json!({ "inspection": inspection }))
            }
            MATERIALIZED_FILE_HASH_VERIFY_FUNCTION => {
                materialized_file_hash_verify_response(&mut store, &invocation)
            }
            PATCH_PROPOSE_FUNCTION => patch_propose_response(&mut store, &invocation),
            PATCH_APPLY_FUNCTION => patch_apply_response(&mut store, &invocation),
            PATCH_MERGE_FUNCTION => {
                let version = lifecycle_wrapper_resource(
                    &mut store,
                    &invocation,
                    "patch_proposal",
                    "merged",
                )?;
                wrapper_version_response(&mut store, version, "merged")
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
        state: None,
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
        state: None,
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

fn wrapper_create_response(
    store: &mut super::ResourceStoreBackend,
    invocation: &Invocation,
    kind: &str,
    lifecycle: Option<&str>,
    role: &str,
) -> Result<Value> {
    let resource = create_wrapper_resource(store, invocation, kind, lifecycle)?;
    Ok(json!({
        "resource": resource,
        "resourceRefs": [resource_ref_from_resource(&resource, role)],
    }))
}

fn wrapper_version_response(
    store: &mut super::ResourceStoreBackend,
    version: EngineResourceVersion,
    role: &str,
) -> Result<Value> {
    let kind = resource_kind_for_version(store, &version)?;
    let resource_ref = resource_ref_from_version(&version, &kind, role);
    Ok(json!({
        "version": version,
        "resourceRefs": [resource_ref],
    }))
}

fn resource_kind_for_version(
    store: &super::ResourceStoreBackend,
    version: &EngineResourceVersion,
) -> Result<String> {
    store
        .inspect(&version.resource_id)?
        .map(|inspection| inspection.resource.kind)
        .ok_or_else(|| EngineError::NotFound {
            kind: "resource",
            id: version.resource_id.clone(),
        })
}

fn resource_ref_from_resource(resource: &EngineResource, role: &str) -> Value {
    let mut value = json!({
        "resourceId": resource.resource_id.as_str(),
        "kind": resource.kind.as_str(),
        "role": role,
    });
    if let Some(version_id) = &resource.current_version_id {
        value["versionId"] = json!(version_id);
    }
    value
}

fn resource_ref_from_version(version: &EngineResourceVersion, kind: &str, role: &str) -> Value {
    json!({
        "resourceId": version.resource_id.as_str(),
        "kind": kind,
        "versionId": version.version_id.as_str(),
        "role": role,
        "contentHash": version.content_hash.as_str(),
    })
}

fn materialized_file_create_response(
    store: &mut super::ResourceStoreBackend,
    invocation: &Invocation,
) -> Result<Value> {
    let (resource, version) = create_materialized_file(store, invocation, false)?;
    let resource_ref = resource_ref_from_version(&version, "materialized_file", "materialized");
    Ok(json!({
        "version": version,
        "resource": resource,
        "resourceRefs": [resource_ref],
    }))
}

fn materialized_file_update_response(
    store: &mut super::ResourceStoreBackend,
    invocation: &Invocation,
) -> Result<Value> {
    let (resource, version) = create_materialized_file(store, invocation, true)?;
    let resource_ref = resource_ref_from_version(&version, "materialized_file", "updated");
    Ok(json!({
        "version": version,
        "resource": resource,
        "resourceRefs": [resource_ref],
    }))
}

fn create_materialized_file(
    store: &mut super::ResourceStoreBackend,
    invocation: &Invocation,
    allow_update: bool,
) -> Result<(EngineResource, EngineResourceVersion)> {
    let path = required_str(&invocation.payload, "path")?;
    let content = optional_string(invocation.payload.get("content"))?.unwrap_or_default();
    let canonical = canonical_materialized_path(path)?;
    let content_hash = sha256_hex(content.as_bytes());
    if let Some(declared) = optional_string(invocation.payload.get("contentHash"))?
        && declared != content_hash
    {
        return Err(EngineError::PolicyViolation(format!(
            "materialized file hash mismatch for {}: declared {declared}, actual {content_hash}",
            canonical.display()
        )));
    }
    let resource_id = optional_string(invocation.payload.get("resourceId"))?
        .unwrap_or_else(|| materialized_file_resource_id(&canonical));
    let existing = store.inspect(&resource_id)?;
    let update_expected = if let Some(inspection) = &existing {
        ensure_resource_kind(&inspection, "materialized_file")?;
        if !allow_update {
            return Err(EngineError::PolicyViolation(format!(
                "materialized file resource {resource_id} already exists"
            )));
        }
        let caller_expected = optional_string(invocation.payload.get("expectedCurrentVersionId"))?;
        if caller_expected.is_some()
            && caller_expected.as_ref() != inspection.resource.current_version_id.as_ref()
        {
            return Err(EngineError::PolicyViolation(format!(
                "resource {resource_id} version conflict: expected {:?}, actual {:?}",
                caller_expected, inspection.resource.current_version_id
            )));
        }
        Some(caller_expected.or(inspection.resource.current_version_id.clone()))
    } else {
        None
    };
    let new_scope = if existing.is_none() {
        Some(resource_scope_from_payload(invocation, false)?)
    } else {
        None
    };
    materialize_content_at_path(&canonical, &content)?;
    let payload = materialized_file_payload(&canonical, &content, &content_hash)?;
    let locations = materialized_file_locations(&canonical, content.len() as u64, &content_hash);
    if existing.is_some() {
        let version = store.update(UpdateResource {
            resource_id: resource_id.clone(),
            expected_current_version_id: update_expected.flatten(),
            lifecycle: Some("materialized".to_owned()),
            payload,
            state: None,
            locations,
            trace_id: invocation.causal_context.trace_id.clone(),
            invocation_id: Some(invocation.id.clone()),
        })?;
        let resource = store.inspect(&resource_id)?.unwrap().resource;
        Ok((resource, version))
    } else {
        let resource = store.create(CreateResource {
            resource_id: Some(resource_id.clone()),
            kind: "materialized_file".to_owned(),
            schema_id: None,
            scope: new_scope.expect("new materialized file scope is resolved before write"),
            owner_worker_id: WorkerId::new(RESOURCE_WORKER_ID).unwrap(),
            owner_actor_id: invocation.causal_context.actor_id.clone(),
            lifecycle: Some("materialized".to_owned()),
            policy: invocation
                .payload
                .get("policy")
                .cloned()
                .unwrap_or_else(|| json!({})),
            initial_payload: Some(payload),
            locations,
            trace_id: invocation.causal_context.trace_id.clone(),
            invocation_id: Some(invocation.id.clone()),
        })?;
        let version = current_version_for_resource(store, &resource.resource_id)?;
        Ok((resource, version))
    }
}

fn artifact_materialize_response(
    store: &mut super::ResourceStoreBackend,
    invocation: &Invocation,
) -> Result<Value> {
    let artifact_id = required_string_owned(&invocation.payload, "artifactResourceId")?;
    let path = required_str(&invocation.payload, "path")?;
    let inspection = store
        .inspect(&artifact_id)?
        .ok_or_else(|| EngineError::NotFound {
            kind: "resource",
            id: artifact_id.clone(),
        })?;
    ensure_resource_kind(&inspection, "artifact")?;
    let artifact_payload = current_payload(&inspection)?;
    let content = artifact_payload
        .get("body")
        .and_then(Value::as_str)
        .map(str::to_owned)
        .unwrap_or_else(|| artifact_payload.to_string());
    let payload = json!({
        "path": path,
        "content": content,
        "resourceId": optional_string(invocation.payload.get("resourceId"))?,
    });
    let mut child_invocation = invocation.clone();
    child_invocation.payload = payload;
    let (materialized, version) = create_materialized_file(store, &child_invocation, true)?;
    let resource_ref = resource_ref_from_version(&version, "materialized_file", "materialized");
    Ok(json!({
        "artifact": inspection.resource,
        "materializedFile": materialized,
        "version": version,
        "resourceRefs": [resource_ref],
    }))
}

fn materialized_file_read_response(
    store: &mut super::ResourceStoreBackend,
    invocation: &Invocation,
) -> Result<Value> {
    let resource_id = required_str(&invocation.payload, "resourceId")?;
    let inspection = store
        .inspect(resource_id)?
        .ok_or_else(|| EngineError::NotFound {
            kind: "resource",
            id: resource_id.to_owned(),
        })?;
    ensure_resource_kind(&inspection, "materialized_file")?;
    let payload = current_payload(&inspection)?;
    let content = payload
        .get("content")
        .and_then(Value::as_str)
        .unwrap_or_default()
        .to_owned();
    Ok(json!({"content": content, "resource": inspection.resource}))
}

fn materialized_file_hash_verify_response(
    store: &mut super::ResourceStoreBackend,
    invocation: &Invocation,
) -> Result<Value> {
    let resource_id = required_string_owned(&invocation.payload, "resourceId")?;
    let inspection = store
        .inspect(&resource_id)?
        .ok_or_else(|| EngineError::NotFound {
            kind: "resource",
            id: resource_id.clone(),
        })?;
    ensure_resource_kind(&inspection, "materialized_file")?;
    let current = current_version_for_inspection(&inspection)?;
    let payload = current.payload.clone();
    let canonical = payload
        .get("canonicalPath")
        .and_then(Value::as_str)
        .ok_or_else(|| {
            EngineError::PolicyViolation("materialized file has no canonicalPath".to_owned())
        })?;
    let bytes = std::fs::read(canonical)
        .map_err(|error| EngineError::HandlerFailed(format!("read materialized file: {error}")))?;
    let actual_hash = sha256_hex(&bytes);
    let expected_hash = payload
        .get("contentHash")
        .and_then(Value::as_str)
        .unwrap_or_default();
    if actual_hash == expected_hash {
        let resource_ref = resource_ref_from_version(&current, "materialized_file", "verified");
        return Ok(json!({
            "version": current,
            "resourceRefs": [resource_ref],
        }));
    }
    let mut damaged_payload = payload.clone();
    damaged_payload["actualContentHash"] = json!(actual_hash);
    damaged_payload["damageReason"] = json!("file bytes do not match contentHash");
    let version = store.update(UpdateResource {
        resource_id: resource_id.clone(),
        expected_current_version_id: inspection.resource.current_version_id.clone(),
        lifecycle: Some("damaged".to_owned()),
        payload: damaged_payload,
        state: Some(crate::engine::resources::EngineResourceVersionState::Damaged),
        locations: current.locations.clone(),
        trace_id: invocation.causal_context.trace_id.clone(),
        invocation_id: Some(invocation.id.clone()),
    })?;
    let resource_ref = resource_ref_from_version(&version, "materialized_file", "damaged");
    Ok(json!({
        "version": version,
        "resourceRefs": [resource_ref],
    }))
}

fn patch_propose_response(
    store: &mut super::ResourceStoreBackend,
    invocation: &Invocation,
) -> Result<Value> {
    let payload = json!({
        "targetPath": required_str(&invocation.payload, "targetPath")?,
        "targetResourceId": optional_string(invocation.payload.get("targetResourceId"))?,
        "baseVersionId": optional_string(invocation.payload.get("baseVersionId"))?,
        "baseContentHash": optional_string(invocation.payload.get("baseContentHash"))?,
        "diff": required_str(&invocation.payload, "diff")?,
        "status": "proposed",
        "result": invocation.payload.get("result").cloned().unwrap_or_else(|| json!({})),
    });
    let resource = create_typed_resource(
        store,
        invocation,
        "patch_proposal",
        Some("proposed"),
        Some(payload),
    )?;
    let resource_ref = resource_ref_from_resource(&resource, "patch");
    Ok(json!({
        "resource": resource,
        "resourceRefs": [resource_ref],
    }))
}

fn patch_apply_response(
    store: &mut super::ResourceStoreBackend,
    invocation: &Invocation,
) -> Result<Value> {
    let patch_id = required_string_owned(&invocation.payload, "patchResourceId")?;
    let patch_inspection = store
        .inspect(&patch_id)?
        .ok_or_else(|| EngineError::NotFound {
            kind: "resource",
            id: patch_id.clone(),
        })?;
    ensure_resource_kind(&patch_inspection, "patch_proposal")?;
    let patch_payload = current_payload(&patch_inspection)?;
    let path = patch_payload
        .get("targetPath")
        .and_then(Value::as_str)
        .ok_or_else(|| {
            EngineError::PolicyViolation("patch proposal missing targetPath".to_owned())
        })?;
    let new_content = required_str(&invocation.payload, "content")?;
    let mut child_invocation = invocation.clone();
    child_invocation.payload = json!({
        "path": path,
        "content": new_content,
        "resourceId": optional_string(invocation.payload.get("targetResourceId"))?
            .or_else(|| patch_payload.get("targetResourceId").and_then(Value::as_str).map(str::to_owned)),
    });
    let (_materialized, file_version) = create_materialized_file(store, &child_invocation, true)?;
    let patch_version = store.update(UpdateResource {
        resource_id: patch_id.clone(),
        expected_current_version_id: patch_inspection.resource.current_version_id.clone(),
        lifecycle: Some("applied".to_owned()),
        payload: json!({
            "targetPath": path,
            "targetResourceId": file_version.resource_id.as_str(),
            "baseVersionId": patch_payload.get("baseVersionId").cloned().unwrap_or(Value::Null),
            "baseContentHash": patch_payload.get("baseContentHash").cloned().unwrap_or(Value::Null),
            "diff": patch_payload.get("diff").cloned().unwrap_or_else(|| json!("")),
            "status": "applied",
            "result": {"versionId": file_version.version_id.as_str()},
        }),
        state: None,
        locations: Vec::new(),
        trace_id: invocation.causal_context.trace_id.clone(),
        invocation_id: Some(invocation.id.clone()),
    })?;
    let patch_ref = resource_ref_from_version(&patch_version, "patch_proposal", "applied_patch");
    let file_ref = resource_ref_from_version(&file_version, "materialized_file", "patched_file");
    Ok(json!({
        "patch": patch_version,
        "version": file_version,
        "resourceRefs": [patch_ref, file_ref],
    }))
}

fn current_version_for_resource(
    store: &super::ResourceStoreBackend,
    resource_id: &str,
) -> Result<EngineResourceVersion> {
    let inspection = store
        .inspect(resource_id)?
        .ok_or_else(|| EngineError::NotFound {
            kind: "resource",
            id: resource_id.to_owned(),
        })?;
    current_version_for_inspection(&inspection)
}

fn current_version_for_inspection(
    inspection: &EngineResourceInspection,
) -> Result<EngineResourceVersion> {
    let current = inspection
        .resource
        .current_version_id
        .as_ref()
        .ok_or_else(|| {
            EngineError::PolicyViolation(format!(
                "resource {} has no current version",
                inspection.resource.resource_id
            ))
        })?;
    inspection
        .versions
        .iter()
        .find(|version| &version.version_id == current)
        .cloned()
        .ok_or_else(|| {
            EngineError::PolicyViolation(format!(
                "resource {} current version {current} is missing",
                inspection.resource.resource_id
            ))
        })
}

fn materialized_file_payload(canonical: &Path, content: &str, content_hash: &str) -> Result<Value> {
    let metadata = std::fs::metadata(canonical).ok();
    Ok(json!({
        "canonicalPath": canonical.to_string_lossy(),
        "relativePath": canonical.file_name().and_then(|name| name.to_str()).unwrap_or_default(),
        "entryType": if metadata.as_ref().is_some_and(std::fs::Metadata::is_dir) { "directory" } else { "file" },
        "content": content,
        "contentHash": content_hash,
        "sizeBytes": u64::try_from(content.len()).unwrap_or(u64::MAX),
        "mimeType": "text/plain",
        "metadata": {
            "readonly": metadata.map(|metadata| metadata.permissions().readonly()).unwrap_or(false)
        }
    }))
}

fn materialized_file_locations(
    canonical: &Path,
    size_bytes: u64,
    content_hash: &str,
) -> Vec<EngineResourceLocation> {
    vec![
        EngineResourceLocation {
            kind: "file".to_owned(),
            uri: canonical.to_string_lossy().into_owned(),
            mime_type: Some("text/plain".to_owned()),
            size_bytes: Some(size_bytes),
        },
        EngineResourceLocation {
            kind: "blob".to_owned(),
            uri: format!("sha256:{content_hash}"),
            mime_type: Some("text/plain".to_owned()),
            size_bytes: Some(size_bytes),
        },
    ]
}

fn materialized_file_resource_id(path: &Path) -> String {
    let hash = sha256_hex(path.to_string_lossy().as_bytes());
    format!("materialized_file:{hash}")
}

fn canonical_materialized_path(path: &str) -> Result<PathBuf> {
    let candidate = PathBuf::from(path);
    if candidate.exists() {
        return candidate.canonicalize().map_err(|error| {
            EngineError::PolicyViolation(format!("canonicalize {path}: {error}"))
        });
    }
    let absolute = if candidate.is_absolute() {
        candidate
    } else {
        std::env::current_dir()
            .map_err(|error| EngineError::HandlerFailed(format!("read current dir: {error}")))?
            .join(candidate)
    };
    let mut suffix = Vec::new();
    let mut ancestor = absolute.as_path();
    while !ancestor.exists() {
        let name = ancestor.file_name().ok_or_else(|| {
            EngineError::PolicyViolation(format!("path {path} has no materializable name"))
        })?;
        suffix.push(name.to_os_string());
        ancestor = ancestor.parent().ok_or_else(|| {
            EngineError::PolicyViolation(format!("path {path} has no materializable parent"))
        })?;
    }
    let mut resolved = ancestor
        .canonicalize()
        .map_err(|error| EngineError::PolicyViolation(format!("canonicalize parent: {error}")))?;
    for component in suffix.iter().rev() {
        resolved.push(component);
    }
    Ok(resolved)
}

fn materialize_content_at_path(canonical: &Path, content: &str) -> Result<()> {
    if canonical.exists() && canonical.is_dir() {
        if content.is_empty() {
            return Ok(());
        }
        return Err(EngineError::PolicyViolation(format!(
            "cannot materialize file bytes over directory {}",
            canonical.display()
        )));
    }
    if let Some(parent) = canonical.parent() {
        std::fs::create_dir_all(parent).map_err(|error| {
            EngineError::HandlerFailed(format!("create materialized file parent: {error}"))
        })?;
    }
    std::fs::write(canonical, content.as_bytes())
        .map_err(|error| EngineError::HandlerFailed(format!("write materialized file: {error}")))
}

fn sha256_hex(bytes: &[u8]) -> String {
    let mut hasher = Sha256::new();
    hasher.update(bytes);
    hex::encode(hasher.finalize())
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
        "required": ["resource", "link", "resourceRefs"],
        "additionalProperties": false,
        "properties": {
            "resource": {"type": "object"},
            "link": {"type": "object"},
            "resourceRefs": resource_refs_schema()
        }
    })
}

fn resource_refs_schema() -> Value {
    json!({
        "type": "array",
        "items": {
            "type": "object",
            "required": ["resourceId", "kind", "role"],
            "additionalProperties": false,
            "properties": {
                "resourceId": {"type": "string"},
                "kind": {"type": "string"},
                "versionId": {"type": "string"},
                "role": {"type": "string"},
                "contentHash": {"type": "string"},
                "relation": {"type": "string"}
            }
        }
    })
}

fn materialized_file_create_schema() -> Value {
    json!({
        "type": "object",
        "required": ["path", "content"],
        "additionalProperties": false,
        "properties": {
            "resourceId": {"type": "string"},
            "path": {"type": "string"},
            "content": {"type": "string"},
            "contentHash": {"type": "string"},
            "scope": {"type": "string", "enum": ["system", "workspace", "session"]},
            "sessionId": {"type": "string"},
            "workspaceId": {"type": "string"},
            "policy": {"type": "object"}
        }
    })
}

fn materialized_file_update_schema() -> Value {
    json!({
        "type": "object",
        "required": ["path", "content"],
        "additionalProperties": false,
        "properties": {
            "resourceId": {"type": "string"},
            "expectedCurrentVersionId": {"type": "string"},
            "path": {"type": "string"},
            "content": {"type": "string"},
            "contentHash": {"type": "string"},
            "scope": {"type": "string", "enum": ["system", "workspace", "session"]},
            "sessionId": {"type": "string"},
            "workspaceId": {"type": "string"},
            "policy": {"type": "object"}
        }
    })
}

fn artifact_materialize_schema() -> Value {
    json!({
        "type": "object",
        "required": ["artifactResourceId", "path"],
        "additionalProperties": false,
        "properties": {
            "artifactResourceId": {"type": "string"},
            "resourceId": {"type": "string"},
            "path": {"type": "string"},
            "scope": {"type": "string", "enum": ["system", "workspace", "session"]},
            "sessionId": {"type": "string"},
            "workspaceId": {"type": "string"},
            "policy": {"type": "object"}
        }
    })
}

fn patch_propose_schema() -> Value {
    json!({
        "type": "object",
        "required": ["targetPath", "diff"],
        "additionalProperties": false,
        "properties": {
            "resourceId": {"type": "string"},
            "targetPath": {"type": "string"},
            "targetResourceId": {"type": "string"},
            "baseVersionId": {"type": "string"},
            "baseContentHash": {"type": "string"},
            "diff": {"type": "string"},
            "result": {"type": "object"},
            "scope": {"type": "string", "enum": ["system", "workspace", "session"]},
            "sessionId": {"type": "string"},
            "workspaceId": {"type": "string"},
            "policy": {"type": "object"}
        }
    })
}

fn patch_apply_schema() -> Value {
    json!({
        "type": "object",
        "required": ["patchResourceId", "content"],
        "additionalProperties": false,
        "properties": {
            "patchResourceId": {"type": "string"},
            "targetResourceId": {"type": "string"},
            "content": {"type": "string"}
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
            Ok(EngineResourceScope::Workspace(non_empty_scope_id(
                "workspaceId",
                workspace_id,
            )?))
        }
        Some("session") => {
            let session_id = optional_string(invocation.payload.get("sessionId"))?
                .or(invocation.causal_context.session_id.clone())
                .ok_or_else(|| {
                    EngineError::PolicyViolation(
                        "session-scoped resource requires sessionId".to_owned(),
                    )
                })?;
            Ok(EngineResourceScope::Session(non_empty_scope_id(
                "sessionId",
                session_id,
            )?))
        }
        Some(other) => Err(EngineError::PolicyViolation(format!(
            "unsupported resource scope {other}"
        ))),
        None if allow_absent => Err(EngineError::PolicyViolation(
            "resource scope filter absent".to_owned(),
        )),
        None => {
            if let Some(workspace_id) = &invocation.causal_context.workspace_id {
                Ok(EngineResourceScope::Workspace(non_empty_scope_id(
                    "workspaceId",
                    workspace_id.clone(),
                )?))
            } else if let Some(session_id) = &invocation.causal_context.session_id {
                Ok(EngineResourceScope::Session(non_empty_scope_id(
                    "sessionId",
                    session_id.clone(),
                )?))
            } else {
                Ok(EngineResourceScope::System)
            }
        }
    }
}

fn non_empty_scope_id(field: &str, value: String) -> Result<String> {
    if value.trim().is_empty() {
        return Err(EngineError::PolicyViolation(format!(
            "{field} must not be empty"
        )));
    }
    Ok(value)
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
