//! Provider schema additions for module install review-gate execute operations.
//!
//! These fields describe metadata-only request and decision records. They do
//! not expose an install operation and must not be interpreted as physical
//! installation, activation, execution, dependency restoration, or package
//! manager authority.

use serde_json::{Map, Value, json};

#[cfg(test)]
pub(super) const MODULE_INSTALL_SCHEMA_FIELDS: &[&str] = &[
    "moduleInstallRequestResourceId",
    "moduleInstallDecisionResourceId",
    "installRequestId",
    "installDecisionId",
    "dependencyPolicyRefs",
    "dependencyPolicyStatus",
    "rollbackProofRefs",
    "rollbackReadiness",
    "approvalRequestResourceId",
    "approvalDecisionResourceId",
    "decision",
    "denialEvidence",
];

pub(super) fn append_schema_properties(properties: &mut Map<String, Value>) {
    insert_string(
        properties,
        "moduleInstallRequestResourceId",
        "Durable module_install_request resource id for module_install_request_inspect or module_install_decision_record.",
    );
    insert_string(
        properties,
        "moduleInstallDecisionResourceId",
        "Durable module_install_decision resource id for module_install_decision_inspect.",
    );
    insert_string(
        properties,
        "installRequestId",
        "Optional caller-visible module install request id for module_install_request_record.",
    );
    insert_string(
        properties,
        "installDecisionId",
        "Optional caller-visible module install decision id for module_install_decision_record.",
    );
    insert_array(
        properties,
        "dependencyPolicyRefs",
        "Bounded metadata refs to dependency policy evidence; no dependency restore or package-manager action is performed.",
    );
    insert_string(
        properties,
        "dependencyPolicyStatus",
        "Metadata-only dependency policy status for module install review.",
    );
    insert_array(
        properties,
        "rollbackProofRefs",
        "Bounded metadata refs to rollback proof evidence; no rollback action is performed.",
    );
    insert_string(
        properties,
        "rollbackReadiness",
        "Metadata-only rollback readiness for module install review.",
    );
    insert_string(
        properties,
        "approvalRequestResourceId",
        "Approval request resource id required by module_install_decision_record.",
    );
    insert_string(
        properties,
        "approvalDecisionResourceId",
        "Approval decision resource id required for approved module_install_decision_record.",
    );
    insert_string(
        properties,
        "decision",
        "Module install review decision: approved, rejected, or denied. Approved records install-candidate metadata only.",
    );
    insert_array(
        properties,
        "denialEvidence",
        "Required bounded evidence refs when module_install_decision_record rejects or denies the request.",
    );
}

fn insert_string(properties: &mut Map<String, Value>, name: &str, description: &str) {
    properties.insert(
        name.to_owned(),
        json!({"type": "string", "description": description}),
    );
}

fn insert_array(properties: &mut Map<String, Value>, name: &str, description: &str) {
    properties.insert(
        name.to_owned(),
        json!({"type": "array", "description": description}),
    );
}
