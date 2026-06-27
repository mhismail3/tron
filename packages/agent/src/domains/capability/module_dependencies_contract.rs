//! Provider schema additions for module dependency policy execute operations.
//!
//! These fields describe metadata-only dependency request, decision, and
//! policy records. They never authorize package-manager execution, dependency
//! restoration, manifest or lockfile mutation, network access, or runtime code.

use serde_json::{Map, Value, json};

#[cfg(test)]
pub(super) const MODULE_DEPENDENCIES_SCHEMA_FIELDS: &[&str] = &[
    "moduleDependencyRequestResourceId",
    "moduleDependencyDecisionResourceId",
    "moduleDependencyPolicyResourceId",
    "dependencyRequestId",
    "dependencyDecisionId",
    "dependencyPolicyId",
    "moduleRef",
    "proposalRef",
    "validationRef",
    "installRef",
    "runtimeRef",
    "dependencyName",
    "dependencyVersionReq",
    "dependencyEcosystem",
    "rationale",
    "securityNeed",
    "licenseNeed",
    "runtimeNeed",
    "removalPlan",
    "riskClass",
    "reviewStatus",
    "cargoTomlEvidence",
    "cargoLockEvidence",
];

pub(super) fn append_schema_properties(properties: &mut Map<String, Value>) {
    insert_string(
        properties,
        "moduleDependencyRequestResourceId",
        "Durable module_dependency_request resource id for dependency request inspect or decision record.",
    );
    insert_string(
        properties,
        "moduleDependencyDecisionResourceId",
        "Durable module_dependency_decision resource id for decision inspect or policy activation.",
    );
    insert_string(
        properties,
        "moduleDependencyPolicyResourceId",
        "Durable module_dependency_policy resource id for policy inspect.",
    );
    insert_string(
        properties,
        "dependencyRequestId",
        "Optional caller-visible module dependency request id.",
    );
    insert_string(
        properties,
        "dependencyDecisionId",
        "Optional caller-visible module dependency decision id.",
    );
    insert_string(
        properties,
        "dependencyPolicyId",
        "Optional caller-visible module dependency policy id.",
    );
    for (name, description) in [
        (
            "moduleRef",
            "Bounded owner module ref object for module_dependency_request_record.",
        ),
        (
            "proposalRef",
            "Optional bounded module proposal ref object.",
        ),
        (
            "validationRef",
            "Optional bounded module validation report ref object.",
        ),
        (
            "installRef",
            "Optional bounded module install decision ref object.",
        ),
        ("runtimeRef", "Optional bounded module runtime ref object."),
        (
            "cargoTomlEvidence",
            "Bounded Cargo.toml parity evidence object proving no package-manager execution or file mutation.",
        ),
        (
            "cargoLockEvidence",
            "Bounded Cargo.lock parity evidence object proving no package-manager execution or file mutation.",
        ),
    ] {
        properties.insert(
            name.to_owned(),
            json!({"type": "object", "description": description}),
        );
    }
    for (name, description) in [
        ("dependencyName", "Bounded dependency identity token."),
        (
            "dependencyVersionReq",
            "Optional bounded dependency version requirement text.",
        ),
        ("dependencyEcosystem", "Bounded dependency ecosystem token."),
        ("rationale", "Bounded owner rationale for the dependency."),
        ("securityNeed", "Bounded security need or risk explanation."),
        ("licenseNeed", "Bounded license review need."),
        ("runtimeNeed", "Bounded runtime need."),
        ("removalPlan", "Bounded future removal or rollback plan."),
        (
            "riskClass",
            "Dependency risk class: low, medium, high, or critical.",
        ),
        ("reviewStatus", "Metadata review status."),
    ] {
        insert_string(properties, name, description);
    }
}

fn insert_string(properties: &mut Map<String, Value>, name: &str, description: &str) {
    properties.insert(
        name.to_owned(),
        json!({"type": "string", "description": description}),
    );
}
