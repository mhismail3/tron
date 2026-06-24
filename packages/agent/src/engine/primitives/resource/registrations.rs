use super::*;

pub(super) fn resource_wrapper_registrations(
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
                "promote an artifact resource; use expectedCurrentVersionId, not versionId, as the optional CAS guard",
                EffectClass::IdempotentWrite,
            )
            .with_request_schema(wrapper_lifecycle_schema())
            .with_response_schema(version_response.clone()),
            handler.clone(),
        ),
        handled_registration(
            resource_wrapper_function(
                ARTIFACT_DISCARD_FUNCTION,
                "discard an artifact resource; use expectedCurrentVersionId, not versionId, as the optional CAS guard",
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
                ARTIFACT_SPLIT_FUNCTION,
                "split an artifact into derived artifact resources",
                EffectClass::IdempotentWrite,
            )
            .with_request_schema(artifact_split_schema())
            .with_response_schema(json!({
                "type": "object",
                "required": ["source", "parts", "links", "resourceRefs"],
                "additionalProperties": false,
                "properties": {
                    "source": {"type": "object"},
                    "parts": {"type": "array"},
                    "links": {"type": "array"},
                    "resourceRefs": resource_refs_schema()
                }
            }))
            .with_output_contract(DurableOutputContract::resource_backed(["artifact"])),
            handler.clone(),
        ),
        handled_registration(
            resource_wrapper_function(
                ARTIFACT_COMPOSE_FUNCTION,
                "compose input artifacts into a new artifact resource",
                EffectClass::IdempotentWrite,
            )
            .with_request_schema(artifact_compose_schema())
            .with_response_schema(json!({
                "type": "object",
                "required": ["artifact", "links", "resourceRefs"],
                "additionalProperties": false,
                "properties": {
                    "artifact": {"type": "object"},
                    "links": {"type": "array"},
                    "resourceRefs": resource_refs_schema()
                }
            }))
            .with_output_contract(DurableOutputContract::resource_backed(["artifact"])),
            handler.clone(),
        ),
        handled_registration(
            resource_wrapper_function(
                ARTIFACT_MERGE_FUNCTION,
                "merge artifact resources into a target artifact version",
                EffectClass::IdempotentWrite,
            )
            .with_request_schema(artifact_merge_schema())
            .with_response_schema(json!({
                "type": "object",
                "required": ["version", "links", "resourceRefs"],
                "additionalProperties": false,
                "properties": {
                    "version": {"type": "object"},
                    "links": {"type": "array"},
                    "resourceRefs": resource_refs_schema()
                }
            }))
            .with_output_contract(DurableOutputContract::resource_backed(["artifact"])),
            handler.clone(),
        ),
        handled_registration(
            resource_wrapper_function(
                ARTIFACT_SEARCH_FUNCTION,
                "search artifact payload previews",
                EffectClass::PureRead,
            )
            .with_request_schema(artifact_search_schema())
            .with_response_schema(json!({
                "type": "object",
                "required": ["matches", "resourceRefs"],
                "additionalProperties": false,
                "properties": {
                    "matches": {"type": "array"},
                    "resourceRefs": resource_refs_schema()
                }
            })),
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
                "required": ["goalVersion", "decision", "link", "agentResultLink", "promotedLinks", "resourceRefs"],
                "additionalProperties": false,
                "properties": {
                    "goalVersion": {"type": "object"},
                    "decision": {"type": "object"},
                    "link": {"type": "object"},
                    "agentResultLink": {"type": "object"},
                    "promotedLinks": {"type": "array"},
                    "resourceRefs": resource_refs_schema()
                }
            })),
            handler.clone(),
        ),
        handled_registration(
            resource_wrapper_function(
                GOAL_WORKING_SET_FUNCTION,
                "project a goal working set from resource lineage",
                EffectClass::PureRead,
            )
            .with_request_schema(json!({
                "type": "object",
                "required": ["goalResourceId"],
                "additionalProperties": false,
                "properties": {
                    "goalResourceId": {"type": "string"},
                    "previewBytes": {"type": "integer"},
                    "limit": {"type": "integer"}
                }
            }))
            .with_response_schema(json!({
                "type": "object",
                "required": ["goal", "resources", "links", "unresolvedClaims", "candidateOutputs", "promotedOutputs"],
                "additionalProperties": false,
                "properties": {
                    "goal": {"type": "object"},
                    "resources": {"type": "array"},
                    "links": {"type": "array"},
                    "unresolvedClaims": {"type": "array"},
                    "candidateOutputs": {"type": "array"},
                    "promotedOutputs": {"type": "array"}
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
                "promote a materialized file resource; use expectedCurrentVersionId, not versionId, as the optional CAS guard",
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
                "discard a materialized file resource; use expectedCurrentVersionId, not versionId, as the optional CAS guard",
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
                "merge a patch proposal resource; use expectedCurrentVersionId, not versionId, as the optional CAS guard",
                EffectClass::IdempotentWrite,
            )
            .with_request_schema(wrapper_lifecycle_schema())
            .with_response_schema(version_response)
            .with_output_contract(DurableOutputContract::resource_backed(["patch_proposal"])),
            handler,
        ),
    ])
}
