use super::*;
use crate::domains::capability_support::implementations::primitive_surface::{
    EngineCapabilityTarget, ResolvedCapabilitySurface,
};
use crate::domains::capability_support::implementations::traits::ExecutionMode;
use crate::engine::{EffectClass, FunctionDefinition, FunctionId, VisibilityScope, WorkerId};
use std::collections::{BTreeMap, HashSet};

fn surface(modes: Vec<(&str, ExecutionMode)>) -> ResolvedCapabilitySurface {
    let mut targets_by_name = BTreeMap::new();
    for (name, mode) in modes {
        let function_id = FunctionId::new(format!("capability::{}", name.to_ascii_lowercase()))
            .expect("function id");
        let function = FunctionDefinition::new(
            function_id.clone(),
            WorkerId::new("capability").expect("worker id"),
            name.to_owned(),
            VisibilityScope::System,
            EffectClass::PureRead,
        );
        let _ = targets_by_name.insert(
            name.to_owned(),
            EngineCapabilityTarget {
                model_capability_id: name.to_owned(),
                function_id,
                function,
                stops_turn: false,
                is_interactive: false,
                execution_mode: mode,
            },
        );
    }
    let all_model_capability_ids = targets_by_name.keys().cloned().collect();
    ResolvedCapabilitySurface {
        catalog_revision: crate::engine::CatalogRevision(0),
        capabilities: Vec::new(),
        targets_by_name,
        all_model_capability_ids,
        turn_stopping_capabilities: HashSet::new(),
    }
}

#[test]
fn turn_result_success() {
    let tr = TurnResult {
        success: true,
        capability_invocations_executed: 2,
        stop_reason: Some(StopReason::EndTurn),
        ..Default::default()
    };
    assert!(tr.success);
    assert_eq!(tr.capability_invocations_executed, 2);
    assert_eq!(tr.stop_reason, Some(StopReason::EndTurn));
}

#[test]
fn build_execution_waves_parallel_capabilities_share_one_wave() {
    let calls = vec![
        crate::shared::messages::CapabilityInvocationDraft::new("1", "search", Default::default()),
        crate::shared::messages::CapabilityInvocationDraft::new("2", "inspect", Default::default()),
    ];
    let surface = surface(vec![
        ("search", ExecutionMode::Parallel),
        ("inspect", ExecutionMode::Parallel),
    ]);
    let waves = capability_invocations::build_execution_waves(&calls, &surface);
    assert_eq!(waves, vec![vec![0, 1]]);
}

#[test]
fn build_execution_waves_serialized_capabilities_are_sequenced() {
    let calls = vec![
        crate::shared::messages::CapabilityInvocationDraft::new("1", "A", Default::default()),
        crate::shared::messages::CapabilityInvocationDraft::new("2", "B", Default::default()),
        crate::shared::messages::CapabilityInvocationDraft::new("3", "C", Default::default()),
    ];
    let surface = surface(vec![
        ("A", ExecutionMode::Serialized("browser".into())),
        ("B", ExecutionMode::Serialized("browser".into())),
        ("C", ExecutionMode::Parallel),
    ]);
    let waves = capability_invocations::build_execution_waves(&calls, &surface);
    assert_eq!(waves, vec![vec![0, 2], vec![1]]);
}

#[test]
fn build_execution_waves_keeps_read_primitives_from_blocking_execute() {
    let calls = vec![
        crate::shared::messages::CapabilityInvocationDraft::new("1", "search", Default::default()),
        crate::shared::messages::CapabilityInvocationDraft::new("2", "execute", Default::default()),
        crate::shared::messages::CapabilityInvocationDraft::new("3", "execute", Default::default()),
    ];
    let surface = surface(vec![
        (
            "search",
            ExecutionMode::Serialized("capability-read".into()),
        ),
        (
            "execute",
            ExecutionMode::Serialized("capability-execute".into()),
        ),
    ]);
    let waves = capability_invocations::build_execution_waves(&calls, &surface);
    assert_eq!(waves, vec![vec![0, 1], vec![2]]);
}
