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
        8
    );
    assert_eq!(
        tools
            .iter()
            .filter(|tool| matches!(tool.audience, ModelToolAudience::Specialist))
            .count(),
        10
    );

    let ordinary = tools
        .iter()
        .filter(|tool| matches!(tool.audience, ModelToolAudience::Ordinary))
        .map(|tool| tool.name.as_str())
        .collect::<BTreeSet<_>>();
    assert_eq!(
        ordinary,
        BTreeSet::from([
            "agent_discover",
            "agent_manage",
            "agent_send",
            "agent_spawn",
            "agent_wait",
            "result_read",
            "worker_discover",
            "worker_invoke",
        ])
    );

    let specialist = tools
        .iter()
        .filter(|tool| matches!(tool.audience, ModelToolAudience::Specialist))
        .map(|tool| tool.name.as_str())
        .collect::<BTreeSet<_>>();
    assert_eq!(
        specialist,
        BTreeSet::from([
            "worker_disable",
            "worker_enable",
            "worker_inbox",
            "worker_inspect",
            "worker_list",
            "worker_retire",
            "worker_rollback",
            "worker_runs",
            "worker_stop",
            "worker_upsert",
        ])
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
        "result_read",
        "agent_discover",
        "agent_spawn",
        "agent_send",
        "agent_wait",
        "agent_manage",
    ] {
        assert!(
            ordinary_names.contains(required),
            "{required} must remain available to an ordinary main agent"
        );
    }

    for removed in [
        "worker_await",
        "worker_cancel",
        "worker_result_read",
        "worker_detach",
        "worker_purge",
        "agent_wait_for_workers",
        "agent_mailbox_list",
        "agent_mailbox_claim",
    ] {
        assert!(
            !ordinary_names.contains(removed),
            "{removed} must not remain in the ordinary model surface"
        );
    }
}

#[test]
fn worker_invoke_contract_distinguishes_nested_enqueue_from_nested_wait() {
    let definitions = contract::function_definitions().expect("worker-kernel contracts");
    let invoke = definitions
        .iter()
        .find(|definition| definition.id.as_str() == "worker_kernel::invoke")
        .expect("worker invoke contract");
    assert!(
        invoke
            .description
            .contains("mode=enqueue returns immediately")
    );
    assert!(
        invoke
            .description
            .contains("nested mode=wait synchronously joins")
    );
    assert!(
        invoke
            .description
            .contains("Reusable parent assignments structurally join")
    );
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
