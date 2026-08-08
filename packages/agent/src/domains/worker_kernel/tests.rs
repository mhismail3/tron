//! Worker-kernel fixed model-contract tests.

use std::collections::BTreeSet;

use super::contract;
use crate::engine::ModelToolAudience;

#[test]
fn model_facing_contracts_own_unique_names_and_order() {
    let definitions = contract::function_definitions().expect("worker-kernel contracts");
    let tools = definitions
        .iter()
        .filter_map(|definition| definition.model_tool.as_ref())
        .collect::<Vec<_>>();
    assert_eq!(
        tools
            .iter()
            .map(|tool| tool.name.as_str())
            .collect::<BTreeSet<_>>()
            .len(),
        tools.len()
    );
    assert!(
        tools
            .iter()
            .all(|tool| tool.order.is_some() && tool.group.is_some())
    );
    assert_eq!(
        tools
            .iter()
            .filter(|tool| matches!(tool.audience, ModelToolAudience::Ordinary))
            .count(),
        16
    );
    assert_eq!(
        tools
            .iter()
            .filter(|tool| matches!(tool.audience, ModelToolAudience::Specialist))
            .count(),
        12
    );
}

#[test]
fn ordinary_surface_always_contains_worker_coordination_primitives() {
    let definitions = contract::function_definitions().expect("worker-kernel contracts");
    let ordinary_names = definitions
        .iter()
        .filter_map(|definition| definition.model_tool.as_ref())
        .filter(|tool| matches!(tool.audience, ModelToolAudience::Ordinary))
        .map(|tool| tool.name.as_str())
        .collect::<BTreeSet<_>>();

    for required in [
        "worker_discover",
        "worker_invoke",
        "worker_await",
        "worker_cancel",
        "worker_result_read",
        "agent_send",
        "agent_wait_for_workers",
        "agent_mailbox_list",
        "agent_mailbox_claim",
    ] {
        assert!(
            ordinary_names.contains(required),
            "{required} must remain available to an ordinary main agent"
        );
    }
}

#[test]
fn secret_and_engine_wide_operations_are_client_only() {
    let definitions = contract::function_definitions().expect("worker-kernel contracts");
    for function_id in [
        "worker_kernel::result_handoff",
        "worker_kernel::webhook_rotate",
        "worker_kernel::stop_all",
    ] {
        let definition = definitions
            .iter()
            .find(|definition| definition.id.as_str() == function_id)
            .unwrap_or_else(|| panic!("missing {function_id}"));
        assert!(
            definition.model_tool.is_none(),
            "{function_id} must not enter a provider request"
        );
    }
}
