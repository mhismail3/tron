use super::*;
use crate::domains::agent::r#loop::primitive_surface::ExecutionMode;
use crate::domains::agent::r#loop::primitive_surface::{
    PrimitiveExecutionTarget, ResolvedPrimitiveSurface,
};
use crate::engine::{EffectClass, FunctionDefinition, FunctionId, VisibilityScope, WorkerId};
use std::collections::{BTreeMap, HashSet};

fn surface(mode: ExecutionMode) -> ResolvedPrimitiveSurface {
    let mut targets_by_name = BTreeMap::new();
    let function_id = FunctionId::new("capability::execute").expect("function id");
    let function = FunctionDefinition::new(
        function_id.clone(),
        WorkerId::new("capability").expect("worker id"),
        "execute",
        VisibilityScope::System,
        EffectClass::DelegatedInvocation,
    );
    let _ = targets_by_name.insert(
        "execute".to_owned(),
        PrimitiveExecutionTarget {
            model_capability_id: "execute".to_owned(),
            function_id,
            function,
            stops_turn: false,
            execution_mode: mode,
        },
    );
    ResolvedPrimitiveSurface {
        capabilities: Vec::new(),
        targets_by_name,
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
fn build_execution_waves_parallel_execute_calls_share_one_wave() {
    let calls = vec![
        crate::shared::protocol::messages::CapabilityInvocationDraft::new(
            "1",
            "execute",
            Default::default(),
        ),
        crate::shared::protocol::messages::CapabilityInvocationDraft::new(
            "2",
            "execute",
            Default::default(),
        ),
    ];
    let surface = surface(ExecutionMode::Parallel);
    let waves = capability_invocations::build_execution_waves(&calls, &surface);
    assert_eq!(waves, vec![vec![0, 1]]);
}

#[test]
fn build_execution_waves_serialized_execute_calls_are_sequenced() {
    let calls = vec![
        crate::shared::protocol::messages::CapabilityInvocationDraft::new(
            "1",
            "execute",
            Default::default(),
        ),
        crate::shared::protocol::messages::CapabilityInvocationDraft::new(
            "2",
            "execute",
            Default::default(),
        ),
        crate::shared::protocol::messages::CapabilityInvocationDraft::new(
            "3",
            "execute",
            Default::default(),
        ),
    ];
    let surface = surface(ExecutionMode::Serialized("capability-execute".into()));
    let waves = capability_invocations::build_execution_waves(&calls, &surface);
    assert_eq!(waves, vec![vec![0], vec![1], vec![2]]);
}
