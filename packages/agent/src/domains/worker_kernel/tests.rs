//! Worker-kernel composition and architectural manifest tests.

use std::collections::BTreeSet;

use super::contract;

#[test]
fn core_primitive_manifest_is_unique_ordered_and_covers_each_family() {
    let descriptors = contract::core_primitives();
    assert_eq!(
        descriptors
            .iter()
            .map(|descriptor| descriptor.group)
            .collect::<BTreeSet<_>>(),
        BTreeSet::from([
            contract::CorePrimitiveGroup::Host,
            contract::CorePrimitiveGroup::WorkerControl,
            contract::CorePrimitiveGroup::CoreChange,
        ])
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
