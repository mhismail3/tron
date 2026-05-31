//! Resource primitive worker contracts and handlers.
//!
//! `resource::*` is the canonical capability surface for durable engine
//! resources. Higher-level modules such as artifacts, goals, claims, evidence,
//! decisions, and generated UI should compose these functions instead of
//! creating separate persistence planes.

use std::path::{Component, Path, PathBuf};
use std::sync::Arc;

use async_trait::async_trait;
use serde_json::{Value, json};
use sha2::{Digest, Sha256};

use super::{
    PrimitiveFunctionRegistration, PrimitiveStores, RESOURCE_WORKER_ID, ResourceStoreBackend,
    handled_registration, optional_string, optional_u64, primitive_function, required_str,
    required_string_owned,
};
use crate::engine::invocation::RUNTIME_METADATA_WORKING_DIRECTORY;
use crate::engine::{
    CreateResource, DurableOutputContract, EffectClass, EngineError, EngineResourceLocation,
    EngineResourceScope, EngineResourceVersioningMode, IdempotencyContract,
    InProcessFunctionHandler, Invocation, LinkResources, ListResources, RegisterResourceType,
    Result, UpdateResource, VisibilityScope, WorkerId,
};
use crate::engine::{EngineResource, EngineResourceInspection, EngineResourceVersion};

mod artifact;
mod common;
mod input;
mod materialized_file;
mod registrations;
mod schemas;

use artifact::{
    artifact_compose_response, artifact_merge_response, artifact_search_response,
    artifact_split_response, goal_working_set_response,
};
use common::{
    create_and_attach_resource, create_typed_resource, ensure_inspected_kind,
    lifecycle_resource_by_id, lifecycle_wrapper_resource, optional_resource_scope_filter,
    resource_kind_for_version, resource_ref_from_resource, resource_ref_from_version,
    update_wrapper_resource, wrapper_create_response, wrapper_version_response,
};
use input::{
    locations, optional_string_array, optional_worker_id, resource_scope_from_payload,
    string_array, versioning_mode,
};
use materialized_file::*;
use registrations::resource_wrapper_registrations;
use schemas::*;

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
pub(crate) const ARTIFACT_SPLIT_FUNCTION: &str = "artifact::split";
pub(crate) const ARTIFACT_COMPOSE_FUNCTION: &str = "artifact::compose";
pub(crate) const ARTIFACT_MERGE_FUNCTION: &str = "artifact::merge";
pub(crate) const ARTIFACT_SEARCH_FUNCTION: &str = "artifact::search";
pub(crate) const GOAL_CREATE_FUNCTION: &str = "goal::create";
pub(crate) const GOAL_COMPLETE_FUNCTION: &str = "goal::complete";
pub(crate) const GOAL_WORKING_SET_FUNCTION: &str = "goal::working_set";
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
            .with_idempotency(IdempotencyContract::caller_system_engine_ledger())
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
            ARTIFACT_SPLIT_FUNCTION => artifact_split_response(&mut store, &invocation),
            ARTIFACT_COMPOSE_FUNCTION => artifact_compose_response(&mut store, &invocation),
            ARTIFACT_MERGE_FUNCTION => artifact_merge_response(&mut store, &invocation),
            ARTIFACT_SEARCH_FUNCTION => artifact_search_response(&mut store, &invocation),
            ARTIFACT_MATERIALIZE_FUNCTION => artifact_materialize_response(&mut store, &invocation),
            GOAL_CREATE_FUNCTION => {
                wrapper_create_response(&mut store, &invocation, "goal", None, "created")
            }
            GOAL_COMPLETE_FUNCTION => {
                let goal_id = required_string_owned(&invocation.payload, "goalResourceId")?;
                let agent_result_id =
                    required_string_owned(&invocation.payload, "agentResultResourceId")?;
                let promoted_resource_ids =
                    string_array(&invocation.payload, "promotedResourceIds")?;
                if promoted_resource_ids.is_empty() {
                    return Err(EngineError::PolicyViolation(
                        "goal::complete requires at least one promoted resource".to_owned(),
                    ));
                }
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
                    source_resource_id: goal_id.clone(),
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
                let agent_link = store.link(LinkResources {
                    source_resource_id: goal_id.clone(),
                    target_resource_id: agent_result_id,
                    relation: "produced".to_owned(),
                    metadata: json!({"role": "agent_result"}),
                    trace_id: invocation.causal_context.trace_id.clone(),
                    invocation_id: Some(invocation.id.clone()),
                })?;
                let mut promoted_links = Vec::new();
                for resource_id in promoted_resource_ids {
                    promoted_links.push(store.link(LinkResources {
                        source_resource_id: goal_id.clone(),
                        target_resource_id: resource_id,
                        relation: "promoted_output".to_owned(),
                        metadata: json!({}),
                        trace_id: invocation.causal_context.trace_id.clone(),
                        invocation_id: Some(invocation.id.clone()),
                    })?);
                }
                let goal_ref = resource_ref_from_version(&goal_version, "goal", "completed");
                let decision_ref = resource_ref_from_resource(&decision, "decision");
                Ok(json!({
                    "goalVersion": goal_version,
                    "decision": decision,
                    "link": link,
                    "agentResultLink": agent_link,
                    "promotedLinks": promoted_links,
                    "resourceRefs": [goal_ref, decision_ref],
                }))
            }
            GOAL_WORKING_SET_FUNCTION => goal_working_set_response(&mut store, &invocation),
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
