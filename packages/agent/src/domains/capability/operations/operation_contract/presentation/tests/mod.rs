//! Presentation exhaustiveness, style, and compatibility regressions.

use super::*;

#[test]
fn every_operation_has_friendly_concise_presentation_metadata() {
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

#[test]
fn representative_provider_visible_presentations_are_stable() {
    let cases = [
        (
            OperationId::ProcessRun,
            "Run Process",
            "Run a bounded local command with timeout, output, and no-network enforcement.",
        ),
        (
            OperationId::GoalCreate,
            "Create Goal",
            "Create a durable scoped goal with lifecycle and evidence references.",
        ),
        (
            OperationId::ModuleLifecycleRequest,
            "Request Module Lifecycle Change",
            "Request a governed module enable, disable, quarantine, or rollback transition.",
        ),
        (
            OperationId::CapabilityBindingCockpitOverview,
            "View Capability Dashboard",
            "Show operation ownership, replacement readiness, and route evidence for the current scope.",
        ),
    ];

    for (operation, display_name, description) in cases {
        assert_eq!(
            operation_presentation(operation.as_str()),
            Some(OperationPresentation {
                display_name,
                description,
            })
        );
    }
}
