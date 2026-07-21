//! Worker-kernel composition and architectural manifest tests.

use std::collections::BTreeSet;

use serde_json::Value;

use super::contract;

#[test]
fn replay_fixture_describes_executable_expected_outcome() {
    let fixture: Value = serde_json::from_str(include_str!(
        "../../../tests/fixtures/last30days_worker_gap.json"
    ))
    .unwrap();
    assert_eq!(fixture["observedOutcome"]["kind"], "inert_proposal");
    assert_eq!(
        fixture["expectedOutcome"]["atomicOperation"],
        "worker_upsert"
    );
    assert_eq!(fixture["expectedOutcome"]["directTypedTool"], true);
}

#[test]
fn core_primitive_manifest_is_exact_unique_and_grouped() {
    let descriptors = contract::core_primitives();
    assert_eq!(descriptors.len(), 27);
    assert_eq!(
        descriptors
            .iter()
            .filter(|descriptor| descriptor.group == contract::CorePrimitiveGroup::Host)
            .count(),
        7
    );
    assert_eq!(
        descriptors
            .iter()
            .filter(|descriptor| {
                descriptor.group == contract::CorePrimitiveGroup::WorkerControl
            })
            .count(),
        16
    );
    assert_eq!(
        descriptors
            .iter()
            .filter(|descriptor| descriptor.group == contract::CorePrimitiveGroup::CoreChange)
            .count(),
        4
    );
    assert_eq!(
        descriptors
            .iter()
            .map(|descriptor| descriptor.operation_key)
            .collect::<BTreeSet<_>>()
            .len(),
        descriptors.len()
    );
    assert_eq!(
        descriptors
            .iter()
            .map(|descriptor| descriptor.model_name)
            .collect::<BTreeSet<_>>()
            .len(),
        descriptors.len()
    );
    assert!(
        descriptors
            .windows(2)
            .all(|pair| pair[0].order < pair[1].order)
    );
}

#[test]
fn engine_component_manifest_distinguishes_kernel_from_product_shell() {
    let components = contract::core_components();
    assert_eq!(components.len(), 8);
    assert_eq!(
        components
            .iter()
            .map(|component| component.id)
            .collect::<BTreeSet<_>>()
            .len(),
        components.len()
    );
    assert!(
        components
            .iter()
            .any(|component| component.category == "kernel")
    );
    assert!(
        components
            .iter()
            .any(|component| component.category == "product_infrastructure")
    );
    assert!(
        components
            .iter()
            .any(|component| component.category == "protected_boundary")
    );
}
