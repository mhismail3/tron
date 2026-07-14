//! Frozen provider-visible presentation oracle and facade regression owner.

use std::collections::{BTreeMap, BTreeSet};

use super::super::{
    capability_binding as input_capability_binding, direct as input_direct,
    governance as input_governance, records as input_records,
};
use super::*;

mod oracle_capability_binding;
mod oracle_direct;
mod oracle_governance;
mod oracle_records;

pub(super) type OracleRow = (&'static str, &'static str, &'static str, &'static str);

fn frozen_provider_visible_presentation_oracle() -> Vec<OracleRow> {
    let mut direct = oracle_direct::ROWS.into_iter();
    let mut records = oracle_records::ROWS.into_iter();
    let mut governance = oracle_governance::ROWS.into_iter();
    let mut capability_binding = oracle_capability_binding::ROWS.into_iter();

    let rows = OperationId::ALL_NAMES
        .iter()
        .map(|operation_name| {
            let operation = OperationId::parse(operation_name)
                .unwrap_or_else(|| panic!("oracle operation is not registered: {operation_name}"));
            match presentation_family(operation) {
                PresentationFamily::Direct => direct
                    .next()
                    .expect("direct oracle row count matches facade"),
                PresentationFamily::Records => records
                    .next()
                    .expect("records oracle row count matches facade"),
                PresentationFamily::Governance => governance
                    .next()
                    .expect("governance oracle row count matches facade"),
                PresentationFamily::CapabilityBinding => capability_binding
                    .next()
                    .expect("capability-binding oracle row count matches facade"),
            }
        })
        .collect::<Vec<_>>();

    assert!(direct.next().is_none(), "unused direct oracle row");
    assert!(records.next().is_none(), "unused records oracle row");
    assert!(governance.next().is_none(), "unused governance oracle row");
    assert!(
        capability_binding.next().is_none(),
        "unused capability-binding oracle row"
    );
    rows
}

#[test]
fn all_188_presentations_match_frozen_provider_visible_oracle() {
    let oracle = frozen_provider_visible_presentation_oracle();
    assert_eq!(oracle.len(), 188);
    let oracle_names = oracle
        .iter()
        .map(|(operation_name, _, _, _)| *operation_name)
        .collect::<Vec<_>>();
    assert_eq!(oracle_names.as_slice(), OperationId::ALL_NAMES);
    assert_eq!(
        oracle_names.iter().copied().collect::<BTreeSet<_>>().len(),
        188
    );

    for (operation_name, _, display_name, description) in oracle {
        let actual = operation_presentation(operation_name)
            .unwrap_or_else(|| panic!("missing presentation metadata for {operation_name}"));
        assert_eq!(
            actual.display_name, display_name,
            "{operation_name} display name drifted"
        );
        assert_eq!(
            actual.description, description,
            "{operation_name} description drifted"
        );
    }
    assert!(operation_presentation("future_unknown_operation").is_none());
}

#[test]
fn presentation_oracle_matches_unique_input_schema_family_ownership() {
    let mut family_counts = BTreeMap::new();
    for (operation_name, expected_family, _, _) in frozen_provider_visible_presentation_oracle() {
        let operation = OperationId::parse(operation_name)
            .unwrap_or_else(|| panic!("oracle operation is not registered: {operation_name}"));
        assert_eq!(
            presentation_family(operation).as_str(),
            expected_family,
            "{operation_name} facade and oracle families drifted"
        );

        let owners = [
            (
                "direct",
                input_direct::input_schema(operation_name).is_some(),
            ),
            (
                "records",
                input_records::input_schema(operation_name).is_some(),
            ),
            (
                "governance",
                input_governance::input_schema(operation_name).is_some(),
            ),
            (
                "capability_binding",
                input_capability_binding::input_schema(operation_name).is_some(),
            ),
        ]
        .into_iter()
        .filter_map(|(family, owns_operation)| owns_operation.then_some(family))
        .collect::<Vec<_>>();

        assert_eq!(
            owners.len(),
            1,
            "{operation_name} has schema-family owners {owners:?}"
        );
        assert_eq!(
            owners[0], expected_family,
            "{operation_name} presentation and schema families drifted"
        );
        *family_counts.entry(expected_family).or_insert(0_usize) += 1;
    }

    assert_eq!(
        family_counts,
        BTreeMap::from([
            ("capability_binding", 25_usize),
            ("direct", 41_usize),
            ("governance", 59_usize),
            ("records", 63_usize),
        ])
    );
}

#[test]
fn all_188_operations_have_friendly_concise_presentation_metadata() {
    assert_eq!(OperationId::ALL_NAMES.len(), 188);
    for operation_name in OperationId::ALL_NAMES {
        let metadata = operation_presentation(operation_name)
            .unwrap_or_else(|| panic!("missing presentation metadata for {operation_name}"));
        assert!(!metadata.display_name.trim().is_empty(), "{operation_name}");
        assert!(!metadata.description.trim().is_empty(), "{operation_name}");
        assert!(
            !metadata.display_name.contains(['_', ':']),
            "{operation_name} leaked raw separators into {}",
            metadata.display_name
        );
        assert!(
            !metadata.description.contains(['_', ':']),
            "{operation_name} leaked raw separators into {}",
            metadata.description
        );
        assert!(
            metadata.description.len() <= 180,
            "{operation_name} description is too long: {}",
            metadata.description
        );
    }
    assert!(operation_presentation("future_unknown_operation").is_none());
}
