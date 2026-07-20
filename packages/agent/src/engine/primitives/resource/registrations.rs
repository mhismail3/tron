//! Fixed reliability wrappers over the generic resource substrate.
//!
//! Higher-level artifact curation, goals, claims, evidence, and decisions are
//! worker behavior. The engine retains only materialized-file and patch records
//! needed to make filesystem effects inspectable and recoverable.

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
    Ok(vec![
        handled_registration(
            resource_wrapper_function(
                MATERIALIZED_FILE_CREATE_FUNCTION,
                "create a materialized file reliability record",
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
                "read a materialized file reliability record",
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
                "append a materialized file reliability version",
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
                "promote a materialized file reliability record",
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
                "discard a materialized file reliability record",
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
                "inspect a materialized file reliability record",
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
                "verify materialized bytes against their recorded hash",
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
                "record a filesystem patch preview",
                EffectClass::IdempotentWrite,
            )
            .with_request_schema(patch_propose_schema())
            .with_response_schema(create_response)
            .with_output_contract(DurableOutputContract::resource_backed(["patch_proposal"])),
            handler.clone(),
        ),
        handled_registration(
            resource_wrapper_function(
                PATCH_APPLY_FUNCTION,
                "apply a patch record and produce materialization evidence",
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
                "mark a patch reliability record merged",
                EffectClass::IdempotentWrite,
            )
            .with_request_schema(wrapper_lifecycle_schema())
            .with_response_schema(version_response)
            .with_output_contract(DurableOutputContract::resource_backed(["patch_proposal"])),
            handler,
        ),
    ])
}
