//! Provider schema additions for module validation execute operations.
//!
//! The focused module keeps Slice 23C's bounded report fields out of the
//! shared execute contract root while preserving one provider-visible
//! `capability::execute` schema.

use serde_json::{Map, Value, json};

#[cfg(test)]
pub(super) const MODULE_VALIDATION_SCHEMA_FIELDS: &[&str] = &[
    "moduleValidationReportResourceId",
    "reportId",
    "lifecycleState",
    "validationStatus",
    "moduleRefs",
    "proposalRefs",
    "manifestProjectionParity",
    "resourceProjectionParity",
    "providerProjectionParity",
    "docEvidence",
    "testEvidence",
    "commandRefs",
    "resultRefs",
    "failureEvidence",
    "validationChecks",
];

pub(super) fn append_schema_properties(properties: &mut Map<String, Value>) {
    insert_string(
        properties,
        "moduleValidationReportResourceId",
        "Durable module_validation_report resource id for module_validation_inspect.",
    );
    insert_string(
        properties,
        "reportId",
        "Optional caller-visible module validation report id for module_validation_record.",
    );
    insert_string(
        properties,
        "lifecycleState",
        "Module proposal or validation lifecycle for module_proposal_record/module_validation_record.",
    );
    insert_string(
        properties,
        "validationStatus",
        "Optional bounded validation status for module_proposal_record or module_validation_record.",
    );
    insert_array(
        properties,
        "moduleRefs",
        "Required bounded module refs for module_validation_record.",
    );
    insert_array(
        properties,
        "proposalRefs",
        "Optional bounded proposal refs for module_validation_record.",
    );
    insert_array(
        properties,
        "manifestProjectionParity",
        "Bounded manifest projection parity checks for module_validation_record.",
    );
    insert_array(
        properties,
        "resourceProjectionParity",
        "Bounded resource projection parity checks for module_validation_record.",
    );
    insert_array(
        properties,
        "providerProjectionParity",
        "Bounded provider projection parity checks for module_validation_record.",
    );
    insert_array(
        properties,
        "docEvidence",
        "Required bounded docs evidence refs for module_validation_record.",
    );
    insert_array(
        properties,
        "testEvidence",
        "Required bounded test evidence refs for module_validation_record.",
    );
    insert_array(
        properties,
        "commandRefs",
        "Bounded deterministic command identity refs for module_validation_record; raw command text is rejected.",
    );
    insert_array(
        properties,
        "resultRefs",
        "Bounded deterministic result refs for module_validation_record.",
    );
    insert_array(
        properties,
        "failureEvidence",
        "Bounded failure evidence refs for failed module_validation_record reports.",
    );
    insert_array(
        properties,
        "validationChecks",
        "Bounded validation check summaries for module_validation_record.",
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
