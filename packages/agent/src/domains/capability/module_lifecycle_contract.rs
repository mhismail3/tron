use serde_json::{Map, json};

#[cfg(test)]
pub(super) const MODULE_LIFECYCLE_SCHEMA_FIELDS: &[&str] = &[
    "moduleLifecycleResourceId",
    "moduleInstallDecisionResourceId",
    "expectedModuleLifecycleVersionId",
    "lifecycleAction",
    "lifecycleTransitionId",
    "rollbackProofRefs",
    "rollbackReadiness",
];

pub(super) fn insert_module_lifecycle_request_fields(
    properties: &mut Map<String, serde_json::Value>,
) {
    properties.insert(
        "moduleLifecycleResourceId".to_owned(),
        json!({"type": "string", "description": "Exact module_lifecycle_state resource id for lifecycle decision or inspect."}),
    );
    properties.insert(
        "moduleInstallDecisionResourceId".to_owned(),
        json!({"type": "string", "description": "Exact current-scope module_install_decision resource id in install_candidate state for lifecycle request."}),
    );
    properties.insert(
        "expectedModuleLifecycleVersionId".to_owned(),
        json!({"type": "string", "description": "Expected current module_lifecycle_state version id for lifecycle decision freshness."}),
    );
    properties.insert(
        "lifecycleAction".to_owned(),
        json!({"type": "string", "description": "Metadata-only lifecycle transition action: enable, disable, quarantine, or rollback."}),
    );
    properties.insert(
        "lifecycleTransitionId".to_owned(),
        json!({"type": "string", "description": "Optional bounded provider-visible lifecycle transition id."}),
    );
    properties.insert(
        "rollbackProofRefs".to_owned(),
        json!({"type": "array", "description": "Bounded rollback proof refs; required with rollbackReadiness ready for rollback actions."}),
    );
    properties.insert(
        "rollbackReadiness".to_owned(),
        json!({"type": "string", "description": "Metadata-only rollback readiness state: not_proven, ready, or blocked."}),
    );
}
